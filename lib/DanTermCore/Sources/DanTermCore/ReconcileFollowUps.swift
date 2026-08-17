// The dispatch discipline for facts a reconcile pass discovers about the view.
// A pass never sends: it returns what it found, and this queue decides when the
// runtime may dispatch it. The rule is pure ordering logic, so it lives here and
// is unit-tested without AppKit; the runtime glue that owns a queue and calls
// update() stays in app/AppRuntime.swift.

/// Holds what reconcile passes reported and releases it only to the outermost
/// send frame.
///
/// Two invariants ride on this type. A follow-up is dispatched only after the
/// sweep that discovered it has returned, so every pass cache is advanced before
/// the follow-up's own sweep reads it. And a send that arrives while a sweep is
/// in flight -- from any path, including an edge laundered through AppKit
/// dispatch that no static check can see -- accumulates into the frame already
/// running instead of dispatching itself. The second rule is what makes the
/// channel correct without depending on having found every in-pass send site.
struct ReconcileFollowUps {
    private var pending: [Msg] = []
    private var depth = 0

    /// True when nothing a sweep reported is still waiting to be dispatched.
    var isEmpty: Bool { pending.isEmpty }

    /// Open a send frame. Every path that runs `update()` must bracket itself
    /// with `enterFrame()`/`leaveFrame()`, or a nested send would drain.
    mutating func enterFrame() { depth += 1 }

    /// Close the send frame opened by the matching `enterFrame()`.
    mutating func leaveFrame() {
        precondition(depth > 0, "leaveFrame() without a matching enterFrame()")
        depth -= 1
    }

    /// Record what one sweep's passes discovered.
    mutating func report(_ messages: [Msg]) {
        pending.append(contentsOf: messages)
    }

    /// The next message the caller may dispatch, or nil while a frame is running
    /// or nothing is pending. Callers loop until nil, so a follow-up's own sweep
    /// can report one; termination rests on the reported facts being
    /// self-clearing -- a pass reports only while view and model disagree, and
    /// dispatching the follow-up removes the disagreement.
    mutating func nextToDispatch() -> Msg? {
        guard depth == 0, !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}
