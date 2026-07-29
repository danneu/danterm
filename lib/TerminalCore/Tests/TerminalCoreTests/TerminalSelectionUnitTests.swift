// Word, cluster, and logical-line range queries used by local multi-click selection.
import Testing

@testable import TerminalCore

/// Pins selection units to the terminal's logical projection rather than visual rows.
struct TerminalSelectionUnitTests {
    @Test("word ranges use whitespace word and symbol classes")
    func wordClasses() throws {
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("abc_12  \u{00E9}\u{754C}!!".utf8))

        #expect(terminal.wordRange(at: .init(row: 0, column: 2)) == range(0, 0, 0, 6))
        #expect(terminal.wordRange(at: .init(row: 0, column: 6)) == range(0, 6, 0, 8))
        #expect(terminal.wordRange(at: .init(row: 0, column: 8)) == range(0, 8, 0, 11))
        #expect(terminal.wordRange(at: .init(row: 0, column: 11)) == range(0, 11, 0, 13))
    }

    @Test("word and line ranges cross soft wraps but stop at hard lines")
    func logicalWrapRanges() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 4))
        terminal.feed(Array("abcdef\r\nXY".utf8))

        #expect(terminal.wordRange(at: .init(row: 1, column: 1)) == range(0, 0, 1, 2))
        #expect(terminal.logicalLineRange(at: .init(row: 1, column: 0)) == range(0, 0, 1, 2))
        #expect(terminal.logicalLineRange(at: .init(row: 2, column: 1)) == range(2, 0, 2, 2))

        var empty = try #require(Terminal(columns: 4, rows: 3))
        empty.feed(Array("A\r\n\r\nB".utf8))
        #expect(empty.logicalLineRange(at: .init(row: 1, column: 2)) == range(1, 0, 1, 0))

        let wrappedLine = terminal.logicalLineRange(at: .init(row: 1, column: 0))
        terminal.setSelection(wrappedLine)
        #expect(terminal.selectedText == "abcdef")
    }

    @Test("cluster ranges select a whitespace-delimited token whole")
    func clusterSelectsPunctuatedToken() throws {
        // Intent: a cluster query inside a punctuated path returns the path alone,
        //   excluding a leading output glyph and the space that follows it.
        // Why it exists: pins the whole point of the granularity -- word selection
        //   stops at `/`, `-`, and `.`, so the path had no one-gesture target.
        // Scenario: triple-clicking a path in Claude Code output, which prefixes
        //   each line with a non-ASCII glyph and a space.
        var terminal = try #require(Terminal(columns: 40, rows: 2))
        terminal.feed(Array("\u{23FA} docs/research/13-live-app.md".utf8))

        let cluster = terminal.clusterRange(at: .init(row: 0, column: 10))
        terminal.setSelection(cluster)
        #expect(terminal.selectedText == "docs/research/13-live-app.md")
    }

    @Test("cluster ranges cross soft wraps but stop at hard lines")
    func clusterWrapRanges() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 4))
        terminal.feed(Array("ab.def\r\nXY".utf8))

        #expect(terminal.clusterRange(at: .init(row: 1, column: 1)) == range(0, 0, 1, 2))
        terminal.setSelection(terminal.clusterRange(at: .init(row: 1, column: 1)))
        #expect(terminal.selectedText == "ab.def")
    }

    @Test("cluster ranges select whitespace runs and fall back past retained content")
    func clusterWhitespaceRegions() throws {
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("ab   cd".utf8))

        #expect(terminal.clusterRange(at: .init(row: 0, column: 3)) == range(0, 2, 0, 5))
        #expect(terminal.clusterRange(at: .init(row: 0, column: 20)) == range(0, 5, 0, 7))
    }

    @Test("selection-unit positions address scrollback and clamp at stream edges")
    func scrollbackAndClamping() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("old\r\nnew\r\nend".utf8))

        #expect(terminal.wordRange(at: .init(row: 0, column: 1)) == range(0, 0, 0, 3))
        #expect(terminal.wordRange(at: .init(row: -20, column: -20)) == range(0, 0, 0, 3))
        #expect(terminal.wordRange(at: .init(row: 200, column: 200)) == range(2, 0, 2, 3))
        #expect(terminal.logicalLineRange(at: .init(row: 200, column: 200)) == range(2, 0, 2, 3))
    }

    private func range(
        _ startRow: Int,
        _ startColumn: Int,
        _ endRow: Int,
        _ endColumn: Int
    ) -> TerminalTextRange {
        TerminalTextRange(
            start: .init(row: startRow, column: startColumn),
            end: .init(row: endRow, column: endColumn)
        )
    }
}
