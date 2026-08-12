// Portable pane-tape stream values, record construction, and bounded subscription lifecycle.
import Foundation
import DanTermProtocol

/// Carries both coordinates needed to resume after recorder eviction without estimating loss.
struct PaneTapeFollowCursor: Equatable, Sendable {
    let nextSequence: UInt64
    let payloadBytesBeforeNextSequence: Int

    static let beginning = Self(nextSequence: 0, payloadBytesBeforeNextSequence: 0)
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
    let droppedPayloadBytes: Int
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

/// Identifies the exact owner-fenced suffix an append edge may fetch.
struct PaneTapeFollowFetch: Equatable, Sendable {
    let subscriptionId: UUID
    let connectionId: UUID
    let paneId: UUID
    let cursor: PaneTapeFollowCursor
}

/// Routes one terminal record before the runtime closes its owning connection.
struct PaneTapeFollowEnd: Equatable, Sendable {
    let subscriptionId: UUID
    let connectionId: UUID
    let record: JSONValue
}

/// Carries the owner coordinates needed to remove a disconnected recorder notice.
struct PaneTapeFollowRemoval: Equatable, Sendable {
    let subscriptionId: UUID
    let connectionId: UUID
    let paneId: UUID
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
            "droppedPayloadBytes": .number(Double(snapshot.droppedPayloadBytes)),
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

    /// Removes one failed stream while preserving the coordinates needed to disarm its recorder.
    mutating func remove(_ subscriptionId: UUID) -> PaneTapeFollowRemoval? {
        guard let subscription = subscriptions.removeValue(forKey: subscriptionId) else {
            return nil
        }
        return PaneTapeFollowRemoval(
            subscriptionId: subscriptionId,
            connectionId: subscription.connectionId,
            paneId: subscription.paneId
        )
    }

    /// Removes all streams for a vanished pane and returns their one promised terminator.
    mutating func paneClosed(_ paneId: UUID) -> [PaneTapeFollowEnd] {
        let ids = subscriptions.compactMap { id, subscription in
            subscription.paneId == paneId ? id : nil
        }
        return ids.compactMap { id in
            guard let subscription = subscriptions.removeValue(forKey: id) else { return nil }
            return PaneTapeFollowEnd(
                subscriptionId: id,
                connectionId: subscription.connectionId,
                record: makePaneTapeFollowEndRecord()
            )
        }
    }

    /// Ensures a disconnected socket can never trigger another owner-queue fence.
    mutating func connectionClosed(_ connectionId: UUID) -> [PaneTapeFollowRemoval] {
        let removed = subscriptions.compactMap { id, subscription -> PaneTapeFollowRemoval? in
            guard subscription.connectionId == connectionId else { return nil }
            return PaneTapeFollowRemoval(
                subscriptionId: id,
                connectionId: connectionId,
                paneId: subscription.paneId
            )
        }
        subscriptions = subscriptions.filter { $0.value.connectionId != connectionId }
        return removed
    }

    /// Drops process-ending streams and returns the recorder notices teardown must disarm.
    mutating func removeAll() -> [PaneTapeFollowRemoval] {
        let removals = subscriptions.map { id, subscription in
            PaneTapeFollowRemoval(
                subscriptionId: id,
                connectionId: subscription.connectionId,
                paneId: subscription.paneId
            )
        }
        subscriptions.removeAll()
        return removals
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
            connectionId: subscription.connectionId,
            paneId: subscription.paneId,
            cursor: subscription.cursor
        )
    }
}
