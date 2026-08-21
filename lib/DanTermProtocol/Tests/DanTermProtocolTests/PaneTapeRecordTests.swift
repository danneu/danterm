// Coverage for the decode half of the pane-tape record shape. The producer lives in the Mac
// host layer, so the test that pairs the two ends is in the root package; this file covers
// what a reader must do on its own -- most of all, survive a record it predates.
import Foundation
import Testing
import DanTermProtocol

struct PaneTapeRecordTests {
    @Test("a state sync decodes its ordered part and completion cursor")
    func stateSyncDecodes() throws {
        let record = JSONValue.object([
            "kind": .string("sync"),
            "part": .number(2),
            "parts": .number(2),
            "base64": .string(Data("state".utf8).base64EncodedString()),
            "cursor": .object([
                "recorderLifetimeId": .string("11111111-1111-4111-8111-111111111111"),
                "sequence": .number(41),
                "feedByteOffset": .number(100),
                "writeByteOffset": .number(7),
            ]),
        ])

        guard case .sync(let sync)? = decodePaneTapeRecord(record) else {
            Issue.record("sync record did not decode")
            return
        }
        #expect(sync.part == 2)
        #expect(sync.parts == 2)
        #expect(sync.bytes == Data("state".utf8))
        #expect(sync.cursor?.nextSequence == 41)
    }

    // Intent: the count decodes off the wire beside the geometry, and a first part missing it
    //   is malformed rather than a transfer with an unstated count.
    // Why it exists: the reader cannot substitute a default here. Reading an absent count as
    //   zero is exactly the claim "this replica has the whole history", which is the one
    //   thing a bounded sync must never assert on its own.
    // Scenario: spec-first contract for the sync record's whole-transfer facts.
    @Test("a sync record decodes its dropped history count, or fails to decode without it")
    func syncRecordDecodesDroppedHistoryRows() {
        func record(_ extra: [String: JSONValue]) -> JSONValue {
            var object: [String: JSONValue] = [
                "kind": .string("sync"),
                "part": .number(1),
                "parts": .number(1),
                "base64": .string(Data("state".utf8).base64EncodedString()),
                "initial": .object([
                    "columns": .number(80),
                    "rows": .number(24),
                    "pinned": .bool(false),
                ]),
                "focused": .bool(false),
                "cursor": .object([
                    "recorderLifetimeId": .string("11111111-1111-4111-8111-111111111111"),
                    "sequence": .number(41),
                    "feedByteOffset": .number(100),
                    "writeByteOffset": .number(7),
                ]),
            ]
            object.merge(extra) { _, new in new }
            return .object(object)
        }

        guard case .sync(let sync)? = decodePaneTapeRecord(
            record(["droppedHistoryRows": .number(512)])
        ) else {
            Issue.record("sync record did not decode")
            return
        }
        #expect(sync.transfer?.droppedHistoryRows == 512)
        #expect(sync.transfer?.columns == 80)

        // Geometry without the count, and a fractional or negative count, are malformed.
        #expect(decodePaneTapeRecord(record([:])) == nil)
        #expect(decodePaneTapeRecord(record(["droppedHistoryRows": .number(1.5)])) == nil)
        #expect(decodePaneTapeRecord(record(["droppedHistoryRows": .number(-1)])) == nil)

        // So is the count without the geometry: the whole-transfer facts travel as one, and
        // a record stating half of them describes a transfer no reader can apply.
        var countOnly: [String: JSONValue] = [:]
        if case .object(let fields) = record(["droppedHistoryRows": .number(512)]) {
            countOnly = fields
        }
        countOnly.removeValue(forKey: "initial")
        #expect(decodePaneTapeRecord(.object(countOnly)) == nil)
    }

    // Intent: the effective focus a sync was captured with decodes beside the geometry and
    //   the history count, and a first part missing it is malformed.
    // Why it exists: focus is retained terminal state that the serialized bytes cannot
    //   restate. A reader that defaulted it would rebuild a replica whose answer to a later
    //   `DECSET 1004` names focus the pane never held.
    // Scenario: spec-first contract for the sync record's whole-transfer facts.
    @Test("a sync record decodes its effective focus, or fails to decode without it")
    func syncRecordDecodesFocus() {
        func record(_ extra: [String: JSONValue]) -> JSONValue {
            var object: [String: JSONValue] = [
                "kind": .string("sync"),
                "part": .number(1),
                "parts": .number(1),
                "base64": .string(Data("state".utf8).base64EncodedString()),
                "initial": .object([
                    "columns": .number(80),
                    "rows": .number(24),
                    "pinned": .bool(false),
                ]),
                "droppedHistoryRows": .number(0),
                "cursor": .object([
                    "recorderLifetimeId": .string("11111111-1111-4111-8111-111111111111"),
                    "sequence": .number(41),
                    "feedByteOffset": .number(100),
                    "writeByteOffset": .number(7),
                ]),
            ]
            object.merge(extra) { _, new in new }
            return .object(object)
        }

        guard case .sync(let sync)? = decodePaneTapeRecord(record(["focused": .bool(true)]))
        else {
            Issue.record("sync record did not decode")
            return
        }
        #expect(sync.transfer?.focused == true)

        guard case .sync(let unfocused)? = decodePaneTapeRecord(record(["focused": .bool(false)]))
        else {
            Issue.record("sync record did not decode")
            return
        }
        #expect(unfocused.transfer?.focused == false)

        // The whole-transfer facts travel as one, so a record stating the rest without focus
        // is malformed rather than a transfer whose focus a reader may choose.
        #expect(decodePaneTapeRecord(record([:])) == nil)
        #expect(decodePaneTapeRecord(record(["focused": .number(1)])) == nil)
    }

    @Test("a record kind this build does not know decodes as unknown, not as a failure")
    func unknownKindSurvives() throws {
        // Intent: an unfamiliar kind is reported as unfamiliar and the reader keeps going.
        // Why it exists: the producer will gain record kinds -- a resume fence is already
        //   planned -- and every one of them would be a breaking change if a reader that
        //   predates it could not tell "I do not handle this" from "this stream is broken".
        // Scenario: a client built today reads a stream from a newer DanTerm.
        let record = JSONValue.object([
            "kind": .string("future"),
            "sequence": .number(41),
            "someFieldFromTheFuture": .bool(true),
        ])

        #expect(decodePaneTapeRecord(record) == .unknown(kind: "future"))
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
        // Why it exists: tolerating a future kind must not also tolerate a corrupt one.
        #expect(decodePaneTapeRecord(.object(["kind": .string("event")])) == nil)
        #expect(decodePaneTapeRecord(.object([
            "kind": .string("start"),
            "capture": .string("snapshot"),
            "format": .string("replay"),
        ])) == nil)
    }

    @Test("numeric record coordinates must be whole and inside their decoded domains")
    func malformedNumericCoordinatesFail() {
        #expect(decodePaneTapeRecord(.object([
            "kind": .string("start"),
            "version": .number(3),
            "capture": .string("snapshot"),
            "format": .string("replay"),
            "reconstructible": .bool(true),
            "initial": .object([
                "columns": .number(80.5),
                "rows": .number(24),
                "pinned": .bool(false),
            ]),
        ])) == nil)
        #expect(decodePaneTapeRecord(.object([
            "kind": .string("gap"),
            "droppedEventCount": .number(-1),
            "droppedFeedBytes": .number(0),
            "droppedWriteBytes": .number(0),
        ])) == nil)
        #expect(decodePaneTapeRecord(.object([
            "kind": .string("event"),
            "sequence": .number(1.5),
            "elapsedNanoseconds": .number(2),
            "event": .object([:]),
        ])) == nil)
    }

    @Test("a reconstructible start may withhold its cursor until sync completion")
    func synchronizedStartWithholdsCursor() throws {
        let record = JSONValue.object([
            "kind": .string("start"),
            "version": .number(3),
            "capture": .string("snapshot"),
            "format": .string("replay"),
            "reconstructible": .bool(true),
            "initial": .object([
                "columns": .number(80),
                "rows": .number(24),
                "pinned": .bool(false),
            ]),
        ])

        guard case .start(let start)? = decodePaneTapeRecord(record) else {
            Issue.record("start record did not decode")
            return
        }
        #expect(start.cursor == nil)
        #expect(start.reconstructible)
    }

    @Test("a total gap stays distinct from exact loss")
    func totalGapDecodes() {
        #expect(decodePaneTapeRecord(.object([
            "kind": .string("gap"),
            "loss": .string("total"),
        ])) == .gap(.total))
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
            "initial": .object([
                "columns": .number(80),
                "rows": .number(24),
                "pinned": .bool(false),
            ]),
            "cursor": .object([
                "sequence": .number(0),
                "feedByteOffset": .number(0),
                "writeByteOffset": .number(0),
            ]),
        ])) == nil)
    }
}
