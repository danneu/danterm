// The pane-tape record shape: one declaration of every key spelling, the typed record family
// those keys describe, and the decode that reads them back. It sits at the protocol boundary
// because the producer in DanTermSupport, every reading client, and the inspect view in
// PaneTapeInspect.swift must agree on the shape down to the last key -- a spelling declared
// on one side alone compiles clean everywhere and fails mid-stream.
//
// The stream's other vocabulary -- version, format, capture mode, end reasons -- lives in
// PaneTapeStream.swift, and the cursor codec in PaneTapeRequest.swift. Assembling a
// multi-part transfer is a reader's job and belongs with the reader, not here.
import Foundation

/// Every key a pane-tape record can carry, declared once so encode, decode, and the inspect
/// view all read the same spelling.
///
/// The recorded event's own inner keys are not here: that object is the engine's event
/// vocabulary passing through this shape, not part of it.
public enum PaneTapeRecordKey {
    public static let kind = "kind"
    public static let version = "version"
    public static let capture = "capture"
    public static let format = "format"
    public static let provenance = "provenance"
    public static let initial = "initial"
    public static let cursor = "cursor"
    public static let reconstructible = "reconstructible"
    public static let loss = "loss"
    public static let droppedEventCount = "droppedEventCount"
    public static let droppedFeedBytes = "droppedFeedBytes"
    public static let droppedWriteBytes = "droppedWriteBytes"
    public static let sequence = "sequence"
    public static let elapsedNanoseconds = "elapsedNanoseconds"
    public static let originElapsedNanoseconds = "originElapsedNanoseconds"
    public static let byteOffset = "byteOffset"
    public static let byteLength = "byteLength"
    public static let event = "event"
    public static let part = "part"
    public static let parts = "parts"
    public static let base64 = "base64"
    public static let droppedHistoryRows = "droppedHistoryRows"
    public static let reason = "reason"
    /// The three keys inside the geometry object a start record and a sync's first part share.
    public static let columns = "columns"
    public static let rows = "rows"
    public static let pinned = "pinned"
}

/// The record kinds this build knows how to read, spelled once for both ends.
public enum PaneTapeRecordKind: String, Sendable {
    case start
    case gap
    case event
    case sync
    case end
}

/// The one loss a gap record can state instead of exact counts.
public enum PaneTapeLoss: String, Sendable {
    /// The producer cannot measure what preceded the replacement state.
    case total
}

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
    /// Whatever the producer stamped about where this recording came from, left as JSON
    /// because only the producer gives it meaning; nil when the record stated none.
    public let provenance: JSONValue?
    /// Gives the initial terminal width.
    public let columns: Int
    /// Gives the initial terminal height.
    public let rows: Int
    /// States whether that grid is pinned -- an explicit override rather than a projection
    /// of the pane's rectangle. Required: the producer states geometry whole, and a reader
    /// that guessed would report a claim the pane does not hold.
    public let pinned: Bool
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
        provenance: JSONValue? = nil,
        columns: Int,
        rows: Int,
        pinned: Bool,
        cursor: PaneTapeCursor?,
        reconstructible: Bool
    ) {
        self.version = version
        self.capture = capture
        self.format = format
        self.provenance = provenance
        self.columns = columns
        self.rows = rows
        self.pinned = pinned
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
    /// Gives that grid's pinnedness on the first part only, beside its columns and rows.
    public let pinned: Bool?
    /// States on the first part how many of the source's retained history rows this transfer
    /// leaves out, oldest first. The bytes look the same either way, so only the producer can
    /// say it.
    public let droppedHistoryRows: Int?
    /// Publishes the continuation position on the final part only.
    public let cursor: PaneTapeCursor?

    /// Creates one decoded part for ordered assembly.
    public init(
        part: Int,
        parts: Int,
        bytes: [UInt8],
        columns: Int?,
        rows: Int?,
        pinned: Bool?,
        droppedHistoryRows: Int?,
        cursor: PaneTapeCursor?
    ) {
        self.part = part
        self.parts = parts
        self.bytes = bytes
        self.columns = columns
        self.rows = rows
        self.pinned = pinned
        self.droppedHistoryRows = droppedHistoryRows
        self.cursor = cursor
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
    guard let kind = value[PaneTapeRecordKey.kind]?.asString else { return nil }
    switch PaneTapeRecordKind(rawValue: kind) {
    case .start:
        // An unknown capture mode is malformed rather than unknown-but-fine. The two
        // captures differ in whether EOF is a legitimate ending, so a reader that guessed
        // would apply the permissive rule to a stream that never claimed it.
        guard let versionValue = value[PaneTapeRecordKey.version]?.asNumber,
              let version = nonnegativeInt(versionValue),
              let capture = value[PaneTapeRecordKey.capture]?.asString
                .flatMap(PaneTapeCaptureMode.init(rawValue:)),
              let format = value[PaneTapeRecordKey.format]?.asString
                .flatMap(PaneTapeFormat.init(rawValue:)),
              let initial = value[PaneTapeRecordKey.initial],
              let columnsValue = initial[PaneTapeRecordKey.columns]?.asNumber,
              let rowsValue = initial[PaneTapeRecordKey.rows]?.asNumber,
              let columns = positiveInt(columnsValue),
              let rows = positiveInt(rowsValue),
              case .bool(let pinned)? = initial[PaneTapeRecordKey.pinned],
              case .bool(let reconstructible)? = value[PaneTapeRecordKey.reconstructible]
        else { return nil }
        let cursor: PaneTapeCursor?
        if let cursorValue = value[PaneTapeRecordKey.cursor] {
            guard let decoded = decodePaneTapeCursor(cursorValue) else { return nil }
            cursor = decoded
        } else {
            cursor = nil
        }
        return .start(PaneTapeStartRecord(
            version: version,
            capture: capture,
            format: format,
            provenance: value[PaneTapeRecordKey.provenance],
            columns: columns,
            rows: rows,
            pinned: pinned,
            cursor: cursor,
            reconstructible: reconstructible
        ))
    case .gap:
        if let rawLoss = value[PaneTapeRecordKey.loss]?.asString {
            guard PaneTapeLoss(rawValue: rawLoss) == .total else { return nil }
            return .gap(.total)
        }
        guard let droppedValue = value[PaneTapeRecordKey.droppedEventCount]?.asNumber,
              let feedValue = value[PaneTapeRecordKey.droppedFeedBytes]?.asNumber,
              let writeValue = value[PaneTapeRecordKey.droppedWriteBytes]?.asNumber,
              let dropped = wholeUInt64(droppedValue),
              let feed = nonnegativeInt(feedValue),
              let write = nonnegativeInt(writeValue)
        else { return nil }
        return .gap(PaneTapeGapRecord(
            droppedEventCount: dropped,
            droppedFeedBytes: feed,
            droppedWriteBytes: write
        ))
    case .event:
        guard let sequenceValue = value[PaneTapeRecordKey.sequence]?.asNumber,
              let elapsedValue = value[PaneTapeRecordKey.elapsedNanoseconds]?.asNumber,
              let sequence = wholeUInt64(sequenceValue),
              let elapsed = wholeUInt64(elapsedValue),
              let event = value[PaneTapeRecordKey.event]
        else { return nil }
        let origin = optionalUInt64(value[PaneTapeRecordKey.originElapsedNanoseconds])
        let byteOffset = optionalNonnegativeInt(value[PaneTapeRecordKey.byteOffset])
        let byteLength = optionalNonnegativeInt(value[PaneTapeRecordKey.byteLength])
        guard origin.isValid, byteOffset.isValid, byteLength.isValid else { return nil }
        return .event(PaneTapeEventRecord(
            sequence: sequence,
            elapsedNanoseconds: elapsed,
            originElapsedNanoseconds: origin.value,
            byteOffset: byteOffset.value,
            byteLength: byteLength.value,
            event: event
        ))
    case .sync:
        guard let partValue = value[PaneTapeRecordKey.part]?.asNumber,
              let partsValue = value[PaneTapeRecordKey.parts]?.asNumber,
              let part = positiveInt(partValue),
              let parts = positiveInt(partsValue),
              let payload = value[PaneTapeRecordKey.base64]?.asString,
              let data = Data(base64Encoded: payload)
        else { return nil }
        guard parts >= part else { return nil }
        let initial = value[PaneTapeRecordKey.initial]
        let columns = initial?[PaneTapeRecordKey.columns]?.asNumber.flatMap(positiveInt)
        let rows = initial?[PaneTapeRecordKey.rows]?.asNumber.flatMap(positiveInt)
        let pinned: Bool?
        if case .bool(let value)? = initial?[PaneTapeRecordKey.pinned] {
            pinned = value
        } else {
            pinned = nil
        }
        let droppedHistoryRows = value[PaneTapeRecordKey.droppedHistoryRows]?
            .asNumber.flatMap(nonnegativeInt)
        // The whole-transfer facts arrive together or not at all, so a first part missing any
        // one of them is malformed rather than a part carrying some of them.
        guard (columns == nil) == (rows == nil),
              (columns == nil) == (pinned == nil),
              (columns == nil) == (droppedHistoryRows == nil)
        else {
            return nil
        }
        let cursor: PaneTapeCursor?
        if let cursorValue = value[PaneTapeRecordKey.cursor] {
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
            pinned: pinned,
            droppedHistoryRows: droppedHistoryRows,
            cursor: cursor
        ))
    case .end:
        return .end(reason: value[PaneTapeRecordKey.reason]?.asString
            .flatMap(PaneTapeEndReason.init(rawValue:)))
    case nil:
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
