// Differential tests for the one decode the phone now performs on a tape event: the
// JSONValue bridge against the encode-to-Data-then-JSONDecoder round trip it replaced.
//
// Every fixture is decoded both ways and the answers must agree, on the value and on
// refusal alike. The corpus is deliberately two halves: every spelling the recorder emits,
// and the malformed shapes -- key-shape and primitive-conversion both -- that the event's
// own decoder refuses. The bridge lives in DanTermProtocol and knows nothing about events,
// so this suite is where the two meet.
import DanTermMobileKit
import DanTermProtocol
import Foundation
import Testing
import TerminalCore
import TerminalCoreRecording

@Suite
struct TapeEventBridgeTests {
    @Test("Every event spelling the recorder emits decodes to the same event both ways")
    func bothPathsAgreeOnEveryRecorderEvent() throws {
        for event in recorderEvents {
            let tree = try encodedTree(event)
            #expect(try JSONValueDecoder().decode(
                NeutralTerminalRecordingEvent.self,
                from: tree
            ) == event)
            expectAgreement(tree)
        }
    }

    @Test("A byte payload spelled as text decodes the same way through both paths")
    func bothPathsAgreeOnTheTextByteEncoding() {
        // The producer writes base64, but the decoder accepts either spelling, so the
        // bridge has to reach the same bytes from the one the producer does not write.
        for type in ["feed", "write"] {
            expectAgreement(.object([
                "type": .string(type),
                "text": .string("hi"),
            ]))
        }
    }

    @Test("Both paths refuse the same malformed event key shapes")
    func bothPathsRefuseTheSameKeyShapes() {
        for tree in malformedKeyShapes {
            expectAgreement(tree)
        }
    }

    @Test("Both paths agree at every primitive conversion the event decoder reaches")
    func bothPathsAgreeAtPrimitiveConversions() {
        for tree in primitiveConversionCases {
            expectAgreement(tree)
        }
    }

    @Test("Both paths agree on the modifiers array, empty, populated, and ill-typed")
    func bothPathsAgreeOnTheModifiersContainer() {
        for modifiers in [
            JSONValue.array([]),
            .array([.string("shift"), .string("control")]),
            .array([.number(1)]),
            .array([.string("hyper")]),
            .string("shift"),
            .null,
        ] {
            expectAgreement(.object([
                "type": .string("input"),
                "key": .string("return"),
                "modifiers": modifiers,
            ]))
            expectAgreement(.object([
                "type": .string("mouse"),
                "action": .string("move"),
                "column": .number(3),
                "row": .number(4),
                "modifiers": modifiers,
            ]))
        }
    }
}

/// Every spelling the recorder puts on the tape, so the valid half of the corpus is the
/// producer's own vocabulary rather than a paraphrase of it.
private let recorderEvents: [NeutralTerminalRecordingEvent] = [
    .feed(Array("hello\u{1b}[31m".utf8)),
    .feed([]),
    .write(Array("ls\r".utf8)),
    .input(key: .returnKey, modifiers: []),
    .input(key: .character("a"), modifiers: [.control, .shift]),
    .input(key: .f12, modifiers: [.command, .alt]),
    .paste("two\nlines"),
    .focus(true),
    .focus(false),
    .mouse(NeutralTerminalMouseEvent(
        action: .down,
        button: 1,
        column: 4,
        row: 9,
        offsetX: 0.25,
        modifiers: [.shift],
        clickCount: 2
    )),
    .mouse(NeutralTerminalMouseEvent(
        action: .up,
        button: 7,
        column: 0,
        row: 0,
        offsetX: 0,
        modifiers: [],
        clickCount: 1
    )),
    .mouse(NeutralTerminalMouseEvent(
        action: .move,
        button: nil,
        column: 12,
        row: 3,
        offsetX: 0,
        modifiers: [],
        clickCount: 1
    )),
    .resize(columns: 80, rows: 24, pinned: false),
    .resize(columns: 40, rows: 60, pinned: true),
    .viewport(.byRows(-3)),
    .viewport(.toTopRow(120)),
    .viewport(.toBottom),
    .checkpoint,
]

/// The key shapes the event decoder refuses: an unrecognized kind, a required key that is
/// absent, a key it does not know, and every way the two byte encodings can be wrong.
private let malformedKeyShapes: [JSONValue] = [
    .object(["type": .string("teleport")]),
    .object(["type": .string("feed")]),
    .object(["type": .string("feed"), "base64": .string("aGk="), "text": .string("hi")]),
    .object(["type": .string("feed"), "base64": .string("not base64 at all!")]),
    .object(["type": .string("feed"), "base64": .string("aGk="), "colour": .string("red")]),
    .object(["type": .string("resize"), "columns": .number(80)]),
    .object(["type": .string("resize"), "rows": .number(24)]),
    .object(["type": .string("input")]),
    .object(["type": .string("input"), "key": .string("character")]),
    .object(["type": .string("input"), "key": .string("hyperspace")]),
    .object(["type": .string("paste")]),
    .object(["type": .string("focus")]),
    .object(["type": .string("mouse"), "action": .string("action"), "column": .number(1)]),
    .object([
        "type": .string("mouse"),
        "action": .string("move"),
        "button": .number(1),
        "column": .number(1),
        "row": .number(1),
    ]),
    .object([
        "type": .string("mouse"),
        "action": .string("down"),
        "button": .number(9),
        "column": .number(1),
        "row": .number(1),
    ]),
    .object(["type": .string("viewport"), "action": .string("sideways")]),
    .object(["type": .string("viewport"), "action": .string("byRows")]),
    .string("feed"),
    .array([]),
    .null,
]

/// One case per conversion the event decoder performs, at the boundary where it can fail:
/// a whole type given a fraction, a negative, or a number past its range, a scalar of the
/// wrong kind, and null against a required key and an optional one alike.
private let primitiveConversionCases: [JSONValue] = [
    // Int, from a fraction, a negative, and beyond the type's range.
    .object(["type": .string("resize"), "columns": .number(80.5), "rows": .number(24)]),
    .object(["type": .string("resize"), "columns": .number(-80), "rows": .number(24)]),
    .object(["type": .string("resize"), "columns": .number(1e30), "rows": .number(24)]),
    .object(["type": .string("viewport"), "action": .string("byRows"), "rows": .number(0.5)]),
    // UInt64, whose lower bound differs from Int's, at the inert timing stamps.
    .object([
        "type": .string("feed"),
        "base64": .string("aGk="),
        "elapsedNanoseconds": .number(-1),
    ]),
    .object([
        "type": .string("feed"),
        "base64": .string("aGk="),
        "elapsedNanoseconds": .number(1.5),
    ]),
    .object([
        "type": .string("feed"),
        "base64": .string("aGk="),
        "elapsedNanoseconds": .number(1e30),
    ]),
    .object([
        "type": .string("write"),
        "base64": .string("aGk="),
        "originElapsedNanoseconds": .number(-1),
    ]),
    // A scalar where another kind belongs, in both directions.
    .object(["type": .number(1)]),
    .object(["type": .string("resize"), "columns": .string("80"), "rows": .number(24)]),
    .object([
        "type": .string("resize"),
        "columns": .number(80),
        "rows": .number(24),
        "pinned": .string("true"),
    ]),
    .object(["type": .string("focus"), "focused": .number(1)]),
    .object(["type": .string("paste"), "text": .bool(true)]),
    .object(["type": .string("feed"), "base64": .array([.number(104)])]),
    .object(["type": .string("mouse"),
             "action": .string("move"),
             "column": .number(1),
             "row": .number(1),
             "offsetX": .string("0")]),
    // Null against a required key, and against a key read with decodeIfPresent -- the two
    // must not collapse into the same answer unless they already do.
    .object(["type": .null]),
    .object(["type": .string("focus"), "focused": .null]),
    .object(["type": .string("resize"),
             "columns": .number(80),
             "rows": .number(24),
             "pinned": .null]),
    .object(["type": .string("feed"),
             "base64": .string("aGk="),
             "elapsedNanoseconds": .null]),
    .object(["type": .string("mouse"),
             "action": .string("down"),
             "button": .null,
             "column": .number(1),
             "row": .number(1)]),
]

/// The JSON tree the producer's encode puts on the wire for one event.
private func encodedTree(_ event: NeutralTerminalRecordingEvent) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(event))
}

/// Asserts the bridge and the round trip it replaced give the same answer for one tree,
/// whether that answer is an event or a refusal.
private func expectAgreement(
    _ tree: JSONValue,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let bridged = Result {
        try JSONValueDecoder().decode(NeutralTerminalRecordingEvent.self, from: tree)
    }
    let roundTripped = Result {
        try JSONDecoder().decode(
            NeutralTerminalRecordingEvent.self,
            from: JSONEncoder().encode(tree)
        )
    }
    switch (bridged, roundTripped) {
    case (.success(let left), .success(let right)):
        #expect(left == right, "\(tree)", sourceLocation: sourceLocation)
    case (.failure, .failure):
        break
    case (.success, .failure):
        Issue.record("Bridge accepted an event the round trip refused: \(tree)",
                     sourceLocation: sourceLocation)
    case (.failure(let error), .success):
        Issue.record("Bridge refused an event the round trip accepted: \(tree) -- \(error)",
                     sourceLocation: sourceLocation)
    }
}
