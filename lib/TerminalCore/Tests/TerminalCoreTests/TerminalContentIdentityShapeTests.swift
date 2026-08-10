// Behavioral proofs for the retained-row `contentIdentity` shape reader.
//
// The reader exists for one measurement doc 28's `PR1` cannot take without it: a retained
// row's `contentIdentity` field is allocated once per printed cell, so preserving it in a
// packed row costs either 4 bytes on every stored cell or a small constant per contiguous
// run -- and which one recorded content forces is the difference between C6's headline and
// no headline. The probe reads retained rows through the public row API, which deliberately
// does not carry `contentIdentity`, so nothing downstream could see the field at all.
//
// These tests pin what a "run" means, because the whole pricing rests on it: contiguous in
// *print* order, not merely present. A reader that counted identified cells, or that let a
// cursor jump pass as contiguous, would report a single-run fraction near 1.0 on any
// content and price the target variant into existence.
import Testing

@testable import TerminalCore

/// Holds the run definition the packing candidates are priced against.
struct TerminalContentIdentityShapeTests {
    @Test("A row printed left to right is a single contiguous identity run")
    func contiguousPrintIsOneRun() throws {
        // Intent: text printed in one uninterrupted left-to-right pass reports exactly one
        //   run covering every stored cell, with none unidentified.
        // Why it exists: this is the case the cheap encoding is priced for -- a per-run base
        //   plus extent. If ordinary printed output did not come back as one run, the target
        //   variant would be unreachable and C6 would pay the per-cell floor.
        var terminal = try #require(Terminal(columns: 20, rows: 1))
        terminal.feed(Array("abcdef\r\n".utf8))

        let shape = try #require(terminal.scrollbackRecordContentIdentityShape(at: 0))

        #expect(shape.runCount == 1)
        #expect(shape.identifiedCellCount == 6)
        #expect(shape.unidentifiedCellCount == 0)
    }

    @Test("A cursor jump that leaves a gap splits the row into separate runs")
    func cursorJumpSplitsRuns() throws {
        // Intent: printing, jumping the cursor forward, and printing again reports two runs
        //   and counts every skipped column as unidentified.
        // Why it exists: the negative half of the case above, and the one that makes the
        //   measurement worth taking. TUI repaint, overwrite, and insert-mode assembly all
        //   produce rows like this; if they were counted as contiguous the pricing would be
        //   optimistic in exactly the direction the plan is trying not to assume.
        var terminal = try #require(Terminal(columns: 20, rows: 1))
        terminal.feed(Array("ab\u{1B}[6Gcd\r\n".utf8))

        let shape = try #require(terminal.scrollbackRecordContentIdentityShape(at: 0))

        #expect(shape.runCount == 2)
        #expect(shape.identifiedCellCount == 4)
        #expect(shape.unidentifiedCellCount == 3)
    }

    @Test("Overwriting a column mid-row breaks contiguity without leaving a gap")
    func overwriteBreaksContiguity() throws {
        // Intent: a row whose cells are all identified, but whose identities were not issued
        //   in column order, reports more than one run.
        // Why it exists: the subtle failure mode. A reader that split runs only on absent
        //   identities would call this row contiguous, because every cell carries one --
        //   they are simply out of sequence. Contiguity is about the values, not the count.
        var terminal = try #require(Terminal(columns: 20, rows: 1))
        terminal.feed(Array("abcd\u{1B}[2Gx\r\n".utf8))

        let shape = try #require(terminal.scrollbackRecordContentIdentityShape(at: 0))

        #expect(shape.identifiedCellCount == 4)
        #expect(shape.unidentifiedCellCount == 0)
        #expect(shape.runCount > 1)
    }

    @Test("A wide cell's shared identity does not split a run")
    func wideCellSharesOneIdentityWithoutSplitting() throws {
        // Intent: a wide glyph, whose head and tail are stamped with one identity, stays
        //   inside a single run with the ASCII around it.
        // Why it exists: `printWide` issues one identity for two columns, so a reader that
        //   demanded a strict +1 step per column would split every CJK or emoji row into
        //   runs and price non-ASCII content as fragmented when it is perfectly contiguous.
        var terminal = try #require(Terminal(columns: 20, rows: 1))
        terminal.feed(Array("a\u{4E00}b\r\n".utf8))

        let shape = try #require(terminal.scrollbackRecordContentIdentityShape(at: 0))

        #expect(shape.runCount == 1)
        #expect(shape.identifiedCellCount == 4)
    }

    @Test("A blank retained row has no identity runs at all")
    func blankRowHasNoRuns() throws {
        // Intent: a row that was never printed into reports zero runs and zero identified
        //   cells.
        // Why it exists: blank rows are a large share of some histories, and a reader that
        //   charged them a run apiece would inflate the encoding's cost on exactly the rows
        //   it costs nothing for.
        var terminal = try #require(Terminal(columns: 20, rows: 1))
        terminal.feed(Array("\r\n".utf8))

        let shape = try #require(terminal.scrollbackRecordContentIdentityShape(at: 0))

        #expect(shape.runCount == 0)
        #expect(shape.identifiedCellCount == 0)
    }

    @Test("The shape reader is bounded by the retained row count")
    func outOfRangeIndexReturnsNil() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 1))
        terminal.feed(Array("abc\r\n".utf8))

        #expect(terminal.scrollbackRecordContentIdentityShape(at: terminal.scrollbackRecordCount) == nil)
        #expect(terminal.scrollbackRecordContentIdentityShape(at: -1) == nil)
    }
}
