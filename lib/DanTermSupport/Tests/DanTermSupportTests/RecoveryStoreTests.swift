// Swift Testing suite for DanTermSupport's RecoveryStore -- the session-lock
// write/presence/delete contract. Split out of DanTermCore's CheckpointTests in the
// Phase 4 persistence move: the pure codec/merge tests stayed in core; this
// disk-touching lock test came here with the I/O it exercises. What the paths are
// is InstancePathsTests' subject, not this file's. The tests drive a
// temporary-rooted paths value plus the defaulted now/pid seams (frozen clock,
// fixed pid) directly -- no CoreEnv -- so they are hermetic + parallel-safe and prove
// the store needs nothing from core.
import Foundation
import DanTermProtocol
import Testing

@testable import DanTermSupport

/// Roots the lock under a unique temp directory. The caller's defer removes it,
/// so the suite remains hermetic.
private func makeTestInstancePaths(
    root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-recoverystore-\(UUID().uuidString)", isDirectory: true)
) -> DanTermInstancePaths {
    DanTermInstancePaths(
        identity: .production,
        applicationSupportRoot: root.appendingPathComponent("ApplicationSupport", isDirectory: true),
        cachesRoot: root.appendingPathComponent("Caches", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("Temporary", isDirectory: true)
    )
}

/// The lock's payload is diagnostics for a human reading the recovery directory, so no
/// production decoder exists. This test-only mirror is how the suite proves the writer
/// still records a real pid and timestamp instead of quietly degrading to `{}`.
private struct DiagnosticSessionLock: Decodable {
    let pid: Int32
    let startedAt: Date
}

@Suite struct RecoveryStoreTests {
    @Test("the session lock is present after a write and absent after a delete")
    func sessionLockPresenceFollowsWriteAndDelete() throws {
        // Intent: writeSessionLockFile creates a session.json under the paths value,
        //   sessionLockIsPresent sees it, and deleteSessionLockFile removes it.
        // Why it exists: presence is the whole crash decision, so the two writers and
        //   the query have to agree about one file on disk. The paths value points at
        //   a per-test temp root, so the suite is hermetic + parallel-safe.
        // Scenario: spec-first session-lock I/O at a per-test temp root.
        let paths = makeTestInstancePaths()
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportRoot) }

        #expect(sessionLockIsPresent(paths: paths) == false,
            "nothing has been written yet, so absence must be confirmed")

        try writeSessionLockFile(paths: paths)

        #expect(FileManager.default.fileExists(atPath: paths.sessionLockFile.path),
            "writeSessionLockFile should create session.json under the temp root")
        #expect(sessionLockIsPresent(paths: paths))

        deleteSessionLockFile(paths: paths)

        #expect(!FileManager.default.fileExists(atPath: paths.sessionLockFile.path),
            "deleteSessionLockFile should remove the temp session.json")
        #expect(sessionLockIsPresent(paths: paths) == false)
    }

    @Test("the written lock carries the pid and start time a human would read")
    func writtenLockCarriesDiagnostics() throws {
        // Intent: the bytes the writer leaves behind decode to the injected pid and
        //   timestamp through the .iso8601 strategy.
        // Why it exists: production never reads the lock back, so nothing else would
        //   notice the writer degrading to an empty or wrong payload -- and the payload
        //   is the only reason the file has contents at all.
        // Scenario: spec-first inspection of a crashed instance's recovery directory.
        let paths = makeTestInstancePaths()
        let frozenNow = Date(timeIntervalSince1970: 1_700_000_000)
        let fixedPid: Int32 = 424_242
        defer { try? FileManager.default.removeItem(at: paths.applicationSupportRoot) }

        try writeSessionLockFile(paths: paths, now: frozenNow, pid: fixedPid)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lock = try decoder.decode(
            DiagnosticSessionLock.self,
            from: try Data(contentsOf: paths.sessionLockFile)
        )
        #expect(lock.pid == fixedPid, "pid should round-trip the injected pid seam")
        #expect(lock.startedAt == frozenNow, "startedAt should use the injected now seam")
    }

    @Test("a write that cannot create the recovery directory reports the failure")
    func unwritableRecoveryDirectoryReportsFailure() throws {
        // Intent: the writer throws rather than swallowing an I/O error.
        // Why it exists: a lock that was never created disables crash detection for the
        //   whole run, and a silent writer gives the launch path nothing to report.
        // Scenario: spec-first launch with a regular file sitting where the recovery
        //   directory belongs, so no directory can be created there.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-lockwrite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makeTestInstancePaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.recoveryDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a directory".utf8).write(to: paths.recoveryDirectory)

        #expect(throws: (any Error).self) {
            try writeSessionLockFile(paths: paths)
        }
    }
}
