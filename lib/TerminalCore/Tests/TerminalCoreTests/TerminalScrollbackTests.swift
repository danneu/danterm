// Proves retained primary rows and their shared logical-text projection.
import Testing

@testable import TerminalCore

/// Locks scroll-off retention and full-history inspection to exact public row state.
struct TerminalScrollbackTests {
    @Test("scroll-off retains exact cells and soft-wrap identity in oldest-first order")
    func scrollbackRetention() throws {
        // Intent: prove the viewport's single scroll-off path moves whole rows
        //   into retained history without flattening their continuation state.
        // Why it exists: dropping the wrap flag or written-space cell identity
        //   makes later projection and resize reflow change logical content.
        // Scenario: a wrapped line followed by a written-space line scrolls
        //   completely above a two-row primary viewport.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("ABCDE\r\n \r\n\r\n".utf8))

        #expect(terminal.scrollbackRowCount == 3)
        let first = try #require(terminal.scrollbackRow(at: 0))
        #expect(first.isSoftWrapped)
        #expect(first.cells.map(\.kind) == [.narrow, .narrow, .narrow, .narrow])
        #expect(first.cells.map(\.scalars) == [["A"], ["B"], ["C"], ["D"]])

        let second = try #require(terminal.scrollbackRow(at: 1))
        #expect(second.isSoftWrapped == false)
        #expect(second.cells.map(\.kind) == [.narrow, .padding, .padding, .padding])
        #expect(second.cells[0].scalars == ["E"])

        let third = try #require(terminal.scrollbackRow(at: 2))
        #expect(third.isSoftWrapped == false)
        #expect(third.cells.map(\.kind) == [.narrow, .padding, .padding, .padding])
        #expect(third.cells[0].scalars == [" "])
        #expect(terminal.scrollbackRow(at: -1) == nil)
        #expect(terminal.scrollbackRow(at: 3) == nil)
    }

    @Test("clearing a viewport wide cell repairs its retained spacer row")
    func crossBoundarySpacerRepair() throws {
        // Intent: preserve wide-cell atomicity when the scrollback/viewport
        //   boundary falls between a deferred spacer and its wide head.
        // Why it exists: the pre-scrollback pair cleanup only inspected the
        //   preceding viewport row, leaving an orphaned spacer in history.
        // Scenario: a right-edge wide glyph scrolls until its spacer is the
        //   newest retained row, then the visible glyph is overwritten.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.moveCursor(row: 1, column: 3)
        terminal.feed(Array("\u{754C}".utf8))
        terminal.feed([0x0A])

        let before = try #require(terminal.scrollbackRow(at: 1))
        #expect(before.cells[3].kind == .spacerHead)
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed(Array("X".utf8))

        let after = try #require(terminal.scrollbackRow(at: 1))
        #expect(after.cells[3].kind == .padding)
        #expect(terminal.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .padding, .padding, .padding,
        ])
    }

    @Test("full-history text joins soft wraps and preserves interior padding")
    func fullHistorySoftWrapProjection() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[4GA".utf8))
        terminal.feed(Array("B".utf8))

        #expect(terminal.fullHistoryText == "   AB")
    }

    @Test("full-history text omits a structural spacer before a wrapped wide cell")
    func fullHistorySpacerProjection() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[4G\u{754C}".utf8))

        #expect(terminal.fullHistoryText == "   \u{754C}")
    }

    @Test("full-history text preserves every scalar in an emoji cluster")
    func fullHistoryEmojiProjection() throws {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array(family.utf8))

        #expect(terminal.fullHistoryText == family)
    }

    @Test("full-history text preserves written trailing spaces without padding or final newline")
    func fullHistoryWrittenSpaces() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("A  ".utf8))

        #expect(terminal.fullHistoryText == "A  ")
    }

    @Test("full-history text preserves empty hard lines but omits trailing blank rows")
    func fullHistoryEmptyLines() throws {
        var terminal = try #require(Terminal(columns: 3, rows: 2))
        terminal.feed([0x0A, 0x0A])
        terminal.feed(Array("A".utf8))

        #expect(terminal.scrollbackRowCount == 1)
        #expect(terminal.fullHistoryText == "\n\nA")
    }
}
