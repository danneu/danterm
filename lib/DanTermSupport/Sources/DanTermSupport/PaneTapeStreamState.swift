// Pure pane-tape stream policy in two halves: it decides retained events or an atomic state
// sync from one owner fence, then builds the records for whichever it decided. Deciding never
// touches terminal state, so a stream that ships events never asks for state to be serialized.
// IPC request parsing and socket delivery stay outside this file.
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
///
/// Only the materialize phase holds one: it is what serializing the fenced terminal produces,
/// and the decide phase below runs entirely without it.
struct PaneTapeStateSynchronization: Equatable, Sendable {
    let bytes: [UInt8]
    let dimensions: PaneTapeDimensions
    /// How many retained history rows these bytes leave out, oldest first. A replica cannot
    /// derive it -- the bytes look the same whether the source had more history or not -- so
    /// the record has to state it.
    let droppedHistoryRows: Int
    let cursor: PaneTapeCursor
}

/// Gives stream policy every cheap value observed at one pane-owner fence.
///
/// The fenced terminal itself is deliberately absent: it stays an opaque handle in the app,
/// which resolves it only for a decision that asked for a synchronization.
struct PaneTapeStreamFence: Equatable, Sendable {
    let origin: PaneTapeOrigin
    /// Live geometry with the cursor past every event recorded before the fence, which is
    /// what an opening at the fenced moment publishes instead of replaying up to it.
    let live: PaneTapeOrigin
    let retained: PaneTapeSnapshot
    let requested: PaneTapeCursorPlacement
}

/// What a selected synchronization needs before it can become records: the exact-loss record
/// that precedes it, and the bound its retained history obeys.
///
/// The budget lives here and nowhere else below the request boundary, so a stream that ships
/// events has no place to carry one. `nil` means every retained row, which is what an exact
/// consumer such as `pane.snapshot` asks for.
struct PaneTapeSynchronizationRequirement: Equatable, Sendable {
    let loss: JSONValue?
    let historyBudgetBytes: Int?
}

/// The one answer to "ship these events" or "replace them with a synchronization".
///
/// Openings and continuations decide the same question against the same fence facts, so they
/// decide it in one type; only the metadata around an events answer differs between them.
enum PaneTapePayloadDecision<Events: Equatable & Sendable>: Equatable, Sendable {
    case events(Events)
    case synchronize(PaneTapeSynchronizationRequirement)
}

/// Everything an opening that ships recorder events publishes, decided without terminal state.
struct PaneTapeEventOpening: Equatable, Sendable {
    let initial: PaneTapeDimensions
    let publishedCursor: PaneTapeCursor
    let records: [JSONValue]
    let nextCursor: PaneTapeCursor
    let replicaHistoryIsComplete: Bool
}

/// One opening's answer, plus the start-record facts that hold either way.
struct PaneTapeOpeningDecision: Equatable, Sendable {
    let capture: PaneTapeCaptureMode
    let reconstructible: Bool
    let payload: PaneTapePayloadDecision<PaneTapeEventOpening>
}

/// One followed suffix that ships as the recorder events it is, with the history standing it
/// leaves the replica holding.
struct PaneTapeEventContinuation: Equatable, Sendable {
    let snapshot: PaneTapeSnapshot
    let replicaHistoryIsComplete: Bool
}

/// One continuation's answer. It needs no surrounding metadata: a followed suffix publishes no
/// start record.
typealias PaneTapeContinuationDecision = PaneTapePayloadDecision<PaneTapeEventContinuation>

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

/// Chooses what one followed suffix ships, replacing lost events with state in reconstructible
/// mode.
///
/// The same replacement covers a second case: a suffix that resizes cannot be replayed by a
/// replica whose history the stream truncated, so that suffix is replaced whole by a fresh
/// bounded sync at its ending cursor. No replaced event is also delivered, which is what keeps
/// the replica's grid exact instead of an argument about how far a reflow can reach.
func decidePaneTapeContinuation(
    policy: PaneTapeSyncPolicy,
    replicaHistoryIsComplete: Bool,
    snapshot: PaneTapeSnapshot
) -> PaneTapeContinuationDecision {
    if case .reconstructible(let historyBudgetBytes) = policy {
        if snapshot.droppedEventCount > 0 {
            return .synchronize(PaneTapeSynchronizationRequirement(
                loss: makePaneTapeExactGapRecord(snapshot),
                historyBudgetBytes: historyBudgetBytes
            ))
        }
        if replicaHistoryIsComplete == false,
           snapshot.events.contains(where: \.needsCompleteHistory)
        {
            return .synchronize(PaneTapeSynchronizationRequirement(
                loss: nil,
                historyBudgetBytes: historyBudgetBytes
            ))
        }
    }
    return .events(PaneTapeEventContinuation(
        snapshot: snapshot,
        replicaHistoryIsComplete: replicaHistoryIsComplete
    ))
}

/// Builds the suffix a continuation decided to ship as recorder events.
func makePaneTapeContinuation(events: PaneTapeEventContinuation) -> PaneTapeContinuation {
    PaneTapeContinuation(
        batch: makePaneTapeBatch(from: events.snapshot),
        replicaHistoryIsComplete: events.replicaHistoryIsComplete
    )
}

/// Builds the suffix a continuation decided to replace with state, from the synchronization
/// serialized for that requirement.
func makePaneTapeContinuation(
    requirement: PaneTapeSynchronizationRequirement,
    synchronization: PaneTapeStateSynchronization
) -> PaneTapeContinuation {
    PaneTapeContinuation(
        batch: PaneTapeBatch(
            records: (requirement.loss.map { [$0] } ?? [])
                + makePaneTapeSynchronizationRecords(synchronization),
            nextCursor: synchronization.cursor
        ),
        // Only the encode knows how much history fit, and the next fetch decides the resize
        // question from it, so the materialized suffix is what carries the standing forward.
        replicaHistoryIsComplete: synchronization.droppedHistoryRows == 0
    )
}

/// Applies the reconstructibility rule to one opening without IO or terminal state.
func decidePaneTapeOpening(
    request: PaneTapeStreamRequest,
    fence: PaneTapeStreamFence
) -> PaneTapeOpeningDecision {
    PaneTapeOpeningDecision(
        capture: request.capture,
        reconstructible: request.policy.mode == .reconstructible,
        payload: selectPaneTapeOpeningPayload(request: request, fence: fence)
    )
}

/// Builds the opening an events decision selected.
func makePaneTapeOpening(
    _ decision: PaneTapeOpeningDecision,
    events: PaneTapeEventOpening,
    provenance: JSONValue = defaultPaneTapeProvenance
) -> PaneTapeOpening {
    PaneTapeOpening(
        start: makePaneTapeStart(
            capture: decision.capture,
            provenance: provenance,
            initial: events.initial,
            cursor: events.publishedCursor,
            publishesCursor: true,
            reconstructible: decision.reconstructible
        ),
        records: events.records,
        nextCursor: events.nextCursor,
        replicaHistoryIsComplete: events.replicaHistoryIsComplete
    )
}

/// Builds the opening a synchronization decision selected, from the state serialized for that
/// requirement.
func makePaneTapeOpening(
    _ decision: PaneTapeOpeningDecision,
    requirement: PaneTapeSynchronizationRequirement,
    synchronization: PaneTapeStateSynchronization,
    provenance: JSONValue = defaultPaneTapeProvenance
) -> PaneTapeOpening {
    PaneTapeOpening(
        start: makePaneTapeStart(
            capture: decision.capture,
            provenance: provenance,
            initial: synchronization.dimensions,
            // The sync record carries the continuation cursor itself, so the start record
            // stating one too would publish the same position twice.
            cursor: synchronization.cursor,
            publishesCursor: false,
            reconstructible: decision.reconstructible
        ),
        records: (requirement.loss.map { [$0] } ?? [])
            + makePaneTapeSynchronizationRecords(synchronization),
        nextCursor: synchronization.cursor,
        replicaHistoryIsComplete: synchronization.droppedHistoryRows == 0
    )
}

/// What a stream states about where its records came from when no caller names something else.
let defaultPaneTapeProvenance = JSONValue.object(["source": .string("danterm-live-capture")])

/// Splits the opening decision by policy case, so a raw stream never has a history budget in
/// scope and never has a branch that could ask for a synchronization.
private func selectPaneTapeOpeningPayload(
    request: PaneTapeStreamRequest,
    fence: PaneTapeStreamFence
) -> PaneTapePayloadDecision<PaneTapeEventOpening> {
    switch request.policy {
    case .raw:
        return .events(rawOpening(position: request.position, fence: fence))
    case .reconstructible(let historyBudgetBytes):
        return reconstructibleOpening(
            position: request.position,
            fence: fence,
            historyBudgetBytes: historyBudgetBytes
        )
    }
}

/// A raw stream preserves recorder evidence and synthesizes nothing, so every start position
/// answers with records the fence already holds. Its return type says so.
private func rawOpening(
    position: PaneTapeStartPosition,
    fence: PaneTapeStreamFence
) -> PaneTapeEventOpening {
    switch position {
    case .now:
        return PaneTapeEventOpening(
            initial: fence.live.initial,
            publishedCursor: fence.live.cursor,
            records: [],
            nextCursor: fence.live.cursor,
            replicaHistoryIsComplete: false
        )

    case .beginning:
        return eventOpening(
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
            return eventOpening(
                initial: fence.origin.initial,
                cursor: cursor,
                snapshot: snapshot,
                // The client held this cursor, and a cursor is a recorder coordinate: it
                // reports nothing about the history the replica behind it actually holds.
                replicaHistoryIsComplete: false
            )
        case .unplaceable:
            return PaneTapeEventOpening(
                initial: fence.origin.initial,
                publishedCursor: retainedHeadCursor(
                    origin: fence.origin.cursor,
                    snapshot: fence.retained
                ),
                records: [makePaneTapeTotalGapRecord()]
                    + fence.retained.events.map(makePaneTapeEventRecord),
                nextCursor: fence.retained.nextCursor,
                replicaHistoryIsComplete: false
            )
        }
    }
}

/// A reconstructible stream may replace evidence it cannot deliver with terminal state, so
/// this is the only place a synchronization requirement -- and a budget -- is minted.
private func reconstructibleOpening(
    position: PaneTapeStartPosition,
    fence: PaneTapeStreamFence,
    historyBudgetBytes: Int?
) -> PaneTapePayloadDecision<PaneTapeEventOpening> {
    func synchronize(loss: JSONValue?) -> PaneTapePayloadDecision<PaneTapeEventOpening> {
        .synchronize(PaneTapeSynchronizationRequirement(
            loss: loss,
            historyBudgetBytes: historyBudgetBytes
        ))
    }

    switch position {
    case .now:
        return synchronize(loss: nil)

    case .beginning:
        guard fence.retained.droppedEventCount == 0 else {
            return synchronize(loss: makePaneTapeExactGapRecord(fence.retained))
        }
        return .events(eventOpening(
            initial: fence.origin.initial,
            cursor: fence.origin.cursor,
            snapshot: fence.retained,
            // Replayed from the recorder's own beginning with nothing evicted: the replica
            // built every history row the source has.
            replicaHistoryIsComplete: true
        ))

    case .cursor(let cursor):
        switch fence.requested {
        case .placed(let snapshot):
            guard snapshot.droppedEventCount == 0 else {
                return synchronize(loss: makePaneTapeExactGapRecord(snapshot))
            }
            return .events(eventOpening(
                initial: fence.origin.initial,
                cursor: cursor,
                snapshot: snapshot,
                // The client held this cursor, and a cursor is a recorder coordinate: it
                // reports nothing about the history the replica behind it actually holds.
                replicaHistoryIsComplete: false
            ))
        case .unplaceable:
            return synchronize(loss: makePaneTapeTotalGapRecord())
        }
    }
}

private func eventOpening(
    initial: PaneTapeDimensions,
    cursor: PaneTapeCursor,
    snapshot: PaneTapeSnapshot,
    replicaHistoryIsComplete: Bool
) -> PaneTapeEventOpening {
    PaneTapeEventOpening(
        initial: initial,
        publishedCursor: cursor,
        records: makePaneTapeBatch(from: snapshot).records,
        nextCursor: snapshot.nextCursor,
        replicaHistoryIsComplete: replicaHistoryIsComplete
    )
}

private func makePaneTapeTotalGapRecord() -> JSONValue {
    encodePaneTapeRecord(.gap(.total))
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
        // The transfer's whole-state facts ride the first part, and the position it leaves the
        // reader at rides the last, so a single-part transfer carries both.
        let isFirst = index == chunks.startIndex
        let isLast = index == chunks.index(before: chunks.endIndex)
        return encodePaneTapeRecord(.sync(PaneTapeSyncRecord(
            part: index + 1,
            parts: chunks.count,
            bytes: bytes,
            transfer: isFirst
                ? PaneTapeSyncRecord.Transfer(
                    columns: synchronization.dimensions.columns,
                    rows: synchronization.dimensions.rows,
                    pinned: synchronization.dimensions.pinned,
                    droppedHistoryRows: synchronization.droppedHistoryRows
                )
                : nil,
            cursor: isLast ? synchronization.cursor : nil
        )))
    }
}
