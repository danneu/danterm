// Behavioral proof that evicting a scrollback line also releases the memory it held.
//
// Separate from TerminalScrollbackBudgetTests because that file proves the budget's *accounting*
// -- which lines are admitted, and what they are charged -- while this one proves the budget's
// *effect*: that content the accounting has dropped stops costing anything. The two failed
// independently once (doc 15's F4: accounting correct, memory retained), which is what earns this
// file its own place.
//
// Restated for doc 31's arena (`31/DD11`). F4's waste was a heap allocation per retained row that
// eviction left owned; with one region allocated once and never grown there are no such
// allocations to strand, so the proof becomes the pair of statements that region makes checkable:
// bytes in use fall when records are evicted, and the capacity does not grow.
import Testing

@testable import TerminalCore

/// Pins eviction to actually freeing, so history cannot silently retain content it has dropped.
struct TerminalScrollbackRetentionTests {
    @Test("front eviction releases the evicted line's bytes, not just its index")
    func frontEvictionReleasesEvictedRows() throws {
        // Intent: across sustained front eviction, the arena's bytes in use stay bounded by the
        //   capacity it was built at, and that capacity never moves.
        // Why it exists: locks down doc 15's F4 in the terms the successor store makes true.
        //   The old buffer evicted by advancing a start index, and the vacated slot kept its
        //   `GridRow` -- including the separate heap allocation its `cells` array owned -- until
        //   periodic compaction rebuilt the array, so history held up to twice the rows it
        //   admitted. The arena has no per-row allocation and no compaction, so the failure mode
        //   it replaces is the head pointer failing to advance -- which shows up here as bytes in
        //   use ratcheting past the capacity rather than as a sawtooth.
        // Scenario: a long-running session streaming output far past its scrollback budget --
        //   the steady state of the `scrollback-stream` benchmark, and of any real shell that
        //   outlives its history.
        var terminal = try #require(Terminal(columns: 8, rows: 2, scrollbackBudgetBytes: 6_000))
        let capacity = terminal.scrollbackCensus.capacityBytes

        var peakCharge = 0
        var sawEviction = false
        for line in 1...1_200 {
            let before = terminal.scrollbackRowCount
            terminal.feed(Array("\(line % 10)\r\n".utf8))
            if terminal.scrollbackRowCount <= before, before > 0 { sawEviction = true }
            peakCharge = max(peakCharge, terminal.scrollbackCensus.chargedBytes)
        }

        // The invariant, checked continuously rather than only at the end: a single endpoint
        // assertion could pass on a store that ratcheted and then happened to be read low.
        #expect(peakCharge <= capacity)
        #expect(terminal.scrollbackCensus.capacityBytes == capacity)

        // Guard the guard. If eviction never ran, the run above proves nothing.
        #expect(sawEviction)
        #expect(terminal.scrollbackRowCount > 0)
        #expect(1_200 - terminal.scrollbackRowCount > 100)
    }

    @Test("clearing history releases every byte it held")
    func clearingHistoryReleasesEveryRow() throws {
        // Intent: the bulk-clear path leaves nothing owned behind either.
        // Why it exists: F4 found the front-eviction path retaining rows and cleared the other two
        //   paths by reading them. This pins that reading, so the cheaper paths cannot regress into
        //   the same defect unnoticed.
        var terminal = try #require(Terminal(columns: 8, rows: 2, scrollbackBudgetBytes: 6_000))
        for line in 1...200 { terminal.feed(Array("\(line % 10)\r\n".utf8)) }
        #expect(terminal.scrollbackRowCount > 0)
        let capacity = terminal.scrollbackCensus.capacityBytes

        terminal.feed(Array("\u{1B}[3J".utf8))

        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.scrollbackRecordCount == 0)
        #expect(terminal.scrollbackCensus.arenaBytesInUse == 0)
        #expect(terminal.scrollbackCensus.capacityBytes == capacity)
    }
}
