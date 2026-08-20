// Proves CSI line, display, and character erasure through public byte ingestion, plus DECALN
// where it shares the display erases' history-seam handling.
import Testing

@testable import TerminalCore

/// Locks erase dispatch to padding-producing, wide-safe default-mode semantics.
struct CSIEraseTests {
    @Test(
        "EL modes erase their inclusive regions and widen across wide cells",
        arguments: [
            EraseLineFixture(
                sequence: "\u{1B}[K",
                cursorColumn: 2,
                expectedKinds: [.narrow, .padding, .padding, .padding, .padding, .padding]
            ),
            EraseLineFixture(
                sequence: "\u{1B}[1K",
                cursorColumn: 1,
                expectedKinds: [.padding, .padding, .padding, .narrow, .narrow, .padding]
            ),
            EraseLineFixture(
                sequence: "\u{1B}[2K",
                cursorColumn: 3,
                expectedKinds: [.padding, .padding, .padding, .padding, .padding, .padding]
            ),
        ]
    )
    func eraseLineRegions(fixture: EraseLineFixture) throws {
        // Intent: prove each EL mode erases its inclusive region without
        //   leaving either half of an intersected wide cell behind.
        // Why it exists: both the cursor boundary and the erase endpoint can
        //   bisect the storage pair used for a double-width character.
        // Scenario: terminal output erases right, left, or the whole line
        //   while the cursor sits on one half of a Chinese glyph.
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("A\u{754C}BC".utf8))
        terminal.moveCursor(row: 0, column: fixture.cursorColumn)
        let expectedCursor = terminal.geometry.cursor

        terminal.feed(Array(fixture.sequence.utf8))

        #expect(terminal.geometry.rows[0].cells.map(\.kind) == fixture.expectedKinds)
        #expect(terminal.geometry.cursor == expectedCursor)
        expectValidGrid(terminal)
    }

    @Test("EL right resets soft wrap while left and complete preserve it")
    func eraseLineWrapAsymmetry() throws {
        // Intent: pin that only EL 0 resets the row's soft wrap; EL 1 and EL 2
        //   blank cells but leave the line structure alone.
        // Why it exists: EL is a cell-content operation, not a line-structure one,
        //   and the references agree. Verified 2026-08-05: xterm drops the flag
        //   only in util.c#ClearRight ("with the right part cleared, we can't be
        //   wrapping"); Ghostty's Terminal.zig#eraseLine explicitly declined to
        //   reset it for EL complete, to match xterm; kitty and foot touch no wrap
        //   state in any EL mode. tmux severs on EL 2 (confirmed in a live PTY via
        //   capture-pane -J joining) and is the one reference we do not follow.
        // Scenario: a soft-wrapped shell line is partially or fully erased, e.g. a
        //   redraw that blanks a mid-line row before refilling it.
        for (sequence, expectedWrap) in [
            ("\u{1B}[0K", false),
            ("\u{1B}[1K", true),
            ("\u{1B}[2K", true),
        ] {
            var terminal = try #require(Terminal(columns: 4, rows: 2))
            terminal.feed(Array("ABCDE".utf8))
            terminal.moveCursor(row: 0, column: 2)

            terminal.feed(Array(sequence.utf8))

            #expect(terminal.geometry.rows[0].isSoftWrapped == expectedWrap)
            #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))
            expectValidGrid(terminal)
        }
    }

    @Test(
        "ED modes erase the display regions and reset only fully cleared row wraps",
        arguments: [0, 1, 2]
    )
    func eraseDisplayRegions(mode: Int) throws {
        // Intent: prove ED composes its cursor-row EL behavior with complete
        //   row clearing above or below, preserving the cursor.
        // Why it exists: partial display erasure has asymmetric row-wrap
        //   effects and can otherwise clear one row too many or too few.
        // Scenario: a three-row wrapped viewport receives ED below, above,
        //   or complete while the cursor is in the middle row.
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("ABCDEFGHIJKL".utf8))
        terminal.moveCursor(row: 1, column: 2)
        let expectedCursor = terminal.geometry.cursor

        terminal.feed(Array("\u{1B}[\(mode)J".utf8))

        let kinds = terminal.geometry.rows.map { $0.cells.map(\.kind) }
        switch mode {
        case 0:
            #expect(kinds[0] == Array(repeating: .narrow, count: 4))
            #expect(kinds[1] == [.narrow, .narrow, .padding, .padding])
            #expect(kinds[2] == Array(repeating: .padding, count: 4))
            #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [true, false, false])
        case 1:
            #expect(kinds[0] == Array(repeating: .padding, count: 4))
            #expect(kinds[1] == [.padding, .padding, .padding, .narrow])
            #expect(kinds[2] == Array(repeating: .narrow, count: 4))
            #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [false, true, false])
        default:
            #expect(kinds.allSatisfy { $0 == Array(repeating: .padding, count: 4) })
            #expect(terminal.geometry.rows.allSatisfy { $0.isSoftWrapped == false })
        }
        #expect(terminal.geometry.cursor == expectedCursor)
        expectValidGrid(terminal)
    }

    @Test("home then ED complete clears the viewport without moving the home cursor")
    func canonicalClearScreenPair() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("ABCDEFGHI".utf8))

        terminal.feed(Array("\u{1B}[H\u{1B}[2J".utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        #expect(terminal.geometry.rows.allSatisfy { row in
            row.cells.allSatisfy { $0.kind == .padding } && row.isSoftWrapped == false
        })
        expectValidGrid(terminal)
    }

    @Test("ED 3 clears only scrollback and pending motion state")
    func eraseDisplayScrollback() throws {
        // Intent: clear retained history without changing viewport, cursor,
        //   pen, or active region, while ending deferred wrap and attachment.
        // Why it exists: ED 3 shares dispatch with active-grid erase modes but
        //   has a distinct target and the slice-wide side-state policy.
        // Scenario: a shell clears its transcript while a bounded TUI remains
        //   displayed and continues scrolling inside the same margins.
        var terminal = try #require(Terminal(columns: 3, rows: 3))
        terminal.feed(Array("ABCDEFGHIJ".utf8))
        terminal.feed(Array("\u{1B}[2;3r\u{1B}[3;2H\u{1B}[1;31;44m".utf8))
        let expectedGeometry = terminal.geometry
        let expectedStyle = terminal.currentStyle
        #expect(terminal.scrollbackRowCount == 1)

        terminal.feed(Array("\u{1B}[3J".utf8))

        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.geometry == expectedGeometry)
        #expect(terminal.currentStyle == expectedStyle)
        #expect(terminal.geometry.cursor?.isPendingWrap == false)
        terminal.feed(Array("\u{1B}[S".utf8))
        #expect(terminal.scrollbackRowCount == 0)
        expectValidGrid(terminal)

        let once = terminal
        terminal.feed(Array("\u{1B}[3J".utf8))
        #expect(terminal == once)

        terminal.moveCursor(row: 0, column: 0)
        terminal.feed(Array("Z".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["Z"])
        expectValidGrid(terminal)

        var combining = try #require(Terminal(columns: 3, rows: 1))
        combining.feed(Array("A\u{1B}[3J\u{0301}".utf8))
        #expect(combining.cell(row: 0, column: 0)?.scalars == ["A"])
    }

    @Test("ECH defaults and zero to one, clamps, widens, and supports two columns")
    func eraseCharactersMatrix() throws {
        // Intent: cover ECH count defaulting, clamping, and wide-pair boundary
        //   expansion on normal and minimal grid widths.
        // Why it exists: a one-cell erase can start on a wide tail, while a
        //   large count must clamp without overrunning the row.
        // Scenario: an application blanks characters under the cursor in a
        //   line containing Chinese text.
        for sequence in ["\u{1B}[X", "\u{1B}[0X"] {
            var terminal = try #require(Terminal(columns: 6, rows: 1))
            terminal.feed(Array("A\u{754C}BC".utf8))
            terminal.moveCursor(row: 0, column: 2)
            let expectedCursor = terminal.geometry.cursor

            terminal.feed(Array(sequence.utf8))

            #expect(terminal.geometry.rows[0].cells.map(\.kind) == [
                .narrow, .padding, .padding, .narrow, .narrow, .padding,
            ])
            #expect(terminal.geometry.cursor == expectedCursor)
            expectValidGrid(terminal)
        }

        var clamped = try #require(Terminal(columns: 6, rows: 1))
        clamped.feed(Array("ABCDEF".utf8))
        clamped.moveCursor(row: 0, column: 3)
        clamped.feed(Array("\u{1B}[99X".utf8))
        #expect(clamped.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .narrow, .narrow, .padding, .padding, .padding,
        ])
        expectValidGrid(clamped)

        var minimal = try #require(Terminal(columns: 2, rows: 1))
        minimal.feed(Array("\u{754C}".utf8))
        minimal.moveCursor(row: 0, column: 0)
        minimal.feed(Array("\u{1B}[X".utf8))
        #expect(minimal.geometry.rows[0].cells.map(\.kind) == [.padding, .padding])
        expectValidGrid(minimal)
    }

    @Test("ECH resets a mid-row wrap and clears the preceding spacer head")
    func eraseCharactersWrapAndSpacerCleanup() throws {
        // Intent: prove ECH resets logical wrap even for a short mid-row
        //   range and repairs the spacer linking a wrapped wide character.
        // Why it exists: range erasure alone does not describe either row
        //   metadata or the previous row's trailing spacer representation.
        // Scenario: a wrapped line is blanked in place, including a wide
        //   glyph that wrapped from a spacer at the prior right margin.
        var midRow = try #require(Terminal(columns: 4, rows: 2))
        midRow.feed(Array("ABCDE".utf8))
        midRow.moveCursor(row: 0, column: 1)
        midRow.feed(Array("\u{1B}[X".utf8))
        #expect(midRow.geometry.rows[0].isSoftWrapped == false)
        expectValidGrid(midRow)

        var spacer = try #require(Terminal(columns: 4, rows: 2))
        spacer.moveCursor(row: 0, column: 3)
        spacer.feed(Array("\u{754C}".utf8))
        #expect(spacer.geometry.rows[0].cells[3].kind == .spacerHead)
        spacer.moveCursor(row: 1, column: 0)
        spacer.feed(Array("\u{1B}[X".utf8))
        #expect(spacer.geometry.rows[0].cells[3].kind == .padding)
        expectValidGrid(spacer)
    }

    @Test("active-grid erases clear pending wrap and combining attachment")
    func activeEraseClearsPendingState() throws {
        // Intent: prove interpreted EL, ED, and ECH dispatches clear deferred
        //   wrap, and a mutating erase blocks later combining attachment.
        // Why it exists: visible cell assertions cannot observe stale parser-
        //   adjacent state that changes the next scalar's behavior.
        // Scenario: terminal output erases while a last-column wrap or a
        //   previous printable attachment target is pending.
        for sequence in ["\u{1B}[K", "\u{1B}[J", "\u{1B}[X"] {
            var terminal = try #require(Terminal(columns: 2, rows: 2))
            terminal.feed(Array("AB".utf8))
            terminal.feed(Array(sequence.utf8))
            #expect(terminal.geometry.cursor?.isPendingWrap == false)
            expectValidGrid(terminal)
        }

        var combining = try #require(Terminal(columns: 4, rows: 1))
        combining.feed(Array("A\u{1B}[X\u{0301}".utf8))
        #expect(combining.cell(row: 0, column: 0)?.scalars == ["A"])
        expectValidGrid(combining)
    }

    @Test("erasure produces padding rather than written spaces")
    func eraseProducesPadding() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("A B".utf8))
        terminal.moveCursor(row: 0, column: 1)
        let expectedCursor = terminal.geometry.cursor

        terminal.feed(Array("\u{1B}[X".utf8))

        #expect(terminal.screenText == "A B ")
        #expect(terminal.geometry.rows[0].cells[1].kind == .padding)
        #expect(terminal.geometry.cursor == expectedCursor)
        expectValidGrid(terminal)
    }

    @Test(
        "invalid erase dispatches leave terminal state bit-identical",
        arguments: [
            "\u{1B}[1;2K",
            "\u{1B}[3K",
            "\u{1B}[1;2J",
            "\u{1B}[4J",
            "\u{1B}[22J",
            "\u{1B}[1;2X",
            "\u{1B}[?K",
            "\u{1B}[1:2K",
        ]
    )
    func invalidEraseIsNoOp(sequence: String) throws {
        // Intent: enforce erase arity, mode, intermediate, and colon gates
        //   before any grid or pending-state mutation occurs.
        // Why it exists: malformed terminal output must not partially clear
        //   a line or consume deferred wrap state.
        // Scenario: a full last column has pending wrap when an unsupported
        //   erase-shaped CSI dispatch arrives.
        var terminal = try #require(Terminal(columns: 2, rows: 2))
        terminal.feed(Array("AB".utf8))
        let expected = terminal

        terminal.feed(Array(sequence.utf8))

        #expect(terminal == expected)
    }

    @Test("an erase starting at column 1 still repairs the previous row's spacer head")
    func eraseAtColumnOneClearsPrecedingSpacer() throws {
        // Intent: the preceding row's trailing spacer head is repaired when the
        //   erased range begins at column 1, not only when it begins at column 0.
        // Why it exists: the repair is reachable for any erased range whose lower
        //   bound is at most 1, and that boundary is easy to narrow accidentally
        //   when the per-cell repair call is hoisted out of the erase loop.
        // Scenario: a wide glyph wrapped off the right margin, leaving a spacer
        //   head behind it, and the application blanks the wrapped row from its
        //   second column.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.moveCursor(row: 0, column: 3)
        terminal.feed(Array("\u{754C}".utf8))
        #expect(terminal.geometry.rows[0].cells[3].kind == .spacerHead)

        terminal.moveCursor(row: 1, column: 1)
        terminal.feed(Array("\u{1B}[X".utf8))

        #expect(terminal.geometry.rows[0].cells[3].kind == .padding)
        expectValidGrid(terminal)
    }

    @Test("erasing the first viewport row repairs a spacer head left in scrollback")
    func eraseAtTopRowClearsScrollbackSpacer() throws {
        // Intent: the spacer repair reaches the last scrollback row when the
        //   erased row is the top of the viewport.
        // Why it exists: this is the only branch of the repair that leaves the
        //   viewport, so a hoisted or range-based erase can silently drop it while
        //   every in-viewport case keeps passing.
        // Scenario: a wide glyph wrapped at the right margin, the row carrying its
        //   spacer head then scrolled into scrollback, and the application blanks
        //   the wrapped character now sitting at the top of the viewport.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.moveCursor(row: 0, column: 3)
        terminal.feed(Array("\u{754C}".utf8))
        terminal.moveCursor(row: 1, column: 0)
        terminal.feed(Array("\n".utf8))
        #expect(terminal.scrollbackRowCount == 1)

        terminal.moveCursor(row: 0, column: 0)
        terminal.feed(Array("\u{1B}[X".utf8))

        #expect(terminal.scrollbackRowCount == terminal.independentScrollbackRowRecount)
        expectValidGrid(terminal)
    }

    @Test("an erase that blanks the whole of live row 0 ends history's open logical line")
    func wholeRowZeroErasesSeverTheScrollbackWrapClaim() throws {
        // Intent: exactly the erases that blank the whole of live row 0 -- ED 2, ED 1 with the
        //   cursor below row 0, ED 0 from home, DECALN -- close history's open tail record; the
        //   erases that leave any of row 0's cells standing, and EL 2, leave it open.
        // Why it exists: the open bit is history's claim that the last retained row continues
        //   into live row 0. Once that row is blanked in full, the cells the claim names are
        //   gone, so keeping it asserts a continuation that no longer exists. The converse cases
        //   are the hazard in the other direction: with columns 0..<cursor.column of row 0 still
        //   standing, those cells genuinely continue the retained line, and severing would split
        //   one real logical line in two.
        // Scenario: a wrapped line straddles the history/live seam -- its head is in scrollback,
        //   its remainder on live row 0 -- and an application issues each erase in turn.
        let severing = ["\u{1B}[2J", "\u{1B}[2;1H\u{1B}[1J", "\u{1B}[H\u{1B}[J", "\u{1B}#8"]
        for sequence in severing {
            var terminal = try makeSeamTerminal()
            #expect(terminal.scrollbackRow(at: 2)?.isSoftWrapped == true)
            terminal.feed(Array(sequence.utf8))
            #expect(terminal.scrollbackRow(at: 2)?.isSoftWrapped == false, "\(sequence)")
            expectValidGrid(terminal)
        }

        // ED 1 with the cursor on row 0 blanks only columns 0...cursor.column; ED 0 with the
        // cursor past column 0 blanks only columns cursor.column..<columnCount; EL 2 is a
        // rewrite-in-place idiom and is not an erase-family wrap-flag trigger at all today.
        let preserving = ["\u{1B}[1;4H\u{1B}[1J", "\u{1B}[1;4H\u{1B}[J", "\u{1B}[H\u{1B}[2K"]
        for sequence in preserving {
            var terminal = try makeSeamTerminal()
            terminal.feed(Array(sequence.utf8))
            #expect(terminal.scrollbackRow(at: 2)?.isSoftWrapped == true, "\(sequence)")
            expectValidGrid(terminal)
        }
    }

    @Test("output printed after ED 2 starts a new history line rather than joining the cleared one")
    func eraseDisplayCompleteStopsHistoryJoiningAcrossTheClear() throws {
        var terminal = try makeSeamTerminal()

        terminal.feed(Array("\u{1B}[2J\u{1B}[H".utf8))
        terminal.feed(Array("NEW\r\nX\r\nY".utf8))

        let lines = terminal.primaryHistoryText.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.contains("NEW"))
        #expect(terminal.primaryHistoryText.contains("wrappingNEW") == false)
    }

    @Test("a width change after ED 2 does not pull pre-clear text back onto the cleared screen")
    func eraseDisplayCompleteSurvivesTheOpenTailPullBack() throws {
        // Intent: after ED 2 clears the screen, widening the pane leaves the screen clear.
        // Why it exists: a width change re-establishes the open tail record's display-row
        //   boundary by handing its trailing partial row back to the live refold (`research/31/D3`
        //   Decision 4). That pull-back keys off the record's open bit alone, so an erase that
        //   left the bit set could resurrect the text it had just cleared -- history cells
        //   moving back onto the visible screen, which no reference terminal can even express.
        // Scenario: a wrapped line straddles the history/live seam, the user clears the screen,
        //   and then drags the window wider.
        var terminal = try makeSeamTerminal()

        terminal.feed(Array("\u{1B}[2J".utf8))
        terminal.resize(columns: 10, rows: 2)

        #expect(terminal.viewportText.contains("wrapping") == false)
        expectValidGrid(terminal)
    }

    @Test("DECALN homes the cursor and drops origin mode and the scroll region")
    func alignmentFillResetsPositioningState() throws {
        // Intent: after DECALN the cursor is home with no pending wrap, origin mode is off,
        //   and the scroll margins span the whole screen again.
        // Why it exists: DanTerm's DECALN is a known-state reset plus fill, per DEC STD 070.
        //   A fill that leaves the old margins and origin mode standing means the very next
        //   absolute CUP -- the reason a program issues DECALN at all -- lands somewhere else.
        // Scenario: vttest's margin page sets a region, turns origin mode on, fills the screen
        //   with DECALN, and then positions absolutely.
        var terminal = try #require(Terminal(columns: 4, rows: 4))
        terminal.feed(Array("\u{1B}[2;3r\u{1B}[?6h".utf8))

        terminal.feed(Array("\u{1B}#8".utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))

        // With origin mode still on and the old region standing, this CUP would clamp to row 2.
        terminal.feed(Array("\u{1B}[4;1H".utf8))
        #expect(terminal.geometry.cursor?.row == 3)

        // With the old region standing, scroll-down would leave row 0 untouched.
        terminal.feed(Array("\u{1B}[T".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.scalars.description == "")
        #expect(terminal.cell(row: 3, column: 0)?.scalars.description == "E")
        expectValidGrid(terminal)
    }

    @Test("DECALN reduces the pen to its colours and fills in that pen")
    func alignmentFillKeepsOnlyThePenColours() throws {
        // Intent: DECALN's cells and the live pen afterwards both carry the pen's foreground
        //   and background and no other attribute.
        // Why it exists: DanTerm's contract is DEC STD 070's rendition reset, which keeps the
        //   colours and drops the attributes -- so text printed after DECALN is not still bold,
        //   underlined, or reversed from whatever the program set before the fill. (alacritty
        //   and wezterm drop the colours too; DanTerm deliberately keeps them.)
        // Scenario: a program sets a loud pen, fills the screen with DECALN, and then prints.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[1;4;7;31;44m".utf8))

        terminal.feed(Array("\u{1B}#8".utf8))

        let coloursOnly = TerminalStyle(foreground: .indexed(1), background: .indexed(4))
        #expect(terminal.cell(row: 0, column: 0)?.style == coloursOnly)
        #expect(terminal.cell(row: 1, column: 3)?.style == coloursOnly)
        #expect(terminal.currentStyle == coloursOnly)

        terminal.feed(Array("x".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.scalars.description == "x")
        #expect(terminal.cell(row: 0, column: 0)?.style == coloursOnly)
        expectValidGrid(terminal)
    }

    @Test("DECALN leaves the saved cursor and the tab stops alone")
    func alignmentFillPreservesSavedCursorAndTabStops() throws {
        // Intent: DECALN resets positioning state, not the DECSC slot or the tab stops.
        // Why it exists: the reset is deliberately narrower than RIS. A program that saves its
        //   cursor around a DECALN, or that set its own tab stops earlier, must still find both
        //   intact afterwards.
        // Scenario: a program clears the tab stops, sets one of its own, saves the cursor,
        //   fills with DECALN, then restores and tabs.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("\u{1B}[3g\u{1B}[1;4H\u{1B}H".utf8))
        terminal.feed(Array("\u{1B}[2;3H\u{1B}7".utf8))

        terminal.feed(Array("\u{1B}#8".utf8))
        terminal.feed(Array("\u{1B}8".utf8))

        #expect(terminal.geometry.cursor?.row == 1)
        #expect(terminal.geometry.cursor?.column == 2)

        // The only remaining stop is column 3; a cleared stop table would send HT to column 7.
        terminal.feed(Array("\t".utf8))
        #expect(terminal.geometry.cursor?.column == 3)
    }

    @Test("DECALN links none of the cells it fills and leaves an open hyperlink open")
    func alignmentFillDoesNotTouchTheHyperlinkPen() throws {
        // Intent: the filled cells carry no hyperlink, and DECALN does not close a hyperlink
        //   the program opened before it.
        // Why it exists: DECALN's reset covers rendition and positioning only. Linking a
        //   screenful of 'E's would make them all activatable, and closing the pen would drop
        //   the link from output the program still expects to be linked.
        // Scenario: a program opens an OSC 8 link, fills with DECALN, and keeps printing.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}]8;;https://example.test\u{7}".utf8))

        terminal.feed(Array("\u{1B}#8".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.hyperlink == nil)
        #expect(terminal.cell(row: 1, column: 3)?.hyperlink == nil)

        terminal.feed(Array("x".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.hyperlink?.uri == "https://example.test")
    }

    /// Builds a terminal whose last retained row is the head of a wrapped line whose remainder
    /// is still live on row 0 -- i.e. history holds an open tail record claiming live row 0.
    private func makeSeamTerminal() throws -> Terminal {
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        // "wrapping line" overflows the 8-column width, so its head enters scrollback
        // soft-wrapped while " line" stays on live row 0.
        terminal.feed(Array("first\r\nsecond\r\nwrapping line\r\nfourth".utf8))
        #expect(terminal.scrollbackRowCount == 3)
        return terminal
    }

    struct EraseLineFixture: Sendable {
        let sequence: String
        let cursorColumn: Int
        let expectedKinds: [TerminalCellKind]
    }

}
