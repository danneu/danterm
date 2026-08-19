// Coverage for the envelope a `pane.tape.event` notification carries: that the producer's
// encode and the reader's recognition are the same declaration, that an unknown record rides
// it untouched, and that a notification which is not this shape yields nothing at all.
//
// The record inside the envelope has its own coverage in PaneTapeRecordEncodingTests.swift and
// PaneTapeRecordTests.swift; nothing here asserts a record key.
import Foundation
import Testing
import DanTermProtocol

struct PaneTapeEventNotificationTests {
    // Intent: what the producer writes is exactly what the reader recognises.
    // Why it exists: the two keys of this envelope used to be spelled once on each side, so a
    //   drift on a key name, on nesting, or on optionality compiled clean on both sides and
    //   showed up only as a stream that silently stopped producing records.
    // Scenario: spec-first contract for the pane-tape notification envelope.
    @Test("a written notification is recognised, and carries its records verbatim")
    func writtenNotificationIsRecognised() throws {
        let outgoing = PaneTapeEventNotification(
            subscription: "s7",
            records: [PaneTapeOutgoingRecord<JSONValue>.end(reason: .paneClosed)]
        )
        let params = try parsed(outgoing)

        let carried = try #require(PaneTapeEventNotification<JSONValue>(
            method: Methods.paneTapeEvent,
            params: params
        ))

        #expect(carried.subscription == "s7")
        #expect(carried.records == params["records"]?.asArray)
        #expect(carried.records.map(decodePaneTapeRecord) == [.end(reason: .paneClosed)])
    }

    // Intent: a batch of records travels in one notification, in the order it was written.
    // Why it exists: the wire unit is the delivered batch, so an envelope that reordered or
    //   dropped part of it would hand a replica a stream that never happened -- and the
    //   defect would be invisible until a busy pane delivered more than one record at once.
    // Scenario: spec-first contract for a batch carrying a gap and two events.
    @Test("a batch of records rides one notification in order")
    func batchOfRecordsRidesOneNotification() throws {
        let records: [PaneTapeOutgoingRecord<JSONValue>] = [
            .gap(PaneTapeGapRecord(
                droppedEventCount: 3,
                droppedFeedBytes: 4,
                droppedWriteBytes: 5
            )),
            .event(eventRecord(sequence: 8)),
            .event(eventRecord(sequence: 9)),
        ]
        let params = try parsed(
            PaneTapeEventNotification(subscription: "s2", records: records)
        )

        let carried = try #require(PaneTapeEventNotification<JSONValue>(
            method: Methods.paneTapeEvent,
            params: params
        ))

        #expect(carried.subscription == "s2")
        #expect(carried.records.map { $0["kind"]?.asString } == ["gap", "event", "event"])
        #expect(carried.records.compactMap { $0["sequence"]?.asNumber } == [8, 9])
    }

    // Intent: a record kind this build does not know reaches the consumer unchanged.
    // Why it exists: the reader forwards what arrived rather than a re-encoding of what it
    //   understood, so a producer may gain a record kind without breaking an older reader.
    // Scenario: spec-first; the envelope must not decode the record it carries.
    @Test("a record of an unknown kind survives the envelope unchanged")
    func unknownRecordSurvives() throws {
        let record = JSONValue.object([
            "kind": .string("teleport"),
            "destination": .object(["deck": .number(7)]),
        ])

        let carried = try #require(PaneTapeEventNotification<JSONValue>(
            method: Methods.paneTapeEvent,
            params: .object(["subscription": .string("s1"), "records": .array([record])])
        ))

        #expect(carried.records == [record])
        #expect(carried.records.map(decodePaneTapeRecord) == [.unknown(kind: "teleport")])
    }

    // Intent: pulling the carried tree out of the params is value-identity.
    // Why it exists: the envelope decodes its record out of an already-parsed tree, so every
    //   node kind -- a null, a fractional number, an empty container -- must come back equal
    //   rather than merely similar.
    // Scenario: spec-first; the premise the whole shared declaration rests on.
    @Test("every node kind in a carried tree comes back equal")
    func carriedTreeIsValueIdentical() throws {
        let record = JSONValue.object([
            "null": .null,
            "fraction": .number(0.5),
            "negative": .number(-17.25),
            "flag": .bool(false),
            "text": .string(""),
            "emptyArray": .array([]),
            "emptyObject": .object([:]),
            "nested": .array([
                .object(["deep": .array([.null, .number(1), .string("x")])]),
            ]),
        ])

        let carried = try #require(PaneTapeEventNotification<JSONValue>(
            method: Methods.paneTapeEvent,
            params: .object(["subscription": .string("s1"), "records": .array([record])])
        ))

        #expect(carried.records == [record])
    }

    // Intent: anything that is not this envelope yields no value at all.
    // Why it exists: there is no partial notification. A reader holding half of one would
    //   route records to no subscription, or forward records that were never there.
    // Scenario: spec-first; one case per way the shape can fail to match.
    @Test("a notification that is not this envelope is refused outright")
    func mismatchedNotificationIsRefused() {
        let record = JSONValue.object(["kind": .string("end")])
        let records = JSONValue.array([record])
        let rejected: [(String, String, JSONValue?)] = [
            ("wrong method", "roster.event", .object([
                "subscription": .string("s1"), "records": records,
            ])),
            ("absent params", Methods.paneTapeEvent, nil),
            ("params are not an object", Methods.paneTapeEvent, .array([])),
            ("subscription missing", Methods.paneTapeEvent, .object(["records": records])),
            ("subscription is not a string", Methods.paneTapeEvent, .object([
                "subscription": .number(1), "records": records,
            ])),
            ("records missing", Methods.paneTapeEvent, .object(["subscription": .string("s1")])),
            ("records are not a list", Methods.paneTapeEvent, .object([
                "subscription": .string("s1"), "records": record,
            ])),
        ]

        for (label, method, params) in rejected {
            #expect(
                PaneTapeEventNotification<JSONValue>(method: method, params: params) == nil,
                "\(label) must yield no notification"
            )
        }
    }

    /// One event record whose only interesting fact is which sequence it states.
    private func eventRecord(sequence: UInt64) -> PaneTapeEventRecord<JSONValue> {
        PaneTapeEventRecord(
            sequence: sequence,
            elapsedNanoseconds: sequence,
            originElapsedNanoseconds: nil,
            byteOffset: nil,
            byteLength: nil,
            event: .object(["type": .string("feed")])
        )
    }

    /// Puts a notification through a real JSON encode so the test reads what the wire carries,
    /// not what the same declaration would hand back in memory.
    private func parsed<Record: Encodable>(
        _ notification: PaneTapeEventNotification<Record>
    ) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(notification))
    }
}
