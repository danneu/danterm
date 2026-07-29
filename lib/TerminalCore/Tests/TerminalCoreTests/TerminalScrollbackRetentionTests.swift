// Behavioral proof that evicting a scrollback row also releases the memory it held.
//
// Separate from TerminalScrollbackBudgetTests because that file proves the budget's *accounting*
// -- which rows are admitted, and what they are charged -- while this one proves the budget's
// *effect*: that a row the accounting has dropped stops costing anything. The two failed
// independently once (doc 15's F4: accounting correct, memory retained), which is what earns this
// file its own place.
import Testing

@testable import TerminalCore

/// Pins eviction to actually freeing, so history cannot silently retain rows it has dropped.
struct TerminalScrollbackRetentionTests {
    @Test("front eviction releases the evicted row's cells, not just its index")
    func frontEvictionReleasesEvictedRows() throws {
        // Intent: across sustained front eviction, history owns cell storage for exactly the rows
        //   it still reports, never for rows it has already dropped.
        // Why it exists: locks down doc 15's F4. `ScrollbackBuffer` evicts by advancing a start
        //   index, and the vacated slot kept its `GridRow` -- including the separate heap
        //   allocation its `cells` array owns -- until periodic compaction rebuilt the array. Since
        //   compaction will not run until dead slots outnumber live ones, history held up to twice
        //   the rows it admitted: ~22 MB of already-evicted cells at the production budget.
        //   `scrollbackByteCount` could not see it, because it counts only live rows.
        // Scenario: a long-running session streaming output far past its scrollback budget --
        //   the steady state of the `scrollback-stream` benchmark, and of any real shell that
        //   outlives its history.
        //
        // The geometry is small and the budget tight on purpose. The retention only became
        // observable once dead slots passed `compactIfNeeded`'s floor, so the test must cross that
        // floor; doing it with narrow rows keeps a >1,000-eviction run fast.
        var terminal = try #require(Terminal(columns: 8, rows: 2, scrollbackBudgetBytes: 6_000))

        var worstExcess = 0
        for line in 1...1_200 {
            terminal.feed(Array("\(line % 10)\r\n".utf8))
            worstExcess = max(worstExcess, terminal.retainedCellStorageRowCount - terminal.scrollbackRowCount)
        }

        // The invariant, checked continuously rather than only at the end: a single endpoint
        // assertion would pass on the old code whenever it happened to land just after a
        // compaction, since the waste is a sawtooth rather than a plateau.
        #expect(worstExcess == 0)

        // Guard the guard. If eviction never crossed the compaction floor, the run above proves
        // nothing, and a future budget or cost-model change could silently make it vacuous.
        #expect(terminal.scrollbackRowCount > 0)
        #expect(1_200 - terminal.scrollbackRowCount > 1_024)
    }

    @Test("clearing history releases every row it held")
    func clearingHistoryReleasesEveryRow() throws {
        // Intent: the bulk-clear path leaves nothing owned behind either.
        // Why it exists: F4 found the front-eviction path retaining rows and cleared the other two
        //   paths by reading them. This pins that reading, so the cheaper paths cannot regress into
        //   the same defect unnoticed.
        var terminal = try #require(Terminal(columns: 8, rows: 2, scrollbackBudgetBytes: 6_000))
        for line in 1...200 { terminal.feed(Array("\(line % 10)\r\n".utf8)) }
        #expect(terminal.scrollbackRowCount > 0)

        terminal.feed(Array("\u{1B}[3J".utf8))

        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.retainedCellStorageRowCount == 0)
    }
}
