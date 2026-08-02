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
}
