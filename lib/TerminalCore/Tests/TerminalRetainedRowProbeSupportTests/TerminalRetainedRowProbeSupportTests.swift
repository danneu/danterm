// Behavioral tests for the retained-row shape probe.
//
// These pin the properties that make the probe's numbers usable: the public-API derivation
// of stored extents reconstructs the engine's own exact census (otherwise every byte the
// probe reports is a guess dressed as a measurement), blank rows are counted as blank
// rather than as one-cell rows (which is the whole of `research/28/F9`), and the composition axes
// `research/28/F11` prices a packing scheme against count what they say they count. Nothing here
// asserts a blank frequency, a styled fraction, or a size class -- the corpus supplies the
// first two and libmalloc the third, and a unit test that pinned any of them would be
// inventing evidence.
import Foundation
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
    func derivationMatchesCensus() throws {
        // Intent: derived scrollback cells plus full-width screen rows equal
        //   `memoryCensus.cellStorageBytes` for a history of mixed row lengths.
        // Why it exists: the probe reads stored extents through the public row API, which
        //   materializes rows to full width. That is only legitimate because canonical
        //   form makes the stored extent a pure function of observable content. This test
        //   is the check on that inference, and the `derivationMatchesCensus` flag it
        //   pins is what a future representation change would trip.
        let lines = (0..<40).map { String(repeating: "x", count: 1 + $0 % 17) }
        let terminal = makeTerminal(columns: 40, rows: 4, lines: lines)
        let report = try readRetainedRowShape(of: terminal, stimulus: "mixed", fedByteCount: 0)

        #expect(report.retainedRowCount > 0)
        #expect(report.derivationMatchesCensus)
        #expect(report.storedCellCounts.count == report.retainedRowCount)
    }

    @Test("The probe reads every content axis back off the record arena")
    func compositionCoversEveryContentAxis() throws {
        // Intent: the composition the probe reads through the public API covers styled runs,
        //   wide cells, combining sequences, hyperlinks and non-BMP scalars together, and the
        //   arena reports bytes in use for them.
        // Why it exists: doc 28's per-row payload model was retired with the representation it
        //   described -- history charges one header per logical line since doc 31, not per
        //   display row (`research/31/D3` Decision 6), so a per-row model cannot equal the arena and a
        //   comparison against it would be false by construction rather than by defect. What
        //   survives is the extent claim `derivationMatchesCensus` makes, held over the same
        //   union of content axes.
        // Scenario: spec-first; the content is deliberately the union of the axes doc 28
        //   prices separately, because a plain-ASCII corpus would exercise almost none of the
        //   record format.
        var terminal = Terminal(columns: 40, rows: 3)!
        for index in 0..<40 {
            terminal.feed(Array("\u{1B}[3\(index % 8)mstyled-\(index) ".utf8))
            terminal.feed(Array("\u{1B}[0m plain \u{754C}\u{2500} e\u{0301} ".utf8))
            terminal.feed(Array("\u{1B}]8;;https://danterm.test/\(index)\u{1B}\\link\u{1B}]8;;\u{1B}\\".utf8))
            terminal.feed(Array("\r\n".utf8))
        }
        // A row assembled out of print order, so at least one row takes the per-cell
        // `contentIdentity` fallback rather than the run table.
        for column in stride(from: 30, through: 0, by: -6) {
            terminal.feed(Array("\u{1B}[3;\(column + 1)Hfrag".utf8))
        }
        terminal.feed(Array("\r\n\r\n\r\n".utf8))

        let report = try readRetainedRowShape(of: terminal, stimulus: "mixed-metadata", fedByteCount: 0)
        #expect(report.retainedRowCount > 0)
        #expect(report.composition.styledRowCount > 0)
        #expect(report.composition.multiScalarRowCount > 0)
        #expect(report.composition.hyperlinkCellCounts.contains { $0 > 0 })
        #expect(report.composition.wideCellCounts.contains { $0 > 0 })
        #expect(report.derivationMatchesCensus)
        #expect(report.censusRetainedArenaBytesInUse > 0)
    }

    @Test("A blank retained row counts as blank, and stores one cell")
    func blankRowsAreCountedAndCostOneCell() throws {
        // Intent: rows fed as bare newlines are counted in `blankRowCount`, and their
        //   derived stored extent is 1.
        // Why it exists: canonical trimming compacts an all-default row to a single cell,
        //   so a blank row is indistinguishable by extent from a row with one character in
        //   column 0. `H2`'s ceiling is denominated in blank rows specifically, so
        //   conflating the two would size the wrong population.
        var terminal = Terminal(columns: 40, rows: 4)!
        for _ in 0..<20 { terminal.feed(Array("\r\n".utf8)) }
        let report = try readRetainedRowShape(of: terminal, stimulus: "blank", fedByteCount: 0)

        #expect(report.retainedRowCount > 0)
        #expect(report.blankRowCount == report.retainedRowCount)
        #expect(report.storedCellCounts.allSatisfy { $0 == 1 })
        #expect(report.blankRowFraction == 1.0)
    }

    @Test("A one-character row is not blank, though it stores one cell too")
    func singleCharacterRowIsNotBlank() throws {
        // Intent: rows holding a single character in column 0 store one cell but are not
        //   counted as blank.
        // Why it exists: the negative half of the case above. Without it, a probe that
        //   derived blankness from the stored extent alone would pass every assertion in
        //   the blank test while overstating `H2`'s population by every short row in a
        //   real history.
        var terminal = Terminal(columns: 40, rows: 4)!
        for _ in 0..<20 { terminal.feed(Array("a\r\n".utf8)) }
        let report = try readRetainedRowShape(of: terminal, stimulus: "single", fedByteCount: 0)

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
        //   assumption. `research/15/D4` made the same call for the budget charge.
        for storedCells in [1, 7, 30, 52, 179, 300] {
            let allocation = rowAllocation(storedCells: storedCells, cellStrideBytes: 16)
            #expect(allocation.request == 32 + storedCells * 16)
            #expect(allocation.allocated >= allocation.request)
        }
    }

    @Test("H2's ceiling counts every blank row's block but one, and is zero below two")
    func sharedBlankCeilingIsStatedAsBestCase() throws {
        // Intent: `sharedBlankCeilingBytes` is `(blankRows - 1)` blank allocations, and 0
        //   when fewer than two blank rows exist.
        // Why it exists: `F8` stated `H4`'s ceiling as best-case-at-zero-overhead in
        //   absolute bytes, and `F9` is asked to state `H2`'s the same way. A ceiling that
        //   quietly charged the shared row, or that counted a lone blank row as reclaimable,
        //   would not be the same kind of number.
        var terminal = Terminal(columns: 40, rows: 4)!
        for _ in 0..<20 { terminal.feed(Array("\r\n".utf8)) }
        let report = try readRetainedRowShape(of: terminal, stimulus: "blank", fedByteCount: 0)
        let perBlank = rowAllocation(storedCells: 1, cellStrideBytes: 16).allocated

        #expect(report.sharedBlankCeilingBytes == (report.blankRowCount - 1) * perBlank)
        #expect(report.sharedBlankCeilingBytes < report.allocatedBytes)
    }

    @Test("Composition is read over the stored prefix, index-aligned with it")
    func compositionCoversOnlyStoredCells() throws {
        // Intent: every composition array has one entry per retained row, and a row's
        //   scalar count never exceeds its stored cell count for single-scalar content.
        // Why it exists: the public row reader materializes rows to full width, so the
        //   easy mistake is to read composition across the pane rather than across the
        //   row. That would report a styled *fraction* diluted by the pane width and a
        //   plain-row cost that grew with the window -- both plausible-looking, both
        //   wrong, and neither visible in a total.
        let lines = (0..<40).map { String(repeating: "x", count: 1 + $0 % 17) }
        let terminal = makeTerminal(columns: 40, rows: 4, lines: lines)
        let report = try readRetainedRowShape(of: terminal, stimulus: "mixed", fedByteCount: 0)
        let composition = report.composition

        #expect(composition.styledCellCounts.count == report.retainedRowCount)
        #expect(composition.scalarCounts.count == report.retainedRowCount)
        #expect(composition.maxSingleScalarValues.count == report.retainedRowCount)
        for (index, stored) in report.storedCellCounts.enumerated() {
            #expect(composition.scalarCounts[index] == stored)
            #expect(composition.styleRunCounts[index] == 1)
            #expect(composition.maxSingleScalarValues[index] == Int(UnicodeScalar("x").value))
        }
    }

    @Test("A styled run is counted as one run, and its cells as styled")
    func styledRunsAreCountedAsRuns() throws {
        // Intent: a row of plain text with a coloured middle reports its styled cells and
        //   the number of maximal style runs, not the number of style changes or cells.
        // Why it exists: `F11`'s run-length pricing is denominated in runs. Counting
        //   transitions rather than runs would under-price a row by one entry; counting
        //   styled cells as runs would over-price a uniformly styled row by its whole
        //   length, which is the difference between run-length styles winning and losing.
        var terminal = Terminal(columns: 40, rows: 4)!
        for _ in 0..<20 {
            terminal.feed(Array("aa\u{1B}[31mbbb\u{1B}[0mcc\r\n".utf8))
        }
        let report = try readRetainedRowShape(of: terminal, stimulus: "styled", fedByteCount: 0)
        let composition = report.composition

        #expect(report.retainedRowCount > 0)
        for index in 0..<report.retainedRowCount {
            #expect(report.storedCellCounts[index] == 7)
            #expect(composition.styledCellCounts[index] == 3)
            #expect(composition.styleRunCounts[index] == 3)
            #expect(composition.distinctStyleCounts[index] == 2)
        }
    }

    @Test("A combining sequence is one multi-scalar cell, and widens the row's scalar tier")
    func multiScalarCellsAreCountedOnce() throws {
        // Intent: a base scalar plus a combining mark is one cell holding two scalars, and
        //   the row's widest *single-scalar* cell is unaffected by it.
        // Why it exists: the fixed-width scalar slot `F11` prices takes its tier from
        //   single-scalar cells only, because a multi-scalar cell is an indirection at any
        //   tier. If the tier were taken from every scalar, one combining mark would push
        //   an otherwise-ASCII row to a wide slot and silently erase the saving the
        //   candidate is chosen for.
        var terminal = Terminal(columns: 40, rows: 4)!
        for _ in 0..<20 { terminal.feed(Array("cafe\u{0301}\r\n".utf8)) }
        let report = try readRetainedRowShape(of: terminal, stimulus: "combining", fedByteCount: 0)
        let composition = report.composition

        #expect(report.retainedRowCount > 0)
        for index in 0..<report.retainedRowCount {
            #expect(report.storedCellCounts[index] == 4)
            #expect(composition.multiScalarCellCounts[index] == 1)
            #expect(composition.scalarCounts[index] == 5)
            #expect(composition.nonASCIIScalarCounts[index] == 1)
            #expect(composition.maxSingleScalarValues[index] < 0x80)
        }
    }

    @Test("UTF-8 byte counts follow the encoding's own boundaries")
    func utf8ByteCountsMatchTheEncoding() {
        // Intent: `utf8ByteCount` returns 1/2/3/4 at the encoding's real boundaries.
        // Why it exists: it is spelled out rather than delegated to `String`, so nothing
        //   but a test holds it to the encoding. A text-packed row's whole payload size is
        //   this function summed, so an off-by-one boundary would misprice a candidate.
        #expect(utf8ByteCount(of: "a") == 1)
        #expect(utf8ByteCount(of: "\u{7F}") == 1)
        #expect(utf8ByteCount(of: "\u{80}") == 2)
        #expect(utf8ByteCount(of: "\u{7FF}") == 2)
        #expect(utf8ByteCount(of: "\u{800}") == 3)
        #expect(utf8ByteCount(of: "\u{FFFF}") == 3)
        #expect(utf8ByteCount(of: "\u{10000}") == 4)
    }

    @Test("Every reduction divides by the row count its per-row arrays carry")
    func reductionsShareOneRowCount() throws {
        // Intent: the reductions that sum over `storedCellCounts` and the reductions that
        //   divide by a row count use the same number of rows, on a history whose rows are
        //   of mixed length and whose full-width price is not its ragged one.
        // Why it exists: the report used to carry a row count stored beside the per-row
        //   arrays, which made two denominators the fractions could disagree on -- and any
        //   disagreement understated what retained rows cost, in the direction that flatters
        //   whatever `research/28/H2` and `research/28/H3` are being priced against. One
        //   denominator is the fix; this states it as arithmetic rather than as a field.
        // Scenario: forty rows between 1 and 17 columns wide, in a 40-column pane, so the
        //   full-width and ragged prices differ and a wrong row count moves the fractions.
        let lines = (0..<40).map { String(repeating: "x", count: 1 + $0 % 17) }
        let terminal = makeTerminal(columns: 40, rows: 4, lines: lines)
        let report = try readRetainedRowShape(of: terminal, stimulus: "mixed", fedByteCount: 0)

        #expect(report.retainedRowCount == report.storedCellCounts.count)
        #expect(report.retainedRowCount > 1)
        let perFullRow = rowAllocation(
            storedCells: report.columns, cellStrideBytes: report.cellStrideBytes
        )
        #expect(report.fullWidthAllocatedBytes == report.storedCellCounts.count * perFullRow.allocated)
        #expect(
            report.realizedSavingFraction
                == 1 - Double(report.allocatedBytes) / Double(report.fullWidthAllocatedBytes)
        )
        #expect(
            report.paperSavingFraction
                == 1 - Double(report.requestBytes)
                    / Double(report.storedCellCounts.count * perFullRow.request)
        )
        #expect(report.realizedSavingFraction > 0)
    }

    @Test("A decoded report still derives its row count from the rows it carries")
    func decodedReportDerivesItsRowCount() throws {
        // Intent: after a round trip through the JSON the probe CLI writes, the report's row
        //   count is still its per-row array's length.
        // Why it exists: `retainedRowCount` is a derivation now, not a stored field, so it is
        //   no longer an encoded key that a reader could find disagreeing with the arrays
        //   beside it. That is the wire contract `scripts/terminal-retained-row-shape.py`
        //   already assumed, deriving `len(counts)` itself; this pins that it holds.
        let lines = (0..<40).map { String(repeating: "x", count: 1 + $0 % 17) }
        let terminal = makeTerminal(columns: 40, rows: 4, lines: lines)
        let report = try readRetainedRowShape(of: terminal, stimulus: "mixed", fedByteCount: 0)

        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(RetainedRowShapeReport.self, from: encoded)

        #expect(decoded == report)
        #expect(decoded.retainedRowCount == decoded.storedCellCounts.count)
        let keys = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(keys["storedCellCounts"] != nil)
        #expect(keys["retainedRowCount"] == nil)
    }

    @Test("A geometry the engine will not build is named as such")
    func rejectedGeometryIsNamedApart() {
        // Intent: `measureRetainedRowShape` refuses a one-column geometry with the failure
        //   that accuses the geometry, not the one that accuses the engine.
        // Why it exists: reading a retained row can now fail too, and both failures reach the
        //   same `fail(...)` in `main.swift`. Two causes behind one message is what the
        //   `--columns` minimum in `RetainedRowProbeCommandLine` was added to end, so the
        //   second cause has to arrive under its own name.
        #expect(throws: RetainedRowShapeFailure.geometryRejected(columns: 1, rows: 4)) {
            try measureRetainedRowShape(stimulus: "narrow", chunks: [], columns: 1, rows: 4)
        }
    }
}
