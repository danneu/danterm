// Behavioral proofs for bounded replica checkpoints, exact restore, and total rejection.
import DanTermClient
@testable import DanTermMobileKit
import DanTermProtocol
import Foundation
import TerminalCore
import TerminalCoreRecording
import Testing

/// Exercises checkpoint behavior without depending on UIKit or private replica storage.
struct PaneReplicaCheckpointTests {
    private let paneId = PaneId(rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)

    @Test("different event histories produce the same checkpoint at the same state and cursor")
    func checkpointDependsOnCurrentStateRatherThanHistory() throws {
        // Intent: make the continuation record a pure function of retained state and cursor.
        // Why it exists: an event suffix grows with the path taken to the current state.
        // Scenario: one replica receives "AB" in one event while another receives it in two.
        var short = try checkpointReplica(bytes: [], cursor: checkpointCursor(sequence: 1))
        try short.apply(try checkpointEvent(
            sequence: 1,
            byteOffset: 0,
            byteLength: 2,
            event: .feed(Array("AB".utf8))
        ))

        var long = try checkpointReplica(bytes: [], cursor: checkpointCursor(sequence: 0))
        try long.apply(try checkpointEvent(
            sequence: 0,
            byteOffset: 0,
            byteLength: 1,
            event: .feed(Array("A".utf8))
        ))
        try long.apply(try checkpointEvent(
            sequence: 1,
            byteOffset: 1,
            byteLength: 1,
            event: .feed(Array("B".utf8))
        ))

        #expect(short.checkpoint(for: paneId) == long.checkpoint(for: paneId))
    }

    @Test("checkpoint size plateaus under continuing grapheme churn")
    func checkpointSizeStopsGrowingWithDroppedScalars() throws {
        // Intent: carry TerminalCore's grapheme bound through replica checkpoint synthesis.
        // Why it exists: one never-ending cluster used to grow every saved continuation record.
        // Scenario: checkpoints are compared before and after thousands of dropped joiners.
        let mark = "\u{0301}"
        let admitted = String(
            repeating: mark,
            count: (Terminal.graphemeClusterByteLimit - 1) / mark.utf8.count
        )
        var replica = try checkpointReplica(
            bytes: Array(("A" + admitted).utf8),
            cursor: checkpointCursor(sequence: 1, feed: Terminal.graphemeClusterByteLimit)
        )
        let atLimit = try #require(replica.checkpoint(for: paneId))

        let overflow = Array(String(repeating: mark, count: 4_096).utf8)
        try replica.apply(try checkpointEvent(
            sequence: 1,
            byteOffset: Terminal.graphemeClusterByteLimit,
            byteLength: overflow.count,
            event: .feed(overflow)
        ))
        let flooded = try #require(replica.checkpoint(for: paneId))

        #expect(flooded.stateBytes == atLimit.stateBytes)
        #expect(try flooded.encoded().count == atLimit.encoded().count)
    }

    @Test("checkpoint state plateaus after retained scrollback saturates")
    func checkpointStopsGrowingAfterScrollbackSaturates() throws {
        // Intent: make checkpoint size independent of event churn after retained history is full.
        // Why it exists: deleting the suffix is useful only if old events really leave the record.
        // Scenario: a replica starts beyond the engine budget, then receives more identical rows.
        let columns = 1_024
        let line = String(repeating: "x", count: columns - 2) + "\r\n"
        let baselineLineCount = Terminal.scrollbackByteLimit / line.utf8.count + 128
        let baseline = Array(String(repeating: line, count: baselineLineCount).utf8)
        var replica = try checkpointReplica(
            bytes: baseline,
            cursor: checkpointCursor(sequence: 1, feed: baseline.count),
            columns: columns,
            rows: 2
        )
        let saturated = try #require(replica.checkpoint(for: paneId))

        let churn = Array(String(repeating: line, count: 128).utf8)
        try replica.apply(try checkpointEvent(
            sequence: 1,
            byteOffset: baseline.count,
            byteLength: churn.count,
            event: .feed(churn)
        ))
        let churned = try #require(replica.checkpoint(for: paneId))

        #expect(churned.stateBytes == saturated.stateBytes)
        #expect(try churned.encoded().count == saturated.encoded().count)
    }

    @Test("checkpoint restore preserves serialized terminal state across a split sequence")
    func restoreAndContinuationMatchOriginal() throws {
        // Intent: restore all engine-owned state and continue from the paired cursor exactly once.
        // Why it exists: visible text cannot prove parser, wrap, screen, mode, or history state.
        // Scenario: history and an alternate screen coexist while a CSI is split at the fence.
        let prefix = Array("1\r\n2\r\n3\u{1B}[?1h\u{1B}[?2004h\u{1B}[?1049hALT\u{1B}[".utf8)
        var original = try checkpointReplica(
            bytes: prefix,
            cursor: checkpointCursor(sequence: 4, feed: prefix.count),
            columns: 8,
            rows: 2
        )
        let captured = try #require(original.checkpoint(for: paneId))
        let persisted = try PaneReplicaCheckpoint.decode(captured.encoded())
        var restored = try PaneReplica(checkpoint: persisted, for: paneId)

        let continuation = Array("31mZ".utf8)
        let event = try checkpointEvent(
            sequence: 4,
            byteOffset: prefix.count,
            byteLength: continuation.count,
            event: .feed(continuation)
        )
        try original.apply(event)
        try restored.apply(event)

        #expect(restored.cursor == original.cursor)
        #expect(restored.terminal?.stateSynchronization == original.terminal?.stateSynchronization)
        #expect(restored.terminal?.isAlternateScreenActive == true)
        #expect(restored.terminal?.inputModes.applicationCursorKeys == true)
        #expect(restored.terminal?.inputModes.bracketedPaste == true)
        #expect((restored.terminal?.scrollbackRowCount ?? 0) > 0)
    }

    @Test("checkpoint restore preserves pending autowrap")
    func restoreContinuesFromPendingAutowrap() throws {
        // Intent: preserve the deferred wrap that controls where the next printable scalar lands.
        // Why it exists: a full last column looks correct before restore but diverges on next input.
        // Scenario: a four-column row is full at the checkpoint fence, then both replicas print E.
        let prefix = Array("ABCD".utf8)
        var original = try checkpointReplica(
            bytes: prefix,
            cursor: checkpointCursor(sequence: 1, feed: prefix.count),
            columns: 4,
            rows: 2
        )
        var restored = try PaneReplica(
            checkpoint: #require(original.checkpoint(for: paneId)),
            for: paneId
        )
        let continuation = try checkpointEvent(
            sequence: 1,
            byteOffset: prefix.count,
            byteLength: 1,
            event: .feed(Array("E".utf8))
        )

        try original.apply(continuation)
        try restored.apply(continuation)

        #expect(restored.terminal?.stateSynchronization == original.terminal?.stateSynchronization)
        #expect(restored.terminal?.cell(row: 1, column: 0)?.scalars == TerminalScalars("E".unicodeScalars))
    }

    @Test("checkpoint restore starts with fresh interaction state")
    func restoreDropsGestureStateAndAcceptsNextGesture() throws {
        // Intent: give checkpoint restore the same fresh interaction state as a server sync.
        // Why it exists: transient pointer ownership is not part of authoritative terminal bytes.
        // Scenario: restore happens after mouse-down, then a complete new selection succeeds.
        var original = try checkpointReplica(
            bytes: Array("abcd".utf8),
            cursor: checkpointCursor(sequence: 1),
            columns: 8,
            rows: 2
        )
        try original.apply(try checkpointEvent(
            sequence: 1,
            event: .mouse(.init(action: .down, button: 1, column: 0, row: 0))
        ))
        let checkpoint = try #require(original.checkpoint(for: paneId))
        var restored = try PaneReplica(checkpoint: checkpoint, for: paneId)
        var syncFresh = try checkpointReplica(
            bytes: checkpoint.stateBytes,
            cursor: checkpoint.cursor,
            columns: checkpoint.columns,
            rows: checkpoint.rows
        )

        #expect(restored.terminal?.selectedText == nil)
        for (sequence, mouse) in [
            (2, NeutralTerminalMouseEvent(action: .down, button: 1, column: 1, row: 0)),
            (3, NeutralTerminalMouseEvent(action: .move, column: 3, row: 0)),
            (4, NeutralTerminalMouseEvent(action: .up, button: 1, column: 3, row: 0)),
        ] {
            let event = try checkpointEvent(sequence: UInt64(sequence), event: .mouse(mouse))
            try restored.apply(event)
            try syncFresh.apply(event)
        }
        #expect(restored.terminal?.selectedText == "bc")
        #expect(restored.terminal?.selectedText == syncFresh.terminal?.selectedText)
        #expect(restored.terminal?.stateSynchronization == syncFresh.terminal?.stateSynchronization)
    }

    @Test("partial sync and gap checkpoints stay at the last exact fence")
    func incompleteStateCannotLeakIntoCheckpoint() throws {
        // Intent: pair state and cursor only at a complete exact fence.
        // Why it exists: a partial replacement paired with an old or future cursor is unrecoverable.
        // Scenario: capture during a multipart sync and again after an explicit gap.
        var replica = try checkpointReplica(
            bytes: Array("old".utf8),
            cursor: checkpointCursor(sequence: 1, feed: 3)
        )
        let exact = replica.checkpoint(for: paneId)
        try replica.apply(.sync(.init(
            part: 1,
            parts: 2,
            bytes: Array("new".utf8),
            columns: 8,
            rows: 2,
            cursor: nil
        )))
        #expect(replica.checkpoint(for: paneId) == exact)

        try replica.apply(.gap(.total))
        #expect(replica.checkpoint(for: paneId) == exact)
    }

    @Test("every still-decodable envelope-field mutation fails integrity", arguments: [
        "stateBytes", "columns", "rows", "paneId", "recorderLifetimeId",
        "nextSequence", "feedBytesBeforeNextSequence", "writeBytesBeforeNextSequence",
        "formatVersion", "integrity",
    ])
    func envelopeMutationIsRejected(key: String) throws {
        let replica = try checkpointReplica(
            bytes: Array("safe".utf8),
            cursor: checkpointCursor(sequence: 7, feed: 4, write: 2)
        )
        let checkpoint = try #require(replica.checkpoint(for: paneId))
        let corrupted = try mutateCheckpointField(in: checkpoint.encoded(), key: key)

        #expect(throws: PaneReplicaCheckpointError.integrityMismatch) {
            try PaneReplicaCheckpoint.decode(corrupted)
        }
    }

    @Test("version, pane, and geometry mismatches are rejected before restore")
    func validButUnusableCheckpointIsRejected() throws {
        let cursor = checkpointCursor(sequence: 1)
        let state = Array("safe".utf8)
        let wrongVersion = PaneReplicaCheckpoint(
            stateBytes: state,
            columns: 8,
            rows: 2,
            paneId: paneId,
            cursor: cursor,
            formatVersion: PaneReplicaCheckpoint.currentFormatVersion + 1
        )
        #expect(throws: PaneReplicaCheckpointError.unsupportedFormatVersion(
            PaneReplicaCheckpoint.currentFormatVersion + 1
        )) {
            try PaneReplica(checkpoint: wrongVersion, for: paneId)
        }

        let otherPane = PaneId(rawValue: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!)
        let valid = PaneReplicaCheckpoint(
            stateBytes: state,
            columns: 8,
            rows: 2,
            paneId: paneId,
            cursor: cursor
        )
        #expect(throws: PaneReplicaCheckpointError.paneMismatch) {
            try PaneReplica(checkpoint: valid, for: otherPane)
        }

        let invalidGeometry = PaneReplicaCheckpoint(
            stateBytes: state,
            columns: 1,
            rows: 0,
            paneId: paneId,
            cursor: cursor
        )
        #expect(throws: PaneReplicaCheckpointError.invalidGeometry(columns: 1, rows: 0)) {
            try PaneReplica(checkpoint: invalidGeometry, for: paneId)
        }

        let invalidCursor = PaneReplicaCheckpoint(
            stateBytes: state,
            columns: 8,
            rows: 2,
            paneId: paneId,
            cursor: checkpointCursor(sequence: 1, feed: -1)
        )
        #expect(throws: PaneReplicaCheckpointError.invalidCursor) {
            try PaneReplica(checkpoint: invalidCursor, for: paneId)
        }
    }

    @Test("binary checkpoint encoding adds only fixed envelope overhead")
    func stateBytesAreNotInflatedIntoNumbers() throws {
        let state = [UInt8](repeating: 0x41, count: 1_048_576)
        let checkpoint = PaneReplicaCheckpoint(
            stateBytes: state,
            columns: 80,
            rows: 24,
            paneId: paneId,
            cursor: checkpointCursor(sequence: 1, feed: state.count)
        )
        let encoded = try checkpoint.encoded()

        #expect(encoded.count < state.count + 1_024)
        #expect(try PaneReplicaCheckpoint.decode(encoded) == checkpoint)
    }

    @Test("a restored foreign recorder cursor enters a gap and converges through fresh state")
    func foreignRecorderLifetimeRepairsAfterCheckpointRestore() throws {
        let replica = try checkpointReplica(
            bytes: Array("old".utf8),
            cursor: checkpointCursor(sequence: 4)
        )
        var restored = try PaneReplica(
            checkpoint: #require(replica.checkpoint(for: paneId)),
            for: paneId
        )
        let foreign = checkpointCursor(
            sequence: 4,
            lifetime: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        try restored.apply(.start(.init(
            version: 1,
            capture: .follow,
            format: .replay,
            columns: 8,
            rows: 2,
            cursor: foreign,
            reconstructible: true
        )))
        #expect(restored.state == .gap(.detected))

        try restored.apply(.sync(.init(
            part: 1,
            parts: 1,
            bytes: Array("fresh".utf8),
            columns: 8,
            rows: 2,
            cursor: foreign
        )))
        #expect(restored.terminal?.viewportText == "fresh")
        #expect(restored.cursor == foreign)
        #expect(restored.state == .exact)
    }
}

private func checkpointReplica(
    bytes: [UInt8],
    cursor: PaneTapeCursor,
    columns: Int = 8,
    rows: Int = 2
) throws -> PaneReplica {
    var replica = PaneReplica()
    try replica.apply(.sync(.init(
        part: 1,
        parts: 1,
        bytes: bytes,
        columns: columns,
        rows: rows,
        cursor: cursor
    )))
    return replica
}

private func checkpointEvent(
    sequence: UInt64,
    byteOffset: Int? = nil,
    byteLength: Int? = nil,
    event: NeutralTerminalRecordingEvent
) throws -> PaneTapeRecord {
    let data = try JSONEncoder().encode(event)
    return .event(.init(
        sequence: sequence,
        elapsedNanoseconds: sequence,
        originElapsedNanoseconds: nil,
        byteOffset: byteOffset,
        byteLength: byteLength,
        event: try JSONDecoder().decode(JSONValue.self, from: data)
    ))
}

private func checkpointCursor(
    sequence: UInt64,
    feed: Int = 0,
    write: Int = 0,
    lifetime: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
) -> PaneTapeCursor {
    PaneTapeCursor(
        recorderLifetimeId: lifetime,
        nextSequence: sequence,
        feedBytesBeforeNextSequence: feed,
        writeBytesBeforeNextSequence: write
    )
}

private func mutateCheckpointField(in data: Data, key: String) throws -> Data {
    var envelope = try #require(PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    ) as? [String: Any])
    switch key {
    case "stateBytes", "integrity": envelope[key] = Data("unsafe".utf8)
    case "paneId", "recorderLifetimeId": envelope[key] = UUID().uuidString
    default:
        let value = try #require(envelope[key] as? NSNumber)
        envelope[key] = NSNumber(value: value.int64Value + 1)
    }
    return try PropertyListSerialization.data(
        fromPropertyList: envelope,
        format: .binary,
        options: 0
    )
}
