// The one instrument that delivers a moment the shell scheduled, on the clock the policy
// named it on.
//
// It lives in the kit rather than in the UIKit shell for two reasons: the shell has no
// tests, and a deadline is only worth the base it is delivered on -- an instrument that
// reads a different clock than the policy silently turns an exact moment into a floor.
//
// What does not belong here: any knowledge of what is due at the deadline. The instrument
// delivers a callback and knows nothing about retries or checkpoints.
import Dispatch
import Foundation

/// The single monotonic reading the reconnect policy schedules on and the deadline timer
/// delivers on.
///
/// It is one place so the two cannot drift apart: this clock counts the time the system has
/// been awake, so a correction to the wall clock moves neither a deadline computed from it
/// nor the delivery of that deadline.
public enum MobileMonotonicClock {
    public static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Delivers one main-actor callback at a `MobileMonotonicClock` deadline.
///
/// It exists to replace `Timer.scheduledTimer`, which is wrong for this job twice over: it
/// registers on the current run loop in the default mode only, so a drag anywhere in the UI
/// parks the work until the drag ends, and it fires against a wall-clock date, so a clock
/// correction moves a deadline that was computed monotonically. This delivers through a
/// dispatch timer on the main queue, which the run loop drains in every common mode.
@MainActor
public final class MobileDeadlineTimer {
    private var source: DispatchSourceTimer?
    private var deadline: TimeInterval?

    public init() {}

    /// Whether a deadline is still owed. Callers that schedule one flush per dirty period
    /// use it to leave a pending deadline alone.
    public var isPending: Bool { source != nil }

    /// Replaces any pending deadline with this one. `deliver` runs on the main actor at or
    /// after `deadline`, and never before it.
    public func schedule(
        until deadline: TimeInterval,
        deliver: @escaping @MainActor @Sendable () -> Void
    ) {
        cancel()
        self.deadline = deadline
        arm(deliver)
    }

    /// Drops the pending deadline, so nothing is delivered for it.
    public func cancel() {
        source?.cancel()
        source = nil
        deadline = nil
    }

    // The source is created running and is never suspended, so cancelling it here is enough
    // to make releasing it safe.
    deinit { source?.cancel() }

    private func arm(_ deliver: @escaping @MainActor @Sendable () -> Void) {
        guard let deadline else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        // `DispatchTime` counts the same awake time the deadline was computed on, so the
        // remaining interval and the fire are on one base end to end.
        source.schedule(deadline: .now() + max(0, deadline - MobileMonotonicClock.now))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.deadline == deadline else { return }
                // Dispatch does not fire before its own deadline; re-arming for the
                // remainder is what makes "never early" true on the caller's clock too,
                // whatever the two bases do relative to each other.
                guard MobileMonotonicClock.now >= deadline else {
                    self.source?.cancel()
                    self.source = nil
                    self.arm(deliver)
                    return
                }
                self.source = nil
                self.deadline = nil
                deliver()
            }
        }
        self.source = source
        source.resume()
    }
}
