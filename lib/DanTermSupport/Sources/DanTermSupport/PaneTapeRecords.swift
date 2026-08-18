// The pane-tape stream's portable values, its record construction, and the one enqueue site
// every record goes through. Finite dumps and followed streams both build here, so the two
// captures cannot drift into separate output contracts. The stream's shared vocabulary --
// version, format, capture mode, end reasons -- lives in DanTermProtocol, and the follow-only
// subscription lifecycle in PaneTapeFollow.swift; neither belongs here.
import Foundation
import DanTermProtocol

extension PaneTapeCursor {
    /// Internal sentinel used only where stream policy ignores the supplied-cursor branch.
    static let beginning = Self(
        recorderLifetimeId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        nextSequence: 0,
        feedBytesBeforeNextSequence: 0,
        writeBytesBeforeNextSequence: 0
    )
}

/// Keeps stream geometry independent from the terminal engine's dimension type.
///
/// Geometry is one two-part fact on this stream: the grid, plus whether that grid is pinned
/// -- an explicit override rather than a projection of the pane's rectangle. Every
/// geometry-bearing shape states both, so a reader can never hold half of a transition.
struct PaneTapeDimensions: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let pinned: Bool
}

/// States one pane's geometry whole, so the start record and the sync payload cannot
/// disagree about the shape they publish it in.
func paneTapeGeometryJSON(_ geometry: PaneTapeDimensions) -> JSONValue {
    .object([
        "columns": .number(Double(geometry.columns)),
        "rows": .number(Double(geometry.rows)),
        "pinned": .bool(geometry.pinned),
    ])
}

/// Locates one event's bytes inside its own direction's lifetime byte stream.
struct PaneTapePayloadSpan: Equatable, Sendable {
    let byteOffset: Int
    let byteLength: Int
}

/// Adapts one terminal event to the support layer without importing terminal modules.
struct PaneTapeEvent: Equatable, Sendable {
    let sequence: UInt64
    let elapsedNanoseconds: UInt64
    /// When the event that produced these bytes occurred, on the same scale as
    /// `elapsedNanoseconds`; nil for bytes with no origin earlier than their own transfer.
    let originElapsedNanoseconds: UInt64?
    /// Where these bytes sit in their direction's stream; nil for an event carrying no bytes.
    let payload: PaneTapePayloadSpan?
    let event: JSONValue
}

/// Represents one owner-fenced suffix in protocol-only values for off-main processing.
struct PaneTapeSnapshot: Equatable, Sendable {
    let events: [PaneTapeEvent]
    let droppedEventCount: UInt64
    let droppedFeedBytes: Int
    let droppedWriteBytes: Int
    let nextCursor: PaneTapeCursor
}

/// Delivers complete JSON records together with the cursor they advance through.
struct PaneTapeBatch: Equatable, Sendable {
    let records: [JSONValue]
    let nextCursor: PaneTapeCursor
}

/// Couples the record that opens a stream to the exact cursor its contents continue from.
struct PaneTapeStart: Equatable, Sendable {
    let record: JSONValue
    let cursor: PaneTapeCursor
}

/// One complete finite capture. Both halves come from a single owner fence, so the dump states
/// one atomic moment even though its records reach the socket one at a time afterwards.
struct PaneTapeDump: Equatable, Sendable {
    let start: PaneTapeStart
    let snapshot: PaneTapeSnapshot
}

/// Builds the record that establishes a stream before any event record follows it.
func makePaneTapeStart(
    capture: PaneTapeCaptureMode,
    provenance: JSONValue,
    initial: PaneTapeDimensions,
    cursor: PaneTapeCursor,
    publishesCursor: Bool = true,
    reconstructible: Bool = false
) -> PaneTapeStart {
    var record: [String: JSONValue] = [
        "kind": .string("start"),
        "version": .number(Double(paneTapeStreamVersion)),
        "capture": .string(capture.rawValue),
        "format": .string(PaneTapeFormat.replay.rawValue),
        "provenance": provenance,
        "initial": paneTapeGeometryJSON(initial),
    ]
    if publishesCursor {
        // The baseline every later offset is read against. Without it a stream that starts
        // past the beginning -- a tail-only follow, or a dump whose head was evicted --
        // reports offsets a reader has no origin for.
        record["cursor"] = paneTapeCursorJSON(cursor)
    }
    record["reconstructible"] = .bool(reconstructible)
    return PaneTapeStart(
        record: .object(record),
        cursor: cursor
    )
}

/// Converts an owner-fenced suffix into an ordered gap-and-events delivery.
func makePaneTapeBatch(from snapshot: PaneTapeSnapshot) -> PaneTapeBatch {
    var records: [JSONValue] = []
    records.reserveCapacity(snapshot.events.count + (snapshot.droppedEventCount > 0 ? 1 : 0))
    if snapshot.droppedEventCount > 0 {
        records.append(makePaneTapeExactGapRecord(snapshot))
    }
    records.append(contentsOf: snapshot.events.map(makePaneTapeEventRecord))
    return PaneTapeBatch(records: records, nextCursor: snapshot.nextCursor)
}

/// States exact loss for a cursor the recorder placed in its own lifetime.
func makePaneTapeExactGapRecord(_ snapshot: PaneTapeSnapshot) -> JSONValue {
    .object([
        "kind": .string("gap"),
        "droppedEventCount": .number(Double(snapshot.droppedEventCount)),
        "droppedFeedBytes": .number(Double(snapshot.droppedFeedBytes)),
        "droppedWriteBytes": .number(Double(snapshot.droppedWriteBytes)),
    ])
}

/// Orders every record a finite dump owes after its start record.
///
/// A finite dump always states its own end, because its boundary is a fence it already took:
/// unlike a followed stream, nothing can arrive later to extend it, so stopping without a
/// terminator would leave a reader unable to tell a whole capture from a truncated one.
func makePaneTapeDumpRecords(after dump: PaneTapeDump) -> [JSONValue] {
    makePaneTapeBatch(from: dump.snapshot).records
        + [makePaneTapeEndRecord(reason: .dumpComplete)]
}

/// Builds one event record, with its timing and byte position hoisted out of the event object.
///
/// The origin sits beside the transfer stamp rather than inside the event, because this shape
/// already hoists timing out of the event object. An absent origin omits the key: a number
/// there would read as a measurement of an event that had none, and the same reasoning omits
/// the byte position of an event that carries no bytes.
func makePaneTapeEventRecord(_ event: PaneTapeEvent) -> JSONValue {
    var record: [String: JSONValue] = [
        "kind": .string("event"),
        "sequence": .number(Double(event.sequence)),
        "elapsedNanoseconds": .number(Double(event.elapsedNanoseconds)),
        "event": event.event,
    ]
    if let origin = event.originElapsedNanoseconds {
        record["originElapsedNanoseconds"] = .number(Double(origin))
    }
    if let payload = event.payload {
        record["byteOffset"] = .number(Double(payload.byteOffset))
        record["byteLength"] = .number(Double(payload.byteLength))
    }
    return .object(record)
}

/// Produces the only explicit stream terminator a producer promises while it can still write.
func makePaneTapeEndRecord(reason: PaneTapeEndReason) -> JSONValue {
    .object([
        "kind": .string("end"),
        "reason": .string(reason.rawValue),
    ])
}

/// The single site that puts a tape record on the wire, for dumps, batches, and terminators.
///
/// Each call enqueues straight onto the connection's serial write queue, so records reach the
/// socket in the order they were handed over. Routing one write kind through a concurrent queue
/// instead would let a terminator overtake a batch prepared before it, and a stream's last
/// record would not be its last. The optional completion reports the flush of the final record.
func writePaneTapeRecords(
    _ records: [JSONValue],
    connection: IpcConnection,
    subscriptionId: UUID,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
) {
    precondition(records.isEmpty == false)
    let lastIndex = records.index(before: records.endIndex)
    for (index, record) in records.enumerated() {
        connection.writeNotification(
            method: Methods.paneTapeEvent,
            params: .object([
                "subscription": .string(subscriptionId.uuidString),
                "record": record,
            ]),
            completion: index == lastIndex ? completion : nil
        )
    }
}
