// The bounded-wait primitive, and the pane wait built on it, for everything that
// drives TerminalPTY from outside production code.
//
// It lives in its own target because of who has to reach it. The two opt-in runners
// are plain executables that must not link swift-testing, so it cannot go in
// `TerminalPTYTestSupport`; and `lib/TerminalPTY/Sources` bans Swift concurrency
// outright on the exit-ownership path (`scripts/terminal-exit-concurrency-lint.sh`),
// so it cannot go beside the handle it extends either.
//
// Nothing that reports a test failure belongs here -- that needs swift-testing, which
// is exactly what this target must not have. Callers turn a `false` into whatever
// their context calls a failure.
import Synchronization
import TerminalPaneSession

/// Samples a condition on a deadline and reports whether it ever held.
///
/// The sleep between samples earns its place twice. A `Task.yield()` spin competes with
/// the very work it waits for, and nothing can unwind it -- `Task.yield()` does not throw
/// on cancellation, so a test's time limit has no purchase and a condition that never
/// arrives becomes a process at full CPU for something outside the run to kill.
///
/// And when the sleep is itself cancelled, this stops. Swallowing that error would spin
/// through the rest of the deadline with no sleep left in the loop -- rebuilding the hot
/// loop the sleep was there to prevent, at the exact moment a time limit fired to end it.
public func pollUntil(_ condition: @Sendable () -> Bool, within limit: Duration) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while true {
        if condition() { return true }
        guard ContinuousClock.now < deadline else { return false }
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            return condition()
        }
    }
}

public extension TerminalPaneTerminationHandle {
    /// Waits for quiescence and reports whether it arrived before the deadline.
    ///
    /// `whenQuiescent` cannot be awaited without a continuation that a pane which never
    /// quiesces never resumes. Every caller here is winding down and has a verdict to
    /// record -- an opt-in runner writes an ownership file claiming each resource was
    /// released, and only quiescence supports that claim -- so this hands back an answer
    /// rather than suspending on a question with no reply.
    func quiesced(within limit: Duration) async -> Bool {
        let quiescent = Mutex(false)
        whenQuiescent { quiescent.withLock { $0 = true } }
        return await pollUntil({ quiescent.withLock { $0 } }, within: limit)
    }
}
