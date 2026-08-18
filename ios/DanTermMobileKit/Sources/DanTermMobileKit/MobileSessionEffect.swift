// The only way anything leaves the phone's session model.
//
// Two effect types, one per entry point. The ordinary one has no resize case at all, so a
// layout, keyboard, lifecycle, timer, or frame branch cannot return a resize whatever it
// constructs; the geometry one adds exactly that case. The interpreter's array is the
// wider type and ordinary results are widened into it, so there is still one effect
// stream and one perform loop.
import DanTermClient
import DanTermProtocol
import Foundation

/// One thing the shell must do. Effects are performed in array order, so an order the
/// model returns is an order the phone observes.
public enum MobileSessionEffect: Equatable, Sendable {
    /// Open an attempt against this target.
    case connect(MobileServerTarget)
    /// End the attempt or connection currently open, and fence its callbacks.
    case disconnect
    /// Remember this target for the next launch.
    case storeTarget(host: String, port: String)
    /// Point the surface at this pane, resuming from the stored checkpoint when the model
    /// still trusts it. The surface answers with `paneAttached`.
    case attachPane(pane: PaneId, resumesFromStoredCheckpoint: Bool)
    /// Send the tape subscription over the established session and start reading it.
    case beginStream(requestId: JSONValue, request: MobileOrdinaryRequest)
    /// Send one request on the serving stream.
    case send(requestId: JSONValue, request: MobileOrdinaryRequest)
    /// Give one stream record to the surface. The surface answers with `recordApplied`,
    /// or with `replicaRejectedRecord` when it cannot take it.
    case applyRecord(PaneTapeRecord)
    /// Move the replica's local viewport, which sends nothing to the owner.
    case scrollViewport(rows: Int)
    /// Write the replica's position out. `savingReplica` is false when nothing has moved
    /// since the last write, which leaves a synchronous flush as a plain barrier on work
    /// already in flight. Performing this also drops any armed checkpoint deadline.
    case flushCheckpoint(savingReplica: Bool, synchronously: Bool)
    /// Deliver `retryTimerFired` at this moment, replacing any deadline already armed.
    case armRetryTimer(deadline: TimeInterval)
    case cancelRetryTimer
    /// Deliver `checkpointTimerFired` at this moment.
    case armCheckpointTimer(deadline: TimeInterval)
    /// Drive the smoke run's probe into the terminal's input responder. It enters the
    /// session again as ordinary input events, which is what makes the probe a test of
    /// the responder rather than of the model.
    case driveSmokeInput([MobileSmokeInputStep])
    /// Re-render every projection from the model.
    case redraw
}

/// What the claim and release gestures may produce: everything an ordinary event can, plus
/// the one resize.
public enum MobileSessionGeometryEffect: Equatable, Sendable {
    case session(MobileSessionEffect)
    /// The pane resize a claim or a release sends. This case exists in no other effect
    /// type, which is what keeps the gesture the only source of one.
    case resizePane(requestId: JSONValue, request: IpcRequest)
}
