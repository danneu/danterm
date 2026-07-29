// Behavioral cover for the deduplicated style table that backs `GridCell.styleId`.
//
// Every other style test in this suite asserts what a cell *shows*, and would keep passing if the
// table leaked without bound or resurrected a dead entry -- both are invisible from the projection.
// This file covers the two properties that only exist because the style stopped living in the cell:
// the table stays bounded as distinct styles churn, and a sweep never changes what a surviving cell
// renders. Its own file because it tests the storage indirection, not presentation semantics.

import Testing
@testable import TerminalCore

@Suite("Terminal style table")
struct TerminalStyleTableTests {
    /// Emits a truecolor foreground, the cheapest way to mint a guaranteed-distinct style.
    private func trueColor(_ index: Int) -> [UInt8] {
        let red = UInt8((index >> 16) & 0xFF)
        let green = UInt8((index >> 8) & 0xFF)
        let blue = UInt8(index & 0xFF)
        return Array("\u{1B}[38;2;\(red);\(green);\(blue)m".utf8)
    }

    private func color(_ index: Int) -> TerminalColor {
        .rgb(
            red: UInt8((index >> 16) & 0xFF),
            green: UInt8((index >> 8) & 0xFF),
            blue: UInt8(index & 0xFF)
        )
    }

    @Test("styles keep rendering after far more distinct values than the table holds at once")
    func stylesSurviveTableChurn() {
        // Intent: a session that emits vastly more distinct styles than are ever live at once keeps
        //   showing every cell its own style, and the table does not grow with the number of styles
        //   seen.
        // Why it exists: doc 15's `H3` moved the style out of the cell and behind an id, which
        //   creates two failures no presentation test can see. The table can grow without bound --
        //   trading 16 bytes per cell for an ever-growing side table is a net loss, and the whole
        //   hypothesis rests on it not happening. Or a sweep can drop an entry a live cell still
        //   points at, which shows that cell some other cell's colors.
        // Scenario: a truecolor image renderer -- `chafa`, `timg` -- which assigns a distinct RGB
        //   per cell and blows through more styles in one frame than a whole shell session does.
        let styleCount = 20_000
        var terminal = Terminal(columns: 8, rows: 2)!

        // Column 0 is written once and never touched again, so its style stays live for the whole
        // run. It is the cell that catches a swept id landing on an entry something still points
        // at -- the assertion below reads the *first* color, not the newest one.
        terminal.feed(trueColor(0))
        terminal.feed(Array("a".utf8))

        for index in 1..<styleCount {
            // Rewrite column 1 in place. Nothing scrolls, so the pinned cell above survives, and
            // each style's only cell dies as the next one overwrites it.
            terminal.feed(Array("\u{1B}[1;2H".utf8))
            terminal.feed(trueColor(index))
            terminal.feed(Array("x".utf8))
        }

        #expect(terminal.cell(row: 0, column: 0)?.style.foreground == color(0))
        #expect(terminal.cell(row: 0, column: 1)?.style.foreground == color(styleCount - 1))
        // The live table must stay bounded rather than growing with the number of styles seen,
        // which is the property that makes the id cheaper than the style it replaced.
        #expect(terminal.retainedStyleCount < styleCount)
        expectValidGrid(terminal)
    }

    @Test("a style whose only cells were evicted from history stops being retained")
    func evictedStylesAreReclaimed() {
        // Intent: once history eviction drops the last cell carrying a style, the table stops
        //   holding that style.
        // Why it exists: eviction is the only path that frees cells in bulk, so it is where an
        //   unswept table would accumulate fastest -- a long-running pane would keep every style it
        //   ever showed, long after the rows were gone.
        // Scenario: a pane scrolling colored build output past the scrollback budget for hours.
        var terminal = Terminal(
            columns: 4,
            rows: 2,
            scrollbackBudgetBytes: historyRowCost(columns: 4) * 2
        )!

        let styleCount = 4_000
        for index in 0..<styleCount {
            terminal.feed(trueColor(index + 1))
            terminal.feed(Array("ab\n".utf8))
        }

        // Only a couple of history rows plus the live screen survive the budget, so the styles
        // still reachable from a cell are a small constant. The table is swept lazily rather than
        // on every eviction -- a walk of every cell is far more expensive than the entries it
        // frees -- so the assertion is that it stays *bounded*, not that it is minimal. A table
        // that never swept would sit at `styleCount`.
        #expect(terminal.retainedStyleCount < styleCount / 2)
        expectValidGrid(terminal)
    }

    @Test("styles keep resolving after the id cursor reaches the end of its range")
    func stylesSurviveIdRecycle() {
        // Intent: once the style-id cursor runs off the end of its range it recycles into free
        //   slots, and neither the cell holding an already-issued id nor the cells styled after
        //   the recycle show the wrong colors.
        // Why it exists: ids are issued from a cursor, so the end of the range is reachable by
        //   counting rather than by holding -- `allocateStyleId` puts the bound on styles live at
        //   once, but only because it recycles. Two failures hide here: a monotonic counter that
        //   gives up and renders every later style as the default, and a recycle that hands a live
        //   cell's id to a different style and repaints it.
        // Scenario: a pane left running full-screen truecolor output for hours, which is the only
        //   thing that interns styles fast enough to walk the cursor off the end.
        var terminal = Terminal(columns: 8, rows: 2)!
        terminal.feed(trueColor(0x010203))
        terminal.feed(Array("a".utf8))

        terminal.primeStyleIdRecycleForTesting()
        for index in 1..<64 {
            terminal.feed(Array("\u{1B}[1;2H".utf8))
            terminal.feed(trueColor(0x900000 + index))
            terminal.feed(Array("x".utf8))
        }

        // The pinned cell was styled before the recycle and never rewritten, so it catches a
        // recycled id landing on an entry it still points at.
        #expect(terminal.cell(row: 0, column: 0)?.style.foreground == color(0x010203))
        #expect(terminal.cell(row: 0, column: 1)?.style.foreground == color(0x900000 + 63))
        expectValidGrid(terminal)
    }

    @Test("a sweep leaves every visible cell's style unchanged")
    func sweepPreservesVisibleStyles() {
        // Intent: reclaiming dead table entries does not disturb the styles of cells that are still
        //   on screen or still in history.
        // Why it exists: the sweep's correctness rests on "every id held by a cell is a key of the
        //   table" -- the same invariant `allocateHyperlinkId` documents. If the live-set walk
        //   misses a region (history, the inactive primary screen under the alternate screen), the
        //   sweep silently drops entries those cells still point at.
        // Scenario: a full-screen TUI is open -- so a whole primary screen is retained off-view --
        //   while the alternate screen churns through enough styles to trigger a sweep.
        var terminal = Terminal(columns: 6, rows: 2)!
        terminal.feed(trueColor(0x112233))
        terminal.feed(Array("pinned".utf8))

        terminal.feed(Array("\u{1B}[?1049h".utf8))
        terminal.feed(Array("\u{1B}[H".utf8))
        terminal.feed(trueColor(0x445566))
        terminal.feed(Array("alt".utf8))
        for index in 0..<5_000 {
            terminal.feed(Array("\u{1B}[2;1H".utf8))
            terminal.feed(trueColor(index + 1))
            terminal.feed(Array("z".utf8))
        }
        #expect(terminal.cell(row: 0, column: 0)?.style.foreground == color(0x445566))

        terminal.feed(Array("\u{1B}[?1049l".utf8))
        for column in 0..<6 {
            #expect(terminal.cell(row: 0, column: column)?.style.foreground == color(0x112233))
        }
        expectValidGrid(terminal)
    }
}
