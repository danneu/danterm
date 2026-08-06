// Swift Testing migration of the legacy `tests/TickCoalescerTests.swift`
// harness suite. Pins the pure `ghostty_app_tick` wakeup coalescer's contract
// against the schedule / drain / re-arm / concurrent matrix the legacy suite
// asserted.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct TickCoalescerTests {
    @Test("TickCoalescer: first wakeup schedules")
    func firstWakeupSchedules() {
        // Intent: noteWakeup returns true on the first call (a tick should be
        //   scheduled for the caller to honor).
        // Why it exists: pins the cold-start path so the very first runtime
        //   wakeup cannot be silently dropped.
        // Scenario: spec-first cold-start check -- a freshly constructed
        //   coalescer sees its first wakeup from libghostty.
        let coalescer = TickCoalescer()

        #expect(coalescer.noteWakeup())
    }

    @Test("TickCoalescer: extra wakeups coalesce while scheduled")
    func extraWakeupsCoalesceWhileScheduled() {
        // Intent: while a tick is already scheduled, subsequent noteWakeup
        //   calls return false (coalesced, no duplicate schedule).
        // Why it exists: pins the coalescing contract so a wakeup burst never
        //   schedules N duplicate ticks against the runqueue.
        // Scenario: spec-first burst check -- a Ghostty session fires multiple
        //   wakeups before the runtime drains the first one.
        let coalescer = TickCoalescer()

        #expect(coalescer.noteWakeup())
        #expect(!coalescer.noteWakeup())
        #expect(!coalescer.noteWakeup())
    }

    @Test("TickCoalescer: runTick clears before draining")
    func runTickClearsBeforeDraining() {
        // Intent: runTick releases the scheduled slot BEFORE invoking the
        //   drain body, so a wakeup raised by the drain itself schedules a
        //   follow-up tick.
        // Why it exists: pins the "clear-first-then-drain" ordering so a
        //   self-rescheduling drain (typical libghostty fast-path) cannot
        //   starve its own follow-up.
        // Scenario: spec-first re-entrancy check -- the drain body itself
        //   raises a new wakeup, and the coalescer must accept it.
        let coalescer = TickCoalescer()
        #expect(coalescer.noteWakeup())

        var wakeupDuringDrainScheduled = false
        coalescer.runTick {
            wakeupDuringDrainScheduled = coalescer.noteWakeup()
        }

        #expect(
            wakeupDuringDrainScheduled,
            "wakeup during drain should schedule a follow-up tick"
        )
    }

    @Test("TickCoalescer: clean tick releases the slot")
    func cleanTickReleasesTheSlot() {
        // Intent: after a tick that scheduled nothing new drains, the next
        //   noteWakeup returns true again (the slot is freed).
        // Why it exists: pins the post-drain reset so a quiescent system can
        //   accept the NEXT wakeup without being permanently stuck.
        // Scenario: spec-first quiescence check -- a single wakeup is fully
        //   drained and the coalescer must arm again for the next event.
        let coalescer = TickCoalescer()
        #expect(coalescer.noteWakeup())

        coalescer.runTick {}

        #expect(coalescer.noteWakeup())
    }

    @Test("TickCoalescer: concurrent wakeups schedule exactly one tick")
    func concurrentWakeupsScheduleExactlyOneTick() {
        // Intent: under 1000 concurrent noteWakeup calls, exactly ONE returns
        //   true; all others coalesce to false.
        // Why it exists: pins the thread-safety claim of the atomic
        //   compare-and-swap slot -- a multi-thread race must not double-
        //   schedule the runqueue tick.
        // Scenario: spec-first concurrency check -- many Ghostty sessions (or
        //   threads) report wakeups simultaneously; the runtime must see a
        //   single scheduled tick.
        let coalescer = TickCoalescer()
        let counterLock = NSLock()
        var scheduledCount = 0

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            guard coalescer.noteWakeup() else { return }
            counterLock.lock()
            scheduledCount += 1
            counterLock.unlock()
        }

        #expect(scheduledCount == 1)
    }
}
