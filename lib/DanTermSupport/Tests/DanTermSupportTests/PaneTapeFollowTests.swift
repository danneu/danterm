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
                .init(sequence: 7, elapsedNanoseconds: 10, event: feed),
                .init(sequence: 8, elapsedNanoseconds: 20, event: resize),
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

    @Test("consecutive cursor batches neither duplicate nor skip a sequence")
    func consecutiveBatchesAreContiguous() {
        let first = makePaneTapeFollowBatch(from: snapshot(sequences: [0, 1], nextSequence: 2))
        let second = makePaneTapeFollowBatch(from: snapshot(sequences: [2, 3], nextSequence: 4))

        #expect((first.records + second.records).compactMap(sequence) == [0, 1, 2, 3])
        #expect(first.nextCursor.nextSequence == 2)
        #expect(second.nextCursor.nextSequence == 4)
    }

    @Test("in-flight subscriptions are fetched once until delivery completes")
    func inFlightSubscriptionWaitsForDelivery() throws {
        let subscriptionId = UUID()
        var subscriptions = PaneTapeFollowSubscriptions()
        subscriptions.add(
            id: subscriptionId,
            connectionId: UUID(),
            paneId: UUID(),
            cursor: .beginning
        )

        let firstFetch = try #require(subscriptions.beginFetches().first)
        #expect(firstFetch.subscriptionId == subscriptionId)
        #expect(subscriptions.beginFetches().isEmpty)

        let preparedBatch = makePaneTapeFollowBatch(
            from: snapshot(sequences: [0], nextSequence: 1)
        )
        let finishedBatch = subscriptions.finishFetch(
            subscriptionId: subscriptionId,
            batch: preparedBatch
        )
        let batch = try #require(finishedBatch)
        #expect(batch.records.compactMap(sequence) == [0])
        #expect(subscriptions.beginFetches().isEmpty)

        subscriptions.completeDelivery(subscriptionId: subscriptionId, succeeded: true)
        #expect(subscriptions.beginFetches().first?.cursor.nextSequence == 1)
    }

    @Test("pane close ends each matching stream once and connection close removes ownership")
    func paneAndConnectionClosureRemoveSubscriptions() {
        let paneId = UUID()
        let firstConnection = UUID()
        let secondConnection = UUID()
        var subscriptions = PaneTapeFollowSubscriptions()
        subscriptions.add(id: UUID(), connectionId: firstConnection, paneId: paneId, cursor: .beginning)
        subscriptions.add(id: UUID(), connectionId: secondConnection, paneId: paneId, cursor: .beginning)
        subscriptions.add(id: UUID(), connectionId: firstConnection, paneId: UUID(), cursor: .beginning)

        let ends = subscriptions.paneClosed(paneId)
        #expect(ends.count == 2)
        #expect(ends.allSatisfy { $0.record == .object([
            "kind": .string("end"),
            "reason": .string("pane-closed"),
        ]) })
        #expect(subscriptions.paneClosed(paneId).isEmpty)

        subscriptions.connectionClosed(firstConnection)
        #expect(subscriptions.count == 0)
        #expect(subscriptions.beginFetches().isEmpty)
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
