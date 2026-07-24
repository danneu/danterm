// Behavioral proofs for the xterm/Ghostty rule that a scroll region anchored at
// row 0 still retains the rows it scrolls off the top. Separate from
// TerminalScrollRegionTests (which pins region geometry, cursor motion, and wrap
// seams) because every case here is about one question: does history grow? It is
// the proof surface for inline-viewport TUIs -- codex-style composers that pin a
// footer with `CSI 1;N r` and expect their transcript to reach scrollback.
import Testing

@testable import TerminalCore

/// Locks history retention to the region's top anchor rather than to the absence of a region.
struct TerminalRegionScrollbackTests {
    @Test("a region anchored at row 0 retains rows scrolled off its top")
    func topAnchoredRegionPushesToScrollback() throws {
        // Intent: LF at the bottom margin, CSI S, and a soft wrap at the bottom
        //   margin all push the vacated top row into scrollback when the region
        //   starts at row 0, and none of them disturb rows below the margin.
        // Why it exists: history retention used to require no region at all, so a
        //   top-anchored partial-height region discarded every transcript line --
        //   the wheel then had nothing to scroll into.
        // Scenario: codex's ratatui inline viewport pins its composer with
        //   `CSI 1;N r` and scrolls transcript lines out the top of that region.
        var linefeed = try labeledTerminal(columns: 2, rows: 4)
        linefeed.feed(Array("\u{1B}[1;3r\u{1B}[3;1H\n".utf8))
        #expect(linefeed.scrollbackRowCount == 1)
        #expect(linefeed.scrollbackRow(at: 0)?.cells[0].scalars == ["A"])
        #expect(linefeed.screenText == "B \nC \n  \nD ")
        expectValidGrid(linefeed)

        var scrolled = try labeledTerminal(columns: 2, rows: 4)
        scrolled.feed(Array("\u{1B}[1;3r\u{1B}[S".utf8))
        #expect(scrolled.scrollbackRowCount == 1)
        #expect(scrolled.scrollbackRow(at: 0)?.cells[0].scalars == ["A"])
        #expect(scrolled.screenText == "B \nC \n  \nD ")
        expectValidGrid(scrolled)

        var wrapped = try labeledTerminal(columns: 3, rows: 4)
        wrapped.feed(Array("\u{1B}[1;3r\u{1B}[3;1HXYZQ".utf8))
        #expect(wrapped.scrollbackRowCount == 1)
        #expect(wrapped.scrollbackRow(at: 0)?.cells[0].scalars == ["A"])
        #expect(wrapped.geometry.rows[1].isSoftWrapped)
        #expect(wrapped.fullHistoryText == "A\nB\nXYZQ\nD")
        expectValidGrid(wrapped)
    }

    @Test("a region not anchored at row 0 still discards the rows it scrolls off")
    func offsetRegionDiscardsScrolledRows() throws {
        // Intent: keep the pre-existing discard behavior for any region whose top
        //   margin is below row 0, for LF at the bottom margin and CSI S alike.
        // Why it exists: a mid-screen repaint region must not pollute history; the
        //   new retention rule keys on the anchor, not on scrolling in general.
        // Scenario: a TUI reserves a header and repaints only the rows beneath it.
        var linefeed = try labeledTerminal(columns: 2, rows: 4)
        linefeed.feed(Array("\u{1B}[2;4r\u{1B}[4;1H\n".utf8))
        #expect(linefeed.scrollbackRowCount == 0)
        #expect(linefeed.screenText == "A \nC \nD \n  ")

        var scrolled = try labeledTerminal(columns: 2, rows: 4)
        scrolled.feed(Array("\u{1B}[2;4r\u{1B}[S".utf8))
        #expect(scrolled.scrollbackRowCount == 0)
        #expect(scrolled.screenText == "A \nC \nD \n  ")
    }

    @Test("the alternate screen never grows history, with or without a region")
    func alternateScreenNeverPushes() throws {
        // Intent: the top-anchor rule stays gated on the primary screen.
        // Why it exists: full-screen TUIs scroll constantly on the alternate
        //   screen; leaking those rows would corrupt the primary transcript.
        // Scenario: vim scrolls its buffer, both regionless and inside a region
        //   it anchored at the top of the screen.
        var terminal = try labeledTerminal(columns: 2, rows: 3)
        terminal.feed(Array("\u{1B}[3;1H\n".utf8))
        #expect(terminal.scrollbackRowCount == 1)

        terminal.feed(Array("\u{1B}[?1049h".utf8))
        terminal.feed(Array("\u{1B}[1;2r\u{1B}[S".utf8))
        #expect(terminal.scrollbackRowCount == 1)

        terminal.feed(Array("\u{1B}[r\u{1B}[S".utf8))
        #expect(terminal.scrollbackRowCount == 1)
    }

    @Test("downward and mid-screen shuffles never grow history inside a top-anchored region")
    func downwardAndMidScreenOperationsNeverPush() throws {
        // Intent: only the two upward-scroll paths retain rows; SD, IL, DL, and RI
        //   keep discarding whatever they push out of the region.
        // Why it exists: these paths destroy rows rather than scrolling them past
        //   the viewport, so their content was never part of the output stream.
        // Scenario: an inline-viewport TUI opens and closes lines inside the region
        //   it anchored at row 0 while repainting.
        let sequences = [
            "\u{1B}[T",             // SD
            "\u{1B}[1;1H\u{1B}[L",  // IL at the top margin
            "\u{1B}[1;1H\u{1B}[M",  // DL at the top margin
            "\u{1B}[1;1H\u{1B}M",   // RI at the top margin
        ]

        for sequence in sequences {
            var terminal = try labeledTerminal(columns: 2, rows: 4)
            terminal.feed(Array("\u{1B}[1;3r".utf8))
            terminal.feed(Array(sequence.utf8))
            #expect(terminal.scrollbackRowCount == 0)
        }
    }

    @Test("region-pushed rows accrue byte cost and are evicted by the same budget")
    func regionPushesObeyScrollbackBudget() throws {
        // Intent: rows retained by a top-anchored region are ordinary history --
        //   they accrue the pinned byte cost and trip oldest-first eviction.
        // Why it exists: the retention rule must reuse the existing push path, not
        //   a parallel one that bypasses accounting and grows history unbounded.
        // Scenario: a long-running inline-viewport session overruns its budget.
        let rowCost = 16 + 2 * 32 + 8
        var terminal = try labeledTerminal(
            columns: 2,
            rows: 4,
            scrollbackBudgetBytes: rowCost * 2
        )
        terminal.feed(Array("\u{1B}[1;3r\u{1B}[3;1H".utf8))

        terminal.feed(Array("\n".utf8))
        #expect(terminal.scrollbackRowCount == 1)
        #expect(terminal.scrollbackByteCount == rowCost)

        terminal.feed(Array("\n".utf8))
        #expect(terminal.scrollbackRowCount == 2)
        #expect(terminal.scrollbackByteCount == rowCost * 2)

        terminal.feed(Array("\n".utf8))
        #expect(terminal.scrollbackRowCount == 2)
        #expect(terminal.scrollbackByteCount == rowCost * 2)
        #expect(terminal.scrollbackRow(at: 0)?.cells[0].scalars == ["B"])
        #expect(terminal.scrollbackRow(at: 1)?.cells[0].scalars == ["C"])
        #expect(terminal.recomputedScrollbackByteCount == terminal.scrollbackByteCount)
    }

    @Test("CSI S beyond the region height pushes at most the region's rows")
    func oversizedScrollUpClampsToRegion() throws {
        // Intent: an amount larger than the region height retains exactly the
        //   region's rows -- no blanks appended, no rows below the margin taken.
        // Why it exists: the push slices the region snapshot by the requested
        //   amount, so an unclamped count would over-read it.
        // Scenario: a TUI clears its viewport with a deliberately huge CSI S.
        var terminal = try labeledTerminal(columns: 2, rows: 4)
        terminal.feed(Array("\u{1B}[1;3r\u{1B}[100S".utf8))

        #expect(terminal.scrollbackRowCount == 3)
        #expect(terminal.scrollbackRow(at: 0)?.cells[0].scalars == ["A"])
        #expect(terminal.scrollbackRow(at: 2)?.cells[0].scalars == ["C"])
        #expect(terminal.screenText == "  \n  \n  \nD ")
        expectValidGrid(terminal)
    }

    @Test("a codex-shaped stream yields history the local wheel can scroll into")
    func inlineViewportStreamProducesScrollableHistory() throws {
        // Intent: end to end, a DECSTBM `1;N` stream that scrolls transcript lines
        //   out via LF leaves usable history and a wheel routed to the viewport.
        // Why it exists: this is the reported failure -- the wheel decision was
        //   already correct, but history stayed empty so scrolling did nothing.
        // Scenario: codex renders 12 transcript lines above its pinned composer,
        //   then the user scrolls the wheel up over the pane.
        var terminal = try #require(Terminal(columns: 20, rows: 6))
        terminal.feed(Array("\u{1B}[1;4r\u{1B}[4;1H".utf8))
        for line in 1...12 {
            terminal.feed(Array("line \(line)\r\n".utf8))
        }

        #expect(terminal.scrollbackRowCount > 0)
        #expect(terminal.fullHistoryText.contains("line 1\n"))

        var state = TerminalInteractionState()
        let decision = decideTerminalWheel(
            .init(rowDelta: 2, column: 0, row: 0),
            terminal: terminal,
            state: &state
        )
        #expect(decision.route == .localViewport)
        #expect(decision.localRowDelta != 0)
    }

    private func labeledTerminal(
        columns: Int,
        rows: Int,
        scrollbackBudgetBytes: Int = Terminal.productionScrollbackBudgetBytes
    ) throws -> Terminal {
        var terminal = try #require(
            Terminal(columns: columns, rows: rows, scrollbackBudgetBytes: scrollbackBudgetBytes)
        )
        for row in 0..<rows {
            let label = Unicode.Scalar(65 + row)!
            terminal.feed(Array("\u{1B}[\(row + 1);1H".utf8))
            terminal.feed(Array(String(label).utf8))
        }
        return terminal
    }
}
