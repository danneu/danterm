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
            "\u{1B}[1:2K",
            "\u{1B}[?1;2K",
            "\u{1B}[?3K",
            "\u{1B}[?1;2J",
            "\u{1B}[?4J",
            "\u{1B}[?22J",
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
        // Intent: display erases that blank the whole of live row 0 close history's open tail
        //   record, while line and character erases leave it open even when they blank row 0.
        // Why it exists: the open bit is history's claim that the last retained row continues
        //   into live row 0. Once that row is blanked in full, the cells the claim names are
        //   gone, so keeping it asserts a continuation that no longer exists. The converse cases
        //   are the hazard in the other direction: with columns 0..<cursor.column of row 0 still
        //   standing, those cells genuinely continue the retained line, and severing would split
        //   one real logical line in two.
        // Scenario: a wrapped line straddles the history/live seam -- its head is in scrollback,
        //   its remainder on live row 0 -- and an application issues each erase in turn.
        let severing = [
            "\u{1B}[2J",
            "\u{1B}[2;1H\u{1B}[1J",
            "\u{1B}[H\u{1B}[J",
            "\u{1B}[1;8H\u{1B}[1J",
            "\u{1B}[1;8H\u{1B}[?1J",
            "\u{1B}#8",
        ]
        for sequence in severing {
            var terminal = try makeSeamTerminal()
            #expect(terminal.scrollbackRow(at: 2)?.isSoftWrapped == true)
            terminal.feed(Array(sequence.utf8))
            #expect(terminal.scrollbackRow(at: 2)?.isSoftWrapped == false, "\(sequence)")
            expectValidGrid(terminal)
        }

        // A partial display erase leaves a real continuation standing. EL and ECH are
        // rewrite-in-place operations and do not change the history seam even when they blank
        // every cell in row 0.
        let preserving = [
            "\u{1B}[1;4H\u{1B}[1J",
            "\u{1B}[1;4H\u{1B}[J",
            "\u{1B}[H\u{1B}[K",
            "\u{1B}[H\u{1B}[2K",
            "\u{1B}[H\u{1B}[8X",
        ]
        for sequence in preserving {
            var terminal = try makeSeamTerminal()
            terminal.feed(Array(sequence.utf8))
            #expect(terminal.scrollbackRow(at: 2)?.isSoftWrapped == true, "\(sequence)")
            expectValidGrid(terminal)
        }

        var wideExpansion = try makeSeamTerminal()
        wideExpansion.feed(Array("\u{1B}[H\u{754C}\u{1B}[1;2H\u{1B}[J".utf8))
        #expect(wideExpansion.scrollbackRow(at: 2)?.isSoftWrapped == false)
        expectValidGrid(wideExpansion)

        var protected = try makeSeamTerminal()
        protected.feed(Array("\u{1B}[H\u{1B}[1\"qZ\u{1B}[0\"q\u{1B}[1;8H\u{1B}[?1J".utf8))
        #expect(protected.scrollbackRow(at: 2)?.isSoftWrapped == true)
        expectValidGrid(protected)
    }

    @Test("ED 1 through the last cell retains the same line boundary as ED 2")
    func eraseDisplayLeftCompleteMatchesEraseDisplayCompleteHistory() throws {
        // Intent: ED 1 at row 0's last column and ED 2 produce the same retained line boundary
        //   when both blank all of the live continuation before replacement text is printed.
        // Why it exists: the display-erase mode used to choose whether history's incoming wrap
        //   claim closed, even when both modes produced the same blank row 0.
        // Scenario: a ten-cell line wraps across the history seam, the application clears its
        //   live continuation with either display erase, prints a replacement, and scrolls it off.
        let prefix = "AAAAAAAAAABB\u{1B}[2;1H\n"
        let suffix = "\u{1B}[Hcccc\u{1B}[2;1H\n\n"
        var left = try #require(Terminal(columns: 10, rows: 2))
        var complete = try #require(Terminal(columns: 10, rows: 2))

        left.feed(Array("\(prefix)\u{1B}[1;10H\u{1B}[1J\(suffix)".utf8))
        complete.feed(Array("\(prefix)\u{1B}[2J\(suffix)".utf8))

        #expect(left.primaryHistoryText == "AAAAAAAAAA\ncccc")
        #expect(left.primaryHistoryText == complete.primaryHistoryText)
        expectValidGrid(left)
        expectValidGrid(complete)
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

    @Test("ED, EL and ECH blank protected cells and leave the pen armed")
    func nonSelectiveErasesIgnoreProtection() throws {
        // Intent: the bare erases treat a DECSCA-protected cell like any other cell, and none
        //   of them disarms the pen.
        // Why it exists: xterm's changelog records "ECH should not be masked by DECSCA"; only
        //   the `?` forms are selective, so a protected field must not survive a plain clear.
        // Scenario: a program protects a field, then clears the line, the display, or a run
        //   of characters the ordinary way.
        for sequence in ["\u{1B}[2K", "\u{1B}[2J", "\u{1B}[4X"] {
            var terminal = try #require(Terminal(columns: 4, rows: 1))
            terminal.feed(Array("\u{1B}[1\"qABCD".utf8))

            terminal.feed(Array("\u{1B}[1;1H\(sequence)".utf8))

            for column in 0..<4 {
                let cell = terminal.cell(row: 0, column: column)
                #expect(cell?.kind == .padding, "\(sequence) column \(column)")
                #expect(cell?.style.protected == false, "\(sequence) column \(column)")
            }
            #expect(terminal.currentStyle.protected)
            expectValidGrid(terminal)
        }
    }

    @Test(
        "DECSEL and DECSED blank their region except the protected cells in it",
        arguments: [
            // DECSEL over the whole row; both islands stand and the run between them goes.
            SelectiveEraseFixture(sequence: "\u{1B}[1;1H\u{1B}[?2K", survivors: [2, 3, 6]),
            // DECSEL 0 from column 4: erasing continues past the island at column 6.
            SelectiveEraseFixture(sequence: "\u{1B}[1;5H\u{1B}[?K", survivors: [0, 1, 2, 3, 6]),
            SelectiveEraseFixture(sequence: "\u{1B}[1;5H\u{1B}[?1K", survivors: [2, 3, 5, 6, 7]),
            SelectiveEraseFixture(sequence: "\u{1B}[1;1H\u{1B}[?2J", survivors: [2, 3, 6]),
            SelectiveEraseFixture(sequence: "\u{1B}[1;5H\u{1B}[?J", survivors: [0, 1, 2, 3, 6]),
            SelectiveEraseFixture(sequence: "\u{1B}[1;5H\u{1B}[?1J", survivors: [2, 3, 5, 6, 7]),
        ]
    )
    func selectiveEraseSkipsProtectedCells(fixture: SelectiveEraseFixture) throws {
        // Intent: DECSED/DECSEL blank exactly what ED/EL would, minus the DECSCA-protected
        //   cells, and keep going past a protected run rather than stopping at it.
        // Why it exists: this is the whole point of the family -- a program protects a field
        //   and clears around it, so both halves have to be right: the field survives and
        //   everything else in the region goes.
        // Scenario: a form with two protected fields on one line is cleared from various
        //   cursor positions.
        var terminal = try makeProtectedIslandTerminal()

        terminal.feed(Array(fixture.sequence.utf8))

        for column in 0..<8 {
            let cell = try #require(terminal.cell(row: 0, column: column))
            if fixture.survivors.contains(column) {
                #expect(cell.kind == .narrow, "column \(column)")
                #expect(cell.scalars.first == Self.islandRow[column], "column \(column)")
            } else {
                #expect(cell.kind == .padding, "column \(column)")
                // Every erase writes unprotected blanks, selective or not.
                #expect(cell.style.protected == false, "column \(column)")
            }
        }
        expectValidGrid(terminal)
    }

    @Test("DECSED 3 clears retained history the way ED 3 does")
    func selectiveEraseDisplayModeThreeClearsHistory() throws {
        // Intent: `CSI ? 3 J` empties scrollback exactly as `CSI 3 J` does.
        // Why it exists: xterm names the sequence "Selective Erase Saved Lines" and clears the
        //   same region ED 3 clears; Windows Terminal and vte make it a no-op, and we follow
        //   xterm, Ghostty and libvterm instead.
        // Scenario: a program with a protected field on screen clears the scrollback.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("one\r\ntwo\r\n\u{1B}[1\"qthree".utf8))
        #expect(terminal.scrollbackRowCount > 0)

        terminal.feed(Array("\u{1B}[?3J".utf8))

        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.cell(row: 1, column: 0)?.style.protected == true)
        expectValidGrid(terminal)
    }

    @Test("a selective erase decides a wide pair as one cell")
    func selectiveEraseKeepsWidePairsWhole() throws {
        // Intent: DECSEL keeps or blanks both halves of a double-width character together.
        // Why it exists: deciding per cell could leave a head without its tail, a grid shape
        //   no print can produce. libvterm leaves the tail unprotected and is the outlier here.
        // Scenario: the cursor sits on the tail half of a protected wide glyph when the line
        //   is selectively erased.
        var protectedPair = try #require(Terminal(columns: 6, rows: 1))
        protectedPair.feed(Array("\u{1B}[1\"q\u{754C}\u{1B}[0\"qab".utf8))

        protectedPair.feed(Array("\u{1B}[1;2H\u{1B}[?K".utf8))

        #expect(protectedPair.cell(row: 0, column: 0)?.kind == .wideHead)
        #expect(protectedPair.cell(row: 0, column: 1)?.kind == .wideTail)
        #expect(protectedPair.cell(row: 0, column: 2)?.kind == .padding)
        expectValidGrid(protectedPair)

        var unprotectedPair = try #require(Terminal(columns: 6, rows: 1))
        unprotectedPair.feed(Array("\u{754C}ab".utf8))

        unprotectedPair.feed(Array("\u{1B}[1;2H\u{1B}[?K".utf8))

        #expect(unprotectedPair.cell(row: 0, column: 0)?.kind == .padding)
        #expect(unprotectedPair.cell(row: 0, column: 1)?.kind == .padding)
        expectValidGrid(unprotectedPair)
    }

    @Test(
        "with nothing protected a selective erase leaves the terminal identical to the bare form",
        arguments: ["", "0", "1", "2", "3"], ["J", "K"]
    )
    func selectiveEraseMatchesTheBareFormWhenNothingIsProtected(
        parameter: String,
        final: String
    ) throws {
        // Intent: the `?` prefix changes nothing at all when no cell in the region is
        //   protected -- grid, styles, cursor, pending wrap, soft-wrap flags and history all
        //   compare equal, and a mode neither form accepts is a no-op in both.
        // Why it exists: DECSED/DECSEL are ED/EL plus a skip rule, so every row-level side
        //   effect has to keep deriving from the cells actually blanked. A side effect wired
        //   to the sequence instead of to the blanking would show up here as a difference.
        // Scenario: an ordinary session -- text over several rows, scrollback behind it, the
        //   cursor mid-row with pending wrap armed -- receives each erase in both spellings.
        var selective = try makeParityTerminal()
        var bare = try makeParityTerminal()

        selective.feed(Array("\u{1B}[?\(parameter)\(final)".utf8))
        bare.feed(Array("\u{1B}[\(parameter)\(final)".utf8))

        #expect(selective == bare)
        expectValidGrid(selective)
    }

    @Test("a selective erase preserves a protected wide wrap gap in its region")
    func selectiveEraseBlanksAWrapSpacer() throws {
        // Intent: the derived gap above a protected wide glyph survives a selective erase.
        // Why it exists: the gap projects the follower's protection. Treating the stored margin
        //   blank as unprotected would erase the evidence for a gap the protected glyph still
        //   needs.
        // Scenario: a protected wide glyph is printed at the right margin, so it wraps and
        //   leaves a spacer behind, and the row it left is then selectively erased.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[1;4H\u{1B}[1\"q\u{754C}".utf8))
        #expect(terminal.cell(row: 0, column: 3)?.kind == .spacerHead)

        terminal.feed(Array("\u{1B}[1;4H\u{1B}[?1K".utf8))

        #expect(terminal.cell(row: 0, column: 3)?.kind == .spacerHead)
        expectValidGrid(terminal)

        terminal.feed(Array("\u{1B}[1;4H\u{1B}[?K".utf8))

        #expect(terminal.cell(row: 0, column: 3)?.kind == .padding)
        #expect(terminal.geometry.rows[0].isSoftWrapped == false)
        expectValidGrid(terminal)
    }

    @Test("DECSEL 0 ends the row's wrap and the pending wrap even when the margin cell survives")
    func selectiveEraseLineRightEndsTheWrapDespiteAProtectedMargin() throws {
        // Intent: EL 0's line-structure effects are unconditional under the `?` form too -- the
        //   row stops claiming a soft wrap and the deferred wrap is disarmed, whether or not the
        //   margin cell was blanked.
        // Why it exists: the wrap point is the margin column itself. A protected cell standing
        //   there is text the program means to keep, not a statement that the line continues,
        //   and leaving pending wrap armed would push the next character onto the wrong row.
        // Scenario: a program protects a full-width line, then clears from the margin rightward.
        var wrapped = try #require(Terminal(columns: 4, rows: 2))
        wrapped.feed(Array("\u{1B}[1\"qABCDE".utf8))
        #expect(wrapped.geometry.rows[0].isSoftWrapped)

        wrapped.feed(Array("\u{1B}[1;4H\u{1B}[?K".utf8))

        #expect(wrapped.cell(row: 0, column: 3)?.scalars.first == "D")
        #expect(wrapped.geometry.rows[0].isSoftWrapped == false)
        expectValidGrid(wrapped)

        var pending = try #require(Terminal(columns: 4, rows: 2))
        pending.feed(Array("\u{1B}[1\"qABCD".utf8))

        // No cursor motion in between, so the pending wrap DECSEL 0 has to clear is still armed.
        pending.feed(Array("\u{1B}[?KX".utf8))

        #expect(pending.cell(row: 0, column: 3)?.scalars.first == "X")
        #expect(pending.cell(row: 1, column: 0)?.kind == .padding)
        expectValidGrid(pending)
    }

    @Test("a wrap claim whose margin cell a selective erase spared still names real content")
    func selectiveEraseKeepsTheWrapClaimWhoseMarginSurvived() throws {
        // Intent: `GridRow.marginProvenance` records the margin's last writer, so a protected
        //   margin cell surviving DECSEL 2 leaves the row's claim witnessed and the line stays
        //   fused; the bare EL 2 blanks the margin and the readers split the line.
        // Why it exists: the stale-claim gate exists because an erased margin no longer names
        //   content. A selective erase that spared the margin has not destroyed anything, so
        //   wiring the flag to the sequence rather than to the blanking would split a line that
        //   is still whole.
        // Scenario: a protected character sits at the right margin of a soft-wrapped row that
        //   an application blanks and rewrites, then the rows scroll off.
        var kept = try makeProtectedMarginWrapTerminal(erase: "\u{1B}[?2K")
        #expect(kept.primaryHistoryText == "cccc     Zdddd")

        var severed = try makeProtectedMarginWrapTerminal(erase: "\u{1B}[2K")
        #expect(severed.primaryHistoryText == "cccc\ndddd")
    }

    @Test("a spacer is retired by the wide head below it going away, not by the erase itself")
    func selectiveEraseKeepsTheSpacerAboveAProtectedHead() throws {
        // Intent: the projected spacer survives while its protected column-0 wide head survives,
        //   both for a live row above it and for one at the history seam.
        // Why it exists: the spacer derives from the wide head. Erasing unrelated cells in the
        //   follower row must not remove a gap that the protected glyph still needs.
        // Scenario: a protected wide glyph wrapped off the right margin, and the row it landed
        //   on is selectively erased.
        var live = try #require(Terminal(columns: 4, rows: 2))
        live.feed(Array("\u{1B}[1;4H\u{1B}[1\"q\u{754C}".utf8))

        live.feed(Array("\u{1B}[2;1H\u{1B}[?2K".utf8))

        #expect(live.cell(row: 0, column: 3)?.kind == .spacerHead)
        #expect(live.cell(row: 1, column: 0)?.kind == .wideHead)
        #expect(live.cell(row: 1, column: 1)?.kind == .wideTail)
        expectValidGrid(live)

        var seam = try #require(Terminal(columns: 4, rows: 2))
        seam.feed(Array("\u{1B}[1;4H\u{1B}[1\"q\u{754C}".utf8))
        seam.feed(Array("\u{1B}[2;1H\n".utf8))
        #expect(seam.scrollbackRowCount == 1)

        seam.feed(Array("\u{1B}[1;1H\u{1B}[?2K".utf8))

        #expect(seam.cell(row: 0, column: 0)?.kind == .wideHead)
        #expect(seam.scrollbackRowCount == seam.independentScrollbackRowRecount)
        expectValidGrid(seam)
    }

    @Test("a selective erase that spares a cell in row 0 leaves history's logical line open")
    func selectiveEraseWithAProtectedRowZeroKeepsHistorysWrapClaim() throws {
        // Intent: DECSED 2 severs history's claim on live row 0 only when row 0 is blanked in
        //   full, which is the rule the sever already states for the bare erases.
        // Why it exists: the claim says history's last retained row continues into live row 0.
        //   A protected cell standing there is exactly that continuation still on screen, so
        //   severing would split one real logical line in two.
        // Scenario: a wrapped line straddles the history/live seam and the program has
        //   protected one character of the part that is still live.
        var kept = try makeSeamTerminal()
        kept.feed(Array("\u{1B}[1;3H\u{1B}[1\"qZ\u{1B}[0\"q".utf8))

        kept.feed(Array("\u{1B}[?2J".utf8))

        #expect(kept.scrollbackRow(at: 2)?.isSoftWrapped == true)
        expectValidGrid(kept)

        var severed = try makeSeamTerminal()
        severed.feed(Array("\u{1B}[1;3HZ".utf8))

        severed.feed(Array("\u{1B}[?2J".utf8))

        #expect(severed.scrollbackRow(at: 2)?.isSoftWrapped == false)
        expectValidGrid(severed)
    }

    @Test("a row a selective erase did not fully blank keeps its wrap flag and prompt mark")
    func selectiveEraseKeepsTheStructureOfARowItDidNotClear() throws {
        // Intent: the whole-row structural resets -- the soft-wrap flag and the semantic prompt
        //   stamp -- happen only for a row DECSED actually blanked in full.
        // Why it exists: those resets say "this row holds nothing any more". A row still
        //   showing a protected field holds something, and dropping its prompt mark would move
        //   the prompt boundary the shell integration reports.
        // Scenario: a prompt row carries a protected character when the program clears the
        //   display.
        var kept = try #require(Terminal(columns: 6, rows: 2))
        kept.feed(Array("\u{1B}]133;A\u{7}ABCDE\u{1B}[1\"qF\u{1B}[0\"qG".utf8))
        #expect(kept.geometry.rows[0].isSoftWrapped)

        kept.feed(Array("\u{1B}[?2J".utf8))

        #expect(kept.geometry.rows[0].isSoftWrapped)
        #expect(kept.semanticPromptRowsForTesting[0].stamp == .prompt)
        expectValidGrid(kept)

        var cleared = try #require(Terminal(columns: 6, rows: 2))
        cleared.feed(Array("\u{1B}]133;A\u{7}ABCDEFG".utf8))

        cleared.feed(Array("\u{1B}[?2J".utf8))

        #expect(cleared.geometry.rows[0].isSoftWrapped == false)
        #expect(cleared.semanticPromptRowsForTesting[0].stamp == .none)
        expectValidGrid(cleared)
    }

    /// One row holding two protected islands -- columns 2..3 and column 6 -- inside plain text,
    /// which is the shape every selective-erase region case is measured against.
    private func makeProtectedIslandTerminal() throws -> Terminal {
        var terminal = try #require(Terminal(columns: 10, rows: 1))
        terminal.feed(Array("AB\u{1B}[1\"qCD\u{1B}[0\"qEF\u{1B}[1\"qG\u{1B}[0\"qH".utf8))
        for column in 0..<8 {
            #expect(terminal.cell(row: 0, column: column)?.style.protected == [2, 3, 6].contains(column))
        }
        return terminal
    }

    /// An ordinary unprotected session: scrollback behind the viewport, text on every live row,
    /// and the cursor left at the margin with pending wrap armed.
    private func makeParityTerminal() throws -> Terminal {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("one\r\ntwo\r\nthree\r\nfour-line\r\nfive".utf8))
        #expect(terminal.scrollbackRowCount > 0)
        terminal.feed(Array("\u{1B}[2;1Habcdefgh".utf8))
        return terminal
    }

    /// The Ink repaint transient with one protected character at the margin of the wrapped row,
    /// erased by `erase` and then rewritten and scrolled off.
    private func makeProtectedMarginWrapTerminal(erase: String) throws -> Terminal {
        var terminal = try #require(Terminal(columns: 10, rows: 3))
        terminal.feed(Array("AAAAAAAAA\u{1B}[1\"qZ\u{1B}[0\"qBB".utf8))
        terminal.feed(Array("\u{1B}[H\(erase)cccc".utf8))
        terminal.feed(Array("\u{1B}[2;1H\u{1B}[2Kdddd".utf8))
        terminal.feed(Array("\u{1B}[3;1H\n\n".utf8))
        return terminal
    }

    struct SelectiveEraseFixture: Sendable {
        let sequence: String
        /// Columns whose original character is still standing after the erase.
        let survivors: [Int]
    }

    /// The characters `makeProtectedIslandTerminal` prints, by column.
    private static let islandRow: [Unicode.Scalar] = ["A", "B", "C", "D", "E", "F", "G", "H"]

    struct EraseLineFixture: Sendable {
        let sequence: String
        let cursorColumn: Int
        let expectedKinds: [TerminalCellKind]
    }

}
