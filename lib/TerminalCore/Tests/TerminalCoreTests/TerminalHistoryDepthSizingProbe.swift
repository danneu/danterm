// The candidate-bound sizing probe: what a *proposed* set of history bounds actually
// retains at 179 columns, and what a width change costs at that depth.
//
// It lives in the test target rather than beside the other probes in
// `lib/TerminalCore/Sources/` for one reason: the cap-taking initializer is internal to
// `TerminalCore` on purpose (`D8` -- the public initializer enforcing the fixed
// production values is an invariant with its own test), so a probe that varies the caps
// cannot be an executable in another target without widening that API. Nothing here
// proposes widening it.
//
// Belongs here: constructing a terminal at candidate bounds, feeding a content class,
// and reading back the three quantities the bounds are denominated in -- rows, stored
// cells, and the engine's own charged bytes -- plus a resize distribution measured the
// way `TerminalResizeProbeSupport` measures one. Does not belong here: a threshold, a
// verdict, or a default. Picking bounds is a human decision that reopens `D8`.
//
// Not part of the `just test` gate. Every measurement below is skipped unless
// `DANTERM_HISTORY_DEPTH_PROBE` is set, because saturating a multi-million-cell history
// takes minutes and proves nothing about correctness. Run it as:
//
//     DANTERM_HISTORY_DEPTH_PROBE=1 swift test -c release --package-path lib/TerminalCore \
//       --filter TerminalHistoryDepthSizingProbe
//
// Release matters: the frozen cost model it is read against was fit on release builds.
import Foundation
import Testing

@testable import TerminalCore

/// One content class the sizing question is asked of, kept as data so a report names its shape.
///
/// The three lines are `ResizeProbePayload`'s verbatim, so this probe's depths and the
/// committed resize probe's are measurements of the same content rather than two
/// similarly-described ones.
enum HistorySizingPayload: String, CaseIterable {
    /// A ~50-column line: program output, and what the resize probe's `v1`/`v2` feed.
    case dense
    /// Short shell-history lines: the regime a content-sized row retains deepest.
    case sparse
    /// Lines that fill 179 columns: the regime that maximizes retained *cells*, and the
    /// one a row cap does not bound.
    case wide

    private static let sparseCommands = [
        "ls", "cd ..", "git status", "make", "vim .", "pwd", "top", "git log",
    ]

    func line(_ index: Int) -> String {
        switch self {
        case .dense:
            return "DANTERM-RESIZE-\(String(format: "%05d", index)) plain ascii retained row"
        case .sparse:
            return Self.sparseCommands[index % Self.sparseCommands.count]
        case .wide:
            let unit = "abcdefgh\(index % 10)"
            return String(String(repeating: unit, count: 20).prefix(179))
        }
    }
}

/// What one candidate bound set retained, in the three currencies the bounds are written in.
///
/// All three are reported on every run even when only one can bind, because "which bound
/// bound first" is the whole question and a report that only printed the binding one could
/// not be checked against the arithmetic that predicted it.
struct HistorySizingReading {
    let payload: HistorySizingPayload
    let columns: Int
    let budgetBytes: Int
    let rowCap: Int
    let cellCap: Int
    let fedLineCount: Int
    let retainedRowCount: Int
    let storedCellCount: Int
    /// The engine's own charge, the quantity the byte budget is compared against -- not the
    /// packed payload the retained-row probe reports, which excludes the per-row slot,
    /// array header, and capacity slack.
    let chargedBytes: Int

    /// Mean stored cells per retained row. Only the mean: per-row storage is private to
    /// `Terminal`, and the cells-per-row *distribution* is the retained-row probe's job
    /// (`just terminal-retained-row-probe`), which reads it through the public row API.
    var meanCellsPerRow: Double {
        retainedRowCount == 0 ? 0 : Double(storedCellCount) / Double(retainedRowCount)
    }

    /// Names the bound that stopped the fill, or reports that the line count did.
    ///
    /// Reads "lineCount" rather than silently naming a bound when nothing bound: a fill that
    /// ran out of stimulus is a probe that measured its own recipe, and that has to be
    /// visible rather than inferred from a suspiciously round depth.
    var bindingBound: String {
        if Double(storedCellCount) >= Double(cellCap) - meanCellsPerRow - 1 { return "cell" }
        if retainedRowCount >= rowCap { return "row" }
        if chargedBytes >= budgetBytes - 4_096 { return "byte" }
        return "lineCount (nothing bound -- feed more)"
    }

    var chargedBytesPerRow: Double {
        retainedRowCount == 0 ? 0 : Double(chargedBytes) / Double(retainedRowCount)
    }

    /// `D8`'s frozen two-term fit, in milliseconds, at this reading's depth.
    var modelledResizeMilliseconds: Double {
        (1.85 * Double(retainedRowCount) + 0.352 * Double(storedCellCount)) / 1_000
    }
}

/// Fills a terminal at candidate bounds and reads back what it retained.
///
/// Feeds line by line exactly as `makeSaturatedTerminal` does, so depth differences between
/// this probe and the committed one are differences in bounds rather than in feeding.
func measureHistorySizing(
    payload: HistorySizingPayload,
    columns: Int = 179,
    rows: Int = 66,
    lineCount: Int,
    budgetBytes: Int = Terminal.productionScrollbackBudgetBytes,
    rowCap: Int = Terminal.productionScrollbackRowCap,
    cellCap: Int = Terminal.productionScrollbackCellCap
) -> (reading: HistorySizingReading, terminal: Terminal) {
    var terminal = Terminal(
        columns: columns,
        rows: rows,
        scrollbackBudgetBytes: budgetBytes,
        scrollbackRowCap: rowCap,
        scrollbackCellCap: cellCap
    )!
    for line in 0..<lineCount {
        terminal.feed(Array("\(payload.line(line))\r\n".utf8))
    }

    let reading = HistorySizingReading(
        payload: payload,
        columns: columns,
        budgetBytes: budgetBytes,
        rowCap: rowCap,
        cellCap: cellCap,
        fedLineCount: lineCount,
        retainedRowCount: terminal.scrollbackRowCount,
        storedCellCount: terminal.scrollbackStoredCellCount,
        chargedBytes: terminal.scrollbackByteCount
    )
    return (reading, terminal)
}

/// Times width changes on an already-filled terminal, mirroring `measureSaturatedResize`.
///
/// Deliberately the same alternation, warmup count, and clock as the committed probe: the
/// only intended difference between the two is the bounds the history was filled under, and
/// a second timing methodology would make the comparison uninterpretable.
func measureResizeMilliseconds(
    of terminal: inout Terminal,
    columns: Int = 179,
    rows: Int = 66,
    alternateColumns: Int = 100,
    warmupCount: Int = 4,
    sampleCount: Int = 20
) -> (
    median: Double, minimum: Double, maximum: Double,
    retainedAtStart: Int, storedCellsAtStart: Int
) {
    let widths = [alternateColumns, columns]
    for index in 0..<warmupCount {
        terminal.resize(columns: widths[index % 2], rows: rows)
    }
    // Both terms are re-read after warming, not just rows. A warmup narrowing can trip the
    // row cap and evict -- which is the whole failure mode `D8` describes -- so cells taken
    // before the warmup would price a history the timed samples no longer reflow.
    let retainedAtStart = terminal.scrollbackRowCount
    let storedCellsAtStart = terminal.scrollbackStoredCellCount

    var samples: [UInt64] = []
    samples.reserveCapacity(sampleCount)
    for index in 0..<sampleCount {
        let width = widths[(warmupCount + index) % 2]
        let started = DispatchTime.now().uptimeNanoseconds
        terminal.resize(columns: width, rows: rows)
        samples.append(DispatchTime.now().uptimeNanoseconds &- started)
    }
    samples.sort()
    func milliseconds(_ value: UInt64) -> Double { Double(value) / 1_000_000 }
    return (
        median: milliseconds(samples[samples.count / 2]),
        minimum: milliseconds(samples[0]),
        maximum: milliseconds(samples[samples.count - 1]),
        retainedAtStart: retainedAtStart,
        storedCellsAtStart: storedCellsAtStart
    )
}

private let probeIsEnabled = ProcessInfo.processInfo.environment["DANTERM_HISTORY_DEPTH_PROBE"] != nil

private func report(_ reading: HistorySizingReading) {
    print(
        """
        [sizing] payload=\(reading.payload.rawValue) caps(rows=\(reading.rowCap), \
        cells=\(reading.cellCap), bytes=\(reading.budgetBytes)) fed=\(reading.fedLineCount)
          retainedRows=\(reading.retainedRowCount) storedCells=\(reading.storedCellCount) \
        chargedBytes=\(reading.chargedBytes) (\(String(format: "%.1f", reading.chargedBytesPerRow)) B/row)
          meanCellsPerRow=\(String(format: "%.1f", reading.meanCellsPerRow)) \
        binding=\(reading.bindingBound) \
        modelledResize=\(String(format: "%.1f", reading.modelledResizeMilliseconds)) ms
        """
    )
}

/// Reads what candidate history bounds retain at 179 columns. A probe: no thresholds, no verdicts.
struct TerminalHistoryDepthSizingProbe {
    @Test("today's bounds: which one binds first, per content class", .enabled(if: probeIsEnabled))
    func todaysBoundsBindingPoint() throws {
        for payload in HistorySizingPayload.allCases {
            let lineCount = payload == .sparse ? 250_000 : 60_000
            let (reading, _) = measureHistorySizing(payload: payload, lineCount: lineCount)
            report(reading)
            #expect(reading.retainedRowCount > 0)
        }
    }

    @Test(
        "candidate bounds reaching ~10,000 retained rows at 179 columns",
        .enabled(if: probeIsEnabled)
    )
    func candidateBoundsDepth() throws {
        // Candidate (b): 10,000 rows of full-width content. Cell cap is 10,000 x 179, and the
        // byte budget is left at production so it can be seen binding rather than assumed away.
        let candidates: [(name: String, rowCap: Int, cellCap: Int, budget: Int)] = [
            ("b/worst-case-179", 10_000, 1_790_000, Terminal.productionScrollbackBudgetBytes),
            ("b/worst-case-179-uncapped-bytes", 10_000, 1_790_000, 1 << 30),
        ]
        for candidate in candidates {
            for payload in HistorySizingPayload.allCases {
                let lineCount = payload == .sparse ? 250_000 : 60_000
                let (reading, _) = measureHistorySizing(
                    payload: payload,
                    lineCount: lineCount,
                    budgetBytes: candidate.budget,
                    rowCap: candidate.rowCap,
                    cellCap: candidate.cellCap
                )
                print("[candidate \(candidate.name)]")
                report(reading)
                #expect(reading.retainedRowCount > 0)
            }
        }
    }

    @Test(
        "resize cost at candidate depth, against the frozen model's prediction",
        .enabled(if: probeIsEnabled)
    )
    func candidateResizeCost() throws {
        // The first point is a calibration rather than a result: at production bounds the wide
        // payload is exactly what `just terminal-resize-probe --recipe wide` measures, so if
        // this harness cannot reproduce that number its candidate-depth numbers mean nothing.
        //
        // The two `b/` points differ only in row cap, and that is the measurement: a row cap
        // below `cellCap / alternateColumns` evicts during the warmup narrowing, so the naive
        // one times a history the candidate does not actually hold.
        let points: [(name: String, payload: HistorySizingPayload, rowCap: Int, cellCap: Int, budget: Int)] = [
            ("calibration/production-bounds", .wide, Terminal.productionScrollbackRowCap,
             Terminal.productionScrollbackCellCap, Terminal.productionScrollbackBudgetBytes),
            ("b/worst-case-179, rowCap 10,000", .wide, 10_000, 1_790_000, 1 << 30),
            ("b/worst-case-179, rowCap 89,500 (lossless to 20 cols)", .wide, 89_500, 1_790_000, 1 << 30),
            ("a/typical-plain, cellCap 510k", .dense, 25_500, 510_000, Terminal.productionScrollbackBudgetBytes),
        ]
        for point in points {
            var (reading, terminal) = measureHistorySizing(
                payload: point.payload,
                lineCount: point.payload == .sparse ? 250_000 : 60_000,
                budgetBytes: point.budget,
                rowCap: point.rowCap,
                cellCap: point.cellCap
            )
            report(reading)
            let timing = measureResizeMilliseconds(of: &terminal)
            let modelledAfterWarmup =
                (1.85 * Double(timing.retainedAtStart) + 0.352 * Double(timing.storedCellsAtStart))
                / 1_000
            print(
                """
                [resize \(point.name)] retainedAtStart=\(timing.retainedAtStart) \
                storedCellsAtStart=\(timing.storedCellsAtStart) \
                evictedDuringWarmup=\(reading.retainedRowCount - timing.retainedAtStart) rows \
                median=\(String(format: "%.1f", timing.median)) ms \
                min=\(String(format: "%.1f", timing.minimum)) ms \
                max=\(String(format: "%.1f", timing.maximum)) ms \
                modelled=\(String(format: "%.1f", modelledAfterWarmup)) ms
                """
            )
            #expect(timing.median > 0)
        }
    }
}
