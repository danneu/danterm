// Behavioral coverage for pane-tape stream records, cursor batches, and subscriptions.
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermCore

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
        let dump = PaneTapeDump<JSONValue>(
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

        #expect(records.map(kind) == [.gap, .event, .event, .end])
        #expect(gap(records.first)?.droppedFeedBytes == 6)
        #expect(records.dropFirst().compactMap(sequence) == [4, 5])
        #expect(records.last == .end(reason: .dumpComplete))
    }

    @Test("backlog and from-now starts preserve their fenced geometry and cursor")
    func startsPreserveMetadataAndCursor() {
        let backlog = makePaneTapeStart(
            capture: .dump,
            provenance: .object(["source": .string("danterm-live-capture")]),
            initial: .init(columns: 120, rows: 40, pinned: false),
            cursor: .beginning
        )

        #expect(backlog.record == PaneTapeStartRecord(
            version: paneTapeStreamVersion,
            capture: .dump,
            format: .replay,
            provenance: .object(["source": .string("danterm-live-capture")]),
            columns: 120,
            rows: 40,
            pinned: false,
            cursor: .beginning,
            reconstructible: false
        ))
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
        #expect(fromNow.record.columns == 100)
        #expect(fromNow.record.rows == 30)
        #expect(fromNow.record.pinned == false)
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

        #expect(start.record.version == paneTapeStreamVersion)
        #expect(start.record.capture == .follow)
        #expect(start.record.format == .replay)
        #expect(start.record.cursor == cursor)
    }

    @Test("an event record locates its bytes only when it carries any")
    func eventRecordCarriesItsPayloadSpanOnlyWhenItHasOne() {
        // Intent: an event that carries bytes reports where they sit in its own direction's
        //   stream, and an event that carries none reports neither coordinate.
        // Why it exists: a reader turns an offset back into a position in one direction's
        //   byte stream. A zero offset on a resize would name a real position in that stream
        //   which no byte of that event occupies.
        let batch = makePaneTapeBatch(from: PaneTapeSnapshot<JSONValue>(
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

        #expect(event(batch.records.first)?.byteOffset == 96)
        #expect(event(batch.records.first)?.byteLength == 12)
        #expect(event(batch.records.last)?.byteOffset == nil)
        #expect(event(batch.records.last)?.byteLength == nil)
    }

    @Test("empty cursor snapshot emits nothing and leaves the cursor unchanged")
    func emptySnapshotLeavesCursorUnchanged() {
        let cursor = PaneTapeCursor(
            recorderLifetimeId: Self.lifetimeId,
            nextSequence: 4,
            feedBytesBeforeNextSequence: 20,
            writeBytesBeforeNextSequence: 0
        )
        let batch = makePaneTapeBatch(from: PaneTapeSnapshot<JSONValue>(
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
        let batch = makePaneTapeBatch(from: PaneTapeSnapshot<JSONValue>(
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
        #expect(batch.records.first == .gap(PaneTapeGapRecord(
            droppedEventCount: 7,
            droppedFeedBytes: 30,
            droppedWriteBytes: 12
        )))
        #expect(batch.records.dropFirst().compactMap { event($0)?.event } == [feed, resize])
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
        let batch = makePaneTapeBatch(from: PaneTapeSnapshot<JSONValue>(
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

        #expect(batch.records.first == .event(PaneTapeEventRecord(
            sequence: 0,
            elapsedNanoseconds: 30,
            originElapsedNanoseconds: 10,
            byteOffset: nil,
            byteLength: nil,
            event: write
        )))
        #expect(batch.records.last == .event(PaneTapeEventRecord(
            sequence: 1,
            elapsedNanoseconds: 40,
            originElapsedNanoseconds: nil,
            byteOffset: nil,
            byteLength: nil,
            event: feed
        )))
    }

    @Test("consecutive cursor batches neither duplicate nor skip a sequence")
    func consecutiveBatchesAreContiguous() {
        let first = makePaneTapeBatch(from: snapshot(sequences: [0, 1], nextSequence: 2))
        let second = makePaneTapeBatch(from: snapshot(sequences: [2, 3], nextSequence: 4))

        #expect((first.records + second.records).compactMap(sequence) == [0, 1, 2, 3])
        #expect(first.nextCursor.nextSequence == 2)
        #expect(second.nextCursor.nextSequence == 4)
    }

    private func snapshot(
        sequences: [UInt64],
        nextSequence: UInt64
    ) -> PaneTapeSnapshot<JSONValue> {
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

    private func kind(_ record: PaneTapeOutgoingRecord<JSONValue>) -> PaneTapeRecordKind {
        switch record {
        case .start: .start
        case .gap: .gap
        case .event: .event
        case .sync: .sync
        case .end: .end
        }
    }

    private func gap(_ record: PaneTapeOutgoingRecord<JSONValue>?) -> PaneTapeGapRecord? {
        guard case .gap(let gap)? = record else { return nil }
        return gap
    }

    private func event(
        _ record: PaneTapeOutgoingRecord<JSONValue>?
    ) -> PaneTapeEventRecord<JSONValue>? {
        guard case .event(let event)? = record else { return nil }
        return event
    }

    private func sequence(_ record: PaneTapeOutgoingRecord<JSONValue>) -> UInt64? {
        event(record)?.sequence
    }
}
