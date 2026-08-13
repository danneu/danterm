// The readable view derived from one replay tape record. Payload bytes become ordered spans;
// everything else about the record is left exactly as the producer stated it. This does not
// interpret terminal sequences: a CSI or OSC reads here as its ESC control span followed by
// its literal text, and giving those sequences meaning is a parser-level job, not this one.
import Foundation

/// Rewrites one replay record as its inspect equivalent, or returns it unchanged when it
/// carries no payload to derive from.
///
/// The transform is per record on purpose. A derived view that needed the whole recording in
/// memory would give back exactly what the line-oriented stream was built to avoid.
public func paneTapeInspectRecord(_ record: JSONValue) throws -> JSONValue {
    guard var fields = record.asObject else { return record }
    switch record["kind"] {
    case .string("start"):
        // Only the format field moves. Everything else a start record states -- its version,
        // its capture, its provenance, its geometry, its cursor baseline -- describes the
        // recording itself and is as true of this view as of the bytes it came from.
        fields["format"] = .string(PaneTapeFormat.inspect.rawValue)
        return .object(fields)
    case .string("event"):
        guard var event = record["event"]?.asObject,
              let encoded = event["base64"]?.asString
        else { return record }
        guard let payload = Data(base64Encoded: encoded) else {
            throw PaneTapeInspectError.malformedPayload
        }
        event["base64"] = nil
        event["spans"] = .array(paneTapeInspectSpans(Array(payload)))
        fields["event"] = .object(event)
        return .object(fields)
    default:
        return record
    }
}

/// Reports a replay record this view cannot be derived from.
public enum PaneTapeInspectError: Error, LocalizedError {
    case malformedPayload

    public var errorDescription: String? {
        switch self {
        case .malformedPayload: return "pane tape record carried a malformed payload"
        }
    }
}

/// Splits one payload into ordered spans that account for every byte exactly once.
///
/// Three span kinds, each under its own key so the view stays unambiguous: `text` holds a run
/// of printable characters, `control` names one C0 byte or DEL, and `hex` holds a run of bytes
/// that decode as nothing. The keys are what make literal text safe -- the four characters
/// `ESC` typed into a shell are `{"text":"ESC"}` and the escape byte is `{"control":"ESC"}`,
/// so no reader has to guess which one a payload held.
///
/// Bytes are classified within the one event that recorded them. A character split across two
/// recorded transfers stays split, and each half appears as hex in its own event, because that
/// is what the pane actually did -- joining the halves would report a transfer that never
/// happened.
public func paneTapeInspectSpans(_ bytes: [UInt8]) -> [JSONValue] {
    var spans: [JSONValue] = []
    var text = ""
    var hex: [String] = []

    func flushText() {
        guard text.isEmpty == false else { return }
        spans.append(.object(["text": .string(text)]))
        text = ""
    }
    func flushHex() {
        guard hex.isEmpty == false else { return }
        spans.append(.object(["hex": .string(hex.joined(separator: " "))]))
        hex = []
    }

    var index = bytes.startIndex
    while index < bytes.endIndex {
        let byte = bytes[index]
        if let name = paneTapeControlName(byte) {
            flushText()
            flushHex()
            spans.append(.object(["control": .string(name)]))
            index += 1
            continue
        }
        if let decoded = paneTapeDecodeScalar(bytes, at: index) {
            flushHex()
            text.unicodeScalars.append(decoded.scalar)
            index += decoded.length
            continue
        }
        flushText()
        hex.append(String(format: "%02x", byte))
        index += 1
    }
    flushText()
    flushHex()
    return spans
}

/// Names the one byte a control span stands for, or nil when the byte is not one.
///
/// C0 and DEL never join a text span even though they are valid UTF-8. A run of printable
/// characters is what a reader scans; a control byte hidden inside one as an invisible
/// character would be exactly the thing they opened the tape to find.
func paneTapeControlName(_ byte: UInt8) -> String? {
    if byte == 0x7F { return "DEL" }
    guard byte < 0x20 else { return nil }
    return c0ControlNames[Int(byte)]
}

/// Decodes the one UTF-8 scalar starting at `index`, or nil when no whole valid scalar does.
///
/// The decoding is written out rather than handed to a string decoder because a decoder is
/// free to normalize what it reads, and this view may not: Foundation's, for one, swallows a
/// byte-order mark, which would drop three real payload bytes and leave the spans no longer
/// accounting for every byte. Here a lead byte states its own sequence length, and only the
/// whole sequence proves it is one -- overlong forms, surrogates, and values past U+10FFFF all
/// start off plausible. A sequence that runs past the end of this event was truncated by the
/// recording rather than malformed, and its bytes are reported as the bytes they are.
private func paneTapeDecodeScalar(
    _ bytes: [UInt8],
    at index: Int
) -> (scalar: Unicode.Scalar, length: Int)? {
    let lead = bytes[index]
    let length: Int
    var value: UInt32
    switch lead {
    case 0x00...0x7F: return (Unicode.Scalar(lead), 1)
    case 0xC2...0xDF: length = 2; value = UInt32(lead & 0x1F)
    case 0xE0...0xEF: length = 3; value = UInt32(lead & 0x0F)
    case 0xF0...0xF4: length = 4; value = UInt32(lead & 0x07)
    default: return nil
    }
    guard index + length <= bytes.endIndex else { return nil }
    for continuation in bytes[(index + 1)..<(index + length)] {
        guard (0x80...0xBF).contains(continuation) else { return nil }
        value = (value << 6) | UInt32(continuation & 0x3F)
    }
    // Every code point has exactly one encoding, so a shorter form for this value means the
    // producer wrote a sequence no decoder should accept.
    let minimum: UInt32 = length == 2 ? 0x80 : (length == 3 ? 0x800 : 0x1_0000)
    guard value >= minimum, let scalar = Unicode.Scalar(value) else { return nil }
    return (scalar, length)
}

private let c0ControlNames = [
    "NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL",
    "BS", "HT", "LF", "VT", "FF", "CR", "SO", "SI",
    "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB",
    "CAN", "EM", "SUB", "ESC", "FS", "GS", "RS", "US",
]
