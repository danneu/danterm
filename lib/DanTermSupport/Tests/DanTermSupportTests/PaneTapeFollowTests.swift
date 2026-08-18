// Behavioral coverage for pane-tape stream records, cursor batches, and subscriptions.
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermSupport

struct PaneTapeFollowTests {
    private static let lifetimeId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test("a finite dump ends with its own terminator after its gap and events")
    func dumpRecordsEndWithDumpComplete() {
        // Intent: everything a finite dump owes after its start record is its loss, then its
        //   events in order, then an `end` naming a completed dump.
        // Why it exists: a dump's boundary is a fence it already took, so nothing can arrive
        //   later to extend it. Stopping without that terminator would leave a reader unable
        //   to tell a whole capture from one the app died partway through, which is exactly
        //   the difference the CLI turns into a nonzero exit.
        // Scenario: an agent dumps a busy pane whose oldest events the recorder already evicted.
        let dump = PaneTapeDump(
            start: makePaneTapeStart(
                capture: .dump,
                provenance: .object(["source": .string("danterm-live-capture")]),
                initial: .init(columns: 80, rows: 24, pinned: false),
                cursor: .beginning
            ),
            snapshot: PaneTapeSnapshot(
                events: [
                    PaneTapeEvent(
                        sequence: 4,
                        elapsedNanoseconds: 11,
                        originElapsedNanoseconds: nil,
                        payload: .init(byteOffset: 6, byteLength: 2),
                        event: .object(["type": .string("feed")]),
                        needsCompleteHistory: false
                    ),
                    PaneTapeEvent(
                        sequence: 5,
                        elapsedNanoseconds: 12,
                        originElapsedNanoseconds: nil,
                        payload: nil,
                        event: .object(["type": .string("resize")]),
                        needsCompleteHistory: true
                    ),
                ],
                droppedEventCount: 4,
                droppedFeedBytes: 6,
                droppedWriteBytes: 0,
                nextCursor: .init(
                    recorderLifetimeId: Self.lifetimeId,
                    nextSequence: 6,
                    feedBytesBeforeNextSequence: 8,
                    writeBytesBeforeNextSequence: 0
                )
            )
        )

        let records = makePaneTapeDumpRecords(after: dump)

        #expect(records.map { $0["kind"] } == [
            .string("gap"),
            .string("event"),
            .string("event"),
            .string("end"),
        ])
        #expect(records.first?["droppedFeedBytes"] == .number(6))
        #expect(records.dropFirst().compactMap { $0["sequence"] } == [.number(4), .number(5)])
        #expect(records.last == .object([
            "kind": .string("end"),
            "reason": .string("dump-complete"),
        ]))
    }

    @Test("backlog and from-now starts preserve their fenced geometry and cursor")
    func startsPreserveMetadataAndCursor() {
        let backlog = makePaneTapeStart(
            capture: .dump,
            provenance: .object(["source": .string("danterm-live-capture")]),
            initial: .init(columns: 120, rows: 40, pinned: false),
            cursor: .beginning
        )

        #expect(backlog.record == .object([
            "kind": .string("start"),
            "version": .number(Double(paneTapeStreamVersion)),
            "capture": .string("dump"),
            "format": .string("replay"),
            "reconstructible": .bool(false),
            "provenance": .object(["source": .string("danterm-live-capture")]),
            "initial": .object([
                "columns": .number(120),
                "rows": .number(40),
                "pinned": .bool(false),
            ]),
            "cursor": .object([
                "recorderLifetimeId": .string(PaneTapeCursor.beginning.recorderLifetimeId.uuidString),
                "sequence": .number(0),
                "feedByteOffset": .number(0),
                "writeByteOffset": .number(0),
            ]),
        ]))
        #expect(backlog.cursor == .beginning)

        let tailCursor = PaneTapeCursor(
            recorderLifetimeId: Self.lifetimeId,
            nextSequence: 9,
            feedBytesBeforeNextSequence: 42,
            writeBytesBeforeNextSequence: 7
        )
        let fromNow = makePaneTapeStart(
            capture: .follow,
            provenance: .object(["source": .string("danterm-live-capture")]),
            initial: .init(columns: 100, rows: 30, pinned: false),
            cursor: tailCursor
        )
        #expect(fromNow.record["initial"] == .object([
            "columns": .number(100),
            "rows": .number(30),
            "pinned": .bool(false),
        ]))
        #expect(fromNow.cursor == tailCursor)
    }

    @Test("a start record states the stream version, its capture, its format, and its baseline")
    func startRecordStatesTheStreamContract() {
        // Intent: every start record declares the version a reader keys its expectations off,
        //   which of the two captures it opens, that its payloads are the replay form, and the
        //   exact three-coordinate cursor its later offsets are measured from.
        // Why it exists: a stream that starts past the beginning -- a tail-only follow, or a
        //   dump whose head was already evicted -- reports byte offsets that mean nothing
        //   without their baseline, and a reader cannot demand the right terminator without
        //   knowing which capture it is reading.
        let cursor = PaneTapeCursor(
            recorderLifetimeId: Self.lifetimeId,
            nextSequence: 12,
            feedBytesBeforeNextSequence: 480,
            writeBytesBeforeNextSequence: 36
        )
        let start = makePaneTapeStart(
            capture: .follow,
            provenance: .object(["source": .string("danterm-live-capture")]),
            initial: .init(columns: 100, rows: 30, pinned: false),
            cursor: cursor
        )

        #expect(start.record["version"] == .number(Double(paneTapeStreamVersion)))
        #expect(start.record["capture"] == .string("follow"))
        #expect(start.record["format"] == .string("replay"))
        #expect(start.record["cursor"] == .object([
            "recorderLifetimeId": .string(Self.lifetimeId.uuidString),
            "sequence": .number(12),
            "feedByteOffset": .number(480),
            "writeByteOffset": .number(36),
        ]))
    }

    @Test("an event record locates its bytes only when it carries any")
    func eventRecordCarriesItsPayloadSpanOnlyWhenItHasOne() {
        // Intent: an event that carries bytes reports where they sit in its own direction's
        //   stream, and an event that carries none reports neither coordinate.
        // Why it exists: a reader turns an offset back into a position in one direction's
        //   byte stream. A zero offset on a resize would name a real position in that stream
        //   which no byte of that event occupies.
        let batch = makePaneTapeBatch(from: .init(
            events: [
                .init(
                    sequence: 4,
                    elapsedNanoseconds: 10,
                    originElapsedNanoseconds: nil,
                    payload: .init(byteOffset: 96, byteLength: 12),
                    event: .object(["type": .string("feed"), "base64": .string("SGk=")]),
                    needsCompleteHistory: false
                ),
                .init(
                    sequence: 5,
                    elapsedNanoseconds: 20,
                    originElapsedNanoseconds: nil,
                    payload: nil,
                    event: .object([
                        "type": .string("resize"),
                        "columns": .number(100),
                        "rows": .number(30),
                    ]),
                    needsCompleteHistory: true
                ),
            ],
            droppedEventCount: 0,
            droppedFeedBytes: 0,
            droppedWriteBytes: 0,
            nextCursor: .init(
                recorderLifetimeId: Self.lifetimeId,
                nextSequence: 6,
                feedBytesBeforeNextSequence: 108,
                writeBytesBeforeNextSequence: 0
            )
        ))

        #expect(batch.records.first?["byteOffset"] == .number(96))
        #expect(batch.records.first?["byteLength"] == .number(12))
        #expect(batch.records.last?["byteOffset"] == nil)
        #expect(batch.records.last?["byteLength"] == nil)
    }

    @Test("each end reason reaches the wire with its own spelling")
    func endRecordSpellsEveryReason() {
        // Intent: the three reasons a producer can state are distinct strings on the wire.
        // Why it exists: a reader holds a finite dump to `dump-complete` and accepts
        //   the two follow endings, so two reasons sharing a spelling would let a truncated
        //   dump pass as a complete one.
        #expect(makePaneTapeEndRecord(reason: .dumpComplete) == .object([
            "kind": .string("end"),
            "reason": .string("dump-complete"),
        ]))
        #expect(makePaneTapeEndRecord(reason: .paneClosed) == .object([
            "kind": .string("end"),
            "reason": .string("pane-closed"),
        ]))
        #expect(makePaneTapeEndRecord(reason: .streamFailed) == .object([
            "kind": .string("end"),
            "reason": .string("stream-failed"),
        ]))
    }

    @Test("empty cursor snapshot emits nothing and leaves the cursor unchanged")
    func emptySnapshotLeavesCursorUnchanged() {
        let cursor = PaneTapeCursor(
            recorderLifetimeId: Self.lifetimeId,
            nextSequence: 4,
            feedBytesBeforeNextSequence: 20,
            writeBytesBeforeNextSequence: 0
        )
        let batch = makePaneTapeBatch(from: .init(
            events: [],
            droppedEventCount: 0,
            droppedFeedBytes: 0,
            droppedWriteBytes: 0,
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
        let nextCursor = PaneTapeCursor(
            recorderLifetimeId: Self.lifetimeId,
            nextSequence: 9,
            feedBytesBeforeNextSequence: 99,
            writeBytesBeforeNextSequence: 0
        )
        let batch = makePaneTapeBatch(from: .init(
            events: [
                .init(
                    sequence: 7,
                    elapsedNanoseconds: 10,
                    originElapsedNanoseconds: nil,
                    payload: .init(byteOffset: 30, byteLength: 2),
                    event: feed,
                    needsCompleteHistory: false
                ),
                .init(
                    sequence: 8,
                    elapsedNanoseconds: 20,
                    originElapsedNanoseconds: nil,
                    payload: nil,
                    event: resize,
                    needsCompleteHistory: true
                ),
            ],
            droppedEventCount: 7,
            droppedFeedBytes: 30,
            droppedWriteBytes: 12,
            nextCursor: nextCursor
        ))

        // The two directions stay apart: a summed loss cannot be subtracted from either
        // stream's offsets, which would leave every byte position after the gap unverifiable.
        #expect(batch.records.first == .object([
            "kind": .string("gap"),
            "droppedEventCount": .number(7),
            "droppedFeedBytes": .number(30),
            "droppedWriteBytes": .number(12),
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
        let batch = makePaneTapeBatch(from: .init(
            events: [
                .init(
                    sequence: 0,
                    elapsedNanoseconds: 30,
                    originElapsedNanoseconds: 10,
                    payload: nil,
                    event: write,
                    needsCompleteHistory: false
                ),
                .init(
                    sequence: 1,
                    elapsedNanoseconds: 40,
                    originElapsedNanoseconds: nil,
                    payload: nil,
                    event: feed,
                    needsCompleteHistory: false
                ),
            ],
            droppedEventCount: 0,
            droppedFeedBytes: 0,
            droppedWriteBytes: 0,
            nextCursor: .init(
                recorderLifetimeId: Self.lifetimeId,
                nextSequence: 2,
                feedBytesBeforeNextSequence: 4,
                writeBytesBeforeNextSequence: 0
            )
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
        let first = makePaneTapeBatch(from: snapshot(sequences: [0, 1], nextSequence: 2))
        let second = makePaneTapeBatch(from: snapshot(sequences: [2, 3], nextSequence: 4))

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

        let preparedBatch = makePaneTapeBatch(
            from: snapshot(sequences: [0], nextSequence: 1)
        )
        let finishedBatch = subscriptions.finishFetch(
            subscriptionId: subscriptionId,
            continuation: .init(batch: preparedBatch, replicaHistoryIsComplete: false)
        )
        let batch = try #require(finishedBatch)
        #expect(batch.records.compactMap(sequence) == [0])

        let pendingFetch = subscriptions.completeDelivery(subscriptionId: subscriptionId)
        let followUp = try #require(pendingFetch)
        #expect(followUp.cursor.nextSequence == 1)
        #expect(subscriptions.eventsAvailable(subscriptionId) == nil)
    }

    // Intent: a stream's fetch carries the replica's history standing beside its cursor, and
    //   each delivered continuation restates it for the next fetch.
    // Why it exists: the standing decides whether the next suffix may carry a resize. Held
    //   anywhere but with the cursor it could drift from the position it describes, and a
    //   stream would forward a resize a replica cannot reflow.
    // Scenario: a stream opens on a truncated sync, takes one continuation that resyncs it
    //   whole, and the fetch after that reports it exact.
    @Test("a stream's replica history standing travels with its cursor across fetches")
    func replicaHistoryStandingTravelsWithTheCursor() throws {
        let subscriptionId = UUID()
        var subscriptions = PaneTapeFollowSubscriptions()
        subscriptions.add(
            id: subscriptionId,
            connectionId: UUID(),
            paneId: UUID(),
            cursor: .beginning,
            replicaHistoryIsComplete: false
        )

        let opened = subscriptions.eventsAvailable(subscriptionId)
        let firstFetch = try #require(opened)
        #expect(firstFetch.replicaHistoryIsComplete == false)

        _ = subscriptions.finishFetch(
            subscriptionId: subscriptionId,
            continuation: .init(
                batch: makePaneTapeBatch(from: snapshot(sequences: [0], nextSequence: 1)),
                replicaHistoryIsComplete: true
            )
        )
        _ = subscriptions.completeDelivery(subscriptionId: subscriptionId)

        let resumed = subscriptions.eventsAvailable(subscriptionId)
        let secondFetch = try #require(resumed)
        #expect(secondFetch.replicaHistoryIsComplete)
        #expect(secondFetch.cursor.nextSequence == 1)
    }

    @Test("live output waits until every opening synchronization record is delivered")
    func openingSynchronizationBlocksLiveFetch() throws {
        let subscriptionId = UUID()
        let cursor = PaneTapeCursor(
            recorderLifetimeId: Self.lifetimeId,
            nextSequence: 7,
            feedBytesBeforeNextSequence: 40,
            writeBytesBeforeNextSequence: 2
        )
        var subscriptions = PaneTapeFollowSubscriptions()
        subscriptions.add(
            id: subscriptionId,
            connectionId: UUID(),
            paneId: UUID(),
            cursor: cursor,
            isDeliveringOpening: true
        )

        #expect(subscriptions.eventsAvailable(subscriptionId) == nil)
        let completedOpening = subscriptions.completeDelivery(subscriptionId: subscriptionId)
        let fetch = try #require(completedOpening)
        #expect(fetch.cursor == cursor)
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
        let siblingCursor = PaneTapeCursor(
            recorderLifetimeId: Self.lifetimeId,
            nextSequence: 12,
            feedBytesBeforeNextSequence: 480,
            writeBytesBeforeNextSequence: 0
        )
        subscriptions.add(
            id: siblingId,
            connectionId: connectionId,
            paneId: UUID(),
            cursor: siblingCursor
        )

        let end = subscriptions.end(retiredId, reason: .streamFailed)
        #expect(end?.subscriptionId == retiredId)
        #expect(end?.record == .object([
            "kind": .string("end"),
            "reason": .string("stream-failed"),
        ]))
        #expect(subscriptions.end(retiredId, reason: .streamFailed) == nil)
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
    ) -> PaneTapeSnapshot {
        PaneTapeSnapshot(
            events: sequences.map {
                .init(
                    sequence: $0,
                    elapsedNanoseconds: $0 * 10,
                    originElapsedNanoseconds: nil,
                    payload: .init(byteOffset: Int($0), byteLength: 0),
                    event: .object(["type": .string("feed"), "base64": .string("")]),
                    needsCompleteHistory: false
                )
            },
            droppedEventCount: 0,
            droppedFeedBytes: 0,
            droppedWriteBytes: 0,
            nextCursor: .init(
                recorderLifetimeId: Self.lifetimeId,
                nextSequence: nextSequence,
                feedBytesBeforeNextSequence: Int(nextSequence),
                writeBytesBeforeNextSequence: 0
            )
        )
    }

    private func sequence(_ record: JSONValue) -> UInt64? {
        guard let value = record["sequence"]?.asNumber else { return nil }
        return UInt64(value)
    }
}
