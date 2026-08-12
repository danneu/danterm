// Behavioral coverage for pane-tape stream records, cursor batches, and subscriptions.
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermSupport

struct PaneTapeFollowTests {
    @Test("backlog and from-now starts preserve their fenced geometry and cursor")
    func startsPreserveMetadataAndCursor() {
        let backlog = makePaneTapeFollowStart(
            provenance: .object(["source": .string("danterm-live-capture")]),
            initial: .init(columns: 120, rows: 40),
            cursor: .beginning
        )

        #expect(backlog.record == .object([
            "kind": .string("start"),
            "version": .number(1),
            "provenance": .object(["source": .string("danterm-live-capture")]),
            "initial": .object([
                "columns": .number(120),
                "rows": .number(40),
            ]),
        ]))
        #expect(backlog.cursor == .beginning)

        let tailCursor = PaneTapeFollowCursor(
            nextSequence: 9,
            payloadBytesBeforeNextSequence: 42
        )
        let fromNow = makePaneTapeFollowStart(
            provenance: .object(["source": .string("danterm-live-capture")]),
            initial: .init(columns: 100, rows: 30),
            cursor: tailCursor
        )
        #expect(fromNow.record["initial"] == .object([
            "columns": .number(100),
            "rows": .number(30),
        ]))
        #expect(fromNow.cursor == tailCursor)
    }

    @Test("empty cursor snapshot emits nothing and leaves the cursor unchanged")
    func emptySnapshotLeavesCursorUnchanged() {
        let cursor = PaneTapeFollowCursor(nextSequence: 4, payloadBytesBeforeNextSequence: 20)
        let batch = makePaneTapeFollowBatch(from: .init(
            events: [],
            droppedEventCount: 0,
            droppedPayloadBytes: 0,
            nextCursor: cursor
        ))

        #expect(batch.records.isEmpty)
        #expect(batch.nextCursor == cursor)
    }

    @Test("gap precedes retained events with exact loss and unchanged event JSON")
    func gapPrecedesEventsAndPreservesEventJSON() {
        let feed: JSONValue = .object(["type": .string("feed"), "base64": .string("SGk=")])
        let resize: JSONValue = .object([
            "type": .string("resize"),
            "columns": .number(100),
            "rows": .number(30),
        ])
        let nextCursor = PaneTapeFollowCursor(nextSequence: 9, payloadBytesBeforeNextSequence: 99)
        let batch = makePaneTapeFollowBatch(from: .init(
            events: [
                .init(sequence: 7, elapsedNanoseconds: 10, originElapsedNanoseconds: nil, event: feed),
                .init(sequence: 8, elapsedNanoseconds: 20, originElapsedNanoseconds: nil, event: resize),
            ],
            droppedEventCount: 7,
            droppedPayloadBytes: 42,
            nextCursor: nextCursor
        ))

        #expect(batch.records.first == .object([
            "kind": .string("gap"),
            "droppedEventCount": .number(7),
            "droppedPayloadBytes": .number(42),
        ]))
        #expect(batch.records.dropFirst().map { $0["event"] } == [feed, resize])
        #expect(batch.nextCursor == nextCursor)
    }

    @Test("an event's origin stamp is carried beside its transfer stamp")
    func originStampIsCarriedBesideTheTransferStamp() {
        // Intent: a stream record reports the origin of the bytes it carries, next to the
        //   stamp for the transfer itself, and omits the key for an event that has no origin.
        // Why it exists: the follow stream hoists timing above the event object, so an origin
        //   left inside the event -- or emitted as zero -- would reach readers as a different
        //   fact from the one the recorder holds.
        let write: JSONValue = .object(["type": .string("write"), "base64": .string("SGk=")])
        let feed: JSONValue = .object(["type": .string("feed"), "base64": .string("SGk=")])
        let batch = makePaneTapeFollowBatch(from: .init(
            events: [
                .init(sequence: 0, elapsedNanoseconds: 30, originElapsedNanoseconds: 10, event: write),
                .init(sequence: 1, elapsedNanoseconds: 40, originElapsedNanoseconds: nil, event: feed),
            ],
            droppedEventCount: 0,
            droppedPayloadBytes: 0,
            nextCursor: .init(nextSequence: 2, payloadBytesBeforeNextSequence: 4)
        ))

        #expect(batch.records.first == .object([
            "kind": .string("event"),
            "sequence": .number(0),
            "elapsedNanoseconds": .number(30),
            "originElapsedNanoseconds": .number(10),
            "event": write,
        ]))
        #expect(batch.records.last == .object([
            "kind": .string("event"),
            "sequence": .number(1),
            "elapsedNanoseconds": .number(40),
            "event": feed,
        ]))
    }

    @Test("consecutive cursor batches neither duplicate nor skip a sequence")
    func consecutiveBatchesAreContiguous() {
        let first = makePaneTapeFollowBatch(from: snapshot(sequences: [0, 1], nextSequence: 2))
        let second = makePaneTapeFollowBatch(from: snapshot(sequences: [2, 3], nextSequence: 4))

        #expect((first.records + second.records).compactMap(sequence) == [0, 1, 2, 3])
        #expect(first.nextCursor.nextSequence == 2)
        #expect(second.nextCursor.nextSequence == 4)
    }

    @Test("an append during delivery starts one follow-up fetch after completion")
    func appendDuringDeliveryStartsOneFollowUpFetch() throws {
        let subscriptionId = UUID()
        var subscriptions = PaneTapeFollowSubscriptions()
        subscriptions.add(
            id: subscriptionId,
            connectionId: UUID(),
            paneId: UUID(),
            cursor: .beginning
        )

        let availableFetch = subscriptions.eventsAvailable(subscriptionId)
        let firstFetch = try #require(availableFetch)
        #expect(firstFetch.subscriptionId == subscriptionId)
        #expect(subscriptions.eventsAvailable(subscriptionId) == nil)

        let preparedBatch = makePaneTapeFollowBatch(
            from: snapshot(sequences: [0], nextSequence: 1)
        )
        let finishedBatch = subscriptions.finishFetch(
            subscriptionId: subscriptionId,
            batch: preparedBatch
        )
        let batch = try #require(finishedBatch)
        #expect(batch.records.compactMap(sequence) == [0])

        let pendingFetch = subscriptions.completeDelivery(subscriptionId: subscriptionId)
        let followUp = try #require(pendingFetch)
        #expect(followUp.cursor.nextSequence == 1)
        #expect(subscriptions.eventsAvailable(subscriptionId) == nil)
    }

    @Test("delivery completion stays idle when no append arrived in flight")
    func deliveryCompletionWithoutPendingAppendStaysIdle() throws {
        let subscriptionId = UUID()
        var subscriptions = PaneTapeFollowSubscriptions()
        subscriptions.add(
            id: subscriptionId,
            connectionId: UUID(),
            paneId: UUID(),
            cursor: .beginning
        )

        let availableFetch = subscriptions.eventsAvailable(subscriptionId)
        _ = try #require(availableFetch)
        #expect(subscriptions.completeDelivery(subscriptionId: subscriptionId) == nil)
    }

    @Test("pane close ends every stream on that pane, one terminator per subscription")
    func paneClosureEndsEveryStreamOnThatPane() {
        // Intent: closing a pane produces exactly one `end` per stream watching it, and
        //   leaves streams on other panes alone.
        // Why it exists: the terminators used to be routed by connection, so two streams
        //   sharing a socket cost one of them its promised `end` record.
        // Scenario: two agents follow the same pane -- one of them over the socket it also
        //   uses to follow a second pane -- and the watched pane closes.
        let closingPane = UUID()
        let sharedConnection = UUID()
        let otherPaneSubscriptionId = UUID()
        let firstSubscriptionId = UUID()
        let secondSubscriptionId = UUID()
        var subscriptions = PaneTapeFollowSubscriptions()
        subscriptions.add(
            id: firstSubscriptionId,
            connectionId: sharedConnection,
            paneId: closingPane,
            cursor: .beginning
        )
        subscriptions.add(
            id: secondSubscriptionId,
            connectionId: UUID(),
            paneId: closingPane,
            cursor: .beginning
        )
        subscriptions.add(
            id: otherPaneSubscriptionId,
            connectionId: sharedConnection,
            paneId: UUID(),
            cursor: .beginning
        )

        let ends = subscriptions.paneClosed(closingPane)
        #expect(Set(ends.map(\.subscriptionId)) == [firstSubscriptionId, secondSubscriptionId])
        #expect(ends.allSatisfy { $0.record == .object([
            "kind": .string("end"),
            "reason": .string("pane-closed"),
        ]) })
        #expect(subscriptions.paneClosed(closingPane).isEmpty)
        #expect(subscriptions.count == 1)
        #expect(subscriptions.eventsAvailable(otherPaneSubscriptionId)?.subscriptionId
                == otherPaneSubscriptionId)
    }

    @Test("retiring one stream on a socket leaves its sibling claiming at its own cursor")
    func retiringOneStreamLeavesTheSiblingOnThatSocketIntact() {
        // Intent: ending one subscription never disturbs another on the same connection.
        // Why it exists: the runtime's follow resources used to be keyed by connection and
        //   shared by every stream on that socket, so retiring one silently dropped the rest.
        // Scenario: one agent follows two panes over a single socket and stops one follow.
        let connectionId = UUID()
        let retiredId = UUID()
        let siblingId = UUID()
        var subscriptions = PaneTapeFollowSubscriptions()
        subscriptions.add(
            id: retiredId,
            connectionId: connectionId,
            paneId: UUID(),
            cursor: .beginning
        )
        let siblingCursor = PaneTapeFollowCursor(
            nextSequence: 12,
            payloadBytesBeforeNextSequence: 480
        )
        subscriptions.add(
            id: siblingId,
            connectionId: connectionId,
            paneId: UUID(),
            cursor: siblingCursor
        )

        let end = subscriptions.end(retiredId, reason: "stream-failed")
        #expect(end?.subscriptionId == retiredId)
        #expect(end?.record == .object([
            "kind": .string("end"),
            "reason": .string("stream-failed"),
        ]))
        #expect(subscriptions.end(retiredId, reason: "stream-failed") == nil)
        #expect(subscriptions.eventsAvailable(retiredId) == nil)

        let siblingFetch = subscriptions.eventsAvailable(siblingId)
        #expect(siblingFetch?.subscriptionId == siblingId)
        #expect(siblingFetch?.cursor == siblingCursor)
        #expect(subscriptions.count == 1)
    }

    @Test("removing a stream with a dead transport reports it without a terminator")
    func removingAStreamWithADeadTransportYieldsNoTerminator() {
        // Intent: `remove` retires a stream whose socket already failed, so no record is
        //   produced, and it reports whether there was a stream to retire.
        // Why it exists: the delivery-failure path must not try to write to a socket the
        //   transport just closed, while still disposing exactly that stream's resources.
        let subscriptionId = UUID()
        var subscriptions = PaneTapeFollowSubscriptions()
        subscriptions.add(
            id: subscriptionId,
            connectionId: UUID(),
            paneId: UUID(),
            cursor: .beginning
        )

        let removed = subscriptions.remove(subscriptionId)
        let removedAgain = subscriptions.remove(subscriptionId)
        #expect(removed)
        #expect(removedAgain == false)
        #expect(subscriptions.count == 0)
    }

    @Test("connection close and remove-all report every subscription the runtime must dispose")
    func bulkRemovalsReportEverySubscriptionId() {
        // Intent: both bulk removals name each retired subscription, and connection close
        //   leaves streams on other sockets claimable.
        // Why it exists: the runtime disposes transport resources per subscription, so a
        //   removal that reported fewer ids than it dropped would leak a recorder notice
        //   and a shutdown census entry.
        let closingConnection = UUID()
        let firstId = UUID()
        let secondId = UUID()
        let survivorId = UUID()
        var subscriptions = PaneTapeFollowSubscriptions()
        subscriptions.add(id: firstId, connectionId: closingConnection, paneId: UUID(), cursor: .beginning)
        subscriptions.add(id: secondId, connectionId: closingConnection, paneId: UUID(), cursor: .beginning)
        subscriptions.add(id: survivorId, connectionId: UUID(), paneId: UUID(), cursor: .beginning)

        #expect(Set(subscriptions.connectionClosed(closingConnection)) == [firstId, secondId])
        #expect(subscriptions.connectionClosed(closingConnection).isEmpty)
        #expect(subscriptions.eventsAvailable(firstId) == nil)
        #expect(subscriptions.eventsAvailable(survivorId)?.subscriptionId == survivorId)

        #expect(subscriptions.removeAll() == [survivorId])
        #expect(subscriptions.count == 0)
        #expect(subscriptions.removeAll().isEmpty)
    }

    private func snapshot(
        sequences: [UInt64],
        nextSequence: UInt64
    ) -> PaneTapeFollowSnapshot {
        PaneTapeFollowSnapshot(
            events: sequences.map {
                .init(
                    sequence: $0,
                    elapsedNanoseconds: $0 * 10,
                    originElapsedNanoseconds: nil,
                    event: .object(["type": .string("feed"), "base64": .string("")])
                )
            },
            droppedEventCount: 0,
            droppedPayloadBytes: 0,
            nextCursor: .init(
                nextSequence: nextSequence,
                payloadBytesBeforeNextSequence: Int(nextSequence)
            )
        )
    }

    private func sequence(_ record: JSONValue) -> UInt64? {
        guard let value = record["sequence"]?.asNumber else { return nil }
        return UInt64(value)
    }
}
