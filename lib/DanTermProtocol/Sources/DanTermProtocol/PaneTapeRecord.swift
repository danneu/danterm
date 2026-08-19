// The pane-tape record shape: one declaration of every key spelling, the typed record family
// those keys describe, the encode that writes them, and the decode that reads them back. It
// sits at the protocol boundary
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
/// The event payload is a type parameter rather than always JSON so a reader that owns the
/// engine's event vocabulary can carry the decoded event in the record itself. This module
/// must name no engine type -- every layer depends on it -- and a type parameter names
/// none, so one record family serves both sides without a second enum kept in sync by hand.
public enum PaneTapeRecord<Event> {
    /// Declares the stream contract and its initial cursor or pending synchronization.
    case start(PaneTapeStartRecord)
    /// Reports recorder evidence that is unavailable before the following records.
    case gap(PaneTapeGapRecord)
    /// Carries one retained recorder event.
    case event(PaneTapeEventRecord<Event>)
    /// Carries one ordered part of exact terminal state.
    case sync(PaneTapeSyncRecord)
    /// A clean end, carrying the producer's reason when this build knows the spelling.
    case end(reason: PaneTapeEndReason?)
    case unknown(kind: String)
}

extension PaneTapeRecord: Equatable where Event: Equatable {}
extension PaneTapeRecord: Sendable where Event: Sendable {}

extension PaneTapeRecord {
    /// Replaces the event payload and leaves every other record kind untouched, which is
    /// how a reader lifts the wire's JSON event into its own typed event exactly once.
    public func mapEvent<Mapped>(
        _ transform: (Event) throws -> Mapped
    ) rethrows -> PaneTapeRecord<Mapped> {
        switch self {
        case .start(let start): .start(start)
        case .gap(let gap): .gap(gap)
        case .event(let record): .event(try record.mapEvent(transform))
        case .sync(let sync): .sync(sync)
        case .end(let reason): .end(reason: reason)
        case .unknown(let kind): .unknown(kind: kind)
        }
    }
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
    /// What the whole transfer states about itself, carried by its first part alone.
    ///
    /// The four facts are one value rather than four optional fields so "all four or none"
    /// holds by construction: a record cannot state the geometry without the history count,
    /// and no encoder, decoder, or assembler has to check that it did not.
    public struct Transfer: Equatable, Sendable {
        /// Gives the terminal width the state must be applied at.
        public let columns: Int
        /// Gives the terminal height the state must be applied at.
        public let rows: Int
        /// Gives that grid's pinnedness, beside its columns and rows.
        public let pinned: Bool
        /// States how many of the source's retained history rows this transfer leaves out,
        /// oldest first. The bytes look the same either way, so only the producer can say it.
        public let droppedHistoryRows: Int

        /// Creates the whole-transfer facts one first part publishes.
        public init(columns: Int, rows: Int, pinned: Bool, droppedHistoryRows: Int) {
            self.columns = columns
            self.rows = rows
            self.pinned = pinned
            self.droppedHistoryRows = droppedHistoryRows
        }
    }

    /// Gives this part's one-based position.
    public let part: Int
    /// Gives the complete transfer's part count.
    public let parts: Int
    /// Carries this part's terminal-state bytes.
    public let bytes: [UInt8]
    /// Carries the whole-transfer facts on the first part, and nil on every later part.
    public let transfer: Transfer?
    /// Publishes the continuation position on the final part only.
    public let cursor: PaneTapeCursor?

    /// Creates one decoded part for ordered assembly.
    public init(
        part: Int,
        parts: Int,
        bytes: [UInt8],
        transfer: Transfer?,
        cursor: PaneTapeCursor?
    ) {
        self.part = part
        self.parts = parts
        self.bytes = bytes
        self.transfer = transfer
        self.cursor = cursor
    }
}

/// One tape event, with its timing and byte position hoisted out of the event object the
/// same way the producer hoists them.
public struct PaneTapeEventRecord<Event> {
    public let sequence: UInt64
    public let elapsedNanoseconds: UInt64
    public let originElapsedNanoseconds: UInt64?
    public let byteOffset: Int?
    public let byteLength: Int?
    /// The recording event itself. It is JSON on the wire, because this module names no
    /// engine type; a reader that links the recording types lifts it to that type once.
    public let event: Event

    public init(
        sequence: UInt64,
        elapsedNanoseconds: UInt64,
        originElapsedNanoseconds: UInt64?,
        byteOffset: Int?,
        byteLength: Int?,
        event: Event
    ) {
        self.sequence = sequence
        self.elapsedNanoseconds = elapsedNanoseconds
        self.originElapsedNanoseconds = originElapsedNanoseconds
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.event = event
    }

    /// Replaces the event payload while preserving every position and timing fact, so the
    /// lift cannot quietly restate one of them.
    public func mapEvent<Mapped>(
        _ transform: (Event) throws -> Mapped
    ) rethrows -> PaneTapeEventRecord<Mapped> {
        PaneTapeEventRecord<Mapped>(
            sequence: sequence,
            elapsedNanoseconds: elapsedNanoseconds,
            originElapsedNanoseconds: originElapsedNanoseconds,
            byteOffset: byteOffset,
            byteLength: byteLength,
            event: try transform(event)
        )
    }
}

extension PaneTapeEventRecord: Equatable where Event: Equatable {}
extension PaneTapeEventRecord: Sendable where Event: Sendable {}

/// One record a producer can put on the wire.
///
/// It is the read family minus the two states only a reader can hold: `.unknown`, which has
/// already discarded every field but the kind, and an end whose reason this build could not
/// name. Both would encode to a lossy object, so the encoder does not accept them -- and it
/// refuses them by construction rather than at runtime, which is why this is a separate
/// enum instead of a precondition inside the encode.
///
/// The event payload is a type parameter for the same reason it is one on the read family:
/// this module names no engine type, and a producer that owns the event vocabulary hands its
/// own event straight to the encoder, which writes it through the event's own `Codable`
/// conformance. Carrying it as `any Encodable` instead would cost the conditional
/// `Equatable` and `Sendable` conformances the producer's stream types are built on.
public enum PaneTapeOutgoingRecord<Event> {
    case start(PaneTapeStartRecord)
    case gap(PaneTapeGapRecord)
    case event(PaneTapeEventRecord<Event>)
    case sync(PaneTapeSyncRecord)
    case end(reason: PaneTapeEndReason)
}

extension PaneTapeOutgoingRecord: Equatable where Event: Equatable {}
extension PaneTapeOutgoingRecord: Sendable where Event: Sendable {}

/// Names every key by its one declaration in `PaneTapeRecordKey`. A `String`-raw-valued
/// `CodingKey` enum cannot: raw values must be literals, so the spellings would be
/// written a second time.
private struct RecordKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ key: String) { stringValue = key }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { nil }

    static let kind = RecordKey(PaneTapeRecordKey.kind)
    static let version = RecordKey(PaneTapeRecordKey.version)
    static let capture = RecordKey(PaneTapeRecordKey.capture)
    static let format = RecordKey(PaneTapeRecordKey.format)
    static let provenance = RecordKey(PaneTapeRecordKey.provenance)
    static let initial = RecordKey(PaneTapeRecordKey.initial)
    static let cursor = RecordKey(PaneTapeRecordKey.cursor)
    static let reconstructible = RecordKey(PaneTapeRecordKey.reconstructible)
    static let loss = RecordKey(PaneTapeRecordKey.loss)
    static let droppedEventCount = RecordKey(PaneTapeRecordKey.droppedEventCount)
    static let droppedFeedBytes = RecordKey(PaneTapeRecordKey.droppedFeedBytes)
    static let droppedWriteBytes = RecordKey(PaneTapeRecordKey.droppedWriteBytes)
    static let sequence = RecordKey(PaneTapeRecordKey.sequence)
    static let elapsedNanoseconds = RecordKey(PaneTapeRecordKey.elapsedNanoseconds)
    static let originElapsedNanoseconds = RecordKey(PaneTapeRecordKey.originElapsedNanoseconds)
    static let byteOffset = RecordKey(PaneTapeRecordKey.byteOffset)
    static let byteLength = RecordKey(PaneTapeRecordKey.byteLength)
    static let event = RecordKey(PaneTapeRecordKey.event)
    static let part = RecordKey(PaneTapeRecordKey.part)
    static let parts = RecordKey(PaneTapeRecordKey.parts)
    static let base64 = RecordKey(PaneTapeRecordKey.base64)
    static let droppedHistoryRows = RecordKey(PaneTapeRecordKey.droppedHistoryRows)
    static let reason = RecordKey(PaneTapeRecordKey.reason)
    static let columns = RecordKey(PaneTapeRecordKey.columns)
    static let rows = RecordKey(PaneTapeRecordKey.rows)
    static let pinned = RecordKey(PaneTapeRecordKey.pinned)
}

/// Writes the record as the JSON object the wire carries -- the only encode of this shape,
/// paired with `decodePaneTapeRecord`.
///
/// A field the record does not hold is omitted rather than stated as null: a reader treats a
/// present key as a measurement the producer made, so a null origin stamp or byte span would
/// report a measurement of something that had none.
///
/// The event object is the event's own encoding, written inline. Restating that vocabulary
/// here would give the producer a second spelling of it that only a test could keep honest.
extension PaneTapeOutgoingRecord: Encodable where Event: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RecordKey.self)
        switch self {
        case .start(let start):
            try container.encode(PaneTapeRecordKind.start.rawValue, forKey: .kind)
            try container.encode(start.version, forKey: .version)
            try container.encode(start.capture.rawValue, forKey: .capture)
            try container.encode(start.format.rawValue, forKey: .format)
            try container.encodeIfPresent(start.provenance, forKey: .provenance)
            try encodeGeometry(
                columns: start.columns,
                rows: start.rows,
                pinned: start.pinned,
                into: &container
            )
            try container.encode(start.reconstructible, forKey: .reconstructible)
            // The baseline every later offset is read against. A stream withholds it only when
            // another record publishes the same position, because a stream that starts past the
            // beginning otherwise reports offsets a reader has no origin for.
            if let cursor = start.cursor {
                try container.encode(paneTapeCursorJSON(cursor), forKey: .cursor)
            }
        case .gap(let gap):
            try container.encode(PaneTapeRecordKind.gap.rawValue, forKey: .kind)
            switch gap.loss {
            case .total:
                try container.encode(PaneTapeLoss.total.rawValue, forKey: .loss)
            case .exact(let events, let feedBytes, let writeBytes):
                try container.encode(events, forKey: .droppedEventCount)
                try container.encode(feedBytes, forKey: .droppedFeedBytes)
                try container.encode(writeBytes, forKey: .droppedWriteBytes)
            }
        case .event(let event):
            try container.encode(PaneTapeRecordKind.event.rawValue, forKey: .kind)
            try container.encode(event.sequence, forKey: .sequence)
            try container.encode(event.elapsedNanoseconds, forKey: .elapsedNanoseconds)
            try container.encodeIfPresent(
                event.originElapsedNanoseconds,
                forKey: .originElapsedNanoseconds
            )
            try container.encodeIfPresent(event.byteOffset, forKey: .byteOffset)
            try container.encodeIfPresent(event.byteLength, forKey: .byteLength)
            try container.encode(event.event, forKey: .event)
        case .sync(let sync):
            try container.encode(PaneTapeRecordKind.sync.rawValue, forKey: .kind)
            try container.encode(sync.part, forKey: .part)
            try container.encode(sync.parts, forKey: .parts)
            try container.encode(Data(sync.bytes).base64EncodedString(), forKey: .base64)
            if let transfer = sync.transfer {
                try encodeGeometry(
                    columns: transfer.columns,
                    rows: transfer.rows,
                    pinned: transfer.pinned,
                    into: &container
                )
                try container.encode(transfer.droppedHistoryRows, forKey: .droppedHistoryRows)
            }
            if let cursor = sync.cursor {
                try container.encode(paneTapeCursorJSON(cursor), forKey: .cursor)
            }
        case .end(let reason):
            try container.encode(PaneTapeRecordKind.end.rawValue, forKey: .kind)
            try container.encode(reason.rawValue, forKey: .reason)
        }
    }

    /// States one pane's geometry whole, so the start record and a sync's first part cannot
    /// disagree about the shape they publish it in.
    private func encodeGeometry(
        columns: Int,
        rows: Int,
        pinned: Bool,
        into container: inout KeyedEncodingContainer<RecordKey>
    ) throws {
        var geometry = container.nestedContainer(keyedBy: RecordKey.self, forKey: .initial)
        try geometry.encode(columns, forKey: .columns)
        try geometry.encode(rows, forKey: .rows)
        try geometry.encode(pinned, forKey: .pinned)
    }
}

/// Builds the same object as a `JSONValue` tree, for the producer sites that still pass tape
/// records around as JSON.
///
/// Temporary: the support producer builds records in one place and writes them in another,
/// and both halves move to the typed record together. This entry point and the tree it builds
/// go away with that move, leaving the `Encodable` conformance above as the only encode.
public func encodePaneTapeRecord(_ record: PaneTapeOutgoingRecord<JSONValue>) -> JSONValue {
    switch record {
    case .start(let start):
        var fields: [String: JSONValue] = [
            PaneTapeRecordKey.kind: .string(PaneTapeRecordKind.start.rawValue),
            PaneTapeRecordKey.version: .number(Double(start.version)),
            PaneTapeRecordKey.capture: .string(start.capture.rawValue),
            PaneTapeRecordKey.format: .string(start.format.rawValue),
            PaneTapeRecordKey.initial: encodePaneTapeGeometry(
                columns: start.columns,
                rows: start.rows,
                pinned: start.pinned
            ),
            PaneTapeRecordKey.reconstructible: .bool(start.reconstructible),
        ]
        if let provenance = start.provenance {
            fields[PaneTapeRecordKey.provenance] = provenance
        }
        // The baseline every later offset is read against. A stream withholds it only when
        // another record publishes the same position, because a stream that starts past the
        // beginning otherwise reports offsets a reader has no origin for.
        if let cursor = start.cursor {
            fields[PaneTapeRecordKey.cursor] = paneTapeCursorJSON(cursor)
        }
        return .object(fields)
    case .gap(let gap):
        switch gap.loss {
        case .total:
            return .object([
                PaneTapeRecordKey.kind: .string(PaneTapeRecordKind.gap.rawValue),
                PaneTapeRecordKey.loss: .string(PaneTapeLoss.total.rawValue),
            ])
        case .exact(let events, let feedBytes, let writeBytes):
            return .object([
                PaneTapeRecordKey.kind: .string(PaneTapeRecordKind.gap.rawValue),
                PaneTapeRecordKey.droppedEventCount: .number(Double(events)),
                PaneTapeRecordKey.droppedFeedBytes: .number(Double(feedBytes)),
                PaneTapeRecordKey.droppedWriteBytes: .number(Double(writeBytes)),
            ])
        }
    case .event(let event):
        var fields: [String: JSONValue] = [
            PaneTapeRecordKey.kind: .string(PaneTapeRecordKind.event.rawValue),
            PaneTapeRecordKey.sequence: .number(Double(event.sequence)),
            PaneTapeRecordKey.elapsedNanoseconds: .number(Double(event.elapsedNanoseconds)),
            PaneTapeRecordKey.event: event.event,
        ]
        if let origin = event.originElapsedNanoseconds {
            fields[PaneTapeRecordKey.originElapsedNanoseconds] = .number(Double(origin))
        }
        if let byteOffset = event.byteOffset {
            fields[PaneTapeRecordKey.byteOffset] = .number(Double(byteOffset))
        }
        if let byteLength = event.byteLength {
            fields[PaneTapeRecordKey.byteLength] = .number(Double(byteLength))
        }
        return .object(fields)
    case .sync(let sync):
        var fields: [String: JSONValue] = [
            PaneTapeRecordKey.kind: .string(PaneTapeRecordKind.sync.rawValue),
            PaneTapeRecordKey.part: .number(Double(sync.part)),
            PaneTapeRecordKey.parts: .number(Double(sync.parts)),
            PaneTapeRecordKey.base64: .string(Data(sync.bytes).base64EncodedString()),
        ]
        if let transfer = sync.transfer {
            fields[PaneTapeRecordKey.initial] = encodePaneTapeGeometry(
                columns: transfer.columns,
                rows: transfer.rows,
                pinned: transfer.pinned
            )
            fields[PaneTapeRecordKey.droppedHistoryRows] =
                .number(Double(transfer.droppedHistoryRows))
        }
        if let cursor = sync.cursor {
            fields[PaneTapeRecordKey.cursor] = paneTapeCursorJSON(cursor)
        }
        return .object(fields)
    case .end(let reason):
        return .object([
            PaneTapeRecordKey.kind: .string(PaneTapeRecordKind.end.rawValue),
            PaneTapeRecordKey.reason: .string(reason.rawValue),
        ])
    }
}

/// States one pane's geometry whole, so the start record and a sync's first part cannot
/// disagree about the shape they publish it in.
private func encodePaneTapeGeometry(columns: Int, rows: Int, pinned: Bool) -> JSONValue {
    .object([
        PaneTapeRecordKey.columns: .number(Double(columns)),
        PaneTapeRecordKey.rows: .number(Double(rows)),
        PaneTapeRecordKey.pinned: .bool(pinned),
    ])
}

/// Decodes one tape record, or returns nil when the value is not a record at all or a
/// record whose own required fields are missing.
///
/// A record kind this build does not know is not a failure: it decodes to `.unknown`.
///
/// The event payload stays JSON here, because this module names no engine type. A reader
/// that owns the event vocabulary lifts it with `mapEvent` at its own edge.
public func decodePaneTapeRecord(_ value: JSONValue) -> PaneTapeRecord<JSONValue>? {
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
        // The whole-transfer facts arrive together or not at all, so a record carrying some of
        // them is malformed rather than a part that states a subset.
        let transfer: PaneTapeSyncRecord.Transfer?
        switch (columns, rows, pinned, droppedHistoryRows) {
        case (nil, nil, nil, nil):
            transfer = nil
        case (let columns?, let rows?, let pinned?, let droppedHistoryRows?):
            transfer = PaneTapeSyncRecord.Transfer(
                columns: columns,
                rows: rows,
                pinned: pinned,
                droppedHistoryRows: droppedHistoryRows
            )
        default:
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
            transfer: transfer,
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
