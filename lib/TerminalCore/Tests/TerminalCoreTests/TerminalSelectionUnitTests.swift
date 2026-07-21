// Word and logical-line range queries used by local multi-click selection.
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
