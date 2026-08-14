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
                initial: PaneTapeDimensions(columns: 120, rows: 40),
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
                    event: .object(["feed": .string("aGk=")])
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
                initial: PaneTapeDimensions(columns: 80, rows: 24),
                cursor: .beginning
            ),
            snapshot: PaneTapeSnapshot(
                events: [
                    PaneTapeEvent(
                        sequence: 1,
                        elapsedNanoseconds: 10,
                        originElapsedNanoseconds: nil,
                        payload: nil,
                        event: .object(["resize": .object(["columns": .number(80)])])
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
}
