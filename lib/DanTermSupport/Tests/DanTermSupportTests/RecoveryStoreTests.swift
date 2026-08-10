// Swift Testing suite for DanTermSupport's RecoveryStore -- the recovery-path
// helpers (recoveryDirectoryURL/light/enriched/sessionLockURL) and the
// session-lock write/read/delete round-trip. Split out of DanTermCore's
// CheckpointTests in the Phase 4 persistence move: the pure codec/merge tests
// stayed in core; these disk-touching path/lock tests came here with the I/O
// they exercise. The round-trip test drives the defaulted recoveryDir/now/pid
// seams (a per-test temp dir, frozen clock, fixed pid) directly -- no CoreEnv --
// so it is hermetic + parallel-safe and proves the store needs nothing from core.
import Foundation
import DanTermProtocol
import Testing

@testable import DanTermSupport

/// Build a unique-per-test recovery directory under the OS temp dir. The
/// caller's defer removes it, so the suite remains hermetic.
private func makeTestRecoveryDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-recoverystore-\(UUID().uuidString)", isDirectory: true)
}

@Suite struct RecoveryStoreTests {
    // MARK: - Session Lock round-trip

    @Test("SessionLock round-trips through write/read helpers")
    func sessionLockRoundTripsThroughWriteReadHelpers() throws {
        // Intent: writeSessionLockFile creates a session.json on disk
        //   that readSessionLockFile parses back into a SessionLock;
        //   deleteSessionLockFile removes it.
        // Why it exists: pins the lock-file I/O contract end to end. The
        //   defaulted recoveryDir/now/pid seams are pointed at a per-test
        //   temp dir, frozen clock, and fixed pid so the suite is hermetic
        //   + parallel-safe. The on-disk fileExists assertions verify the
        //   recovery-dir seam; the startedAt and pid assertions verify the
        //   now and pid seams round-trip through the .iso8601 codec.
        // Scenario: spec-first session-lock I/O at a per-test temp dir.
        let recoveryDir = makeTestRecoveryDir()
        let frozenNow = Date(timeIntervalSince1970: 1_700_000_000)
        let fixedPid: Int32 = 424_242
        defer { try? FileManager.default.removeItem(at: recoveryDir) }

        writeSessionLockFile(recoveryDir: recoveryDir, now: frozenNow, pid: fixedPid)
        let sessionJSONPath = recoveryDir.appendingPathComponent("session.json").path
        #expect(FileManager.default.fileExists(atPath: sessionJSONPath),
            "writeSessionLockFile should create session.json under the temp dir")
        let lock = try #require(readSessionLockFile(recoveryDir: recoveryDir),
            "readSessionLockFile returned nil after write")
        #expect(lock.pid == fixedPid, "pid should round-trip the injected pid seam")
        #expect(lock.startedAt == frozenNow, "startedAt should use the injected now seam")
        deleteSessionLockFile(recoveryDir: recoveryDir)
        #expect(!FileManager.default.fileExists(atPath: sessionJSONPath),
            "deleteSessionLockFile should remove the temp session.json")
        let deleted = readSessionLockFile(recoveryDir: recoveryDir)
        #expect(deleted == nil, "lock should be nil after delete")
    }

    // MARK: - Recovery path helpers

    @Test("recoveryDirectoryURL is namespaced by bundle identifier")
    func recoveryDirectoryURLIsNamespacedByBundleId() {
        // Intent: distinct bundleIds (prod / dev) produce distinct
        //   recovery directories.
        // Why it exists: pins the namespacing rule that keeps dev runs
        //   from sharing prod recovery files.
        // Scenario: spec-first prod-vs-dev namespacing.
        let prodURL = recoveryDirectoryURL(
            identity: DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm")
        )
        let devURL = recoveryDirectoryURL(
            identity: DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm-dev")
        )
        #expect(prodURL != devURL, "prod and dev paths must differ, both were \(prodURL.path)")
        #expect(prodURL.path.hasSuffix("/Library/Application Support/com.danneu.danterm/Recovery"),
            "prod path wrong: \(prodURL.path)")
        #expect(devURL.path.hasSuffix("/Library/Application Support/com.danneu.danterm-dev/Recovery"),
            "dev path wrong: \(devURL.path)")
    }

    @Test("scrollback replay directories are namespaced by instance identity")
    func scrollbackReplayDirectoriesAreNamespacedByIdentity() throws {
        // Intent: replay files for two live identities occupy disjoint directories.
        // Why it exists: launch cleanup removes an entire replay directory, so a
        //   shared path lets one instance erase another instance's live files.
        // Scenario: slot 1 launches while slot 2 is already serving panes and must
        //   clean only its own abandoned replay files.
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-replay-tests-\(UUID().uuidString)", isDirectory: true)
        let slot1 = DanTermInstanceIdentity(developmentSlot: 1)!
        let slot2 = DanTermInstanceIdentity(developmentSlot: 2)!
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let first = scrollbackReplayDirectoryURL(
            identity: slot1,
            temporaryDirectory: temporaryDirectory
        )
        let second = scrollbackReplayDirectoryURL(
            identity: slot2,
            temporaryDirectory: temporaryDirectory
        )

        #expect(first != second)
        #expect(first.path.hasSuffix("/danterm-scrollback/com.danneu.danterm-dev.1"))
        #expect(second.path.hasSuffix("/danterm-scrollback/com.danneu.danterm-dev.2"))

        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let survivor = second.appendingPathComponent("live.txt")
        try Data("live".utf8).write(to: survivor)

        cleanupStaleScrollbackReplayDirectory(
            identity: slot1,
            temporaryDirectory: temporaryDirectory
        )

        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: survivor.path))
    }

    @Test("lightCheckpointURL ends with last-light.json")
    func lightCheckpointURLEndsWithLastLightJson() {
        // Intent: lightCheckpointURL ends with last-light.json.
        // Why it exists: pins the file name contract.
        // Scenario: spec-first light file name.
        let url = lightCheckpointURL()
        #expect(url.lastPathComponent == "last-light.json", "expected last-light.json, got \(url.lastPathComponent)")
    }

    @Test("enrichedCheckpointURL ends with last-enriched.json")
    func enrichedCheckpointURLEndsWithLastEnrichedJson() {
        // Intent: enrichedCheckpointURL ends with last-enriched.json.
        // Why it exists: pins the enriched file name contract.
        // Scenario: spec-first enriched file name.
        let url = enrichedCheckpointURL()
        #expect(url.lastPathComponent == "last-enriched.json", "expected last-enriched.json, got \(url.lastPathComponent)")
    }

    @Test("sessionLockURL ends with session.json")
    func sessionLockURLEndsWithSessionJson() {
        // Intent: sessionLockURL ends with session.json.
        // Why it exists: pins the session lock file name.
        // Scenario: spec-first session lock file name.
        let url = sessionLockURL()
        #expect(url.lastPathComponent == "session.json", "expected session.json, got \(url.lastPathComponent)")
    }
}
