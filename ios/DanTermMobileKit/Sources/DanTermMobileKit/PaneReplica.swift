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

/// Persists enough exact replica evidence to continue from its cursor after relaunch.
public struct PaneReplicaArchive: Codable, Equatable, Sendable {
    /// Carries the last complete state synchronization as the restore baseline.
    public private(set) var synchronizationBytes: [UInt8]
    /// Gives the baseline terminal width.
    public private(set) var columns: Int
    /// Gives the baseline terminal height.
    public private(set) var rows: Int
    /// Carries owner-ordered events applied after the baseline synchronization.
    public private(set) var events: [NeutralTerminalRecordingEvent]
    /// Identifies the recorder lifetime that produced the continuation cursor.
    public private(set) var recorderLifetimeId: UUID
    /// Names the next recorder event needed after archive restoration.
    public private(set) var nextSequence: UInt64
    /// Gives the feed-byte offset at the continuation cursor.
    public private(set) var feedBytesBeforeNextSequence: Int
    /// Gives the write-byte offset at the continuation cursor.
    public private(set) var writeBytesBeforeNextSequence: Int

    /// Names the first recorder event after this archived exact state.
    public var cursor: PaneTapeCursor {
        PaneTapeCursor(
            recorderLifetimeId: recorderLifetimeId,
            nextSequence: nextSequence,
            feedBytesBeforeNextSequence: feedBytesBeforeNextSequence,
            writeBytesBeforeNextSequence: writeBytesBeforeNextSequence
        )
    }

    fileprivate mutating func append(
        _ event: NeutralTerminalRecordingEvent,
        cursor: PaneTapeCursor
    ) {
        events.append(event)
        recorderLifetimeId = cursor.recorderLifetimeId
        nextSequence = cursor.nextSequence
        feedBytesBeforeNextSequence = cursor.feedBytesBeforeNextSequence
        writeBytesBeforeNextSequence = cursor.writeBytesBeforeNextSequence
    }
}

/// Applies one pane's recorder stream without ever producing authoritative terminal output.
public struct PaneReplica: Sendable {
    public private(set) var terminal: Terminal?
    public private(set) var cursor: PaneTapeCursor?
    public private(set) var state = PaneReplicaState.awaitingSynchronization
    /// Preserves the last exact state and cursor for process-dead continuation.
    public private(set) var archive: PaneReplicaArchive?

    private var syncAssembler = PaneTapeSyncAssembler()
    private var interactionState = TerminalInteractionState()

    /// Creates an empty replica that cannot present until exact state arrives.
    public init() {}

    /// Restores exact terminal state before a resumed stream starts at the archived cursor.
    public init(archive: PaneReplicaArchive) throws {
        guard archive.feedBytesBeforeNextSequence >= 0,
              archive.writeBytesBeforeNextSequence >= 0,
              var terminal = Terminal(columns: archive.columns, rows: archive.rows)
        else {
            throw PaneReplicaError.invalidGeometry(columns: archive.columns, rows: archive.rows)
        }
        terminal.feed(archive.synchronizationBytes)
        discardAuthority(from: &terminal)
        var interactionState = TerminalInteractionState()
        for event in archive.events {
            try replay(event, terminal: &terminal, interactionState: &interactionState)
        }
        self.terminal = terminal
        cursor = archive.cursor
        state = .exact
        self.archive = archive
        self.interactionState = interactionState
    }

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

    /// Moves only the replicated primary-screen viewport for local phone scrolling.
    public mutating func scrollViewport(byRows rows: Int) {
        guard state == .exact, terminal?.isAlternateScreenActive == false else { return }
        terminal?.scroll(byRows: rows)
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
            state = .gap(.total)
            syncAssembler = PaneTapeSyncAssembler()
            return
        }
        guard terminal != nil else {
            state = .gap(.total)
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
        state = .exact
        interactionState = TerminalInteractionState()
        archive = PaneReplicaArchive(
            synchronizationBytes: synchronization.bytes,
            columns: synchronization.columns,
            rows: synchronization.rows,
            events: [],
            recorderLifetimeId: synchronization.cursor.recorderLifetimeId,
            nextSequence: synchronization.cursor.nextSequence,
            feedBytesBeforeNextSequence: synchronization.cursor.feedBytesBeforeNextSequence,
            writeBytesBeforeNextSequence: synchronization.cursor.writeBytesBeforeNextSequence
        )
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
        archive?.append(event, cursor: nextCursor)
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

private func replay(
    _ event: NeutralTerminalRecordingEvent,
    terminal: inout Terminal,
    interactionState: inout TerminalInteractionState
) throws {
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
            throw PaneReplicaError.invalidGeometry(columns: columns, rows: rows)
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
