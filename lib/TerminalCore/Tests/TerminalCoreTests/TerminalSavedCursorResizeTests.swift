// Proofs that the DECSC slot follows its text through every primary-screen resize.
//
// Separate from TerminalSavedCursorTests.swift, which owns what the slot stores and how DECRC
// re-applies it: this file only asks where the saved position lands after the grid is rebuilt.
import Testing

@testable import TerminalCore

/// Pins the saved cursor as a passenger through resize: the live cursor decides the layout, and
/// the saved slot is mapped through the displacement or the reflow that layout produced.
struct TerminalSavedCursorResizeTests {
    @Test("height-only resize preserves a pending wide-tail live cursor and saved slot")
    func heightResizePreservesPendingWideTail() throws {
        // Intent: keep both pending cursors on the margin tail of a wide cell when width is stable.
        // Why it exists: generic cursor normalization used to demote a wide tail to its head.
        // Scenario: DECAWM is off while a wide row is saved, the height grows, then DECRC and a
        //   later DECAWM enable reveal whether the saved last-column state survived.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[?7l\u{754C}\u{754C}\u{1B}7".utf8))
        terminal.resize(columns: 4, rows: 3)

        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: true))
        terminal.feed(Array("\r\u{1B}8".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: true))
        terminal.feed(Array("\u{1B}[?7hA".utf8))
        #expect(terminal.screenText == "\u{754C}\u{754C}\nA   \n    ")
        expectValidGrid(terminal)
    }

    /// Six rows of one character each, a marker saved on row 4, and the live cursor parked on the
    /// last row so no trailing-blank trim runs.
    private func markerColumnTerminal() throws -> Terminal {
        var terminal = try #require(Terminal(columns: 4, rows: 6))
        terminal.feed(Array("a\r\nb\r\nc\r\nd\r\nM\r\nZ".utf8))
        terminal.feed(Array("\u{1B}[5;1H\u{1B}7\u{1B}[6;2H".utf8))
        return terminal
    }

    @Test("a height shrink displaces the saved cursor by the same rows as the live cursor")
    func heightShrinkDisplacesSavedCursor() throws {
        // Intent: after rows move into history, DECRC lands on the cell DECSC saved.
        // Why it exists: the shrink subtracted the row delta from the live cursor only, so the
        //   saved slot was merely clamped into the new rectangle and pointed at other text.
        // Scenario: audit finding BUG-17 -- a shell holds a DECSC while the window is dragged
        //   shorter, and its restored prompt cursor must still be on the prompt.
        var terminal = try markerColumnTerminal()
        terminal.resize(columns: 4, rows: 3)
        terminal.feed(Array("\u{1B}8".utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 0, isPendingWrap: false))
        #expect(terminal.cell(row: 1, column: 0)?.scalars == ["M"])

        // The audit's own probe, which has no marker: the saved row 4 becomes row 1, not the
        // clamped row 2 that also happens to be where the live cursor sits.
        var probe = try #require(Terminal(columns: 4, rows: 6))
        probe.feed(Array("\u{1B}[5;2H\u{1B}7\u{1B}[6;1HZ".utf8))
        probe.resize(columns: 4, rows: 3)
        probe.feed(Array("\u{1B}8".utf8))
        #expect(probe.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
    }

    @Test("growing rows back pulls the saved cursor down with the history it restores")
    func heightGrowthCarriesSavedCursorWithPulledRows() throws {
        // Intent: a shrink followed by a matching growth returns the saved slot to its cell.
        // Why it exists: the growth branch pulls rows out of history and shifts the live cursor
        //   down by that count; a saved slot that skipped the shift would drift by the same rows.
        // Scenario: a window dragged shorter and then back to its original height.
        var terminal = try markerColumnTerminal()
        terminal.resize(columns: 4, rows: 3)
        terminal.resize(columns: 4, rows: 6)
        terminal.feed(Array("\u{1B}8".utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(row: 4, column: 0, isPendingWrap: false))
        #expect(terminal.cell(row: 4, column: 0)?.scalars == ["M"])
    }

    @Test("a saved row pushed out of the active area homes to row zero and keeps its column")
    func savedRowLeavingTheActiveAreaTakesTheLiveCursorPolicy() throws {
        // Intent: with no cell left on screen to follow, the saved slot takes the live cursor's
        //   off-screen policy -- row 0, column kept, then the usual clamp.
        // Why it exists: the fallback is unspecified by any standard, so it has to be pinned or
        //   it will drift toward whichever reference is read next.
        // Scenario: a shrink deep enough to push the saved row into scrollback.
        var terminal = try #require(Terminal(columns: 4, rows: 6))
        terminal.feed(Array("aaaa\r\nb\r\nc\r\nd\r\ne\r\nZ".utf8))
        terminal.feed(Array("\u{1B}[1;3H\u{1B}7\u{1B}[6;2H".utf8))
        terminal.resize(columns: 4, rows: 3)
        terminal.feed(Array("\u{1B}8".utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))
    }

    @Test("a width change reflows the saved cursor onto the same logical cell")
    func widthChangeReflowsSavedCursorOntoItsCell() throws {
        // Intent: DECRC lands on the saved character after the line is refolded at a new width.
        // Why it exists: the saved slot was not one of the anchors the reflow followed, so it
        //   kept a row and column whose text had moved.
        // Scenario: audit finding BUG-16 -- a save on the 'f' of a wrapped "abcdefgh".
        var widened = try #require(Terminal(columns: 4, rows: 3))
        widened.feed(Array("abcdefgh\u{1B}[2;2H\u{1B}7\u{1B}[3;1H".utf8))
        widened.resize(columns: 8, rows: 3)
        widened.feed(Array("\u{1B}8".utf8))
        #expect(widened.geometry.cursor == TerminalCursor(row: 0, column: 5, isPendingWrap: false))
        #expect(widened.cell(row: 0, column: 5)?.scalars == ["f"])

        var narrowed = try #require(Terminal(columns: 8, rows: 3))
        narrowed.feed(Array("abcdefgh\u{1B}[1;6H\u{1B}7\u{1B}[1;1H".utf8))
        narrowed.resize(columns: 4, rows: 3)
        narrowed.feed(Array("\u{1B}8".utf8))
        #expect(narrowed.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
        #expect(narrowed.cell(row: 1, column: 1)?.scalars == ["f"])
    }

    @Test("a saved pending wrap reflows as a line boundary and re-arms only at a new edge")
    func savedPendingWrapFollowsTheLineBoundary() throws {
        // Intent: a saved position one past the last cell stays one past it, and carries pending
        //   wrap only when the new width puts it back on the right edge.
        // Why it exists: pending wrap is how DanTerm spells "past the end of a full row"; a
        //   reflow that dropped the flag would turn the next printed scalar into an overwrite.
        // Scenario: a save taken with the wrap armed at the old right edge, widened then narrowed.
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("abcd\u{1B}7\u{1B}[3;1H".utf8))
        terminal.resize(columns: 8, rows: 3)
        terminal.feed(Array("\u{1B}8".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 4, isPendingWrap: false))

        terminal.feed(Array("\u{1B}[3;1H".utf8))
        terminal.resize(columns: 4, rows: 3)
        terminal.feed(Array("\u{1B}8".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: true))
    }

    @Test("a saved cursor past a line's content keeps its distance from the content end")
    func savedTrailingPaddingKeepsItsDistance() throws {
        // Intent: a save on a blank cell after the text is mapped by distance, not by column.
        // Why it exists: the trailing-padding rule is the live cursor's, and one rule for both
        //   cursors is the whole point of carrying the saved slot through the same code path.
        // Scenario: a save one blank past the end of a wrapped line, then a widening.
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("abcdef\u{1B}[2;4H\u{1B}7\u{1B}[3;1H".utf8))
        terminal.resize(columns: 8, rows: 3)
        terminal.feed(Array("\u{1B}8".utf8))

        #expect(terminal.cell(row: 0, column: 5)?.scalars == ["f"])
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 7, isPendingWrap: false))
    }

    @Test("a saved cursor on a blank row below the content keeps its offset below it")
    func savedBlankRowBelowContentKeepsItsOffset() throws {
        // Intent: with no text under it to follow, a saved row below the content is mapped by how
        //   far below the content end it sat.
        // Why it exists: the reflow only rebuilds rows down to the last content row, so a saved
        //   row below that has no reflow line and needs its own stated rule.
        // Scenario: a save two rows under the last written row, then a widening that halves the
        //   rows the content occupies.
        var terminal = try #require(Terminal(columns: 4, rows: 6))
        terminal.feed(Array("abcdefgh\u{1B}[4;2H\u{1B}7\u{1B}[2;1H".utf8))
        terminal.resize(columns: 8, rows: 6)
        terminal.feed(Array("\u{1B}8".utf8))

        #expect(terminal.cell(row: 0, column: 7)?.scalars == ["h"])
        #expect(terminal.geometry.cursor == TerminalCursor(row: 2, column: 1, isPendingWrap: false))
    }

    @Test("the primary's saved cursor is carried while the alternate screen is live")
    func alternateScreenResizeCarriesThePrimarySavedCursor() throws {
        // Intent: the shell's implicitly saved cursor comes back onto its own text after a resize
        //   that happened entirely while a full-screen program was drawing.
        // Why it exists: this is the user-visible path for both audit findings -- CSI ?1049h, a
        //   window resize, CSI ?1049l -- and it must not depend on which screen was live.
        // Scenario: vim entered from a shell prompt, the window dragged shorter and narrower,
        //   then `:q`.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("abcdefgMijklmno".utf8))
        terminal.feed(Array("\u{1B}[1;8H\u{1B}[?1049h".utf8))
        terminal.feed(Array("\u{1B}[2;3H\u{1B}7ALT".utf8))
        terminal.resize(columns: 5, rows: 3)
        terminal.feed(Array("\u{1B}8".utf8))
        // The alternate's own slot keeps its coordinates: its rows do not reflow.
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 2, isPendingWrap: false))

        terminal.feed(Array("\u{1B}[?1049l".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))
        #expect(terminal.cell(row: 0, column: 2)?.scalars == ["M"])
    }

    @Test("the saved cursor stays screen-relative when content scrolls without a resize")
    func savedCursorDoesNotFollowScrolledText() throws {
        // Intent: DECSC saves a screen position, so ordinary scrolling moves the text out from
        //   under it and DECRC restores the coordinate, not the character.
        // Why it exists: it would be easy to make the slot a durable content anchor while fixing
        //   the resize paths, and every resize test here would still pass if that happened.
        // Scenario: a marker saved on row 1, then one line of scrolling.
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("a\r\nM\u{1B}[2;1H\u{1B}7".utf8))
        terminal.feed(Array("\u{1B}[3;1H\nQ\u{1B}8".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["M"])
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 0, isPendingWrap: false))
    }
}
