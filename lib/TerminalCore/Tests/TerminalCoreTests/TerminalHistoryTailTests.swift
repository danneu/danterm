// Proves the bounded tail projection of primary history: that it is always a suffix of the
// whole projection, that it carries enough of that suffix for a budget-sized truncation to
// land in the same place, and that reading it costs the budget rather than the scrollback
// capacity. Separate from TerminalScrollbackTests because that suite pins what the whole
// projection *says*, and this one pins how much of it a bounded reader has to walk.
import Testing

@testable import TerminalCore

/// Pins `primaryHistoryTailText(maxLines:maxChars:)` against the full projection it stands in
/// for. Every case here builds a terminal, projects both ways, and compares -- there is no
/// separate model of what the tail "should" be, because the full projection is that model.
struct TerminalHistoryTailTests {
    /// One terminal state, named so a failure says which shape broke rather than which index.
    private struct Scenario {
        let name: String
        let columns: Int
        let rows: Int
        let feed: String
    }

    /// The boundary conditions `I2` names, plus the ordinary long-history case.
    private static let scenarios: [Scenario] = [
        Scenario(name: "empty history", columns: 8, rows: 4, feed: ""),
        Scenario(name: "whitespace-only history", columns: 8, rows: 4, feed: "   \r\n \r\n  "),
        Scenario(
            name: "history shorter than the budget",
            columns: 8, rows: 4,
            feed: (1...6).map { "line \($0)\r\n" }.joined()
        ),
        Scenario(
            name: "no hard line breaks at all",
            columns: 8, rows: 4,
            feed: String(repeating: "abcdefgh", count: 40)
        ),
        Scenario(
            name: "one soft-wrapped run spanning the tail boundary",
            columns: 8, rows: 4,
            feed: (1...8).map { _ in String(repeating: "wxyz", count: 9) + "\r\n" }.joined()
        ),
        Scenario(
            name: "blank lines straddling the tail boundary",
            columns: 8, rows: 4,
            feed: (1...30).map { $0 % 3 == 0 ? "\r\n" : "row \($0)\r\n" }.joined()
        ),
        Scenario(
            name: "history longer than the budget",
            columns: 8, rows: 4,
            feed: (1...200).map { "line \($0)\r\n" }.joined()
        ),
        Scenario(
            name: "trailing blank rows after the last content",
            columns: 8, rows: 4,
            feed: (1...60).map { "line \($0)\r\n" }.joined() + String(repeating: "\r\n", count: 20)
        ),
    ]

    /// Budgets small enough that the scenarios above straddle them in both directions.
    private static let budgets: [(maxLines: Int, maxChars: Int)] = [
        (maxLines: 1, maxChars: 1),
        (maxLines: 4, maxChars: 20),
        (maxLines: 10, maxChars: 120),
        (maxLines: 4000, maxChars: 400_000),
    ]

    private func makeTerminal(_ scenario: Scenario) throws -> Terminal {
        var terminal = try #require(Terminal(columns: scenario.columns, rows: scenario.rows))
        terminal.feed(Array(scenario.feed.utf8))
        return terminal
    }

    @Test("the bounded tail read is always a suffix of the whole projection")
    func tailIsASuffixOfTheFullProjection() throws {
        // Intent: whatever the budget, the tail read returns text the whole projection also
        //   ends with -- never a re-derivation that could differ in a cell, a wrap seam, or a
        //   trailing blank row.
        // Why it exists: the tail read starts mid-stream, so it sees neither the rows before
        //   its start nor the whole-stream `lastContentRow` the full walk computes. Both are
        //   ways it could quietly disagree with the projection it stands in for.
        for scenario in Self.scenarios {
            let terminal = try makeTerminal(scenario)
            let full = terminal.primaryHistoryText
            for budget in Self.budgets {
                let tail = terminal.primaryHistoryTailText(
                    maxLines: budget.maxLines,
                    maxChars: budget.maxChars
                )
                #expect(
                    full.hasSuffix(tail),
                    "\(scenario.name) at \(budget): tail is not a suffix of the full projection"
                )
            }
        }
    }

    @Test("the bounded tail read covers its budget, or is the whole projection")
    func tailCoversItsBudgetOrIsComplete() throws {
        // Intent: the tail either carries the budget's worth of text -- `maxLines` hard breaks
        //   or more than `maxChars` characters, measured after leading and trailing whitespace
        //   is dropped -- or it is the entire projection because history holds no more.
        // Why it exists: this is the property that makes the tail interchangeable with the
        //   full projection for a truncation that keeps only a suffix. A tail that stops one
        //   line short still reads as valid text, so nothing else here would catch it.
        for scenario in Self.scenarios {
            let terminal = try makeTerminal(scenario)
            let full = terminal.primaryHistoryText
            for budget in Self.budgets {
                let tail = terminal.primaryHistoryTailText(
                    maxLines: budget.maxLines,
                    maxChars: budget.maxChars
                )
                let trimmed = tail.drop(while: \.isWhitespace).reversed()
                    .drop(while: \.isWhitespace).reversed()
                let breaks = trimmed.filter { $0 == "\n" }.count
                let covers = breaks >= budget.maxLines || trimmed.count + 1 > budget.maxChars
                #expect(
                    covers || tail == full,
                    "\(scenario.name) at \(budget): tail neither covers the budget nor is complete"
                )
            }
        }
    }

    @Test("a history that fits inside the budget is returned whole")
    func shortHistoryIsReturnedWhole() throws {
        // Intent: the tail read is the identity when there is nothing to leave out, so a
        //   restored session of a few lines keeps every one of them.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("alpha\r\nbeta\r\ngamma".utf8))

        let tail = terminal.primaryHistoryTailText(maxLines: 4000, maxChars: 400_000)
        #expect(tail == terminal.primaryHistoryText)
        #expect(tail == "alpha\nbeta\ngamma")
    }

    @Test("reading the tail costs the budget rather than the retained history")
    func tailReadCostTracksTheBudgetNotTheCapacity() throws {
        // Intent: the bounded read's cost is set by the budget it is given, so growing the
        //   retained scrollback behind it does not make it slower.
        // Why it exists: `I3`. The checkpoint projected every pane's entire retained history
        //   and then kept only its last 4000 lines / 400K characters, which made a periodic
        //   checkpoint cost the 16 MiB scrollback capacity rather than what it stores. A tail
        //   read that still walked from the head would satisfy every equivalence test above
        //   and change none of that.
        // Scenario: a long-lived pane at a budget-full history, checkpointed every 600s.
        func tailCost(lines: Int) throws -> Double {
            var terminal = try #require(Terminal(columns: 200, rows: 50))
            let line = Array((String(repeating: "abcdefghij", count: 19) + " end\r\n").utf8)
            for _ in 0..<lines { terminal.feed(line) }
            let start = ContinuousClock.now
            _ = terminal.primaryHistoryTailText(maxLines: 200, maxChars: 20_000)
            let elapsed = (ContinuousClock.now - start).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }

        _ = try tailCost(lines: 200)  // warm up caches and any one-time growth
        let small = try tailCost(lines: 400)
        let large = try tailCost(lines: 6_400)

        // Sixteen times the history at the same budget. Under a bounded read the two costs are
        // the same walk, so their ratio sits near 1; under a full projection it tracks the 16x.
        // 4x sits between with room for scheduling noise on a loaded machine, and is still far
        // enough below 16 to fail a read that walks the whole history.
        #expect(
            large < small * 4,
            "tail read at a fixed budget: \(small)s over 400 lines, \(large)s over 6400 lines"
        )
    }
}
