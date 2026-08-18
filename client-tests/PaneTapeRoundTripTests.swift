// The pane-tape record shape, checked end to end: every record the Mac host's producer
// builds is fed straight to the client's reader and must come back as the value it was
// built from.
//
// This is the only test target that links both ends, and that is the point. The producer
// lives in the host layer and the reader in the client module, so nothing else can catch
// the two drifting apart -- a renamed field would otherwise pass both sides' own tests
// and fail only on a real device.
import Foundation
import Testing
import DanTermClient
import DanTermProtocol
@testable import DanTermSupport

struct PaneTapeRoundTripTests {
    @Test("the start record round-trips its capture, format, geometry, and cursor")
    func startRecordRoundTrips() throws {
        let cursor = PaneTapeCursor(
            recorderLifetimeId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            nextSequence: 12,
            feedBytesBeforeNextSequence: 340,
            writeBytesBeforeNextSequence: 56
        )
        for capture in [PaneTapeCaptureMode.dump, .follow, .snapshot] {
            let start = makePaneTapeStart(
                capture: capture,
                provenance: .object(["pane": .string("p")]),
                initial: PaneTapeDimensions(columns: 120, rows: 40, pinned: true),
                cursor: cursor
            )

            guard case .start(let decoded)? = decodePaneTapeRecord(start.record) else {
                Issue.record("start record did not decode as a start")
                continue
            }
            #expect(decoded.version == paneTapeStreamVersion)
            #expect(decoded.capture == capture)
            #expect(decoded.format == .replay)
            #expect(decoded.columns == 120)
            #expect(decoded.rows == 40)
            #expect(decoded.pinned)
            #expect(decoded.cursor == cursor)
            #expect(decoded.reconstructible == false)
            #expect(decoded.nextSequence == cursor.nextSequence)
            #expect(decoded.feedByteOffset == cursor.feedBytesBeforeNextSequence)
            #expect(decoded.writeByteOffset == cursor.writeBytesBeforeNextSequence)
        }
    }

    @Test("the gap record round-trips every eviction count the producer states")
    func gapRecordRoundTrips() throws {
        let batch = makePaneTapeBatch(from: PaneTapeSnapshot(
            events: [],
            droppedEventCount: 7,
            droppedFeedBytes: 900,
            droppedWriteBytes: 11,
            nextCursor: .beginning
        ))
        let record = try #require(batch.records.first)

        #expect(decodePaneTapeRecord(record) == .gap(PaneTapeGapRecord(
            droppedEventCount: 7,
            droppedFeedBytes: 900,
            droppedWriteBytes: 11
        )))
    }

    @Test("an event round-trips with and without its origin stamp and its payload span")
    func eventRecordRoundTripsEveryOptionalField() throws {
        // Intent: the two optional halves of an event record survive in all four
        //   combinations, absent as absent rather than as zero.
        // Why it exists: the producer omits a key rather than writing a number, because a
        //   number there would read as a measurement of an event that had none. A reader
        //   that defaulted the missing key would report an origin the producer never
        //   claimed, and a byte span for an event carrying no bytes.
        // Scenario: a pane emits a resize (no bytes) and a burst of output (bytes with an
        //   origin earlier than their transfer).
        let spans: [PaneTapePayloadSpan?] = [nil, PaneTapePayloadSpan(byteOffset: 64, byteLength: 8)]
        let origins: [UInt64?] = [nil, 4_000]
        for span in spans {
            for origin in origins {
                let event = PaneTapeEvent(
                    sequence: 3,
                    elapsedNanoseconds: 9_000,
                    originElapsedNanoseconds: origin,
                    payload: span,
                    event: .object(["feed": .string("aGk=")]),
                    needsCompleteHistory: false
                )

                #expect(decodePaneTapeRecord(makePaneTapeEventRecord(event)) == .event(
                    PaneTapeEventRecord(
                        sequence: 3,
                        elapsedNanoseconds: 9_000,
                        originElapsedNanoseconds: origin,
                        byteOffset: span?.byteOffset,
                        byteLength: span?.byteLength,
                        event: .object(["feed": .string("aGk=")])
                    )
                ))
            }
        }
    }

    @Test("every end reason the producer can state round-trips as that reason")
    func endRecordRoundTripsEveryReason() {
        // Intent: no reason spelling is readable by the producer alone.
        // Why it exists: the reasons are raw strings on the wire, so a rename on one side
        //   is invisible until a reader silently reports "ended for no stated reason".
        for reason in [
            PaneTapeEndReason.dumpComplete, .snapshotComplete, .paneClosed, .streamFailed,
        ] {
            #expect(decodePaneTapeRecord(makePaneTapeEndRecord(reason: reason)) == .end(reason: reason))
        }
    }

    @Test("a whole finite dump decodes in order, gap first and terminator last")
    func dumpRecordsDecodeInOrder() throws {
        let dump = PaneTapeDump(
            start: makePaneTapeStart(
                capture: .dump,
                provenance: .null,
                initial: PaneTapeDimensions(columns: 80, rows: 24, pinned: false),
                cursor: .beginning
            ),
            snapshot: PaneTapeSnapshot(
                events: [
                    PaneTapeEvent(
                        sequence: 1,
                        elapsedNanoseconds: 10,
                        originElapsedNanoseconds: nil,
                        payload: nil,
                        event: .object(["resize": .object(["columns": .number(80)])]),
                        needsCompleteHistory: true
                    ),
                ],
                droppedEventCount: 2,
                droppedFeedBytes: 3,
                droppedWriteBytes: 4,
                nextCursor: .beginning
            )
        )

        let decoded = makePaneTapeDumpRecords(after: dump).map(decodePaneTapeRecord)

        #expect(decoded.count == 3)
        if case .gap? = decoded.first ?? nil {} else { Issue.record("a dump leads with its gap") }
        if case .event? = decoded[1] {} else { Issue.record("the event follows the gap") }
        #expect(decoded.last == .end(reason: .dumpComplete))
    }

    @Test("a state sync round-trips the pane's pinnedness with its grid")
    func syncRoundTripsPinnedness() {
        // Intent: the pinnedness the producer puts on a sync's first part is the pinnedness
        //   the reader's assembler publishes when the transfer completes.
        // Why it exists: a sync replaces a replica's state outright, so it is the only
        //   record that can restate geometry after a gap. Dropping the bit here would leave
        //   a repaired replica reporting the pane's claim wrongly until its next resize.
        // Scenario: a followed stream loses events on a claimed pane and is repaired.
        let evicted = PaneTapeSnapshot(
            events: [],
            droppedEventCount: 2,
            droppedFeedBytes: 3,
            droppedWriteBytes: 0,
            nextCursor: PaneTapeCursor(
                recorderLifetimeId: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                nextSequence: 9,
                feedBytesBeforeNextSequence: 3,
                writeBytesBeforeNextSequence: 0
            )
        )
        for pinned in [true, false] {
            let batch = repairedContinuation(
                snapshot: evicted,
                synchronization: .init(
                    bytes: Array("state".utf8),
                    dimensions: .init(columns: 62, rows: 19, pinned: pinned),
                    droppedHistoryRows: 0,
                    cursor: evicted.nextCursor
                )
            ).batch

            var assembler = PaneTapeSyncAssembler()
            var assembled: DanTermClient.PaneTapeStateSynchronization?
            for record in batch.records {
                guard case .sync(let part)? = decodePaneTapeRecord(record) else { continue }
                assembled = assembler.ingest(part) ?? assembled
            }

            #expect(assembled?.columns == 62)
            #expect(assembled?.rows == 19)
            #expect(assembled?.pinned == pinned)
        }
    }

    @Test("the served protocol number is the one the shipped client speaks")
    func servedProtocolNumberMatchesTheClient() {
        // Intent: the number the Mac announces at hello is exactly the number this
        //   client refuses every other value in favour of.
        // Why it exists: the two ends used to name the number independently -- a literal
        //   at the server's write site, a constant in the client -- so bumping one and
        //   forgetting the other would lock every peer out with no test failing.
        // Scenario: the pane-tape record shape changed, so the number had to move.
        #expect(
            IpcHello.params(
                protocolVersion: danTermIpcProtocolVersion,
                appVersion: "test",
                livenessBound: .standard
            )["protocol"] == .number(Double(DanTermClientSession.supportedProtocolVersion))
        )
    }

    // Intent: the count of history rows a sync left out survives the whole producer-to-reader
    //   path -- built in the Mac host layer, chunked across records, reassembled by the client.
    // Why it exists: the producer and the reader are the two ends this file exists to pair.
    //   The count is the replica's only evidence that its history is incomplete, and the bytes
    //   look identical either way, so a hop that dropped it would leave a truncated replica
    //   believing it holds everything the pane ever printed.
    // Scenario: a followed stream repairs a gap with a sync bounded well below the pane's
    //   retained history.
    @Test("a bounded sync round-trips its dropped history count to the reader")
    func syncRoundTripsDroppedHistoryRows() {
        let evicted = PaneTapeSnapshot(
            events: [],
            droppedEventCount: 2,
            droppedFeedBytes: 3,
            droppedWriteBytes: 0,
            nextCursor: PaneTapeCursor(
                recorderLifetimeId: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                nextSequence: 9,
                feedBytesBeforeNextSequence: 3,
                writeBytesBeforeNextSequence: 0
            )
        )
        // Long enough to chunk, so the count has to survive multi-part assembly.
        let bytes = [UInt8](repeating: 0x41, count: IpcLineFramer.maxLineBytes + 1)
        let batch = repairedContinuation(
            snapshot: evicted,
            synchronization: .init(
                bytes: bytes,
                dimensions: .init(columns: 62, rows: 19, pinned: false),
                droppedHistoryRows: 3141,
                cursor: evicted.nextCursor
            )
        ).batch

        var assembler = PaneTapeSyncAssembler()
        var assembled: DanTermClient.PaneTapeStateSynchronization?
        var parts = 0
        for record in batch.records {
            guard case .sync(let part)? = decodePaneTapeRecord(record) else { continue }
            parts += 1
            assembled = assembler.ingest(part) ?? assembled
        }

        #expect(parts > 1)
        #expect(assembled?.bytes == bytes)
        #expect(assembled?.droppedHistoryRows == 3141)
    }

    @Test("the tape stream version moved with the sync record's shape")
    func streamVersionStatesTheSyncShape() {
        // Intent: the version a start record publishes is the one whose sync records state
        //   how much history they left out.
        // Why it exists: readers key their expectations off this number. Leaving it at the
        //   value that named a sync with no such field would let a reader accept a stream
        //   whose shape it does not know, and the protocol number's refusal is the only other
        //   guard.
        // Scenario: a reader deciding whether it understands the stream it just opened.
        #expect(paneTapeStreamVersion == 5)
    }

    /// Builds the suffix a reconstructible stream ships when eviction forced it to replace
    /// events with state, taking the decide and materialize halves in one step so these
    /// reader-side tests stay about what reaches the wire.
    private func repairedContinuation(
        snapshot: PaneTapeSnapshot,
        synchronization: DanTermSupport.PaneTapeStateSynchronization
    ) -> PaneTapeContinuation {
        let decision = decidePaneTapeContinuation(
            policy: .reconstructible(historyBudgetBytes: 4096),
            replicaHistoryIsComplete: true,
            snapshot: snapshot
        )
        guard case .synchronize(let requirement) = decision else {
            Issue.record("an evicted reconstructible suffix must select a sync")
            return PaneTapeContinuation(
                batch: PaneTapeBatch(records: [], nextCursor: snapshot.nextCursor),
                replicaHistoryIsComplete: false
            )
        }
        return makePaneTapeContinuation(
            requirement: requirement,
            synchronization: synchronization
        )
    }
}
