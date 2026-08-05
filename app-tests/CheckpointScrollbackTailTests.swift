// Proves the checkpoint's bounded scrollback read is interchangeable with the unbounded one:
// truncating the tail `TerminalCore` hands over stores exactly what truncating the whole
// projection would have stored. This test lives here rather than beside either half because it
// is the only target that compiles both -- `TerminalCore`'s projection and `DanTermCore`'s
// `truncateScrollback` -- and the claim is about the two of them agreeing.
import Testing
import TerminalCore

@testable import DanTerm

/// Pins `I2`: the scrollback a checkpoint stores does not depend on how much history was read
/// to produce it. The full projection is the reference; there is no separate expected value.
struct CheckpointScrollbackTailTests {
    /// One terminal state, named so a failure says which shape broke rather than which index.
    private struct Scenario {
        let name: String
        let columns: Int
        let rows: Int
        let feed: String
    }

    /// The boundary conditions `I2` names, plus the ordinary over-budget case. A tail read is
    /// only interesting where the budget falls *inside* history, so the budgets below are small
    /// enough that these states straddle them.
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
            name: "blank lines run longer than the budget",
            columns: 8, rows: 4,
            feed: "kept\r\n" + String(repeating: "\r\n", count: 40) + "tail\r\n"
        ),
        Scenario(
            name: "trailing blank rows after the last content",
            columns: 8, rows: 4,
            feed: (1...60).map { "line \($0)\r\n" }.joined() + String(repeating: "\r\n", count: 20)
        ),
        Scenario(
            name: "history longer than the budget",
            columns: 8, rows: 4,
            feed: (1...200).map { "line \($0)\r\n" }.joined()
        ),
        Scenario(
            name: "wide glyphs across the tail boundary",
            columns: 8, rows: 4,
            feed: (1...40).map { "\u{754C}\u{754C}x\($0)\r\n" }.joined()
        ),
    ]

    private static let budgets: [ScrollbackRetention] = [
        // A zero line budget is "no line cut": counting breaks backward from the end never
        // reaches a zeroth one, so every line is kept and only the character bound applies.
        // The tail read has to read the same way round, and cannot conclude it is already done.
        ScrollbackRetention(maxLines: 0, maxChars: 400_000),
        ScrollbackRetention(maxLines: 1, maxChars: 1),
        ScrollbackRetention(maxLines: 4, maxChars: 20),
        ScrollbackRetention(maxLines: 10, maxChars: 120),
        ScrollbackRetention(maxLines: 25, maxChars: 60),
        .checkpoint,
    ]

    @Test("truncating the bounded tail read stores what truncating the full projection would")
    func boundedTailTruncatesIdenticallyToTheFullProjection() throws {
        // Intent: for any terminal state and any budget, `truncateScrollback` applied to the
        //   bounded tail read returns exactly what it returns applied to the whole projection --
        //   including the nil that means "nothing worth storing".
        // Why it exists: this is what lets the checkpoint stop projecting every pane's entire
        //   retained history. The bounded read is a pure optimization only while this holds, and
        //   the ways it can break are all invisible in isolation: a tail one line short, a
        //   leading blank run the truncation would have trimmed differently, a soft-wrapped run
        //   whose start the tail cuts into. Restore fidelity is the thing at stake, and it is
        //   not observable until a session comes back wrong.
        for scenario in Self.scenarios {
            var terminal = try #require(Terminal(columns: scenario.columns, rows: scenario.rows))
            terminal.feed(Array(scenario.feed.utf8))
            let full = terminal.primaryHistoryText

            for budget in Self.budgets {
                let tail = terminal.primaryHistoryTailText(
                    maxLines: budget.maxLines,
                    maxChars: budget.maxChars
                )
                let fromTail = truncateScrollback(tail, keeping: budget)
                let fromFull = truncateScrollback(full, keeping: budget)
                #expect(
                    fromTail == fromFull,
                    "\(scenario.name) at \(budget): bounded read stored different scrollback"
                )
            }
        }
    }
}
