// The F7 blank-record counting-pass probe for doc 31: what does the eager block-total recompute
// cost at the record count `31/D2` Decision 1 actually admits?
//
// `31/D2` charges the block index 8 bytes per record, so a 16 MiB budget admits 1,048,576 blank
// logical lines (8 arena bytes + 8 index bytes each) -- 10.5x the deepest depth `31/F2` measured.
// `D2`'s own open-question section extrapolated `F2`'s 100,000-line per-line rate to ~6.4 ms
// against `F2`'s one-frame (16.67 ms) reject bound, and froze a decision rule that has to be read
// against a measurement rather than that arithmetic. This file takes the measurement.
//
// It follows `F2`'s instrument as closely as a zero-cell stimulus allows -- same 9 measured
// rounds plus 2 warmup, same median-of-rounds statistic with min/max/n, same three width changes,
// both count-sources, release build, headless, one process -- and reuses `F2`'s harness
// (`CountSource`, `measurePass`, `passSummary`, `medianMilliseconds`, `loadAverageDescription`)
// and `F1`'s arena rather than reimplementing either.
//
// Belongs here: the blank stimulus, the two controls a zero-cell stimulus needs (a real-engine
// fidelity control, and a sentinel arm that restores the width-responsiveness gate 1 loses when
// every record folds to one display row at every width), and the reporting. Does not belong here:
// the arena (`TerminalLogicalLineReadProbe.swift` owns it), `F2`'s own arms
// (`TerminalLogicalLineIndexProbe.swift`, unedited), a threshold, or a verdict -- `31/D2`'s open
// question holds the rule, frozen before this file existed.
//
// Not part of the `just test` gate. Every measurement is skipped unless
// `DANTERM_LOGICAL_LINE_PROBE` is set. Run it as:
//
//     DANTERM_LOGICAL_LINE_PROBE=1 swift test -c release --package-path lib/TerminalCore \
//       --filter TerminalLogicalLineBlankIndexProbe
//
// Release matters: the bound this is read against is a release-build bound.
import Foundation
import Testing

@testable import TerminalCore

// MARK: - The blank stimulus

/// Blank retained history as a real `Terminal` produces it: `lineCount` empty rows scrolled off.
///
/// The degenerate regime `31/D2` Decision 1 bounds. Every row is hard-ended, so every display row
/// is its own logical line and every record is as small as a record gets. Built through the engine
/// rather than by hand so the control arena's geometry is the engine's own.
///
/// **The one thing it does not reproduce is `D2`'s zero-cell record.** Today's canonical extent
/// (`PackedRetainedRow.pack`, invariant `I2`) is floored at one cell, so a blank retained row packs
/// to *one* stored cell, not zero. That floor is a property of today's per-display-row store, not
/// of the arena, and `D2`'s 1,048,576 derivation assumes a zero-cell record is representable
/// (`DD15`). The probe therefore measures both: the zero-cell arm is the verdict-bearing one
/// because it is `D2`'s stimulus, and the one-cell arm bounds the alternative record format --
/// which, being 16 arena bytes per record, admits *fewer* records at the same budget (699,050),
/// so the zero-cell record count bounds it from above.
func buildBlankStimulus(lineCount: Int, columns: Int = 179, rows: Int = 66) -> RetainedStimulus {
    var terminal = Terminal(
        columns: columns,
        rows: rows,
        scrollbackBudgetBytes: 1 << 28
    )!

    let chunk = Array(String(repeating: "\r\n", count: 256).utf8)
    while terminal.scrollbackRowCount < lineCount { terminal.feed(chunk) }

    var displayRows: [Terminal.GridRow] = []
    var lineStarts: [Int] = [0]
    for index in 0..<lineCount {
        guard let row = terminal.retainedRowForTesting(at: index) else { break }
        precondition(row.isSoftWrapped == false, "a blank retained row must not soft-wrap")
        precondition(
            Terminal.PackedRetainedRow.pack(row).storedCellCount <= 1,
            "a blank retained row must pack to at most the canonical floor of one cell"
        )
        displayRows.append(row)
        lineStarts.append(displayRows.count)
    }
    return RetainedStimulus(displayRows: displayRows, lineStarts: lineStarts, columns: columns)
}

/// `count` records of `cells` cells each: the synthetic form of the stimulus above.
func uniformCellCounts(_ count: Int, cells: Int) -> [Int] { [Int](repeating: cells, count: count) }

/// Blank records with one full-width record every `stride`, for the width-responsiveness control.
///
/// A pure blank arena folds to one display row per record at *every* width, so its total cannot
/// tell a pass that ran from a pass an optimizer hoisted. Sprinkling records the width does change
/// restores that discrimination at ~0.1% of the record count.
func blankCellCountsWithSentinels(_ count: Int, stride: Int, cells: Int) -> [Int] {
    (0..<count).map { $0 % stride == stride - 1 ? cells : 0 }
}

// MARK: - The probe

/// `31/F7`: prices `F2`'s eager counting pass at the blank-record count `31/D2` admits.
///
/// Reports distributions and gate outcomes; it prints no verdict. The rule is `31/D2`'s open
/// question -- at or above one 60 Hz frame a record-count safety bound ships -- and it is applied
/// once, by hand, to what this prints.
@Suite(.serialized)
struct TerminalLogicalLineBlankIndexProbe {
    static let probeIsEnabled = ProcessInfo.processInfo.environment["DANTERM_LOGICAL_LINE_PROBE"] != nil

    /// `31/D2` Decision 1: 16,777,216 B / (8 arena + 8 index) B per blank record.
    static let budgetRecords = 1_048_576
    /// The depth `F2`'s gate 2 control is taken at, and `F2`'s own shallow depth.
    static let controlRecords = 10_000
    /// `F2`'s three width changes, unchanged: same-width floor, narrow, widen.
    static let widths = [179, 100, 200]

    @Test(
        "F7 -- the eager counting pass at 1,048,576 blank records",
        .enabled(if: probeIsEnabled)
    )
    func blankCountingPassAtBudgetDepth() throws {
        print("[F7] eager block-total recompute, blank (zero-cell) records; 9 measured rounds + 2 warmup per cell")
        print("[F7] load average before: \(loadAverageDescription())")

        // Gate 2's control, adapted: the real-engine arena at 10,000 blank records against a
        // synthetic one built from the *same* per-record counts, so the two agree on geometry
        // exactly and the only variable is how they were constructed. `F2`'s rule allows 15%.
        let stimulus = buildBlankStimulus(lineCount: Self.controlRecords)
        #expect(stimulus.lineCount == Self.controlRecords)
        var realArena = LogicalLineArena(stimulus)
        let realCounts = realArena.lineCellCountsSnapshot()
        #expect(realCounts.count == Self.controlRecords)
        var syntheticControl = LogicalLineArena(
            syntheticCellCounts: realCounts, width: stimulus.columns
        )
        #expect(syntheticControl.arenaByteCount == realArena.arenaByteCount)
        #expect(syntheticControl.lineCount == realArena.lineCount)
        print("""
            [F7] control arenas at \(Self.controlRecords) engine-produced blank records: real \
            \(realArena.arenaByteCount) bytes, synthetic \(syntheticControl.arenaByteCount) bytes; \
            engine stored-cell counts min \(realCounts.min() ?? -1) max \(realCounts.max() ?? -1) \
            (canonical extent is floored at one cell -- see `DD15`)
            """)

        // The verdict-bearing arm: `D2`'s stimulus, 1,048,576 zero-cell records.
        var deep = LogicalLineArena(
            syntheticCellCounts: uniformCellCounts(Self.budgetRecords, cells: 0),
            width: stimulus.columns
        )
        // Descriptive: the same record count with today's one-cell canonical floor, which doubles
        // the arena stride from 8 B to 16 B. It bounds the record format `DD15` decides against.
        var deepOneCell = LogicalLineArena(
            syntheticCellCounts: uniformCellCounts(Self.budgetRecords, cells: 1),
            width: stimulus.columns
        )
        // The sentinel arm: same depth, ~0.1% of records full-width, so its total moves with width.
        var sentinel = LogicalLineArena(
            syntheticCellCounts: blankCellCountsWithSentinels(
                Self.budgetRecords, stride: 1_000, cells: stimulus.columns
            ),
            width: stimulus.columns
        )
        print("""
            [F7] deep arenas at \(Self.budgetRecords) records: zero-cell \(deep.arenaByteCount) \
            arena bytes + \(Self.budgetRecords * 8) index bytes = \
            \(deep.arenaByteCount + Self.budgetRecords * 8) B charged; one-cell \
            \(deepOneCell.arenaByteCount) arena bytes; sentinel \(sentinel.arenaByteCount) arena bytes
            """)

        for width in Self.widths {
            for source in CountSource.allCases {
                let real = measurePass(&realArena, width: width, source: source)
                let control = measurePass(&syntheticControl, width: width, source: source)
                let budget = measurePass(&deep, width: width, source: source)
                let oneCell = measurePass(&deepOneCell, width: width, source: source)
                let sentinelRounds = measurePass(&sentinel, width: width, source: source)

                // Gate 1, non-elision: every pass's product is cross-checked against a total
                // computed by a route the blocked prefix does not share, and no total is zero.
                for (arena, rounds) in [
                    (realArena, real), (syntheticControl, control), (deep, budget),
                    (deepOneCell, oneCell), (sentinel, sentinelRounds),
                ] {
                    let expected = arena.independentDisplayRowTotal(width: width)
                    #expect(expected > 0)
                    for round in rounds { #expect(round.displayRowTotal == expected) }
                }
                // The blank arms fold to one display row per record at every width, so their
                // totals cannot show that the pass responded to width. The sentinel arm can.
                #expect(deep.displayRowCount == Self.budgetRecords)

                let fidelity = medianMilliseconds(control) / medianMilliseconds(real)
                let perRecord = medianMilliseconds(budget) * 1_000_000 / Double(Self.budgetRecords)
                print("""
                    [F7] blank 179->\(width) \(source.rawValue): \
                    real-10k \(passSummary(real)) | synthetic-10k \(passSummary(control)) \
                    | zero-cell-1048576 \(passSummary(budget)) \
                    = \(String(format: "%.2f ns/record", perRecord)) \
                    | one-cell-1048576 \(passSummary(oneCell)) \
                    | fidelity \(String(format: "%.3fx", fidelity)) \
                    | sentinel \(passSummary(sentinelRounds)) \
                    | rows zero-cell \(budget.first?.displayRowTotal ?? -1) / sentinel \
                    \(sentinelRounds.first?.displayRowTotal ?? -1)
                    """)
            }
        }

        print("[F7] load average after: \(loadAverageDescription())")
    }

    /// Descriptive: the pass's cost against blank-record count, with the middle of the curve.
    ///
    /// `31/D2`'s open question extrapolated from `F2`'s two-point curve, and
    /// `agent-docs/measurement-discipline.md` is explicit that a model predicting a curve gets its
    /// middle measured before it is acted on. No threshold is read off this arm.
    @Test("F7 -- blank counting-pass cost against record count (descriptive)", .enabled(if: probeIsEnabled))
    func blankCountingPassDepthLadder() throws {
        let depths = [10_000, 100_000, 300_000, Self.budgetRecords]
        print("[F7 ladder] descriptive; blank records; width 179->100; 9 measured rounds per cell")

        for depth in depths {
            var arena = LogicalLineArena(
                syntheticCellCounts: uniformCellCounts(depth, cells: 0), width: 179
            )
            let expected = arena.independentDisplayRowTotal(width: 100)
            #expect(expected == depth)
            var line = "[F7 ladder] \(depth) blank records, \(arena.arenaByteCount) arena bytes:"
            for source in CountSource.allCases {
                let rounds = measurePass(&arena, width: 100, source: source)
                for round in rounds { #expect(round.displayRowTotal == expected) }
                let perRecord = medianMilliseconds(rounds) * 1_000_000 / Double(depth)
                line += " \(source.rawValue) \(passSummary(rounds))"
                line += String(format: " = %.2f ns/record;", perRecord)
            }
            print(line)
        }
    }
}
