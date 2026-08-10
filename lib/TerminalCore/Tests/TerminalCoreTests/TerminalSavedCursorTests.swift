// Verifies the single saved-cursor slot and every sequence that snapshots or restores it.
import Testing

@testable import TerminalCore

/// Pins saved cursor state to position, pen, pending wrap, and origin mode.
struct TerminalSavedCursorTests {
    @Test("DECSC and DECRC round-trip the full saved cursor slot repeatably")
    func escapeSaveRestoreRoundTrip() throws {
        // Intent: verify the saved slot restores all four promised fields and is
        //   not consumed by a restore.
        // Why it exists: position-only implementations silently lose pen, origin,
        //   or the pending-wrap phantom that changes the next printable action.
        // Scenario: a full-screen application saves a styled bottom-margin cursor,
        //   draws elsewhere, then restores the same state more than once.
        var terminal = try #require(Terminal(columns: 5, rows: 5))
        terminal.feed(Array("\u{1B}[2;4r\u{1B}[?6h\u{1B}[1;31m\u{1B}[3;5HA\u{1B}7".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 3, column: 4, isPendingWrap: true))

        terminal.feed(Array("\u{1B}[?6l\u{1B}[m\u{1B}[5;1H\u{1B}8".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 3, column: 4, isPendingWrap: true))
        #expect(terminal.currentStyle == TerminalStyle(foreground: .indexed(1), bold: true))

        terminal.feed(Array("\u{1B}[m\u{1B}[1;1H\u{1B}8".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 3, column: 4, isPendingWrap: true))
        #expect(terminal.currentStyle == TerminalStyle(foreground: .indexed(1), bold: true))

        terminal.feed(Array("B".utf8))
        #expect(terminal.geometry.cursor?.row == 3)
        #expect(terminal.geometry.cursor?.column == 1)
        #expect(terminal.cell(row: 3, column: 0)?.scalars == ["B"])
        expectValidGrid(terminal)
    }

    @Test("saving is a pure snapshot that preserves pending wrap and cluster attachment")
    func savePreservesPrintSideState() throws {
        var pending = try #require(Terminal(columns: 2, rows: 2))
        pending.feed(Array("AB\u{1B}7C".utf8))
        #expect(pending.screenText == "AB\nC ")

        var cluster = try #require(Terminal(columns: 4, rows: 1))
        cluster.feed(Array("A\u{200D}\u{1B}[s\u{0301}".utf8))
        #expect(cluster.cell(row: 0, column: 0)?.scalars == ["A", "\u{200D}", "\u{0301}"])
    }

    @Test("CSI and DEC private aliases overwrite and restore the same slot")
    func saveRestoreAliasesAndOverwrite() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("\u{1B}[2;2H\u{1B}[s\u{1B}[3;3H\u{1B}[?1048h\u{1B}[1;1H".utf8))

        terminal.feed(Array("\u{1B}[u".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 2, column: 2, isPendingWrap: false))
        terminal.feed(Array("\u{1B}[1;1H\u{1B}[?1048l".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 2, column: 2, isPendingWrap: false))

        for sequence in ["\u{1B}[1s", "\u{1B}[1u"] {
            var pending = try #require(Terminal(columns: 2, rows: 2))
            pending.feed(Array("AB\u{200D}".utf8))
            let expected = pending
            pending.feed(Array(sequence.utf8))
            #expect(pending == expected)
        }
    }

    @Test("saved cursor contents participate in terminal equality")
    func savedCursorAffectsEquality() throws {
        var saved = try #require(Terminal(columns: 5, rows: 2))
        saved.moveCursor(row: 1, column: 2)
        saved.feed(Array("\u{1B}7".utf8))
        saved.moveCursor(row: 0, column: 0)
        let baseline = try #require(Terminal(columns: 5, rows: 2))

        #expect(saved != baseline)
    }

    @Test("restore before save applies the initial home cursor and default pen")
    func restoreBeforeSaveUsesDefaults() throws {
        var terminal = try #require(Terminal(columns: 5, rows: 5))
        terminal.feed(Array("\u{1B}[2;4r\u{1B}[?6h\u{1B}[1;31m\u{1B}[3;3H\u{1B}8".utf8))

        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
        #expect(terminal.currentStyle == TerminalStyle())
        terminal.feed(Array("\u{1B}[1;1H".utf8))
        #expect(terminal.geometry.cursor?.row == 0)
    }

    @Test("restore reclamps saved state and re-arms pending wrap only at an active edge")
    func restoreClampAndPendingTripleGate() throws {
        var terminal = try #require(Terminal(columns: 5, rows: 6))
        terminal.feed(Array("\u{1B}[2;5r\u{1B}[?6h\u{1B}[4;5HA\u{1B}7".utf8))

        terminal.feed(Array("\u{1B}[2;3r\u{1B}8".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 2, column: 4, isPendingWrap: true))

        terminal.feed(Array("\u{1B}[?7l\u{1B}8".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 2, column: 4, isPendingWrap: false))

        terminal.feed(Array("\u{1B}[?7h".utf8))
        terminal.resize(columns: 6, rows: 6)
        terminal.feed(Array("\u{1B}8".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 4, column: 4, isPendingWrap: false))

        terminal.resize(columns: 4, rows: 6)
        terminal.feed(Array("\u{1B}8".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 4, column: 3, isPendingWrap: true))
    }

    @Test("DEC mode parameters apply left-to-right around save and restore aliases")
    func privateModeOrderingAndChunkInvariance() throws {
        let bytes = Array("\u{1B}[2;4r\u{1B}[3;3H\u{1B}[?6;1048h\u{1B}[?6l\u{1B}[?1048l".utf8)
        var oneChunk = try #require(Terminal(columns: 5, rows: 5))
        oneChunk.feed(bytes)
        var bytewise = try #require(Terminal(columns: 5, rows: 5))
        for byte in bytes {
            bytewise.feed([byte])
        }

        #expect(oneChunk == bytewise)
        #expect(oneChunk.geometry.cursor == TerminalCursor(row: 1, column: 0, isPendingWrap: false))
        oneChunk.feed(Array("\u{1B}[1;1H".utf8))
        #expect(oneChunk.geometry.cursor?.row == 1)
    }

    @Test(
        "tab and save controls are invariant across every byte boundary",
        arguments: [
            "\u{1B}[4G\u{1B}H\r\t\u{1B}[g",
            "\u{1B}[2;3H\u{1B}7\u{1B}[1;1H\u{1B}8",
            "\u{1B}[2;3H\u{1B}[s\u{1B}[1;1H\u{1B}[u",
            "\u{1B}[2;3H\u{1B}[?1048h\u{1B}[1;1H\u{1B}[?1048l",
        ]
    )
    func dispatchChunkInvariance(sequence: String) throws {
        let bytes = Array(sequence.utf8)
        var oneChunk = try #require(Terminal(columns: 10, rows: 3))
        oneChunk.feed(bytes)
        var bytewise = try #require(Terminal(columns: 10, rows: 3))
        for byte in bytes {
            bytewise.feed([byte])
        }

        #expect(oneChunk == bytewise)
    }
}
