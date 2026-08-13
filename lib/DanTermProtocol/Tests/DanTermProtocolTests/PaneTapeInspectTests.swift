// Tests for the readable view derived from a replay tape record: how payload bytes become
// spans, and what the derived record keeps from the record it came from.
import Foundation
import Testing
@testable import DanTermProtocol

struct PaneTapeInspectTests {
    @Test("a run of printable ASCII becomes one text span")
    func printableASCIIBecomesOneTextSpan() {
        #expect(paneTapeInspectSpans(Array("hello world".utf8)) == [
            .object(["text": .string("hello world")]),
        ])
    }

    @Test("multibyte scalars stay inside text spans")
    func multibyteScalarsStayInsideTextSpans() {
        // Intent: two-, three-, and four-byte UTF-8 sequences read as the characters they
        //   encode, in the same run as the ASCII around them.
        // Why it exists: a view that reported these as hex would make ordinary output --
        //   accented words, CJK text, an emoji in a prompt -- unreadable, which is the one
        //   thing this format exists to prevent.
        #expect(paneTapeInspectSpans(Array("aé漢😀b".utf8)) == [
            .object(["text": .string("aé漢😀b")]),
        ])
    }

    @Test("literal control labels stay text and never become controls")
    func literalControlLabelsStayText() {
        // Intent: the characters `ESC` and `^[` typed as text produce text spans, and a real
        //   escape byte beside them produces a control span; the two differ by their key.
        // Why it exists: this is the unambiguity claim of the whole format. If a reader had to
        //   tell a control from text by the span's value, a shell that printed the word ESC --
        //   a keybinding table, a help screen -- would read as an escape byte the pane never
        //   carried.
        // Scenario: a pane prints `ESC` and `^[` as help text and then sends a real escape.
        let spans = paneTapeInspectSpans(Array("ESC".utf8) + [0x1B] + Array("^[".utf8))

        #expect(spans == [
            .object(["text": .string("ESC")]),
            .object(["control": .string("ESC")]),
            .object(["text": .string("^[")]),
        ])
        // The literal text and the escape byte carry the same value, so only the key separates
        // them.
        #expect(spans[0]["text"] == spans[1]["control"])
        #expect(spans[0]["control"] == nil)
        #expect(spans[1]["text"] == nil)
    }

    @Test("every C0 byte and DEL gets its own standard name")
    func everyC0ByteAndDELGetsItsOwnStandardName() {
        // Intent: all 32 C0 bytes and DEL each map to their standard spelling, and no two share
        //   a name.
        // Why it exists: a reader identifies a control only by its name, so a missing or
        //   duplicated one makes two different bytes indistinguishable in the output.
        let expected = [
            "NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL",
            "BS", "HT", "LF", "VT", "FF", "CR", "SO", "SI",
            "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB",
            "CAN", "EM", "SUB", "ESC", "FS", "GS", "RS", "US",
        ]
        for (byte, name) in expected.enumerated() {
            #expect(paneTapeControlName(UInt8(byte)) == name)
            #expect(paneTapeInspectSpans([UInt8(byte)]) == [.object(["control": .string(name)])])
        }
        #expect(paneTapeControlName(0x7F) == "DEL")
        #expect(paneTapeInspectSpans([0x7F]) == [.object(["control": .string("DEL")])])
        #expect(Set(expected + ["DEL"]).count == 33)

        // The bytes just outside the two control ranges are printable text, not controls.
        #expect(paneTapeControlName(0x20) == nil)
        #expect(paneTapeControlName(0x7E) == nil)
    }

    @Test("undecodable bytes coalesce into one lowercase hex span")
    func undecodableBytesCoalesceIntoOneHexSpan() {
        // Intent: a lone continuation byte, an unassignable lead byte, an overlong encoding, a
        //   surrogate encoding, and a value past U+10FFFF all report as hex, and a consecutive
        //   run of them is one span.
        // Why it exists: every one of these starts off plausible -- an overlong or surrogate
        //   form has a lead byte that states a length -- so a view that trusted the lead byte
        //   would print characters the pane never carried.
        let payload = Array("a".utf8)
            + [0x80, 0xFF, 0xC0, 0x80, 0xED, 0xA0, 0x80, 0xF5, 0x80, 0x80, 0x80]
            + Array("b".utf8)

        #expect(paneTapeInspectSpans(payload) == [
            .object(["text": .string("a")]),
            .object(["hex": .string("80 ff c0 80 ed a0 80 f5 80 80 80")]),
            .object(["text": .string("b")]),
        ])
    }

    @Test("an empty payload has no spans")
    func anEmptyPayloadHasNoSpans() {
        #expect(paneTapeInspectSpans([]) == [])
        #expect(eventObject(inspect(eventRecord(base64: "")))["spans"] == JSONValue.array([]))
    }

    @Test("a scalar split across two events stays split")
    func aScalarSplitAcrossTwoEventsStaysSplit() {
        // Intent: the leading bytes of a multibyte scalar in one event and its trailing byte in
        //   the next each report as hex, in their own event.
        // Why it exists: the tape states what each transfer carried. Joining the halves would
        //   report a character arriving in a transfer that carried only part of it, and would
        //   hide the split read that is often the bug under investigation.
        // Scenario: a euro sign arrives in two PTY reads, `e2 82` then `ac`.
        #expect(paneTapeInspectSpans([0xE2, 0x82]) == [.object(["hex": .string("e2 82")])])
        #expect(paneTapeInspectSpans([0xAC]) == [.object(["hex": .string("ac")])])
    }

    @Test(
        "the spans reconstruct every payload byte exactly",
        arguments: [
            (0...255).map { UInt8($0) },
            // A byte-order mark, which a string decoder is entitled to swallow. It is a real
            // scalar in a terminal stream -- a BOM-prefixed file printed to the pane -- and
            // dropping it would leave the spans reporting fewer bytes than the event carried.
            Array("\u{FEFF}".utf8),
            Array("a\u{FEFF}b".utf8),
            // Every span kind at once, with the invalid bytes bracketed by text so a run that
            // swallowed its neighbors would show up as a shifted reconstruction.
            Array("aé漢😀".utf8) + [0x00, 0x1B, 0x7F, 0x80, 0xFF] + Array("\u{FEFF}z".utf8),
            [0xE4, 0xB8],
            [],
        ]
    )
    func spansReconstructEveryPayloadByte(payload: [UInt8]) throws {
        // Intent: mapping each span back to the bytes it stands for, and concatenating them in
        //   order, returns the payload unchanged.
        // Why it exists: a reader counts bytes off this view against the `byteLength` the
        //   record states. A byte dropped, duplicated, reordered, or rewritten would make the
        //   view disagree with the record carrying it, and no reader could tell which one was
        //   wrong. Summing span lengths is not enough: a loss with a matching gain sums right.
        // Scenario: a pane emits text, controls, and bytes that decode as nothing.
        let spans = paneTapeInspectSpans(payload)

        var reconstructed: [UInt8] = []
        for span in spans {
            let fields = try #require(span.asObject)
            #expect(fields.count == 1)
            if let text = fields["text"]?.asString {
                reconstructed += Array(text.utf8)
            } else if let name = fields["control"]?.asString {
                reconstructed.append(try #require(controlByte(named: name)))
            } else {
                let hex = try #require(fields["hex"]?.asString)
                for pair in hex.split(separator: " ") {
                    #expect(pair.count == 2)
                    #expect(pair.allSatisfy { $0.isHexDigit && !$0.isUppercase })
                    reconstructed.append(try #require(UInt8(pair, radix: 16)))
                }
            }
        }
        #expect(reconstructed == payload)
    }

    @Test("terminal sequences are reported as bytes, not interpreted")
    func terminalSequencesAreReportedAsBytes() {
        // Intent: a CSI sequence reads as its escape control span followed by its literal text.
        // Why it exists: giving sequences meaning is a parser's job. A view that named this
        //   sequence would have to name every sequence, and would report its own parser's
        //   opinion where the reader asked what bytes arrived.
        #expect(paneTapeInspectSpans([0x1B] + Array("[31m".utf8)) == [
            .object(["control": .string("ESC")]),
            .object(["text": .string("[31m")]),
        ])
    }

    @Test("a start record changes only its format")
    func aStartRecordChangesOnlyItsFormat() {
        // Intent: the derived start record states the inspect format and repeats every other
        //   field byte for byte.
        // Why it exists: version, capture, provenance, geometry, and the cursor baseline
        //   describe the recording itself, and are as true of this view as of the bytes it came
        //   from. A reader that lost the cursor could not resolve any later byte offset.
        let start = startRecord()
        let derived = inspect(start)

        #expect(derived["format"] == .string("inspect"))
        #expect(withoutKey("format", of: derived) == withoutKey("format", of: start))
    }

    @Test("an event record swaps base64 for spans and keeps every other field")
    func anEventRecordSwapsBase64ForSpansAndKeepsEveryOtherField() {
        // Intent: only the payload representation changes. Every sibling of the payload, inside
        //   the event object and outside it, survives untouched.
        // Why it exists: an agent reads this view to locate an event in the recording it came
        //   from -- by sequence, by timing, by byte offset. Dropping one of those fields would
        //   leave a readable payload nobody could place.
        let replay = eventRecord(base64: Data("hi\u{1B}".utf8).base64EncodedString())
        let derived = inspect(replay)

        #expect(eventObject(derived)["spans"] == JSONValue.array([
            .object(["text": .string("hi")]),
            .object(["control": .string("ESC")]),
        ]))
        #expect(eventObject(derived)["base64"] == nil)
        // Everything outside the event object, compared whole so a dropped field fails.
        #expect(withoutKey("event", of: derived) == withoutKey("event", of: replay))
        // And everything beside the payload inside it.
        #expect(
            withoutKey("spans", of: derived["event"]!)
                == withoutKey("base64", of: replay["event"]!)
        )
    }

    @Test("a write event is transformed like a feed event")
    func aWriteEventIsTransformedLikeAFeedEvent() {
        // Intent: direction does not change how a payload is derived, and the direction itself
        //   survives the transform.
        // Why it exists: input the pane sent toward the child is exactly what an agent reads
        //   the tape to check, so a view that only derived feed payloads would answer half the
        //   question.
        let replay = eventRecord(
            type: "write",
            base64: Data("ls\r".utf8).base64EncodedString()
        )
        let derived = inspect(replay)

        #expect(eventObject(derived)["type"] == JSONValue.string("write"))
        #expect(eventObject(derived)["spans"] == JSONValue.array([
            .object(["text": .string("ls")]),
            .object(["control": .string("CR")]),
        ]))
        #expect(derived["originElapsedNanoseconds"] == replay["originElapsedNanoseconds"])
        #expect(withoutKey("event", of: derived) == withoutKey("event", of: replay))
    }

    @Test("gap and end records pass through unchanged")
    func gapAndEndRecordsPassThroughUnchanged() {
        let gap = JSONValue.object([
            "kind": .string("gap"),
            "droppedEventCount": .number(3),
            "droppedFeedBytes": .number(120),
            "droppedWriteBytes": .number(4),
        ])
        let end = JSONValue.object([
            "kind": .string("end"),
            "reason": .string("snapshot-complete"),
        ])

        #expect(inspect(gap) == gap)
        #expect(inspect(end) == end)
    }

    @Test("a malformed payload is rejected")
    func aMalformedPayloadIsRejected() {
        // Intent: a record whose payload cannot be decoded stops the derivation instead of
        //   producing a record with no payload in it.
        // Why it exists: an event silently rendered without its bytes would read as an event
        //   that carried none, and the reader would draw a conclusion from a hole.
        #expect(throws: PaneTapeInspectError.self) {
            _ = try paneTapeInspectRecord(eventRecord(base64: "not base64!!"))
        }
    }

    // MARK: - Helpers

    private func inspect(_ record: JSONValue) -> JSONValue {
        (try? paneTapeInspectRecord(record)) ?? .null
    }

    private func eventObject(_ record: JSONValue) -> [String: JSONValue] {
        record["event"]?.asObject ?? [:]
    }

    private func withoutKey(_ key: String, of record: JSONValue) -> JSONValue {
        var fields = record.asObject ?? [:]
        fields[key] = nil
        return .object(fields)
    }

    /// Resolves a control span's name back to the one byte it stands for, by searching the
    /// bytes a control span can name rather than restating the production name table.
    private func controlByte(named name: String) -> UInt8? {
        (Array(UInt8(0)...UInt8(0x1F)) + [0x7F]).first { paneTapeControlName($0) == name }
    }

    private func startRecord() -> JSONValue {
        .object([
            "kind": .string("start"),
            "version": .number(2),
            "capture": .string("snapshot"),
            "format": .string("replay"),
            "provenance": .object([
                "source": .string("live-capture"),
                "terminal": .string("DanTerm"),
            ]),
            "initial": .object(["columns": .number(80), "rows": .number(24)]),
            "cursor": .object([
                "sequence": .number(7),
                "feedByteOffset": .number(4096),
                "writeByteOffset": .number(12),
            ]),
        ])
    }

    private func eventRecord(type: String = "feed", base64: String) -> JSONValue {
        .object([
            "kind": .string("event"),
            "sequence": .number(9),
            "elapsedNanoseconds": .number(1_500),
            "originElapsedNanoseconds": .number(1_200),
            "byteOffset": .number(64),
            "byteLength": .number(3),
            "event": .object([
                "type": .string(type),
                "base64": .string(base64),
            ]),
        ])
    }
}
