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

    // Intent: the census counts spill *tables*, one per live row and one per retained record
    // that holds one, whether the row is on the live screen or in history.
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

        #expect(terminal.memoryCensus.scrollbackRecordCount > 0)
        #expect(terminal.memoryCensus.multiScalarCellCount == 3)
        #expect(terminal.memoryCensus.multiScalarAllocationCount == 1)
    }
}
