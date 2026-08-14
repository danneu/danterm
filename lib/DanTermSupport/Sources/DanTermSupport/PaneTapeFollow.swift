// The bounded lifecycle of a followed pane-tape stream: which fence a subscription may claim,
// which batch it owes, and what it is owed when it ends. The record shapes it delivers are
// built in PaneTapeRecords.swift, shared with the finite dump; nothing here restates them.
import Foundation
import DanTermProtocol

/// Identifies the exact owner-fenced suffix an append edge may fetch. It names no
/// connection: the fetch resolves its transport under the subscription id, and a coarser
/// coordinate here is what let one stream's teardown reroute a sibling's delivery.
struct PaneTapeFollowFetch: Equatable, Sendable {
    let subscriptionId: UUID
    let paneId: UUID
    let cursor: PaneTapeCursor
}

/// Names the one stream a terminal record belongs to. It carries no transport coordinate:
/// the runtime holds each stream's transport under this same subscription id, so routing an
/// `end` by anything coarser is what let one stream's teardown swallow a sibling's.
struct PaneTapeFollowEnd: Equatable, Sendable {
    let subscriptionId: UUID
    let record: JSONValue
}

/// Enforces one fetch-and-delivery batch in flight per stream and drops dead owners eagerly.
struct PaneTapeFollowSubscriptions {
    /// One main-actor-owned stream position; no event storage lives here.
    private struct Subscription {
        let connectionId: UUID
        let paneId: UUID
        var cursor: PaneTapeCursor
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
        cursor: PaneTapeCursor,
        isDeliveringOpening: Bool = false
    ) {
        subscriptions[id] = Subscription(
            connectionId: connectionId,
            paneId: paneId,
            cursor: cursor,
            isInFlight: isDeliveringOpening
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
        batch: PaneTapeBatch
    ) -> PaneTapeBatch? {
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
    mutating func end(_ subscriptionId: UUID, reason: PaneTapeEndReason) -> PaneTapeFollowEnd? {
        guard subscriptions.removeValue(forKey: subscriptionId) != nil else { return nil }
        return PaneTapeFollowEnd(
            subscriptionId: subscriptionId,
            record: makePaneTapeEndRecord(reason: reason)
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
            PaneTapeFollowEnd(
                subscriptionId: id,
                record: makePaneTapeEndRecord(reason: .paneClosed)
            )
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
