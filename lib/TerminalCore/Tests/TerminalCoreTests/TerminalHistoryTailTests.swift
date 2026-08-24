// Proves the bounded positional tail projection of primary history, including its exact hard-
// boundary cuts and its cost independent of retained history depth.
import Testing

@testable import TerminalCore

/// Pins `primaryHistoryTailText(maxLines:maxChars:)` against the canonical full projection.
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
            name: "wide combining and multi-scalar graphemes",
            columns: 8, rows: 4,
            feed: (1...40).map {
                "\u{754C}e\u{301}\u{1F469}\u{200D}\u{1F4BB}\($0)\r\n"
            }.joined()
        ),
        Scenario(
            name: "primary history while alternate screen is active",
            columns: 8, rows: 4,
            feed: "primary one\r\nprimary two\u{1B}[?1049halt-only"
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

    private func referenceTail(_ text: String, maxLines: Int, maxChars: Int) -> String {
        guard maxLines > 0, maxChars > 0 else { return "" }
        var lineStart = text.startIndex
        var breaks = 0
        for index in text.indices.reversed() where text[index] == "\n" {
            breaks += 1
            if breaks == maxLines {
                lineStart = text.index(after: index)
                break
            }
        }
        var characterStart = text.startIndex
        if text.count > maxChars {
            let candidate = text.index(text.endIndex, offsetBy: -maxChars)
            if candidate == text.startIndex || text[text.index(before: candidate)] == "\n" {
                characterStart = candidate
            } else if let boundary = text[candidate...].firstIndex(of: "\n") {
                characterStart = text.index(after: boundary)
            } else {
                characterStart = text.endIndex
            }
        }
        return String(text[max(lineStart, characterStart)...])
    }

    @Test("the character cut never returns a partial oldest logical line")
    func characterCutRequiresAHardBoundary() throws {
        // Intent: a character window that starts inside one unbroken logical line returns no
        //   history because there is no canonical boundary at which to begin replay.
        // Why it exists: persistence must not synthesize a newline and turn a torn line into an
        //   apparently complete recovery record.
        // Scenario: one soft-wrapped line is longer than the five-grapheme positional budget.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("abcdefghijklmnop".utf8))

        #expect(terminal.primaryHistoryTailText(maxLines: 20, maxChars: 5) == "")
    }

    @Test("boundary whitespace consumes the positional budget")
    func boundaryWhitespaceConsumesBudget() throws {
        // Intent: the engine counts the source projection as-is and leaves whitespace policy to
        //   persistence, even when the oldest retained line is whitespace-only.
        // Why it exists: trimming before the engine cut would keep two policy owners and preserve
        //   the duplicate decision this API removes.
        // Scenario: the two-line budget lands on a blank line before the final content line.
        var terminal = try #require(Terminal(columns: 12, rows: 2))
        terminal.feed(Array("old\r\n   \r\nkept".utf8))

        #expect(terminal.primaryHistoryTailText(maxLines: 2, maxChars: 100) == "   \nkept")
    }

    @Test("the bounded tail equals a positional cut of the canonical projection")
    func tailMatchesTheFullProjectionReference() throws {
        // Intent: the bounded walk returns the exact line-and-grapheme tail of the canonical
        //   projection, including hard and soft boundaries and trailing layout blanks.
        // Why it exists: starting the projection mid-stream must not create a second text model.
        for scenario in Self.scenarios {
            let terminal = try makeTerminal(scenario)
            let full = terminal.primaryHistoryText
            for budget in Self.budgets {
                let tail = terminal.primaryHistoryTailText(
                    maxLines: budget.maxLines,
                    maxChars: budget.maxChars
                )
                #expect(
                    tail == referenceTail(
                        full,
                        maxLines: budget.maxLines,
                        maxChars: budget.maxChars
                    ),
                    "\(scenario.name) at \(budget): bounded and canonical cuts differ"
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
