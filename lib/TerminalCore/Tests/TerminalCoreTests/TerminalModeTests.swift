// Proves ANSI and DEC terminal modes through public byte ingestion and grid projections.
import Testing

@testable import TerminalCore

/// Locks persistent mode state to its print, movement, and side-state effects.
struct TerminalModeTests {
    @Test("IRM inserts cluster starts while continuations keep their original insertion")
    func insertModeShiftsClusterStarts() throws {
        // Intent: prove IRM shifts once per newly printed cluster, preserves moved
        //   styles, and does not shift again for combining or width upgrades.
        // Why it exists: the print path has separate narrow, wide, append, and
        //   upgrade routes that must agree on what constitutes one insertion.
        // Scenario: a styled prompt is edited with ASCII, a wide glyph, and an
        //   emoji variation selector while insert mode is active.
        var narrow = try #require(Terminal(columns: 6, rows: 2))
        narrow.feed(Array("A\u{1B}[32mB\u{1B}[mCDE".utf8))
        narrow.moveCursor(row: 0, column: 1)
        narrow.feed(Array("\u{1B}[4hX\u{0301}".utf8))

        #expect(narrow.screenText == "AX\u{0301}BCDE\n      ")
        #expect(narrow.cell(row: 0, column: 2)?.style.foreground == .indexed(2))
        expectValidGrid(narrow)

        var wide = try #require(Terminal(columns: 6, rows: 1))
        wide.feed(Array("ABCDE".utf8))
        wide.moveCursor(row: 0, column: 2)
        wide.feed(Array("\u{1B}[4h\u{754C}".utf8))

        #expect(wide.screenText == "AB\u{754C}CD")
        #expect(wide.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .narrow, .wideHead, .wideTail, .narrow, .narrow,
        ])
        expectValidGrid(wide)

        var upgraded = try #require(Terminal(columns: 6, rows: 1))
        upgraded.feed(Array("ABCD".utf8))
        upgraded.moveCursor(row: 0, column: 1)
        upgraded.feed(Array("\u{1B}[4h\u{00A9}\u{FE0F}".utf8))

        #expect(upgraded.cell(row: 0, column: 1)?.scalars == ["\u{00A9}", "\u{FE0F}"])
        #expect(upgraded.cell(row: 0, column: 3)?.scalars == ["C"])
        #expect(upgraded.cell(row: 0, column: 4)?.scalars == ["D"])
        expectValidGrid(upgraded)
    }

    @Test("IRM resolves pending wrap before inserting on the continuation row")
    func insertModeWrapsThenShifts() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[4h".utf8))
        terminal.moveCursor(row: 1, column: 0)
        terminal.feed(Array("Z".utf8))
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed(Array("ABCDX".utf8))

        #expect(terminal.screenText == "ABCD\nXZ  ")
        #expect(terminal.geometry.rows[0].isSoftWrapped)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
        expectValidGrid(terminal)
    }

    @Test("IRM preserves a wide wrap gap while shifting the follower")
    func insertModePreservesWideWrapGap() throws {
        // Intent: a wide print that wraps in insert mode has the same projected gap as the
        //   ordinary print path, while existing content on the follower moves two columns.
        // Why it exists: the old stored spacer was retired by the insert shift that followed
        //   the wrap, so IRM projected one extra content blank before the wide glyph.
        // Scenario: the successor starts with two narrow cells before a wide glyph wraps from
        //   the row above and inserts ahead of them.
        var inserted = try #require(Terminal(columns: 4, rows: 2))
        inserted.moveCursor(row: 1, column: 0)
        inserted.feed(Array("AB".utf8))
        inserted.feed(Array("\u{1B}[4h\u{1B}[1;4H\u{754C}".utf8))

        var control = try #require(Terminal(columns: 4, rows: 2))
        control.moveCursor(row: 1, column: 2)
        control.feed(Array("AB".utf8))
        control.feed(Array("\u{1B}[1;4H\u{754C}".utf8))

        #expect(inserted.rowStructure[0].marginCellKind == .spacerHead)
        #expect(inserted.screenText == "    \n\u{754C}AB")
        #expect(inserted.screenText == control.screenText)
        #expect(inserted.cell(row: 1, column: 2)?.scalars.first == "A")
        #expect(inserted.cell(row: 1, column: 3)?.scalars.first == "B")
        expectValidGrid(inserted)
    }

    @Test("LNM gives LF VT and FF carriage-return behavior but leaves IND unchanged")
    func lineFeedNewLineMode() throws {
        for control in ["\n", "\u{000B}", "\u{000C}"] {
            var terminal = try #require(Terminal(columns: 5, rows: 3))
            terminal.moveCursor(row: 0, column: 3)
            terminal.feed(Array(("\u{1B}[20h" + control).utf8))
            #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 0, isPendingWrap: false))
        }

        var index = try #require(Terminal(columns: 5, rows: 3))
        index.moveCursor(row: 0, column: 3)
        index.feed(Array("\u{1B}[20h\u{1B}D".utf8))
        #expect(index.geometry.cursor == TerminalCursor(row: 1, column: 3, isPendingWrap: false))

        var reset = try #require(Terminal(columns: 5, rows: 3))
        reset.moveCursor(row: 0, column: 3)
        reset.feed(Array("\u{1B}[20h\u{1B}[20l\n".utf8))
        #expect(reset.geometry.cursor == TerminalCursor(row: 1, column: 3, isPendingWrap: false))
    }

    @Test("DECOM homes and confines vertical positioning to the active region")
    func originModePositionsWithinRegion() throws {
        // Intent: pin the complete origin-relative positioning surface and its
        //   interaction with a changing scroll region.
        // Why it exists: mixing absolute storage with region-relative commands
        //   otherwise risks inconsistent offsets and clamps between handlers.
        // Scenario: a full-screen application establishes rows 5 through 15,
        //   enables origin mode, and uses several equivalent cursor commands.
        var terminal = try #require(Terminal(columns: 8, rows: 20))
        terminal.feed(Array("\u{1B}[5;15r\u{1B}[?6h".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 4, column: 0, isPendingWrap: false))

        terminal.feed(Array("\u{1B}[3;3H".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 6, column: 2, isPendingWrap: false))
        terminal.feed(Array("\u{1B}[?6h".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 4, column: 0, isPendingWrap: false))
        terminal.feed(Array("\u{1B}[3;3H".utf8))
        terminal.feed(Array("\u{1B}[10A".utf8))
        #expect(terminal.geometry.cursor?.row == 4)
        terminal.feed(Array("\u{1B}[20B".utf8))
        #expect(terminal.geometry.cursor?.row == 14)
        terminal.feed(Array("\u{1B}[1d".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 4, column: 2, isPendingWrap: false))
        terminal.feed(Array("\u{1B}[20B".utf8))
        #expect(terminal.geometry.cursor?.row == 14)
        terminal.feed(Array("\u{1B}[99k".utf8))
        #expect(terminal.geometry.cursor?.row == 4)
        terminal.feed(Array("\u{1B}[99E".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 14, column: 0, isPendingWrap: false))
        terminal.feed(Array("\u{1B}[99F".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 4, column: 0, isPendingWrap: false))

        terminal.feed(Array("\u{1B}[8;12r".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 7, column: 0, isPendingWrap: false))
        terminal.feed(Array("\u{1B}[?6l".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        terminal.feed(Array("\u{1B}[?6h\u{1B}[r".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
    }

    @Test("DECOM keeps line motion and wrapped printing inside the active region")
    func originModeConfinement() throws {
        var terminal = try #require(Terminal(columns: 3, rows: 5))
        terminal.feed(Array("\u{1B}[2;4r\u{1B}[?6h\u{1B}[99BABCDEF".utf8))

        #expect(terminal.geometry.cursor?.row == 3)
        #expect(terminal.geometry.rows[0].cells.allSatisfy { $0.kind == .padding })
        #expect(terminal.geometry.rows[4].cells.allSatisfy { $0.kind == .padding })
        expectValidGrid(terminal)

        terminal.feed(Array("\u{1B}M".utf8))
        #expect(terminal.geometry.cursor.map { (1..<4).contains($0.row) } == true)
        expectValidGrid(terminal)
    }

    @Test("DECAWM off pins narrow and wide output at the right edge")
    func autoWrapModeControlsRightEdge() throws {
        // Intent: prove disabled autowrap never arms or consumes the phantom,
        //   including wide cluster starts and width upgrades at the last column.
        // Why it exists: all three print routes previously wrapped unconditionally.
        // Scenario: a terminal status line repeatedly overwrites its final cell
        //   while autowrap is disabled, then returns to ordinary wrapping.
        var narrow = try #require(Terminal(columns: 3, rows: 2))
        narrow.feed(Array("\u{1B}[?7lABCD".utf8))
        #expect(narrow.screenText == "ABD\n   ")
        #expect(narrow.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))

        var disarmed = try #require(Terminal(columns: 3, rows: 2))
        disarmed.feed(Array("ABC\u{1B}[?7lD".utf8))
        #expect(disarmed.screenText == "ABD\n   ")
        #expect(disarmed.geometry.cursor?.isPendingWrap == false)

        narrow.feed(Array("\u{1B}[?7hEF".utf8))
        #expect(narrow.screenText == "ABE\nF  ")
        #expect(narrow.geometry.rows[0].isSoftWrapped)

        var wide = try #require(Terminal(columns: 4, rows: 1))
        wide.feed(Array("\u{1B}[?7l\u{1B}[3G\u{754C}A".utf8))
        #expect(wide.geometry.rows[0].cells.map(\.kind) == [
            .padding, .padding, .padding, .narrow,
        ])
        #expect(wide.cell(row: 0, column: 3)?.scalars == ["A"])
        #expect(wide.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: false))
        #expect(wide.geometry.rows[0].isSoftWrapped == false)
        expectValidGrid(wide)

        var upgraded = try #require(Terminal(columns: 4, rows: 2))
        upgraded.moveCursor(row: 0, column: 3)
        upgraded.feed(Array("\u{1B}[?7l\u{00A9}\u{FE0F}".utf8))
        #expect(upgraded.cell(row: 0, column: 2)?.scalars == ["\u{00A9}", "\u{FE0F}"])
        #expect(upgraded.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: false))
        #expect(upgraded.geometry.rows[0].isSoftWrapped == false)
        expectValidGrid(upgraded)
    }

    @Test("mode dispatch applies recognized parameters and preserves wholly inert sequences")
    func modeDispatchNormalizationAndSideState() throws {
        // Intent: prove left-to-right recognized mode handling, the side-state
        //   gate, and strict no-op routing for unsupported intermediate forms.
        // Why it exists: private markers share CSI intermediate storage with
        //   true intermediates, so loose routing can mutate on malformed input.
        // Scenario: mode traffic arrives while the terminal holds both a pending
        //   wrap and an open grapheme attachment target.
        let inertSequences = [
            "\u{1B}[h",
            "\u{1B}[99h",
            "\u{1B}[?25;26$p",
            "\u{1B}[4!q",
            "\u{1B}[?6;7$p",
        ]
        for sequence in inertSequences {
            var terminal = try #require(Terminal(columns: 2, rows: 2))
            terminal.feed(Array("AB".utf8))
            let expected = terminal
            terminal.feed(Array(sequence.utf8))
            #expect(terminal == expected)
        }

        var pending = try #require(Terminal(columns: 2, rows: 2))
        pending.feed(Array("AB\u{1B}[4;99;20h".utf8))
        #expect(pending.geometry.cursor?.isPendingWrap == false)

        var cluster = try #require(Terminal(columns: 3, rows: 1))
        cluster.feed(Array("A\u{200D}\u{1B}[?7h\u{0301}".utf8))
        #expect(cluster.cell(row: 0, column: 0)?.scalars == ["A", "\u{200D}"])

        var oneChunk = try #require(Terminal(columns: 5, rows: 5))
        oneChunk.feed(Array("\u{1B}[2;4r\u{1B}[4;20h\u{1B}[?6;7h".utf8))
        var bytewise = try #require(Terminal(columns: 5, rows: 5))
        for byte in Array("\u{1B}[2;4r\u{1B}[4;20h\u{1B}[?6;7h".utf8) {
            bytewise.feed([byte])
        }
        #expect(oneChunk == bytewise)

        for sequence in ["\u{1B}[4h", "\u{1B}[20h", "\u{1B}[?6h", "\u{1B}[?7l"] {
            var changedMode = try #require(Terminal(columns: 5, rows: 5))
            changedMode.feed(Array(sequence.utf8))
            #expect(changedMode != Terminal(columns: 5, rows: 5))
        }
    }

    @Test("input modes follow DECSET and keypad application escape controls")
    func inputModeProjection() throws {
        var terminal = try #require(Terminal(columns: 5, rows: 3))
        #expect(terminal.inputModes == .default)

        terminal.feed(Array("\u{1B}[?1h\u{1B}[20h\u{1B}[?1004h\u{1B}[?2004h\u{1B}=".utf8))
        #expect(terminal.inputModes == TerminalInputModes(
            applicationCursorKeys: true,
            applicationKeypad: true,
            lineFeedNewLine: true,
            focusReporting: true,
            bracketedPaste: true
        ))

        terminal.feed(Array("\u{1B}[?1l\u{1B}[20l\u{1B}[?1004l\u{1B}[?2004l\u{1B}>".utf8))
        #expect(terminal.inputModes == .default)
    }
}
