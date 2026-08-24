// Verifies hard and soft reset state matrices through public terminal controls.
import Testing

@testable import TerminalCore

/// Locks RIS and DECSTR to their distinct screen, history, cursor, and memory scopes.
struct TerminalResetTests {
    @Test("DECSTR and RIS reset the complete saved-cursor payload")
    func resetSavedCursorPayload() throws {
        // Intent: DECRC after either reset restores every saved field to its initial value.
        // Why it exists: a stale slot can undo reset position, rendition, origin, wrap,
        //   presentation, or charset state even when the live reset state was correct.
        // Scenario: a TUI saves a styled, hidden bar cursor at the margin under origin mode
        //   and DEC graphics, resets, then later restores that slot.
        for reset in ["\u{1B}[!p", "\u{1B}c"] {
            var terminal = try #require(Terminal(columns: 4, rows: 3))
            terminal.feed(Array("\u{1B}[2;3r\u{1B}[?6h\u{1B}[?25l\u{1B}[6 q\u{1B}[31m\u{1B}(0\u{1B}[1;4HX\u{1B}7\(reset)\u{1B}8".utf8))

            #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
            #expect(terminal.currentStyle == TerminalStyle())
            #expect(terminal.presentation == TerminalPresentation(
                isCursorVisible: true,
                cursorShape: .block,
                isCursorBlinking: false,
                isSynchronizedOutputActive: false
            ))

            terminal.feed(Array("\u{1B}[2;3r\u{1B}[1;1Hq".utf8))
            #expect(terminal.cell(row: 0, column: 0)?.scalars == ["q"])
        }
    }

    @Test("DECSTR resets only the live saved-cursor slot")
    func softResetSavedCursorScope() throws {
        // Intent: reset the live slot while preserving the retained screen's distinct slot.
        // Why it exists: screen selection and saved-cursor scope are asymmetric under DECSTR.
        // Scenario: both buffers save distinct positions and styles before one is soft-reset.
        var alternateLive = try #require(Terminal(columns: 6, rows: 3))
        alternateLive.feed(Array("\u{1B}[2;3H\u{1B}[31m\u{1B}[?1049h\u{1B}[3;5H\u{1B}[34m\u{1B}7\u{1B}[!p\u{1B}8".utf8))
        #expect(alternateLive.isAlternateScreenActive)
        #expect(alternateLive.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        #expect(alternateLive.currentStyle == TerminalStyle())
        alternateLive.feed(Array("\u{1B}[?1049l".utf8))
        #expect(alternateLive.geometry.cursor == TerminalCursor(row: 1, column: 2, isPendingWrap: false))
        #expect(alternateLive.currentStyle.foreground == .indexed(1))

        var primaryLive = try #require(Terminal(columns: 6, rows: 3))
        primaryLive.feed(Array("\u{1B}[?1047h\u{1B}[3;5H\u{1B}[34m\u{1B}7\u{1B}[?1047l".utf8))
        primaryLive.feed(Array("\u{1B}[2;3H\u{1B}[31m\u{1B}7\u{1B}[!p\u{1B}8".utf8))
        #expect(primaryLive.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        #expect(primaryLive.currentStyle == TerminalStyle())
        primaryLive.feed(Array("\u{1B}[?1047h\u{1B}8".utf8))
        #expect(primaryLive.geometry.cursor == TerminalCursor(row: 2, column: 4, isPendingWrap: false))
        #expect(primaryLive.currentStyle.foreground == .indexed(4))
    }

    @Test("RIS resets an offscreen alternate saved-cursor slot")
    func hardResetOffscreenSavedCursor() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("\u{1B}[?1047h\u{1B}[3;5H\u{1B}[34m\u{1B}7\u{1B}[?1047l\u{1B}c".utf8))
        terminal.feed(Array("\u{1B}[?1047h\u{1B}8".utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        #expect(terminal.currentStyle == TerminalStyle())
    }

    @Test("DECSTR resets soft state and live saved slot while preserving screen cursor history and REP memory")
    func softResetMatrix() throws {
        // Intent: verify every soft-reset matrix row, including the state that
        //   must survive and the defaults observable only through later input.
        // Why it exists: DECSTR shares defaults with RIS but must not erase,
        //   home the live cursor, discard history, or forget REP.
        // Scenario: a styled full-screen program soft-resets after customizing
        //   margins, modes, tabs, and a saved cursor over retained shell output.
        var terminal = try #require(Terminal(columns: 10, rows: 3))
        terminal.feed(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ12345".utf8))
        terminal.feed(Array("\u{1B}[31m\u{1B}[1\"q\u{1B}7Z\u{200D}\u{1B}[2;3r\u{1B}[4;20h\u{1B}[?6h\u{1B}[?7l\u{1B}[3g\u{1B}H".utf8))
        let screen = terminal.screenText
        let cursor = try #require(terminal.geometry.cursor)
        let history = (0..<terminal.scrollbackRowCount).compactMap(terminal.scrollbackRow(at:))

        terminal.feed(Array("\u{1B}[!p".utf8))

        #expect(terminal.screenText == screen)
        #expect(terminal.geometry.cursor == TerminalCursor(
            row: cursor.row,
            column: cursor.column,
            isPendingWrap: false
        ))
        #expect((0..<terminal.scrollbackRowCount).compactMap(terminal.scrollbackRow(at:)) == history)
        #expect(terminal.currentStyle == TerminalStyle())

        terminal.feed(Array("\u{0301}".utf8))
        #expect(terminal.cell(row: 0, column: 9)?.scalars == ["T", "\u{0301}"])

        var tabProbe = try #require(Terminal(columns: 10, rows: 2))
        tabProbe.feed(Array("\u{1B}[3g\u{1B}[1;4H\u{1B}H\u{1B}[!p\r\t".utf8))
        #expect(tabProbe.geometry.cursor?.column == 3)

        var lineFeedProbe = terminal
        lineFeedProbe.moveCursor(row: 0, column: 4)
        lineFeedProbe.feed(Array("\n".utf8))
        #expect(lineFeedProbe.geometry.cursor?.column == 4)

        var insertProbe = terminal
        insertProbe.moveCursor(row: 0, column: 0)
        insertProbe.feed(Array("X".utf8))
        #expect(insertProbe.cell(row: 0, column: 1)?.scalars == ["L"])

        var autoWrapProbe = terminal
        autoWrapProbe.moveCursor(row: 0, column: 9)
        autoWrapProbe.feed(Array("X".utf8))
        #expect(autoWrapProbe.geometry.cursor?.isPendingWrap == true)

        var regionProbe = terminal
        let historyCount = regionProbe.scrollbackRowCount
        regionProbe.moveCursor(row: 2, column: 0)
        regionProbe.feed(Array("\n".utf8))
        #expect(regionProbe.scrollbackRowCount == historyCount + 1)

        var originProbe = terminal
        originProbe.feed(Array("\u{1B}[2;3r\u{1B}[1;1H".utf8))
        #expect(originProbe.geometry.cursor?.row == 0)

        var slotProbe = terminal
        slotProbe.feed(Array("\u{1B}8".utf8))
        #expect(slotProbe.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        #expect(slotProbe.currentStyle == TerminalStyle())

        var repeatProbe = terminal
        repeatProbe.moveCursor(row: 0, column: 0)
        repeatProbe.feed(Array("\u{1B}[b".utf8))
        #expect(repeatProbe.cell(row: 0, column: 0)?.scalars == ["T", "\u{0301}"])
        expectValidGrid(terminal)
    }

    @Test("RIS restores hard defaults and erases in place without dropping history")
    func hardResetMatrix() throws {
        // Intent: verify hard reset ordering, locality, and the single permitted
        //   history mutation where erased viewport row zero loses its precursor.
        // Why it exists: implementing RIS as viewport replacement or ED would
        //   either lose retained rows, push new history, or erase with stale BCE.
        // Scenario: a colored TUI hard-resets after wrapping shell output into
        //   scrollback while modes, margins, tabs, and a saved cursor are active.
        var terminal = try #require(Terminal(columns: 10, rows: 3))
        terminal.feed(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ12345".utf8))
        let historyCount = terminal.scrollbackRowCount
        let lastHistory = try #require(terminal.scrollbackRow(at: historyCount - 1))
        #expect(lastHistory.isSoftWrapped)

        terminal.feed(Array("\u{1B}[31m\u{1B}[1\"q\u{1B}7\u{1B}[1;4;32;44m\u{1B}[2;3r\u{1B}[4;20h\u{1B}[?6h\u{1B}[?7l\u{1B}[3g\u{1B}H\u{1B}c".utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        #expect(terminal.screenText == "          \n          \n          ")
        #expect(terminal.currentStyle == TerminalStyle())
        #expect(terminal.scrollbackRowCount == historyCount)
        let resetHistory = try #require(terminal.scrollbackRow(at: historyCount - 1))
        #expect(resetHistory.cells == lastHistory.cells)
        #expect(resetHistory.isSoftWrapped == false)
        for row in 0..<3 {
            #expect(terminal.geometry.rows[row].isSoftWrapped == false)
            for column in 0..<10 {
                #expect(terminal.cell(row: row, column: column)?.style == TerminalStyle())
            }
        }

        var repeatProbe = terminal
        let beforeRepeat = repeatProbe
        repeatProbe.feed(Array("\u{1B}[1000b".utf8))
        #expect(repeatProbe == beforeRepeat)

        var tabProbe = terminal
        tabProbe.feed(Array("\t".utf8))
        #expect(tabProbe.geometry.cursor?.column == 8)

        var slotProbe = terminal
        slotProbe.feed(Array("\u{1B}8".utf8))
        #expect(slotProbe.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        #expect(slotProbe.currentStyle == TerminalStyle())

        var insertProbe = terminal
        insertProbe.feed(Array("ABC\u{1B}[1GZ".utf8))
        #expect(insertProbe.screenText.hasPrefix("ZBC"))

        var lineFeedProbe = terminal
        lineFeedProbe.moveCursor(row: 0, column: 4)
        lineFeedProbe.feed(Array("\n".utf8))
        #expect(lineFeedProbe.geometry.cursor?.column == 4)

        var autoWrapProbe = terminal
        autoWrapProbe.moveCursor(row: 0, column: 9)
        autoWrapProbe.feed(Array("X".utf8))
        #expect(autoWrapProbe.geometry.cursor?.isPendingWrap == true)

        var regionProbe = terminal
        regionProbe.moveCursor(row: 2, column: 0)
        regionProbe.feed(Array("\n".utf8))
        #expect(regionProbe.scrollbackRowCount == historyCount + 1)

        var originProbe = terminal
        originProbe.feed(Array("\u{1B}[2;3r\u{1B}[1;1H".utf8))
        #expect(originProbe.geometry.cursor?.row == 0)

        var wideSeam = try #require(Terminal(columns: 3, rows: 2))
        wideSeam.moveCursor(row: 0, column: 2)
        wideSeam.feed(Array("\u{754C}AB".utf8))
        let seamIndex = wideSeam.scrollbackRowCount - 1
        #expect(wideSeam.scrollbackRow(at: seamIndex)?.cells[2].kind == .spacerHead)
        wideSeam.feed(Array("\u{1B}c".utf8))
        #expect(wideSeam.scrollbackRow(at: seamIndex)?.cells[2].kind == .padding)
        #expect(wideSeam.scrollbackRow(at: seamIndex)?.isSoftWrapped == false)
        expectValidGrid(terminal)
        expectValidGrid(wideSeam)
    }

    @Test("RIS preserves compact history and exact byte accounting")
    func hardResetOverCompactHistory() throws {
        // Intent: hard reset can inspect and mutate the history seam without inflating a short row.
        // Why it exists: RIS repairs the predecessor wrap claim directly, so compact storage must
        //   keep that last-column access safe and its cached budget charge exact.
        // Scenario: a short shell line enters a wide pane's history before the application resets.
        var terminal = try #require(Terminal(columns: 10, rows: 1))
        terminal.feed(Array("abc\r\n".utf8))
        let before = terminal.memoryCensus.cellCount

        terminal.feed(Array("\u{1B}c".utf8))

        #expect(terminal.primaryHistoryText == "abc")
        #expect(terminal.memoryCensus.cellCount == before)
        #expect(terminal.scrollbackRowCount == terminal.independentScrollbackRowRecount)
        expectValidGrid(terminal)
    }

    @Test("parameterized DECSTR is inert and reset controls are chunk invariant")
    func resetDispatchAndChunkInvariance() throws {
        var invalid = try #require(Terminal(columns: 3, rows: 2))
        invalid.feed(Array("ABC\u{200D}".utf8))
        let expected = invalid
        invalid.feed(Array("\u{1B}[1!p".utf8))
        #expect(invalid == expected)

        var pending = try #require(Terminal(columns: 3, rows: 2))
        pending.feed(Array("ABC\u{1B}[!p".utf8))
        #expect(pending.geometry.cursor?.isPendingWrap == false)

        var cluster = try #require(Terminal(columns: 3, rows: 1))
        cluster.feed(Array("A\u{200D}\u{1B}[!p\u{0301}".utf8))
        #expect(cluster.cell(row: 0, column: 0)?.scalars == ["A", "\u{200D}", "\u{0301}"])

        let bytes = Array("A\u{0301}\u{1B}[3b\u{1B}[!pB\u{1B}c".utf8)
        var oneChunk = try #require(Terminal(columns: 5, rows: 2))
        oneChunk.feed(bytes)
        var bytewise = try #require(Terminal(columns: 5, rows: 2))
        for byte in bytes {
            bytewise.feed([byte])
        }
        #expect(oneChunk == bytewise)
    }
}
