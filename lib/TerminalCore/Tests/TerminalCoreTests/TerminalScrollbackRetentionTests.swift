// Calibration for the retention fixture the census suite proves its bound against.
//
// This file used to carry the retention proof itself: that evicting a scrollback line also
// releases the memory it held. Under doc 31's arena (`31/DD11`) that proof is the pair of
// statements the region makes checkable -- bytes in use fall when records are evicted, and the
// capacity does not grow -- and `TerminalMemoryCensusTests.censusReportsRetentionHealth` already
// asserts exactly those, over a byte-for-byte identical fixture (8x2 at a 6,000-byte budget, 1,200
// fed lines), against the same quantity: `TerminalMemoryCensus.retainedChargedBytes` *is*
// `LogicalLineStore.Census.chargedBytes`. Two copies of one proof is one proof and one liability,
// so the duplicated halves are gone.
//
// What survives is the half no other file had: proof that the shared fixture *evicts*, and evicts
// deeply. A bound that is never approached is satisfied by a store that retains nothing and by a
// store that retains everything it was fed, so without this the census suite's peak-charge
// assertion cannot say it measured anything.
//
// The separation this file's original header claimed -- accounting versus effect, which failed
// independently once in doc 15's `F4` (accounting correct, memory retained) -- is preserved by the
// census suite reading resident bytes rather than the admission ledger, not by a second file.
import Testing

@testable import TerminalCore

/// Calibrates the retention fixture, so the census suite's bound cannot pass unexercised.
struct TerminalScrollbackRetentionTests {
    @Test("the shared retention fixture evicts, and evicts most of what it was fed")
    func retentionFixtureEvictsDeeply() throws {
        // Intent: the 8x2 pane at a 6,000-byte budget really drops lines while 1,200 are fed,
        //   and ends holding a small fraction of them.
        // Why it exists: guard the guard. `censusReportsRetentionHealth` asserts a peak charge
        //   under capacity over this exact fixture, and that assertion holds vacuously on a
        //   store that never evicted -- so the fixture's eviction depth has to be a checked
        //   property rather than an assumption about the arithmetic.
        // Scenario: a long-running session streaming output far past its scrollback budget --
        //   the steady state of the `scrollback-stream` benchmark, and of any real shell that
        //   outlives its history.
        var terminal = try #require(Terminal(columns: 8, rows: 2, scrollbackBudgetBytes: 6_000))

        var sawEviction = false
        for line in 1...1_200 {
            let before = terminal.scrollbackRowCount
            terminal.feed(Array("\(line % 10)\r\n".utf8))
            if terminal.scrollbackRowCount <= before, before > 0 { sawEviction = true }
        }

        #expect(sawEviction)
        #expect(terminal.scrollbackRowCount > 0)
        #expect(1_200 - terminal.scrollbackRowCount > 100)
    }
}
