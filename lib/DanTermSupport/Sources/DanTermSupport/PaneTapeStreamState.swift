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
    /// Whether this prefix leaves the replica holding the source's whole retained history.
    /// Only this stream can establish it: it replayed the recorder from its beginning with
    /// nothing evicted, or a sync on it reported no dropped history rows. A cursor is a
    /// recorder coordinate and says nothing about a replica, so a resumed stream starts unknown.
    let replicaHistoryIsComplete: Bool
}

/// Keeps one followed suffix inseparable from what it leaves the replica knowing about its
/// own history, so the next fetch cannot decide the resize question from a stale standing.
struct PaneTapeContinuation: Equatable, Sendable {
    let batch: PaneTapeBatch
    let replicaHistoryIsComplete: Bool
}

/// Keeps a followed suffix inseparable from exact replacement state at its ending cursor.
struct PaneTapeFollowStreamFence: Equatable, Sendable {
    let snapshot: PaneTapeSnapshot
    let synchronization: PaneTapeStateSynchronization
}

/// Builds one followed suffix, replacing lost events with exact state in reconstructible mode.
///
/// The same replacement covers a second case: a suffix that resizes cannot be replayed by a
/// replica whose history the stream truncated, so that suffix is replaced whole by a fresh
/// bounded sync at its ending cursor. No replaced event is also delivered, which is what keeps
/// the replica's grid exact instead of an argument about how far a reflow can reach.
func makePaneTapeContinuation(
    policy: PaneTapeSyncPolicy,
    replicaHistoryIsComplete: Bool,
    fence: PaneTapeFollowStreamFence
) -> PaneTapeContinuation {
    if policy.mode == .reconstructible, fence.snapshot.droppedEventCount > 0 {
        return synchronizedContinuation(
            loss: makePaneTapeExactGapRecord(fence.snapshot),
            synchronization: fence.synchronization
        )
    }
    if policy.mode == .reconstructible,
       replicaHistoryIsComplete == false,
       fence.snapshot.events.contains(where: \.needsCompleteHistory)
    {
        return synchronizedContinuation(loss: nil, synchronization: fence.synchronization)
    }
    return PaneTapeContinuation(
        batch: makePaneTapeBatch(from: fence.snapshot),
        replicaHistoryIsComplete: replicaHistoryIsComplete
    )
}

private func synchronizedContinuation(
    loss: JSONValue?,
    synchronization: PaneTapeStateSynchronization
) -> PaneTapeContinuation {
    PaneTapeContinuation(
        batch: PaneTapeBatch(
            records: (loss.map { [$0] } ?? [])
                + makePaneTapeSynchronizationRecords(synchronization),
            nextCursor: synchronization.cursor
        ),
        replicaHistoryIsComplete: synchronization.droppedHistoryRows == 0
    )
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
        nextCursor: selection.nextCursor,
        replicaHistoryIsComplete: selection.replicaHistoryIsComplete
    )
}

private struct PaneTapeOpeningSelection {
    let initial: PaneTapeDimensions
    let publishedCursor: PaneTapeCursor?
    let records: [JSONValue]
    let nextCursor: PaneTapeCursor
    let replicaHistoryIsComplete: Bool
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
            nextCursor: fence.synchronization.cursor,
            replicaHistoryIsComplete: false
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
            snapshot: fence.retained,
            // Replayed from the recorder's own beginning: the replica built every history row
            // the source has, unless the recorder already evicted some of them.
            replicaHistoryIsComplete: fence.retained.droppedEventCount == 0
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
                snapshot: snapshot,
                // The client held this cursor, and a cursor is a recorder coordinate: it
                // reports nothing about the history the replica behind it actually holds.
                replicaHistoryIsComplete: false
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
                nextCursor: fence.retained.nextCursor,
                replicaHistoryIsComplete: false
            )
        }
    }
}

private func eventSelection(
    initial: PaneTapeDimensions,
    cursor: PaneTapeCursor,
    snapshot: PaneTapeSnapshot,
    replicaHistoryIsComplete: Bool
) -> PaneTapeOpeningSelection {
    PaneTapeOpeningSelection(
        initial: initial,
        publishedCursor: cursor,
        records: makePaneTapeBatch(from: snapshot).records,
        nextCursor: snapshot.nextCursor,
        replicaHistoryIsComplete: replicaHistoryIsComplete
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
        nextCursor: fence.synchronization.cursor,
        replicaHistoryIsComplete: fence.synchronization.droppedHistoryRows == 0
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
