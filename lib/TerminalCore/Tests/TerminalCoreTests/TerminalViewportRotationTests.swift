// Characterization proofs for the viewport row order and row metadata that a storage-ring
// implementation must preserve. These tests observe only terminal behavior; storage shape and
// allocation claims belong to the benchmark and memory-probe gates.
import Testing

@testable import TerminalCore

/// Pins mixed viewport mutations and the metadata of rows that cross the history seam.
struct TerminalViewportRotationTests {
    @Test("mixed viewport mutations keep rows in logical order")
    func mixedViewportMutations() throws {
        // Intent: one script pins logical row order across every mutation that will share the
        //   ring-backed viewport and across the history seam.
        // Why it exists: a storage rotation can preserve simple LF output while translating a
        //   subregion, resize transfer, alternate swap, or oversized scroll incorrectly.
        // Scenario: a labeled primary grid passes through each operation in sequence, including
        //   a scroll on the alternate screen, before its final damage and state bytes are read.
        var terminal = try labeledTerminal(columns: 6, rows: 6)
        _ = terminal.drainDamage()

        func verify(_ expected: [String], phase: String) {
            #expect(displayedRows(of: terminal) == expected, Comment(rawValue: phase))
            expectValidGrid(terminal, context: Comment(rawValue: phase))
        }

        terminal.feed(Array("\u{1B}[6;1H\n".utf8))
        verify(["A     ", "B     ", "C     ", "D     ", "E     ", "F     ", "      "], phase: "full LF")

        terminal.feed(Array("\u{1B}[2;5r\u{1B}[S".utf8))
        verify(["A     ", "B     ", "D     ", "E     ", "F     ", "      ", "      "], phase: "subregion SU")

        terminal.feed(Array("\u{1B}[r".utf8))
        terminal.feed(Array("\u{1B}[3;1H\u{1B}[L\u{1B}[M".utf8))
        verify(["A     ", "B     ", "D     ", "E     ", "F     ", "      ", "      "], phase: "IL then DL")

        terminal.feed(Array("\u{1B}[2S".utf8))
        verify([
            "A     ", "B     ", "D     ", "E     ", "F     ",
            "      ", "      ", "      ", "      ",
        ], phase: "full SU 2")

        terminal.feed(Array("\u{1B}[T".utf8))
        verify([
            "A     ", "B     ", "D     ", "      ", "E     ",
            "F     ", "      ", "      ", "      ",
        ], phase: "full SD")

        terminal.feed(Array("\u{1B}[1;1H\u{1B}M".utf8))
        verify([
            "A     ", "B     ", "D     ", "      ", "      ",
            "E     ", "F     ", "      ", "      ",
        ], phase: "top RI")

        terminal.resize(columns: 6, rows: 8)
        verify([
            "A     ", "B     ", "D     ", "      ", "      ", "E     ",
            "F     ", "      ", "      ", "      ", "      ",
        ], phase: "resize up")
        terminal.resize(columns: 6, rows: 6)
        verify([
            "A     ", "B     ", "D     ", "      ", "      ",
            "E     ", "F     ", "      ", "      ",
        ], phase: "resize down")

        terminal.feed(Array("\u{1B}[?1049h\u{1B}[6;1HZ\n".utf8))
        verify([
            "A     ", "B     ", "D     ", "      ", "      ",
            "      ", "      ", "Z     ", "      ",
        ], phase: "alternate scroll")
        terminal.feed(Array("\u{1B}[?1049l".utf8))
        verify([
            "A     ", "B     ", "D     ", "      ", "      ",
            "E     ", "F     ", "      ", "      ",
        ], phase: "primary restore")

        terminal.feed(Array("\u{1B}[99S".utf8))
        verify([
            "A     ", "B     ", "D     ", "      ", "      ", "E     ",
            "F     ", "      ", "      ", "      ", "      ", "      ",
            "      ", "      ", "      ",
        ], phase: "oversized SU")

        #expect(terminal.drainDamage() == .full)
        #expect((0..<terminal.scrollbackRowCount).map {
            terminal.scrollbackRow(at: $0)?.isSoftWrapped
        } == [false, false, false, false, false, false, false, false, false])

        let synchronizedRow = "\u{1B}]133;S;mark=none;wrap=hard\u{7}"
        let synchronizedRows = [
            "A", "B", "D", "", "", "E", "F", "", "", "", "", "", "", "", "",
        ].map { $0 + synchronizedRow }.joined(separator: "\r\n")
        // The alternate screen this terminal still retains is replayed through mode 47 -- the one
        // switch that neither saves the cursor nor clears a grid -- and strictly before the
        // primary's own reconstruction, which restores every live mode the replay disturbs.
        let retainedAlternate = "\u{1B}[0m\u{1B}[?47h"
            + "\u{1B}[?6l\u{1B}[?25h\u{1B}[2 q\u{1B}[0;59m\u{1B}[0\"q\u{1B}[1;1H\u{1B}7"
            + "\u{1B}]133;S;charset-saved=BBBB,0,none\u{7}\u{1B}[<u\u{1B}]133;D\u{7}"
            + "\u{1B}[4l\u{1B}[?6l\u{1B}[?7h\u{1B}[r\u{1B}[H"
            + synchronizedRow + "\u{1B}[0;59m\u{1B}[0\"q\r\n"
            + ["", "", "", "Z", ""].map { $0 + synchronizedRow }.joined(separator: "\r\n")
            + "\u{1B}[?47l"
        let expectedSynchronization = "\u{1B}c\u{1B}[3J\u{1B}]133;S;redraw=0\u{7}\u{1B}[0;59m\u{1B}[0\"q"
            + synchronizedRows
            + retainedAlternate
            + "\u{1B}[3g\u{1B}[1;1H\u{1B}H\u{1B}[r\u{1B}[?6l\u{1B}[?25h\u{1B}[2 q"
            + "\u{1B}[0;59m\u{1B}[0\"q\u{1B}[1;1H\u{1B}7"
            + "\u{1B}]133;S;charset-saved=BBBB,0,none\u{7}\u{1B}[4l\u{1B}[20l\u{1B}>"
            + "\u{1B}[?1l\u{1B}[?6l\u{1B}[?7h\u{1B}[?12l\u{1B}[?25h\u{1B}[?1000l"
            + "\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1004l\u{1B}[?1006l\u{1B}[?1007h\u{1B}[?2004l"
            + "\u{1B}[?2026l\u{1B}[2 q\u{1B}[<u\u{1B}[0;59m\u{1B}[0\"q\u{1B}]8;;\u{7}"
            + "\u{1B}[1;1H\u{1B}]133;D\u{7}" + synchronizedRow
            + "\u{1B}]133;S;redraw=1\u{7}\u{1B}]133;S;repeat=none\u{7}"
            + "\u{1B}]133;S;repeat-add=1:5a\u{7}\u{1B}]133;S;cluster=none\u{7}"
            + "\u{1B}]133;S;charset=BBBB,0,none\u{7}"
        #expect(terminal.stateSynchronization.bytes == Array(expectedSynchronization.utf8))
    }

    @Test("a whole-viewport scroll replaces every evicted-row field with a BCE blank", arguments: [false, true])
    func wholeViewportScrollBlanksEvictedRow(shared: Bool) throws {
        // Intent: a row vacated by a whole-viewport scroll keeps only BCE style on default cells.
        // Why it exists: recycling will reuse the evicted top row, whose old style, link, wrap,
        //   provenance, and prompt mark must not leak into the new bottom row.
        // Scenario: a linked, styled prompt row ends in a wide wrap, then scrolls under a BCE
        //   pen with and without a retained terminal copy sharing its cell buffer.
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array((
            "\u{1B}]133;A;redraw=1\u{7}\u{1B}[31m"
                + "\u{1B}]8;id=top;https://example.test\u{7}AB"
                + "\u{1B}[1;6H\u{754C}\u{1B}]8;;\u{7}"
                + "\u{1B}]133;D\u{7}"
                + "\u{1B}[48;5;17m"
        ).utf8))
        #expect(terminal.geometry.rows[0].isSoftWrapped)
        #expect(terminal.semanticPromptRowsForTesting[0].stamp == .prompt)
        #expect(terminal.cell(row: 0, column: 0)?.hyperlink?.uri == "https://example.test")
        #expect(terminal.cell(row: 0, column: 0)?.style.foreground == .indexed(1))
        #expect(terminal.cell(row: 0, column: 5)?.kind == .spacerHead)
        #expect(terminal.cell(row: 1, column: 0)?.kind == .wideHead)
        #expect(terminal.rowStructure[0].marginCellKind == .spacerHead)

        let retainedCopy = shared ? terminal : nil
        terminal.feed(Array("\u{1B}[3;1H\n".utf8))

        let blank = TerminalCell(
            kind: .padding,
            scalars: .empty,
            style: TerminalStyle(foreground: .indexed(1), background: .indexed(17))
        )
        for column in 0..<6 {
            #expect(terminal.cell(row: 2, column: column) == blank)
        }
        let bottomStructure = try #require(terminal.rowStructure.last)
        #expect(bottomStructure.isRetained == false)
        #expect(bottomStructure.isSoftWrapped == false)
        #expect(bottomStructure.contentEnd == 0)
        #expect(bottomStructure.staleWrapClaim == false)
        #expect(terminal.semanticPromptRowsForTesting[2] == TerminalSemanticPromptRowSnapshot(
            stamp: .none,
            isSoftWrapped: false,
            isEmpty: true
        ))
        expectValidGrid(terminal)

        if let retainedCopy {
            #expect(retainedCopy.geometry.rows[0].isSoftWrapped)
            #expect(retainedCopy.semanticPromptRowsForTesting[0].stamp == .prompt)
            #expect(retainedCopy.cell(row: 0, column: 0)?.scalars == ["A"])
            #expect(retainedCopy.cell(row: 0, column: 0)?.hyperlink?.uri == "https://example.test")
            #expect(retainedCopy.cell(row: 0, column: 5)?.kind == .spacerHead)
            #expect(retainedCopy.cell(row: 1, column: 0)?.kind == .wideHead)
        }
    }

    @Test("multi-row SU preserves history order and a soft wrap across the history seam")
    func multirowScrollPreservesHistorySeam() throws {
        // Intent: an `SU` amount greater than one admits rows oldest-first and keeps the last
        //   admitted row joined to its surviving follower.
        // Why it exists: rotating several rows at once can reverse the admitted prefix or sever
        //   the wrap at the cut even when one-row LF remains correct.
        // Scenario: row B wraps into row C, then `SU 2` moves A and B into history while C stays.
        var terminal = try labeledTerminal(columns: 4, rows: 4)
        terminal.feed(Array("\u{1B}[2;4HXY\u{1B}[2S".utf8))

        #expect(displayedRows(of: terminal) == [
            "A   ",
            "B  X|wrap",
            "Y   ",
            "D   ",
            "    ",
            "    ",
        ])
        #expect((0..<terminal.scrollbackRowCount).map {
            terminal.scrollbackRow(at: $0)?.isSoftWrapped
        } == [false, true])
        #expect(terminal.fullHistoryText == "A\nB  XY\nD")
        expectValidGrid(terminal)
    }

    @Test("alternate-screen line advances past the row count leave every row correct")
    func alternateScreenAdvancesPastRowCount() throws {
        // Intent: more line advances than the screen has rows leave the surviving text, its
        //   styles, and the cursor exactly where the pre-rotation shift left them.
        // Why it exists: recycling gives each row a second life, so a wrong rotation direction
        //   or a payload that survives the reset only shows up once every row has been reused.
        // Scenario: a four-row alternate screen prints eight differently coloured lines.
        var terminal = try #require(Terminal(columns: 6, rows: 4))
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        for index in 0..<8 {
            terminal.feed(Array("\u{1B}[3\(index % 6 + 1)mline\(index)".utf8))
            if index < 7 { terminal.feed(Array("\r\n".utf8)) }
        }

        #expect(displayedRows(of: terminal) == ["line4 ", "line5 ", "line6 ", "line7 "])
        #expect((0..<4).map { terminal.cell(row: $0, column: 0)?.style.foreground } == [
            .indexed(5), .indexed(6), .indexed(1), .indexed(2),
        ])
        #expect(terminal.geometry.cursor == TerminalCursor(row: 3, column: 5, isPendingWrap: false))
        expectValidGrid(terminal)
    }

    @Test("every whole-viewport scroll shape moves alternate-screen rows the same way")
    func alternateScreenWholeViewportShapes() throws {
        // Intent: `SU`, `SD`, a top reverse index, whole-viewport `IL`/`DL`, and an oversized
        //   `SU` each land the same rows in the same order on the alternate screen.
        // Why it exists: the alternate screen never pushes to scrollback, so every one of these
        //   shapes reaches the rotation only through the shape of the move.
        // Scenario: one labelled alternate screen passes through each shape in sequence.
        var terminal = try #require(Terminal(columns: 4, rows: 4))
        terminal.feed(Array("\u{1B}[?1049h".utf8))

        func label() {
            for row in 0..<4 {
                terminal.feed(Array("\u{1B}[\(row + 1);1H\(String(Unicode.Scalar(65 + row)!))".utf8))
            }
        }
        label()

        func verify(_ expected: [String], phase: String) {
            #expect(displayedRows(of: terminal) == expected, Comment(rawValue: phase))
            expectValidGrid(terminal, context: Comment(rawValue: phase))
        }

        terminal.feed(Array("\u{1B}[2S".utf8))
        verify(["C   ", "D   ", "    ", "    "], phase: "SU 2")

        terminal.feed(Array("\u{1B}[T".utf8))
        verify(["    ", "C   ", "D   ", "    "], phase: "SD 1")

        terminal.feed(Array("\u{1B}[1;1H\u{1B}M".utf8))
        verify(["    ", "    ", "C   ", "D   "], phase: "top RI")

        terminal.feed(Array("\u{1B}[1;1H\u{1B}[L".utf8))
        verify(["    ", "    ", "    ", "C   "], phase: "whole-viewport IL")

        terminal.feed(Array("\u{1B}[1;1H\u{1B}[M".utf8))
        verify(["    ", "    ", "C   ", "    "], phase: "whole-viewport DL")

        terminal.feed(Array("\u{1B}[9S".utf8))
        verify(["    ", "    ", "    ", "    "], phase: "oversized SU")

        label()
        terminal.feed(Array("\u{1B}[2T".utf8))
        verify(["    ", "    ", "A   ", "B   "], phase: "SD 2")

        terminal.feed(Array("\u{1B}[9T".utf8))
        verify(["    ", "    ", "    ", "    "], phase: "oversized SD")
    }

    @Test("a whole-viewport scroll retains exactly the rows it retains today")
    func wholeViewportScrollRetentionIsUnchanged() throws {
        // Intent: rows leaving the top of the primary screen still land in history, and a
        //   whole-viewport `DL` at row 0 still retains nothing.
        // Why it exists: the rotation is selected by the shape of the move, so it must not
        //   carry the disposal decision with it -- a discarding whole-viewport scroll that
        //   started pushing would invent history no terminal reports.
        // Scenario: two line advances push A and B, then a whole-viewport `DL` discards.
        var terminal = try labeledTerminal(columns: 4, rows: 4)
        terminal.feed(Array("\u{1B}[4;1H\n\n".utf8))

        #expect(terminal.scrollbackRowCount == 2)
        #expect(terminal.fullHistoryText == "A\nB\nC\nD")
        #expect(displayedRows(of: terminal) == ["A   ", "B   ", "C   ", "D   ", "    ", "    "])

        terminal.feed(Array("\u{1B}[1;1H\u{1B}[M".utf8))
        #expect(terminal.scrollbackRowCount == 2)
        #expect(terminal.fullHistoryText == "A\nB\nD")
        #expect(displayedRows(of: terminal) == ["A   ", "B   ", "D   ", "    ", "    ", "    "])
        expectValidGrid(terminal)
    }

    @Test("a downward whole-viewport scroll blanks the row it recycles", arguments: [false, true])
    func wholeViewportScrollDownBlanksRecycledRow(shared: Bool) throws {
        // Intent: the row a downward whole-viewport scroll pushes off the bottom re-enters at
        //   the top holding nothing but the background-erase paint.
        // Why it exists: the downward direction recycles the *last* row, a row the upward path
        //   never touches, and its style, wrap claim and prompt mark must not survive.
        // Scenario: a styled, linked, prompt-marked bottom row is scrolled down under a BCE
        //   pen, with and without a retained terminal copy sharing its cell buffer.
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array((
            "\u{1B}[3;1H\u{1B}]133;A;redraw=1\u{7}\u{1B}[31m"
                + "\u{1B}]8;id=end;https://example.test\u{7}Z\u{754C}\u{1B}]8;;\u{7}"
                + "\u{1B}]133;D\u{7}\u{1B}[48;5;17m"
        ).utf8))
        #expect(terminal.semanticPromptRowsForTesting[2].stamp == .prompt)
        #expect(terminal.cell(row: 2, column: 0)?.hyperlink?.uri == "https://example.test")
        #expect(terminal.cell(row: 2, column: 1)?.kind == .wideHead)

        let retainedCopy = shared ? terminal : nil
        terminal.feed(Array("\u{1B}[T".utf8))

        let blank = TerminalCell(
            kind: .padding,
            scalars: .empty,
            style: TerminalStyle(foreground: .indexed(1), background: .indexed(17))
        )
        for column in 0..<4 {
            #expect(terminal.cell(row: 0, column: column) == blank)
        }
        let topStructure = try #require(terminal.rowStructure.first)
        #expect(topStructure.isSoftWrapped == false)
        #expect(topStructure.contentEnd == 0)
        #expect(topStructure.staleWrapClaim == false)
        #expect(terminal.semanticPromptRowsForTesting[0] == TerminalSemanticPromptRowSnapshot(
            stamp: .none,
            isSoftWrapped: false,
            isEmpty: true
        ))
        expectValidGrid(terminal)

        // The independent oracle for `AR2`: a partial-region scroll still fills from a freshly
        // made blank row, so its vacated row is the value a recycled row has to equal. Sampling
        // fields cannot say that -- only the whole row value can. It has to be the same terminal
        // because a style id is interned per terminal and means nothing across two of them.
        terminal.feed(Array("\u{1B}[2;3r\u{1B}[3;1H\n".utf8))
        #expect(terminal.liveRowForTesting(at: 0) == terminal.liveRowForTesting(at: 2))

        if let retainedCopy {
            #expect(retainedCopy.cell(row: 2, column: 0)?.scalars == ["Z"])
            #expect(retainedCopy.cell(row: 2, column: 0)?.hyperlink?.uri == "https://example.test")
            #expect(retainedCopy.cell(row: 2, column: 1)?.kind == .wideHead)
            #expect(retainedCopy.semanticPromptRowsForTesting[2].stamp == .prompt)
        }
    }

    @Test("a recycled row keeps its cluster arena and none of its clusters")
    func recycledRowReleasesMultiScalarStorage() throws {
        // Intent: after a row carrying multi-scalar clusters scrolls out and back in as a blank,
        //   no reader can tell it from a freshly made blank row, it holds no cluster, and the
        //   arena it kept is what the next cluster printed into it grows in.
        // Why it exists: row equality compares visible cells and ignores a row's private cluster
        //   storage, so an implementation could overwrite every cell, keep every old cluster, and
        //   still look correct. The kept arena is `research/39/H2` AR2, deliberate and priced: a
        //   screen of clusters pays for its arenas once per row slot rather than once per line
        //   printed, and the census's capacity measure is the only reader that can see it.
        // Scenario: an alternate screen prints combining-mark clusters, then scrolls them all
        //   away, against an untouched alternate screen of the same size that never held one.
        var baseline = try #require(Terminal(columns: 6, rows: 3))
        baseline.feed(Array("\u{1B}[?1049h\u{1B}[3S".utf8))

        // A screen scrolled through without ever holding a cluster allocates nothing for one.
        #expect(baseline.memoryCensus.multiScalarAllocationCount == 0)

        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        for row in 0..<3 {
            terminal.feed(Array("\u{1B}[\(row + 1);1He\u{0301}e\u{0301}e\u{0301}".utf8))
        }
        #expect(terminal.memoryCensus.multiScalarCellCount == 9)
        #expect(terminal.memoryCensus.multiScalarAllocationCount == 3)

        terminal.feed(Array("\u{1B}[3S".utf8))

        #expect(terminal.memoryCensus.multiScalarCellCount == 0)
        for row in 0..<3 {
            #expect(terminal.liveRowForTesting(at: row) == baseline.liveRowForTesting(at: row))
        }
        #expect(terminal.memoryCensus.liveClusterStorageBytes > 0)

        // Reprinting a cluster into a recycled row reuses the arena that row kept.
        let recycled = terminal.memoryCensus.multiScalarAllocationCount
        terminal.feed(Array("\u{1B}[1;1He\u{0301}e\u{0301}e\u{0301}".utf8))
        #expect(terminal.memoryCensus.multiScalarCellCount == 3)
        #expect(terminal.memoryCensus.multiScalarAllocationCount == recycled)
        expectValidGrid(terminal)
    }

    @Test("history and a published snapshot are unaffected by later recycling")
    func recyclingLeavesHistoryAndSnapshotsIntact() throws {
        // Intent: rows already admitted to history, and a terminal value copied before a
        //   scroll, keep their content while the live screen recycles rows underneath them.
        // Why it exists: recycling mutates a row in place, and the row it reuses is one history
        //   was just handed -- I5 fails silently if either holder still sees that storage.
        // Scenario: eight lines scroll through a three-row primary screen, with a copy taken
        //   after the first two, and both holders are read back at the end.
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("line0\r\nline1\r\n".utf8))
        let snapshot = terminal
        for index in 2..<8 { terminal.feed(Array("line\(index)\r\n".utf8)) }

        #expect(terminal.fullHistoryText == "line0\nline1\nline2\nline3\nline4\nline5\nline6\nline7")
        #expect(snapshot.fullHistoryText == "line0\nline1")
        #expect(displayedRows(of: snapshot) == ["line0 ", "line1 ", "      "])
        expectValidGrid(terminal)
        expectValidGrid(snapshot)
    }
}
