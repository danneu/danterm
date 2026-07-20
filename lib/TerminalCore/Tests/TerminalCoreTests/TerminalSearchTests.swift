// Literal logical-history search semantics and navigation proofs.
import Testing

@testable import TerminalCore

/// Locks unit-aligned search to live terminal content without a stale match cache.
struct TerminalSearchTests {
    @Test("search folds ASCII only and requires complete non-ASCII units")
    func foldingAndUnicodeExactness() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("AbC ñ n\u{0303}".utf8))

        var result = terminal.beginSearch("aBc")
        #expect(result)
        #expect(terminal.activeSearchMatchRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 3)
        ))
        result = terminal.beginSearch("Ñ")
        #expect(result == false)
        result = terminal.beginSearch("n\u{0303}")
        #expect(result)
        result = terminal.beginSearch("n")
        #expect(result == false)
        result = terminal.beginSearch("ñ")
        #expect(result)
        result = terminal.beginSearch("")
        #expect(result == false)
        #expect(terminal.activeSearchMatchRange == nil)
    }

    @Test("newest-first navigation exposes overlaps and stops without moving")
    func navigationAndOverlaps() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("aaa aa".utf8))

        var moved = terminal.beginSearch("aa")
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 4)
        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 1)
        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 0)
        let oldest = terminal.activeSearchMatchRange
        moved = terminal.searchNext()
        #expect(moved == false)
        #expect(terminal.activeSearchMatchRange == oldest)
        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 1)
        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 4)
        let newest = terminal.activeSearchMatchRange
        moved = terminal.searchPrevious()
        #expect(moved == false)
        #expect(terminal.activeSearchMatchRange == newest)
    }

    @Test("search spans soft wraps and only requested hard boundaries")
    func wrapAndBoundaryMatching() throws {
        var soft = try #require(Terminal(columns: 4, rows: 3))
        soft.feed(Array("ABCDEF".utf8))
        var result = soft.beginSearch("CDEF")
        #expect(result)

        var padding = try #require(Terminal(columns: 4, rows: 2))
        padding.moveCursor(row: 0, column: 3)
        padding.feed(Array("XY".utf8))
        result = padding.beginSearch("  XY")
        #expect(result)

        var hard = try #require(Terminal(columns: 4, rows: 3))
        hard.feed(Array("AB\r\nCD".utf8))
        result = hard.beginSearch("BC")
        #expect(result == false)
        result = hard.beginSearch("B\nC")
        #expect(result)
        result = hard.beginSearch("\n")
        #expect(result)
        #expect(hard.activeSearchMatchRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 2),
            end: TerminalTextPosition(row: 1, column: 0)
        ))
    }

    @Test("navigation rescans changed nonintersecting rows")
    func navigationUsesLiveContent() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("hit\r\nhit\r\nhit".utf8))
        var moved = terminal.beginSearch("hit")
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.row == 2)

        terminal.feed(Array("\u{1B}[1;1Hzip".utf8))
        #expect(terminal.activeSearchMatchRange?.start.row == 2)
        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.row == 1)
        moved = terminal.searchNext()
        #expect(moved == false)
    }
}
