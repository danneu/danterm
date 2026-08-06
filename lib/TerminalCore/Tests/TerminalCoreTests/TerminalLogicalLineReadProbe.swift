// The research/31/F1 read-path probe for doc 31: does storing history as unwrapped logical lines and
// wrapping at read cost more to *browse* than today's display-row store?
//
// Two arms, one process, interleaved. **Baseline** is today's shape: one
// `Terminal.PackedRetainedRow` per display row, addressed at an O(1) index, read through the
// same `forEachKind` + `forEachContentCell` walks the browse path uses (`research/28/F17`).
// **Candidate** is doc 31's sketch: one contiguous byte arena of variable-length logical-line
// records, plus a derived block index (per-line record offsets, blocked, one cached
// display-row total per block) whose display-row lookup is a binary search then an in-block
// scan. Both arms read the *same cells in the same order* and prove it with a checksum.
//
// Belongs here: the two stores, the two access patterns research/31/D1 froze (sequential browse, random
// seek), the stimulus that reproduces `research/28/F23`'s content distribution, and the calibration
// that decides whether a run may be quoted. Does not belong here: a threshold, a verdict, or
// anything a production type has to change to accommodate. Nothing in `lib/TerminalCore`'s
// sources is touched by this file, and the candidate store is local to it -- Phase 1
// prototypes live in a test target until `research/31/D1` answers go (doc 31, Investigation rules).
//
// `TerminalLogicalLineIndexProbe.swift` (research/31/F2) reuses `LogicalLineArena` from this file and adds
// its own harness there rather than editing the arms above; the arena's synthetic initializer
// and its second counting-pass variant are the only things research/31/F2 added here, because they need the
// type's private storage.
//
// It lives in the test target for the same reason `TerminalHistoryDepthSizingProbe` does: it
// needs `@testable` reach into `PackedRetainedRow` and the cap-taking initializer, which are
// internal on purpose.
//
// Not part of the `just test` gate. Every measurement is skipped unless
// `DANTERM_LOGICAL_LINE_PROBE` is set. Run it as:
//
//     DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
//       --filter TerminalLogicalLineReadProbe
//
// Release matters: the thresholds in `research/31/D1` are derived from release-build measurements.
import Foundation
import Testing

@testable import TerminalCore

// MARK: - Stimulus

/// The two content classes `research/31/D1` froze, kept as data so a report names the shape it measured.
///
/// `mix` must land inside `research/28/F23`'s measured band (display-row cell counts, median 119-154,
/// p95 179) or the run is void for that class -- the band is a validity gate, not a target to
/// approach. `full` is `research/28/F23`'s `bound/wide-full-width-saturation`: every display row full.
enum LogicalLineContentClass: String, CaseIterable {
    case mix
    case full
}

/// A fixed-seed LCG, so the stimulus and the seek order are byte-identical between arms,
/// between rounds, and between runs. Nothing here may consult a clock or a system RNG:
/// two arms that read different rows are not a comparison.
struct DeterministicSequence {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 17
    }

    mutating func next(below bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

/// Generates the logical lines a class is made of.
///
/// `mix`'s length distribution is the only tuned quantity in this file, and it is tuned
/// against the calibration gate alone -- the achieved distribution is printed, and the
/// tuning happened before any arm was timed.
func logicalLines(for contentClass: LogicalLineContentClass, count: Int) -> [String] {
    var random = DeterministicSequence(seed: 0x5EED_31F1)
    var lines: [String] = []
    lines.reserveCapacity(count)
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 -_/.:")

    for index in 0..<count {
        let length: Int
        switch contentClass {
        case .mix:
            // Two regimes, mirroring what `research/28/F23` found real sessions retain at 179
            // columns: most lines wrap at least once (which is what puts p95 at the full
            // width), and a minority are short enough to leave a partial row.
            length = random.next(below: 100) < 55
                ? 180 + random.next(below: 260)
                : 20 + random.next(below: 150)
        case .full:
            // An exact multiple of 179, so every display row this line produces is full.
            length = 179 * (1 + random.next(below: 3))
        }
        var line = String()
        line.reserveCapacity(length)
        for offset in 0..<length {
            line.append(alphabet[(index &* 31 &+ offset &* 7) % alphabet.count])
        }
        lines.append(line)
    }
    return lines
}

// MARK: - Retained content, taken from the real engine

/// The display rows and logical lines one stimulus produced, as the engine itself wrapped them.
///
/// Both arms are built from this single structure, which is what makes them a comparison of
/// storage shape rather than of two independent wrap implementations. The logical lines are
/// not the generator's strings: they are recovered from the engine's retained rows by joining
/// on `isSoftWrapped`, so the candidate arm stores exactly the cells the baseline arm stores.
struct RetainedStimulus {
    /// One entry per display row, in display order. Cells are full-width for every row that
    /// soft-wraps into the next, and canonically trimmed for the last row of a logical line.
    let displayRows: [Terminal.GridRow]
    /// Index into `displayRows` of each logical line's first row, plus a terminating index.
    let lineStarts: [Int]
    let columns: Int

    var displayRowCount: Int { displayRows.count }
    var lineCount: Int { lineStarts.count - 1 }

    /// Display-row cell counts, the distribution `research/28/F23` measured and `research/31/D1` gates on.
    func storedCellCounts() -> [Int] {
        displayRows.map { Terminal.PackedRetainedRow.pack($0).storedCellCount }
    }
}

/// Feeds a real `Terminal` and reads back what it retained, trimmed to a logical-line boundary.
///
/// Caps are raised far above production so the fill stops on the stimulus rather than on a
/// bound: this probe is measuring a read path, and a run that silently evicted would be
/// comparing two different histories. `hyperlinkId` and `contentIdentity` are stripped from
/// every cell before either arm sees it -- see `buildStimulus`'s note on why that is the
/// conservative choice.
func buildStimulus(
    contentClass: LogicalLineContentClass,
    targetDisplayRows: Int,
    columns: Int = 179,
    rows: Int = 66
) -> RetainedStimulus {
    var terminal = Terminal(
        columns: columns,
        rows: rows,
        scrollbackBudgetBytes: 1 << 28
    )!

    var fed = 0
    let lines = logicalLines(for: contentClass, count: 40_000)
    while terminal.scrollbackRowCount < targetDisplayRows + rows, fed < lines.count {
        terminal.feed(Array("\(lines[fed])\r\n".utf8))
        fed += 1
    }

    // Take retained rows in display order, stripping the two side-table fields. Both arms
    // lose them, so the comparison stays controlled -- and the loss is *conservative toward
    // the baseline*: under the candidate a content-identity run table would be built once per
    // logical line instead of once per display row, so keeping the tables could only widen
    // the candidate's margin. research/31/F1 therefore measures the wrapping indirection alone.
    var displayRows: [Terminal.GridRow] = []
    var lineStarts: [Int] = [0]
    var index = 0
    while index < terminal.scrollbackRowCount {
        guard var row = terminal.retainedRowForTesting(at: index) else { break }
        for column in row.cells.indices {
            row.cells[column].hyperlinkId = nil
            row.cells[column].contentIdentity = nil
        }
        displayRows.append(row)
        if row.isSoftWrapped == false { lineStarts.append(displayRows.count) }
        index += 1
        if displayRows.count >= targetDisplayRows, row.isSoftWrapped == false { break }
    }
    // A trailing partial logical line would give the candidate a record the baseline's rows
    // do not fully cover. Drop it rather than measure a ragged edge.
    if lineStarts.last != displayRows.count {
        displayRows.removeLast(displayRows.count - lineStarts[lineStarts.count - 1])
    }

    return RetainedStimulus(displayRows: displayRows, lineStarts: lineStarts, columns: columns)
}

// MARK: - Baseline arm: today's store

/// Today's retained-row store, reproduced: one packed row per display row at an O(1) index.
///
/// `Terminal.ScrollbackBuffer` is `private`, so this reproduces its element type, its readers
/// and its index arithmetic rather than calling it. That substitution is research/31/F1's stated fidelity
/// limit. What it does *not* substitute is the encoding or the decode: rows are built by
/// `PackedRetainedRow.pack` and read by the production walks.
struct DisplayRowStore {
    private var rows: [Terminal.PackedRetainedRow]

    init(_ stimulus: RetainedStimulus) {
        rows = stimulus.displayRows.map { Terminal.PackedRetainedRow.pack($0) }
    }

    var displayRowCount: Int { rows.count }

    /// A read that borrows the row in place instead of copying it out of the array.
    ///
    /// **Descriptive, and deliberately not the arm `research/31/D1`'s rule names.** `read` above
    /// reproduces what `ScrollbackBuffer`'s subscript does today -- it returns a
    /// `PackedRetainedRow` *by value*, and that struct owns two Swift arrays, so every row
    /// read retains and releases both. This variant is the control that separates "the
    /// candidate's storage shape is better" from "today's store pays ARC per row read", which
    /// is a competing interpretation research/31/F1 cannot otherwise distinguish and which, if it
    /// dominates, is fixable inside today's design with no storage change at all.
    @inline(__always)
    func readBorrowed(displayRow: Int, into checksum: inout UInt64) {
        rows.withUnsafeBufferPointer { buffer in
            buffer[displayRow].forEachKind { column, kind in
                checksum = checksum &* 31 &+ UInt64(column) &+ UInt64(kind.probeCode)
            }
            buffer[displayRow].forEachContentCell { column, scalars, styleId in
                checksum = checksum &* 31 &+ UInt64(column) &+ UInt64(styleId)
                checksum = checksum &* 31 &+ UInt64(scalars.count)
                if scalars.count > 0 { checksum = checksum &+ UInt64(scalars[0].value) }
            }
        }
    }

    /// The two walks the browse path performs per visible retained row (`research/28/F17`).
    @inline(__always)
    func read(displayRow: Int, into checksum: inout UInt64) {
        let row = rows[displayRow]
        row.forEachKind { column, kind in
            checksum = checksum &* 31 &+ UInt64(column) &+ UInt64(kind.probeCode)
        }
        row.forEachContentCell { column, scalars, styleId in
            checksum = checksum &* 31 &+ UInt64(column) &+ UInt64(styleId)
            checksum = checksum &* 31 &+ UInt64(scalars.count)
            if scalars.count > 0 { checksum = checksum &+ UInt64(scalars[0].value) }
        }
    }
}

// MARK: - Candidate arm: logical-line arena plus derived block index

/// Doc 31's candidate store, prototyped: a contiguous byte arena of logical-line records and
/// a block index derived from the current width.
///
/// Record layout, chosen to keep the cell words 8-byte aligned and to keep the header a
/// single load:
///
///     bytes 0..3   cell count (UInt32)
///     byte  4      flags -- bit 0 soft-continued, bits 1..3 semantic prompt
///     bytes 5..7   spare
///     bytes 8..    cell count x the C1 8-byte cell word, verbatim from `PackedRetainedRow`
///
/// Nothing width-dependent is stored. `blockPrefix` -- the only width-dependent state -- is
/// derived by `recomputeIndex(width:)` and is what `research/31/F2` will price; research/31/F1 builds it once and
/// then only reads it.
struct LogicalLineArena {
    private var arena: [UInt8] = []
    /// The deque of record offsets, one per logical line.
    private var lineOffsets: [Int] = []
    /// Cell count per line, mirrored out of the record headers. Read only by the index
    /// recompute; the in-block scan deliberately reads the header in the arena instead, so
    /// the scan pays the cache cost the real design would pay.
    private var lineCellCounts: [Int] = []
    /// Display rows before block `b`, at the current width. `blockPrefix.count` is
    /// `blockCount + 1`.
    private var blockPrefix: [Int] = []
    private(set) var width: Int
    private let blockSize: Int

    private static let headerBytes = 8
    private static let cellBytes = 8

    var displayRowCount: Int { blockPrefix.last ?? 0 }
    var lineCount: Int { lineOffsets.count }
    var arenaByteCount: Int { arena.count }

    /// Builds the arena from the same retained rows the baseline arm packs.
    ///
    /// A logical line's cells are its display rows concatenated: every row but the last
    /// materialized to the full width, the last one canonically trimmed. That is exactly the
    /// inverse of wrapping, and `verifyWrapArithmetic` is what holds it to that claim.
    init(_ stimulus: RetainedStimulus, blockSize: Int = 256) {
        self.width = stimulus.columns
        self.blockSize = blockSize

        for line in 0..<stimulus.lineCount {
            let start = stimulus.lineStarts[line]
            let end = stimulus.lineStarts[line + 1]
            var cells: [Terminal.GridCell] = []
            cells.reserveCapacity((end - start) * stimulus.columns)
            for row in start..<(end - 1) {
                cells.append(contentsOf: stimulus.displayRows[row].materialized(to: stimulus.columns).cells)
            }
            let lastPacked = Terminal.PackedRetainedRow.pack(stimulus.displayRows[end - 1])
            let lastCells = stimulus.displayRows[end - 1].materialized(to: stimulus.columns).cells
            cells.append(contentsOf: lastCells[0..<lastPacked.storedCellCount])
            append(cells: cells, softContinued: false, promptCode: 0)
        }
        recomputeIndex(width: stimulus.columns)
    }

    private mutating func append(cells: [Terminal.GridCell], softContinued: Bool, promptCode: UInt8) {
        let offset = arena.count
        lineOffsets.append(offset)
        lineCellCounts.append(cells.count)

        arena.append(contentsOf: [UInt8](repeating: 0, count: Self.headerBytes + cells.count * Self.cellBytes))
        arena.withUnsafeMutableBufferPointer { bytes in
            let count = UInt32(cells.count)
            for byte in 0..<4 {
                bytes[offset + byte] = UInt8(truncatingIfNeeded: count >> (8 * UInt32(byte)))
            }
            bytes[offset + 4] = (softContinued ? 1 : 0) | (promptCode << 1)
            for column in cells.indices {
                // The C1 cell word, byte for byte as `PackedRetainedRow.pack` writes it. A
                // divergence here would make the two arms decode different content, which
                // the cross-arm checksum gate exists to catch.
                var word = UInt64(cells[column].kind.probeCode) << 21
                word |= UInt64(cells[column].styleId) << 32
                let scalarCount = cells[column].scalars.count
                if scalarCount == 1 {
                    word |= UInt64(cells[column].scalars[0].value)
                } else if scalarCount > 1 {
                    // The probe's stimulus has no multi-scalar cell; a spill would need the
                    // side array the production row carries, and encoding one silently as a
                    // single scalar would corrupt the comparison.
                    fatalError("probe stimulus produced a multi-scalar cell; arena has no spill table")
                }
                if word == 0 { continue }
                let at = offset + Self.headerBytes + column * Self.cellBytes
                for byte in 0..<Self.cellBytes {
                    bytes[at + byte] = UInt8(truncatingIfNeeded: word >> (8 * byte))
                }
            }
        }
    }

    /// Builds an arena with real record geometry but unpopulated cell payload. **research/31/F2 only.**
    ///
    /// The counting pass reads a record header and nothing else, so an arena whose cell words
    /// are left zero prices it exactly -- and it is the only way to reach 100,000 lines of wide
    /// content, which is hundreds of megabytes and cannot come out of a real `Terminal` at this
    /// probe's cost. What must still be real is the *geometry*: record sizes, header offsets and
    /// the total footprint, because those are what the pointer chase pays for. `research/31/D1`'s gate 2
    /// is the control that holds this claim to account -- at 10,000 lines the synthetic arena
    /// and the real one are both measured, and must agree.
    ///
    /// Not usable for reading: `read` would decode zeros. Nothing in research/31/F2 reads a cell.
    init(syntheticCellCounts counts: [Int], width: Int, blockSize: Int = 256) {
        self.width = width
        self.blockSize = blockSize

        var total = 0
        lineOffsets.reserveCapacity(counts.count)
        for cells in counts {
            lineOffsets.append(total)
            total += Self.headerBytes + cells * Self.cellBytes
        }
        lineCellCounts = counts
        arena = [UInt8](repeating: 0, count: total)
        arena.withUnsafeMutableBufferPointer { bytes in
            for line in counts.indices {
                let offset = lineOffsets[line]
                let count = UInt32(counts[line])
                for byte in 0..<4 {
                    bytes[offset + byte] = UInt8(truncatingIfNeeded: count >> (8 * UInt32(byte)))
                }
            }
        }
        recomputeIndex(width: width)
    }

    /// The per-line cell counts, so research/31/F2 can build a synthetic arena from a real one's geometry.
    func lineCellCountsSnapshot() -> [Int] { lineCellCounts }

    /// The display-row total computed by a route the blocked prefix cannot share.
    ///
    /// `research/31/D1` gate 1: a counting pass is exactly the loop shape an optimizer deletes, and a
    /// deleted loop reports an excellent number. Every timed pass is checked against this.
    func independentDisplayRowTotal(width: Int) -> Int {
        var total = 0
        for cells in lineCellCounts { total += Self.displayRows(cells: cells, width: width) }
        return total
    }

    /// The eager recompute doc 31 settled on: discard every cached block total and rebuild it
    /// in one pass. research/31/F1 calls it once at construction; `research/31/F2` prices it at depth.
    ///
    /// This is `research/31/D1`'s `counts` count-source: the per-line cell count comes from a dense
    /// parallel array. That is *not* what the candidate direction sketches -- the sketched index
    /// holds record offsets and the count lives in the record -- so research/31/F2's primary variant is
    /// `recomputeIndexFromArena` below and this one is the priced alternative.
    mutating func recomputeIndex(width: Int) {
        self.width = width
        let blockCount = (lineOffsets.count + blockSize - 1) / blockSize
        blockPrefix = [Int](repeating: 0, count: blockCount + 1)
        var total = 0
        for block in 0..<blockCount {
            blockPrefix[block] = total
            let start = block * blockSize
            let end = min(start + blockSize, lineOffsets.count)
            for line in start..<end {
                total += Self.displayRows(cells: lineCellCounts[line], width: width)
            }
        }
        blockPrefix[blockCount] = total
    }

    /// The same eager pass, reading each line's cell count out of its record header.
    ///
    /// `research/31/D1`'s **primary** count-source, because it is what the candidate direction describes:
    /// the index stores offsets only. The loop is therefore a strided chase across the whole
    /// arena rather than a scan of a dense array, and the gap between this and `recomputeIndex`
    /// is the price of not carrying a parallel counts array.
    mutating func recomputeIndexFromArena(width: Int) {
        self.width = width
        let blockCount = (lineOffsets.count + blockSize - 1) / blockSize
        blockPrefix = [Int](repeating: 0, count: blockCount + 1)
        var total = 0
        arena.withUnsafeBufferPointer { bytes in
            for block in 0..<blockCount {
                blockPrefix[block] = total
                let start = block * blockSize
                let end = min(start + blockSize, lineOffsets.count)
                for line in start..<end {
                    let offset = lineOffsets[line]
                    let cells = Int(UInt32(bytes[offset])
                        | (UInt32(bytes[offset + 1]) << 8)
                        | (UInt32(bytes[offset + 2]) << 16)
                        | (UInt32(bytes[offset + 3]) << 24))
                    total += Self.displayRows(cells: cells, width: width)
                }
            }
        }
        blockPrefix[blockCount] = total
    }

    @inline(__always)
    private static func displayRows(cells: Int, width: Int) -> Int {
        cells <= 0 ? 1 : (cells + width - 1) / width
    }

    /// Binary search over block totals, then an in-block scan reading each line's header.
    ///
    /// The scan reads `cellCount` out of the arena rather than out of `lineCellCounts`,
    /// because the design's index stores offsets and the count lives in the record -- reading
    /// a parallel array instead would price a cache-friendly walk the real store would not
    /// have.
    @inline(__always)
    func locate(displayRow: Int) -> (line: Int, rowWithinLine: Int) {
        var low = 0
        var high = blockPrefix.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if blockPrefix[mid] <= displayRow { low = mid } else { high = mid }
        }
        var remaining = displayRow - blockPrefix[low]
        var line = low * blockSize
        let end = min(line + blockSize, lineOffsets.count)
        return arena.withUnsafeBufferPointer { bytes in
            while line < end {
                let offset = lineOffsets[line]
                let cells = Int(UInt32(bytes[offset])
                    | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16)
                    | (UInt32(bytes[offset + 3]) << 24))
                let rows = Self.displayRows(cells: cells, width: width)
                if remaining < rows { return (line, remaining) }
                remaining -= rows
                line += 1
            }
            return (end - 1, remaining)
        }
    }

    /// Steps one display row forward without consulting the index.
    ///
    /// This is what makes sequential browse amortize: within a viewport the reader already
    /// knows where it is, so the next row is either the next slice of the open record or the
    /// start of the next one. The line's row count is read from its header in the arena, the
    /// same load `locate`'s scan does.
    @inline(__always)
    func advance(_ position: (line: Int, rowWithinLine: Int)) -> (line: Int, rowWithinLine: Int) {
        let offset = lineOffsets[position.line]
        let cells = Int(UInt32(arena[offset])
            | (UInt32(arena[offset + 1]) << 8)
            | (UInt32(arena[offset + 2]) << 16)
            | (UInt32(arena[offset + 3]) << 24))
        let rows = Self.displayRows(cells: cells, width: width)
        if position.rowWithinLine + 1 < rows { return (position.line, position.rowWithinLine + 1) }
        return (min(position.line + 1, lineOffsets.count - 1), 0)
    }

    /// The same two walks the baseline performs, over the display row's slice of a logical line.
    ///
    /// Per-cell work is identical to `PackedRetainedRow`'s by construction: `forEachKind`'s
    /// safe byte-wise `u64` read for the kind walk, and the unsafe-buffer read for the
    /// content walk. The only difference research/31/F1 is measuring is where the bytes came from.
    @inline(__always)
    func read(line: Int, rowWithinLine: Int, into checksum: inout UInt64) {
        let offset = lineOffsets[line]
        let cellCount = Int(UInt32(arena[offset])
            | (UInt32(arena[offset + 1]) << 8)
            | (UInt32(arena[offset + 2]) << 16)
            | (UInt32(arena[offset + 3]) << 24))
        let first = rowWithinLine * width
        let count = max(min(width, cellCount - first), 0)
        let base = offset + Self.headerBytes + first * Self.cellBytes

        for column in 0..<count {
            var word: UInt64 = 0
            let at = base + column * Self.cellBytes
            for byte in 0..<8 { word |= UInt64(arena[at + byte]) << (8 * byte) }
            let kind = Terminal.probeKind(packedCode: UInt8((word >> 21) & 0x7))
            checksum = checksum &* 31 &+ UInt64(column) &+ UInt64(kind.probeCode)
        }

        arena.withUnsafeBufferPointer { buffer in
            let bytes = buffer.baseAddress! + base
            for column in 0..<count {
                var word: UInt64 = 0
                let at = column * Self.cellBytes
                for byte in 0..<8 { word |= UInt64(bytes[at + byte]) << (8 * byte) }

                let styleId = Terminal.StyleId(truncatingIfNeeded: word >> 32)
                let field = UInt32(word & 0x1F_FFFF)
                let scalars: TerminalScalars
                if field != 0, let scalar = Unicode.Scalar(field) {
                    scalars = TerminalScalars(scalar)
                } else {
                    scalars = .empty
                }
                checksum = checksum &* 31 &+ UInt64(column) &+ UInt64(styleId)
                checksum = checksum &* 31 &+ UInt64(scalars.count)
                if scalars.count > 0 { checksum = checksum &+ UInt64(scalars[0].value) }
            }
        }
    }

    /// Proves the arena's derived display-row count and per-row extents match the display
    /// rows the engine actually produced. A mismatch means the candidate is not storing the
    /// baseline's content and no timing from the run may be quoted.
    func verifyWrapArithmetic(against stimulus: RetainedStimulus) -> String? {
        guard displayRowCount == stimulus.displayRowCount else {
            return "derived display rows \(displayRowCount) != engine's \(stimulus.displayRowCount)"
        }
        for line in 0..<stimulus.lineCount {
            let expected = stimulus.lineStarts[line + 1] - stimulus.lineStarts[line]
            let derived = Self.displayRows(cells: lineCellCounts[line], width: width)
            if derived != expected {
                return "line \(line): derived \(derived) display rows, engine produced \(expected)"
            }
        }
        return nil
    }
}

// MARK: - Kind coding, local to the probe

extension Terminal {
    /// The probe's own kind coding, mirroring `PackedRetainedRow`'s `fileprivate packedCode`.
    ///
    /// Restated here rather than reached into because that one is `fileprivate` to a
    /// production file; `TerminalPackedRetainedRowTests` is what holds the production
    /// encoding to round-tripping, and the checksum gate is what holds this one to agreeing
    /// with it for the stimulus actually measured.
    static func probeKind(packedCode: UInt8) -> TerminalCellKind {
        switch packedCode {
        case 1: return .narrow
        case 2: return .wideHead
        case 3: return .wideTail
        case 4: return .spacerHead
        default: return .padding
        }
    }
}

extension TerminalCellKind {
    var probeCode: UInt8 {
        switch self {
        case .padding: return 0
        case .narrow: return 1
        case .wideHead: return 2
        case .wideTail: return 3
        case .spacerHead: return 4
        }
    }
}

// MARK: - Timing

/// One arm's measured time for one round, with the sample count it was measured over.
///
/// The count travels with the aggregate on purpose: an aggregate that cannot say how many
/// reads it covers cannot distinguish "fast" from "did not run"
/// (`agent-docs/measurement-discipline.md`).
struct ArmRound {
    let nanoseconds: UInt64
    let readCount: Int
    let checksum: UInt64

    var nanosecondsPerRead: Double {
        readCount == 0 ? .nan : Double(nanoseconds) / Double(readCount)
    }
}

/// Runs two arms ABBA for the frozen round count and reports each arm's median per-read time.
///
/// ABBA rather than A-then-B because a linear drift in machine state biases a run of A
/// followed by a run of B by the whole drift, and cancels to first order when the order is
/// reversed within the round (`agent-docs/measurement-discipline.md`: interleave, same
/// session).
func interleavedRounds(
    rounds: Int,
    warmupRounds: Int,
    armA: () -> ArmRound,
    armB: () -> ArmRound
) -> (a: [Double], b: [Double], checksumA: UInt64, checksumB: UInt64, readCount: Int) {
    for _ in 0..<warmupRounds {
        _ = armA()
        _ = armB()
    }
    var a: [Double] = []
    var b: [Double] = []
    var checksumA: UInt64 = 0
    var checksumB: UInt64 = 0
    var readCount = 0
    for _ in 0..<rounds {
        let a1 = armA()
        let b1 = armB()
        let b2 = armB()
        let a2 = armA()
        a.append((a1.nanosecondsPerRead + a2.nanosecondsPerRead) / 2)
        b.append((b1.nanosecondsPerRead + b2.nanosecondsPerRead) / 2)
        checksumA = a1.checksum
        checksumB = b1.checksum
        readCount = a1.readCount
        #expect(a1.checksum == a2.checksum)
        #expect(b1.checksum == b2.checksum)
    }
    return (a, b, checksumA, checksumB, readCount)
}

func median(_ values: [Double]) -> Double {
    guard values.isEmpty == false else { return .nan }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

func percentile(_ values: [Int], _ fraction: Double) -> Int {
    guard values.isEmpty == false else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * fraction).rounded(.down))))
    return sorted[index]
}

// MARK: - Access patterns

private let viewportRows = 66
private let browseFrames = 300
private let seekCount = 20_000

/// The retained-browse pattern: one index lookup per frame, then 66 rows walked forward.
///
/// One lookup per frame is what a real reader would do -- the viewport is contiguous, so the
/// index is consulted once and the walk continues from there. Charging the candidate a lookup
/// per row would price an implementation nobody would write; `random seek` is where the
/// unamortized lookup is measured.
func browseFrameTops(displayRowCount: Int) -> [Int] {
    let span = max(1, displayRowCount - viewportRows)
    return (0..<browseFrames).map { ($0 * 33) % span }
}

func seekTargets(displayRowCount: Int) -> [Int] {
    var random = DeterministicSequence(seed: 0xC0FFEE_31)
    return (0..<seekCount).map { _ in random.next(below: displayRowCount) }
}

// MARK: - The probe

private let probeIsEnabled = ProcessInfo.processInfo.environment["DANTERM_LOGICAL_LINE_PROBE"] != nil

private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// Compares doc 31's candidate store against today's on the two access patterns `research/31/D1` froze.
/// A probe: it prints measurements and gate outcomes, and decides nothing.
struct TerminalLogicalLineReadProbe {
    @Test("F1 calibration: the stimulus reproduces research/28/F23's content distribution", .enabled(if: probeIsEnabled))
    func stimulusCalibration() throws {
        for contentClass in LogicalLineContentClass.allCases {
            let stimulus = buildStimulus(contentClass: contentClass, targetDisplayRows: 10_000)
            let counts = stimulus.storedCellCounts()
            let sorted = counts.sorted()
            print(
                """
                [calibration] class=\(contentClass.rawValue) displayRows=\(counts.count) \
                logicalLines=\(stimulus.lineCount) \
                median=\(sorted[sorted.count / 2]) p95=\(percentile(counts, 0.95)) \
                mean=\(String(format: "%.1f", Double(counts.reduce(0, +)) / Double(counts.count))) \
                min=\(sorted.first ?? 0) max=\(sorted.last ?? 0)
                """
            )
            #expect(counts.count >= 9_000)
        }
    }

    @Test("F1: sequential browse and random seek, candidate vs today's store", .enabled(if: probeIsEnabled))
    func readPathComparison() throws {
        let rounds = 5
        let warmupRounds = 2

        for contentClass in LogicalLineContentClass.allCases {
            let stimulus = buildStimulus(contentClass: contentClass, targetDisplayRows: 10_000)
            let counts = stimulus.storedCellCounts()
            let sortedCounts = counts.sorted()
            let medianCells = sortedCounts[sortedCounts.count / 2]
            let p95Cells = percentile(counts, 0.95)

            let baseline = DisplayRowStore(stimulus)
            let control = DisplayRowStore(stimulus)
            let candidate = LogicalLineArena(stimulus)

            let wrapProblem = candidate.verifyWrapArithmetic(against: stimulus)
            print(
                """
                [stimulus] class=\(contentClass.rawValue) displayRows=\(stimulus.displayRowCount) \
                logicalLines=\(stimulus.lineCount) medianCells=\(medianCells) p95Cells=\(p95Cells) \
                arenaBytes=\(candidate.arenaByteCount) \
                wrapCheck=\(wrapProblem ?? "ok")
                """
            )
            #expect(wrapProblem == nil)

            let tops = browseFrameTops(displayRowCount: stimulus.displayRowCount)
            let targets = seekTargets(displayRowCount: stimulus.displayRowCount)

            func browseBaseline(_ store: DisplayRowStore) -> ArmRound {
                var checksum: UInt64 = 5_381
                let started = now()
                for top in tops {
                    for offset in 0..<viewportRows {
                        store.read(displayRow: top + offset, into: &checksum)
                    }
                }
                return ArmRound(
                    nanoseconds: now() &- started,
                    readCount: tops.count * viewportRows,
                    checksum: checksum
                )
            }

            func browseCandidate() -> ArmRound {
                var checksum: UInt64 = 5_381
                let started = now()
                for top in tops {
                    var located = candidate.locate(displayRow: top)
                    for _ in 0..<viewportRows {
                        candidate.read(line: located.line, rowWithinLine: located.rowWithinLine, into: &checksum)
                        located = candidate.advance(located)
                    }
                }
                return ArmRound(
                    nanoseconds: now() &- started,
                    readCount: tops.count * viewportRows,
                    checksum: checksum
                )
            }

            func seekBaseline(_ store: DisplayRowStore) -> ArmRound {
                var checksum: UInt64 = 5_381
                let started = now()
                for target in targets {
                    store.read(displayRow: target, into: &checksum)
                }
                return ArmRound(nanoseconds: now() &- started, readCount: targets.count, checksum: checksum)
            }

            func seekCandidate() -> ArmRound {
                var checksum: UInt64 = 5_381
                let started = now()
                for target in targets {
                    let located = candidate.locate(displayRow: target)
                    candidate.read(line: located.line, rowWithinLine: located.rowWithinLine, into: &checksum)
                }
                return ArmRound(nanoseconds: now() &- started, readCount: targets.count, checksum: checksum)
            }

            let patterns: [(name: String, a: () -> ArmRound, b: () -> ArmRound, control: () -> ArmRound)] = [
                ("sequential-browse",
                 { browseBaseline(baseline) }, browseCandidate, { browseBaseline(control) }),
                ("random-seek",
                 { seekBaseline(baseline) }, seekCandidate, { seekBaseline(control) }),
            ]

            for pattern in patterns {
                let measured = interleavedRounds(
                    rounds: rounds, warmupRounds: warmupRounds, armA: pattern.a, armB: pattern.b
                )
                let aa = interleavedRounds(
                    rounds: rounds, warmupRounds: warmupRounds, armA: pattern.a, armB: pattern.control
                )
                let baselineMedian = median(measured.a)
                let candidateMedian = median(measured.b)
                let controlMedian = median(aa.b)
                let aaMedian = median(aa.a)

                print(
                    """
                    [F1 \(contentClass.rawValue)/\(pattern.name)] reads=\(measured.readCount) rounds=\(rounds)
                      baseline  median=\(String(format: "%.1f", baselineMedian)) ns/read \
                    (min \(String(format: "%.1f", measured.a.min() ?? .nan)), \
                    max \(String(format: "%.1f", measured.a.max() ?? .nan)))
                      candidate median=\(String(format: "%.1f", candidateMedian)) ns/read \
                    (min \(String(format: "%.1f", measured.b.min() ?? .nan)), \
                    max \(String(format: "%.1f", measured.b.max() ?? .nan)))
                      ratio=\(String(format: "%.3f", candidateMedian / baselineMedian))x \
                    delta=\(String(format: "%+.2f", (candidateMedian / baselineMedian - 1) * 100))%
                      A/A control ratio=\(String(format: "%.3f", controlMedian / aaMedian))x \
                    delta=\(String(format: "%+.2f", (controlMedian / aaMedian - 1) * 100))% \
                    (resolution floor)
                      checksums baseline=\(measured.checksumA) candidate=\(measured.checksumB) \
                    equal=\(measured.checksumA == measured.checksumB)
                    """
                )
                #expect(measured.checksumA == measured.checksumB)
                #expect(measured.readCount > 0)
            }

            // The ARC control, descriptive and outside research/31/D1's rule. Same baseline store, same
            // walks, the row borrowed in place rather than copied out. What it isolates is how
            // much of the candidate's margin is the storage shape and how much is a per-read
            // retain/release pair today's subscript performs.
            let borrowedBrowse = interleavedRounds(
                rounds: rounds, warmupRounds: warmupRounds,
                armA: { browseBaseline(baseline) },
                armB: {
                    var checksum: UInt64 = 5_381
                    let started = now()
                    for top in tops {
                        for offset in 0..<viewportRows {
                            baseline.readBorrowed(displayRow: top + offset, into: &checksum)
                        }
                    }
                    return ArmRound(
                        nanoseconds: now() &- started,
                        readCount: tops.count * viewportRows,
                        checksum: checksum
                    )
                }
            )
            print(
                """
                [F1 \(contentClass.rawValue)/arc-control] reads=\(borrowedBrowse.readCount) \
                rounds=\(rounds) copying=\(String(format: "%.1f", median(borrowedBrowse.a))) ns/read \
                borrowed=\(String(format: "%.1f", median(borrowedBrowse.b))) ns/read \
                ratio=\(String(format: "%.3f", median(borrowedBrowse.b) / median(borrowedBrowse.a)))x \
                checksumsEqual=\(borrowedBrowse.checksumA == borrowedBrowse.checksumB)
                """
            )
            #expect(borrowedBrowse.checksumA == borrowedBrowse.checksumB)
        }
    }

    @Test("F1 supplementary: how random seek responds to block size", .enabled(if: probeIsEnabled))
    func blockSizeSweep() throws {
        // Descriptive, and outside `research/31/D1`'s rule: the rule is frozen at the design's stated
        // ~256 lines per block. This exists so a `narrow-go` on random seek has a measured
        // starting point rather than a guess about which way to move the parameter.
        for contentClass in LogicalLineContentClass.allCases {
            let stimulus = buildStimulus(contentClass: contentClass, targetDisplayRows: 10_000)
            let targets = seekTargets(displayRowCount: stimulus.displayRowCount)
            for blockSize in [32, 64, 128, 256, 1_024] {
                let candidate = LogicalLineArena(stimulus, blockSize: blockSize)
                var checksum: UInt64 = 5_381
                for _ in 0..<2 {
                    checksum = 5_381
                    for target in targets {
                        let located = candidate.locate(displayRow: target)
                        candidate.read(line: located.line, rowWithinLine: located.rowWithinLine, into: &checksum)
                    }
                }
                let started = now()
                var timed: UInt64 = 5_381
                for target in targets {
                    let located = candidate.locate(displayRow: target)
                    candidate.read(line: located.line, rowWithinLine: located.rowWithinLine, into: &timed)
                }
                let elapsed = now() &- started
                print(
                    """
                    [sweep \(contentClass.rawValue)] blockSize=\(blockSize) seeks=\(targets.count) \
                    ns/seek=\(String(format: "%.1f", Double(elapsed) / Double(targets.count))) \
                    checksum=\(timed)
                    """
                )
                #expect(checksum != 0)
            }
        }
    }
}
