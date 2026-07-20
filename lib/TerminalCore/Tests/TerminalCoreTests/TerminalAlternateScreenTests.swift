// Alternate-screen mode, isolation, projection, resize, and reset proofs.
import Testing

@testable import TerminalCore

/// Pins the alternate screen as transient grid state over shared terminal control state.
struct TerminalAlternateScreenTests {
    @Test("1047 switches grids, clears on every entry, and carries the live cursor on exit")
    func mode1047SwitchesAndClears() throws {
        var terminal = try #require(Terminal(columns: 5, rows: 2))
        terminal.feed(Array("PRIMARY".utf8))
        let primary = primaryContent(of: terminal)

        terminal.feed(Array("\u{1B}[2;3H\u{1B}[31;44;1m\u{1B}[?1047h".utf8))

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

        terminal.feed(Array("ALT\u{1B}[?1047h".utf8))
        #expect(terminal.screenText == "     \n     ")
        terminal.feed(Array("\u{1B}[1;5HZ\u{1B}[?1047l".utf8))

        #expect(primaryContent(of: terminal) == primary)
        #expect(terminal.screenText == "PRIMA\nRY   ")
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 4, isPendingWrap: false))
        expectValidGrid(terminal)
    }

    @Test("1049 saves before entry and restores after exit, including redundant operations")
    func mode1049OrderingAndRedundantOperations() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("AB\u{1B}[?1049h".utf8))
        #expect(terminal.geometry.cursor.isPendingWrap == false)

        terminal.feed(Array("\u{1B}[1;3HX\u{1B}[?1049h".utf8))
        #expect(terminal.screenText == "    \n    ")
        terminal.feed(Array("\u{1B}[2;1H\u{1B}[?1049l".utf8))

        #expect(terminal.screenText == "AB  \n    ")
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: false))

        terminal.feed(Array("\u{1B}[2;4H\u{1B}[?1048h\u{1B}[1;1H\u{1B}[?1049l".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 3, isPendingWrap: false))

        var pending = try #require(Terminal(columns: 2, rows: 2))
        pending.feed(Array("AB\u{1B}[?1049h\u{1B}[?1049l".utf8))
        #expect(pending.geometry.cursor.isPendingWrap)
        pending.feed(Array("X".utf8))
        #expect(pending.screenText == "AB\nX ")
    }

    @Test("recognized switches clear pending wrap and cluster attachment while mode 47 stays inert")
    func switchSideStateAndUnsupportedMode() throws {
        for sequence in [
            "\u{1B}[?47h", "\u{1B}[?47l", "\u{1B}[?2047h", "\u{1B}[?1047$h",
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
        #expect(cluster.cell(row: 0, column: 0)?.scalars == ["A", "\u{200D}"])
    }

    @Test("screen switches preserve shared modes, tabs, margins, REP memory, pen, and saved slot")
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
        #expect(tabs.geometry.cursor.column == 3)

        var autoWrap = try #require(Terminal(columns: 3, rows: 2))
        autoWrap.feed(Array("\u{1B}[?7l\u{1B}[?1047hABCD".utf8))
        #expect(autoWrap.screenText == "ABD\n   ")

        var marginsAndOrigin = try #require(Terminal(columns: 5, rows: 4))
        marginsAndOrigin.feed(Array("\u{1B}[2;3r\u{1B}[?6h\u{1B}[?1047h\u{1B}[1;1H".utf8))
        #expect(marginsAndOrigin.geometry.cursor.row == 1)

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

        terminal.feed(Array("\u{1B}[?1047h123456789012".utf8))
        #expect(terminal.scrollbackRowCount == history.count)
        #expect((0..<terminal.scrollbackRowCount).compactMap(terminal.scrollbackRow(at:)) == history)
        terminal.feed(Array("\u{1B}[?1047l".utf8))
        #expect(primaryContent(of: terminal) == primary)

        terminal.feed(Array("\u{1B}[?1047h\u{1B}[3J".utf8))
        #expect(terminal.scrollbackRowCount == 0)
        terminal.feed(Array("\u{1B}[?1047l".utf8))
        expectValidGrid(terminal)
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
        #expect(terminal.geometry.cursor.row == 0)

        terminal.feed(Array("\u{1B}[?1047l\u{1B}[?1048l".utf8))
        #expect(terminal.geometry.cursor.column == 1)

        var restore = try #require(Terminal(columns: 4, rows: 2))
        restore.moveCursor(row: 0, column: 2)
        restore.feed(Array("\u{1B}[?1048h\u{1B}[1;2H\u{754C}\u{1B}[?1048l".utf8))
        #expect(restore.geometry.cursor.column == 1)
    }

    @Test("inactive primary resize is content-equivalent to resizing before alt entry")
    func inactivePrimaryResizeEquivalence() throws {
        var whileAlternate = try makePrimaryResizeSubject()
        var beforeEntry = whileAlternate

        whileAlternate.feed(Array("\u{1B}[?1047hALT".utf8))
        for dimensions in [(5, 2), (3, 4), (7, 3)] {
            whileAlternate.resize(columns: dimensions.0, rows: dimensions.1)
        }
        whileAlternate.feed(Array("\u{1B}[?1047l".utf8))

        for dimensions in [(5, 2), (3, 4), (7, 3)] {
            beforeEntry.resize(columns: dimensions.0, rows: dimensions.1)
        }
        beforeEntry.feed(Array("\u{1B}[?1047h\u{1B}[?1047l".utf8))

        #expect(primaryContent(of: whileAlternate) == primaryContent(of: beforeEntry))
        expectValidGrid(whileAlternate)
    }

    @Test("RIS and DECSTR leave the primary screen selected")
    func resetsReselectPrimary() throws {
        var hard = try #require(Terminal(columns: 4, rows: 2))
        hard.feed(Array("PRIMARY\u{1B}[?1047hALT\u{1B}c".utf8))
        #expect(hard.screenText == "    \n    ")
        hard.feed(Array("H".utf8))
        #expect(hard.primaryHistoryText.hasSuffix("H"))

        var soft = try #require(Terminal(columns: 4, rows: 2))
        soft.feed(Array("PRIMARY\u{1B}[?1047hALT\u{1B}[!p".utf8))
        #expect(soft.screenText == "PRIM\nARY ")
        soft.feed(Array("S".utf8))
        #expect(soft.primaryHistoryText.hasSuffix("S"))
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
