// Owns exact-or-gap application of pane-tape records to a headless terminal replica.
import DanTermClient
import DanTermProtocol
import Foundation
import TerminalCore
import TerminalCoreRecording

/// Says who found the gap, because that alone decides what can repair it.
///
/// A declared gap is the producer's own loss report. The subscription runs in
/// reconstructible mode, so the replacement sync is already in the stream a few records
/// behind it and waiting is the whole remedy. A detected gap is the replica's finding that
/// what arrived disagrees with what it holds: the producer believes the stream is healthy
/// and will send no further sync, so only a fresh subscription reconciles the two.
public enum PaneReplicaGap: Equatable, Sendable {
    case declared(PaneTapeGapRecord.Loss)
    case detected
}

/// States whether the visible replica is exact or frozen behind a gap.
public enum PaneReplicaState: Equatable, Sendable {
    case awaitingSynchronization
    case exact
    case gap(PaneReplicaGap)
}

/// Rejects malformed stream events before they can weaken the replica's exactness claim.
public enum PaneReplicaError: Error, Equatable, Sendable {
    case invalidEvent
    case invalidGeometry(columns: Int, rows: Int)
}

/// Applies one pane's recorder stream without ever producing authoritative terminal output.
public struct PaneReplica: Sendable {
    public private(set) var terminal: Terminal?
    public private(set) var cursor: PaneTapeCursor?
    public private(set) var state = PaneReplicaState.awaitingSynchronization

    /// States whether the replicated grid is pinned -- an override a client claimed rather
    /// than a projection of the pane's rectangle -- at the replica's own cursor.
    ///
    /// Nothing whenever the replica is not exact: behind a gap the held bit describes a
    /// position the producer has already left, and a caller offering a release from it
    /// would act on a claim that may no longer exist.
    public var pinned: Bool? { state == .exact ? heldPinned : nil }

    private var heldPinned: Bool?
    private var syncAssembler = PaneTapeSyncAssembler()
    private var interactionState = TerminalInteractionState()

    /// Creates an empty replica that cannot present until exact state arrives.
    public init() {}

    /// Restores exact terminal state before a resumed stream starts at the checkpoint cursor.
    public init(checkpoint: PaneReplicaCheckpoint, for paneId: PaneId) throws {
        try checkpoint.validate(for: paneId)
        guard var terminal = Terminal(columns: checkpoint.columns, rows: checkpoint.rows) else {
            throw PaneReplicaCheckpointError.invalidGeometry(
                columns: checkpoint.columns,
                rows: checkpoint.rows
            )
        }
        terminal.feed(checkpoint.stateBytes)
        discardAuthority(from: &terminal)
        self.terminal = terminal
        cursor = checkpoint.cursor
        heldPinned = checkpoint.pinned
        state = .exact
    }

    /// Synthesizes one bounded state-and-cursor fence without retaining event history.
    public func checkpoint(for paneId: PaneId) -> PaneReplicaCheckpoint? {
        guard let terminal, let cursor, let heldPinned else { return nil }
        let synchronization = terminal.stateSynchronization
        return PaneReplicaCheckpoint(
            stateBytes: synchronization.bytes,
            columns: synchronization.columns,
            rows: synchronization.rows,
            pinned: heldPinned,
            paneId: paneId,
            cursor: cursor
        )
    }

    /// Applies one decoded record while keeping incomplete synchronization invisible.
    public mutating func apply(_ record: PaneTapeRecord) throws {
        switch record {
        case .start(let start):
            try applyStart(start)
        case .gap(let gap):
            state = .gap(.declared(gap.loss))
            syncAssembler = PaneTapeSyncAssembler()
        case .sync(let part):
            guard let synchronization = syncAssembler.ingest(part) else { return }
            try replace(with: synchronization)
        case .event(let record):
            try applyEvent(record)
        case .end, .unknown:
            break
        }
    }

    /// Moves only the replicated primary-screen viewport for local phone scrolling.
    public mutating func scrollViewport(byRows rows: Int) {
        guard state == .exact, terminal?.isAlternateScreenActive == false else { return }
        terminal?.scroll(byRows: rows)
    }

    /// Puts an absolute row at the top of the replicated primary-screen window, which is
    /// what the phone's scroll chrome names once it can project the whole stream.
    ///
    /// Clamping and the return to following are the engine's: a request that lands on the
    /// last complete window is how pinned-to-bottom comes back, with no flag kept here.
    public mutating func scrollViewport(toTopRow row: Int) {
        guard state == .exact, terminal?.isAlternateScreenActive == false else { return }
        terminal?.scroll(toTopRow: row)
    }

    /// Drains engine damage while returning the exact terminal snapshot to present.
    public mutating func drainPresentation() -> (terminal: Terminal, damage: TerminalDamage)? {
        guard state == .exact, var terminal else { return nil }
        let damage = terminal.drainDamage()
        self.terminal = terminal
        return (terminal, damage)
    }

    private mutating func applyStart(_ start: PaneTapeStartRecord) throws {
        guard start.columns >= 2, start.rows >= 1 else {
            throw PaneReplicaError.invalidGeometry(columns: start.columns, rows: start.rows)
        }
        guard let startCursor = start.cursor else {
            if terminal == nil { state = .awaitingSynchronization }
            return
        }
        if terminal != nil, cursor != startCursor {
            state = .gap(.detected)
            syncAssembler = PaneTapeSyncAssembler()
            return
        }
        guard terminal != nil else {
            state = .gap(.detected)
            return
        }
        cursor = startCursor
        state = .exact
    }

    private mutating func replace(with synchronization: PaneTapeStateSynchronization) throws {
        guard var replacement = Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ) else {
            throw PaneReplicaError.invalidGeometry(
                columns: synchronization.columns,
                rows: synchronization.rows
            )
        }
        replacement.feed(synchronization.bytes)
        discardAuthority(from: &replacement)
        terminal = replacement
        cursor = synchronization.cursor
        heldPinned = synchronization.pinned
        state = .exact
        interactionState = TerminalInteractionState()
    }

    private mutating func applyEvent(_ record: PaneTapeEventRecord) throws {
        guard state == .exact, var terminal, let cursor else { return }
        guard record.sequence == cursor.nextSequence else {
            state = .gap(.detected)
            syncAssembler = PaneTapeSyncAssembler()
            return
        }
        let data = try JSONEncoder().encode(record.event)
        guard let event = try? JSONDecoder().decode(
            NeutralTerminalRecordingEvent.self,
            from: data
        ) else { throw PaneReplicaError.invalidEvent }

        var appliedPinned = heldPinned
        switch event {
        case .feed(let bytes):
            terminal.feed(bytes)
            discardAuthority(from: &terminal)
        case .mouse(let mouse):
            _ = applyNeutralTerminalMouse(
                mouse,
                terminal: &terminal,
                interactionState: &interactionState
            )
            discardAuthority(from: &terminal)
        // The producer states geometry whole, so the grid and its pinnedness apply together.
        // A pinnedness-only event repeats the grid the replica already holds; the engine
        // resize is then a no-op and the bit is what moves.
        case .resize(let columns, let rows, let pinned):
            guard columns >= 2, rows >= 1 else {
                state = .gap(.detected)
                syncAssembler = PaneTapeSyncAssembler()
                return
            }
            terminal.resize(columns: columns, rows: rows)
            appliedPinned = pinned
        case .viewport(let navigation):
            switch navigation {
            case .byRows(let rows): terminal.scroll(byRows: rows)
            case .toTopRow(let row): terminal.scroll(toTopRow: row)
            case .toBottom: terminal.scrollToBottom()
            }
        case .write, .input, .paste, .focus, .checkpoint:
            break
        }

        guard let nextCursor = advancedCursor(from: cursor, record: record, event: event) else {
            state = .gap(.detected)
            syncAssembler = PaneTapeSyncAssembler()
            return
        }
        self.terminal = terminal
        self.cursor = nextCursor
        heldPinned = appliedPinned
    }

    private func advancedCursor(
        from cursor: PaneTapeCursor,
        record: PaneTapeEventRecord,
        event: NeutralTerminalRecordingEvent
    ) -> PaneTapeCursor? {
        var feed = cursor.feedBytesBeforeNextSequence
        var write = cursor.writeBytesBeforeNextSequence
        switch event {
        case .feed(let bytes):
            guard let offset = record.byteOffset,
                  let length = record.byteLength,
                  length == bytes.count,
                  offset == feed,
                  record.originElapsedNanoseconds == nil,
                  let end = byteEnd(offset: offset, length: length)
            else { return nil }
            feed = end
        case .write(let bytes):
            guard let offset = record.byteOffset,
                  let length = record.byteLength,
                  length == bytes.count,
                  offset == write,
                  let end = byteEnd(offset: offset, length: length)
            else { return nil }
            write = end
        default:
            guard record.byteOffset == nil,
                  record.byteLength == nil,
                  record.originElapsedNanoseconds == nil
            else { return nil }
        }
        let nextSequence = record.sequence.addingReportingOverflow(1)
        guard nextSequence.overflow == false else { return nil }
        return PaneTapeCursor(
            recorderLifetimeId: cursor.recorderLifetimeId,
            nextSequence: nextSequence.partialValue,
            feedBytesBeforeNextSequence: feed,
            writeBytesBeforeNextSequence: write
        )
    }
}

private func byteEnd(offset: Int, length: Int) -> Int? {
    let end = offset.addingReportingOverflow(length)
    return end.overflow ? nil : end.partialValue
}

private func discardAuthority(from terminal: inout Terminal) {
    _ = terminal.drainReplyBytes()
    _ = terminal.drainPendingClipboardWrite()
    _ = terminal.drainSemanticEvents()
}
