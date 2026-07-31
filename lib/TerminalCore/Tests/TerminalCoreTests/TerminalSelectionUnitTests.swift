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

    @Test("line ranges trim whitespace at both outer edges of the logical line")
    func lineRangeTrimsOuterWhitespace() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("  foo bar       ".utf8))

        let trimmed = terminal.trimmedLogicalLineRange(at: .init(row: 0, column: 12))
        #expect(trimmed == range(0, 2, 0, 9))
        terminal.setSelection(trimmed)
        #expect(terminal.selectedText == "foo bar")
    }

    @Test("line trimming removes whole Unicode-whitespace units")
    func lineRangeTrimsUnicodeWhitespaceUnits() throws {
        // Intent: trimming classifies a projected unit by its leading scalar's
        //   Unicode whitespace property and never splits a wide cell.
        // Why it exists: the ASCII set {NUL, space, tab} would leave a no-break or
        //   ideographic space selected, and a per-column trim could start the range
        //   on a wide cell's tail column.
        // Scenario: a line padded with CJK-era spacing whose content starts on a
        //   double-width glyph.
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("\u{00A0}\u{3000} \u{0301}\u{6F22}z \u{3000}\u{00A0}".utf8))

        let trimmed = terminal.trimmedLogicalLineRange(at: .init(row: 0, column: 0))
        #expect(trimmed == range(0, 4, 0, 7))
        terminal.setSelection(trimmed)
        #expect(terminal.selectedText == "\u{6F22}z")
    }

    @Test("line trimming spans a soft-wrapped line and keeps whitespace inside it")
    func lineRangeTrimsAcrossSoftWrap() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 4))
        terminal.feed(Array("  ab  cd  \r\nX".utf8))

        let wrapped = terminal.trimmedLogicalLineRange(at: .init(row: 1, column: 0))
        #expect(wrapped == range(0, 2, 1, 4))
        terminal.setSelection(wrapped)
        #expect(terminal.selectedText == "ab  cd")

        let afterHardLine = terminal.trimmedLogicalLineRange(at: .init(row: 3, column: 2))
        #expect(afterHardLine == range(3, 0, 3, 1))
        terminal.setSelection(afterHardLine)
        #expect(terminal.selectedText == "X")
    }

    @Test("whitespace-only and unwritten lines trim to empty ranges at their line start")
    func lineRangeEmptyForBlankLines() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("A\r\n   \r\nB".utf8))

        #expect(terminal.trimmedLogicalLineRange(at: .init(row: 1, column: 2)) == range(1, 0, 1, 0))
        #expect(terminal.trimmedLogicalLineRange(at: .init(row: 3, column: 5)) == range(3, 0, 3, 0))
    }

    @Test("link detection keeps scanning the untrimmed logical line")
    func detectedLinksIgnoreLineTrimming() throws {
        // Intent: a URL on a line whose first row holds only whitespace still
        //   resolves, because detection scans `logicalLineRange`, not the trimmed unit.
        // Why it exists: trimming inside `logicalLineRange` would have moved the row
        //   window link detection searches, silently dropping links.
        // Scenario: an indented wrapped line whose visible URL begins after the wrap.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("        https://a.example/x".utf8))

        #expect(terminal.logicalLineRange(at: .init(row: 0, column: 0)) == range(0, 0, 3, 3))
        #expect(terminal.trimmedLogicalLineRange(at: .init(row: 0, column: 0)) == range(1, 0, 3, 3))
        let link = try #require(terminal.activatableLink(at: .init(row: 1, column: 2)))
        #expect(link.hyperlink.uri == "https://a.example/x")
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
