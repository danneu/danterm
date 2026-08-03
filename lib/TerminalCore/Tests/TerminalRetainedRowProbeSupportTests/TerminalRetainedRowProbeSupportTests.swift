// Behavioral tests for the retained-row shape probe.
//
// These pin the two properties that make the probe's numbers usable: the public-API
// derivation of stored extents reconstructs the engine's own exact census (otherwise every
// byte the probe reports is a guess dressed as a measurement), and blank rows are counted
// as blank rather than as one-cell rows (which is the whole of `28/F9`). Nothing here
// asserts a blank frequency or a size class -- the corpus supplies the first and libmalloc
// the second, and a unit test that pinned either would be inventing evidence.
import Testing
import TerminalCore
@testable import TerminalRetainedRowProbeSupport

@Suite("Retained-row shape probe")
struct TerminalRetainedRowProbeSupportTests {
    /// Feeds enough short lines to push rows into history at a small geometry.
    private func makeTerminal(columns: Int, rows: Int, lines: [String]) -> Terminal {
        var terminal = Terminal(columns: columns, rows: rows)!
        for line in lines { terminal.feed(Array("\(line)\r\n".utf8)) }
        return terminal
    }

    @Test("The derived stored extents reconstruct the census exactly")
    func derivationMatchesCensus() {
        // Intent: derived scrollback cells plus full-width screen rows equal
        //   `memoryCensus.cellStorageBytes` for a history of mixed row lengths.
        // Why it exists: the probe reads stored extents through the public row API, which
        //   materializes rows to full width. That is only legitimate because canonical
        //   form makes the stored extent a pure function of observable content. This test
        //   is the check on that inference, and the `derivationMatchesCensus` flag it
        //   pins is what a future representation change would trip.
        let lines = (0..<40).map { String(repeating: "x", count: 1 + $0 % 17) }
        let terminal = makeTerminal(columns: 40, rows: 4, lines: lines)
        let report = readRetainedRowShape(of: terminal, stimulus: "mixed", fedByteCount: 0)

        #expect(report.retainedRowCount > 0)
        #expect(report.derivationMatchesCensus)
        #expect(report.storedCellCounts.count == report.retainedRowCount)
    }

    @Test("A blank retained row counts as blank, and stores one cell")
    func blankRowsAreCountedAndCostOneCell() {
        // Intent: rows fed as bare newlines are counted in `blankRowCount`, and their
        //   derived stored extent is 1.
        // Why it exists: canonical trimming compacts an all-default row to a single cell,
        //   so a blank row is indistinguishable by extent from a row with one character in
        //   column 0. `H2`'s ceiling is denominated in blank rows specifically, so
        //   conflating the two would size the wrong population.
        var terminal = Terminal(columns: 40, rows: 4)!
        for _ in 0..<20 { terminal.feed(Array("\r\n".utf8)) }
        let report = readRetainedRowShape(of: terminal, stimulus: "blank", fedByteCount: 0)

        #expect(report.retainedRowCount > 0)
        #expect(report.blankRowCount == report.retainedRowCount)
        #expect(report.storedCellCounts.allSatisfy { $0 == 1 })
        #expect(report.blankRowFraction == 1.0)
    }

    @Test("A one-character row is not blank, though it stores one cell too")
    func singleCharacterRowIsNotBlank() {
        // Intent: rows holding a single character in column 0 store one cell but are not
        //   counted as blank.
        // Why it exists: the negative half of the case above. Without it, a probe that
        //   derived blankness from the stored extent alone would pass every assertion in
        //   the blank test while overstating `H2`'s population by every short row in a
        //   real history.
        var terminal = Terminal(columns: 40, rows: 4)!
        for _ in 0..<20 { terminal.feed(Array("a\r\n".utf8)) }
        let report = readRetainedRowShape(of: terminal, stimulus: "single", fedByteCount: 0)

        #expect(report.retainedRowCount > 0)
        #expect(report.blankRowCount == 0)
        #expect(report.storedCellCounts.allSatisfy { $0 == 1 })
    }

    @Test("Allocation arithmetic asks the allocator rather than modelling size classes")
    func allocationArithmeticUsesGoodSize() {
        // Intent: a row's allocated bytes are `malloc_good_size(header + cells * stride)`,
        //   never smaller than the request.
        // Why it exists: `F10`'s question is precisely what the allocator does to ragged
        //   requests, so a modelled size-class table would answer the question with its own
        //   assumption. Doc 15's `D4` made the same call for the budget charge.
        for storedCells in [1, 7, 30, 52, 179, 300] {
            let allocation = rowAllocation(storedCells: storedCells, cellStrideBytes: 32)
            #expect(allocation.request == 32 + storedCells * 32)
            #expect(allocation.allocated >= allocation.request)
        }
    }

    @Test("H2's ceiling counts every blank row's block but one, and is zero below two")
    func sharedBlankCeilingIsStatedAsBestCase() {
        // Intent: `sharedBlankCeilingBytes` is `(blankRows - 1)` blank allocations, and 0
        //   when fewer than two blank rows exist.
        // Why it exists: `F8` stated `H4`'s ceiling as best-case-at-zero-overhead in
        //   absolute bytes, and `F9` is asked to state `H2`'s the same way. A ceiling that
        //   quietly charged the shared row, or that counted a lone blank row as reclaimable,
        //   would not be the same kind of number.
        var terminal = Terminal(columns: 40, rows: 4)!
        for _ in 0..<20 { terminal.feed(Array("\r\n".utf8)) }
        let report = readRetainedRowShape(of: terminal, stimulus: "blank", fedByteCount: 0)
        let perBlank = rowAllocation(storedCells: 1, cellStrideBytes: 32).allocated

        #expect(report.sharedBlankCeilingBytes == (report.blankRowCount - 1) * perBlank)
        #expect(report.sharedBlankCeilingBytes < report.allocatedBytes)
    }
}
