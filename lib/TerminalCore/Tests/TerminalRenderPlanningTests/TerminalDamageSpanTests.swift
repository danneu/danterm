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

    @Test("Empty damage coalesces into no spans at all")
    func emptyDamageHasNoSpans() {
        #expect(TerminalDamage.none.maximalContiguousSpans().isEmpty)
    }

    @Test("Two separated bands at 179x66 coalesce into two spans across the word boundary")
    func twoBandsCoalesceAt179x66() {
        // Intent: two three-row bands, one of them straddling the 64-row word boundary,
        //   coalesce into exactly two maximal spans at the canonical 66-row geometry.
        // Why it exists: the coalescer walks a multi-word bitset, and 66 rows is the
        //   only shipped height where a span can cross from word 0 into word 1. A scan
        //   that restarted per word would report three spans here.
        let drawn = TerminalDamage(rows: [4, 5, 6, 62, 63, 64], rowCount: 66)
        #expect(drawn.damagedRowCount == 6)
        #expect(drawn.maximalContiguousSpanCount == 2)
        #expect(drawn.maximalContiguousSpans() == [4..<7, 62..<65])
    }

    @Test("The most disjoint 66-row shape coalesces into 33 single-row spans")
    func maximumSpanCountAt179x66() {
        // Intent: damage on every other row of a 66-row grid stays 33 separate spans --
        //   the most disjoint compound clip this height can produce.
        // Why it exists: this is the worst case the plan's per-span cost is reasoned
        //   against, so a coalescer that fused non-adjacent rows would read as cheap
        //   here while drawing the whole viewport.
        let rows = Set(stride(from: 0, to: 66, by: 2))
        #expect(rows.count == 33)
        let drawn = TerminalDamage(rows: rows, rowCount: 66)
        #expect(drawn.damagedRowCount == 33)
        #expect(drawn.maximalContiguousSpanCount == 33)
    }
}
