// The retained-row shape probe: how long retained rows are, how many are blank, and what
// the allocator actually charges for them.
//
// This is the instrument doc 28's Phase 2 needs for `F9` (blank-row frequency, sizing
// `H2`'s ceiling) and `F10` (allocator behavior under ragged rows, sizing whether `H3`'s
// paper savings survive malloc's size classes). Both questions are answered by the same
// two facts about a history -- the distribution of *stored* cells per retained row, and
// what malloc hands back for a request of that size -- so they share one instrument
// rather than two that could disagree.
//
// Why it can read stored extents without touching the engine: canonical form means a
// retained row's stored cells are a pure function of its observable content, so the
// stored extent is *derivable* from the public row reader -- it is the index of the last
// non-default cell, plus one, floored at one. That derivation is not assumed here; every
// report carries `derivationMatchesCensus`, which holds the derived cell total against
// `Terminal.memoryCensus`'s exact arithmetic. A representation change that broke the
// derivation would flip that flag rather than silently produce plausible numbers.
//
// Belongs here: the per-row derivation, the size-class arithmetic, and the reductions the
// two findings quote. Does not belong here: a stimulus corpus (the driver supplies bytes,
// so the probe cannot be accused of shaping content to flatter a hypothesis), a threshold,
// or a verdict -- `F9` and `F10` are sizing measurements, and neither has a second arm.
//
// Depends on `TerminalCore` and Darwin's `malloc_good_size` alone. No planning, no
// rendering, no AppKit, and no timing: nothing here is a hot path and nothing here is
// measured against a clock.
import Darwin
import Foundation
import TerminalCore

/// The public image of a default `GridCell` -- what a never-written column reads as.
///
/// Canonical trimming is defined against cell equality with a default cell, so the
/// derivation needs exactly this value and nothing about the engine's private types.
public let defaultTerminalCell = TerminalCell(
    kind: .padding,
    scalars: .empty,
    style: TerminalStyle(),
    hyperlink: nil
)

/// Bytes a Swift array's storage header costs on top of its elements.
///
/// Mirrors `Terminal.arrayStorageHeaderBytes`, which is private to the engine. Restated
/// rather than plumbed out because the probe must be able to model an allocation the
/// engine does not expose, and because `derivationMatchesCensus` plus `F8`'s independently
/// measured per-row residual are what check the model.
public let arrayStorageHeaderBytes = 32

/// Rounds an allocation request the way macOS malloc really does.
///
/// `malloc_good_size` is the allocator's own answer, not a table of size classes modelled
/// from memory -- the same reason doc 15's `D4` charges `Array.capacity` instead of
/// predicting buckets. `F10`'s whole question is what this function does to ragged
/// requests, so asking libmalloc is the measurement.
public func allocatedBytes(forRequest request: Int) -> Int {
    request <= 0 ? 0 : malloc_good_size(request)
}

/// What one retained row's cell array costs, from its stored cell count.
public func rowAllocation(storedCells: Int, cellStrideBytes: Int) -> (request: Int, allocated: Int) {
    let request = arrayStorageHeaderBytes + storedCells * cellStrideBytes
    return (request, allocatedBytes(forRequest: request))
}

/// One stimulus's retained-row shape, plus every quantity `F9` and `F10` are reduced from.
///
/// Raw counts are retained alongside the reductions -- `storedCellCounts` is the whole
/// distribution -- because `20/F12` is the standing example of an artifact that had to be
/// recovered by hand when only a summary was kept.
public struct RetainedRowShapeReport: Codable, Equatable, Sendable {
    public let stimulus: String
    public let columns: Int
    public let rows: Int
    public let scrollbackBudgetBytes: Int
    public let fedByteCount: Int
    public let cellStrideBytes: Int

    /// Retained rows present when the shape was read.
    public let retainedRowCount: Int

    /// Retained rows whose every column reads as a default cell. These are the rows `H2`
    /// proposes to back with one shared allocation, and canonical form stores each of them
    /// as exactly one cell.
    public let blankRowCount: Int

    /// Stored cells per retained row, oldest first. The distribution `F10` needs.
    public let storedCellCounts: [Int]

    /// Live screen rows the census also counts, so a reader can see why the derived
    /// scrollback total is smaller than `census.cellStorageBytes`.
    public let screenRowCount: Int

    /// The census's exact cell-storage total, carried so the derivation can be audited
    /// rather than trusted.
    public let censusCellStorageBytes: Int

    /// True when derived scrollback cells plus full-width screen rows reconstruct the
    /// census exactly. False means the derivation no longer describes the representation,
    /// and every byte below it is unusable -- which is the state this flag exists to make
    /// loud instead of silent.
    public let derivationMatchesCensus: Bool

    /// What malloc really hands back for these rows' requests -- the quantity a footprint
    /// measurement sees, and the one `F10` asks about.
    ///
    /// Stored rather than computed so it survives encoding: it is the only number in this
    /// report that cannot be re-derived without asking libmalloc, which is exactly why the
    /// driver re-derives everything *else* and compares this one against its own modelled
    /// size classes. A disagreement means the model is wrong, and the allocator wins.
    public let allocatedBytes: Int

    public init(
        stimulus: String,
        columns: Int,
        rows: Int,
        scrollbackBudgetBytes: Int,
        fedByteCount: Int,
        cellStrideBytes: Int,
        retainedRowCount: Int,
        blankRowCount: Int,
        storedCellCounts: [Int],
        screenRowCount: Int,
        censusCellStorageBytes: Int,
        derivationMatchesCensus: Bool
    ) {
        self.stimulus = stimulus
        self.columns = columns
        self.rows = rows
        self.scrollbackBudgetBytes = scrollbackBudgetBytes
        self.fedByteCount = fedByteCount
        self.cellStrideBytes = cellStrideBytes
        self.retainedRowCount = retainedRowCount
        self.blankRowCount = blankRowCount
        self.storedCellCounts = storedCellCounts
        self.screenRowCount = screenRowCount
        self.censusCellStorageBytes = censusCellStorageBytes
        self.derivationMatchesCensus = derivationMatchesCensus
        self.allocatedBytes = storedCellCounts.reduce(0) {
            $0 + rowAllocation(storedCells: $1, cellStrideBytes: cellStrideBytes).allocated
        }
    }

    /// Fraction of retained rows that are entirely blank -- `F9`'s headline number.
    public var blankRowFraction: Double {
        retainedRowCount == 0 ? 0 : Double(blankRowCount) / Double(retainedRowCount)
    }

    /// Exact stored bytes across retained rows, excluding headers and rounding.
    public var storedCellBytes: Int {
        storedCellCounts.reduce(0) { $0 + $1 * cellStrideBytes }
    }

    /// What the retained rows asked malloc for, headers included.
    public var requestBytes: Int {
        storedCellCounts.reduce(0) { $0 + rowAllocation(storedCells: $1, cellStrideBytes: cellStrideBytes).request }
    }

    /// Bytes malloc's size classes add on top of what was asked for.
    public var roundingBytes: Int { allocatedBytes - requestBytes }

    /// Rounding as a share of what the allocator handed back.
    public var roundingFractionOfAllocated: Double {
        allocatedBytes == 0 ? 0 : Double(roundingBytes) / Double(allocatedBytes)
    }

    /// What the same rows would have cost stored full width -- the pre-trim shape, priced
    /// through the same allocator. The denominator of `F10`'s "did the savings survive"
    /// question.
    public var fullWidthAllocatedBytes: Int {
        let perRow = rowAllocation(storedCells: columns, cellStrideBytes: cellStrideBytes)
        return retainedRowCount * perRow.allocated
    }

    /// Ragged storage's realized saving against full width, after rounding.
    public var realizedSavingFraction: Double {
        fullWidthAllocatedBytes == 0 ? 0 : 1 - Double(allocatedBytes) / Double(fullWidthAllocatedBytes)
    }

    /// The same saving on paper -- before the allocator rounds either side.
    public var paperSavingFraction: Double {
        let fullWidthRequest = retainedRowCount
            * rowAllocation(storedCells: columns, cellStrideBytes: cellStrideBytes).request
        return fullWidthRequest == 0 ? 0 : 1 - Double(requestBytes) / Double(fullWidthRequest)
    }

    /// Bytes a shared blank-row allocation could reclaim, at zero overhead: every blank
    /// row's storage block but one.
    ///
    /// This is `H2`'s ceiling for this stimulus, stated the way `F8` stated `H4`'s -- best
    /// case, no mechanism cost, absolute bytes. It counts only the heap block: the row's
    /// `GridRow` slot lives in history's own buffer and sharing storage does not remove it.
    public var sharedBlankCeilingBytes: Int {
        guard blankRowCount > 1 else { return 0 }
        let perBlank = rowAllocation(storedCells: 1, cellStrideBytes: cellStrideBytes).allocated
        return (blankRowCount - 1) * perBlank
    }

    /// `H2`'s ceiling as a share of what retained rows actually allocate.
    public var sharedBlankCeilingFractionOfAllocated: Double {
        allocatedBytes == 0 ? 0 : Double(sharedBlankCeilingBytes) / Double(allocatedBytes)
    }
}

/// Reads one terminal's retained-row shape without mutating it.
///
/// Separated from the feeding so a test can build a terminal with known rows and hold this
/// derivation against the census directly, which is the only check that the public-API
/// derivation still describes canonical storage.
public func readRetainedRowShape(
    of terminal: Terminal,
    stimulus: String,
    fedByteCount: Int
) -> RetainedRowShapeReport {
    let census = terminal.memoryCensus
    let columns = terminal.geometry.columns
    var storedCellCounts: [Int] = []
    storedCellCounts.reserveCapacity(terminal.scrollbackRowCount)
    var blankRowCount = 0

    for index in 0..<terminal.scrollbackRowCount {
        guard let row = terminal.scrollbackRow(at: index) else { continue }
        let lastContentColumn = row.cells.lastIndex(where: { $0 != defaultTerminalCell })
        if lastContentColumn == nil { blankRowCount += 1 }
        storedCellCounts.append((lastContentColumn ?? 0) + 1)
    }

    // Live screen rows are always full width -- the grid materializes them at construction
    // and reflow -- so the census total is the derived scrollback cells plus that block.
    // Reconstructing it is what turns the derivation from an assumption into a check.
    let derivedCells = storedCellCounts.reduce(0, +) + census.screenRowCount * columns
    return RetainedRowShapeReport(
        stimulus: stimulus,
        columns: columns,
        rows: terminal.geometry.rows.count,
        scrollbackBudgetBytes: Terminal.productionScrollbackBudgetBytes,
        fedByteCount: fedByteCount,
        cellStrideBytes: census.cellStrideBytes,
        retainedRowCount: terminal.scrollbackRowCount,
        blankRowCount: blankRowCount,
        storedCellCounts: storedCellCounts,
        screenRowCount: census.screenRowCount,
        censusCellStorageBytes: census.cellStorageBytes,
        derivationMatchesCensus: derivedCells * census.cellStrideBytes == census.cellStorageBytes
    )
}

/// Feeds one stimulus into a fresh terminal at the given geometry and reads its shape.
///
/// Chunked feeding mirrors `TerminalMemoryProbeSupport.measure`: a stimulus arrives from a
/// PTY in reads, and feeding one giant buffer would build a token array proportional to the
/// whole stream. Nothing here is timed, so this only matters for peak transient memory --
/// but the two probes measuring the same corpus should drive the engine the same way.
public func measureRetainedRowShape(
    stimulus: String,
    chunks: [[UInt8]],
    columns: Int,
    rows: Int
) -> RetainedRowShapeReport? {
    guard var terminal = Terminal(columns: columns, rows: rows) else { return nil }
    var fedByteCount = 0
    for chunk in chunks {
        terminal.feed(chunk)
        fedByteCount += chunk.count
    }
    return readRetainedRowShape(of: terminal, stimulus: stimulus, fedByteCount: fedByteCount)
}
