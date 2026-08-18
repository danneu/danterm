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

    @Test("reading the tail walks the budget's rows rather than the retained history's")
    func tailReadCostTracksTheBudgetNotTheCapacity() throws {
        // Intent: the bounded read's cost is set by the budget it is given, so growing the
        //   retained scrollback behind it does not make it walk further.
        // Why it exists: `I3`. The checkpoint projected every pane's entire retained history
        //   and then kept only its last 4000 lines / 400K characters, which made a periodic
        //   checkpoint cost the 16 MiB scrollback capacity rather than what it stores -- tens
        //   of seconds per pane. A tail read that still walked from the head would return the
        //   correct suffix and satisfy every equivalence test above, so nothing else here
        //   would catch it.
        // Scenario: a long-lived pane at a budget-full history, checkpointed every 600s.
        //
        // Rows walked, not seconds elapsed. The rows *are* the cost, they are exactly what the
        // contract bounds, and they are deterministic -- so this needs none of the warm-up,
        // interleaving and best-of-N sampling a wall-clock ratio needs to survive the parallel
        // `just test` pool, and it still cannot be satisfied by an implementation that projects
        // everything and slices the suffix. The timing form this replaced is kept as an
        // env-gated probe (`TerminalHistoryTailCostProbe`) for the wall clock itself.
        let budget = (maxLines: 200, maxChars: 20_000)
        let smallTerminal = try historyProjectionTerminal(lines: 400)
        let largeTerminal = try historyProjectionTerminal(lines: 3_200)

        let smallTailRows = Instrument.projectionRow.measure {
            _ = smallTerminal.primaryHistoryTailText(
                maxLines: budget.maxLines, maxChars: budget.maxChars
            )
        }
        let largeTailRows = Instrument.projectionRow.measure {
            _ = largeTerminal.primaryHistoryTailText(
                maxLines: budget.maxLines, maxChars: budget.maxChars
            )
        }

        // The whole-projection reads over the same two terminals, which is what this counter
        // has to separate the tail read from. It is also the control that keeps the equality
        // above from passing vacuously: a counter wired to nothing, or to a path neither read
        // takes, reports equal row counts for the bounded read *and* for the unbounded one.
        let smallFullRows = Instrument.projectionRow.measure { _ = smallTerminal.primaryHistoryText }
        let largeFullRows = Instrument.projectionRow.measure { _ = largeTerminal.primaryHistoryText }
        #expect(
            largeFullRows > smallFullRows * 4,
            """
            control: the unbounded projection must track history size, or this counter is not \
            measuring the walk -- \(smallFullRows) rows over 400 lines, \(largeFullRows) over 3200
            """
        )

        // Eight times the history, at the same budget, walking the same rows. Exact equality
        // rather than a ratio: the tail read's start row is computed from the budget and the
        // stream end, so nothing about the depth behind it may enter the count.
        #expect(
            smallTailRows == largeTailRows,
            """
            tail read at a fixed budget: \(smallTailRows) rows over 400 lines, \
            \(largeTailRows) rows over 3200 lines
            """
        )

        // And the absolute bound the caller is promised, not merely that the two agree -- two
        // reads that both walked everything would satisfy the equality above. `maxLines` rows
        // plus the live screen plus one is the first reach `primaryHistoryTailText` tries, and
        // `2x` that is the ceiling its own doc gives for the `rowBudget *= 2` retry ("retrying
        // costs at most twice the text finally read"). This corpus covers on the first pass and
        // measures exactly `reach`, so the assertion has a full doubling of headroom.
        let reach = budget.maxLines + 4 + 1
        #expect(
            largeTailRows <= reach * 2,
            "tail read walked \(largeTailRows) rows for a \(budget.maxLines)-line budget"
        )
    }
}
