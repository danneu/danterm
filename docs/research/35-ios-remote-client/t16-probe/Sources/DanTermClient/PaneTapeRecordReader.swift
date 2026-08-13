// The reader counterpart to the producer's record construction: one decode of the
// pane-tape record shape, so a client never re-derives "kind"/"sequence"/"byteOffset"
// from string literals of its own. Today three readers do exactly that.
import Foundation
import DanTermProtocol

/// One record off the tape stream, in the three shapes a producer can emit.
public enum PaneTapeRecord: Equatable, Sendable {
    case start(PaneTapeStartRecord)
    case gap(PaneTapeGapRecord)
    case event(PaneTapeEventRecord)
    case end(PaneTapeEndReason?)
}

/// The stream's opening record: what it carries, and the cursor later offsets read against.
public struct PaneTapeStartRecord: Equatable, Sendable {
    public let version: Int
    public let capture: PaneTapeCaptureMode
    public let format: PaneTapeFormat
    public let columns: Int
    public let rows: Int
    public let nextSequence: UInt64
    public let feedByteOffset: Int
    public let writeByteOffset: Int
}

/// What the producer evicted before this point, stated so a client can say so rather
/// than silently rendering a discontinuity.
public struct PaneTapeGapRecord: Equatable, Sendable {
    public let droppedEventCount: UInt64
    public let droppedFeedBytes: Int
    public let droppedWriteBytes: Int
}

/// One tape event with its timing and byte position hoisted out, matching the producer.
public struct PaneTapeEventRecord: Equatable, Sendable {
    public let sequence: UInt64
    public let elapsedNanoseconds: UInt64
    public let originElapsedNanoseconds: UInt64?
    public let byteOffset: Int?
    public let byteLength: Int?
    /// The neutral recording event itself, left as JSON so this module does not depend
    /// on the terminal engine; a client that links TerminalCoreRecording decodes it.
    public let event: JSONValue
}

/// Decodes one record, returning nil for a shape this version does not know rather than
/// throwing, so an older client survives a producer that gained a record kind.
public func decodePaneTapeRecord(_ value: JSONValue) -> PaneTapeRecord? {
    guard let kind = value["kind"]?.asString else { return nil }
    switch kind {
    case "start":
        guard let capture = value["capture"]?.asString.flatMap(PaneTapeCaptureMode.init(rawValue:)),
              let format = value["format"]?.asString.flatMap(PaneTapeFormat.init(rawValue:)),
              let initial = value["initial"], let cursor = value["cursor"],
              let columns = initial["columns"]?.asNumber, let rows = initial["rows"]?.asNumber,
              let sequence = cursor["sequence"]?.asNumber,
              let feed = cursor["feedByteOffset"]?.asNumber,
              let write = cursor["writeByteOffset"]?.asNumber
        else { return nil }
        return .start(PaneTapeStartRecord(
            version: Int(value["version"]?.asNumber ?? 0),
            capture: capture,
            format: format,
            columns: Int(columns),
            rows: Int(rows),
            nextSequence: UInt64(sequence),
            feedByteOffset: Int(feed),
            writeByteOffset: Int(write)
        ))
    case "gap":
        return .gap(PaneTapeGapRecord(
            droppedEventCount: UInt64(value["droppedEventCount"]?.asNumber ?? 0),
            droppedFeedBytes: Int(value["droppedFeedBytes"]?.asNumber ?? 0),
            droppedWriteBytes: Int(value["droppedWriteBytes"]?.asNumber ?? 0)
        ))
    case "event":
        guard let sequence = value["sequence"]?.asNumber,
              let elapsed = value["elapsedNanoseconds"]?.asNumber,
              let event = value["event"]
        else { return nil }
        return .event(PaneTapeEventRecord(
            sequence: UInt64(sequence),
            elapsedNanoseconds: UInt64(elapsed),
            originElapsedNanoseconds: value["originElapsedNanoseconds"]?.asNumber.map(UInt64.init),
            byteOffset: value["byteOffset"]?.asNumber.map(Int.init),
            byteLength: value["byteLength"]?.asNumber.map(Int.init),
            event: event
        ))
    case "end":
        return .end(value["reason"]?.asString.flatMap(PaneTapeEndReason.init(rawValue:)))
    default:
        return nil
    }
}
