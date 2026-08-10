// Behavioral proofs for coalescing sparse terminal row damage into exact clip spans.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

struct TerminalDamageSpanTests {
    @Test(
        "Damage rows count their maximal contiguous spans",
        arguments: [
            (rows: Set<Int>(), expected: 0),
            (rows: Set([2, 3, 4]), expected: 1),
            (rows: Set([9, 1, 2, 6]), expected: 3),
        ]
    )
    func maximalContiguousSpanCount(example: (rows: Set<Int>, expected: Int)) {
        #expect(TerminalDamage(rows: example.rows).maximalContiguousSpanCount == example.expected)
    }

    @Test("Damage rows coalesce into ordered maximal contiguous spans")
    func maximalContiguousSpans() {
        #expect(
            TerminalDamage(rows: [9, 1, 2, 6]).maximalContiguousSpans()
                == [1..<3, 6..<7, 9..<10]
        )
    }

    @Test("Partial damage expands by a bounded one-row glyph halo")
    func glyphHaloStaysInsideTheViewport() {
        // Intent: the halo adds one neighbouring row on each side and never leaves the grid.
        // Why it exists: unclipped glyph ink crosses a row boundary, so a halo narrower
        //   than one row leaves artifacts, while one that escapes the viewport would
        //   invalidate rows the plan cannot describe.
        // Scenario: a TUI rewrites its top, middle, and bottom status rows.
        #expect(TerminalDamage(rows: [0], rowCount: 4).withGlyphHalo(rowCount: 4).rowIndices == [0, 1])
        #expect(TerminalDamage(rows: [2], rowCount: 4).withGlyphHalo(rowCount: 4).rowIndices == [1, 2, 3])
        #expect(TerminalDamage(rows: [3], rowCount: 4).withGlyphHalo(rowCount: 4).rowIndices == [2, 3])
        #expect(TerminalDamage(rows: [], rowCount: 4).withGlyphHalo(rowCount: 4).rowIndices.isEmpty)
    }

    @Test("The halo truncates to the target grid rather than expanding past it")
    func glyphHaloClampsRowsOutsideTheGrid() {
        // Intent: a halo computed against a shorter grid than the damage was recorded
        //   for contributes nothing outside `0..<rowCount`.
        // Why it exists: an out-of-grid row reaching the drawing clip invalidates a row
        //   no plan can describe. The bounded representation already refuses out-of-grid
        //   rows at construction; this pins the remaining seam, the halo's own bound.
        #expect(TerminalDamage(rows: [7], rowCount: 10).withGlyphHalo(rowCount: 4).rowIndices.isEmpty)
        #expect(TerminalDamage(rows: [2, 7], rowCount: 10).withGlyphHalo(rowCount: 4).rowIndices == [1, 2, 3])
        #expect(TerminalDamage(rows: [], rowCount: 1).withGlyphHalo(rowCount: 0).rowIndices.isEmpty)
    }

    @Test("Empty damage coalesces into no spans at all")
    func emptyDamageHasNoSpans() {
        #expect(TerminalDamage.none.maximalContiguousSpans().isEmpty)
    }

    @Test("Two distant interior rows derive the six-row, two-span drawing topology")
    func fewSpanDrawingTopologyAt179x66() {
        // Intent: two engine-damaged rows further apart than the halo reach drawing as
        //   6 damaged rows in 2 maximal spans at the canonical 66-row geometry.
        // Why it exists: this is the ideal-case topology the `sparse-spans-few`
        //   benchmark exists to protect, and its verdict is impossible unless the
        //   transform derives exactly this shape from the published engine damage.
        let drawn = TerminalDamage(rows: [5, 60], rowCount: 66).withGlyphHalo(rowCount: 66)
        #expect(drawn.damagedRowCount == 6)
        #expect(drawn.maximalContiguousSpanCount == 2)
        #expect(drawn.maximalContiguousSpans() == [4..<7, 59..<62])
    }

    @Test("Stride-four engine damage derives the 50-row, 17-span drawing topology")
    func maximumSpanDrawingTopologyAt179x66() {
        // Intent: engine damage on every fourth row of a 66-row grid reaches drawing as
        //   50 damaged rows in 17 maximal spans -- the most disjoint spans a one-row
        //   halo can leave at this height.
        // Why it exists: this is the worst compound clip `sparse-spans-max` exists to
        //   bound, and the count is what the plan's `ceil(rows / 4)` risk note rests on.
        let sourceRows = Set(stride(from: 0, to: 66, by: 4))
        #expect(sourceRows.count == 17)
        let drawn = TerminalDamage(rows: sourceRows, rowCount: 66).withGlyphHalo(rowCount: 66)
        #expect(drawn.damagedRowCount == 50)
        #expect(drawn.maximalContiguousSpanCount == 17)
    }
}
