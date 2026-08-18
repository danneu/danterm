// The one channel a view reports a discovered fact through, and the only thing
// that decides when that fact becomes a Msg. The ordering rule itself is pure and
// lives in DanTermCore's ReconcileFollowUps; this type adds the two things a queue
// cannot have on its own -- the send frame that brackets a dispatch, and the
// wake-up for a report that no frame is going to drain.
import Foundation

/// Buffers what views and reconcile passes report, and guarantees every report is
/// delivered without ever dispatching on the reporting stack.
///
/// A reporting stack is not a safe place to run `update()`. It can be AppKit
/// mid-traversal (a recycled cell tearing down the rename it carries), or AppKit
/// mid-field-editor-teardown (the click-away callback), or a reconcile pass whose
/// projection cache has not advanced yet. So a report never dispatches itself:
/// delivery happens at the exit of the outermost send frame, or -- for a report
/// made with no frame open -- on the next main-queue turn.
///
/// The outbox outlives every view that reports into it, which is what makes a
/// report survive the reporting view being released before the drain runs.
@MainActor
final class ReconcileOutbox {
    private var queue = ReconcileFollowUps()
    private var dispatch: ((Msg) -> Void)?
    private var drainIsScheduled = false
    private var isDraining = false

    /// Installs the runtime's dispatch. The closure must capture its runtime
    /// weakly: the outbox is owned by that runtime, so a strong capture would be a
    /// cycle, and a scheduled drain must be inert once the runtime is gone.
    func setDispatcher(_ dispatch: @escaping (Msg) -> Void) {
        self.dispatch = dispatch
    }

    /// Runs `body` inside one send frame and delivers what it reported once the
    /// outermost frame closes. A nested frame delivers nothing, so a send arriving
    /// mid-sweep accumulates into the frame already running.
    func withFrame(_ body: () -> Void) {
        queue.enterFrame()
        body()
        queue.leaveFrame()
        drain()
    }

    /// The sole ingress for a fact discovered outside `update()`. It never
    /// delivers on the caller's stack: an open frame delivers at its exit, and a
    /// report with no frame open is woken by a scheduled drain.
    func report(_ messages: [Msg]) {
        guard !messages.isEmpty else { return }
        queue.report(messages)
        scheduleDrainIfNeeded()
    }

    /// Delivers everything the frames have released. A re-entrant call returns at
    /// once, so a dispatched follow-up's own frame does not recurse into a nested
    /// drain -- the outermost loop keeps going instead, and picks up whatever that
    /// follow-up's own sweep reported.
    func drain() {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while let next = queue.nextToDispatch() {
            dispatch?(next)
        }
    }

    /// Wakes up a report that no frame exit will drain. At most one hop is in
    /// flight, and the hop is inert if the outbox is gone by the time it runs.
    private func scheduleDrainIfNeeded() {
        guard queue.needsScheduledDrain, !drainIsScheduled else { return }
        drainIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.drainIsScheduled = false
                self.drain()
            }
        }
    }
}
