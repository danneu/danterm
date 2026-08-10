// The research/31/F9 wide-content counting-pass probe for doc 31: what does the eager block-total recompute
// cost when every record takes the wide-cell fallback instead of one divide?
//
// `research/31/D3` Decision 7 reframed that fallback from "an O(cells) scan" to `O(display rows)` -- the
// fold only has to know, at each display-row boundary, whether a 2-cell cluster straddles it, which
// is one probe per display row and not one per cell -- and then declined to close inherited
// condition 1 on arithmetic: the bracket clears one 60 Hz frame by ~3.2x on a per-probe constant
// nobody measured. It froze this probe and a three-way decision rule instead. This file takes the
// measurement; the rule is `research/31/D3` Decision 7's and is applied once, by hand, to what this prints.
//
// The instrument is `research/31/F2`'s, with the three changes `research/31/D3` Decision 7 names and no others: the
// stimulus is `research/31/F3`'s `wide` CJK generator (so every record carries `hasWideCells` and every
// boundary probe fires), the depths are the record count a 16 MiB arena admits for that class plus
// `research/31/F2`'s 10,000 and 100,000 rungs for continuity, and the width changes add `179 -> 2` -- the
// engine minimum (`research/31/F4` case 3), where display rows per record and therefore boundary probes are
// maximised. Everything else is unchanged: 9 measured rounds plus 2 warmup, median over rounds of
// wall time for one whole pass, min/max/n beside every aggregate, release, headless, one process.
//
// Per `research/31/F7`, the ladder that matters is **cells per record**, not record count: the counting pass's
// cost is governed by stride, and the blank end of that ladder is already measured. So the
// cells-per-record ladder here holds the byte budget fixed and varies bytes per record, and every
// rung of it is budget-admissible and therefore verdict-bearing. The record-count ladder is the
// continuity arm and is descriptive: 10,000 wide records is already 22 MB of arena, which the
// budget does not admit.
//
// One arm of `research/31/F2`'s instrument is **inapplicable here and is replaced rather than dropped
// silently**: `research/31/D1`'s two count-sources. `arena` versus `counts` prices carrying a dense parallel
// array of per-record cell counts, and a flagged record cannot be counted from it at all -- the
// boundary probes have to read the record's cells wherever the count came from. So the primary
// source is the only one measurable, and what takes the second arm's place is the **fast path over
// the same records** (`research/31/F2`'s divide, which counts wide content *wrong*): it is what the fallback is
// measured against, and at an odd width its total differs, which is this stimulus's elision guard.
//
// Belongs here: the wide arena and its two counting variants (the wide-aware fold and, as the
// contrast arm, `research/31/F2`'s fast path over the same records), the wide stimulus controls, and the
// reporting. Does not belong here: `research/31/F1`'s arena or `research/31/F2`'s, `research/31/F3`'s admitters, a threshold, or a
// verdict. **`research/31/F1`'s, `research/31/F2`'s, `research/31/F3`'s and `research/31/F7`'s probe files are unedited**, the practice `research/31/F2`
// established and every probe since has kept; nothing under `lib/TerminalCore/Sources/` is touched.
//
// Not part of the `just test` gate. Every measurement is skipped unless
// `DANTERM_LOGICAL_LINE_PROBE` is set. Run it as:
//
//     DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
//       --filter TerminalLogicalLineWideIndexProbe
//
// Release matters: `research/31/D3` Decision 7's 1.67 ms and 16.67 ms bounds are release-build bounds.
import Foundation
import Testing

@testable import TerminalCore

// MARK: - The wide arena

/// Which counting pass a round measures.
///
/// `wideAware` is the fallback `research/31/D3` Decision 7 is about: a flagged record is folded by walking its
/// display-row boundaries, probing the cell that would land in the last column. `fastPath` is
/// `research/31/F2`'s pass over the *same* records -- one divide, no probe -- and is the contrast arm that says
/// what the fallback costs over the arithmetic it replaces. It is also this stimulus's elision
/// guard: at an odd width the two produce **different** totals (a 179-column row of CJK holds 178
/// cells, not 179), so a boundary walk an optimizer hoisted or deleted fails the cross-check.
enum WidePassVariant: String {
    case wideAware = "wide-aware"
    case fastPath = "fast-path"
}

/// Doc 31's record arena, restricted to what a counting pass touches, with wide cells in it.
///
/// Record layout is `research/31/F1`'s and `research/31/F3`'s, so the campaign's probes agree on one format:
///
///     bytes 0..3   cell count (UInt32)
///     byte  4      flags -- bit 0 hasWideCells
///     bytes 5..7   spare
///     bytes 8..    cell count x the C1 8-byte cell word, verbatim from `PackedRetainedRow`
///
/// **The spacer is never stored** (`research/31/F4` case 10, `research/31/F3`'s admitter): a `.spacerHead` is a wrap
/// artifact of one width, so the fold re-derives it -- which is exactly why the display-row count
/// of a wide record is not `ceil(cells / width)` and why this probe exists. Its own type rather
/// than `research/31/F1`'s `LogicalLineArena` because the boundary probe has to read cell kinds out of the
/// arena's bytes, and that storage is `private` to `research/31/F1`'s file.
struct WideLogicalLineArena {
    private var arena: [UInt8] = []
    private var lineOffsets: [Int] = []
    private var lineCellCounts: [Int] = []
    private var blockPrefix: [Int] = []
    private(set) var width: Int
    private let blockSize: Int

    private static let headerBytes = 8
    private static let cellBytes = 8
    private static let hasWideBit: UInt8 = 0x01
    /// The kind field sits at bits 21..23 of the cell word, i.e. bits 5..7 of its third byte.
    private static let kindByte = 2
    private static let kindShift: UInt8 = 5

    var displayRowCount: Int { blockPrefix.last ?? 0 }
    var recordCount: Int { lineOffsets.count }
    var arenaByteCount: Int { arena.count }
    /// `research/31/D2` Decision 1's charge: the arena's bytes plus 8 index bytes per record.
    var chargedBytes: Int { arena.count + lineOffsets.count * 8 }
    var cellCount: Int { lineCellCounts.reduce(0, +) }

    /// Builds the arena from the display rows a real `Terminal` retained.
    ///
    /// A logical line's cells are its display rows concatenated with the spacers dropped, each row
    /// measured to full width if it soft-wraps and to its canonical extent if it ends the line --
    /// `Terminal.swift#reconstructLogicalLines`'s own rule, and the same one `research/31/F3`'s admitter
    /// follows.
    init(_ stimulus: RetainedStimulus, blockSize: Int = 256) {
        self.width = stimulus.columns
        self.blockSize = blockSize

        for line in 0..<stimulus.lineCount {
            let start = stimulus.lineStarts[line]
            let end = stimulus.lineStarts[line + 1]
            var words: [UInt64] = []
            var hasWide = false
            for row in start..<end {
                let gridRow = stimulus.displayRows[row].materialized(to: stimulus.columns)
                var rowWords: [UInt64] = []
                var lastWritten = 0
                for cell in gridRow.cells {
                    if cell.kind == .spacerHead { continue }
                    if cell.kind == .wideHead { hasWide = true }
                    var word = UInt64(cell.kind.probeCode) << 21
                    word |= UInt64(cell.styleId) << 32
                    precondition(
                        cell.scalars.count <= 1,
                        "probe stimulus produced a multi-scalar cell; arena has no spill table"
                    )
                    if cell.scalars.count == 1 { word |= UInt64(cell.scalars[0].value) }
                    if word != 0 { lastWritten = rowWords.count }
                    rowWords.append(word)
                }
                let extent = gridRow.isSoftWrapped
                    ? rowWords.count
                    : min(max(lastWritten + 1, 1), rowWords.count)
                words.append(contentsOf: rowWords[0..<extent])
            }
            append(words: words, hasWide: hasWide)
        }
        recomputeIndexWideAware(width: stimulus.columns)
    }

    /// Builds an arena of all-wide records with the given cell counts.
    ///
    /// The synthetic form `research/31/F2`'s gate 2 controls: real record geometry -- header offsets, record
    /// sizes, total footprint -- and, unlike `research/31/F2`'s synthetic arena, real *kind* bytes, because the
    /// boundary probe reads them. Every record is CJK clusters end to end (head, tail, head, ...),
    /// which is the stimulus `research/31/D3` Decision 7 asks for taken to its limit: every boundary probe
    /// fires and every record is flagged.
    init(syntheticWideCellCounts counts: [Int], width: Int, blockSize: Int = 256) {
        self.width = width
        self.blockSize = blockSize

        var total = 0
        lineOffsets.reserveCapacity(counts.count)
        for cells in counts {
            precondition(cells % 2 == 0, "an all-wide record holds whole 2-cell clusters")
            lineOffsets.append(total)
            total += Self.headerBytes + cells * Self.cellBytes
        }
        lineCellCounts = counts
        arena = [UInt8](repeating: 0, count: total)
        let headCode = TerminalCellKind.wideHead.probeCode << Self.kindShift
        let tailCode = TerminalCellKind.wideTail.probeCode << Self.kindShift
        arena.withUnsafeMutableBufferPointer { bytes in
            for record in counts.indices {
                let offset = lineOffsets[record]
                let count = UInt32(counts[record])
                for byte in 0..<4 {
                    bytes[offset + byte] = UInt8(truncatingIfNeeded: count >> (8 * UInt32(byte)))
                }
                bytes[offset + 4] = Self.hasWideBit
                let base = offset + Self.headerBytes
                for cell in 0..<counts[record] {
                    bytes[base + cell * Self.cellBytes + Self.kindByte] =
                        cell % 2 == 0 ? headCode : tailCode
                }
            }
        }
        recomputeIndexWideAware(width: width)
    }

    private mutating func append(words: [UInt64], hasWide: Bool) {
        let offset = arena.count
        lineOffsets.append(offset)
        lineCellCounts.append(words.count)
        arena.append(
            contentsOf: [UInt8](repeating: 0, count: Self.headerBytes + words.count * Self.cellBytes)
        )
        arena.withUnsafeMutableBufferPointer { bytes in
            let count = UInt32(words.count)
            for byte in 0..<4 {
                bytes[offset + byte] = UInt8(truncatingIfNeeded: count >> (8 * UInt32(byte)))
            }
            bytes[offset + 4] = hasWide ? Self.hasWideBit : 0
            for cell in words.indices {
                let word = words[cell]
                if word == 0 { continue }
                let at = offset + Self.headerBytes + cell * Self.cellBytes
                for byte in 0..<Self.cellBytes {
                    bytes[at + byte] = UInt8(truncatingIfNeeded: word >> (8 * byte))
                }
            }
        }
    }

    func recordCellCounts() -> [Int] { lineCellCounts }

    // MARK: The two counting passes

    /// The wide-aware eager recompute: the fallback `research/31/D3` Decision 7 prices.
    ///
    /// A flagged record is folded by walking its display-row boundaries -- one probe of the cell
    /// that would occupy the last column, backing the row off by one when that cell starts a 2-cell
    /// cluster, which is `Terminal.swift#pack`'s spacer rule read from the record's side and
    /// iTerm2's `LineBuffer` loop read from the other. An unflagged record takes `research/31/F2`'s divide.
    /// The probe reads the byte holding the kind field rather than the whole cell word: both touch
    /// the same cache line, so the difference is register work, not memory traffic.
    mutating func recomputeIndexWideAware(width: Int) {
        self.width = width
        let blockCount = (lineOffsets.count + blockSize - 1) / blockSize
        blockPrefix = [Int](repeating: 0, count: blockCount + 1)
        var total = 0
        arena.withUnsafeBufferPointer { bytes in
            for block in 0..<blockCount {
                blockPrefix[block] = total
                let start = block * blockSize
                let end = min(start + blockSize, lineOffsets.count)
                for record in start..<end {
                    let offset = lineOffsets[record]
                    let cells = Int(UInt32(bytes[offset])
                        | (UInt32(bytes[offset + 1]) << 8)
                        | (UInt32(bytes[offset + 2]) << 16)
                        | (UInt32(bytes[offset + 3]) << 24))
                    if bytes[offset + 4] & Self.hasWideBit == 0 {
                        total += cells <= 0 ? 1 : (cells + width - 1) / width
                        continue
                    }
                    let base = offset + Self.headerBytes
                    var consumed = 0
                    var rows = 0
                    while consumed < cells {
                        var take = width
                        let boundary = consumed + width - 1
                        if boundary < cells {
                            let kind = bytes[base + boundary * Self.cellBytes + Self.kindByte]
                                >> Self.kindShift
                            if kind == TerminalCellKind.wideHead.probeCode { take = width - 1 }
                        }
                        consumed += take
                        rows += 1
                    }
                    total += max(1, rows)
                }
            }
        }
        blockPrefix[blockCount] = total
    }

    /// `research/31/F2`'s pass over the same records: `max(1, ceil(cells / width))`, flags ignored.
    ///
    /// The contrast arm. It is not a candidate implementation -- it counts wrong for wide content,
    /// which is `research/31/F4`'s arithmetic correction -- it is what the wide fallback is measured against,
    /// and the difference between the two totals at an odd width is this probe's elision guard.
    mutating func recomputeIndexFastPath(width: Int) {
        self.width = width
        let blockCount = (lineOffsets.count + blockSize - 1) / blockSize
        blockPrefix = [Int](repeating: 0, count: blockCount + 1)
        var total = 0
        arena.withUnsafeBufferPointer { bytes in
            for block in 0..<blockCount {
                blockPrefix[block] = total
                let start = block * blockSize
                let end = min(start + blockSize, lineOffsets.count)
                for record in start..<end {
                    let offset = lineOffsets[record]
                    let cells = Int(UInt32(bytes[offset])
                        | (UInt32(bytes[offset + 1]) << 8)
                        | (UInt32(bytes[offset + 2]) << 16)
                        | (UInt32(bytes[offset + 3]) << 24))
                    total += cells <= 0 ? 1 : (cells + width - 1) / width
                }
            }
        }
        blockPrefix[blockCount] = total
    }

    // MARK: Independent cross-checks

    /// The display-row total for all-wide records, computed by a route that reads no arena byte.
    ///
    /// `research/31/F2` gate 1: a counting pass is the loop shape an optimizer deletes, and a deleted loop
    /// reports an excellent number. For content that is CJK end to end a row holds
    /// `2 * (width / 2)` cells -- an odd width leaves the last column to a spacer -- so the total is
    /// closed-form arithmetic over the cell counts, sharing nothing with the boundary walk.
    func independentWideDisplayRowTotal(width: Int) -> Int {
        let perRow = 2 * (width / 2)
        var total = 0
        for cells in lineCellCounts {
            total += cells <= 0 ? 1 : (cells + perRow - 1) / perRow
        }
        return total
    }

    func independentFastPathTotal(width: Int) -> Int {
        var total = 0
        for cells in lineCellCounts { total += cells <= 0 ? 1 : (cells + width - 1) / width }
        return total
    }

    /// Every record is flagged and holds whole CJK clusters, or the stimulus is not what the rule
    /// asked for. Runs outside every timed region.
    func wideRecordAudit() -> (flagged: Int, allWideCells: Int) {
        var flagged = 0
        var allWide = 0
        for record in lineOffsets.indices {
            let offset = lineOffsets[record]
            if arena[offset + 4] & Self.hasWideBit != 0 { flagged += 1 }
            var wide = true
            for cell in 0..<lineCellCounts[record] {
                let kind = arena[offset + Self.headerBytes + cell * Self.cellBytes + Self.kindByte]
                    >> Self.kindShift
                let expected = cell % 2 == 0
                    ? TerminalCellKind.wideHead.probeCode
                    : TerminalCellKind.wideTail.probeCode
                if kind != expected { wide = false; break }
            }
            if wide { allWide += 1 }
        }
        return (flagged, allWide)
    }

    /// Proves the fold reproduces the display rows the engine itself produced, record by record.
    ///
    /// What replaces `research/31/F2`'s content-class calibration for this stimulus (see the probe's gate 5):
    /// `research/28/F23` measured an ASCII band, so there is no cell-count band a CJK stimulus can be held
    /// to -- but the engine did wrap this exact content at 179 columns, spacers and all, and the
    /// fold has to agree with it or nothing measured here is a fold of the retained content.
    func verifyFold(against stimulus: RetainedStimulus) -> String? {
        guard width == stimulus.columns else { return "audit width \(width) != stimulus width" }
        guard displayRowCount == stimulus.displayRowCount else {
            return "derived display rows \(displayRowCount) != engine's \(stimulus.displayRowCount)"
        }
        let perRow = 2 * (width / 2)
        for record in 0..<stimulus.lineCount {
            let expected = stimulus.lineStarts[record + 1] - stimulus.lineStarts[record]
            let cells = lineCellCounts[record]
            let derived = cells <= 0 ? 1 : (cells + perRow - 1) / perRow
            if derived != expected {
                return "record \(record): derived \(derived) display rows, engine produced \(expected)"
            }
        }
        return nil
    }
}

// MARK: - Timing

/// `research/31/F2`'s `measurePass`, over this file's arena and its two variants. Round counts are `research/31/F2`'s.
func measureWidePass(
    _ arena: inout WideLogicalLineArena,
    width: Int,
    variant: WidePassVariant,
    rounds: Int = 9,
    warmupRounds: Int = 2
) -> [PassRound] {
    for _ in 0..<warmupRounds {
        switch variant {
        case .wideAware: arena.recomputeIndexWideAware(width: width)
        case .fastPath: arena.recomputeIndexFastPath(width: width)
        }
    }
    var out: [PassRound] = []
    out.reserveCapacity(rounds)
    for _ in 0..<rounds {
        let start = DispatchTime.now().uptimeNanoseconds
        switch variant {
        case .wideAware: arena.recomputeIndexWideAware(width: width)
        case .fastPath: arena.recomputeIndexFastPath(width: width)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        out.append(
            PassRound(
                nanoseconds: Double(elapsed),
                lineCount: arena.recordCount,
                displayRowTotal: arena.displayRowCount
            )
        )
    }
    return out
}

/// Tiles a real arena's per-record cell counts until the charge reaches `budgetBytes`.
///
/// `research/31/D2` Decision 1's charge is the arena's bytes plus 8 index bytes per record, so the depth a
/// class actually reaches is a property of its record sizes. Taking the counts from a real arena
/// rather than from the generator keeps the geometry the engine's own, exactly as `research/31/F2`'s
/// `tiledCounts` does.
func wideCountsFillingBudget(_ counts: [Int], budgetBytes: Int) -> [Int] {
    var out: [Int] = []
    var charged = 0
    var index = 0
    while true {
        let cells = counts[index % counts.count]
        let cost = 8 + cells * 8 + 8
        if charged + cost > budgetBytes { break }
        out.append(cells)
        charged += cost
        index += 1
    }
    return out
}

// MARK: - The probe

/// `research/31/F9`: prices the wide-content counting pass at the depths and widths `research/31/D3` Decision 7 froze.
///
/// Reports distributions and gate outcomes; it prints no verdict. The three-way rule -- confirm
/// under 1.67 ms, narrow confirm under 16.67 ms, reject at or above one 60 Hz frame -- lives in
/// `research/31/D3` Decision 7, frozen before this file existed, and is applied once by hand.
@Suite(.serialized)
struct TerminalLogicalLineWideIndexProbe {
    static let probeIsEnabled = ProcessInfo.processInfo.environment["DANTERM_LOGICAL_LINE_PROBE"] != nil

    /// `Terminal.swift#scrollbackByteLimit`, which `research/31/D2` Decision 1 keeps unchanged.
    static let budgetBytes = 16_777_216
    /// `research/31/F2`'s three width changes plus `research/31/D3` Decision 7's addition: the engine minimum, where
    /// display rows per record -- and so boundary probes -- are maximised.
    static let widths = [179, 100, 200, 2]
    /// `research/31/F2`'s shallow depth, which is also where its synthetic-fidelity control is taken.
    static let controlRecords = 10_000

    /// The verdict-bearing measurement: a budget-full wide arena, at all four widths.
    @Test(
        "F9 -- the wide counting pass at the record count 16 MiB admits for CJK content",
        .enabled(if: probeIsEnabled)
    )
    func wideCountingPassAtBudgetDepth() throws {
        print("[F9] eager block-total recompute, wide (CJK) records; 9 measured rounds + 2 warmup per cell")
        print("[F9] load average before: \(loadAverageDescription())")

        // `research/31/F3`'s `wide` class, through a real engine at 179x66, cut to `research/31/F2`'s shallow depth.
        let raw = buildAdmissionStimulus(contentClass: .wide, targetDisplayRows: 26_000)
        #expect(raw.lineCount >= Self.controlRecords)
        let stimulus = truncated(raw, toLineCount: Self.controlRecords)
        var realArena = WideLogicalLineArena(stimulus)
        let counts = realArena.recordCellCounts()

        // The stimulus is the rule's, or the run is void: every record flagged, every record CJK
        // end to end, and the fold agreeing with the wrapping the engine actually performed.
        let audit = realArena.wideRecordAudit()
        let foldProblem = realArena.verifyFold(against: stimulus)
        let spacers = stimulus.displayRows.reduce(0) { total, row in
            total + row.cells.filter { $0.kind == .spacerHead }.count
        }
        // `research/31/F3`'s own band for this class, which is what `research/28/F23`'s ASCII cell-count band cannot be
        // for CJK: at least half the admitted rows carry a wide cell, and at least one spacer is
        // present -- the artifact the store refuses to hold and the fold has to put back.
        let wideRows = stimulus.displayRows.filter { row in row.cells.contains { $0.kind == .wideHead } }.count
        let wideRowFraction = Double(wideRows) / Double(stimulus.displayRowCount)
        print("""
            [F9] stimulus: \(stimulus.lineCount) records, \(stimulus.displayRowCount) engine display \
            rows, \(realArena.cellCount) cells, \(realArena.arenaByteCount) arena bytes \
            (\(String(format: "%.1f", Double(realArena.arenaByteCount) / Double(stimulus.lineCount))) \
            B/record against `research/31/F3` Observation 4's 2,215), mean \
            \(String(format: "%.1f", Double(realArena.cellCount) / Double(stimulus.lineCount))) \
            cells/record, \(spacers) spacers at 179, wide rows \
            \(String(format: "%.1f%%", wideRowFraction * 100)) (`research/31/F3` band: >=50%, >=1 spacer); \
            flagged \(audit.flagged)/\(stimulus.lineCount), \
            all-wide \(audit.allWideCells)/\(stimulus.lineCount); fold-vs-engine \(foldProblem ?? "ok")
            """)
        #expect(wideRowFraction >= 0.5)
        #expect(spacers >= 1)
        #expect(audit.flagged == stimulus.lineCount)
        #expect(audit.allWideCells == stimulus.lineCount)
        #expect(foldProblem == nil)

        var syntheticControl = WideLogicalLineArena(syntheticWideCellCounts: counts, width: stimulus.columns)
        #expect(syntheticControl.arenaByteCount == realArena.arenaByteCount)
        #expect(syntheticControl.recordCount == realArena.recordCount)

        // The verdict-bearing arm: as many of these records as the 16 MiB charge admits.
        let budgetCounts = wideCountsFillingBudget(counts, budgetBytes: Self.budgetBytes)
        var budgetArena = WideLogicalLineArena(syntheticWideCellCounts: budgetCounts, width: stimulus.columns)
        print("""
            [F9] budget arena: \(budgetArena.recordCount) records, \(budgetArena.cellCount) cells, \
            \(budgetArena.arenaByteCount) arena bytes + \(budgetArena.recordCount * 8) index bytes \
            = \(budgetArena.chargedBytes) B charged of \(Self.budgetBytes); control arena \
            \(realArena.recordCount) records at \(realArena.chargedBytes) B charged (over budget, \
            it is `research/31/F2`'s fidelity depth rather than a verdict-bearing one)
            """)

        for width in Self.widths {
            let real = measureWidePass(&realArena, width: width, variant: .wideAware)
            let control = measureWidePass(&syntheticControl, width: width, variant: .wideAware)
            let budget = measureWidePass(&budgetArena, width: width, variant: .wideAware)
            let fast = measureWidePass(&budgetArena, width: width, variant: .fastPath)

            // Gate 1, non-elision: every pass's product is cross-checked against a total computed
            // by a route that reads no arena byte, and no total is zero.
            for (arena, rounds) in [(realArena, real), (syntheticControl, control), (budgetArena, budget)] {
                let expected = arena.independentWideDisplayRowTotal(width: width)
                #expect(expected > 0)
                for round in rounds { #expect(round.displayRowTotal == expected) }
            }
            let fastExpected = budgetArena.independentFastPathTotal(width: width)
            for round in fast { #expect(round.displayRowTotal == fastExpected) }

            let wideTotal = budgetArena.independentWideDisplayRowTotal(width: width)
            let fidelity = medianMilliseconds(control) / medianMilliseconds(real)
            let perRow = medianMilliseconds(budget) * 1_000_000 / Double(wideTotal)
            let overFast = medianMilliseconds(budget) / medianMilliseconds(fast)
            print("""
                [F9] wide 179->\(width): real-10k \(passSummary(real)) \
                | synthetic-10k \(passSummary(control)) \
                | budget-\(budgetArena.recordCount) \(passSummary(budget)) \
                = \(String(format: "%.2f ns/display row", perRow)) \
                | fast-path-same-arena \(passSummary(fast)) \
                (\(String(format: "%.2fx", overFast))) \
                | fidelity \(String(format: "%.3fx", fidelity)) \
                | rows wide \(wideTotal) / fast-path \(fastExpected)
                """)
        }

        print("[F9] load average after: \(loadAverageDescription())")
    }

    /// The ladder `research/31/F7` said would matter: cells per record, at a fixed 16 MiB charge.
    ///
    /// Every rung is budget-admissible, so every rung is verdict-bearing. The extreme is the
    /// narrow end -- `research/31/D3` Decision 7's worst case is narrowness, not depth: CJK folded at the
    /// 2-column minimum puts one cluster per display row, so the whole arena's cells become
    /// boundary probes.
    @Test("F9 -- the wide counting pass against cells per record", .enabled(if: probeIsEnabled))
    func wideCountingPassCellsPerRecordLadder() throws {
        print("[F9 ladder] cells per record at a fixed 16 MiB charge; 9 measured rounds + 2 warmup per cell")
        for cellsPerRecord in [2, 8, 32, 128, 276, 1_024, 4_096] {
            let records = Self.budgetBytes / (16 + cellsPerRecord * 8)
            var arena = WideLogicalLineArena(
                syntheticWideCellCounts: [Int](repeating: cellsPerRecord, count: records), width: 179
            )
            var line = "[F9 ladder] \(cellsPerRecord) cells/record x \(records) records"
            line += " = \(arena.cellCount) cells, \(arena.chargedBytes) B charged:"
            for width in Self.widths {
                let expected = arena.independentWideDisplayRowTotal(width: width)
                let rounds = measureWidePass(&arena, width: width, variant: .wideAware)
                for round in rounds { #expect(round.displayRowTotal == expected) }
                let perRow = medianMilliseconds(rounds) * 1_000_000 / Double(expected)
                line += " 179->\(width) \(passSummary(rounds))"
                line += String(format: " over %d rows = %.2f ns/row;", expected, perRow)
            }
            print(line)
        }
    }

    /// Descriptive continuity with `research/31/F2`'s own rungs, and outside the verdict.
    ///
    /// `research/31/F2` measured 10,000 and 100,000 logical lines; at this class's ~2,215 bytes a record those
    /// are 22 MB and 222 MB of arena, which the 16 MiB budget does not admit -- the same thing `research/31/F2`
    /// Observation 3 said about its own deep rung. They are here because `research/31/D3` Decision 7 named
    /// them, and they are reported as a curve rather than read against a bound.
    @Test("F9 -- the wide counting pass against record count (descriptive)", .enabled(if: probeIsEnabled))
    func wideCountingPassRecordCountLadder() throws {
        let raw = buildAdmissionStimulus(contentClass: .wide, targetDisplayRows: 26_000)
        let stimulus = truncated(raw, toLineCount: Self.controlRecords)
        let counts = WideLogicalLineArena(stimulus).recordCellCounts()
        print("[F9 record ladder] descriptive; wide records; 9 measured rounds per cell")

        for depth in [Self.controlRecords, 100_000] {
            var arena = WideLogicalLineArena(
                syntheticWideCellCounts: tiledCounts(counts, toLineCount: depth), width: 179
            )
            var line = "[F9 record ladder] \(depth) records, \(arena.cellCount) cells,"
            line += " \(arena.chargedBytes) B charged (budget is \(Self.budgetBytes)):"
            for width in [100, 2] {
                let expected = arena.independentWideDisplayRowTotal(width: width)
                let rounds = measureWidePass(&arena, width: width, variant: .wideAware)
                for round in rounds { #expect(round.displayRowTotal == expected) }
                let perRow = medianMilliseconds(rounds) * 1_000_000 / Double(expected)
                line += " 179->\(width) \(passSummary(rounds))"
                line += String(format: " over %d rows = %.2f ns/row;", expected, perRow)
            }
            print(line)
        }
    }

    /// `research/31/F2`'s own arms, re-run in this session as the control `research/31/D3` Decision 7 asks for.
    ///
    /// `mix` and `full` contain no wide cell, so no record is flagged and none takes the fallback.
    /// Two things this is for: it says the fast path is untouched by the wide arm, and -- because
    /// it is `research/31/F2`'s instrument on `research/31/F2`'s stimulus at `research/31/F2`'s depth -- its numbers are directly
    /// comparable to `research/31/F2`'s published 0.015-0.016 ms, which is the cheapest available check that
    /// this session's machine is the one `research/31/F2` measured on.
    @Test("F9 -- research/31/F2's mix and full arms, re-run as the control", .enabled(if: probeIsEnabled))
    func fastPathControl() throws {
        for contentClass in LogicalLineContentClass.allCases {
            let raw = buildStimulus(contentClass: contentClass, targetDisplayRows: 34_000)
            let stimulus = truncated(raw, toLineCount: Self.controlRecords)
            var arena = LogicalLineArena(stimulus)
            var line = "[F9 control] \(contentClass.rawValue) \(Self.controlRecords) lines,"
            line += " \(arena.arenaByteCount) arena bytes:"
            for width in Self.widths {
                let expected = arena.independentDisplayRowTotal(width: width)
                let rounds = measurePass(&arena, width: width, source: .arena)
                for round in rounds { #expect(round.displayRowTotal == expected) }
                line += " 179->\(width) \(passSummary(rounds));"
            }
            print(line)
        }
    }
}
