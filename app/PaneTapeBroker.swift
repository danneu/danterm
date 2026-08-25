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
        let policy: PaneTapeSyncPolicy
        /// Registers the stream in the shutdown census. Its cancel closure closes the socket,
        /// which is right for app teardown and wrong for one stream ending, so every teardown
        /// short of shutdown retires this token with `run` instead of `cancel`.
        let shutdownToken: AppRuntimeSchedulingToken?
        var noticeRegistration: PaneTapeFollowNoticeRegistration?
    }

    private let schedulingLifecycle: AppRuntimeSchedulingLifecycle
    private var sessionLookup: ((PaneId) -> (any TerminalSession)?)?
    private var subscriptions = PaneTapeFollowSubscriptions()
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
        for subscriptionId in subscriptions.connectionClosed(connectionId) {
            retireTransport(subscriptionId)
        }
    }

    /// Ends every follow stream for a pane while leaving each client socket open.
    func paneClosed(_ paneId: PaneId) {
        for end in subscriptions.paneClosed(paneId.rawValue) {
            writeFollowEnd(end)
        }
    }

    /// Closes every follower at app shutdown without first writing a terminator record.
    func shutdown() {
        for subscriptionId in subscriptions.removeAll() {
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
                connection.writeSuccess(
                    reqId: reqId,
                    result: PaneTapeOutgoingRecord<JSONValue>.start(opening.start.record)
                ) { [weak self] succeeded in
                    guard let self else { return }
                    self.schedulingLifecycle.run(callbackToken) {
                        self.finishFollowStart(
                            succeeded: succeeded,
                            subscriptionId: subscriptionId,
                            paneId: paneId,
                            connection: connection.connection,
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

    private func finishFollowStart(
        succeeded: Bool,
        subscriptionId: UUID,
        paneId: PaneId,
        connection: IpcConnection,
        opening: PaneTapeOpening<PaneTapeSessionEvent>,
        policy: PaneTapeSyncPolicy
    ) {
        guard schedulingLifecycle.isActive else { return }
        guard succeeded else { return }
        // The pane went away between the start reply and this callback. The client is owed the
        // same terminator a pane close writes; its socket stays open for its other work.
        guard let session = sessionLookup?(paneId) else {
            writePaneTapeRecords(
                [PaneTapeOutgoingRecord<PaneTapeSessionEvent>.end(reason: .paneClosed)],
                connection: connection,
                subscriptionId: subscriptionId
            )
            return
        }
        subscriptions.add(
            id: subscriptionId,
            connectionId: connection.id,
            paneId: paneId.rawValue,
            cursor: opening.nextCursor,
            replicaHistoryIsComplete: opening.replicaHistoryIsComplete,
            isDeliveringOpening: opening.records.isEmpty == false
        )
        transports[subscriptionId] = FollowTransport(
            connection: connection,
            policy: policy,
            shutdownToken: schedulingLifecycle.arm(
                .subscription,
                cancel: { connection.close() }
            )
        )
        guard let noticeRegistration = session.addPaneTapeFollowNotice(
            id: subscriptionId,
            cursor: opening.nextCursor,
            // This hop is real, unlike the ones the write completions used to need: the notice
            // fires on the PTY host's owner queue, and that queue has no business learning
            // about the main actor just to save the crossing.
            notify: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.eventsAvailable(subscriptionId)
                    }
                }
            }
        ) else {
            failFollow(subscriptionId)
            return
        }
        transports[subscriptionId]?.noticeRegistration = noticeRegistration
        guard opening.records.isEmpty == false else { return }
        guard let callbackToken = schedulingLifecycle.arm(.deferredCallback, cancel: {}) else {
            dropFollow(subscriptionId)
            return
        }
        writePaneTapeRecords(
            opening.records,
            connection: connection,
            subscriptionId: subscriptionId
        ) { [weak self] succeeded in
            guard let self else { return }
            self.schedulingLifecycle.run(callbackToken) {
                guard succeeded else {
                    self.dropFollow(subscriptionId)
                    return
                }
                if let fetch = self.subscriptions.completeDelivery(
                    subscriptionId: subscriptionId
                ) {
                    self.fetch(fetch)
                }
            }
        }
    }

    private func eventsAvailable(_ subscriptionId: UUID) {
        guard schedulingLifecycle.isActive else { return }
        guard let fetch = subscriptions.eventsAvailable(subscriptionId) else { return }
#if DANTERM_TERMINAL_BENCHMARK
        TerminalBenchmarkObserver.shared?.observePaneTapeFollowPush()
#endif
        self.fetch(fetch)
    }

    private func fetch(_ fetch: PaneTapeFollowFetch) {
        guard let transport = transports[fetch.subscriptionId] else {
            dropFollow(fetch.subscriptionId)
            return
        }
        let connection = transport.connection
        let paneId = PaneId(rawValue: fetch.paneId)
        guard let session = sessionLookup?(paneId) else {
            paneClosed(paneId)
            return
        }
        guard let prepareBatch = session.paneTapeFollowBatch(
            subscriptionId: fetch.subscriptionId,
            from: fetch.cursor,
            policy: transport.policy,
            replicaHistoryIsComplete: fetch.replicaHistoryIsComplete
        ) else {
            failFollow(fetch.subscriptionId)
            return
        }
        guard let callbackToken = schedulingLifecycle.arm(
            .deferredCallback,
            cancel: {}
        ) else { return }
        DispatchQueue.global(qos: .utility).async {
            let continuation = prepareBatch()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.schedulingLifecycle.run(callbackToken) {
                    self.deliverBatch(
                        subscriptionId: fetch.subscriptionId,
                        connection: connection,
                        continuation: continuation
                    )
                }
            }
        }
    }

    private func deliverBatch(
        subscriptionId: UUID,
        connection: IpcConnection,
        continuation: PaneTapeContinuation<PaneTapeSessionEvent>
    ) {
        guard schedulingLifecycle.isActive else { return }
        guard let accepted = subscriptions.finishFetch(
            subscriptionId: subscriptionId,
            continuation: continuation
        ) else { return }
#if DANTERM_TERMINAL_BENCHMARK
        if accepted.records.contains(where: { record in
            if case .sync = record { return true }
            return false
        }) {
            TerminalBenchmarkObserver.shared?.observePaneTapeFollowSynchronization()
        }
#endif
        guard accepted.records.isEmpty == false else {
            if let fetch = subscriptions.completeDelivery(subscriptionId: subscriptionId) {
                self.fetch(fetch)
            }
            return
        }
        guard let callbackToken = schedulingLifecycle.arm(.deferredCallback, cancel: {}) else {
            return
        }

        writePaneTapeRecords(
            accepted.records,
            connection: connection,
            subscriptionId: subscriptionId
        ) { [weak self] succeeded in
            guard let self else { return }
            self.schedulingLifecycle.run(callbackToken) {
                // The transport closed the socket itself on a failed write, so this stream
                // ends at EOF rather than with a record nothing can carry.
                guard succeeded else {
                    self.dropFollow(subscriptionId)
                    return
                }
                if let fetch = self.subscriptions.completeDelivery(
                    subscriptionId: subscriptionId
                ) {
                    self.fetch(fetch)
                }
            }
        }
    }

    /// Ends one stream whose socket is still writable, on an internal failure the client
    /// would otherwise only see as silence.
    private func failFollow(_ subscriptionId: UUID) {
        guard let end = subscriptions.end(subscriptionId, reason: .streamFailed) else { return }
        writeFollowEnd(end)
    }

    /// Retires one stream whose transport is already gone. The peer sees EOF, not an `end`.
    private func dropFollow(_ subscriptionId: UUID) {
        subscriptions.remove(subscriptionId)
        retireTransport(subscriptionId)
    }

    /// Retires one ended stream's transport and writes its terminator on the way out, so the
    /// record goes to that subscription's own socket and lands after every batch already
    /// accepted for it.
    private func writeFollowEnd(_ end: PaneTapeFollowEnd) {
        guard let connection = retireTransport(end.subscriptionId) else { return }
        writePaneTapeRecords(
            [PaneTapeOutgoingRecord<PaneTapeSessionEvent>.end(reason: end.reason)],
            connection: connection,
            subscriptionId: end.subscriptionId
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
        transport.noticeRegistration?.cancel()
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
