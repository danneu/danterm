// Swift Testing suite for DanTermSupport's RecoveryStore -- the session-lock
// write/read/delete round-trip. Split out of DanTermCore's CheckpointTests in the
// Phase 4 persistence move: the pure codec/merge tests stayed in core; this
// disk-touching lock test came here with the I/O it exercises. What the paths are
// is InstancePathsTests' subject, not this file's. The round-trip drives a
// temporary-rooted paths value plus the defaulted now/pid seams (frozen clock,
// fixed pid) directly -- no CoreEnv -- so it is hermetic + parallel-safe and proves
// the store needs nothing from core.
import Foundation
import DanTermProtocol
import Testing

@testable import DanTermSupport

/// Roots the lock under a unique temp directory. The caller's defer removes it,
/// so the suite remains hermetic.
private func makeTestInstancePaths() -> DanTermInstancePaths {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-recoverystore-\(UUID().uuidString)", isDirectory: true)
    return DanTermInstancePaths(
        identity: .production,
        applicationSupportRoot: root.appendingPathComponent("ApplicationSupport", isDirectory: true),
        cachesRoot: root.appendingPathComponent("Caches", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("Temporary", isDirectory: true)
    )
}

@Suite struct RecoveryStoreTests {
    @Test("SessionLock round-trips through write/read helpers")
    func sessionLockRoundTripsThroughWriteReadHelpers() throws {
        // Intent: writeSessionLockFile creates a session.json on disk
        //   that readSessionLockFile parses back into a SessionLock;
        //   deleteSessionLockFile removes it.
        // Why it exists: pins the lock-file I/O contract end to end. The paths
        //   value points at a per-test temp root and the now/pid seams are frozen,
        //   so the suite is hermetic + parallel-safe. The on-disk fileExists
        //   assertions verify the paths value is obeyed; the startedAt and pid
        //   assertions verify the now and pid seams round-trip through the
        //   .iso8601 codec.
        // Scenario: spec-first session-lock I/O at a per-test temp root.
        let paths = makeTestInstancePaths()
        let frozenNow = Date(timeIntervalSince1970: 1_700_000_000)
        let fixedPid: Int32 = 424_242
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportRoot) }

        writeSessionLockFile(paths: paths, now: frozenNow, pid: fixedPid)
        #expect(FileManager.default.fileExists(atPath: paths.sessionLockFile.path),
            "writeSessionLockFile should create session.json under the temp root")
        let lock = try #require(readSessionLockFile(paths: paths),
            "readSessionLockFile returned nil after write")
        #expect(lock.pid == fixedPid, "pid should round-trip the injected pid seam")
        #expect(lock.startedAt == frozenNow, "startedAt should use the injected now seam")
        deleteSessionLockFile(paths: paths)
        #expect(!FileManager.default.fileExists(atPath: paths.sessionLockFile.path),
            "deleteSessionLockFile should remove the temp session.json")
        let deleted = readSessionLockFile(paths: paths)
        #expect(deleted == nil, "lock should be nil after delete")
    }
}
