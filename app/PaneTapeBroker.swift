// Owns pane-tape capture and follow-stream state at the IPC boundary. Pure record and
// subscription policy stays in DanTermCore; generic socket framing stays in DanTermSupport.
// This file exists so transport state, lifecycle rules, and the only tape-shaped wire write
// share one access-control boundary.
import Foundation
import DanTermProtocol

/// Keeps every pane-tape transport and subscription behind one runtime-owned boundary.
@MainActor
final class PaneTapeBroker {
    /// Holds one follow stream's transport resources, so ending that stream retires exactly
    /// its own socket handle, shutdown census entry, and recorder notice.
    private struct FollowTransport {
        let connection: IpcConnection
        let paneId: PaneId
        /// Registers the stream in the shutdown census. Its cancel closure closes the socket,
        /// which is right for app teardown and wrong for one stream ending, so every teardown
        /// short of shutdown retires this token with `run` instead of `cancel`.
        let shutdownToken: AppRuntimeSchedulingToken?
        let registration: PaneTapeFollowRegistration
    }

    private let schedulingLifecycle: AppRuntimeSchedulingLifecycle
    private var sessionLookup: ((PaneId) -> (any TerminalSession)?)?
    // Keyed by subscription id, like the subscriptions themselves. Anything coarser is
    // shared by sibling streams and cannot be retired one stream at a time.
    private var transports: [UUID: FollowTransport] = [:]

    /// Binds all broker work to the runtime's scheduling census and shutdown boundary.
    init(schedulingLifecycle: AppRuntimeSchedulingLifecycle) {
        self.schedulingLifecycle = schedulingLifecycle
    }

    /// Installs the runtime's pane resolver after both sides of their ownership link exist.
    func setSessionLookup(_ lookup: @escaping (PaneId) -> (any TerminalSession)?) {
        sessionLookup = lookup
    }

    /// Starts either a finite capture or a follow stream through the broker's shared lookup.
    func streamPaneTape(
        reqId: UUID,
        paneId: PaneId,
        capture: PaneTapeCaptureMode,
        start: PaneTapeStartPosition,
        policy: PaneTapeSyncPolicy,
        connection: IpcRequestTransport
    ) {
        guard let session = sessionLookup?(paneId) else {
            connection.writeError(
                reqId: reqId,
                code: -32603,
                message: "pane no longer available"
            )
            return
        }
        if capture == .follow {
            beginFollow(
                reqId: reqId,
                paneId: paneId,
                start: start,
                policy: policy,
                connection: connection,
                session: session
            )
        } else {
            streamFinite(
                reqId: reqId,
                connection: connection,
                session: session,
                capture: capture,
                start: start,
                policy: policy
            )
        }
    }

    /// Drops all follow streams owned by a closed socket before another append edge can fetch.
    func connectionClosed(_ connectionId: UUID) {
        guard schedulingLifecycle.isActive else { return }
        let ids = transports.compactMap { id, transport in
            transport.connection.id == connectionId ? id : nil
        }
        for subscriptionId in ids {
            retireTransport(subscriptionId)
        }
    }

    /// Ends every follow stream for a pane while leaving each client socket open.
    func paneClosed(_ paneId: PaneId) {
        let ids = transports.compactMap { id, transport in
            transport.paneId == paneId ? id : nil
        }
        for subscriptionId in ids {
            writeFollowEnd(subscriptionId, reason: .paneClosed)
        }
    }

    /// Closes every follower at app shutdown without first writing a terminator record.
    func shutdown() {
        for subscriptionId in Array(transports.keys) {
            retireTransport(subscriptionId)?.close()
        }
    }

    /// Streams one finite capture: the start record as the reply, then this dump's own gap,
    /// events, and terminator as notifications on the same socket.
    ///
    /// The fence is taken here, once, before any record is built. Everything after it works
    /// from that one copy, so output arriving mid-delivery, or the pane closing outright,
    /// cannot add to or truncate a dump that already stated its boundary. This capture holds
    /// no subscription: its id only routes its records to the socket that asked for them.
    private func streamFinite(
        reqId: UUID,
        connection: IpcRequestTransport,
        session: any TerminalSession,
        capture: PaneTapeCaptureMode,
        start: PaneTapeStartPosition,
        policy: PaneTapeSyncPolicy
    ) {
        guard schedulingLifecycle.isActive else {
            connection.close()
            return
        }
        guard let prepareOpening = session.paneTapeOpening(
            capture: capture,
            start: start,
            policy: policy
        ) else {
            connection.writeError(
                reqId: reqId,
                code: -32603,
                message: "pane has no terminal to read a tape from"
            )
            return
        }
        let captureId = UUID()
        DispatchQueue.global(qos: .utility).async {
            do {
                let opening = try prepareOpening()
                // The hop is for `prepareOpening`, which can materialize the whole retained
                // tape while the main actor is drawing panes. The writes below only enqueue;
                // the connection's serial write queue does the encoding, and it keeps the
                // start record ahead of everything enqueued after it.
                connection.writeSuccess(
                    reqId: reqId,
                    result: PaneTapeOutgoingRecord<JSONValue>.start(opening.start.record)
                )
                let endReason: PaneTapeEndReason = capture == .snapshot
                    ? .snapshotComplete
                    : .dumpComplete
                writePaneTapeRecords(
                    opening.records + [.end(reason: endReason)],
                    connection: connection.connection,
                    subscriptionId: captureId
                )
            } catch {
                connection.writeError(
                    reqId: reqId,
                    code: -32603,
                    message: "failed to encode pane tape"
                )
            }
        }
    }

    private func beginFollow(
        reqId: UUID,
        paneId: PaneId,
        start: PaneTapeStartPosition,
        policy: PaneTapeSyncPolicy,
        connection: IpcRequestTransport,
        session: any TerminalSession
    ) {
        guard schedulingLifecycle.isActive else {
            connection.close()
            return
        }
        guard let prepareOpening = session.paneTapeOpening(
            capture: .follow,
            start: start,
            policy: policy
        ) else {
            connection.writeError(
                reqId: reqId,
                code: -32603,
                message: "pane has no terminal to read a tape from"
            )
            return
        }
        let subscriptionId = UUID()
        guard let callbackToken = schedulingLifecycle.arm(.deferredCallback, cancel: {}) else {
            connection.close()
            return
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                let opening = try prepareOpening()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.schedulingLifecycle.run(callbackToken) {
                        self.finishPreparedFollow(
                            reqId: reqId,
                            subscriptionId: subscriptionId,
                            paneId: paneId,
                            connection: connection,
                            opening: opening,
                            policy: policy
                        )
                    }
                }
            } catch {
                connection.writeError(
                    reqId: reqId,
                    code: -32603,
                    message: "failed to encode pane tape"
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.schedulingLifecycle.run(callbackToken, action: {})
                }
            }
        }
    }

    private func finishPreparedFollow(
        reqId: UUID,
        subscriptionId: UUID,
        paneId: PaneId,
        connection: IpcRequestTransport,
        opening: PaneTapeOpening<PaneTapeSessionEvent>,
        policy: PaneTapeSyncPolicy
    ) {
        guard schedulingLifecycle.isActive else { return }
        guard let session = sessionLookup?(paneId) else {
            connection.writeError(
                reqId: reqId,
                code: -32603,
                message: "pane no longer available"
            )
            return
        }
        guard let registration = session.addPaneTapeFollowSubscription(
            id: subscriptionId,
            cursor: opening.nextCursor,
            policy: policy,
            replicaHistoryIsComplete: opening.replicaHistoryIsComplete,
            deliver: { [weak self] materialize in
                guard let self else { return }
                writeLazyPaneTapeRecords(
                    materialize: materialize,
                    connection: connection.connection,
                    subscriptionId: subscriptionId
                ) { [weak self] historyIsComplete in
                    guard let self else { return }
                    guard let historyIsComplete,
                          let session = self.sessionLookup?(paneId)
                    else {
                        self.dropFollow(subscriptionId)
                        return
                    }
                    session.markPaneTapeFollowReady(
                        id: subscriptionId,
                        replicaHistoryIsComplete: historyIsComplete
                    )
                }
            }
        ) else {
            connection.writeError(
                reqId: reqId,
                code: -32603,
                message: "pane already has the maximum of 8 tape followers"
            )
            return
        }
        transports[subscriptionId] = FollowTransport(
            connection: connection.connection,
            paneId: paneId,
            shutdownToken: schedulingLifecycle.arm(
                .subscription,
                cancel: { connection.close() }
            ),
            registration: registration
        )
        guard let callbackToken = schedulingLifecycle.arm(.deferredCallback, cancel: {}) else {
            dropFollow(subscriptionId)
            return
        }
        let prefixCompleted: @MainActor @Sendable (Bool) -> Void = { [weak self, weak session] succeeded in
            guard let self else { return }
            self.schedulingLifecycle.run(callbackToken) {
                guard succeeded, let session else {
                    self.dropFollow(subscriptionId)
                    return
                }
                session.markPaneTapeFollowReady(
                    id: subscriptionId,
                    replicaHistoryIsComplete: opening.replicaHistoryIsComplete
                )
            }
        }
        connection.writeSuccess(
            reqId: reqId,
            result: PaneTapeOutgoingRecord<JSONValue>.start(opening.start.record),
            completion: opening.records.isEmpty ? prefixCompleted : nil
        )
        if opening.records.isEmpty == false {
            writePaneTapeRecords(
                opening.records,
                connection: connection.connection,
                subscriptionId: subscriptionId,
                completion: prefixCompleted
            )
        }
    }

    /// Retires one stream whose transport is already gone. The peer sees EOF, not an `end`.
    private func dropFollow(_ subscriptionId: UUID) {
        retireTransport(subscriptionId)
    }

    /// Retires one ended stream's transport and writes its terminator on the way out, so the
    /// record goes to that subscription's own socket and lands after every batch already
    /// accepted for it.
    private func writeFollowEnd(_ subscriptionId: UUID, reason: PaneTapeEndReason) {
        guard let connection = retireTransport(subscriptionId) else { return }
        writePaneTapeRecords(
            [PaneTapeOutgoingRecord<PaneTapeSessionEvent>.end(reason: reason)],
            connection: connection,
            subscriptionId: subscriptionId
        )
    }

    /// Releases exactly one stream's transport resources and hands back its connection, so a
    /// sibling on the same socket or pane keeps its notice, its census entry, and its writes.
    ///
    /// The census token is retired with `run`, not `cancel`: cancelling fires the closure that
    /// closes the socket, and the socket belongs to the client, not to this one stream.
    @discardableResult
    private func retireTransport(_ subscriptionId: UUID) -> IpcConnection? {
        guard let transport = transports.removeValue(forKey: subscriptionId) else { return nil }
        transport.registration.cancel()
        if let token = transport.shutdownToken {
            schedulingLifecycle.run(token, action: {})
        }
        return transport.connection
    }
}

/// Puts one pane-tape delivery on a connection without crossing the broker's actor boundary.
///
/// Each call enqueues straight onto the connection's serial write queue, which both encodes
/// and writes, so records reach the socket in the order they were handed over. Routing one
/// write kind through a concurrent queue instead would let a terminator overtake a batch
/// prepared before it, and a stream's last record would not be its last.
///
/// The records handed over here go out as one notification, because they are one delivery:
/// the subscription is stated once and the whole group costs one encode and one queued line.
/// The connection splits that line only when it would pass the framing bound the reader
/// enforces, which a group of sync records can. The optional completion reports the flush of
/// the whole group, however many lines it took.
private nonisolated func writePaneTapeRecords<Event: Encodable & Sendable>(
    _ records: [PaneTapeOutgoingRecord<Event>],
    connection: IpcConnection,
    subscriptionId: UUID,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
) {
    precondition(records.isEmpty == false)
    let subscription = subscriptionId.uuidString
    connection.writeBatchedNotification(
        method: Methods.paneTapeEvent,
        batch: records,
        params: { group in
            PaneTapeEventNotification(subscription: subscription, records: Array(group))
        },
        completion: completion
    )
}

/// Materializes and writes one recorder-owned batch at its ordered queue position.
private nonisolated func writeLazyPaneTapeRecords(
    materialize: @escaping @Sendable () -> PaneTapeContinuation<PaneTapeSessionEvent>,
    connection: IpcConnection,
    subscriptionId: UUID,
    completion: @escaping @MainActor @Sendable (Bool?) -> Void
) {
    let subscription = subscriptionId.uuidString
    connection.writeLazyBatchedNotification(
        method: Methods.paneTapeEvent,
        build: {
            let continuation = materialize()
            precondition(continuation.batch.records.isEmpty == false)
            return (
                batch: continuation.batch.records,
                acknowledgement: continuation.replicaHistoryIsComplete
            )
        },
        params: { records in
            PaneTapeEventNotification(subscription: subscription, records: Array(records))
        },
        completion: completion
    )
}
