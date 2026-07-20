// Verifies CSI REP replays the last complete grapheme without crossing a row boundary.
import Testing

@testable import TerminalCore

/// Pins REP memory, normalization, print-path integration, and edge capping.
struct TerminalRepeatTests {
    @Test("REP defaults zero to one and uses the current pen after cursor movement")
    func defaultCountMovementAndStyle() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("\u{1B}[31mA\u{0301}\u{1B}[3G\u{1B}[32m\u{1B}[b\u{1B}[0b".utf8))

        let green = TerminalStyle(foreground: .indexed(2))
        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["A", "\u{0301}"])
        #expect(terminal.cell(row: 0, column: 2)?.scalars == ["A", "\u{0301}"])
        #expect(terminal.cell(row: 0, column: 3)?.scalars == ["A", "\u{0301}"])
        #expect(terminal.cell(row: 0, column: 2)?.style == green)
        #expect(terminal.cell(row: 0, column: 3)?.style == green)
        expectValidGrid(terminal)
    }

    @Test("REP caps huge narrow and wide counts at the row end and arms ordinary wrap")
    func countCapAndWideClusters() throws {
        var narrow = try #require(Terminal(columns: 4, rows: 2))
        narrow.feed(Array("a\u{1B}[1000bb".utf8))

        #expect(narrow.screenText == "aaaa\nb   ")
        #expect(narrow.geometry.rows[0].isSoftWrapped)
        #expect(narrow.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))

        var wide = try #require(Terminal(columns: 6, rows: 2))
        wide.feed(Array("\u{754C}\u{1B}[1000bB".utf8))

        #expect(wide.screenText == "\u{754C}\u{754C}\u{754C}\nB     ")
        #expect(wide.geometry.rows[0].isSoftWrapped)
        #expect(wide.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))

        var upgraded = try #require(Terminal(columns: 6, rows: 1))
        upgraded.feed(Array("#\u{FE0F}\u{1B}[2b".utf8))
        #expect(upgraded.geometry.rows[0].cells.map(\.kind) == [
            .wideHead, .wideTail, .wideHead, .wideTail, .wideHead, .wideTail,
        ])
        #expect(upgraded.cell(row: 0, column: 4)?.scalars == ["#", "\u{FE0F}"])
        #expect(upgraded.geometry.cursor?.isPendingWrap == true)
        expectValidGrid(narrow)
        expectValidGrid(wide)
        expectValidGrid(upgraded)
    }

    @Test("REP does nothing when no cluster exists or pending wrap is already armed")
    func inertWithoutAvailableCluster() throws {
        var fresh = try #require(Terminal(columns: 3, rows: 2))
        let freshExpected = fresh
        fresh.feed(Array("\u{1B}[b".utf8))
        #expect(fresh == freshExpected)

        var pending = try #require(Terminal(columns: 2, rows: 2))
        pending.feed(Array("AB".utf8))
        let pendingExpected = pending
        pending.feed(Array("\u{1B}[1000b".utf8))
        #expect(pending == pendingExpected)

        var excessParameters = try #require(Terminal(columns: 4, rows: 1))
        excessParameters.feed(Array("A".utf8))
        let excessExpected = excessParameters
        excessParameters.feed(Array("\u{1B}[1;2b".utf8))
        #expect(excessParameters == excessExpected)
    }

    @Test("REP fills but never wraps while DECAWM is disabled")
    func autoWrapDisabled() throws {
        var narrow = try #require(Terminal(columns: 4, rows: 2))
        narrow.feed(Array("\u{1B}[?7la\u{1B}[1000b".utf8))
        #expect(narrow.screenText == "aaaa\n    ")
        #expect(narrow.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: false))

        var wide = try #require(Terminal(columns: 5, rows: 2))
        wide.feed(Array("\u{1B}[?7l\u{754C}\u{1B}[1000b".utf8))
        #expect(wide.screenText == "\u{754C}\u{754C} \n     ")
        #expect(wide.geometry.cursor == TerminalCursor(row: 0, column: 4, isPendingWrap: false))
        expectValidGrid(narrow)
        expectValidGrid(wide)
    }

    @Test("REP honors insert mode and leaves the final repeat open for combining")
    func insertModeAndOpenCluster() throws {
        var terminal = try #require(Terminal(columns: 7, rows: 1))
        terminal.feed(Array("ABCDE\u{1B}[2G\u{1B}[4hX\u{1B}[2b\u{0301}".utf8))

        #expect(terminal.screenText == "AXXX\u{0301}BCD")
        #expect(terminal.cell(row: 0, column: 3)?.scalars == ["X", "\u{0301}"])
        expectValidGrid(terminal)
    }

    @Test("last-cluster memory participates in terminal equality")
    func memoryAffectsEquality() throws {
        var remembered = try #require(Terminal(columns: 3, rows: 1))
        remembered.feed(Array("A\u{1B}[2J".utf8))
        var plain = try #require(Terminal(columns: 3, rows: 1))
        plain.moveCursor(row: 0, column: 1)

        #expect(remembered != plain)
    }
}
