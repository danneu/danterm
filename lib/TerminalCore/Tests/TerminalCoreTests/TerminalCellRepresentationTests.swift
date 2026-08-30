// Proves that live cells share the arena word without losing row-owned cluster content.

import Testing

@testable import TerminalCore

/// Locks the POD cell and row-owned spill storage to exact content and bounded growth.
struct TerminalCellRepresentationTests {
    private static let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"

    @Test("the live grid cell is POD with a 16-byte stride")
    func liveGridCellShape() {
        #expect(Terminal.isGridCellTriviallyCopyable)
        #expect(Terminal.gridCellStrideBytes == 16)
    }

    @Test("the blank fill pattern is exactly one cell stride")
    func blankFillPatternMatchesCellStride() {
        // Intent: the pattern a recycled row is filled from covers one whole cell and nothing
        //   more.
        // Why it exists: the fill copies raw bytes, so a cell that grew past the pattern would
        //   write a shredded cell rather than fail (`research/39/H6` PO5, AR1).
        #expect(Terminal.blankCellPatternByteCount == Terminal.gridCellStrideBytes)
    }

    @Test("a cluster survives reflow narrower and back wider")
    func clusterSurvivesPrimaryReflow() throws {
        var terminal = try #require(Terminal(columns: 10, rows: 6))
        terminal.feed(Array("ab\(Self.family)cd".utf8))
        #expect(terminal.screenText.hasPrefix("ab\(Self.family)cd"))
        #expect(terminal.geometry.rows[0].cells.prefix(6).map(\.kind) == [
            .narrow, .narrow, .wideHead, .wideTail, .narrow, .narrow,
        ])

        terminal.resize(columns: 4, rows: 6)
        #expect(terminal.primaryHistoryText.contains(Self.family))

        terminal.resize(columns: 12, rows: 6)
        #expect(terminal.primaryHistoryText.contains(Self.family))
    }

    @Test("a cluster survives alternate-screen resizing")
    func clusterSurvivesAlternateScreenResize() throws {
        var terminal = try #require(Terminal(columns: 10, rows: 3))
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        terminal.feed(Array("ab\(Self.family)".utf8))

        terminal.resize(columns: 6, rows: 2)

        #expect(terminal.cell(row: 0, column: 2)?.kind == .wideHead)
        #expect(
            terminal.cell(row: 0, column: 2)?.scalars
                == TerminalScalars(Self.family.unicodeScalars)
        )
    }

    @Test("a last-column width upgrade carries the whole cluster to the next row")
    func clusterSurvivesLastColumnWidthUpgrade() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.moveCursor(row: 0, column: 3)
        terminal.feed(Array("#\u{20E3}\u{FE0F}".utf8))

        #expect(terminal.geometry.rows[0].cells[3].kind == .spacerHead)
        #expect(terminal.geometry.rows[0].isSoftWrapped)
        #expect(terminal.cell(row: 1, column: 0)?.kind == .wideHead)
        #expect(terminal.cell(row: 1, column: 0)?.scalars == ["#", "\u{20E3}", "\u{FE0F}"])
    }

    @Test("equal content ignores row spill layout")
    func equalityIgnoresSpillLayout() throws {
        var direct = try #require(Terminal(columns: 8, rows: 1))
        direct.feed(Array("e\u{301}x\u{301}".utf8))

        var rewritten = direct
        rewritten.rewriteFirstRowSpillLayoutForTesting()

        #expect(direct == rewritten)
    }

    @Test("the 256-byte cluster limit survives live storage and arena admission")
    func maximumRetainedClusterRoundTrips() throws {
        let cluster = "\u{00E9}" + String(repeating: "\u{0301}", count: 127)
        #expect(cluster.utf8.count == Terminal.graphemeClusterByteLimit)
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("\(cluster)\r\n".utf8))

        #expect(terminal.scrollbackRow(at: 0)?.cells[0].scalars == TerminalScalars(cluster.unicodeScalars))
    }

    @Test("rewriting a cluster keeps live spill bytes bounded")
    func spillStorageTracksLiveClustersNotRewrites() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        let baseline = terminal.memoryCensus.cellStorageBytes
        terminal.replaceFirstCellForSpillBoundTesting(with: Self.family, count: 2_097_153)

        #expect(terminal.cell(row: 0, column: 0)?.scalars == TerminalScalars(Self.family.unicodeScalars))
        #expect(terminal.memoryCensus.cellStorageBytes <= baseline + 4_096)
        #expect(terminal.memoryCensus.multiScalarAllocationCount == 1)
    }

    // Intent: the census counts cluster *storage*, one allocation per live row that holds a
    // cluster and one per retained record that holds one, whether the row is on the live screen
    // or in history.
    // Why it exists: a retained record keeps its clusters in one shared table, so counting one
    // allocation per spilled cell overstated history and made the live and retained halves of
    // the same field mean different things.
    // Scenario: one row carries three separate multi-scalar clusters, then scrolls into history.
    @Test("a spilled row reports one allocation live and one retained")
    func spillAllocationCountsTablesNotCells() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 4))
        terminal.feed(Array("e\u{301} a\u{308} o\u{302}".utf8))

        #expect(terminal.memoryCensus.multiScalarCellCount == 3)
        #expect(terminal.memoryCensus.multiScalarAllocationCount == 1)

        terminal.feed(Array(String(repeating: "\r\n", count: 8).utf8))

        // Two: the retained record, plus the live row slot that held the clusters and keeps its
        // arena when it is recycled as a blank (`research/39/H2` AR2). The other three live rows
        // never held a cluster and allocate nothing for one.
        #expect(terminal.memoryCensus.scrollbackRecordCount > 0)
        #expect(terminal.memoryCensus.multiScalarCellCount == 3)
        #expect(terminal.memoryCensus.multiScalarAllocationCount == 2)
    }

    /// The cluster classes a row's storage has to carry, each as the scalars it is made of.
    private static let clusterClasses: [(name: String, text: String)] = [
        ("combining sequence", "e\u{0301}\u{0327}"),
        ("ZWJ sequence", family),
        ("regional indicator pair", "\u{1F1E6}\u{1F1E7}"),
        ("wide base with a mark", "\u{754C}\u{0301}"),
        ("emoji presentation upgrade", "#\u{FE0F}"),
        ("text presentation downgrade", "\u{2764}\u{FE0E}"),
    ]

    @Test("every cluster class reads back the same through every reader")
    func clusterClassesReadBackThroughEveryReader() throws {
        // Intent: a cluster is the same scalars whichever reader asks -- the cell accessor, the
        //   viewport geometry, search, the state-synchronization encoder, and history.
        // Why it exists: `research/39/H2` moved every cluster into one arena per row, so a
        //   reader that used to be handed a cluster's own array now resolves an offset and a
        //   length inside a buffer its neighbours share. A wrong one reads a neighbouring
        //   cluster's scalars, which is content a single reader can easily agree with itself
        //   about.
        // Scenario: spec-first for `research/39/H2` PO2.
        for cluster in Self.clusterClasses {
            let scalars = TerminalScalars(cluster.text.unicodeScalars)
            var terminal = try #require(Terminal(columns: 10, rows: 3))
            terminal.feed(Array(cluster.text.utf8))

            #expect(terminal.cell(row: 0, column: 0)?.scalars == scalars, "\(cluster.name)")

            // The frame path's reader, which is the one that consumes a cluster per cell.
            var rendered: TerminalScalars = .empty
            terminal.forEachViewportCell(row: 0) { column, cellScalars, _ in
                if column == 0 { rendered = cellScalars }
            }
            #expect(rendered == scalars, "\(cluster.name)")

            let found = terminal.beginSearch(cluster.text)
            #expect(found, "\(cluster.name)")

            let synchronization = terminal.stateSynchronization
            var replica = try #require(Terminal(
                columns: synchronization.columns,
                rows: synchronization.rows
            ))
            replica.feed(synchronization.bytes)
            #expect(replica.cell(row: 0, column: 0)?.scalars == scalars, "\(cluster.name)")

            terminal.feed(Array(String(repeating: "\r\n", count: 4).utf8))
            #expect(terminal.scrollbackRow(at: 0)?.cells[0].scalars == scalars, "\(cluster.name)")
            expectValidGrid(terminal)
        }
    }

    @Test("a cluster re-opened behind a later one grows without disturbing it")
    func recoveredClusterGrowsWithoutDisturbingLaterCells() throws {
        // Intent: printing a joining mark after the cursor moves back to an earlier cluster
        //   extends that cluster and leaves the later one exactly as it was, however many times
        //   the row is asked to do it.
        // Why it exists: a cluster grows in place only while it is the last one its row wrote.
        //   Re-opening an earlier cluster is the case that cannot, so it re-forms the cluster
        //   elsewhere in the row's storage and leaves the space it came from dead. Unreclaimed,
        //   that dead space is unbounded growth in a row that holds two clusters.
        // Scenario: spec-first for `research/39/H2` PO2.
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        let baseline = terminal.memoryCensus.cellStorageBytes

        for _ in 0..<200 {
            terminal.feed(Array("\u{1B}[1Ge\u{0301}\u{1B}[3Ga\u{0308}\u{1B}[2G\u{0327}".utf8))
        }

        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["e", "\u{0301}", "\u{0327}"])
        #expect(terminal.cell(row: 0, column: 2)?.scalars == ["a", "\u{0308}"])
        #expect(terminal.memoryCensus.multiScalarCellCount == 2)
        #expect(terminal.memoryCensus.cellStorageBytes <= baseline + 4_096)
        expectValidGrid(terminal)
    }

    @Test("a row of four-scalar clusters costs one allocation and its own scalars twice over")
    func aRowOfClustersCostsItsOwnScalars() throws {
        // Intent: filling a row with multi-scalar clusters costs that row one cluster
        //   allocation and bytes proportional to the scalars it holds, and the next row costs
        //   the same again rather than more.
        // Why it exists: `research/39/F10` -- the old storage allocated an array per cluster and
        //   re-copied a cluster's payload for every scalar joined to it, so a row's cost
        //   followed its cells and its rewrites rather than its content.
        // Scenario: spec-first for `research/39/H2` PO1.
        let columns = 64
        let row = (0..<columns)
            .map { _ in "a\u{0301}\u{0302}\u{0303}" }
            .joined()
        // Twice what the row's clusters weigh -- four scalars each plus the count each carries
        // -- and one array header: what a storage that doubles as it grows can hold without
        // being asked to grow again. Four bytes per scalar is the layout, not the contract; the
        // contract is that the row pays for its content once rather than per scalar or per cell.
        let budget = 2 * columns * 5 * 4 + 128

        var terminal = try #require(Terminal(columns: columns, rows: 4))
        let empty = terminal.memoryCensus.cellStorageBytes

        terminal.feed(Array(row.utf8))
        let afterFirstRow = terminal.memoryCensus.cellStorageBytes
        #expect(terminal.memoryCensus.multiScalarCellCount == columns)
        #expect(terminal.memoryCensus.multiScalarAllocationCount == 1)
        #expect(afterFirstRow - empty <= budget)

        terminal.feed(Array(("\r\n" + row).utf8))
        let afterSecondRow = terminal.memoryCensus.cellStorageBytes
        #expect(terminal.memoryCensus.multiScalarCellCount == 2 * columns)
        #expect(terminal.memoryCensus.multiScalarAllocationCount == 2)
        #expect(afterSecondRow - afterFirstRow <= afterFirstRow - empty)
        expectValidGrid(terminal)
    }

    @Test("clusters survive every movement a row makes")
    func clustersSurviveRowMovement() throws {
        // Intent: a row's clusters travel with its cells through scrolling, insertion, deletion,
        //   the alternate screen, and admission to history, and none of them moves to another
        //   cell on the way.
        // Why it exists: a cell resolves its cluster against the row that owns it, so a cell
        //   that changes row owner and keeps a bare index reads a stranger's scalars. Every
        //   movement below is a place where a row's cells are copied out of their owner.
        // Scenario: spec-first for `research/39/H2` PO3.
        let first: TerminalScalars = ["e", "\u{0301}"]
        let last: TerminalScalars = ["o", "\u{0302}"]
        // A cluster at column 0 and one at the margin: the two positions a shift can drop.
        let printed = "e\u{0301}    o\u{0302}"

        // Printed on the second row, so the scroll that follows moves it up to the first.
        var scrolled = try #require(Terminal(columns: 6, rows: 3))
        scrolled.feed(Array(("\u{1B}[2;1H" + printed + "\u{1B}[3;1H\n").utf8))
        #expect(scrolled.cell(row: 0, column: 0)?.scalars == first)
        #expect(scrolled.cell(row: 0, column: 5)?.scalars == last)

        var inserted = try #require(Terminal(columns: 6, rows: 3))
        inserted.feed(Array((printed + "\u{1B}[1;1H\u{1B}[1L").utf8))
        #expect(inserted.cell(row: 1, column: 0)?.scalars == first)
        #expect(inserted.cell(row: 1, column: 5)?.scalars == last)

        var shifted = try #require(Terminal(columns: 6, rows: 3))
        shifted.feed(Array((printed + "\u{1B}[1;2H\u{1B}[1P").utf8))
        #expect(shifted.cell(row: 0, column: 0)?.scalars == first)
        #expect(shifted.cell(row: 0, column: 4)?.scalars == last)

        var alternated = try #require(Terminal(columns: 6, rows: 3))
        alternated.feed(Array((printed + "\u{1B}[?1049h").utf8))
        alternated.feed(Array("x\u{0301}\u{1B}[?1049l".utf8))
        #expect(alternated.cell(row: 0, column: 0)?.scalars == first)
        #expect(alternated.cell(row: 0, column: 5)?.scalars == last)

        var resized = try #require(Terminal(columns: 6, rows: 3))
        resized.feed(Array(printed.utf8))
        resized.resize(columns: 4, rows: 3)
        resized.resize(columns: 8, rows: 3)
        #expect(resized.primaryHistoryText.contains("e\u{0301}") || resized.screenText.contains("e\u{0301}"))
        #expect(resized.primaryHistoryText.contains("o\u{0302}") || resized.screenText.contains("o\u{0302}"))

        var retained = try #require(Terminal(columns: 6, rows: 3))
        retained.feed(Array((printed + String(repeating: "\r\n", count: 4)).utf8))
        #expect(retained.scrollbackRow(at: 0)?.cells[0].scalars == first)
        #expect(retained.scrollbackRow(at: 0)?.cells[5].scalars == last)

        expectValidGrid(scrolled)
        expectValidGrid(inserted)
        expectValidGrid(shifted)
        expectValidGrid(alternated)
        expectValidGrid(resized)
        expectValidGrid(retained)
    }

    @Test("a copied terminal and an already-read cluster are unaffected by a later mark")
    func sharedClusterStorageStaysAValue() throws {
        // Intent: extending an open cluster never reaches a terminal copied before the extension
        //   or a payload already handed to a reader.
        // Why it exists: a row's clusters live in storage its cells share, and reading a cluster
        //   out of it is a reference to that storage rather than a copy of the cluster. Value
        //   semantics then rest entirely on copy-on-write detaching the row before it is grown.
        // Scenario: spec-first for `research/39/H2` PO5.
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("e\u{0301}".utf8))

        let copy = terminal
        let read = try #require(terminal.cell(row: 0, column: 0)?.scalars)

        terminal.feed(Array("\u{0327}".utf8))

        #expect(copy.cell(row: 0, column: 0)?.scalars == ["e", "\u{0301}"])
        #expect(read == ["e", "\u{0301}"])
        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["e", "\u{0301}", "\u{0327}"])
        expectValidGrid(terminal)
    }
}

/// Compiles only while its argument is `Sendable`, which is how `GridRow`'s conformance --
/// checked, never `@unchecked` -- is asserted at all: it is a fact about the build.
private func expectSendable(_: (some Sendable).Type) {}

private func expectGridRowIsSendable() {
    expectSendable(Terminal.GridRow.self)
}
