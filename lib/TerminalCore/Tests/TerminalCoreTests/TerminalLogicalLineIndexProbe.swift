// The F2 counting-pass probe for doc 31: what does the eager block-total recompute cost at
// depth, when a width change discards every cached total and rebuilds the index in one pass?
//
// Doc 31 stores nothing width-dependent, so a resize's only history-side work is recounting
// display rows -- one cell count read and one divide per logical line. `research/31/H2` claims that is
// milliseconds where reflow was `research/28/F15`'s `1.85 us x rows + 0.352 us x cells`. This file
// measures it, at 10,000 and 100,000 logical lines, for both count-sources `research/31/D1` named:
// `arena` (the count read from each record's header, which is what the candidate direction
// sketches) and `counts` (a dense parallel array, which is what F1's prototype happened to do
// and which costs 8 bytes per line of extra index state).
//
// Belongs here: the F2 harness, the synthetic-depth control, and the reporting. Does not belong
// here: the arena itself (`TerminalLogicalLineReadProbe.swift` owns it), a threshold, or a
// verdict -- `research/31/D1`'s Part B rule holds those, frozen at `497d181` before this file existed.
//
// Not part of the `just test` gate. Every measurement is skipped unless
// `DANTERM_LOGICAL_LINE_PROBE` is set. Run it as:
//
//     DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
//       --filter TerminalLogicalLineIndexProbe
//
// Release matters: the bounds in `research/31/H2` are read against release-build measurements.
import Foundation
import Testing

@testable import TerminalCore

// MARK: - The two count-sources

/// Where a counting pass reads each logical line's cell count from.
///
/// The distinction is the entire cost: `arena` strides across the whole arena touching one
/// header per line, `counts` scans `8 x lineCount` contiguous bytes. `research/31/D1` makes `arena`
/// primary because the candidate direction's index stores offsets and nothing else.
enum CountSource: String, CaseIterable {
    case arena
    case counts
}

// MARK: - Stimulus at depth

/// Cuts a stimulus down to exactly `lineCount` logical lines.
///
/// `buildStimulus` fills to a display-row target, which overshoots in logical lines by an amount
/// that depends on the content class. F2's depths are stated in logical lines, so a run that
/// measured "10,000 lines" of one class against 12,000 of another would not be one depth.
func truncated(_ stimulus: RetainedStimulus, toLineCount lineCount: Int) -> RetainedStimulus {
    precondition(stimulus.lineCount >= lineCount, "stimulus has \(stimulus.lineCount) lines, needed \(lineCount)")
    let end = stimulus.lineStarts[lineCount]
    return RetainedStimulus(
        displayRows: Array(stimulus.displayRows[0..<end]),
        lineStarts: Array(stimulus.lineStarts[0...lineCount]),
        columns: stimulus.columns
    )
}

/// Repeats a real arena's per-line cell counts up to `lineCount` lines.
///
/// The synthetic deep arena is built from the counts a real `Terminal` actually produced rather
/// than from the generator's string lengths, so its record-size distribution is the engine's own
/// (canonical trailing-cell trimming included) and not a second model of it.
func tiledCounts(_ counts: [Int], toLineCount lineCount: Int) -> [Int] {
    var out: [Int] = []
    out.reserveCapacity(lineCount)
    while out.count < lineCount {
        out.append(counts[out.count % counts.count])
    }
    return out
}

// MARK: - Timing

/// One timed counting pass: its wall time, the depth it ran at, and the total it produced.
///
/// The total is carried out of the timed region on purpose -- it is what `research/31/D1` gate 1 checks
/// against an independent sum, and it is what stops the pass from being optimized away.
struct PassRound {
    let nanoseconds: Double
    let lineCount: Int
    let displayRowTotal: Int
}

private func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// Runs the eager pass `rounds` times after `warmupRounds` untimed ones.
///
/// Each call rebuilds the whole index from scratch, so a round is a complete width change and
/// rounds do not amortize each other. The arena is passed `inout` because the pass mutates the
/// index -- that mutation is the product being priced.
func measurePass(
    _ arena: inout LogicalLineArena,
    width: Int,
    source: CountSource,
    rounds: Int = 9,
    warmupRounds: Int = 2
) -> [PassRound] {
    for _ in 0..<warmupRounds {
        switch source {
        case .arena: arena.recomputeIndexFromArena(width: width)
        case .counts: arena.recomputeIndex(width: width)
        }
    }
    var out: [PassRound] = []
    out.reserveCapacity(rounds)
    for _ in 0..<rounds {
        let start = nowNanoseconds()
        switch source {
        case .arena: arena.recomputeIndexFromArena(width: width)
        case .counts: arena.recomputeIndex(width: width)
        }
        let elapsed = nowNanoseconds() - start
        out.append(
            PassRound(
                nanoseconds: Double(elapsed),
                lineCount: arena.lineCount,
                displayRowTotal: arena.displayRowCount
            )
        )
    }
    return out
}

/// Median, min and max in milliseconds, with the round count, formatted for one report line.
func passSummary(_ rounds: [PassRound]) -> String {
    let millis = rounds.map { $0.nanoseconds / 1_000_000 }.sorted()
    guard let low = millis.first, let high = millis.last else { return "not measured (n=0)" }
    let mid = median(millis)
    return String(format: "median %.3f ms (min %.3f, max %.3f, n=%d)", mid, low, high, millis.count)
}

func medianMilliseconds(_ rounds: [PassRound]) -> Double {
    median(rounds.map { $0.nanoseconds / 1_000_000 })
}

// MARK: - The probe

/// `research/31/F2`: prices the eager counting pass at both depths, both classes, both count-sources.
///
/// Reports distributions and gate outcomes; it does not print a verdict. The thresholds live in
/// `research/31/D1`'s Part B rule and are applied once, by hand, to what this prints.
@Suite(.serialized)
struct TerminalLogicalLineIndexProbe {
    static let probeIsEnabled = ProcessInfo.processInfo.environment["DANTERM_LOGICAL_LINE_PROBE"] != nil

    /// Widths the recompute is measured at. 179 is the floor (the index is rebuilt for the width
    /// it already had), 100 narrows, 200 widens. All three do identical per-line work.
    static let widths = [179, 100, 200]
    static let shallowLines = 10_000
    static let deepLines = 100_000

    @Test("F2 -- the eager counting pass at 10,000 and 100,000 logical lines", .enabled(if: probeIsEnabled))
    func countingPassAtDepth() throws {
        print("[F2] eager block-total recompute; 9 measured rounds + 2 warmup per cell")
        print("[F2] load average before: \(loadAverageDescription())")

        for contentClass in LogicalLineContentClass.allCases {
            // Overshoot the display-row target enough that both classes reach 10,000 logical
            // lines, then cut to exactly that depth.
            let raw = buildStimulus(contentClass: contentClass, targetDisplayRows: 34_000)
            print("[F2] \(contentClass.rawValue): raw stimulus \(raw.displayRowCount) display rows, \(raw.lineCount) logical lines")
            #expect(raw.lineCount >= Self.shallowLines)
            let stimulus = truncated(raw, toLineCount: Self.shallowLines)

            var realArena = LogicalLineArena(stimulus)
            let counts = realArena.lineCellCountsSnapshot()
            #expect(counts.count == Self.shallowLines)
            let cells = counts.reduce(0, +)
            print("""
                [F2] \(contentClass.rawValue): real arena \(realArena.lineCount) lines, \
                \(cells) cells, \(realArena.arenaByteCount) arena bytes
                """)

            var syntheticShallow = LogicalLineArena(syntheticCellCounts: counts, width: stimulus.columns)
            var syntheticDeep = LogicalLineArena(
                syntheticCellCounts: tiledCounts(counts, toLineCount: Self.deepLines),
                width: stimulus.columns
            )
            print("""
                [F2] \(contentClass.rawValue): synthetic arenas \
                \(syntheticShallow.arenaByteCount) bytes at \(Self.shallowLines) lines, \
                \(syntheticDeep.arenaByteCount) bytes at \(Self.deepLines) lines
                """)
            // Geometry equality is what makes the synthetic arena admissible as a stand-in.
            #expect(syntheticShallow.arenaByteCount == realArena.arenaByteCount)
            #expect(syntheticShallow.lineCount == realArena.lineCount)

            for width in Self.widths {
                for source in CountSource.allCases {
                    let real = measurePass(&realArena, width: width, source: source)
                    let shallow = measurePass(&syntheticShallow, width: width, source: source)
                    let deep = measurePass(&syntheticDeep, width: width, source: source)

                    // Gate 1, non-elision: every pass's product is cross-checked against a sum
                    // computed by a route that shares no bookkeeping with the blocked prefix.
                    for (arena, rounds) in [
                        (realArena, real), (syntheticShallow, shallow), (syntheticDeep, deep),
                    ] {
                        let expected = arena.independentDisplayRowTotal(width: width)
                        #expect(expected > 0)
                        for round in rounds { #expect(round.displayRowTotal == expected) }
                    }

                    // Gate 2's control reads off the `arena` source at every width; the ratio is
                    // printed for all of them so a single lucky width cannot carry it.
                    let fidelity = medianMilliseconds(shallow) / medianMilliseconds(real)
                    print("""
                        [F2] \(contentClass.rawValue) 179->\(width) \(source.rawValue): \
                        real-10k \(passSummary(real)) | synthetic-10k \(passSummary(shallow)) \
                        | synthetic-100k \(passSummary(deep)) \
                        | fidelity \(String(format: "%.3fx", fidelity)) \
                        | rows \(real.first?.displayRowTotal ?? -1)/\(deep.first?.displayRowTotal ?? -1)
                        """)
                }
            }
        }

        print("[F2] load average after: \(loadAverageDescription())")
    }

    /// Descriptive: the pass's cost against depth, with a point in the middle of the curve.
    ///
    /// No threshold is read off this. It exists because the two frozen depths are two points,
    /// and the `arena` source's cost between them is not proportional -- a claim about the shape
    /// of that curve needs its middle measured, not interpolated
    /// (`agent-docs/measurement-discipline.md`).
    @Test("F2 -- counting-pass cost against depth (descriptive)", .enabled(if: probeIsEnabled))
    func countingPassDepthLadder() throws {
        let depths = [10_000, 30_000, 100_000]
        print("[F2 ladder] descriptive; width 179->100; 9 measured rounds per cell")

        for contentClass in LogicalLineContentClass.allCases {
            let raw = buildStimulus(contentClass: contentClass, targetDisplayRows: 34_000)
            let stimulus = truncated(raw, toLineCount: Self.shallowLines)
            let counts = LogicalLineArena(stimulus).lineCellCountsSnapshot()

            for depth in depths {
                var arena = LogicalLineArena(
                    syntheticCellCounts: tiledCounts(counts, toLineCount: depth),
                    width: stimulus.columns
                )
                let expected = arena.independentDisplayRowTotal(width: 100)
                var line = "[F2 ladder] \(contentClass.rawValue) \(depth) lines, \(arena.arenaByteCount) bytes:"
                for source in CountSource.allCases {
                    let rounds = measurePass(&arena, width: 100, source: source)
                    for round in rounds { #expect(round.displayRowTotal == expected) }
                    let perLine = medianMilliseconds(rounds) * 1_000_000 / Double(depth)
                    line += " \(source.rawValue) \(passSummary(rounds))"
                    line += String(format: " = %.2f ns/line;", perLine)
                }
                print(line)
            }
        }
    }
}

/// The one-minute load average, or an explicit "unavailable" -- never a 0 that reads as calm.
func loadAverageDescription() -> String {
    var averages = [Double](repeating: 0, count: 3)
    guard getloadavg(&averages, 3) == 3 else { return "unavailable" }
    return String(format: "%.2f", averages[0])
}
