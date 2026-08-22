// `31/PO7`: what planning one frame spends addressing retained history.
//
// The obligation `31/I7` states is that the frame path stays arithmetic -- projection totals, the
// top row, the cursor stream row and every clamp bound are two-integer sums, and a viewport
// traversal converts a display row to a record **once** and then advances a cursor. `research/31/HR1`
// priced the alternative: `scrollProjection` is read roughly 200 times per frame because it is
// free today, and `research/31/F1` measured one index lookup at 0.82-1.09 us, so a mapping that quietly
// made those lookups would cost 164-218 us per frame on `retained-browse` -- the workload the
// whole design is judged by.
//
// `31/AR5` is why this file exists at all: `I7` is a discipline, not a mechanism. Nothing in the
// type system stops a future call site from reaching the index inside a per-row loop, and a
// counter plus a frame plus an assertion is the only guard.
//
// What belongs here: locate counts for whole reads, at two depths. What does not: the cost of a
// locate, which is a benchmark's question rather than a test's.
import Testing

@testable import TerminalCore

@Suite("Frame locate budget")
struct TerminalFrameLocateTests {
    @Test("Planning one frame locates at most once per viewport traversal, at any depth")
    func frameLocateCountIsConstantInHistoryDepth() throws {
        // Intent: the retained-history cell walk a frame makes converts one display row to a
        //   record and then advances, and the count does not move when history gets 100x deeper.
        // Why it exists: `31/PO7`. The depth-invariance half is the load-bearing one: a count
        //   that grows with retained rows is the exact shape of `research/31/HR1`'s hazard, and it is
        //   invisible to every other test in the suite.
        // Scenario: a user scrolled back into a deep history, with the renderer drawing frames.
        func locatesForOneFrame(lines: Int) throws -> Int {
            var terminal = try #require(Terminal(columns: 40, rows: 24))
            for index in 0..<lines {
                terminal.feed(Array("history line \(index)\r\n".utf8))
            }
            terminal.scroll(toTopRow: 0)
            // Warm the read paths once, so the count measures a steady frame rather than
            // whatever the first one happens to fault in.
            terminal.forEachViewportCell(rows: 0..<24) { _, _, _, _ in }

            return Instrument.displayRowLocate.measure {
                terminal.forEachViewportCell(rows: 0..<24) { _, _, _, _ in }
            }
        }

        let shallow = try locatesForOneFrame(lines: 60)
        let deep = try locatesForOneFrame(lines: 6_000)

        // Calibration first: both frames scroll to the top of a history deeper than the
        // viewport, so a working read path must spend at least one locate. Without this the
        // whole test passes at `shallow == deep == 0` -- the state a disconnected counter or a
        // read path that stopped consulting the index produces -- which is exactly the
        // "instrument that cannot say *not measured*" `agent-docs/measurement-discipline.md`
        // rules out.
        #expect(shallow >= 1)
        // One for the frame's only viewport traversal. It then advances a cursor row by row,
        // which is the contract `research/31/D3` Decision 1 rule 2 states and the thing a
        // per-row binary search would break.
        #expect(shallow == 1)
        #expect(deep == shallow)
    }

    @Test("The projection totals and the top row cost no locate at all")
    func projectionArithmeticNeverTouchesTheIndex() throws {
        // Intent: `scrollProjection`, `projectionRowCount`'s public consumers, and the clamp
        //   bounds around them read maintained integers, not the index.
        // Why it exists: `research/31/D3` Decision 1 rule 1 names these as the ~200 reads a frame makes
        //   and requires each to stay the two-integer arithmetic it is today. A single lookup
        //   smuggled into `scrollProjection` would be invisible until the ladder came back
        //   `slower`, which is the failure mode `research/28/F17` already produced once.
        // Scenario: the render planner reading the projection three times per visible row.
        var terminal = try #require(Terminal(columns: 40, rows: 24))
        for index in 0..<2_000 {
            terminal.feed(Array("history line \(index)\r\n".utf8))
        }
        terminal.scroll(toTopRow: 5)

        let spent = Instrument.displayRowLocate.measure {
            for _ in 0..<200 {
                _ = terminal.scrollProjection
                _ = terminal.scrollbackRowCount
            }
        }
        #expect(spent == 0)
    }

    @Test("A CJK frame folds its retained record once regardless of viewport depth")
    func cjkFrameCarriesFoldedRowBoundaries() throws {
        // Intent: a frame that starts in one long wide-cell record pays one first-cell fold,
        //   while every later viewport row advances from the cursor's retained boundary.
        // Why it exists: a fold restart in a row reader or in `advance` makes viewport work grow
        //   with the number of rows drawn even though the frame performs only one index locate.
        // Scenario: the user scrolls to the start of a long CJK logical line in history.
        var terminal = try #require(Terminal(columns: 8, rows: 6))
        terminal.feed(Array(String(repeating: "界", count: 80).utf8))
        terminal.feed(Array("\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n".utf8))
        terminal.scroll(toTopRow: 0)

        func work(rows: Range<Int>) -> Int {
            Instrument.rowBoundaryCellWalk.measure {
                terminal.forEachViewportCell(rows: rows) { _, _, _, _ in }
            }
        }

        let oneRow = work(rows: 0..<1)
        let wholeFrame = work(rows: 0..<6)
        #expect(oneRow > 0)
        #expect(wholeFrame == oneRow)
    }
}
