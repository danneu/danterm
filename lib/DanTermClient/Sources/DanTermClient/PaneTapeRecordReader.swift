// The reader counterpart to the producer's record construction.
//
// The pane-tape record shape had a producer and no reader, so every consumer spelled
// "kind", "sequence", and "byteOffset" out for itself. This file is the one place that
// knows those spellings on the reading side. The vocabulary they belong to -- version,
// format, capture mode, end reasons -- stays in DanTermProtocol, shared with the producer.
import Foundation
import DanTermProtocol

/// One record off the tape stream.
///
/// `unknown` is load-bearing rather than defensive: a producer may gain a record kind, and
/// a client built before that kind must be able to say "I read a record I do not handle"
/// and keep going. Collapsing it into a decode failure would make every future record kind
/// a breaking change.
public enum PaneTapeRecord: Equatable, Sendable {
    case start(PaneTapeStartRecord)
    case gap(PaneTapeGapRecord)
    case event(PaneTapeEventRecord)
    /// A clean end, carrying the producer's reason when this build knows the spelling.
    case end(reason: PaneTapeEndReason?)
    case unknown(kind: String)
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

    public init(
        version: Int,
        capture: PaneTapeCaptureMode,
        format: PaneTapeFormat,
        columns: Int,
        rows: Int,
        nextSequence: UInt64,
        feedByteOffset: Int,
        writeByteOffset: Int
    ) {
        self.version = version
        self.capture = capture
        self.format = format
        self.columns = columns
        self.rows = rows
        self.nextSequence = nextSequence
        self.feedByteOffset = feedByteOffset
        self.writeByteOffset = writeByteOffset
    }
}

/// What the producer evicted before this point, stated so a client can report the
/// discontinuity rather than render across it silently.
public struct PaneTapeGapRecord: Equatable, Sendable {
    public let droppedEventCount: UInt64
    public let droppedFeedBytes: Int
    public let droppedWriteBytes: Int

    public init(droppedEventCount: UInt64, droppedFeedBytes: Int, droppedWriteBytes: Int) {
        self.droppedEventCount = droppedEventCount
        self.droppedFeedBytes = droppedFeedBytes
        self.droppedWriteBytes = droppedWriteBytes
    }
}

/// One tape event, with its timing and byte position hoisted out of the event object the
/// same way the producer hoists them.
public struct PaneTapeEventRecord: Equatable, Sendable {
    public let sequence: UInt64
    public let elapsedNanoseconds: UInt64
    public let originElapsedNanoseconds: UInt64?
    public let byteOffset: Int?
    public let byteLength: Int?
    /// The recording event itself, left as JSON so this module does not depend on the
    /// terminal engine. A client that links the recording types decodes it further.
    public let event: JSONValue

    public init(
        sequence: UInt64,
        elapsedNanoseconds: UInt64,
        originElapsedNanoseconds: UInt64?,
        byteOffset: Int?,
        byteLength: Int?,
        event: JSONValue
    ) {
        self.sequence = sequence
        self.elapsedNanoseconds = elapsedNanoseconds
        self.originElapsedNanoseconds = originElapsedNanoseconds
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.event = event
    }
}

/// Decodes one tape record, or returns nil when the value is not a record at all or a
/// record whose own required fields are missing.
///
/// A record kind this build does not know is not a failure: it decodes to `.unknown`.
public func decodePaneTapeRecord(_ value: JSONValue) -> PaneTapeRecord? {
    guard let kind = value["kind"]?.asString else { return nil }
    switch kind {
    case "start":
        // An unknown capture mode is malformed rather than unknown-but-fine. The two
        // captures differ in whether EOF is a legitimate ending, so a reader that guessed
        // would apply the permissive rule to a stream that never claimed it.
        guard let capture = value["capture"]?.asString
                .flatMap(PaneTapeCaptureMode.init(rawValue:)),
              let format = value["format"]?.asString.flatMap(PaneTapeFormat.init(rawValue:)),
              let initial = value["initial"],
              let cursor = value["cursor"],
              let columns = initial["columns"]?.asNumber,
              let rows = initial["rows"]?.asNumber,
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
        guard let dropped = value["droppedEventCount"]?.asNumber,
              let feed = value["droppedFeedBytes"]?.asNumber,
              let write = value["droppedWriteBytes"]?.asNumber
        else { return nil }
        return .gap(PaneTapeGapRecord(
            droppedEventCount: UInt64(dropped),
            droppedFeedBytes: Int(feed),
            droppedWriteBytes: Int(write)
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
        return .end(reason: value["reason"]?.asString.flatMap(PaneTapeEndReason.init(rawValue:)))
    default:
        return .unknown(kind: kind)
    }
}

/// One `pane.tape.event` notification: which subscription it belongs to, and the record it
/// carries in the exact bytes the producer sent.
///
/// The record stays a `JSONValue` beside its decoded form because a consumer that replays
/// a capture must forward what arrived, not a re-encoding of what this build understood.
public struct PaneTapeStreamNotification: Equatable, Sendable {
    public let subscriptionId: String
    public let record: JSONValue

    /// Returns nil when the notification is not a tape event, so a client can hold one
    /// conversation carrying more than one kind of notification.
    public init?(method: String, params: JSONValue?) {
        guard method == Methods.paneTapeEvent,
              let subscription = params?["subscription"]?.asString,
              let record = params?["record"]
        else { return nil }
        self.subscriptionId = subscription
        self.record = record
    }
}
