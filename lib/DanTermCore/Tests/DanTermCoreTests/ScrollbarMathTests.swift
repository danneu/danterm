// Swift Testing migration of the legacy `tests/ScrollbarMathTests.swift` harness
// suite. Pins the pure scrollbar coordinate math (`scrollbarDocumentHeight`,
// `scrollbarOffsetY`, `scrollbarRowFromPosition`) against the same set of
// inputs the legacy suite asserted, with the round-trip case promoted to
// `@Test(arguments:)` for per-case reporting.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct ScrollbarMathTests {
    @Test("scrollbarDocumentHeight: returns contentHeight when cellHeight is zero")
    func documentHeightFallsBackToContentHeightWhenCellHeightZero() {
        // Intent: documentHeight returns contentHeight verbatim when
        //   cellHeight is zero (the degenerate-grid guard).
        // Why it exists: pins the divide-by-zero / no-grid path so a refactor
        //   that fuses the padding/grid math cannot drop the early-return.
        // Scenario: spec-first guard check -- a pane reports a zero-height cell
        //   before metrics resolve, and the scrollbar must still render the
        //   visible content extent rather than collapse.
        let result = scrollbarDocumentHeight(contentHeight: 600, cellHeight: 0, total: 1000, len: 40)
        #expect(result == 600)
    }

    @Test("scrollbarDocumentHeight: correct with scrollback")
    func documentHeightSumsScrollbackGridExactly() {
        // Intent: with a grid that fits contentHeight exactly (40 rows * 15pt
        //   = 600), documentHeight equals total rows * cellHeight.
        // Why it exists: pins the no-padding case so the padding term cannot
        //   silently regress when the grid fits.
        // Scenario: spec-first happy path -- a pane sized exactly to its row
        //   grid scrolls a 1000-row scrollback as 15000 visible-document points.
        let result = scrollbarDocumentHeight(contentHeight: 600, cellHeight: 15, total: 1000, len: 40)
        #expect(result == 15000)
    }

    @Test("scrollbarDocumentHeight: includes padding when content doesn't fill grid exactly")
    func documentHeightAddsTrailingPadding() {
        // Intent: leftover space between the visible grid (38 rows * 15 = 570)
        //   and contentHeight (600) becomes a 30pt padding term added to the
        //   scrolled document height (1000*15 + 30 = 15030).
        // Why it exists: pins the padding term so a fit-the-grid refactor
        //   cannot truncate a sub-row pixel band the user can scroll into.
        // Scenario: spec-first padding case -- a pane is 30pt taller than its
        //   integer row count, and that 30pt must remain reachable at the
        //   bottom of the scrollback.
        let result = scrollbarDocumentHeight(contentHeight: 600, cellHeight: 15, total: 1000, len: 38)
        #expect(result == 15030)
    }

    @Test("scrollbarOffsetY: at bottom of scrollback, offsetY is 0")
    func offsetYAtBottomIsZero() {
        // Intent: offsetY is 0 when the pane is scrolled to the bottom-most
        //   row (offset == total - len).
        // Why it exists: pins the "bottom == zero" invariant the scrollbar
        //   thumb anchor depends on.
        // Scenario: spec-first end-of-scrollback check -- a user at the bottom
        //   of a 1000-row scrollback sees the thumb anchored at 0pt.
        let result = scrollbarOffsetY(total: 1000, offset: 960, len: 40, cellHeight: 15)
        #expect(result == 0)
    }

    @Test("scrollbarOffsetY: at top of scrollback, offsetY is maximal")
    func offsetYAtTopIsMaximal() {
        // Intent: offsetY equals (total - offset - len) * cellHeight when
        //   offset == 0, the maximum scroll-back position.
        // Why it exists: pins the "top == max" anchor the thumb rests on at
        //   the start of the scrollback.
        // Scenario: spec-first start-of-scrollback check -- a user at the very
        //   top of a 1000-row, 40-row-visible, 15pt-cell pane sees the thumb
        //   at 14400pt (960 hidden rows * 15).
        let result = scrollbarOffsetY(total: 1000, offset: 0, len: 40, cellHeight: 15)
        #expect(result == 14400)
    }

    @Test("scrollbarOffsetY: mid-scrollback")
    func offsetYMidScrollback() {
        // Intent: offsetY is the linear (total - offset - len) * cellHeight
        //   for an interior offset (offset = 500 -> 6900).
        // Why it exists: pins the linearity of offsetY between top and
        //   bottom so a piecewise-clamp regression is caught.
        // Scenario: spec-first interior check -- a user halfway through a
        //   1000-row scrollback sees the thumb at the proportional midpoint.
        let result = scrollbarOffsetY(total: 1000, offset: 500, len: 40, cellHeight: 15)
        #expect(result == 6900)
    }

    @Test("scrollbarRowFromPosition: returns 0 when cellHeight is zero")
    func rowFromPositionFallsBackToZeroWhenCellHeightZero() {
        // Intent: rowFromPosition returns 0 verbatim when cellHeight is zero
        //   (the divide-by-zero guard inverse to documentHeight's).
        // Why it exists: pins the guard so a callsite that reads the row count
        //   pre-metrics-resolved cannot crash or compute nonsense.
        // Scenario: spec-first guard check -- a click on the scrollbar arrives
        //   before metrics resolve and the row index must clamp safely to 0.
        let result = scrollbarRowFromPosition(documentHeight: 15000, visibleOriginY: 0, visibleHeight: 600, cellHeight: 0)
        #expect(result == 0)
    }

    @Test("scrollbarRowFromPosition: at bottom of document returns row 0")
    func rowFromPositionAtBottomIsZero() {
        // Intent: when the visible origin sits at (docHeight - visibleHeight),
        //   the computed row is 0 (the bottom of the scrollback).
        // Why it exists: pins the inverse of "offset 960 -> offsetY 0" so the
        //   forward and reverse mappings stay symmetric.
        // Scenario: spec-first reverse-anchor check -- the scrollbar thumb at
        //   the very bottom resolves to offset 0 (live tail) of the scrollback.
        let result = scrollbarRowFromPosition(documentHeight: 15000, visibleOriginY: 14400, visibleHeight: 600, cellHeight: 15)
        #expect(result == 0)
    }

    @Test("scrollbarRowFromPosition: at top of document returns max row")
    func rowFromPositionAtTopIsMaxRow() {
        // Intent: when the visible origin is 0, the computed row equals
        //   (docHeight - visibleHeight) / cellHeight (960 rows offscreen).
        // Why it exists: pins the inverse of "offset 0 -> offsetY 14400" so
        //   the top boundary stays the count of hidden rows, not a clamp.
        // Scenario: spec-first reverse-anchor check -- dragging the thumb to
        //   the very top must surface 960 rows of a 1000-row scrollback.
        let result = scrollbarRowFromPosition(documentHeight: 15000, visibleOriginY: 0, visibleHeight: 600, cellHeight: 15)
        #expect(result == 960)
    }

    @Test(
        "scrollbar round-trip: offset -> offsetY -> row produces original offset",
        arguments: [UInt64(0), UInt64(100), UInt64(500), UInt64(960)]
    )
    func roundTripOffsetYRow(offset: UInt64) {
        // Intent: composing offsetY then rowFromPosition recovers the original
        //   scrollback offset for representative interior and boundary inputs.
        // Why it exists: locks down the forward/reverse coordinate mapping the
        //   scrollbar relies on -- if either function shifts by one row the
        //   round-trip catches it where individual cases might not.
        // Scenario: spec-first composition check -- the user's drag position
        //   must map back to the same scrollback row that drove the layout.
        //   Replaces the legacy in-test `for`-loop with `@Test(arguments:)`
        //   for per-case reporting; the 4 arguments mirror the original loop's
        //   4 iterations.
        let total: UInt64 = 1000
        let len: UInt64 = 40
        let cellHeight: CGFloat = 15
        let contentHeight: CGFloat = CGFloat(len) * cellHeight

        let offsetY = scrollbarOffsetY(total: total, offset: offset, len: len, cellHeight: cellHeight)
        let docHeight = scrollbarDocumentHeight(contentHeight: contentHeight, cellHeight: cellHeight, total: total, len: len)
        let row = scrollbarRowFromPosition(
            documentHeight: docHeight, visibleOriginY: offsetY,
            visibleHeight: contentHeight, cellHeight: cellHeight
        )
        #expect(row == Int(offset), "Round-trip failed for offset=\(offset)")
    }
}
