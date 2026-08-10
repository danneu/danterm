// The retained-row shape probe: how long retained rows are, what they are made of, how
// many are blank, and what the allocator actually charges for them.
//
// This is the instrument doc 28's Phase 2 needs for `research/28/F9` (blank-row frequency, sizing
// `research/28/H2`'s ceiling) and `research/28/F10` (allocator behavior under ragged rows, sizing whether `research/28/H3`'s
// paper savings survive malloc's size classes). Both questions are answered by the same
// two facts about a history -- the distribution of *stored* cells per retained row, and
// what malloc hands back for a request of that size -- so they share one instrument
// rather than two that could disagree.
//
// Phase 3 added the third fact, for `research/28/F11`: what a retained row's cells actually *contain*.
// `research/28/F8` and `research/28/F10` both closed on the same stated gap -- `styledCellCount` and
// `multiScalarCellCount` were zero in every run, so `research/28/H3`'s packing argument had never met
// the content that would stress it. A packing scheme is priced against composition, not
// against length: a representation that compresses what real rows do not contain wins
// nothing. `RetainedRowComposition` is that measurement, carried as parallel per-row
// arrays alongside `storedCellCounts` so every reduction stays re-derivable from raw
// counts.
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
// or a verdict -- `research/28/F9` and `research/28/F10` are sizing measurements, and neither has a second arm.
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
/// engine does not expose, and because `derivationMatchesCensus` plus `research/28/F8`'s independently
/// measured per-row residual are what check the model.
public let arrayStorageHeaderBytes = 32

/// Rounds an allocation request the way macOS malloc really does.
///
/// `malloc_good_size` is the allocator's own answer, not a table of size classes modelled
/// from memory -- the same reason `research/15/D4` charges `Array.capacity` instead of
/// predicting buckets. `research/28/F10`'s whole question is what this function does to ragged
/// requests, so asking libmalloc is the measurement.
public func allocatedBytes(forRequest request: Int) -> Int {
    request <= 0 ? 0 : malloc_good_size(request)
}

/// What one retained row's cell array costs, from its stored cell count.
public func rowAllocation(storedCells: Int, cellStrideBytes: Int) -> (request: Int, allocated: Int) {
    let request = arrayStorageHeaderBytes + storedCells * cellStrideBytes
    return (request, allocatedBytes(forRequest: request))
}

/// UTF-8 bytes one scalar encodes to, which is what a text-packed row would store per
/// scalar.
///
/// Spelled out rather than taken from `String(scalar).utf8.count` so the probe does not
/// allocate a `String` per cell across a saturated history, and so the boundaries a packing
/// scheme would care about (1/2/3/4 bytes) are visible where they are used.
public func utf8ByteCount(of scalar: Unicode.Scalar) -> Int {
    switch scalar.value {
    case 0..<0x80: 1
    case 0x80..<0x800: 2
    case 0x800..<0x1_0000: 3
    default: 4
    }
}

/// What retained rows are made of, per row, oldest first and index-aligned with
/// `RetainedRowShapeReport.storedCellCounts`.
///
/// Parallel arrays rather than an array of structs: every element is a bare integer, so the
/// JSON stays compact across a saturated history, and each axis can be pooled independently
/// without the reader having to trust a summary. The axes are deliberately *orthogonal*
/// (style, scalar count, scalar width, cell kind, hyperlink) instead of a single "row type"
/// enum, because a packing scheme prices each axis separately -- run-length styles care
/// about `styleRunCounts`, a text-packed payload about `utf8ByteCounts`, a narrow scalar
/// slot about `nonASCIIScalarCounts` -- and a row that is styled *and* multi-scalar must be
/// countable in both. Row-level classification is the driver's reduction, not this type's.
///
/// Every array here is per display row. The three `contentIdentity` axes that used to sit
/// alongside them -- run counts, identified cells, strict run counts -- were retired with
/// the per-row representation they priced: they measured doc 28's per-row candidates
/// `research/28/C1-C6`, and since doc 31's record arena shipped the engine picks a record's identity
/// encoding at admission time (`LogicalLineStore`'s `identityPerCell` fallback), so the
/// question they were built to answer is closed. This is the same retirement
/// `packedPayloadModelBytes` took. `Terminal.scrollbackRecordContentIdentityShape` survives
/// in the engine, so a future model that needs the axis can re-add it *per record* -- which
/// is the unit it is now measured in, and the mismatch with these per-row arrays that made
/// carrying it here a driver-level length error.
public struct RetainedRowComposition: Codable, Equatable, Sendable {
    /// Stored cells whose style differs from the default -- what a style side-table or a
    /// run-length style encoding has to represent.
    public let styledCellCounts: [Int]

    /// Stored cells carrying more than one scalar (a combining sequence, an emoji ZWJ
    /// cluster). These are the cells no fixed-width scalar slot can hold inline.
    public let multiScalarCellCounts: [Int]

    /// Stored cells carrying no scalar at all: interior padding, wide tails, and cells that
    /// exist only because a background-erase style or a later column made them non-default.
    public let emptyScalarCellCounts: [Int]

    /// Total scalars across the row's stored cells -- the element count a packed scalar
    /// buffer would hold.
    public let scalarCounts: [Int]

    /// Scalars at or above U+0080. The share that decides whether a one-byte-per-scalar
    /// packed form needs an escape hatch or is simply wrong.
    public let nonASCIIScalarCounts: [Int]

    /// Total UTF-8 bytes across the row's stored scalars -- the payload size of a
    /// text-packed row.
    public let utf8ByteCounts: [Int]

    /// Maximal runs of equal style across the stored prefix, counting the leading run. A row
    /// of one uniform style has 1; this is the length of a run-length style encoding.
    public let styleRunCounts: [Int]

    /// Distinct styles present in the stored prefix -- the size of a per-row style table.
    public let distinctStyleCounts: [Int]

    /// Stored cells participating in wide-cell geometry (`wideHead`, `wideTail`,
    /// `spacerHead`). A packed form still owes the observability contract for these.
    public let wideCellCounts: [Int]

    /// Stored cells carrying OSC 8 hyperlink metadata.
    public let hyperlinkCellCounts: [Int]

    /// The largest scalar value held by a *single-scalar* cell in the row, or 0 when the row
    /// has none.
    ///
    /// Single-scalar cells only, because a fixed-width scalar slot is a question about the
    /// cells that fit in one: a multi-scalar cell needs an indirection whatever the slot
    /// width is. This is what decides whether a row can use a 1-, 2-, or 4-byte slot, and it
    /// is measured rather than assumed because the whole 1-byte tier stands or falls on it.
    public let maxSingleScalarValues: [Int]

    public init(
        styledCellCounts: [Int],
        multiScalarCellCounts: [Int],
        emptyScalarCellCounts: [Int],
        scalarCounts: [Int],
        nonASCIIScalarCounts: [Int],
        utf8ByteCounts: [Int],
        styleRunCounts: [Int],
        distinctStyleCounts: [Int],
        wideCellCounts: [Int],
        hyperlinkCellCounts: [Int],
        maxSingleScalarValues: [Int]
    ) {
        self.styledCellCounts = styledCellCounts
        self.multiScalarCellCounts = multiScalarCellCounts
        self.emptyScalarCellCounts = emptyScalarCellCounts
        self.scalarCounts = scalarCounts
        self.nonASCIIScalarCounts = nonASCIIScalarCounts
        self.utf8ByteCounts = utf8ByteCounts
        self.styleRunCounts = styleRunCounts
        self.distinctStyleCounts = distinctStyleCounts
        self.wideCellCounts = wideCellCounts
        self.hyperlinkCellCounts = hyperlinkCellCounts
        self.maxSingleScalarValues = maxSingleScalarValues
    }

    /// Retained rows holding at least one styled cell.
    public var styledRowCount: Int { styledCellCounts.count(where: { $0 > 0 }) }

    /// Retained rows holding at least one multi-scalar cell.
    public var multiScalarRowCount: Int { multiScalarCellCounts.count(where: { $0 > 0 }) }
}

/// One stimulus's retained-row shape, plus every quantity `F9` and `F10` are reduced from.
///
/// Raw counts are retained alongside the reductions -- `storedCellCounts` is the whole
/// distribution -- because `research/20/F12` is the standing example of an artifact that had to be
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

    /// What those stored cells contain, index-aligned with `storedCellCounts`. The
    /// measurement `F11` needs, and the one `F8` and `F10` both named as missing.
    public let composition: RetainedRowComposition

    /// Live screen rows the census also counts, so a reader can see why the derived
    /// scrollback total is smaller than `census.cellStorageBytes`.
    public let screenRowCount: Int

    /// The census's exact cell-storage total, carried so the derivation can be audited
    /// rather than trusted.
    public let censusCellStorageBytes: Int

    /// What history's record arena really holds, straight from the census -- headers, cells and
    /// in-arena side tables. The quantity the byte budget is spent on.
    ///
    /// Denominated per *logical line* since doc 31, not per display row: there is one header per
    /// record rather than per retained row, which is why `packedPayloadModelBytes` -- a per-row
    /// model of `research/28/C6` -- was retired with the representation it described.
    public let censusRetainedArenaBytesInUse: Int

    /// Retained stored cells the census counted, held against the extent this probe derives
    /// from the public row reader.
    public let censusRetainedStoredCellCount: Int

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
        composition: RetainedRowComposition,
        screenRowCount: Int,
        censusCellStorageBytes: Int,
        censusRetainedArenaBytesInUse: Int,
        censusRetainedStoredCellCount: Int,
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
        self.composition = composition
        self.screenRowCount = screenRowCount
        self.censusCellStorageBytes = censusCellStorageBytes
        self.censusRetainedArenaBytesInUse = censusRetainedArenaBytesInUse
        self.censusRetainedStoredCellCount = censusRetainedStoredCellCount
        self.derivationMatchesCensus = derivationMatchesCensus
        self.allocatedBytes = storedCellCounts.reduce(0) {
            $0 + rowAllocation(storedCells: $1, cellStrideBytes: cellStrideBytes).allocated
        }
    }

    /// Arena bytes per retained display row -- the successor to the figure `research/28/F18` priced at
    /// 423.0 on the CRLF reference payload, restated against the record arena.
    public var packedPayloadBytesPerRow: Double {
        retainedRowCount == 0
            ? 0
            : Double(censusRetainedArenaBytesInUse) / Double(retainedRowCount)
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

    var styledCellCounts: [Int] = []
    var multiScalarCellCounts: [Int] = []
    var emptyScalarCellCounts: [Int] = []
    var scalarCounts: [Int] = []
    var nonASCIIScalarCounts: [Int] = []
    var utf8ByteCounts: [Int] = []
    var styleRunCounts: [Int] = []
    var distinctStyleCounts: [Int] = []
    var wideCellCounts: [Int] = []
    var hyperlinkCellCounts: [Int] = []
    var maxSingleScalarValues: [Int] = []
    let defaultStyle = TerminalStyle()

    for index in 0..<terminal.scrollbackRowCount {
        guard let row = terminal.scrollbackRow(at: index) else { continue }
        let lastContentColumn = row.cells.lastIndex(where: { $0 != defaultTerminalCell })
        if lastContentColumn == nil { blankRowCount += 1 }
        let storedCount = (lastContentColumn ?? 0) + 1
        storedCellCounts.append(storedCount)

        // Composition is read over the *stored* prefix only. The public reader materializes
        // the row to full width, and the trailing default cells it appends are exactly the
        // ones canonical form does not store -- counting them would report the pane's width
        // rather than the row's content.
        var styled = 0, multiScalar = 0, emptyScalar = 0, scalars = 0
        var nonASCII = 0, utf8Bytes = 0, wide = 0, hyperlinks = 0, runs = 0
        var maxSingleScalar = 0
        var distinctStyles: Set<TerminalStyle> = []
        var previousStyle: TerminalStyle?
        for cell in row.cells.prefix(storedCount) {
            if cell.style != defaultStyle { styled += 1 }
            let scalarCount = cell.scalars.count
            scalars += scalarCount
            if scalarCount == 0 { emptyScalar += 1 }
            if scalarCount > 1 { multiScalar += 1 }
            if scalarCount == 1, let scalar = cell.scalars.first {
                maxSingleScalar = max(maxSingleScalar, Int(scalar.value))
            }
            for scalar in cell.scalars {
                if scalar.value >= 0x80 { nonASCII += 1 }
                utf8Bytes += utf8ByteCount(of: scalar)
            }
            switch cell.kind {
            case .wideHead, .wideTail, .spacerHead: wide += 1
            case .narrow, .padding: break
            }
            if cell.hyperlink != nil { hyperlinks += 1 }
            if previousStyle != cell.style {
                runs += 1
                previousStyle = cell.style
            }
            distinctStyles.insert(cell.style)
        }
        styledCellCounts.append(styled)
        multiScalarCellCounts.append(multiScalar)
        emptyScalarCellCounts.append(emptyScalar)
        scalarCounts.append(scalars)
        nonASCIIScalarCounts.append(nonASCII)
        utf8ByteCounts.append(utf8Bytes)
        styleRunCounts.append(runs)
        distinctStyleCounts.append(distinctStyles.count)
        wideCellCounts.append(wide)
        hyperlinkCellCounts.append(hyperlinks)
        maxSingleScalarValues.append(maxSingleScalar)
    }

    // Live screen rows are always full width -- the grid materializes them at construction
    // and reflow -- so the census's cell-storage total is the live block at the cell stride
    // plus what history's packed blobs hold. Reconstructing both halves is what turns the
    // derivation from an assumption into a check.
    //
    // Retained rows no longer contribute cell-stride bytes at all (`research/28/C1` shipped the
    // packed arena), so the scrollback half of this check is an *extent* claim, not a byte
    // one: `derivationMatchesCensus` below holds the derived stored-cell total against the
    // census's own, and the bytes come from `retainedArenaBytesInUse` rather than being
    // re-priced here.
    let derivedRetainedCells = storedCellCounts.reduce(0, +)
    let derivedStorageBytes = census.screenRowCount * columns * census.cellStrideBytes
        + census.retainedArenaBytesInUse
    return RetainedRowShapeReport(
        stimulus: stimulus,
        columns: columns,
        rows: terminal.geometry.rows.count,
        scrollbackBudgetBytes: Terminal.scrollbackByteLimit,
        fedByteCount: fedByteCount,
        cellStrideBytes: census.cellStrideBytes,
        retainedRowCount: terminal.scrollbackRowCount,
        blankRowCount: blankRowCount,
        storedCellCounts: storedCellCounts,
        composition: RetainedRowComposition(
            styledCellCounts: styledCellCounts,
            multiScalarCellCounts: multiScalarCellCounts,
            emptyScalarCellCounts: emptyScalarCellCounts,
            scalarCounts: scalarCounts,
            nonASCIIScalarCounts: nonASCIIScalarCounts,
            utf8ByteCounts: utf8ByteCounts,
            styleRunCounts: styleRunCounts,
            distinctStyleCounts: distinctStyleCounts,
            wideCellCounts: wideCellCounts,
            hyperlinkCellCounts: hyperlinkCellCounts,
            maxSingleScalarValues: maxSingleScalarValues
        ),
        screenRowCount: census.screenRowCount,
        censusCellStorageBytes: census.cellStorageBytes,
        censusRetainedArenaBytesInUse: census.retainedArenaBytesInUse,
        censusRetainedStoredCellCount: census.retainedStoredCellCount,
        derivationMatchesCensus: derivedRetainedCells == census.retainedStoredCellCount
            && derivedStorageBytes == census.cellStorageBytes
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
