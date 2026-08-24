// Cross-module proof that TerminalCore's one positional cut and DanTermCore's storage
// normalization preserve the legacy checkpoint result outside the two deliberate deviations.
import Testing
import TerminalCore

@testable import DanTerm

/// Compares the new single-owner pipeline with a test-local model of the removed downstream cut.
struct CheckpointScrollbackTailTests {
    private struct Scenario {
        let name: String
        let columns: Int
        let rows: Int
        let feed: String
    }

    private static let ordinaryScenarios: [Scenario] = [
        Scenario(name: "empty history", columns: 8, rows: 4, feed: ""),
        Scenario(name: "whitespace-only history", columns: 8, rows: 4, feed: "   \r\n \r\n  "),
        Scenario(
            name: "history shorter than the budget",
            columns: 8, rows: 4,
            feed: (1...6).map { "line \($0)\r\n" }.joined()
        ),
        Scenario(
            name: "hard boundaries and blank runs",
            columns: 8, rows: 4,
            feed: (1...30).map { $0 % 3 == 0 ? "\r\n" : "row \($0)\r\n" }.joined()
        ),
        Scenario(
            name: "history longer than the budget",
            columns: 8, rows: 4,
            feed: (1...200).map { "line \($0)\r\n" }.joined()
        ),
        Scenario(
            name: "wide and multi-scalar graphemes",
            columns: 8, rows: 4,
            feed: (1...40).map { "\u{754C}e\u{301}\u{1F469}\u{200D}\u{1F4BB}\($0)\r\n" }.joined()
        ),
        Scenario(
            name: "primary history while alternate screen is active",
            columns: 8, rows: 4,
            feed: "primary one\r\nprimary two\u{1B}[?1049halt-only"
        ),
    ]

    private static let budgets: [ScrollbackRetention] = [
        ScrollbackRetention(maxLines: 1, maxChars: 20),
        ScrollbackRetention(maxLines: 4, maxChars: 60),
        ScrollbackRetention(maxLines: 10, maxChars: 120),
        .checkpoint,
    ]

    private func legacyStoredTail(
        _ text: String,
        keeping retention: ScrollbackRetention
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        var newlineCount = 0
        var cutIndex: String.Index?
        for index in trimmed.indices.reversed() where trimmed[index] == "\n" {
            newlineCount += 1
            if newlineCount == retention.maxLines {
                cutIndex = trimmed.index(after: index)
                break
            }
        }
        var result = cutIndex.map { String(trimmed[$0...]) + "\n" } ?? trimmed + "\n"
        if result.count > retention.maxChars {
            let tail = result.suffix(retention.maxChars)
            if let newline = tail.firstIndex(of: "\n") {
                result = String(tail[tail.index(after: newline)...])
            } else {
                result = String(tail)
            }
        }
        return result
    }

    private func storedTail(
        from terminal: Terminal,
        keeping retention: ScrollbackRetention
    ) -> String? {
        let limits = retention.primaryHistoryLimits
        return normalizeCheckpointScrollback(terminal.primaryHistoryTailText(
            maxLines: limits.maxLines,
            maxChars: limits.maxChars
        ))
    }

    @Test("the single positional cut preserves ordinary stored history")
    func ordinaryHistoryMatchesTheLegacyPipeline() throws {
        for scenario in Self.ordinaryScenarios {
            var terminal = try #require(Terminal(columns: scenario.columns, rows: scenario.rows))
            terminal.feed(Array(scenario.feed.utf8))
            for budget in Self.budgets {
                #expect(
                    storedTail(from: terminal, keeping: budget)
                        == legacyStoredTail(terminal.primaryHistoryText, keeping: budget),
                    "\(scenario.name) at \(budget)"
                )
            }
        }
    }

    @Test("boundary whitespace consumes the positional line budget before storage trims it")
    func boundaryWhitespaceCanShortenTheStoredTail() throws {
        var terminal = try #require(Terminal(columns: 12, rows: 2))
        terminal.feed(Array("old\r\n   \r\nkept".utf8))
        let retention = ScrollbackRetention(maxLines: 2, maxChars: 100)

        #expect(legacyStoredTail(terminal.primaryHistoryText, keeping: retention) == "   \nkept\n")
        #expect(storedTail(from: terminal, keeping: retention) == "kept\n")
    }

    @Test("an over-budget line with no hard boundary produces no stored history")
    func unbrokenOverBudgetLineIsOmitted() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("abcdefghijklmnop".utf8))
        let retention = ScrollbackRetention(maxLines: 20, maxChars: 6)

        #expect(legacyStoredTail(terminal.primaryHistoryText, keeping: retention) == "")
        #expect(storedTail(from: terminal, keeping: retention) == nil)
    }

    @Test("the stored final newline fits inside the character limit")
    func finalNewlineIsReservedBeforeTheEngineRead() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("old\r\nkept".utf8))
        let retention = ScrollbackRetention(maxLines: 20, maxChars: 5)
        let stored = try #require(storedTail(from: terminal, keeping: retention))

        #expect(stored == "kept\n")
        #expect(stored.count == retention.maxChars)
    }
}
