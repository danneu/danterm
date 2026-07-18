// Proves vertical margins, scrolling controls, wrap seams, and resize reset behavior.
import Testing

@testable import TerminalCore

/// Locks region-aware scrolling to deterministic grid, history, and side-state behavior.
struct TerminalScrollRegionTests {
    @Test("DECSTBM normalizes bounds, homes the cursor, and rejects excess parameters")
    func decstbmNormalizationAndArity() throws {
        // Intent: pin every DECSTBM clamping row and its cursor-home side effect.
        // Why it exists: an invalid region must normalize to full-screen while
        //   excess parameters must leave even pending attachment state untouched.
        // Scenario: a TUI establishes valid, partial, defaulted, inverted, and
        //   out-of-bounds margins before requesting a cursor-independent scroll.
        let fixtures: [(sequence: String, screen: String, scrollback: Int)] = [
            ("\u{1B}[2;3r", "A \nC \n  \nD ", 0),
            ("\u{1B}[2r", "A \nC \nD \n  ", 0),
            ("\u{1B}[;3r", "B \nC \n  \nD ", 0),
            ("\u{1B}[r", "B \nC \nD \n  ", 1),
            ("\u{1B}[0;0r", "B \nC \nD \n  ", 1),
            ("\u{1B}[5;2r", "B \nC \nD \n  ", 1),
            ("\u{1B}[100;105r", "B \nC \nD \n  ", 1),
        ]

        for fixture in fixtures {
            var terminal = try labeledTerminal(columns: 2, rows: 4)
            terminal.moveCursor(row: 3, column: 1)

            terminal.feed(Array(fixture.sequence.utf8))

            #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))
            terminal.feed(Array("\u{1B}[S".utf8))
            #expect(terminal.screenText == fixture.screen)
            #expect(terminal.scrollbackRowCount == fixture.scrollback)
        }

        var invalid = try #require(Terminal(columns: 2, rows: 2))
        invalid.feed(Array("AB\u{200D}".utf8))
        let expected = invalid
        invalid.feed(Array("\u{1B}[1;2;3r".utf8))
        #expect(invalid == expected)
    }

    @Test("active region state participates in terminal equality")
    func regionParticipatesInEquality() throws {
        let plain = try #require(Terminal(columns: 3, rows: 3))
        var bounded = plain

        bounded.feed(Array("\u{1B}[2;3r".utf8))

        #expect(bounded != plain)
    }

    @Test("LF walks outside margins and scrolls only at the bottom margin")
    func lineFeedRegionMatrix() throws {
        var terminal = try labeledTerminal(columns: 2, rows: 4)
        terminal.feed(Array("\u{1B}[2;3r\u{1B}[1;2H\n".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
        #expect(terminal.screenText == "A \nB \nC \nD ")

        terminal.feed(Array("\u{1B}[3;2H\n".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 2, column: 1, isPendingWrap: false))
        #expect(terminal.screenText == "A \nC \n  \nD ")
        #expect(terminal.scrollbackRowCount == 0)

        let beforeBottom = terminal
        terminal.feed(Array("\u{1B}[4;2H\n".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 3, column: 1, isPendingWrap: false))
        var expectedBottom = beforeBottom
        expectedBottom.moveCursor(row: 3, column: 1)
        #expect(terminal == expectedBottom)
    }

    @Test("IND, NEL, and RI honor vertical margins and cursor columns")
    func escapeIndexControls() throws {
        var index = try labeledTerminal(columns: 3, rows: 4)
        index.feed(Array("\u{1B}[2;3r\u{1B}[3;2H\u{1B}D".utf8))
        #expect(index.screenText == "A  \nC  \n   \nD  ")
        #expect(index.geometry.cursor == TerminalCursor(row: 2, column: 1, isPendingWrap: false))
        #expect(index.scrollbackRowCount == 0)

        var nextLine = try labeledTerminal(columns: 3, rows: 4)
        nextLine.feed(Array("\u{1B}[2;3r\u{1B}[3;3H\u{1B}E".utf8))
        #expect(nextLine.screenText == "A  \nC  \n   \nD  ")
        #expect(nextLine.geometry.cursor == TerminalCursor(row: 2, column: 0, isPendingWrap: false))

        var reverse = try labeledTerminal(columns: 3, rows: 4)
        reverse.feed(Array("\u{1B}[2;3r\u{1B}[2;2H\u{1B}M".utf8))
        #expect(reverse.screenText == "A  \n   \nB  \nD  ")
        #expect(reverse.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
        #expect(reverse.scrollbackRowCount == 0)

        reverse.feed(Array("\u{1B}[4;2H\u{1B}M".utf8))
        #expect(reverse.geometry.cursor.row == 2)
        reverse.feed(Array("\u{1B}[1;2H\u{1B}M".utf8))
        #expect(reverse.geometry.cursor.row == 0)
    }

    @Test("SU and SD clamp counts, ignore cursor location, and apply strict history policy")
    func scrollUpDownSemantics() throws {
        // Intent: prove scroll counts clamp to the region and history receives
        //   only rows vacated by a full-screen upward scroll.
        // Why it exists: bounded TUI repaint regions must not pollute scrollback,
        //   while a large full-screen SU must retain source rows rather than blanks.
        // Scenario: a screen is cleared with CSI 100 S, then a footer-bounded TUI
        //   scrolls the same number of rows in both directions with its cursor outside.
        var full = try labeledTerminal(columns: 2, rows: 3)
        full.moveCursor(row: 1, column: 1)
        let originalCursor = full.geometry.cursor

        full.feed(Array("\u{1B}[100S".utf8))

        #expect(full.screenText == "  \n  \n  ")
        #expect(full.geometry.cursor == originalCursor)
        #expect(full.scrollbackRowCount == 3)
        #expect(full.scrollbackRow(at: 0)?.cells[0].scalars == ["A"])
        #expect(full.scrollbackRow(at: 1)?.cells[0].scalars == ["B"])
        #expect(full.scrollbackRow(at: 2)?.cells[0].scalars == ["C"])

        var boundedUp = try labeledTerminal(columns: 2, rows: 4)
        boundedUp.feed(Array("\u{1B}[2;3r\u{1B}[4;2H\u{1B}[2S".utf8))
        #expect(boundedUp.screenText == "A \n  \n  \nD ")
        #expect(boundedUp.geometry.cursor == TerminalCursor(row: 3, column: 1, isPendingWrap: false))
        #expect(boundedUp.scrollbackRowCount == 0)

        var boundedDown = try labeledTerminal(columns: 2, rows: 4)
        boundedDown.feed(Array("\u{1B}[2;3r\u{1B}[4;2H\u{1B}[2T".utf8))
        #expect(boundedDown.screenText == "A \n  \n  \nD ")
        #expect(boundedDown.geometry.cursor == TerminalCursor(row: 3, column: 1, isPendingWrap: false))
        #expect(boundedDown.scrollbackRowCount == 0)
    }

    @Test("scroll fills use background colors without carrying attributes")
    func scrollUsesBackgroundColorErase() throws {
        let eraseStyle = TerminalStyle(foreground: .indexed(1), background: .indexed(4))
        var terminal = try labeledTerminal(columns: 2, rows: 3)
        terminal.feed(Array("\u{1B}[2;3r\u{1B}[1;2;3;4;7;8;9;31;44m\u{1B}[T".utf8))

        for column in 0..<2 {
            #expect(terminal.cell(row: 1, column: column)?.kind == .padding)
            #expect(terminal.cell(row: 1, column: column)?.style == eraseStyle)
        }
        #expect(terminal.cell(row: 2, column: 0)?.scalars == ["B"])
        expectValidGrid(terminal)
    }

    @Test("vertical scrolls sever displaced wrap claims at every stream seam")
    func verticalScrollSeversWrapSeams() throws {
        // Intent: sever soft-wrap identity whenever its original continuation is
        //   destroyed or displaced across viewport and scrollback boundaries.
        // Why it exists: stale claims merge unrelated rows in fullHistoryText, and
        //   stale spacer heads violate the structural wide-cell contract.
        // Scenario: bounded SU and SD cut logical lines above, below, and across
        //   the retained-history seam used by a scrolled shell transcript.
        var aboveRegion = try #require(Terminal(columns: 3, rows: 4))
        aboveRegion.feed(Array("ABCDEFG".utf8))
        #expect(aboveRegion.geometry.rows[0].isSoftWrapped)
        aboveRegion.feed(Array("\u{1B}[2;3r\u{1B}[S".utf8))
        #expect(aboveRegion.geometry.rows[0].isSoftWrapped == false)
        #expect(aboveRegion.fullHistoryText == "ABC\nG")
        expectValidGrid(aboveRegion)

        var belowRegion = try #require(Terminal(columns: 3, rows: 4))
        belowRegion.feed(Array("ABCDEFGHIJ".utf8))
        belowRegion.feed(Array("\u{1B}[2;3r\u{1B}[S".utf8))
        #expect(belowRegion.geometry.rows[1].isSoftWrapped == false)
        #expect(belowRegion.fullHistoryText == "ABC\nGHI\n\nJ")
        expectValidGrid(belowRegion)

        var historySeam = try #require(Terminal(columns: 3, rows: 3))
        historySeam.feed(Array("ABCDEFGHIJ".utf8))
        #expect(historySeam.scrollbackRow(at: 0)?.isSoftWrapped == true)
        historySeam.feed(Array("\u{1B}[1;2r\u{1B}[S".utf8))
        #expect(historySeam.scrollbackRow(at: 0)?.isSoftWrapped == false)
        #expect(historySeam.fullHistoryText == "ABC\nGHI\n\nJ")
        expectValidGrid(historySeam)

        var insertedAtTop = try #require(Terminal(columns: 3, rows: 3))
        insertedAtTop.feed(Array("ABCDEFGHIJ".utf8))
        insertedAtTop.feed(Array("\u{1B}[1;2r\u{1B}[T".utf8))
        #expect(insertedAtTop.scrollbackRow(at: 0)?.isSoftWrapped == false)
        #expect(insertedAtTop.fullHistoryText == "ABC\n\nDEF\nJ")
        expectValidGrid(insertedAtTop)
    }

    @Test("soft and wide wraps remain joined while scrolling at the bottom margin")
    func marginWrapPreservesLogicalLine() throws {
        // Intent: keep a wrap initiated at the bottom margin attached to the
        //   newly revealed continuation row after the region scrolls.
        // Why it exists: ordinary seam repair severs the moved bottom row, but
        //   printing is simultaneously creating a new legitimate continuation.
        // Scenario: narrow text, an initially wide glyph, and a VS16 width upgrade
        //   each wrap from the final column of a sticky-footer region.
        var narrow = try #require(Terminal(columns: 3, rows: 4))
        narrow.feed(Array("\u{1B}[2;3r\u{1B}[3;1HXYZQ".utf8))
        #expect(narrow.geometry.rows[1].isSoftWrapped)
        #expect(narrow.fullHistoryText.contains("XYZQ"))
        expectValidGrid(narrow)

        var wide = try #require(Terminal(columns: 3, rows: 4))
        wide.feed(Array("\u{1B}[2;3r\u{1B}[3;3H\u{754C}".utf8))
        #expect(wide.geometry.rows[1].cells[2].kind == .spacerHead)
        #expect(wide.geometry.rows[1].isSoftWrapped)
        #expect(wide.geometry.rows[2].cells[0].kind == .wideHead)
        expectValidGrid(wide)

        var upgraded = try #require(Terminal(columns: 3, rows: 4))
        upgraded.feed(Array("\u{1B}[2;3r\u{1B}[3;3H#\u{FE0F}".utf8))
        #expect(upgraded.geometry.rows[1].cells[2].kind == .spacerHead)
        #expect(upgraded.geometry.rows[1].isSoftWrapped)
        #expect(upgraded.geometry.rows[2].cells[0].kind == .wideHead)
        expectValidGrid(upgraded)
    }

    @Test("valid scroll dispatches clear motion state while invalid arity is bit-identical")
    func dispatchSideStateGate() throws {
        // Intent: apply the slice-wide side-state policy at the dispatch gate.
        // Why it exists: cursor-stationary scrolls can otherwise leak deferred
        //   wrapping or grapheme attachment into unrelated post-scroll content.
        // Scenario: valid and malformed scroll controls arrive while printing is
        //   pending, followed by an unsupported bare ESC final.
        var pending = try #require(Terminal(columns: 2, rows: 2))
        pending.feed(Array("AB".utf8))
        pending.feed(Array("\u{1B}[S".utf8))
        #expect(pending.geometry.cursor.isPendingWrap == false)

        var cluster = try #require(Terminal(columns: 3, rows: 1))
        cluster.feed(Array("A\u{200D}".utf8))
        cluster.feed(Array("\u{1B}[T\u{0301}".utf8))
        #expect(cluster.cell(row: 0, column: 0)?.scalars.isEmpty == true)

        var invalid = try #require(Terminal(columns: 2, rows: 2))
        invalid.feed(Array("AB\u{200D}".utf8))
        let expected = invalid
        invalid.feed(Array("\u{1B}[1;2S".utf8))
        #expect(invalid == expected)

        var unsupported = try #require(Terminal(columns: 2, rows: 2))
        unsupported.feed(Array("AB\u{200D}".utf8))
        let expectedUnsupported = unsupported
        unsupported.feed([0x1B, 0x37])
        #expect(unsupported == expectedUnsupported)
    }

    @Test("actual resize resets the region while same-size resize preserves it")
    func resizeRegionReset() throws {
        var sameSize = try #require(Terminal(columns: 4, rows: 4))
        sameSize.feed(Array("\u{1B}[2;3r".utf8))
        let expected = sameSize
        sameSize.resize(columns: 4, rows: 4)
        #expect(sameSize == expected)
        sameSize.feed(Array("\u{1B}[3;1H\n".utf8))
        #expect(sameSize.geometry.cursor.row == 2)
        #expect(sameSize.scrollbackRowCount == 0)

        var resized = try #require(Terminal(columns: 4, rows: 4))
        resized.feed(Array("\u{1B}[2;3r".utf8))
        resized.resize(columns: 5, rows: 4)
        resized.feed(Array("\u{1B}[4;1H\n".utf8))
        #expect(resized.scrollbackRowCount == 1)
    }

    @Test("ESC index controls are invariant across every chunk split")
    func escapeChunkInvariance() throws {
        let bytes = Array("A\u{1B}[2;3r\u{1B}[3;2H\u{1B}D\u{1B}E\u{1B}MZ".utf8)
        var expected = try #require(Terminal(columns: 3, rows: 4))
        expected.feed(bytes)

        for split in 0...bytes.count {
            var terminal = try #require(Terminal(columns: 3, rows: 4))
            terminal.feed(Array(bytes[..<split]))
            terminal.feed(Array(bytes[split...]))
            #expect(terminal == expected)
        }

        var bytewise = try #require(Terminal(columns: 3, rows: 4))
        for byte in bytes {
            bytewise.feed([byte])
        }
        #expect(bytewise == expected)
    }

    private func labeledTerminal(columns: Int, rows: Int) throws -> Terminal {
        var terminal = try #require(Terminal(columns: columns, rows: rows))
        for row in 0..<rows {
            let label = Unicode.Scalar(65 + row)!
            terminal.feed(Array("\u{1B}[\(row + 1);1H".utf8))
            terminal.feed(String(label).utf8.map { $0 })
        }
        return terminal
    }
}
