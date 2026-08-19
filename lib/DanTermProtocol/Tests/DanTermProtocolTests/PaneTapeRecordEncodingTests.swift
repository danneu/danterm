// Coverage for the encode half of the pane-tape record shape: what a producer writes must be
// what a reader reads. Every case here goes out through the real wire encoder and comes back
// through `decodePaneTapeRecord`, because those two are the only declarations of the shape and
// nothing else would notice them drifting apart.
//
// The decode half's own rules -- a record kind this build predates, a malformed field -- live
// in PaneTapeRecordTests.swift.
import Foundation
import Testing
import DanTermProtocol

struct PaneTapeRecordEncodingTests {
    // Intent: every record kind a producer can write, in every combination of the fields it
    //   may withhold, decodes back as the record it was built from.
    // Why it exists: the record shape has one encode and one decode, and they are written by
    //   hand against the same key declarations. A key spelled on one side alone, or an
    //   optional field written where the reader expects it hoisted, compiles clean on both
    //   sides and fails only mid-stream.
    // Scenario: spec-first contract for the pane-tape wire.
    @Test("every record kind encodes to the wire and decodes back as itself")
    func everyRecordKindRoundTrips() throws {
        for (outgoing, expected) in roundTripCases {
            #expect(try decodedFromWire(outgoing) == expected)
        }
    }

    // Intent: a field the producer did not measure is absent from the JSON rather than null.
    // Why it exists: a reader treats a present key as a measurement, so a null origin stamp or
    //   byte span would report a measurement of something that had none -- and the reader
    //   refuses a non-numeric value there, so the whole record would become malformed.
    // Scenario: an event the recorder retained without bytes, such as a resize.
    @Test("an event record omits the facts the recorder did not measure")
    func eventRecordOmitsUnmeasuredFacts() throws {
        let record = PaneTapeOutgoingRecord.event(PaneTapeEventRecord(
            sequence: 4,
            elapsedNanoseconds: 9,
            originElapsedNanoseconds: nil,
            byteOffset: nil,
            byteLength: nil,
            event: JSONValue.object(["kind": .string("resize")])
        ))

        let fields = try #require(try encodedFields(record))
        #expect(fields[PaneTapeRecordKey.originElapsedNanoseconds] == nil)
        #expect(fields[PaneTapeRecordKey.byteOffset] == nil)
        #expect(fields[PaneTapeRecordKey.byteLength] == nil)
    }

    // Intent: the `event` value is exactly what the event type's own encoder writes.
    // Why it exists: the record shape carries the producer's event vocabulary through without
    //   restating it. A hand-built event object here would be a second spelling of that
    //   vocabulary, free to drift from the type that defines it.
    // Scenario: spec-first contract for the event payload, standing in for the engine's
    //   recording event, which this module cannot name.
    @Test("the event object is the event value's own encoding")
    func eventObjectIsTheEventsOwnEncoding() throws {
        let event = EventPayloadProbe(kind: "feed", base64: "8J+Ygg==")
        let record = PaneTapeOutgoingRecord.event(PaneTapeEventRecord(
            sequence: 1,
            elapsedNanoseconds: 2,
            originElapsedNanoseconds: 3,
            byteOffset: 4,
            byteLength: 5,
            event: event
        ))

        let fields = try #require(try encodedFields(record))
        let alone = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(event))
        #expect(fields[PaneTapeRecordKey.event] == alone)
    }

    // Intent: the record's `Encodable` conformance writes the same object the JSONValue
    //   builder does.
    // Why it exists: the producer still builds records as JSON trees while it is moved over to
    //   the typed record, so for now the shape has two writers. This pin holds the wire steady
    //   across that move; it goes away with the builder it compares against.
    // Scenario: spec-first, guarding the producer's migration to typed records.
    @Test("the typed encode writes what the JSONValue builder writes")
    func typedEncodeMatchesTheJSONValueBuilder() throws {
        for (outgoing, _) in roundTripCases {
            #expect(try encodedValue(outgoing) == encodePaneTapeRecord(outgoing))
        }
    }
}

/// The records the wire must carry, each beside the record a reader must get back. They are
/// declared once because the round trip and the builder-equivalence pin must not disagree
/// about which shapes count.
private let roundTripCases: [(PaneTapeOutgoingRecord<JSONValue>, PaneTapeRecord<JSONValue>)] = {
    let cursor = PaneTapeCursor(
        recorderLifetimeId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        nextSequence: 12,
        feedBytesBeforeNextSequence: 340,
        writeBytesBeforeNextSequence: 56
    )
    let provenance = JSONValue.object(["pane": .string("p7")])
    func start(cursor: PaneTapeCursor?, provenance: JSONValue?) -> PaneTapeStartRecord {
        PaneTapeStartRecord(
            version: 3,
            capture: cursor == nil ? .snapshot : .follow,
            format: .replay,
            provenance: provenance,
            columns: 120,
            rows: 40,
            pinned: true,
            cursor: cursor,
            reconstructible: cursor == nil
        )
    }
    let event = PaneTapeEventRecord(
        sequence: 7,
        elapsedNanoseconds: 8,
        originElapsedNanoseconds: 9,
        byteOffset: 10,
        byteLength: 11,
        event: JSONValue.object(["kind": .string("feed"), "base64": .string("8J+Ygg==")])
    )
    let bareEvent = PaneTapeEventRecord(
        sequence: 12,
        elapsedNanoseconds: 13,
        originElapsedNanoseconds: nil,
        byteOffset: nil,
        byteLength: nil,
        event: JSONValue.object(["kind": .string("resize")])
    )
    let firstPart = PaneTapeSyncRecord(
        part: 1,
        parts: 2,
        bytes: Array("state".utf8),
        transfer: PaneTapeSyncRecord.Transfer(
            columns: 80,
            rows: 24,
            pinned: false,
            droppedHistoryRows: 512
        ),
        cursor: nil
    )
    let lastPart = PaneTapeSyncRecord(
        part: 2,
        parts: 2,
        bytes: [],
        transfer: nil,
        cursor: cursor
    )
    let gap = PaneTapeGapRecord(
        droppedEventCount: 7,
        droppedFeedBytes: 900,
        droppedWriteBytes: 11
    )
    let ends: [PaneTapeEndReason] = [
        .dumpComplete, .snapshotComplete, .paneClosed, .streamFailed,
    ]
    return [
        (.start(start(cursor: cursor, provenance: provenance)),
         .start(start(cursor: cursor, provenance: provenance))),
        (.start(start(cursor: nil, provenance: nil)),
         .start(start(cursor: nil, provenance: nil))),
        (.gap(gap), .gap(gap)),
        (.gap(.total), .gap(.total)),
        (.event(event), .event(event)),
        (.event(bareEvent), .event(bareEvent)),
        (.sync(firstPart), .sync(firstPart)),
        (.sync(lastPart), .sync(lastPart)),
    ] + ends.map { (.end(reason: $0), .end(reason: $0)) }
}()

/// Puts one record through the real wire encoder and the reader's decode, which is the only
/// path that proves the two halves of the shape agree.
private func decodedFromWire<Event: Encodable>(
    _ record: PaneTapeOutgoingRecord<Event>
) throws -> PaneTapeRecord<JSONValue>? {
    decodePaneTapeRecord(try encodedValue(record))
}

private func encodedValue<Event: Encodable>(
    _ record: PaneTapeOutgoingRecord<Event>
) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try encodeIpcLine(record))
}

private func encodedFields<Event: Encodable>(
    _ record: PaneTapeOutgoingRecord<Event>
) throws -> [String: JSONValue]? {
    try encodedValue(record).asObject
}

/// Stands in for the producer's own recording event, whose vocabulary this module cannot name.
private struct EventPayloadProbe: Encodable {
    let kind: String
    let base64: String
}
