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
    /// Declares the stream contract and its initial cursor or pending synchronization.
    case start(PaneTapeStartRecord)
    /// Reports recorder evidence that is unavailable before the following records.
    case gap(PaneTapeGapRecord)
    /// Carries one retained recorder event.
    case event(PaneTapeEventRecord)
    /// Carries one ordered part of exact terminal state.
    case sync(PaneTapeSyncRecord)
    /// A clean end, carrying the producer's reason when this build knows the spelling.
    case end(reason: PaneTapeEndReason?)
    case unknown(kind: String)
}

/// The stream's opening record: what it carries, and the cursor later offsets read against.
public struct PaneTapeStartRecord: Equatable, Sendable {
    /// Identifies the pane-tape wire contract.
    public let version: Int
    /// States whether the stream is a finite dump, a follow, or an exact snapshot.
    public let capture: PaneTapeCaptureMode
    /// States whether event bytes are replayable or rendered for inspection.
    public let format: PaneTapeFormat
    /// Gives the initial terminal width.
    public let columns: Int
    /// Gives the initial terminal height.
    public let rows: Int
    /// Continues the stream when no opening synchronization is pending.
    public let cursor: PaneTapeCursor?
    /// States whether the producer may synthesize exact terminal state after loss.
    public let reconstructible: Bool

    /// Preserves the former sequence convenience while allowing a pending synchronization.
    public var nextSequence: UInt64? { cursor?.nextSequence }
    /// Preserves the former feed-offset convenience while allowing a pending synchronization.
    public var feedByteOffset: Int? { cursor?.feedBytesBeforeNextSequence }
    /// Preserves the former write-offset convenience while allowing a pending synchronization.
    public var writeByteOffset: Int? { cursor?.writeBytesBeforeNextSequence }

    /// Creates the decoded opening contract for one tape stream.
    public init(
        version: Int,
        capture: PaneTapeCaptureMode,
        format: PaneTapeFormat,
        columns: Int,
        rows: Int,
        cursor: PaneTapeCursor?,
        reconstructible: Bool
    ) {
        self.version = version
        self.capture = capture
        self.format = format
        self.columns = columns
        self.rows = rows
        self.cursor = cursor
        self.reconstructible = reconstructible
    }
}

/// What the producer evicted before this point, stated so a client can report the
/// discontinuity rather than render across it silently.
public struct PaneTapeGapRecord: Equatable, Sendable {
    /// Separates measurable eviction in one recorder from an unrelated recorder lifetime.
    public enum Loss: Equatable, Sendable {
        /// The producer cannot measure what preceded the replacement state.
        case total
        /// The producer measured the unavailable event and byte counts exactly.
        case exact(droppedEventCount: UInt64, droppedFeedBytes: Int, droppedWriteBytes: Int)
    }

    /// Carries either exact loss counts or a total-loss marker.
    public let loss: Loss
    /// Returns the exact missing event count when the producer could measure it.
    public var droppedEventCount: UInt64? {
        guard case .exact(let count, _, _) = loss else { return nil }
        return count
    }
    /// Returns the exact missing feed-byte count when the producer could measure it.
    public var droppedFeedBytes: Int? {
        guard case .exact(_, let count, _) = loss else { return nil }
        return count
    }
    /// Returns the exact missing write-byte count when the producer could measure it.
    public var droppedWriteBytes: Int? {
        guard case .exact(_, _, let count) = loss else { return nil }
        return count
    }

    /// Represents loss whose size cannot be compared across recorder lifetimes.
    public static let total = Self(loss: .total)

    private init(loss: Loss) {
        self.loss = loss
    }

    /// Creates an exact loss report from one recorder lifetime.
    public init(droppedEventCount: UInt64, droppedFeedBytes: Int, droppedWriteBytes: Int) {
        loss = .exact(
            droppedEventCount: droppedEventCount,
            droppedFeedBytes: droppedFeedBytes,
            droppedWriteBytes: droppedWriteBytes
        )
    }
}

/// One ordered part of an atomic terminal-state synchronization transfer.
public struct PaneTapeSyncRecord: Equatable, Sendable {
    /// Gives this part's one-based position.
    public let part: Int
    /// Gives the complete transfer's part count.
    public let parts: Int
    /// Carries this part's terminal-state bytes.
    public let bytes: [UInt8]
    /// Gives the terminal width on the first part only.
    public let columns: Int?
    /// Gives the terminal height on the first part only.
    public let rows: Int?
    /// Publishes the continuation position on the final part only.
    public let cursor: PaneTapeCursor?

    /// Creates one decoded part for ordered assembly.
    public init(
        part: Int,
        parts: Int,
        bytes: [UInt8],
        columns: Int?,
        rows: Int?,
        cursor: PaneTapeCursor?
    ) {
        self.part = part
        self.parts = parts
        self.bytes = bytes
        self.columns = columns
        self.rows = rows
        self.cursor = cursor
    }
}

/// The complete state transfer a reader may apply atomically at its continuation cursor.
public struct PaneTapeStateSynchronization: Equatable, Sendable {
    /// Carries the complete terminal-state byte stream.
    public let bytes: [UInt8]
    /// Gives the width at which the state must be applied.
    public let columns: Int
    /// Gives the height at which the state must be applied.
    public let rows: Int
    /// Names the first recorder event after this state.
    public let cursor: PaneTapeCursor

    /// Creates one complete state replacement.
    public init(bytes: [UInt8], columns: Int, rows: Int, cursor: PaneTapeCursor) {
        self.bytes = bytes
        self.columns = columns
        self.rows = rows
        self.cursor = cursor
    }
}

/// Buffers one synchronization transfer and publishes state only when every part is complete.
public struct PaneTapeSyncAssembler: Sendable {
    private var expectedPart = 1
    private var expectedCount: Int?
    private var bytes: [UInt8] = []
    private var columns: Int?
    private var rows: Int?

    /// Starts an assembler with no partial transfer.
    public init() {}

    /// Accepts the next ordered part, returning exact state only for the completing part.
    public mutating func ingest(_ record: PaneTapeSyncRecord) -> PaneTapeStateSynchronization? {
        guard record.part == expectedPart,
              expectedCount == nil || expectedCount == record.parts
        else {
            reset()
            return nil
        }
        if record.part == 1 {
            guard let columns = record.columns, let rows = record.rows else {
                reset()
                return nil
            }
            expectedCount = record.parts
            self.columns = columns
            self.rows = rows
        } else if record.columns != nil || record.rows != nil {
            reset()
            return nil
        }
        bytes.append(contentsOf: record.bytes)
        expectedPart += 1
        guard record.part == record.parts else {
            if record.cursor != nil { reset() }
            return nil
        }
        guard let cursor = record.cursor,
              let columns,
              let rows
        else {
            reset()
            return nil
        }
        let synchronization = PaneTapeStateSynchronization(
            bytes: bytes,
            columns: columns,
            rows: rows,
            cursor: cursor
        )
        reset()
        return synchronization
    }

    private mutating func reset() {
        expectedPart = 1
        expectedCount = nil
        bytes.removeAll(keepingCapacity: true)
        columns = nil
        rows = nil
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
        guard let versionValue = value["version"]?.asNumber,
              let version = nonnegativeInt(versionValue),
              let capture = value["capture"]?.asString
                .flatMap(PaneTapeCaptureMode.init(rawValue:)),
              let format = value["format"]?.asString.flatMap(PaneTapeFormat.init(rawValue:)),
              let initial = value["initial"],
              let columnsValue = initial["columns"]?.asNumber,
              let rowsValue = initial["rows"]?.asNumber,
              let columns = positiveInt(columnsValue),
              let rows = positiveInt(rowsValue),
              case .bool(let reconstructible)? = value["reconstructible"]
        else { return nil }
        let cursor: PaneTapeCursor?
        if let cursorValue = value["cursor"] {
            guard let decoded = decodePaneTapeCursor(cursorValue) else { return nil }
            cursor = decoded
        } else {
            cursor = nil
        }
        return .start(PaneTapeStartRecord(
            version: version,
            capture: capture,
            format: format,
            columns: columns,
            rows: rows,
            cursor: cursor,
            reconstructible: reconstructible
        ))
    case "gap":
        if let rawLoss = value["loss"]?.asString {
            guard rawLoss == "total" else { return nil }
            return .gap(.total)
        }
        guard let droppedValue = value["droppedEventCount"]?.asNumber,
              let feedValue = value["droppedFeedBytes"]?.asNumber,
              let writeValue = value["droppedWriteBytes"]?.asNumber,
              let dropped = wholeUInt64(droppedValue),
              let feed = nonnegativeInt(feedValue),
              let write = nonnegativeInt(writeValue)
        else { return nil }
        return .gap(PaneTapeGapRecord(
            droppedEventCount: dropped,
            droppedFeedBytes: feed,
            droppedWriteBytes: write
        ))
    case "event":
        guard let sequenceValue = value["sequence"]?.asNumber,
              let elapsedValue = value["elapsedNanoseconds"]?.asNumber,
              let sequence = wholeUInt64(sequenceValue),
              let elapsed = wholeUInt64(elapsedValue),
              let event = value["event"]
        else { return nil }
        let origin = optionalUInt64(value["originElapsedNanoseconds"])
        let byteOffset = optionalNonnegativeInt(value["byteOffset"])
        let byteLength = optionalNonnegativeInt(value["byteLength"])
        guard origin.isValid, byteOffset.isValid, byteLength.isValid else { return nil }
        return .event(PaneTapeEventRecord(
            sequence: sequence,
            elapsedNanoseconds: elapsed,
            originElapsedNanoseconds: origin.value,
            byteOffset: byteOffset.value,
            byteLength: byteLength.value,
            event: event
        ))
    case "sync":
        guard let partValue = value["part"]?.asNumber,
              let partsValue = value["parts"]?.asNumber,
              let part = positiveInt(partValue),
              let parts = positiveInt(partsValue),
              let payload = value["base64"]?.asString,
              let data = Data(base64Encoded: payload)
        else { return nil }
        guard parts >= part else { return nil }
        let initial = value["initial"]
        let columns = initial?["columns"]?.asNumber.flatMap(positiveInt)
        let rows = initial?["rows"]?.asNumber.flatMap(positiveInt)
        guard (columns == nil) == (rows == nil) else { return nil }
        let cursor: PaneTapeCursor?
        if let cursorValue = value["cursor"] {
            guard let decoded = decodePaneTapeCursor(cursorValue) else { return nil }
            cursor = decoded
        } else {
            cursor = nil
        }
        return .sync(PaneTapeSyncRecord(
            part: part,
            parts: parts,
            bytes: Array(data),
            columns: columns,
            rows: rows,
            cursor: cursor
        ))
    case "end":
        return .end(reason: value["reason"]?.asString.flatMap(PaneTapeEndReason.init(rawValue:)))
    default:
        return .unknown(kind: kind)
    }
}

private func positiveInt(_ number: Double) -> Int? {
    guard number.isFinite,
          number.rounded(.towardZero) == number,
          number > 0,
          number < 9_223_372_036_854_775_808.0
    else { return nil }
    return Int(number)
}

private func nonnegativeInt(_ number: Double) -> Int? {
    guard number.isFinite,
          number.rounded(.towardZero) == number,
          number >= 0,
          number < 9_223_372_036_854_775_808.0
    else { return nil }
    return Int(number)
}

private func wholeUInt64(_ number: Double) -> UInt64? {
    guard number.isFinite,
          number.rounded(.towardZero) == number,
          number >= 0,
          number < 18_446_744_073_709_551_616.0
    else { return nil }
    return UInt64(number)
}

private func optionalUInt64(_ value: JSONValue?) -> (isValid: Bool, value: UInt64?) {
    guard let value else { return (true, nil) }
    guard let number = value.asNumber, let decoded = wholeUInt64(number) else {
        return (false, nil)
    }
    return (true, decoded)
}

private func optionalNonnegativeInt(_ value: JSONValue?) -> (isValid: Bool, value: Int?) {
    guard let value else { return (true, nil) }
    guard let number = value.asNumber, let decoded = nonnegativeInt(number) else {
        return (false, nil)
    }
    return (true, decoded)
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
