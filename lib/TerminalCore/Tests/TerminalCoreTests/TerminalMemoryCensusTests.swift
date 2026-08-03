// Behavioral proofs for the permanent grid-memory census.
//
// The census exists so that questions like "how many bytes is the grid holding, and in what shape"
// can be answered on demand instead of by widening `private` members for one measurement and
// reverting them -- which is how doc 12's F1 and F3 were taken, and why neither can be re-run.
// These tests pin the counts a caller reasons about, so the census can be trusted as evidence
// without re-deriving it each time.
import Testing

@testable import TerminalCore

/// Keeps the census honest about what the grid actually holds, since findings are built on it.
struct TerminalMemoryCensusTests {
    @Test("census reports compact retained cells while terminal rows stay logically full width")
    func censusReportsCompactRetainedRows() throws {
        // Intent: history storage omits default padding while terminal-facing rows remain full
        //   width and byte-identical to their pre-compaction presentation.
        // Why it exists: the memory census is the deliberate representation-level exception to
        //   transparent retained-row compaction and must report the storage actually held.
        // Scenario: a short line enters a wide pane's history and is inspected both as terminal
        //   content and as allocated cell storage.
        var terminal = try #require(Terminal(columns: 20, rows: 1))
        terminal.feed(Array("abc\r\n".utf8))

        let retained = try #require(terminal.scrollbackRow(at: 0))
        let census = terminal.memoryCensus

        #expect(retained.cells.count == 20)
        #expect(retained.cells.map(\.scalars).prefix(3) == [["a"], ["b"], ["c"]])
        #expect(retained.cells.dropFirst(3).allSatisfy { $0.kind == .padding })
        #expect(census.scrollbackRowCount == 1)
        #expect(census.cellCount == 20 + 3)
        // Cell storage is no longer one stride times one count: doc 28's `C6` prices retained
        // rows by their packed blob and live rows by the struct, so the identity that used to
        // hold is now a sum of two terms. Both are reported, which is what keeps it checkable.
        #expect(census.cellStorageBytes
            == census.screenRowCount * 20 * census.cellStrideBytes
                + census.retainedPackedPayloadBytes)
        #expect(census.retainedStoredCellCount == 3)
        #expect(census.retainedPackedPayloadBytes < 3 * census.cellStrideBytes)
    }

    @Test("trimmed retained padding remains readable through inspection and browsing render")
    func compactPaddingRemainsLogicallyVisible() throws {
        // Intent: every terminal-facing reader observes a full-width blank tail on a compact row.
        // Why it exists: pointer inspection, selection, link detection, and browsing render use
        //   separate paths, so any one of them could expose or index past the stored extent.
        // Scenario: a short retained line is browsed and queried at the pane's last column.
        var terminal = try #require(Terminal(columns: 20, rows: 1))
        terminal.feed(Array("abc\r\n".utf8))
        terminal.scroll(toTopRow: 0)

        #expect(terminal.cell(row: 0, column: 19)?.kind == .padding)
        #expect(terminal.activatableLink(at: .init(row: 0, column: 19)) == nil)
        terminal.setSelection(from: .init(row: 0, column: 19), to: .init(row: 0, column: 19))
        #expect(terminal.selectedText == "")

        var rendered: [(Int, TerminalScalars, TerminalStyle)] = []
        terminal.forEachViewportCell(row: 0) { rendered.append(($0, $1, $2)) }
        #expect(rendered.count == 20)
        #expect(rendered.map(\.0) == Array(0..<20))
        #expect(rendered[0].1 == ["a"])
        #expect(rendered[19].1.isEmpty)
        #expect(rendered[19].2 == TerminalStyle())
    }

    @Test("colored erase padding remains stored and visible in history")
    func coloredErasePaddingIsNotCompacted() throws {
        // Intent: compaction drops only cells identical to default blank padding.
        // Why it exists: background-color erase cells are visually meaningful even though they
        //   carry no scalar content, so trimming them would change browsing render output.
        // Scenario: a red pen erases the tail of a short line before it enters history.
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("abc\u{1B}[41m\u{1B}[K\r\n".utf8))

        let retained = try #require(terminal.scrollbackRow(at: 0))
        #expect(retained.cells.last?.kind == .padding)
        #expect(retained.cells.last?.style.background == .indexed(1))
        #expect(terminal.memoryCensus.cellCount == 8 + 8)
    }

    @Test("an untouched grid holds exactly one full screen of cells")
    func emptyGridCensus() throws {
        // Intent: the census's baseline is the screen itself -- rows x columns cells, one array
        //   allocation per row, and nothing in history.
        // Why it exists: every later comparison is a delta against this, so a wrong baseline
        //   silently biases every memory claim in doc 15.
        let terminal = try #require(Terminal(columns: 80, rows: 24))
        let census = terminal.memoryCensus

        #expect(census.screenRowCount == 24)
        #expect(census.scrollbackRowCount == 0)
        #expect(census.cellCount == 80 * 24)
        #expect(census.rowStorageAllocationCount == 24)
        #expect(census.cellStorageBytes == 80 * 24 * census.cellStrideBytes)

        // A blank grid must still cost a full screen: cells are stored, not implied.
        #expect(census.cellStrideBytes > 0)
        #expect(census.bytesPerCell == Double(census.cellStrideBytes))
    }

    @Test("scrolled-off rows report their compact stored-cell extent")
    func scrollbackCensus() throws {
        // Intent: history rows report only content cells while live rows remain full width.
        // Why it exists: compact retention deliberately makes the census representation-visible,
        //   so memory measurements must not silently restore the old full-width assumption.
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        for line in 1...10 { terminal.feed(Array("row\(line)\r\n".utf8)) }

        let census = terminal.memoryCensus
        // Ten newlines leave the cursor on an eleventh row, so nine rows scrolled into history
        // and eleven rows exist in total. Stated explicitly because an off-by-one here would
        // quietly bias every bytes-per-row figure derived from the census.
        #expect(census.scrollbackRowCount == 9)
        #expect(census.screenRowCount == 2)
        #expect(census.cellCount == 2 * 20 + 9 * 4)
        #expect(census.cellStorageBytes
            == 2 * 20 * census.cellStrideBytes + census.retainedPackedPayloadBytes)
        #expect(census.retainedStoredCellCount == 9 * 4)
        #expect(census.rowStorageAllocationCount == 11)
    }

    @Test("the census reports the fields doc 15's hypotheses are sized against")
    func hypothesisFieldCensus() throws {
        // Intent: styled cells, distinct styles, multi-scalar spills, hyperlink cells, and
        //   content-identity cells are all reported, since H2/H3/H4/H5 are sized on exactly these.
        // Why it exists: doc 12's F3 measured all five with a throwaway probe that was reverted,
        //   so its numbers cannot be checked or refreshed. This makes them reproducible.
        var terminal = try #require(Terminal(columns: 20, rows: 3))
        terminal.feed(Array("plain".utf8))
        terminal.feed(Array("\u{1B}[1;31mbold-red\u{1B}[0m".utf8))

        let census = terminal.memoryCensus
        #expect(census.styledCellCount == 8)
        // Two styles are resident: the default, and bold+red.
        #expect(census.distinctStyleCount == 2)
        #expect(census.hyperlinkCellCount == 0)
        #expect(census.contentIdentityCellCount == 13)

        // A grapheme cluster wider than one scalar spills into class-backed storage, which is the
        // only reference-counted allocation a cell can own.
        var spill = try #require(Terminal(columns: 8, rows: 1))
        spill.feed(Array("e\u{301}".utf8))
        #expect(spill.memoryCensus.multiScalarCellCount == 1)
        #expect(terminal.memoryCensus.multiScalarCellCount == 0)
    }

    @Test("history that has evicted rows reports no retained cell storage beyond its live rows")
    func censusReportsRetentionHealth() throws {
        // Intent: the census surfaces the invariant doc 15's F4 found broken, so any future
        //   measurement carries its own proof that it is not measuring retained garbage.
        // Why it exists: F4's waste was invisible to every existing accessor. A census that could
        //   not see it would be able to report a confidently wrong number.
        var terminal = try #require(Terminal(columns: 8, rows: 2, scrollbackBudgetBytes: 6_000))
        for line in 1...1_200 { terminal.feed(Array("\(line % 10)\r\n".utf8)) }

        let census = terminal.memoryCensus
        #expect(census.retainedRowStorageRowCount == census.scrollbackRowCount)
        #expect(census.hasRetainedRowStorageLeak == false)
    }
}
