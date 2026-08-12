// Portable pane-tape stream values, record construction, the bounded subscription lifecycle,
// and the one enqueue site every follow write goes through.
import Foundation
import DanTermProtocol

/// Carries every coordinate needed to resume after recorder eviction without estimating loss.
/// The two byte watermarks stay apart because the feed and write streams are numbered apart.
struct PaneTapeFollowCursor: Equatable, Sendable {
    let nextSequence: UInt64
    let feedBytesBeforeNextSequence: Int
    let writeBytesBeforeNextSequence: Int

    static let beginning = Self(
        nextSequence: 0,
        feedBytesBeforeNextSequence: 0,
        writeBytesBeforeNextSequence: 0
    )
}

/// Keeps stream geometry independent from the terminal engine's dimension type.
struct PaneTapeFollowDimensions: Equatable, Sendable {
    let columns: Int
    let rows: Int
}

/// Adapts one terminal event to the support layer without importing terminal modules.
struct PaneTapeFollowEvent: Equatable, Sendable {
    let sequence: UInt64
    let elapsedNanoseconds: UInt64
    /// When the event that produced these bytes occurred, on the same scale as
    /// `elapsedNanoseconds`; nil for bytes with no origin earlier than their own transfer.
    let originElapsedNanoseconds: UInt64?
    let event: JSONValue
}

/// Represents one owner-fenced suffix in protocol-only values for off-main processing.
struct PaneTapeFollowSnapshot: Equatable, Sendable {
    let events: [PaneTapeFollowEvent]
    let droppedEventCount: UInt64
    let droppedFeedBytes: Int
    let droppedWriteBytes: Int
    let nextCursor: PaneTapeFollowCursor
}

/// Delivers complete JSON records together with the cursor they advance through.
struct PaneTapeFollowBatch: Equatable, Sendable {
    let records: [JSONValue]
    let nextCursor: PaneTapeFollowCursor
}

/// Couples the first result record to the exact cursor its live notifications continue from.
struct PaneTapeFollowStart: Equatable, Sendable {
    let record: JSONValue
    let cursor: PaneTapeFollowCursor
}

/// Identifies the exact owner-fenced suffix an append edge may fetch. It names no
/// connection: the fetch resolves its transport under the subscription id, and a coarser
/// coordinate here is what let one stream's teardown reroute a sibling's delivery.
struct PaneTapeFollowFetch: Equatable, Sendable {
    let subscriptionId: UUID
    let paneId: UUID
    let cursor: PaneTapeFollowCursor
}

/// Names the one stream a terminal record belongs to. It carries no transport coordinate:
/// the runtime holds each stream's transport under this same subscription id, so routing an
/// `end` by anything coarser is what let one stream's teardown swallow a sibling's.
struct PaneTapeFollowEnd: Equatable, Sendable {
    let subscriptionId: UUID
    let record: JSONValue
}

/// Builds the result record that establishes a stream before notifications begin.
func makePaneTapeFollowStart(
    provenance: JSONValue,
    initial: PaneTapeFollowDimensions,
    cursor: PaneTapeFollowCursor
) -> PaneTapeFollowStart {
    PaneTapeFollowStart(
        record: .object([
            "kind": .string("start"),
            "version": .number(1),
            "provenance": provenance,
            "initial": .object([
                "columns": .number(Double(initial.columns)),
                "rows": .number(Double(initial.rows)),
            ]),
        ]),
        cursor: cursor
    )
}

/// Converts an owner-fenced suffix into an ordered gap-and-events delivery.
func makePaneTapeFollowBatch(from snapshot: PaneTapeFollowSnapshot) -> PaneTapeFollowBatch {
    var records: [JSONValue] = []
    records.reserveCapacity(snapshot.events.count + (snapshot.droppedEventCount > 0 ? 1 : 0))
    if snapshot.droppedEventCount > 0 {
        records.append(.object([
            "kind": .string("gap"),
            "droppedEventCount": .number(Double(snapshot.droppedEventCount)),
            "droppedPayloadBytes": .number(
                Double(snapshot.droppedFeedBytes + snapshot.droppedWriteBytes)
            ),
        ]))
    }
    records.append(contentsOf: snapshot.events.map { event in
        // The origin sits beside the transfer stamp rather than inside the event, because this
        // shape already hoists timing out of the event object. An absent origin omits the key:
        // a number there would read as a measurement of an event that had none.
        var record: [String: JSONValue] = [
            "kind": .string("event"),
            "sequence": .number(Double(event.sequence)),
            "elapsedNanoseconds": .number(Double(event.elapsedNanoseconds)),
            "event": event.event,
        ]
        if let origin = event.originElapsedNanoseconds {
            record["originElapsedNanoseconds"] = .number(Double(origin))
        }
        return .object(record)
    })
    return PaneTapeFollowBatch(records: records, nextCursor: snapshot.nextCursor)
}

/// Produces the only explicit stream terminator promised while the app remains alive.
func makePaneTapeFollowEndRecord(reason: String = "pane-closed") -> JSONValue {
    .object([
        "kind": .string("end"),
        "reason": .string(reason),
    ])
}

/// The single site that puts a follow record on the wire, for batches and terminators alike.
///
/// Each call enqueues straight onto the connection's serial write queue, so records reach the
/// socket in the order they were handed over. Routing one write kind through a concurrent queue
/// instead would let a terminator overtake a batch prepared before it, and a stream's last
/// record would not be its last. The optional completion reports the flush of the final record.
func writePaneTapeFollowRecords(
    _ records: [JSONValue],
    connection: IpcConnection,
    subscriptionId: UUID,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
) {
    precondition(records.isEmpty == false)
    let lastIndex = records.index(before: records.endIndex)
    for (index, record) in records.enumerated() {
        connection.writeNotification(
            method: Methods.paneTapeEvent,
            params: .object([
                "subscription": .string(subscriptionId.uuidString),
                "record": record,
            ]),
            completion: index == lastIndex ? completion : nil
        )
    }
}

/// Enforces one fetch-and-delivery batch in flight per stream and drops dead owners eagerly.
struct PaneTapeFollowSubscriptions {
    /// One main-actor-owned stream position; no event storage lives here.
    private struct Subscription {
        let connectionId: UUID
        let paneId: UUID
        var cursor: PaneTapeFollowCursor
        var isInFlight = false
        var hasPendingEvents = false
    }

    private var subscriptions: [UUID: Subscription] = [:]

    var count: Int { subscriptions.count }

    /// Registers one stream only after its start response and origin have been prepared.
    mutating func add(
        id: UUID,
        connectionId: UUID,
        paneId: UUID,
        cursor: PaneTapeFollowCursor
    ) {
        subscriptions[id] = Subscription(
            connectionId: connectionId,
            paneId: paneId,
            cursor: cursor
        )
    }

    /// Records one append edge and claims it immediately only when no batch is in flight.
    mutating func eventsAvailable(_ subscriptionId: UUID) -> PaneTapeFollowFetch? {
        guard var subscription = subscriptions[subscriptionId] else { return nil }
        subscription.hasPendingEvents = true
        subscriptions[subscriptionId] = subscription
        return claimPendingFetch(subscriptionId)
    }

    /// Advances a claimed stream through the exact suffix that will be handed to its socket.
    mutating func finishFetch(
        subscriptionId: UUID,
        batch: PaneTapeFollowBatch
    ) -> PaneTapeFollowBatch? {
        guard var subscription = subscriptions[subscriptionId], subscription.isInFlight else {
            return nil
        }
        subscription.cursor = batch.nextCursor
        subscriptions[subscriptionId] = subscription
        return batch
    }

    /// Releases one delivered batch and claims the single append edge merged behind it.
    mutating func completeDelivery(subscriptionId: UUID) -> PaneTapeFollowFetch? {
        guard var subscription = subscriptions[subscriptionId] else { return nil }
        subscription.isInFlight = false
        subscriptions[subscriptionId] = subscription
        return claimPendingFetch(subscriptionId)
    }

    /// Drops one stream whose transport is already gone, so nothing more is owed on it.
    /// Reports whether there was a stream to drop, so a repeated teardown is a no-op.
    @discardableResult
    mutating func remove(_ subscriptionId: UUID) -> Bool {
        subscriptions.removeValue(forKey: subscriptionId) != nil
    }

    /// Drops one stream that ends while its socket is still writable, and returns the
    /// terminator that stream is owed under `reason`.
    mutating func end(_ subscriptionId: UUID, reason: String) -> PaneTapeFollowEnd? {
        guard subscriptions.removeValue(forKey: subscriptionId) != nil else { return nil }
        return PaneTapeFollowEnd(
            subscriptionId: subscriptionId,
            record: makePaneTapeFollowEndRecord(reason: reason)
        )
    }

    /// Removes all streams for a vanished pane and returns their one promised terminator.
    mutating func paneClosed(_ paneId: UUID) -> [PaneTapeFollowEnd] {
        let ids = subscriptions.compactMap { id, subscription in
            subscription.paneId == paneId ? id : nil
        }
        for id in ids {
            subscriptions.removeValue(forKey: id)
        }
        return ids.map { id in
            PaneTapeFollowEnd(subscriptionId: id, record: makePaneTapeFollowEndRecord())
        }
    }

    /// Ensures a disconnected socket can never trigger another owner-queue fence.
    mutating func connectionClosed(_ connectionId: UUID) -> [UUID] {
        let removed = subscriptions.compactMap { id, subscription in
            subscription.connectionId == connectionId ? id : nil
        }
        subscriptions = subscriptions.filter { $0.value.connectionId != connectionId }
        return removed
    }

    /// Drops process-ending streams and returns the resources teardown must dispose.
    mutating func removeAll() -> [UUID] {
        let ids = Array(subscriptions.keys)
        subscriptions.removeAll()
        return ids
    }

    private mutating func claimPendingFetch(
        _ subscriptionId: UUID
    ) -> PaneTapeFollowFetch? {
        guard var subscription = subscriptions[subscriptionId],
              subscription.hasPendingEvents,
              subscription.isInFlight == false
        else { return nil }
        subscription.hasPendingEvents = false
        subscription.isInFlight = true
        subscriptions[subscriptionId] = subscription
        return PaneTapeFollowFetch(
            subscriptionId: subscriptionId,
            paneId: subscription.paneId,
            cursor: subscription.cursor
        )
    }
}
