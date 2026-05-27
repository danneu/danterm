// Unit tests for the pure ghostty_app_tick wakeup coalescer.

import Foundation

func tickCoalescerTests() {
    test("TickCoalescer: first wakeup schedules") {
        let coalescer = TickCoalescer()

        try expect(coalescer.noteWakeup())
    }

    test("TickCoalescer: extra wakeups coalesce while scheduled") {
        let coalescer = TickCoalescer()

        try expect(coalescer.noteWakeup())
        try expect(!coalescer.noteWakeup())
        try expect(!coalescer.noteWakeup())
    }

    test("TickCoalescer: runTick clears before draining") {
        let coalescer = TickCoalescer()
        try expect(coalescer.noteWakeup())

        var wakeupDuringDrainScheduled = false
        coalescer.runTick {
            wakeupDuringDrainScheduled = coalescer.noteWakeup()
        }

        try expect(
            wakeupDuringDrainScheduled,
            "wakeup during drain should schedule a follow-up tick"
        )
    }

    test("TickCoalescer: clean tick releases the slot") {
        let coalescer = TickCoalescer()
        try expect(coalescer.noteWakeup())

        coalescer.runTick {}

        try expect(coalescer.noteWakeup())
    }

    test("TickCoalescer: concurrent wakeups schedule exactly one tick") {
        let coalescer = TickCoalescer()
        let counterLock = NSLock()
        var scheduledCount = 0

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            guard coalescer.noteWakeup() else { return }
            counterLock.lock()
            scheduledCount += 1
            counterLock.unlock()
        }

        try expectEqual(scheduledCount, 1)
    }
}
