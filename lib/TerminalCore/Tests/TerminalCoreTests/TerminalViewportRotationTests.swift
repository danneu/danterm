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
        let expectedSynchronization = "\u{1B}c\u{1B}[3J\u{1B}]133;S;redraw=0\u{7}\u{1B}[0;59m\u{1B}[0\"q"
            + synchronizedRows
            + "\u{1B}[3g\u{1B}[1;1H\u{1B}H\u{1B}[r\u{1B}[?6l\u{1B}[?25h\u{1B}[2 q"
            + "\u{1B}[0;59m\u{1B}[0\"q\u{1B}[1;1H\u{1B}7"
            + "\u{1B}]133;S;charset-saved=BBBB,0,none\u{7}\u{1B}[4l\u{1B}[20l\u{1B}>"
            + "\u{1B}[?1l\u{1B}[?6l\u{1B}[?7h\u{1B}[?12l\u{1B}[?25h\u{1B}[?1004l"
            + "\u{1B}[?1006l\u{1B}[?2004l\u{1B}[?2026l\u{1B}[?1000l\u{1B}[?1002l"
            + "\u{1B}[?1003l\u{1B}[2 q\u{1B}[<u\u{1B}[0;59m\u{1B}[0\"q\u{1B}]8;;\u{7}"
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
}
