// Coverage for the reading side of the pane-tape record shape. The producer lives in the
// Mac host layer, so the test that pairs the two ends is in the root package; this file
// covers what a reader must do on its own -- most of all, survive a record it predates.
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermClient

struct PaneTapeRecordReaderTests {
    @Test("a record kind this build does not know decodes as unknown, not as a failure")
    func unknownKindSurvives() throws {
        // Intent: an unfamiliar kind is reported as unfamiliar and the reader keeps going.
        // Why it exists: the producer will gain record kinds -- a resume fence is already
        //   planned -- and every one of them would be a breaking change if a reader that
        //   predates it could not tell "I do not handle this" from "this stream is broken".
        // Scenario: a client built today reads a stream from a newer DanTerm.
        let record = JSONValue.object([
            "kind": .string("sync"),
            "sequence": .number(41),
            "someFieldFromTheFuture": .bool(true),
        ])

        #expect(decodePaneTapeRecord(record) == .unknown(kind: "sync"))
    }

    @Test("an end reason this build does not know still reads as an end")
    func unknownEndReasonStillEnds() throws {
        // Intent: the terminator is recognised even when its stated reason is not.
        // Why it exists: a reader that failed here would turn a clean end into a
        //   truncated capture the moment a new reason was added.
        // Scenario: a producer states a reason spelled after this client shipped.
        let record = JSONValue.object([
            "kind": .string("end"),
            "reason": .string("resumed-elsewhere"),
        ])

        #expect(decodePaneTapeRecord(record) == .end(reason: nil))
    }

    @Test("a value with no kind is not a record")
    func kindlessValueIsNotARecord() {
        #expect(decodePaneTapeRecord(.object(["sequence": .number(0)])) == nil)
        #expect(decodePaneTapeRecord(.string("start")) == nil)
    }

    @Test("a known kind missing its own required fields fails to decode")
    func malformedKnownKindFails() {
        // Intent: "unknown kind" and "known kind, broken record" stay apart.
        // Why it exists: tolerating a future kind must not also tolerate a corrupt one --
        //   a start record with no cursor gives a reader no origin for later offsets.
        #expect(decodePaneTapeRecord(.object(["kind": .string("event")])) == nil)
        #expect(decodePaneTapeRecord(.object([
            "kind": .string("start"),
            "capture": .string("snapshot"),
            "format": .string("replay"),
        ])) == nil)
    }

    @Test("a capture mode this build does not know is malformed rather than tolerated")
    func unknownCaptureModeIsMalformed() {
        // Intent: an unfamiliar capture is refused even though an unfamiliar record kind
        //   is not.
        // Why it exists: the two captures differ in whether EOF is a legitimate ending. A
        //   reader that guessed would apply the permissive rule to a stream that never
        //   claimed it, and report a truncated capture as whole.
        #expect(decodePaneTapeRecord(.object([
            "kind": .string("start"),
            "version": .number(2),
            "capture": .string("mirror"),
            "format": .string("replay"),
            "initial": .object(["columns": .number(80), "rows": .number(24)]),
            "cursor": .object([
                "sequence": .number(0),
                "feedByteOffset": .number(0),
                "writeByteOffset": .number(0),
            ]),
        ])) == nil)
    }

    @Test("a tape notification is recognised by method and carries its record verbatim")
    func notificationCarriesItsRecord() throws {
        let record = JSONValue.object(["kind": .string("end"), "reason": .string("pane-closed")])
        let carried = try #require(PaneTapeStreamNotification(
            method: Methods.paneTapeEvent,
            params: .object(["subscription": .string("s7"), "record": record])
        ))

        #expect(carried.subscriptionId == "s7")
        #expect(carried.record == record)
        #expect(PaneTapeStreamNotification(method: "pane.other", params: .object([:])) == nil)
    }
}
