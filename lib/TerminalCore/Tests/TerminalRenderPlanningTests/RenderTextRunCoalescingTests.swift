// Behavioral proofs for the text-run coalescing rule itself: the column
// arithmetic that decides where a run continues and where it splits.
//
// These live apart from the broader frame-planning suite because
// `assertCanonical` structurally cannot catch the failure mode this rule is
// most exposed to -- two runs wrongly fused into one still satisfies ordering,
// non-overlap, and non-mergeability. Every assertion here reads start columns
// and per-cell widths directly instead.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

struct RenderTextRunCoalescingTests {
    @Test("Wide cells advance the run's continuity arithmetic by two columns")
    func wideCellsAdvanceContinuityByTwoColumns() throws {
        // Intent: a same-style row containing wide cells coalesces into one run
        //   whose cell widths account for every column it covers.
        // Why it exists: the continuity test compares the next cell's column
        //   against the open run's start plus its accumulated width. A width
        //   that counted cells instead of columns would split at the first wide
        //   cell, and nothing in `assertCanonical` would notice.
        // Scenario: spec-first -- CJK text mixed into a Latin line, and a pair
        //   of adjacent CJK glyphs, both of which must draw as one shaped run.
        let interior = try plan("AB\u{754C}CD", columns: 8)
        #expect(interior.textRuns.count == 1)
        #expect(interior.textRuns.first?.startColumn == 0)
        #expect(interior.textRuns.first?.cells.map(\.columnWidth) == [1, 1, 2, 1, 1])

        let consecutive = try plan("\u{754C}\u{754C}AB", columns: 8)
        #expect(consecutive.textRuns.count == 1)
        #expect(consecutive.textRuns.first?.startColumn == 0)
        #expect(consecutive.textRuns.first?.cells.map(\.columnWidth) == [2, 2, 1, 1])
    }

    @Test("A column gap splits a same-style run, including immediately after a wide cell")
    func columnGapSplitsSameStyleRun() throws {
        // Intent: untouched cells between two same-style spans start a new run
        //   at the correct column rather than extending the open one.
        // Why it exists: filtered cells (empty scalars here) never reach the
        //   coalescing loop, so the split can only come from column arithmetic.
        //   If the accumulator ignored the candidate's column it would silently
        //   fuse the two spans, which is exactly what `assertCanonical` passes.
        // Scenario: spec-first -- a TUI redrawing two separated labels on one
        //   row via absolute cursor positioning.
        let narrowGap = try plan("AB\u{1B}[1;6HCD", columns: 10)
        #expect(narrowGap.textRuns.map(\.startColumn) == [0, 5])
        #expect(narrowGap.textRuns.map { $0.cells.count } == [2, 2])

        let gapAfterWide = try plan("\u{754C}\u{1B}[1;5HX", columns: 10)
        #expect(gapAfterWide.textRuns.map(\.startColumn) == [0, 4])
        #expect(gapAfterWide.textRuns.map { $0.cells.map(\.columnWidth) } == [[2], [1]])
    }

    @Test("DECSCA protection is invisible to render planning")
    func protectionDoesNotSplitARun() throws {
        // Intent: cells that differ only in DECSCA protection draw as one run.
        // Why it exists: protection rides `TerminalStyle` for storage reasons only. A planner
        //   that compared whole styles would split every field boundary into its own run and
        //   change the drawn output for a bit no renderer can express.
        // Scenario: spec-first -- a form program protects its label and leaves the value
        //   after it unprotected, in the same color.
        let mixed = try plan("\u{1B}[1\"qAB\u{1B}[0\"qCD", columns: 10)
        let plain = try plan("ABCD", columns: 10)

        #expect(mixed.textRuns.count == 1)
        #expect(mixed.textRuns == plain.textRuns)
    }

    @Test("A style change resets the accumulated width for the runs that follow")
    func styleChangeResetsAccumulatedWidth() throws {
        // Intent: when a style change starts a new run, continuity for the run
        //   after it measures from the new run's start, not from the row's.
        // Why it exists: an accumulator that reset its cells but not its width
        //   produces a correct second run and a wrong third one, so the third
        //   run's start column is the observable that pins the reset down.
        // Scenario: spec-first -- a colorized prompt where three adjacent spans
        //   each carry a different foreground.
        let styled = try plan("AB\u{1B}[31mCD\u{1B}[32mEF", columns: 10)
        #expect(styled.textRuns.map(\.startColumn) == [0, 2, 4])
        #expect(styled.textRuns.map { $0.cells.count } == [2, 2, 2])
    }

    @Test("Run accumulation does not leak across a row boundary")
    func accumulationDoesNotLeakAcrossRows() throws {
        // Intent: each row's runs are planned from a fresh accumulator, so a
        //   row's geometry cannot be shifted by the row above it.
        // Why it exists: state carried past the end of a row would mis-place
        //   the next row's first run -- or drop it entirely by treating it as a
        //   continuation -- while every single-row test still passed.
        // Scenario: spec-first -- consecutive output lines with different
        //   lengths and different split points.
        let rows = try plan("AB\u{1B}[1;6HC\r\n\u{1B}[31mXYZ", columns: 10)
        #expect(rows.textRuns.map(\.row) == [0, 0, 1])
        #expect(rows.textRuns.map(\.startColumn) == [0, 5, 0])
        #expect(rows.textRuns.map { $0.cells.count } == [2, 1, 3])
        #expect(rows.textRuns.last?.foreground == RenderTheme.dark.ansiColors[1])
    }
}

private func plan(_ input: String, columns: Int, rows: Int = 2) throws -> RenderFramePlan {
    var terminal = try #require(Terminal(columns: columns, rows: rows))
    terminal.feed(Array(input.utf8))
    return planFrame(
        for: terminal,
        presentation: RenderPresentation(
            theme: .dark,
            isCursorVisible: false,
            cursorShape: .block
        )
    )
}
