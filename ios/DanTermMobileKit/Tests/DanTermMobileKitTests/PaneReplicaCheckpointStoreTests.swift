// Behavioral tests for the portable single-checkpoint file store.
@testable import DanTermMobileKit
import DanTermProtocol
import Foundation
import Testing

/// Uses a unique temporary directory per test so parallel execution shares no file state.
struct PaneReplicaCheckpointStoreTests {
    @Test("saving a second checkpoint atomically replaces the first")
    func saveReplacesTheSingleStoredCheckpoint() throws {
        let directory = checkpointStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PaneReplicaCheckpointStore(directory: directory)
        let pane = checkpointStorePane("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        let first = checkpointStoreValue(pane: pane, text: "first", sequence: 1)
        let second = checkpointStoreValue(pane: pane, text: "second", sequence: 2)

        try store.save(first)
        #expect(store.load(for: pane) == first)
        try store.save(second)

        #expect(store.load(for: pane) == second)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    @Test("an interrupted replacement leaves the prior checkpoint readable")
    func failedAtomicWritePreservesPriorCheckpoint() throws {
        // Intent: preserve one complete old or new checkpoint across an interrupted save.
        // Why it exists: state bytes and cursor must never come from different captures.
        // Scenario: the first real save succeeds and the injected second writer fails.
        let directory = checkpointStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pane = checkpointStorePane("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        let first = checkpointStoreValue(pane: pane, text: "first", sequence: 1)
        let second = checkpointStoreValue(pane: pane, text: "second", sequence: 2)
        let store = PaneReplicaCheckpointStore(directory: directory)
        try store.save(first)

        let interrupted = PaneReplicaCheckpointStore(directory: directory) { _, _ in
            throw CheckpointStoreTestError.interrupted
        }
        #expect(throws: CheckpointStoreTestError.interrupted) {
            try interrupted.save(second)
        }
        #expect(store.load(for: pane) == first)
    }

    @Test("corrupt, foreign-pane, and obsolete checkpoints are discarded")
    func unusableStoredCheckpointReturnsNothing() throws {
        let directory = checkpointStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pane = checkpointStorePane("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        let otherPane = checkpointStorePane("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        let store = PaneReplicaCheckpointStore(directory: directory)

        try store.save(checkpointStoreValue(pane: pane, text: "safe", sequence: 1))
        #expect(store.load(for: otherPane) == nil)
        #expect(store.load(for: pane) == nil)

        let obsolete = PaneReplicaCheckpoint(
            stateBytes: Array("old".utf8),
            columns: 8,
            rows: 2,
            paneId: pane,
            cursor: PaneTapeCursor(
                recorderLifetimeId: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                nextSequence: 1,
                feedBytesBeforeNextSequence: 3,
                writeBytesBeforeNextSequence: 0
            ),
            formatVersion: PaneReplicaCheckpoint.currentFormatVersion + 1
        )
        try store.save(obsolete)
        #expect(store.load(for: pane) == nil)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a checkpoint".utf8).write(to: store.fileURL, options: .atomic)
        #expect(store.load(for: pane) == nil)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path) == false)
    }
}

private enum CheckpointStoreTestError: Error {
    case interrupted
}

private func checkpointStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-mobile-checkpoint-\(UUID().uuidString)", isDirectory: true)
}

private func checkpointStorePane(_ uuid: String) -> PaneId {
    PaneId(rawValue: UUID(uuidString: uuid)!)
}

private func checkpointStoreValue(
    pane: PaneId,
    text: String,
    sequence: UInt64
) -> PaneReplicaCheckpoint {
    PaneReplicaCheckpoint(
        stateBytes: Array(text.utf8),
        columns: 8,
        rows: 2,
        paneId: pane,
        cursor: PaneTapeCursor(
            recorderLifetimeId: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            nextSequence: sequence,
            feedBytesBeforeNextSequence: text.utf8.count,
            writeBytesBeforeNextSequence: 0
        )
    )
}
