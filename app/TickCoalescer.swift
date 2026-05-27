// Pure ghostty_app_tick wakeup coalescer. No AppKit/GhosttyKit dependency so it
// can be compiled in both the app build and the unit test build.

import Foundation

final class TickCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false

    /// Record a wakeup from any thread and report whether a main-queue tick must be scheduled.
    func noteWakeup() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if scheduled { return false }
        scheduled = true
        return true
    }

    /// Run one tick, releasing the pending slot before draining so wakeups during the drain re-arm.
    ///
    /// Assumes `drain` fully drains the app mailbox. This holds for Ghostty v1.3.0:
    /// App.drainMailbox only returns early for App.Message.quit, and no embedded
    /// App.Mailbox.push path enqueues that message. Re-audit on Ghostty upgrades.
    func runTick(_ drain: () -> Void) {
        lock.lock()
        scheduled = false
        lock.unlock()
        drain()
    }
}
