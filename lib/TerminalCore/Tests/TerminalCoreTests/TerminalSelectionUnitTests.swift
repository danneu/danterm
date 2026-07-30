// Cluster and logical-line range queries used by local multi-click selection.
import Testing

@testable import TerminalCore

/// Pins selection units to the terminal's logical projection rather than visual rows.
struct TerminalSelectionUnitTests {
    @Test("cluster ranges use Ghostty's default boundary set")
    func clusterBoundarySet() throws {
        // Intent: every renderable default boundary scalar separates the
        //   non-boundary characters on either side.
        // Why it exists: the fixed set is the selection contract, so omitting
        //   one scalar silently changes what double-click selects.
        // Scenario: a user double-clicks beside each kind of shell punctuation
        //   in otherwise path-like text.
        let boundaries = Array(" '\"\u{2502}`|:;,()[]{}<>$")
        for boundary in boundaries {
            var terminal = try #require(Terminal(columns: 16, rows: 2))
            terminal.feed(Array("x/\(boundary).-_\u{00E9}".utf8))

            #expect(
                terminal.clusterRange(at: .init(row: 0, column: 1)) == range(0, 0, 0, 2),
                "boundary \(boundary) must stop the left run"
            )
            #expect(
                terminal.clusterRange(at: .init(row: 0, column: 3)) == range(0, 3, 0, 7),
                "boundary \(boundary) must stop the right run"
            )
        }
    }

    @Test("cluster ranges select paths and bare identifiers")
    func clusterSelectsPathsAndIdentifiers() throws {
        var terminal = try #require(Terminal(columns: 32, rows: 2))
        terminal.feed(Array("(/foo/bar.txt) bare_name".utf8))

        terminal.setSelection(terminal.clusterRange(at: .init(row: 0, column: 7)))
        #expect(terminal.selectedText == "/foo/bar.txt")
        terminal.setSelection(terminal.clusterRange(at: .init(row: 0, column: 20)))
        #expect(terminal.selectedText == "bare_name")
    }

    @Test("cluster and line ranges cross soft wraps but stop at hard lines")
    func logicalWrapRanges() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 4))
        terminal.feed(Array("abcdef\r\nXY".utf8))

        #expect(terminal.clusterRange(at: .init(row: 1, column: 1)) == range(0, 0, 1, 2))
        #expect(terminal.logicalLineRange(at: .init(row: 1, column: 0)) == range(0, 0, 1, 2))
        #expect(terminal.logicalLineRange(at: .init(row: 2, column: 1)) == range(2, 0, 2, 2))

        var empty = try #require(Terminal(columns: 4, rows: 3))
        empty.feed(Array("A\r\n\r\nB".utf8))
        #expect(empty.logicalLineRange(at: .init(row: 1, column: 2)) == range(1, 0, 1, 0))

        let wrappedLine = terminal.logicalLineRange(at: .init(row: 1, column: 0))
        terminal.setSelection(wrappedLine)
        #expect(terminal.selectedText == "abcdef")
    }

    @Test("heterogeneous adjacent boundary characters form one cluster")
    func heterogeneousBoundaryRun() throws {
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("a;,(b x (y".utf8))

        terminal.setSelection(terminal.clusterRange(at: .init(row: 0, column: 2)))
        #expect(terminal.selectedText == ";,(")
        terminal.setSelection(terminal.clusterRange(at: .init(row: 0, column: 7)))
        #expect(terminal.selectedText == " (")
    }

    @Test("cluster classification uses each cell's leading scalar")
    func leadingScalarClassification() throws {
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("x'\u{0301}y e\u{0301}.z".utf8))

        terminal.setSelection(terminal.clusterRange(at: .init(row: 0, column: 1)))
        #expect(terminal.selectedText == "'\u{0301}")
        terminal.setSelection(terminal.clusterRange(at: .init(row: 0, column: 4)))
        #expect(terminal.selectedText == "e\u{0301}.z")
    }

    @Test("cluster ranges fall back past retained content and clamp at stream edges")
    func fallbackAndClamping() throws {
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("ab   cd".utf8))

        #expect(terminal.clusterRange(at: .init(row: 0, column: 3)) == range(0, 2, 0, 5))
        #expect(terminal.clusterRange(at: .init(row: 0, column: 20)) == range(0, 5, 0, 7))

        var retained = try #require(Terminal(columns: 4, rows: 2))
        retained.feed(Array("old\r\nnew\r\nend".utf8))
        #expect(retained.clusterRange(at: .init(row: 0, column: 1)) == range(0, 0, 0, 3))
        #expect(retained.clusterRange(at: .init(row: -20, column: -20)) == range(0, 0, 0, 3))
        #expect(retained.clusterRange(at: .init(row: 200, column: 200)) == range(2, 0, 2, 3))
        #expect(retained.logicalLineRange(at: .init(row: 200, column: 200))
            == range(2, 0, 2, 3))
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
