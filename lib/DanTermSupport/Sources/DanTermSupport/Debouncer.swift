// Generic trailing-edge debouncer over a long-lived DispatchSourceTimer. Create
// once, reschedule many: each schedule(after:) re-arms the same timer to fire
// after the last call, coalescing a burst into one trailing fire. The
// reschedule-instead-of-recreate shape eliminates per-call timer-object churn
// while preserving the trailing deadline by default; callers that tolerate
// delayed delivery can pass a leeway window so the OS can coalesce wakeups. No
// AppKit/GhosttyKit dependency so it can be compiled in both the app build and
// the unit test build.

import Foundation

/// Owns one dispatch timer for trailing-edge debounce callers that must move the
/// deadline instead of allocating a new timer per event.
///
/// The source is created lazily, resumed once, and reused across both schedule
/// calls and fires. It is cancelled and dropped only from `cancel()` and `deinit`,
/// so resume/cancel stay paired and callers never release a suspended source.
/// Not thread-safe: call every method on `queue`, matching the AppRuntime call
/// sites that use the main queue and the tests that marshal through a serial queue.
final class Debouncer {
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var pendingAction: (() -> Void)?
    private var pending = false

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// True while a trailing fire is armed; the source itself can outlive fires.
    var isPending: Bool { pending }

    /// Re-arm the trailing fire, keeping only the newest action.
    ///
    /// `leeway` is a DispatchSourceTimer coalescing hint: keep latency-sensitive
    /// callers at the default zero, and give slow checkpoint debounces a window.
    func schedule(
        after delay: TimeInterval,
        leeway: DispatchTimeInterval = .nanoseconds(0),
        perform action: @escaping () -> Void
    ) {
        pendingAction = action
        pending = true

        if let timer {
            timer.schedule(deadline: .now() + delay, leeway: leeway)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, leeway: leeway)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending = false
            // Capture before clearing so an action that re-arms the debouncer is not clobbered.
            let action = self.pendingAction
            self.pendingAction = nil
            action?()
        }
        timer.resume()
        self.timer = timer
    }

    /// Disarm any pending fire and retire the source; the debouncer remains reusable.
    func cancel() {
        timer?.cancel()
        timer = nil
        pendingAction = nil
        pending = false
    }

    deinit {
        timer?.cancel()
    }
}
