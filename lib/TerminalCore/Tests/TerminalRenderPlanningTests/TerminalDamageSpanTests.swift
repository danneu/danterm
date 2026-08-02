// Behavioral proofs for coalescing sparse terminal row damage into exact clip spans.
import Testing

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
        #expect(terminalDamageMaximalContiguousSpanCount(example.rows) == example.expected)
    }

    @Test("Damage rows coalesce into ordered maximal contiguous spans")
    func maximalContiguousSpans() {
        #expect(
            terminalDamageMaximalContiguousSpans([9, 1, 2, 6])
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
        #expect(terminalDamageRowsWithGlyphHalo([0], rowCount: 4) == [0, 1])
        #expect(terminalDamageRowsWithGlyphHalo([2], rowCount: 4) == [1, 2, 3])
        #expect(terminalDamageRowsWithGlyphHalo([3], rowCount: 4) == [2, 3])
        #expect(terminalDamageRowsWithGlyphHalo([], rowCount: 4).isEmpty)
    }

    @Test("Two distant interior rows derive the six-row, two-span drawing topology")
    func fewSpanDrawingTopologyAt179x66() {
        // Intent: two engine-damaged rows further apart than the halo reach drawing as
        //   6 damaged rows in 2 maximal spans at the canonical 66-row geometry.
        // Why it exists: this is the ideal-case topology the `sparse-spans-few`
        //   benchmark exists to protect, and its verdict is impossible unless the
        //   transform derives exactly this shape from the published engine damage.
        let drawn = terminalDamageRowsWithGlyphHalo([5, 60], rowCount: 66)
        #expect(drawn.count == 6)
        #expect(terminalDamageMaximalContiguousSpanCount(drawn) == 2)
        #expect(terminalDamageMaximalContiguousSpans(drawn) == [4..<7, 59..<62])
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
        let drawn = terminalDamageRowsWithGlyphHalo(sourceRows, rowCount: 66)
        #expect(drawn.count == 50)
        #expect(terminalDamageMaximalContiguousSpanCount(drawn) == 17)
    }
}
