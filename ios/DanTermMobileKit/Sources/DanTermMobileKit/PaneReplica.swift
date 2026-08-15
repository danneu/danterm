// Owns exact-or-explicit-gap application of pane-tape records to a headless terminal replica.
import DanTermClient
import DanTermProtocol
import Foundation
import TerminalCore
import TerminalCoreRecording

/// States whether the visible replica is exact or frozen behind an explicit loss report.
public enum PaneReplicaState: Equatable, Sendable {
    case awaitingSynchronization
    case exact
    case gap(PaneTapeGapRecord.Loss)
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

    private var syncAssembler = PaneTapeSyncAssembler()
    private var interactionState = TerminalInteractionState()

    /// Creates an empty replica that cannot present until exact state arrives.
    public init() {}

    /// Applies one decoded record while keeping incomplete synchronization invisible.
    public mutating func apply(_ record: PaneTapeRecord) throws {
        switch record {
        case .start(let start):
            try applyStart(start)
        case .gap(let gap):
            state = .gap(gap.loss)
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

    private mutating func applyStart(_ start: PaneTapeStartRecord) throws {
        guard start.columns >= 2, start.rows >= 1 else {
            throw PaneReplicaError.invalidGeometry(columns: start.columns, rows: start.rows)
        }
        guard let startCursor = start.cursor else {
            if terminal == nil { state = .awaitingSynchronization }
            return
        }
        if terminal != nil, cursor != startCursor {
            state = .gap(.total)
            syncAssembler = PaneTapeSyncAssembler()
            return
        }
        if terminal == nil {
            guard let fresh = Terminal(columns: start.columns, rows: start.rows) else {
                throw PaneReplicaError.invalidGeometry(columns: start.columns, rows: start.rows)
            }
            terminal = fresh
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
        state = .exact
        interactionState = TerminalInteractionState()
    }

    private mutating func applyEvent(_ record: PaneTapeEventRecord) throws {
        guard state == .exact, var terminal, let cursor else { return }
        guard record.sequence == cursor.nextSequence else {
            state = .gap(.total)
            syncAssembler = PaneTapeSyncAssembler()
            return
        }
        let data = try JSONEncoder().encode(record.event)
        guard let event = try? JSONDecoder().decode(
            NeutralTerminalRecordingEvent.self,
            from: data
        ) else { throw PaneReplicaError.invalidEvent }

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
        case .resize(let columns, let rows):
            guard columns >= 2, rows >= 1 else {
                state = .gap(.total)
                syncAssembler = PaneTapeSyncAssembler()
                return
            }
            terminal.resize(columns: columns, rows: rows)
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
            state = .gap(.total)
            syncAssembler = PaneTapeSyncAssembler()
            return
        }
        self.terminal = terminal
        self.cursor = nextCursor
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
