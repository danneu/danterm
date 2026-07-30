// Latest-wins bookkeeping for the owner queue's geometry path: which submitted resizes
// have already been superseded by a newer one and can be skipped whole.
//
// This is the submitting side of the decision, so it lives outside the actor and carries
// its own lock -- callers submit from whatever thread AppKit hands them, while the verdict
// is read on the owner queue. It holds no dimensions and performs no work: it answers one
// question about submission order, which keeps the winsize/reflow pair itself untouched.
//
// Its own file because the ordering argument it encodes (a run, and what closes one) is
// the whole of the coalescing invariant, and burying it in the host's 1,400 lines of PTY
// and lifecycle mechanics would hide the one thing a reader has to check.
import Synchronization

/// One resize's place in the run it was submitted into, held by the caller until the owner
/// queue reaches it and asks whether it still has work to do.
struct ResizeSubmission: Equatable, Sendable {
    let run: UInt64
    let index: UInt64
}

/// Decides which submitted resizes are already superseded, so a drag applies as many
/// reflows as the owner queue can afford instead of one per column crossed.
///
/// A *run* is a contiguous stretch of resize submissions: any other externally submitted
/// action closes it. Within a run every resize but the newest is superseded; across the
/// boundary nothing is, because a non-resize action queued between two grids reads the
/// earlier one and must see it applied.
final class ResizeCoalescer: Sendable {
    private struct State {
        var run: UInt64 = 0
        var submissionsInRun: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Enters one resize into the open run, superseding every earlier member of it.
    func submitResize() -> ResizeSubmission {
        state.withLock { state in
            state.submissionsInRun += 1
            return ResizeSubmission(run: state.run, index: state.submissionsInRun)
        }
    }

    /// Closes the open run so no later resize can supersede one already submitted.
    func closeRun() {
        state.withLock { state in
            state.run += 1
            state.submissionsInRun = 0
        }
    }

    /// Answers on the owner queue, immediately before the winsize/reflow pair would begin.
    /// A pair that has begun is never superseded, which is what makes the skip atomic.
    func isSuperseded(_ submission: ResizeSubmission) -> Bool {
        state.withLock { state in
            state.run == submission.run && state.submissionsInRun > submission.index
        }
    }
}
