// Alternate-screen mode, isolation, projection, resize, and reset proofs.
import Testing

@testable import TerminalCore

/// Pins the alternate screen as transient grid state over shared terminal control state.
struct TerminalAlternateScreenTests {
    @Test("alternate width changes clear clipped live and saved last-column state")
    func widthChangeClearsClippedLastColumnState() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[?1047h\u{1B}[?7lABCD\u{1B}7".utf8))

        terminal.resize(columns: 3, rows: 2)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))

        terminal.feed(Array("\r\u{1B}8".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))
        expectValidGrid(terminal)
    }

    @Test("1049 clears on every entry under the erase pen and carries the live cursor on exit")
    func mode1049SwitchesAndClears() throws {
        var terminal = try #require(Terminal(columns: 5, rows: 2))
        terminal.feed(Array("PRIMARY".utf8))
        let primary = primaryContent(of: terminal)

        terminal.feed(Array("\u{1B}[2;3H\u{1B}[31;44;1m\u{1B}[?1049h".utf8))

        #expect(terminal.screenText == "     \n     ")
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 2, isPendingWrap: false))
        for row in 0..<2 {
            for column in 0..<5 {
                #expect(terminal.cell(row: row, column: column)?.style == TerminalStyle(
                    foreground: .indexed(1),
                    background: .indexed(4)
                ))
            }
            #expect(terminal.geometry.rows[row].isSoftWrapped == false)
        }

        terminal.feed(Array("ALT\u{1B}[?1049h".utf8))
        #expect(terminal.screenText == "     \n     ")
        terminal.feed(Array("\u{1B}[1;5HZ\u{1B}[?1049l".utf8))

        #expect(primaryContent(of: terminal) == primary)
        #expect(terminal.screenText == "PRIMA\nRY   ")
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 2, isPendingWrap: false))
        expectValidGrid(terminal)
    }

    @Test("the three alternate-screen modes differ only in their save and clear edges")
    func screenSwitchModesDifferOnlyInTheirAnswers() throws {
        // Intent: 47 neither saves the cursor nor clears a grid, 1047 clears the alternate as it
        //   leaves it, and 1049 saves the cursor and clears the alternate as it arrives.
        // Why it exists: 47 used to be dropped outright, so a program that hardcodes the legacy
        //   switch drew its full-screen UI into the shell transcript; and 1047 cleared the edge
        //   xterm does not, which shows the moment a retained alternate can be re-entered.
        // Scenario: one program draws a frame on the alternate screen and leaves, and a second
        //   one comes back to it through each mode in turn.
        var carried = try #require(Terminal(columns: 5, rows: 2))
        carried.feed(Array("PRIMARY\u{1B}[2;3H\u{1B}[?47hALT".utf8))
        // 47 saves nothing, so the entry lands the live cursor where the primary left it.
        #expect(carried.screenText == "     \n  ALT")
        carried.feed(Array("\u{1B}[?47l".utf8))
        #expect(carried.screenText == "PRIMA\nRY   ")

        carried.feed(Array("\u{1B}[?47h".utf8))
        #expect(carried.screenText == "     \n  ALT", "47 shows the frame it left behind")

        carried.feed(Array("\u{1B}[?1047l".utf8))
        #expect(carried.screenText == "PRIMA\nRY   ")
        carried.feed(Array("\u{1B}[?47h".utf8))
        #expect(carried.screenText == "     \n     ", "1047 blanked the alternate on its way out")

        var entry = try #require(Terminal(columns: 5, rows: 2))
        entry.feed(Array("\u{1B}[?1047hFRAME\u{1B}[?47l\u{1B}[?1047h".utf8))
        #expect(entry.screenText == "FRAME\n     ", "1047 does not clear on entry")

        var saves = try #require(Terminal(columns: 5, rows: 2))
        saves.feed(Array("\u{1B}[2;4H\u{1B}[?1049h\u{1B}[1;1H\u{1B}[?1049l".utf8))
        #expect(saves.geometry.cursor == TerminalCursor(row: 1, column: 3, isPendingWrap: false))
    }

    @Test("a first entry to a never-used alternate screen yields default-styled cells")
    func firstEntryToUnclearedAlternateUsesDefaultStyle() throws {
        // Intent: only a clear paints the erase style, so a mode that clears nothing arrives on
        //   blank default cells however the pen is set.
        // Why it exists: 1047's entry clear used to make every first entry adopt the background
        //   erase pen; dropping that clear also drops the styling that came with it.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[44m\u{1B}[?47h".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.style == TerminalStyle())
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        #expect(terminal.cell(row: 0, column: 0)?.style == TerminalStyle(background: .indexed(4)))
    }

    @Test("RIS drops the alternate screen the terminal retains")
    func hardResetDropsTheRetainedAlternateScreen() throws {
        // Intent: after RIS, re-entering the alternate screen shows a blank grid and restores
        //   default screen-scoped state, exactly as it would on a terminal just created.
        // Why it exists: a retained alternate outlives its program, and no synchronization
        //   stream can encode away a frame the replica holds and the source does not.
        // Scenario: a full-screen program leaves a frame and a saved cursor behind, the shell
        //   resets the terminal, and something re-enters the alternate screen later.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[?47hFRAME\u{1B}[2;3H\u{1B}7\u{1B}[?47l".utf8))
        terminal.feed(Array("\u{1B}c".utf8))

        terminal.feed(Array("\u{1B}[?47h".utf8))
        #expect(terminal.screenText == "    \n    ")
        terminal.feed(Array("\u{1B}[1;2H\u{1B}8".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
    }

    @Test("nested 1049 saves each screen independently and redundant exits are idempotent")
    func mode1049OrderingAndRedundantOperations() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("AB\u{1B}[?1049h".utf8))
        #expect(terminal.geometry.cursor?.isPendingWrap == false)

        terminal.feed(Array("\u{1B}[1;3HX\u{1B}[?1049h".utf8))
        #expect(terminal.screenText == "    \n    ")
        terminal.feed(Array("\u{1B}[2;1H\u{1B}[?1049l".utf8))

        #expect(terminal.screenText == "AB  \n    ")
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))

        terminal.feed(Array("\u{1B}[2;4H\u{1B}[?1048h\u{1B}[1;1H\u{1B}[?1049l".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 3, isPendingWrap: false))

        var pending = try #require(Terminal(columns: 2, rows: 2))
        pending.feed(Array("AB\u{1B}[?1049h\u{1B}[?1049l".utf8))
        #expect(pending.geometry.cursor?.isPendingWrap == true)
        pending.feed(Array("X".utf8))
        #expect(pending.screenText == "AB\nX ")
    }

    @Test(
        "saved cursor aliases use independent slots on the primary and alternate screens",
        arguments: [
            ("\u{1B}7", "\u{1B}8"),
            ("\u{1B}[s", "\u{1B}[u"),
            ("\u{1B}[?1048h", "\u{1B}[?1048l"),
        ]
    )
    func savedCursorSlotsAreScreenScoped(save: String, restore: String) throws {
        // Intent: every save/restore spelling reads and writes only the active screen's slot.
        // Why it exists: a shared slot lets a full-screen application destroy the shell's save.
        // Scenario: each screen saves a different position, then restores it after a round trip.
        var terminal = try #require(Terminal(columns: 6, rows: 4))
        terminal.feed(Array("\u{1B}[2;3H\(save)\u{1B}[?1047h\(restore)".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))

        terminal.feed(Array("\u{1B}[3;5H\(save)\u{1B}[?1047l\u{1B}[1;1H\(restore)".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 2, isPendingWrap: false))

        terminal.feed(Array("\u{1B}[?1047h\u{1B}[1;1H\(restore)".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 2, column: 4, isPendingWrap: false))
    }

    @Test("recognized switches clear pending wrap and recover adjacent grid attachment")
    func switchSideStateAndUnsupportedMode() throws {
        for sequence in [
            "\u{1B}[?2047h", "\u{1B}[?2047l", "\u{1B}[?1047$h",
        ] {
            var terminal = try #require(Terminal(columns: 3, rows: 2))
            terminal.feed(Array("AB\u{200D}".utf8))
            let expected = terminal
            terminal.feed(Array(sequence.utf8))
            #expect(terminal == expected)
        }

        var pending = try #require(Terminal(columns: 2, rows: 2))
        pending.feed(Array("AB\u{1B}[?1047lX".utf8))
        #expect(pending.screenText == "AX\n  ")

        var cluster = try #require(Terminal(columns: 3, rows: 1))
        cluster.feed(Array("A\u{200D}\u{1B}[?1047l\u{0301}".utf8))
        #expect(cluster.cell(row: 0, column: 0)?.scalars == ["A", "\u{200D}", "\u{0301}"])
    }

    @Test("screen switches preserve shared modes, tabs, margins, REP memory, and pen")
    func switchesPreserveSharedState() throws {
        var penAndModes = try #require(Terminal(columns: 5, rows: 3))
        penAndModes.feed(Array("Q\u{1B}[31m\u{1B}[4;20h\u{1B}[?7l\u{1B}[?1047h".utf8))
        penAndModes.feed(Array("\u{1B}[1;1HAB\u{1B}[1GX\n".utf8))
        #expect(penAndModes.screenText.hasPrefix("XAB"))
        #expect(penAndModes.cell(row: 0, column: 0)?.style.foreground == .indexed(1))
        #expect(penAndModes.geometry.cursor == TerminalCursor(row: 1, column: 0, isPendingWrap: false))
        penAndModes.feed(Array("\u{1B}[?1047l\u{1B}[b".utf8))
        #expect(penAndModes.cell(row: 1, column: 0)?.scalars == ["X"])

        var tabs = try #require(Terminal(columns: 10, rows: 2))
        tabs.feed(Array("\u{1B}[3g\u{1B}[1;4H\u{1B}H\r\u{1B}[?1047h\t".utf8))
        #expect(tabs.geometry.cursor?.column == 3)

        var autoWrap = try #require(Terminal(columns: 3, rows: 2))
        autoWrap.feed(Array("\u{1B}[?7l\u{1B}[?1047hABCD".utf8))
        #expect(autoWrap.screenText == "ABD\n   ")

        var marginsAndOrigin = try #require(Terminal(columns: 5, rows: 4))
        marginsAndOrigin.feed(Array("\u{1B}[2;3r\u{1B}[?6h\u{1B}[?1047h\u{1B}[1;1H".utf8))
        #expect(marginsAndOrigin.geometry.cursor?.row == 1)

        var saved = try #require(Terminal(columns: 5, rows: 3))
        saved.feed(Array("\u{1B}[2;4H\u{1B}7\u{1B}[?1047h\u{1B}[1;1H\u{1B}[?1047l\u{1B}8".utf8))
        #expect(saved.geometry.cursor == TerminalCursor(row: 1, column: 3, isPendingWrap: false))
    }

    @Test("alternate scrolling never pushes history and ED 3 still clears primary scrollback")
    func alternateScrollbackIsolation() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("ABCDEFGHI".utf8))
        let history = (0..<terminal.scrollbackRowCount).compactMap(terminal.scrollbackRow(at:))
        let primary = primaryContent(of: terminal)

        // Cells, not whole rows: the active stream severs the last retained row's wrap while
        // the alternate screen is up, and that is the reader's contract, not a push.
        terminal.feed(Array("\u{1B}[?1047h123456789012".utf8))
        #expect(terminal.scrollbackRowCount == history.count)
        #expect(
            (0..<terminal.scrollbackRowCount).compactMap(terminal.scrollbackRow(at:)).map(\.cells)
                == history.map(\.cells)
        )
        terminal.feed(Array("\u{1B}[?1047l".utf8))
        #expect(primaryContent(of: terminal) == primary)

        terminal.feed(Array("\u{1B}[?1047h\u{1B}[3J".utf8))
        #expect(terminal.scrollbackRowCount == 0)
        terminal.feed(Array("\u{1B}[?1047l".utf8))
        expectValidGrid(terminal)
    }

    @Test("alternate display erases and DECALN do not sever the primary history seam")
    func alternateErasesKeepPrimaryHistorysWrapClaim() throws {
        // Intent: display erases and DECALN affect only the active alternate grid and cannot
        //   close the primary history store's open tail record.
        // Why it exists: row-0 display erases have a primary-only history-side effect. A check
        //   based only on what the active row erase blanked can leak that effect across screens.
        // Scenario: a primary wrapped line straddles the history seam while an alternate-screen
        //   application issues every display-erase mode and DECALN before returning.
        let erases = [
            "\u{1B}[H\u{1B}[J",
            "\u{1B}[1;8H\u{1B}[1J",
            "\u{1B}[2J",
            "\u{1B}[H\u{1B}[?J",
            "\u{1B}[1;8H\u{1B}[?1J",
            "\u{1B}[?2J",
            "\u{1B}#8",
        ]
        for erase in erases {
            var terminal = try #require(Terminal(columns: 8, rows: 2))
            terminal.feed(Array("first\r\nsecond\r\nwrapping line\r\nfourth".utf8))
            #expect(terminal.scrollbackRow(at: 2)?.isSoftWrapped == true)

            terminal.feed(Array("\u{1B}[?1047h\(erase)\u{1B}[?1047l".utf8))

            #expect(terminal.scrollbackRow(at: 2)?.isSoftWrapped == true, "\(erase)")
            expectValidGrid(terminal)
        }
    }

    @Test("full history follows alt with a hard seam while primary history stays continuous")
    func activeAndPrimaryHistoryProjections() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("ABCDEFGHI\u{1B}[H\u{1B}[?1047hZ".utf8))

        #expect(terminal.fullHistoryText == "ABCD\nZ")
        #expect(terminal.primaryHistoryText == "ABCDEFGHI")
        #expect(terminal.fullHistoryText != terminal.primaryHistoryText)

        terminal.feed(Array("\u{1B}[?1047l".utf8))
        #expect(terminal.fullHistoryText == terminal.primaryHistoryText)
    }

    @Test("alternate resize retains a rectangle, clips wide clusters, and grows with defaults")
    func alternateRectangleResize() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[?1047hABCD\u{1B}[2;1HEFGH".utf8))
        terminal.resize(columns: 3, rows: 2)
        #expect(terminal.screenText == "ABC\nEFG")
        #expect(terminal.geometry.rows.allSatisfy { $0.isSoftWrapped == false })

        terminal.feed(Array("\u{1B}[1;2H\u{1B}[1;44m\u{754C}".utf8))
        terminal.resize(columns: 2, rows: 2)
        #expect(terminal.cell(row: 0, column: 1) == TerminalCell(
            kind: .padding,
            scalars: [],
            style: TerminalStyle(background: .indexed(4))
        ))

        terminal.resize(columns: 5, rows: 3)
        #expect(terminal.screenText == "A    \nEF   \n     ")
        #expect(terminal.cell(row: 0, column: 4)?.style == TerminalStyle())
        #expect(terminal.cell(row: 2, column: 0)?.style == TerminalStyle())
        expectValidGrid(terminal)

        var spacer = try #require(Terminal(columns: 3, rows: 2))
        spacer.feed(Array("\u{1B}[?1047h\u{1B}[1;3H\u{754C}".utf8))
        spacer.resize(columns: 3, rows: 3)
        #expect(spacer.geometry.rows[0].cells[2].kind == .spacerHead)
        #expect(spacer.geometry.rows[0].isSoftWrapped)
        #expect(spacer.geometry.rows[1].cells[0].kind == .wideHead)
        spacer.resize(columns: 3, rows: 1)
        #expect(spacer.geometry.rows[0].cells[2].kind == .padding)
        #expect(spacer.geometry.rows[0].isSoftWrapped == false)

        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        var cluster = try #require(Terminal(columns: 4, rows: 2))
        cluster.feed(Array(("\u{1B}[?1047h\u{1B}[1;3H" + family).utf8))
        cluster.resize(columns: 3, rows: 2)
        #expect(cluster.cell(row: 0, column: 2)?.kind == .padding)
        #expect(cluster.cell(row: 0, column: 2)?.scalars.isEmpty == true)
        expectValidGrid(cluster)
    }

    @Test("alternate height-only resize preserves an erased margin's stale wrap claim")
    func alternateHeightResizePreservesStaleWrapClaim() throws {
        // Intent: a height-only alternate resize preserves the row fact that gates an erased
        //   margin's surviving wrap claim, so the public line projection keeps its hard break.
        // Why it exists: BUG-30 rebuilt each row without that fact and fused the erased row with
        //   its follower after a height-only resize.
        // Scenario: a 3-column row wraps, EL 2 blanks its margin, then the screen loses one row.
        var terminal = try #require(Terminal(columns: 3, rows: 3))
        terminal.feed(Array("\u{1B}[?1047hABCD\u{1B}[1;1H\u{1B}[2K".utf8))
        let structureBeforeResize = try #require(terminal.rowStructure.first)
        #expect(structureBeforeResize.isSoftWrapped == false)
        #expect(structureBeforeResize.staleWrapClaim)
        #expect(terminal.fullHistoryText == "\nD")

        terminal.resize(columns: 3, rows: 2)

        #expect(terminal.rowStructure.first == structureBeforeResize)
        #expect(terminal.fullHistoryText == "\nD")
        expectValidGrid(terminal)
    }

    @Test("alternate resize resets margins and clamps live and saved cursors off active tails")
    func alternateResizeClampsCursorsAndMargins() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("P\u{1B}[?1047h\u{1B}[1;2H\u{754C}".utf8))
        terminal.moveCursor(row: 0, column: 2)
        terminal.feed(Array("\u{1B}[?1048h".utf8))

        terminal.resize(columns: 4, rows: 4)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 1, isPendingWrap: false))
        terminal.moveCursor(row: 3, column: 3)
        terminal.feed(Array("\u{1B}[2;3r\u{1B}[?6h".utf8))
        terminal.resize(columns: 5, rows: 4)
        terminal.feed(Array("\u{1B}[1;1H".utf8))
        #expect(terminal.geometry.cursor?.row == 0)

        terminal.feed(Array("\u{1B}[?1048l".utf8))
        #expect(terminal.geometry.cursor?.column == 1)

        var restore = try #require(Terminal(columns: 4, rows: 2))
        restore.moveCursor(row: 0, column: 2)
        restore.feed(Array("\u{1B}[?1048h\u{1B}[1;2H\u{754C}\u{1B}[?1048l".utf8))
        #expect(restore.geometry.cursor?.column == 1)
    }

    @Test("inactive screens resize their grids and saved cursors from either active side")
    func inactiveScreenResizeClampsSavedCursors() throws {
        // Intent: resize updates both retained grids and each grid's saved cursor locally -- the
        //   primary's follows its text through the reflow, the alternate's only clamps.
        // Why it exists: switching which screen is live must not decide which state gets resized.
        // Scenario: each screen takes a save on a wide tail before it becomes inactive and shrinks.
        var primaryInactive = try #require(Terminal(columns: 5, rows: 3))
        primaryInactive.feed(Array("\u{1B}[1;4H\u{754C}\u{1B}[1;5H\u{1B}7\u{1B}[?1047h".utf8))
        primaryInactive.feed(Array("\u{1B}[3;1H\u{1B}7".utf8))
        primaryInactive.resize(columns: 4, rows: 3)
        primaryInactive.feed(Array("\u{1B}[?1047l\u{1B}8".utf8))
        // The save was on the glyph's tail, which the narrowing wrapped onto its own row; the
        // restore follows it there and steps off the tail onto the head.
        #expect(primaryInactive.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        #expect(primaryInactive.cell(row: 0, column: 0)?.scalars == ["\u{754C}"])
        #expect(primaryInactive.cell(row: 0, column: 0)?.kind != .wideTail)

        var alternateInactive = try #require(Terminal(columns: 5, rows: 3))
        alternateInactive.feed(Array("\u{1B}[?1047h\u{1B}[1;4H\u{754C}\u{1B}[1;5H\u{1B}7\u{1B}[?1047l".utf8))
        alternateInactive.feed(Array("\u{1B}[3;1H\u{1B}7".utf8))
        alternateInactive.resize(columns: 4, rows: 3)
        alternateInactive.feed(Array("\u{1B}[?1047h\u{1B}8".utf8))
        #expect(alternateInactive.geometry.rows.allSatisfy { $0.cells.count == 4 })
        #expect(alternateInactive.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: false))
        #expect(alternateInactive.cell(row: 0, column: 3)?.kind != .wideTail)
    }

    @Test("primary projections and active row structure select screens explicitly")
    func projectionRoutesStayDistinctAfterAlternateExit() throws {
        // Intent: recovery reads primary rows while diagnostics always report the live grid.
        // Why it exists: retaining both screens makes the old optional-based projection wrong.
        // Scenario: the primary says PRIMARY while an alternate frame says ALT, then exits.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("PRIMARY\u{1B}[?1047h\u{1B}[HALT".utf8))
        #expect(terminal.primaryHistoryText == "PRIMARY")
        #expect(terminal.primaryHistoryTailText(maxLines: 10, maxChars: 100) == "PRIMARY")
        #expect(terminal.rowStructure.suffix(2).first?.contentEnd == 3)

        terminal.feed(Array("\u{1B}[?1047l".utf8))
        #expect(terminal.primaryHistoryText == "PRIMARY")
        #expect(terminal.primaryHistoryTailText(maxLines: 10, maxChars: 100) == "PRIMARY")
        #expect(terminal.rowStructure.suffix(2).first?.contentEnd == 4)
    }

    @Test("inactive primary resize is content-equivalent to resizing before alt entry")
    func inactivePrimaryResizeEquivalence() throws {
        var whileAlternate = try makePrimaryResizeSubject()
        var beforeEntry = whileAlternate

        whileAlternate.feed(Array("\u{1B}[?1049h".utf8))
        for dimensions in [(5, 2), (3, 4), (7, 3)] {
            whileAlternate.resize(columns: dimensions.0, rows: dimensions.1)
        }
        whileAlternate.feed(Array("\u{1B}[?1049l".utf8))

        for dimensions in [(5, 2), (3, 4), (7, 3)] {
            beforeEntry.resize(columns: dimensions.0, rows: dimensions.1)
        }
        beforeEntry.feed(Array("\u{1B}[?1049h\u{1B}[?1049l".utf8))

        #expect(primaryContent(of: whileAlternate) == primaryContent(of: beforeEntry))
        #expect(whileAlternate.geometry.cursor == beforeEntry.geometry.cursor)
        expectValidGrid(whileAlternate)
    }

    @Test("RIS selects primary while DECSTR keeps the live alternate")
    func resetsReselectPrimary() throws {
        var hard = try #require(Terminal(columns: 4, rows: 2))
        hard.feed(Array("PRIMARY\u{1B}[?1047hALT\u{1B}c".utf8))
        #expect(hard.screenText == "    \n    ")
        hard.feed(Array("H".utf8))
        #expect(hard.primaryHistoryText.hasSuffix("H"))

        var soft = try #require(Terminal(columns: 4, rows: 2))
        soft.feed(Array("PRIMARY\u{1B}[?1047hALT".utf8))
        let alternate = soft.screenText
        soft.feed(Array("\u{1B}[!p".utf8))
        #expect(soft.screenText == alternate)
        #expect(soft.isAlternateScreenActive)
        soft.feed(Array("S".utf8))
        #expect(soft.screenText != alternate)
        #expect(soft.primaryHistoryText.hasSuffix("S") == false)
    }

    @Test("alternate cursor stays screen-relative over non-empty primary scrollback, across resize")
    func alternateCursorProjectionOverScrollback() throws {
        // Intent: while the alternate screen is active, the projected cursor row is the
        //   screen row, never the primary stream row, even when primary scrollback is
        //   non-empty -- and it survives a resize taken while alternate is still active.
        // Why it exists: the cursor projection is the one place that branches on which
        //   screen is active and computes a *different* row per branch. Every other alt
        //   test asserts cursors only on terminals with empty scrollback, where both
        //   branches agree, so inverting the branch fails nothing today. Inverted, the row
        //   lands outside the viewport and the cursor silently reads nil.
        // Scenario: a session scrolls output into history, then a full-screen program
        //   takes over the alternate screen and the window is resized under it.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8))
        #expect(terminal.scrollbackRowCount > 0)

        terminal.feed(Array("\u{1B}[?1047h".utf8))
        #expect(terminal.scrollbackRowCount > 0)
        terminal.feed(Array("\u{1B}[1;1H".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        terminal.feed(Array("\u{1B}[2;3H".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 2, isPendingWrap: false))

        terminal.resize(columns: 5, rows: 3)
        #expect(terminal.isAlternateScreenActive)
        #expect(terminal.scrollbackRowCount > 0)
        terminal.feed(Array("\u{1B}[3;2H".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 2, column: 1, isPendingWrap: false))

        terminal.feed(Array("\u{1B}[?1047l".utf8))
        #expect(terminal.isAlternateScreenActive == false)
    }

    @Test("alternate-screen state reports true only while a recognized alternate switch is active")
    func alternateScreenStateTransitions() throws {
        // Intent: `isAlternateScreenActive` is false on a fresh terminal, true after 1047/1049
        //   entry, and false again after exit and after RIS. DECSTR and inert modes do not
        //   change the selected screen.
        // Why it exists: TerminalCore asserts this property only through a fixture manifest
        //   field; the only direct false-transition assertions live outside the module, so
        //   the accessor itself is unpinned here.
        // Scenario: a full-screen program is entered and left by every route a child has --
        //   normal exit, a hard reset, and a soft reset.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        #expect(terminal.isAlternateScreenActive == false)
        terminal.feed(Array("PRIMARY\u{1B}[?1047h".utf8))
        #expect(terminal.isAlternateScreenActive)
        terminal.feed(Array("\u{1B}[?1047l".utf8))
        #expect(terminal.isAlternateScreenActive == false)

        var hard = try #require(Terminal(columns: 4, rows: 2))
        hard.feed(Array("PRIMARY\u{1B}[?1049hALT".utf8))
        #expect(hard.isAlternateScreenActive)
        hard.feed(Array("\u{1B}c".utf8))
        #expect(hard.isAlternateScreenActive == false)

        var soft = try #require(Terminal(columns: 4, rows: 2))
        soft.feed(Array("PRIMARY\u{1B}[?1049hALT".utf8))
        soft.feed(Array("\u{1B}[!p".utf8))
        #expect(soft.isAlternateScreenActive)

        for sequence in ["\u{1B}[?2047h", "\u{1B}[?2047l", "\u{1B}[?1047$h"] {
            var inert = try #require(Terminal(columns: 3, rows: 2))
            inert.feed(Array(("AB" + sequence).utf8))
            #expect(inert.isAlternateScreenActive == false)
        }
    }

    @Test("alternate-screen sequences are chunk invariant and participate in equality")
    func chunkInvarianceAndEquality() throws {
        let bytes = Array("PRIMARY\u{1B}[?1049hALT\u{1B}[?1049hZ\u{1B}[?1049l".utf8)
        var whole = try #require(Terminal(columns: 5, rows: 3))
        whole.feed(bytes)
        var bytewise = try #require(Terminal(columns: 5, rows: 3))
        for byte in bytes {
            bytewise.feed([byte])
        }
        #expect(whole == bytewise)

        var left = try #require(Terminal(columns: 5, rows: 3))
        var right = left
        left.feed(Array("\u{1B}[?1047hA".utf8))
        right.feed(Array("\u{1B}[?1047hB".utf8))
        #expect(left != right)
        expectValidGrid(left)
        expectValidGrid(right)
    }
}

private func makePrimaryResizeSubject() throws -> Terminal {
    var terminal = try #require(Terminal(columns: 8, rows: 3))
    terminal.feed(Array("one \u{754C} two\r\nthree\r\nfour\r\nfive".utf8))
    return terminal
}

private func primaryContent(of terminal: Terminal) -> PrimaryContent {
    let scrollback = (0..<terminal.scrollbackRowCount).compactMap(terminal.scrollbackRow(at:))
    let viewport = terminal.geometry.rows.indices.map { row in
        (0..<terminal.geometry.columns).compactMap { column in
            terminal.cell(row: row, column: column)
        }
    }
    return PrimaryContent(
        history: terminal.primaryHistoryText,
        scrollback: scrollback,
        viewport: viewport,
        wraps: terminal.geometry.rows.map(\.isSoftWrapped)
    )
}

private struct PrimaryContent: Equatable {
    var history: String
    var scrollback: [TerminalScrollbackRow]
    var viewport: [[TerminalCell]]
    var wraps: [Bool]
}
