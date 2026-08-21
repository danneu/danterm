// The reader's side of the pane-tape stream: assembling a multi-part state transfer out of the
// records a stream delivers. The record shape itself -- its keys, its typed family, and its
// decode -- and the notification envelope that carries it are declared once in DanTermProtocol,
// so nothing here spells a wire key.
import Foundation
import DanTermProtocol

/// The complete state transfer a reader may apply atomically at its continuation cursor.
public struct PaneTapeStateSynchronization: Equatable, Sendable {
    /// Carries the complete terminal-state byte stream, in the one buffer the assembler
    /// accumulated the parts into.
    public let bytes: Data
    /// Gives the width at which the state must be applied.
    public let columns: Int
    /// Gives the height at which the state must be applied.
    public let rows: Int
    /// States whether the replaced pane's grid is pinned. A sync replaces a replica outright,
    /// so it restates the whole geometry fact rather than leaving pinnedness to nearby events.
    public let pinned: Bool
    /// How many of the source's retained history rows this transfer leaves out, oldest first;
    /// `0` when it carries the whole retained history. A replica reads it to know whether its
    /// own history is complete.
    public let droppedHistoryRows: Int
    /// The effective terminal focus the source held at the fence. A replica seeds it before
    /// applying `bytes`, because focus is retained terminal state the bytes cannot restate.
    public let focused: Bool
    /// Names the first recorder event after this state.
    public let cursor: PaneTapeCursor

    /// Creates one complete state replacement.
    public init(
        bytes: Data,
        columns: Int,
        rows: Int,
        pinned: Bool,
        droppedHistoryRows: Int,
        focused: Bool,
        cursor: PaneTapeCursor
    ) {
        self.bytes = bytes
        self.columns = columns
        self.rows = rows
        self.pinned = pinned
        self.droppedHistoryRows = droppedHistoryRows
        self.focused = focused
        self.cursor = cursor
    }
}

/// Buffers one synchronization transfer and publishes state only when every part is complete.
public struct PaneTapeSyncAssembler: Sendable {
    private var expectedPart = 1
    private var expectedCount: Int?
    private var bytes = Data()
    private var transfer: PaneTapeSyncRecord.Transfer?

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
            guard let transfer = record.transfer else {
                reset()
                return nil
            }
            expectedCount = record.parts
            self.transfer = transfer
        } else if record.transfer != nil {
            reset()
            return nil
        }
        bytes.append(record.bytes)
        expectedPart += 1
        guard record.part == record.parts else {
            if record.cursor != nil { reset() }
            return nil
        }
        guard let cursor = record.cursor, let transfer else {
            reset()
            return nil
        }
        let synchronization = PaneTapeStateSynchronization(
            bytes: bytes,
            columns: transfer.columns,
            rows: transfer.rows,
            pinned: transfer.pinned,
            droppedHistoryRows: transfer.droppedHistoryRows,
            focused: transfer.focused,
            cursor: cursor
        )
        reset()
        return synchronization
    }

    private mutating func reset() {
        expectedPart = 1
        expectedCount = nil
        bytes.removeAll(keepingCapacity: true)
        transfer = nil
    }
}
