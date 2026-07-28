// Proves the grid cell stays trivially copyable while grapheme clusters, whose scalars now live
// in row-owned storage the cell only references, survive every path that relocates a cell.
//
// Its own file because these are representation proofs, not feature proofs: they exist to fail
// when the cell regains a non-trivial member or when a new cell-relocating path forgets that a
// cluster reference resolves only against the row that owns it. Cluster semantics themselves
// belong in TerminalGraphemeTests; reflow and resize behavior in TerminalResizeTests.
import Testing

@testable import TerminalCore

/// Locks the POD cell and row-owned cluster storage to content preservation and bounded growth.
struct TerminalCellRepresentationTests {
    /// A ZWJ family: one grapheme cluster, five scalars, wide.
    private static let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"

    @Test("the grid cell is trivially copyable")
    func gridCellIsTriviallyCopyable() {
        // Intent: the grid cell carries no reference-counted member, so copying one is a
        //   memory copy.
        // Why it exists: this is the entire point of moving cluster scalars into row storage.
        //   Every grid shift and blank fill copies cells in bulk; a single non-trivial member
        //   silently puts outlined copy/destroy back on those paths, which profiling measured
        //   at -21.5% on incremental-screen-updates and -9.7% on scrollback-stream.
        // Scenario: spec-first -- nothing in the type system stops someone adding an array or
        //   a class reference to the cell, so the check has to be an assertion.
        #expect(Terminal.isGridCellTriviallyCopyable)
    }

    @Test("a cluster survives scrolling into scrollback and eviction of earlier rows")
    func clusterSurvivesScrollbackEntryAndEviction() throws {
        var terminal = try #require(
            Terminal(columns: 8, rows: 2, scrollbackBudgetBytes: 1024)
        )
        // Enough rows ahead of the cluster that the budget evicts them, and one behind it so
        // the cluster row has itself moved through scrollback rather than sitting at its head.
        for filler in 0..<30 {
            terminal.feed(Array("row\(filler)\r\n".utf8))
        }
        terminal.feed(Array("\(Self.family)\r\nz\r\n".utf8))

        #expect(terminal.scrollbackRowCount < 31)
        let retained = (0..<terminal.scrollbackRowCount).compactMap {
            terminal.scrollbackRow(at: $0)?.cells.first
        }
        let cluster = try #require(retained.first { $0.kind == .wideHead })
        #expect(cluster.scalars == TerminalScalars(Self.family.unicodeScalars))
    }

    @Test("a cluster survives reflow narrower and back wider")
    func clusterSurvivesPrimaryReflow() throws {
        // Intent: reflow preserves cluster content scalar-exact in both directions.
        // Why it exists: reflow carries whole cells through transient units and re-packs them
        //   into fresh rows, so a cluster reference copied verbatim would resolve against the
        //   wrong row's storage -- most likely surfacing as the base scalar alone.
        // Scenario: spec-first -- a user drags the window narrower and back while an emoji
        //   family sits on screen.
        var terminal = try #require(Terminal(columns: 10, rows: 3))
        terminal.feed(Array("ab\(Self.family)cd".utf8))

        terminal.resize(columns: 4, rows: 3)
        #expect(terminal.screenText.contains(Self.family))

        terminal.resize(columns: 12, rows: 3)
        #expect(terminal.screenText.contains(Self.family))

        let head = try #require(
            (0..<12).compactMap { terminal.cell(row: 0, column: $0) }
                .first { $0.kind == .wideHead }
        )
        #expect(head.scalars == TerminalScalars(Self.family.unicodeScalars))
    }

    @Test("a cluster survives alternate-screen resizing")
    func clusterSurvivesAlternateScreenResize() throws {
        // Intent: alternate-screen resizing preserves cluster content scalar-exact.
        // Why it exists: the alternate screen never reflows -- it clips into fresh rows built
        //   from cells copied out of the old ones -- which is a second, independent path that
        //   changes a cell's row owner.
        // Scenario: spec-first -- a full-screen TUI shows an emoji family and the window is
        //   resized under it.
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

    @Test("a last-column narrow-to-wide upgrade wraps the whole cluster onto the next row")
    func clusterSurvivesLastColumnWidthUpgrade() throws {
        // Intent: a narrow cluster that widens in the final column arrives at column 0 of the
        //   next row with every scalar it had accumulated.
        // Why it exists: this rebuild is the third path that constructs a cell under a
        //   different row owner, and unlike the two resize paths it fires during normal
        //   printing. A cluster that arrived as its base scalar alone would still render
        //   plausibly, so the assertion has to be scalar-exact.
        // Scenario: spec-first -- a keycap sequence (`#` then a combining enclosing keycap,
        //   then VS16) lands in the last column with autowrap on.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.moveCursor(row: 0, column: 3)
        terminal.feed(Array("#\u{20E3}\u{FE0F}".utf8))

        #expect(terminal.geometry.rows[0].cells[3].kind == .spacerHead)
        #expect(terminal.geometry.rows[0].isSoftWrapped)
        #expect(terminal.cell(row: 1, column: 0)?.kind == .wideHead)
        #expect(
            terminal.cell(row: 1, column: 0)?.scalars == ["#", "\u{20E3}", "\u{FE0F}"]
        )
    }

    @Test("a cluster survives insertion and deletion within its row")
    func clusterSurvivesIntraRowShifts() throws {
        var terminal = try #require(Terminal(columns: 12, rows: 2))
        terminal.feed(Array("ab\(Self.family)".utf8))

        terminal.feed(Array("\u{1B}[1;1H\u{1B}[2@".utf8))
        #expect(
            terminal.cell(row: 0, column: 4)?.scalars
                == TerminalScalars(Self.family.unicodeScalars)
        )

        terminal.feed(Array("\u{1B}[1;1H\u{1B}[2P".utf8))
        #expect(
            terminal.cell(row: 0, column: 2)?.scalars
                == TerminalScalars(Self.family.unicodeScalars)
        )
    }

    @Test("a cluster longer than any inline capacity round-trips intact")
    func longClusterRoundTrips() throws {
        // Intent: cluster length is unbounded -- storage is a row-owned array, not a fixed
        //   inline capacity, so nothing truncates at N scalars.
        // Why it exists: a fixed inline capacity was the rejected alternative; this fails if
        //   anyone reintroduces one.
        // Scenario: spec-first -- a base letter followed by 200 combining marks, which is
        //   degenerate but legal, and one grapheme cluster.
        let marks = String(repeating: "\u{0301}", count: 200)
        let long = "e" + marks
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array(long.utf8))

        let cell = try #require(terminal.cell(row: 0, column: 0))
        #expect(cell.kind == .narrow)
        #expect(cell.scalars == TerminalScalars(long.unicodeScalars))

        terminal.resize(columns: 5, rows: 2)
        #expect(terminal.cell(row: 0, column: 0)?.scalars == TerminalScalars(long.unicodeScalars))
    }

    @Test("rewriting a row's cluster cells leaves storage proportional to its live clusters")
    func clusterStorageTracksLiveClustersNotRewrites() throws {
        // Intent: a row's cluster storage stays proportional to the clusters it currently
        //   holds, however many times those cells are overwritten.
        // Why it exists: row-owned storage has no per-cell reclamation trigger -- an
        //   overwritten cluster just stops being referenced -- so without compaction a cell
        //   redrawn once per frame would grow its row without bound.
        // Scenario: spec-first -- a status line that repaints the same emoji in place, which
        //   is what a progress indicator or a clock does for the life of the session.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        for _ in 0..<500 {
            terminal.feed(Array("\u{1B}[1;1H\(Self.family)".utf8))
        }

        #expect(
            terminal.cell(row: 0, column: 0)?.scalars
                == TerminalScalars(Self.family.unicodeScalars)
        )
        // Five live scalars in the row. The bound leaves room for the compaction floor and one
        // uncompacted generation, and is nowhere near the 2500 an uncompacted row would hold.
        #expect(terminal.clusterStorageScalarCount(row: 0) <= 64)
    }
}
