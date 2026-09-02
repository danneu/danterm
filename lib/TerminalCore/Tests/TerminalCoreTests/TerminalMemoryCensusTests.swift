// Behavioral proofs for the permanent grid-memory census.
//
// The census exists so that questions like "how many bytes is the grid holding, and in what shape"
// can be answered on demand instead of by widening `private` members for one measurement and
// reverting them -- which is how `research/12/F1` and `research/12/F3` were taken, and why neither
// can be re-run.
// These tests pin the counts a caller reasons about, so the census can be trusted as evidence
// without re-deriving it each time.
import Testing

@testable import TerminalCore

/// Keeps the census honest about what the grid actually holds, since findings are built on it.
struct TerminalMemoryCensusTests {
    @Test("census walks retained records without materializing display rows")
    func censusMaterializesNoRetainedRows() throws {
        // Intent: memory census reads retained storage directly without constructing display rows.
        // Why it exists: allocating one row per retained display row perturbs the footprint that
        //   the memory probe is measuring.
        // Scenario: deep retained history is censused while the materialization instrument counts.
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        for line in 0..<1_000 { terminal.feed(Array("line \(line)\r\n".utf8)) }

        let materializedRows = Instrument.retainedRowMaterialization.measure {
            _ = terminal.memoryCensus
        }

        #expect(materializedRows == 0)
    }

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
        // Cell storage is no longer one stride times one count: doc 31 prices retained content
        // by the record arena and live rows by the struct, so the identity that used to hold is
        // now a sum of two terms. Both are reported, which is what keeps it checkable.
        #expect(census.cellStorageBytes
            == census.screenRowCount * 20 * census.cellStrideBytes
                + census.retainedArenaBytesInUse)
        #expect(census.retainedStoredCellCount == 3)
        #expect(census.retainedArenaBytesInUse < 20 * census.cellStrideBytes)
    }

    @Test("census counts both resident screens while the alternate is live")
    func alternateScreenCensus() throws {
        // Intent: an active alternate screen does not hide the retained primary from the census.
        // Why it exists: the census must price every resident cell, and its two-screen walk is a
        //   separate consumer from style and hyperlink reclamation.
        // Scenario: one identified cell lives on each screen when the census is taken.
        var terminal = try #require(Terminal(columns: 2, rows: 2))
        terminal.feed(Array("p\u{1B}[?1047ha".utf8))

        let census = terminal.memoryCensus

        #expect(terminal.isAlternateScreenActive)
        #expect(census.screenRowCount == 4)
        #expect(census.cellCount == 8)
        #expect(census.rowStorageAllocationCount == 4)
        #expect(census.contentIdentityCellCount == 2)
        #expect(census.distinctContentIdentityCount == 2)
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
        let census = terminal.memoryCensus
        #expect(census.cellCount == 8 + 3)
        // The retained cells are unstyled; the eight live blank cells carry the active red pen.
        #expect(census.styledCellCount == 8)
        #expect(census.distinctStyleCount == 2)
    }

    @Test("open retained tails contribute every stored census field")
    func openRetainedTailCensus() throws {
        // Intent: an open retained record contributes style, spill, hyperlink, and identity counts.
        // Why it exists: open records keep hyperlink and identity tables outside the arena, so a
        //   closed-record-only walk silently reads their counted terms as zero.
        // Scenario: styled linked text with a multi-scalar cell soft-wraps into one-row history.
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("\u{1B}[31m\u{1B}]8;;https://example.test\u{7}e\u{301}abcx".utf8))

        let census = terminal.memoryCensus

        #expect(census.retainedStoredCellCount == 4)
        #expect(census.styledCellCount == 8)
        #expect(census.hyperlinkCellCount == 5)
        #expect(census.contentIdentityCellCount == 5)
        #expect(census.multiScalarCellCount == 1)
    }

    @Test("stored census excludes deferred spacers and counts wide cells by storage")
    func storedCellShapes() throws {
        // Intent: retained census counts arena words, not cells synthesized by the display fold.
        // Why it exists: deferred spacers and wide cells distinguish stored from painted counts.
        // Scenario: a wide cluster wraps after two narrow cells in a three-column terminal.
        var terminal = try #require(Terminal(columns: 3, rows: 1))
        terminal.feed(Array("ab\u{754C}".utf8))

        let census = terminal.memoryCensus

        #expect(terminal.scrollbackRow(at: 0)?.cells.last?.kind == .spacerHead)
        #expect(census.retainedStoredCellCount == 2)
        #expect(census.cellCount == 3 + 2)

        var wide = try #require(Terminal(columns: 3, rows: 1))
        wide.feed(Array("\u{754C}\r\n".utf8))
        #expect(wide.memoryCensus.retainedStoredCellCount == 2)
    }

    @Test("arena wraps do not duplicate retained cell counts")
    func arenaWrapCensus() throws {
        // Intent: an arena wrap keeps one stored count per retained cell word.
        // Scenario: one never-terminated line crosses the small arena's physical boundary.
        var terminal = try #require(
            Terminal(columns: 16, rows: 1, scrollbackBudgetBytes: 1 << 14)
        )
        terminal.feed(Array("\u{1B}[31m\u{1B}]8;;https://example.test\u{7}".utf8))
        terminal.feed(Array(String(repeating: "e\u{301}", count: 16 * 400).utf8))

        let census = terminal.memoryCensus

        #expect(census.scrollbackRecordCount == 1)
        #expect(census.cellCount == 16 + census.retainedStoredCellCount)
        #expect(census.styledCellCount == census.cellCount)
        #expect(census.hyperlinkCellCount == census.cellCount)
        #expect(census.contentIdentityCellCount == census.cellCount)
        #expect(census.multiScalarCellCount == census.cellCount)
    }

    @Test("fragmented retained identities survive per-cell encoding")
    func fragmentedRetainedIdentities() throws {
        // Intent: retained identity counts include the fragmented shape encoded per stored cell.
        // Why it exists: the arena chooses between run and per-cell tables, and reading only the
        //   common run encoding makes fragmented output silently disappear from the census.
        // Scenario: cursor skips split three printed identities across a five-cell retained row.
        var terminal = try #require(Terminal(columns: 5, rows: 1))
        terminal.feed(Array("a\u{1B}[1Cb\u{1B}[1Cc\r\n".utf8))

        #expect(terminal.memoryCensus.contentIdentityCellCount == 3)
    }

    @Test("identity census clips closed runs to a head-trimmed record")
    func headTrimmedIdentityRuns() {
        // Intent: a head trim excludes identities before the retained window and keeps those after.
        // Why it exists: closed side tables keep pre-trim coordinates, including runs that no
        //   longer intersect the record and must not form an invalid decode range.
        // Scenario: eviction trims the first display row from one two-row logical record.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        let row = { (base: Terminal.ContentIdentity, softWrapped: Bool) -> Terminal.GridRow in
            var row = Terminal.GridRow(cells: (0..<4).map { offset in
                Terminal.GridCell(
                    scalars: TerminalScalars("x"),
                    kind: .narrow,
                    contentIdentity: base + Terminal.ContentIdentity(offset)
                )
            })
            row.isSoftWrapped = softWrapped
            return row
        }
        store.admit(row(100, true))
        store.admit(row(200, false))

        let evicted = store.evictOneDisplayRow()
        #expect(evicted)
        var identities: [Terminal.ContentIdentity] = []
        store.forEachContentIdentity { identities.append($0) }

        #expect(identities == [200, 201, 202, 203])
    }

    @Test("identity census clips an open table to a head-trimmed record")
    func headTrimmedOpenIdentityTable() {
        // Intent: a head trim excludes open-table identities before the retained window.
        // Why it exists: the open tail keeps original offsets while its stored cells move.
        // Scenario: eviction trims the first display row from one open two-row record.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        let row = { (base: Terminal.ContentIdentity) -> Terminal.GridRow in
            var row = Terminal.GridRow(cells: (0..<4).map { offset in
                Terminal.GridCell(
                    scalars: TerminalScalars("x"),
                    kind: .narrow,
                    hyperlinkId: Terminal.HyperlinkId(base / 100),
                    contentIdentity: base + Terminal.ContentIdentity(offset)
                )
            })
            row.isSoftWrapped = true
            return row
        }
        store.admit(row(100))
        store.admit(row(200))

        let evicted = store.evictOneDisplayRow()
        #expect(evicted)
        var hyperlinks: [Terminal.HyperlinkId] = []
        store.forEachHyperlinkId { hyperlinks.append($0) }
        var identities: [Terminal.ContentIdentity] = []
        store.forEachContentIdentity { identities.append($0) }

        #expect(hyperlinks == [2, 2, 2, 2])
        #expect(identities == [200, 201, 202, 203])
    }

    @Test("identity census clips a closed per-cell table to a head-trimmed record")
    func headTrimmedPerCellIdentityTable() {
        // Intent: a head trim excludes per-cell identities before the retained window.
        // Why it exists: fragmented identities use a different closed arena encoding than runs.
        // Scenario: eviction trims four of eight repeated identities, which force per-cell storage.
        var store = Terminal.LogicalLineStore(budgetBytes: 1 << 16, width: 4)
        let row = { (hyperlink: Terminal.HyperlinkId, softWrapped: Bool) -> Terminal.GridRow in
            var row = Terminal.GridRow(cells: (0..<4).map { _ in
                Terminal.GridCell(
                    scalars: TerminalScalars("x"),
                    kind: .narrow,
                    hyperlinkId: hyperlink,
                    contentIdentity: 300
                )
            })
            row.isSoftWrapped = softWrapped
            return row
        }
        store.admit(row(1, true))
        store.admit(row(2, false))

        let evicted = store.evictOneDisplayRow()
        #expect(evicted)
        var hyperlinks: [Terminal.HyperlinkId] = []
        store.forEachHyperlinkId { hyperlinks.append($0) }
        var identities: [Terminal.ContentIdentity] = []
        store.forEachContentIdentity { identities.append($0) }

        #expect(hyperlinks == [2, 2, 2, 2])
        #expect(identities == [300, 300, 300, 300])
    }

    @Test("cell count stays stable when resize moves retained display rows")
    func retainedCellCountIsWidthFree() throws {
        // Intent: a resize can move display rows without changing whole-grid stored cell counts.
        // Why it exists: a census based on painted rows changes its denominator on pane resize.
        // Scenario: equal live-grid capacity and a blank top row let width and height change while
        //   the retained display-row count moves but no stored content crosses the boundary.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("abcd\r\nefgh\r\nijkl\r\nmnop".utf8))
        terminal.feed(Array("\u{1B}[1;1H\u{1B}[2K\u{1B}[2;1H".utf8))
        let before = terminal.memoryCensus

        terminal.resize(columns: 8, rows: 1)
        let after = terminal.memoryCensus

        #expect(after.scrollbackRowCount > before.scrollbackRowCount)
        #expect(after.retainedStoredCellCount == before.retainedStoredCellCount)
        #expect(after.cellCount == before.cellCount)
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
        #expect(census.cellStrideBytes == 16)

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
            == 2 * 20 * census.cellStrideBytes + census.retainedArenaBytesInUse)
        #expect(census.retainedStoredCellCount == 9 * 4)
        #expect(census.scrollbackRecordCount == 9)
        // Live rows only: history's cells all live in the one arena, so it owns no per-row
        // allocation for the census to count (`research/31/DD11`).
        #expect(census.rowStorageAllocationCount == 2)
    }

    @Test("the census reports the fields doc 15's hypotheses are sized against")
    func hypothesisFieldCensus() throws {
        // Intent: styled cells, distinct styles, multi-scalar spills, hyperlink cells, and
        //   content-identity cells are all reported, since H2/H3/H4/H5 are sized on exactly these.
        // Why it exists: `research/12/F3` measured all five with a throwaway probe that was reverted,
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

    @Test("history that has evicted rows charges no more than the arena it was built at")
    func censusReportsRetentionHealth() throws {
        // Intent: the census surfaces the invariant `research/15/F4` found broken, restated for the
        //   record arena, so any future measurement carries its own proof that it is not
        //   measuring retained garbage -- and prices a retained cell while that is true.
        // Why it exists: F4's waste -- storage held for rows already evicted -- was invisible to
        //   every existing accessor, and it failed while the admission accounting stayed correct:
        //   accounting and effect are separate observables, which is why this test reads resident
        //   bytes rather than the ledger. With one region there are no per-row allocations left to
        //   strand, so the proof becomes "bytes in use fall when records are evicted, and the
        //   capacity never grows" (`research/31/DD11`). The `sawEviction` and eviction-depth expectations
        //   guard the guard: a peak-charge bound that is never approached is satisfied both by a
        //   store that retains nothing and by one that retains everything it was fed, so the
        //   fixture's eviction depth has to be checked rather than assumed.
        // Scenario: a long-running session streaming output far past its scrollback budget -- the
        //   steady state of the `scrollback-stream` benchmark, and of any shell that outlives its
        //   history.
        var terminal = try #require(Terminal(columns: 8, rows: 2, scrollbackBudgetBytes: 6_000))
        let capacity = terminal.memoryCensus.retainedArenaCapacityBytes
        var peak = 0
        var sawEviction = false
        for line in 1...1_200 {
            let before = terminal.scrollbackRowCount
            terminal.feed(Array("\(line % 10)\r\n".utf8))
            if terminal.scrollbackRowCount <= before, before > 0 { sawEviction = true }
            peak = max(peak, terminal.memoryCensus.retainedChargedBytes)
        }

        let census = terminal.memoryCensus
        #expect(sawEviction)
        #expect(1_200 - terminal.scrollbackRowCount > 100)
        #expect(census.scrollbackRowCount > 0)
        #expect(census.retainedArenaCapacityBytes == capacity)
        #expect(peak <= capacity)
        #expect(census.hasRetainedStorageOverdraft == false)

        terminal.feed(Array("\u{1B}[3J".utf8))
        #expect(terminal.memoryCensus.retainedArenaBytesInUse == 0)
        #expect(terminal.memoryCensus.retainedArenaCapacityBytes == capacity)

        // What a retained cell costs, migrated here from the deleted
        // `TerminalScrollbackBudgetTests.historyRespectsItsBudgetInRealBytes`, which priced it
        // over 20,000 lines against the production arena and so only ever in the regime where
        // nothing is reclaimed. It needs its own fixture: the per-record header is amortized over
        // a record's cells, and the one-character lines above hold one cell each, so their average
        // is all header. Ordinary-width lines at the same small budget put it in the evicting
        // regime instead, which is where the number matters.
        var wide = try #require(Terminal(columns: 179, rows: 2, scrollbackBudgetBytes: 6_000))
        for line in 0..<200 {
            wide.feed(Array("DANTERM-BUDGET-\(line) sustained plain-text output payload\r\n".utf8))
        }
        let wideCensus = wide.memoryCensus
        // Eviction is observed, not inferred from a row count the viewport could account for.
        #expect(wide.primaryHistoryText.contains("DANTERM-BUDGET-0 ") == false)
        #expect(wideCensus.retainedStoredCellCount > 0)
        // Bounded on both sides: a record's cell is 8 bytes, so the floor says a retained cell
        // really is packed, and the ceiling says the header and side tables have not grown into
        // a second cell's worth.
        #expect(wideCensus.retainedBytesPerStoredCell > 8)
        #expect(wideCensus.retainedBytesPerStoredCell < Double(wideCensus.cellStrideBytes))
    }
}
