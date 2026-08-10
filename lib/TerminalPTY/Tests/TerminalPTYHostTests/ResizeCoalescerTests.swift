// Unit tests for `ResizeCoalescer`, the submitting-side verdict on which queued resizes
// still have work to do. These need no PTY and no owner queue: the coalescer holds only
// submission order, so its whole contract -- what a run is, what closes one, and what a
// closed run still owes -- is expressible as direct calls. Kept out of
// TerminalPTYHostTests.swift so the real-PTY gate step does not pay for them.
import Testing
@testable import TerminalPTYHost

/// Pins the run/supersession arithmetic that decides how many `TIOCSWINSZ` + reflow pairs
/// a drag costs, independent of the host that consumes the verdict.
struct ResizeCoalescerTests {
    @Test("within an open run every resize but the newest is superseded")
    func newestSubmissionInAnOpenRunSurvives() {
        let coalescer = ResizeCoalescer()

        let first = coalescer.submitResize()
        let second = coalescer.submitResize()
        let third = coalescer.submitResize()

        #expect(coalescer.isSuperseded(first))
        #expect(coalescer.isSuperseded(second))
        #expect(coalescer.isSuperseded(third) == false)
    }

    @Test("closing a run leaves only its final resize unsuperseded")
    func closingARunSealsItsSupersessionVerdicts() throws {
        // Intent: sealing a run with `closeRun()` preserves the verdicts already
        //   earned inside it -- only the last resize submitted before the barrier
        //   still has work to do.
        // Why it exists: the run counter is what `isSuperseded` matched on, so once
        //   a barrier bumped it a whole backlog reported "not superseded" and each
        //   member applied its own TIOCSWINSZ + reflow. The invariant the file
        //   states only requires the LAST resize before the barrier to apply.
        // Scenario: a drag submits a burst of grids while the owner queue is busy
        //   and one `mouseMoved`-driven `sendPointer(.move)` lands behind them,
        //   closing the run before the owner queue has drained a single resize.
        let coalescer = ResizeCoalescer()
        let submissions = (0..<40).map { _ in coalescer.submitResize() }

        coalescer.closeRun()

        for submission in submissions.dropLast() {
            #expect(coalescer.isSuperseded(submission))
        }
        #expect(coalescer.isSuperseded(try #require(submissions.last)) == false)
    }

    @Test("a resize after the barrier never supersedes one submitted before it")
    func supersessionNeverReachesAcrossABarrier() {
        let coalescer = ResizeCoalescer()
        let beforeBarrier = coalescer.submitResize()

        coalescer.closeRun()
        _ = coalescer.submitResize()
        _ = coalescer.submitResize()

        #expect(coalescer.isSuperseded(beforeBarrier) == false)
    }

    @Test("a lone resize in a sealed run still applies")
    func aLoneSealedResizeApplies() {
        let coalescer = ResizeCoalescer()
        let only = coalescer.submitResize()

        coalescer.closeRun()

        #expect(coalescer.isSuperseded(only) == false)
    }

    @Test("verdicts survive several sealed runs queried in order")
    func sealedRunsAreAnsweredInFIFOOrder() {
        let coalescer = ResizeCoalescer()
        let firstRun = (0..<3).map { _ in coalescer.submitResize() }
        coalescer.closeRun()
        let secondRun = (0..<2).map { _ in coalescer.submitResize() }
        coalescer.closeRun()
        let openRun = coalescer.submitResize()

        #expect(firstRun.map(coalescer.isSuperseded) == [true, true, false])
        #expect(secondRun.map(coalescer.isSuperseded) == [true, false])
        #expect(coalescer.isSuperseded(openRun) == false)
    }
}
