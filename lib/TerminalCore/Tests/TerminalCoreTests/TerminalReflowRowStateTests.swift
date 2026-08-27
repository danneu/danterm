// Proofs that a width change carries every fact of a row that has a visible effect -- its text,
// its fill style, the cell the cursor is on, its continuation mark -- and that the height-shrink
// trim reads line structure the way every other reader does (Wave 7 of the 2026-08-26 audit).
//
// The cursor and fill halves live together because one rule produces both: the fold's bound
// on a hard-ended row is the row's visible extent, extended by the blanks before the live
// cursor, and the cursor is the boundary after them.
import Testing

@testable import TerminalCore

struct TerminalReflowRowStateTests {
    private func background(_ terminal: Terminal, row: Int, column: Int) -> TerminalColor? {
        terminal.cell(row: row, column: column)?.style.background
    }

    // MARK: - The cursor keeps its distance from the text (I1, I2)

    @Test("a cursor parked past a row's text keeps sitting past that text after a narrow")
    func parkedCursorKeepsItsDistanceThroughANarrow() throws {
        // Intent: printing after a narrow never overwrites a cell that held committed text.
        // Why it exists: the trailing-padding anchor clamped `contentEnd + distance` into the
        //   last column, and when the refolded line filled its row the clamp parked the cursor
        //   on the last character with no wrap armed.
        // Scenario: audit REFLOW-1 -- 6x3 `abcd` CSI 6G, narrow to 4, print `X` gave `abcX`.
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("abcd\u{1B}[6G".utf8))
        terminal.resize(columns: 4, rows: 3)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))

        terminal.feed(Array("X".utf8))

        #expect(terminal.screenText == "abcd\n X  \n    ")

        var wider = try #require(Terminal(columns: 8, rows: 3))
        wider.feed(Array("abcd\u{1B}[7G".utf8))
        wider.resize(columns: 4, rows: 3)
        wider.feed(Array("X".utf8))
        #expect(wider.screenText == "abcd\n  X \n    ")
    }

    @Test("a cursor on an all-padding continuation row stays past that line's text on widening")
    func cursorOnBlankContinuationRowStaysPastTheText() throws {
        // Intent: a cursor on a wrapped line's blank last row stays after that line's text.
        // Why it exists: the all-padding anchor resolved to the line's *first* packed row, so
        //   the cursor landed on committed text.
        // Scenario: audit REFLOW-3 -- 4x4 `abcdefg`, blank row 1, cursor (1,2), widen to 6.
        var terminal = try #require(Terminal(columns: 4, rows: 4))
        terminal.feed(Array("abcdefg".utf8))
        terminal.feed(Array("\u{1B}[2;1H\u{1B}[2K\u{1B}[2;3H".utf8))
        terminal.resize(columns: 6, rows: 4)

        // Two blanks past `abcd` fill the six-column row, so "after them" is spelled as the
        // last column plus a pending wrap -- the same position as the start of a fresh row,
        // in the one spelling DanTerm has for it, without opening the row.
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 5, isPendingWrap: true))
        terminal.feed(Array("X".utf8))
        let lines = terminal.screenText.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "abcd  ")
        #expect(lines[1] == "X     ")
    }

    @Test("a saved cursor in trailing blanks never lands on committed text after a narrow")
    func savedCursorInTrailingBlanksDoesNotOverwriteText() throws {
        // Intent: DECRC then print after a narrow that fills the line does not eat a character.
        // Why it exists: the saved slot went through the same clamp as the live cursor.
        // Scenario: DECSC one blank past `abcd`, narrow so the line fills, DECRC, print.
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("abcd\u{1B}[6G\u{1B}7\u{1B}[3;1H".utf8))
        terminal.resize(columns: 4, rows: 3)
        terminal.feed(Array("\u{1B}8X".utf8))

        #expect(terminal.fullHistoryText.hasPrefix("abcd"))
        #expect(terminal.cell(row: 0, column: 3)?.scalars == ["d"])
    }

    @Test("the saved slot never creates a row: a full viewport keeps the live cursor's text")
    func savedSlotPastTheFoldBoundDoesNotDisplaceTheLiveCursor() throws {
        // Intent: only the live cursor extends a line; the saved slot is a passenger.
        // Why it exists: if the saved slot folded its blanks too, a narrow could create a row
        //   the viewport cannot hold and push the live cursor's row into history (AR3).
        // Scenario: 6x3, `A`/`B`/`C` on rows 0-2, DECSC at (2,5), live cursor on `A`, narrow to 3.
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("A\r\nB\r\nC\u{1B}[3;6H\u{1B}7\u{1B}[1;1H".utf8))
        terminal.resize(columns: 3, rows: 3)

        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["A"])

        // The saved slot sat past the fold bound, so it lands at its line's end (AR3).
        terminal.feed(Array("\u{1B}8X".utf8))
        #expect(terminal.screenText == "A  \nB  \nCX ")
    }

    // MARK: - Text projections ignore carried padding (I5)

    @Test("carried cursor cells are padding to copy and the text projections")
    func carriedCursorCellsStayTextBlank() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("abcd\u{1B}[6G".utf8))
        let text = terminal.fullHistoryText
        terminal.resize(columns: 4, rows: 3)

        #expect(terminal.fullHistoryText == text)
        #expect(terminal.cell(row: 1, column: 0)?.kind == .padding)
        #expect(terminal.cell(row: 1, column: 1)?.kind == .padding)

        var filled = try #require(Terminal(columns: 6, rows: 3))
        filled.feed(Array("\u{1B}[H\u{1B}[41mAB\u{1B}[K\u{1B}[m".utf8))
        filled.resize(columns: 8, rows: 3)
        #expect(filled.fullHistoryText == "AB")
        #expect(filled.screenText.split(separator: "\n", omittingEmptySubsequences: false)[0] == "AB      ")
    }

    // MARK: - Paint survives (I4, I6)

    @Test("a width change keeps every background-erased blank, on both screens")
    func widthChangePreservesPaint() throws {
        // Intent: a widen and a narrow both keep the paint a background erase left.
        // Why it exists: the live refold rebuilt every blank at the default style, so a width
        //   change erased a painted primary screen while the alternate screen kept its paint.
        // Scenario: audit REFLOW-2's two probes and their alternate-screen control.
        let red = TerminalColor.indexed(1)
        var painted = try #require(Terminal(columns: 4, rows: 3))
        painted.feed(Array("\u{1B}[41m\u{1B}[2J\u{1B}[H".utf8))
        painted.resize(columns: 5, rows: 3)
        for row in 0..<3 {
            for column in 0..<5 {
                #expect(background(painted, row: row, column: column) == red, "(\(row), \(column))")
            }
        }
        painted.resize(columns: 3, rows: 3)
        for row in 0..<3 {
            for column in 0..<3 {
                #expect(background(painted, row: row, column: column) == red, "(\(row), \(column))")
            }
        }

        var filled = try #require(Terminal(columns: 6, rows: 3))
        filled.feed(Array("\u{1B}[H\u{1B}[41mAB\u{1B}[K".utf8))
        filled.resize(columns: 8, rows: 3)
        for column in 0..<8 {
            #expect(background(filled, row: 0, column: column) == red, "column \(column)")
        }

        var alternate = try #require(Terminal(columns: 4, rows: 3))
        alternate.feed(Array("\u{1B}[?1049h\u{1B}[41m\u{1B}[2J\u{1B}[H".utf8))
        alternate.resize(columns: 5, rows: 3)
        for column in 0..<4 {
            #expect(background(alternate, row: 0, column: column) == red, "column \(column)")
        }
    }

    @Test("a differently styled gap between text and fill keeps its own style at every width")
    func gapBetweenTextAndFillKeepsItsStyle() throws {
        // Scenario: `A`, two default blanks, then a red fill to the margin; widen, then narrow.
        let red = TerminalColor.indexed(1)
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("A\u{1B}[4G\u{1B}[41m\u{1B}[K\u{1B}[m\u{1B}[1;1H".utf8))

        terminal.resize(columns: 8, rows: 2)
        #expect(background(terminal, row: 0, column: 1) == .default)
        #expect(background(terminal, row: 0, column: 2) == .default)
        for column in 3..<8 {
            #expect(background(terminal, row: 0, column: column) == red, "column \(column)")
        }

        terminal.resize(columns: 4, rows: 2)
        #expect(background(terminal, row: 0, column: 1) == .default)
        #expect(background(terminal, row: 0, column: 2) == .default)
        #expect(background(terminal, row: 0, column: 3) == red)
    }

    @Test("a cursor parked in a filled row's fill lands on a fill-styled cell after a narrow")
    func parkedCursorInFillLandsOnFill() throws {
        let red = TerminalColor.indexed(1)
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("\u{1B}[41mAB\u{1B}[K\u{1B}[m\u{1B}[5G".utf8))
        terminal.resize(columns: 3, rows: 3)

        let cursor = try #require(terminal.geometry.cursor)
        #expect(cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
        #expect(background(terminal, row: cursor.row, column: cursor.column) == red)
        #expect(terminal.cell(row: cursor.row, column: cursor.column)?.kind == .padding)
    }

    @Test("a styled blank that does not reach the margin survives resize and history")
    func isolatedStyledBlanksAreRetainedAsCells() throws {
        // Intent: the extent rule is lossless -- a styled blank with a default margin is a cell.
        // Why it exists: admission stopped at the last text cell, so `A` + two red blanks + a
        //   default margin lost the red on scroll-off, and the refold lost it on any resize.
        // Scenario: `A`, two red ECH blanks at columns 3-4 of six, default margin.
        let red = TerminalColor.indexed(1)
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("A\u{1B}[3G\u{1B}[41m\u{1B}[2X\u{1B}[m\u{1B}[1;1H".utf8))
        #expect(background(terminal, row: 0, column: 2) == red)
        #expect(background(terminal, row: 0, column: 3) == red)
        #expect(background(terminal, row: 0, column: 4) == .default)

        terminal.resize(columns: 8, rows: 2)
        #expect(background(terminal, row: 0, column: 2) == red)
        #expect(background(terminal, row: 0, column: 3) == red)
        #expect(background(terminal, row: 0, column: 4) == .default)

        terminal.resize(columns: 5, rows: 2)
        #expect(background(terminal, row: 0, column: 2) == red)
        #expect(background(terminal, row: 0, column: 3) == red)
        #expect(background(terminal, row: 0, column: 4) == .default)

        // Into history and back: the row scrolls off the top, then a taller grid pulls it in.
        terminal.feed(Array("\u{1B}[2;1H\n\n".utf8))
        #expect(terminal.scrollbackRowCount == 2)
        terminal.resize(columns: 5, rows: 4)
        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["A"])
        #expect(background(terminal, row: 0, column: 2) == red)
        #expect(background(terminal, row: 0, column: 3) == red)
        #expect(background(terminal, row: 0, column: 4) == .default)
    }

    @Test("a painted screen whose top line wraps displaces paint into history rather than dropping it")
    func paintedRowsAreDisplacedNotDropped() throws {
        // Intent: a row with a visible effect is never dropped by a width change (I6); only
        //   default-blank rows below the last visible effect are trimmed first.
        // Scenario: 4x3 fully red, `abcd` on row 0, cursor on row 0, narrow to 2.
        let red = TerminalColor.indexed(1)
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("\u{1B}[41m\u{1B}[2J\u{1B}[Habcd\u{1B}[m\u{1B}[1;1H".utf8))
        terminal.resize(columns: 2, rows: 3)

        #expect(terminal.scrollbackRowCount == 1)
        #expect(terminal.screenText == "cd\n  \n  ")
        for row in 0..<3 {
            for column in 0..<2 {
                #expect(background(terminal, row: row, column: column) == red, "(\(row), \(column))")
            }
        }
        terminal.resize(columns: 4, rows: 3)
        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.screenText == "abcd\n    \n    ")

        var blanks = try #require(Terminal(columns: 4, rows: 3))
        blanks.feed(Array("abcd\u{1B}[1;1H".utf8))
        blanks.resize(columns: 2, rows: 3)
        #expect(blanks.scrollbackRowCount == 0)
        #expect(blanks.screenText == "ab\ncd\n  ")
    }

    // MARK: - One continuation rule (I7)

    @Test("a soft-wrapped line's continuation marks are the same live, after a resize, and from history")
    func continuationMarkIsStructural() throws {
        // Intent: `.continuation` means "a non-head display row of a marked line", whatever
        //   the head's mark, and whichever path produced the row.
        // Why it exists: the printer stamped by shell context (prompt/input only) while the
        //   packer and the store stamped every marked line, so an `.output`-headed wrapped
        //   line changed its marks when it rematerialized.
        // Scenario: OSC 133;C on a row, `abcdef` wraps at 4, then a resize and a scroll-off.
        var terminal = try #require(Terminal(columns: 4, rows: 4))
        terminal.feed(Array("\u{1B}]133;C\u{7}abcdef".utf8))
        let live = terminal.semanticPromptRowsForTesting.prefix(2).map(\.stamp)
        #expect(live == [.output, .continuation])

        terminal.resize(columns: 3, rows: 4)
        #expect(terminal.semanticPromptRowsForTesting.prefix(2).map(\.stamp) == live)

        terminal.feed(Array("\u{1B}[4;1H\n\n\n".utf8))
        #expect(terminal.scrollbackRowCount == 3)
        terminal.resize(columns: 3, rows: 7)
        #expect(terminal.semanticPromptRowsForTesting.prefix(2).map(\.stamp) == live)

        // A hard newline inside a prompt/input region marks a new logical line's head, which is
        // a different fact and stays.
        var input = try #require(Terminal(columns: 6, rows: 3))
        input.feed(Array("\u{1B}]133;A;redraw=0\u{7}$ \u{1B}]133;B\u{7}ab\r\ncd".utf8))
        #expect(input.semanticPromptRowsForTesting.prefix(2).map(\.stamp) == [.prompt, .continuation])
        input.resize(columns: 8, rows: 3)
        #expect(input.semanticPromptRowsForTesting.prefix(2).map(\.stamp) == [.prompt, .continuation])
    }

    // MARK: - One line-structure reader (I8)

    @Test("a height shrink trims a text-blank last row even under a stale wrap claim")
    func heightShrinkTrimsBlankRowWithStaleClaim() throws {
        // Intent: trailing text-blank rows are dropped before any content row is displaced.
        // Why it exists: the trim read the raw wrap claim, so a blank last row that still
        //   claimed to wrap blocked it and the shrink displaced `XY` into scrollback.
        // Scenario: audit REFLOW-7 -- a scroll region that excludes the last row strands a
        //   claim there, EL 2 blanks it, then the grid shrinks by one row.
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("XY\u{1B}[1;2r\u{1B}[3;1HABCDE\u{1B}[2K\u{1B}[r\u{1B}[1;1H".utf8))
        #expect(terminal.geometry.rows[2].isSoftWrapped == true)

        terminal.resize(columns: 4, rows: 2)

        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.screenText == "XY  \n    ")

        var synchronized = try #require(Terminal(columns: 4, rows: 3))
        synchronized.feed(Array("XY\u{1B}[3;1H\u{1B}]133;S;mark=none;wrap=stale\u{7}\u{1B}[1;1H".utf8))
        synchronized.resize(columns: 4, rows: 2)
        #expect(synchronized.scrollbackRowCount == 0)
        #expect(synchronized.screenText == "XY  \n    ")
    }
}
