// Pure pane-tape opening policy: it chooses retained events or an atomic state sync from one
// owner fence. IPC request parsing and socket delivery stay outside this file.
import Foundation
import DanTermProtocol

/// Holds the request facts that decide the stream's opening records.
struct PaneTapeStreamRequest: Equatable, Sendable {
    let capture: PaneTapeCaptureMode
    let policy: PaneTapeSyncPolicy
    let position: PaneTapeStartPosition
}

/// Keeps recorder birth geometry with the real lifetime cursor at sequence zero.
struct PaneTapeOrigin: Equatable, Sendable {
    let initial: PaneTapeDimensions
    let cursor: PaneTapeCursor
}

/// Separates a cursor the recorder placed from remote coordinates it rejected.
enum PaneTapeCursorPlacement: Equatable, Sendable {
    case placed(PaneTapeSnapshot)
    case unplaceable
}

/// Carries terminal-protocol state bytes with their geometry and continuation position.
struct PaneTapeStateSynchronization: Equatable, Sendable {
    let bytes: [UInt8]
    let dimensions: PaneTapeDimensions
    /// How many retained history rows these bytes leave out, oldest first. A replica cannot
    /// derive it -- the bytes look the same whether the source had more history or not -- so
    /// the record has to state it.
    let droppedHistoryRows: Int
    let cursor: PaneTapeCursor
}

/// Gives stream policy every value observed at one pane-owner fence.
struct PaneTapeStreamFence: Equatable, Sendable {
    let origin: PaneTapeOrigin
    let retained: PaneTapeSnapshot
    let requested: PaneTapeCursorPlacement
    let synchronization: PaneTapeStateSynchronization
}

/// Describes the complete prefix that must be delivered before live follow batches can begin.
struct PaneTapeOpening: Equatable, Sendable {
    let start: PaneTapeStart
    let records: [JSONValue]
    let nextCursor: PaneTapeCursor
}

/// Keeps a followed suffix inseparable from exact replacement state at its ending cursor.
struct PaneTapeFollowStreamFence: Equatable, Sendable {
    let snapshot: PaneTapeSnapshot
    let synchronization: PaneTapeStateSynchronization
}

/// Builds one followed suffix, replacing lost events with exact state in reconstructible mode.
func makePaneTapeContinuation(
    policy: PaneTapeSyncPolicy,
    fence: PaneTapeFollowStreamFence
) -> PaneTapeBatch {
    if policy.mode == .reconstructible, fence.snapshot.droppedEventCount > 0 {
        return PaneTapeBatch(
            records: [makePaneTapeExactGapRecord(fence.snapshot)]
                + makePaneTapeSynchronizationRecords(fence.synchronization),
            nextCursor: fence.synchronization.cursor
        )
    }
    return makePaneTapeBatch(from: fence.snapshot)
}

/// Applies the reconstructibility rule without IO or mutable subscription state.
func makePaneTapeOpening(
    request: PaneTapeStreamRequest,
    fence: PaneTapeStreamFence,
    provenance: JSONValue = .object(["source": .string("danterm-live-capture")])
) -> PaneTapeOpening {
    let selection = selectPaneTapeOpening(request: request, fence: fence)
    let start = makePaneTapeStart(
        capture: request.capture,
        provenance: provenance,
        initial: selection.initial,
        cursor: selection.publishedCursor ?? selection.nextCursor,
        publishesCursor: selection.publishedCursor != nil,
        reconstructible: request.policy.mode == .reconstructible
    )
    return PaneTapeOpening(
        start: start,
        records: selection.records,
        nextCursor: selection.nextCursor
    )
}

private struct PaneTapeOpeningSelection {
    let initial: PaneTapeDimensions
    let publishedCursor: PaneTapeCursor?
    let records: [JSONValue]
    let nextCursor: PaneTapeCursor
}

private func selectPaneTapeOpening(
    request: PaneTapeStreamRequest,
    fence: PaneTapeStreamFence
) -> PaneTapeOpeningSelection {
    switch request.position {
    case .now:
        if request.policy.mode == .reconstructible {
            return synchronizedSelection(loss: nil, fence: fence)
        }
        return PaneTapeOpeningSelection(
            initial: fence.synchronization.dimensions,
            publishedCursor: fence.synchronization.cursor,
            records: [],
            nextCursor: fence.synchronization.cursor
        )

    case .beginning:
        if request.policy.mode == .reconstructible, fence.retained.droppedEventCount > 0 {
            return synchronizedSelection(
                loss: makePaneTapeExactGapRecord(fence.retained),
                fence: fence
            )
        }
        return eventSelection(
            initial: fence.origin.initial,
            cursor: fence.origin.cursor,
            snapshot: fence.retained
        )

    case .cursor(let cursor):
        switch fence.requested {
        case .placed(let snapshot):
            if request.policy.mode == .reconstructible, snapshot.droppedEventCount > 0 {
                return synchronizedSelection(
                    loss: makePaneTapeExactGapRecord(snapshot),
                    fence: fence
                )
            }
            return eventSelection(
                initial: fence.origin.initial,
                cursor: cursor,
                snapshot: snapshot
            )
        case .unplaceable:
            let totalLoss = makePaneTapeTotalGapRecord()
            if request.policy.mode == .reconstructible {
                return synchronizedSelection(loss: totalLoss, fence: fence)
            }
            let head = retainedHeadCursor(origin: fence.origin.cursor, snapshot: fence.retained)
            return PaneTapeOpeningSelection(
                initial: fence.origin.initial,
                publishedCursor: head,
                records: [totalLoss] + fence.retained.events.map(makePaneTapeEventRecord),
                nextCursor: fence.retained.nextCursor
            )
        }
    }
}

private func eventSelection(
    initial: PaneTapeDimensions,
    cursor: PaneTapeCursor,
    snapshot: PaneTapeSnapshot
) -> PaneTapeOpeningSelection {
    PaneTapeOpeningSelection(
        initial: initial,
        publishedCursor: cursor,
        records: makePaneTapeBatch(from: snapshot).records,
        nextCursor: snapshot.nextCursor
    )
}

private func synchronizedSelection(
    loss: JSONValue?,
    fence: PaneTapeStreamFence
) -> PaneTapeOpeningSelection {
    PaneTapeOpeningSelection(
        initial: fence.synchronization.dimensions,
        publishedCursor: nil,
        records: (loss.map { [$0] } ?? [])
            + makePaneTapeSynchronizationRecords(fence.synchronization),
        nextCursor: fence.synchronization.cursor
    )
}

private func makePaneTapeTotalGapRecord() -> JSONValue {
    .object([
        "kind": .string("gap"),
        "loss": .string("total"),
    ])
}

private func retainedHeadCursor(
    origin: PaneTapeCursor,
    snapshot: PaneTapeSnapshot
) -> PaneTapeCursor {
    PaneTapeCursor(
        recorderLifetimeId: origin.recorderLifetimeId,
        nextSequence: origin.nextSequence + snapshot.droppedEventCount,
        feedBytesBeforeNextSequence: origin.feedBytesBeforeNextSequence
            + snapshot.droppedFeedBytes,
        writeBytesBeforeNextSequence: origin.writeBytesBeforeNextSequence
            + snapshot.droppedWriteBytes
    )
}

private func makePaneTapeSynchronizationRecords(
    _ synchronization: PaneTapeStateSynchronization
) -> [JSONValue] {
    let maximumPayloadBytes = IpcLineFramer.maxLineBytes / 4
    let chunks = synchronization.bytes.isEmpty
        ? [[]]
        : stride(from: 0, to: synchronization.bytes.count, by: maximumPayloadBytes).map { start in
            Array(synchronization.bytes[start..<min(start + maximumPayloadBytes, synchronization.bytes.count)])
        }
    return chunks.enumerated().map { index, bytes in
        var record: [String: JSONValue] = [
            "kind": .string("sync"),
            "part": .number(Double(index + 1)),
            "parts": .number(Double(chunks.count)),
            "base64": .string(Data(bytes).base64EncodedString()),
        ]
        if index == chunks.startIndex {
            record["initial"] = paneTapeGeometryJSON(synchronization.dimensions)
            record["droppedHistoryRows"] = .number(Double(synchronization.droppedHistoryRows))
        }
        if index == chunks.index(before: chunks.endIndex) {
            record["cursor"] = paneTapeCursorJSON(synchronization.cursor)
        }
        return .object(record)
    }
}
