// Swift Testing suite for DanTermInstancePaths -- the one value that owns every
// identity-keyed path. It covers what the value derives (the exact on-disk
// layout, and that two identities never share it) and that the production
// writers put all three recovery files in the directory it names. The session
// lock's own read/write/delete contract stays in RecoveryStoreTests.
import DanTermProtocol
import Foundation
import Testing

@testable import DanTermSupport

/// Builds a value whose roots are all disposable, so a test can drive the real
/// writers without touching the user's Application Support or Caches trees.
private func makeTemporaryInstancePaths(
    identity: DanTermInstanceIdentity,
    root: URL
) -> DanTermInstancePaths {
    DanTermInstancePaths(
        identity: identity,
        applicationSupportRoot: root.appendingPathComponent("ApplicationSupport", isDirectory: true),
        cachesRoot: root.appendingPathComponent("Caches", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("Temporary", isDirectory: true)
    )
}

private func makeTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-instance-paths-\(UUID().uuidString)", isDirectory: true)
}

@Suite struct InstancePathsTests {
    @Test("every identity-keyed path keeps its documented layout")
    func derivedPathsKeepTheirDocumentedLayout() {
        // Intent: the value derives the exact on-disk names the app, the CLI tests,
        //   and the viability script already depend on.
        // Why it exists: these strings are external contract -- a rename here
        //   silently orphans a live session or a running agent's socket.
        // Scenario: spec-first layout check on disposable roots.
        let root = URL(fileURLWithPath: "/dt-root", isDirectory: true)
        let paths = makeTemporaryInstancePaths(identity: .production, root: root)

        #expect(paths.recoveryDirectory.path
            == "/dt-root/ApplicationSupport/com.danneu.danterm/Recovery")
        #expect(paths.lightCheckpointFile.lastPathComponent == "last-light.json")
        #expect(paths.enrichedCheckpointFile.lastPathComponent == "last-enriched.json")
        #expect(paths.sessionLockFile.lastPathComponent == "session.json")
        #expect(paths.ipcAuditDirectory == paths.recoveryDirectory)
        #expect(paths.controlSocket.path
            == "/dt-root/Caches/com.danneu.danterm/control.sock")
        #expect(paths.scrollbackReplayDirectory.path
            == "/dt-root/Temporary/danterm-scrollback/com.danneu.danterm")
    }

    @Test("two identities on the same roots share no path")
    func twoIdentitiesShareNoPath() {
        // Intent: a development instance never reads or writes a production file.
        // Why it exists: restoring a prod session into the dev app, or deleting its
        //   live socket, is the failure the bundle-id namespacing exists to prevent.
        // Scenario: spec-first prod-vs-dev namespacing on one set of roots.
        let root = URL(fileURLWithPath: "/dt-root", isDirectory: true)
        let production = makeTemporaryInstancePaths(identity: .production, root: root)
        let development = makeTemporaryInstancePaths(identity: .development, root: root)

        #expect(production.recoveryDirectory != development.recoveryDirectory)
        #expect(production.controlSocket != development.controlSocket)
        #expect(production.scrollbackReplayDirectory != development.scrollbackReplayDirectory)
        #expect(development.recoveryDirectory.path
            == "/dt-root/ApplicationSupport/com.danneu.danterm-dev/Recovery")
    }

    @Test("both checkpoint tiers, the lock, and the audit log land in one directory")
    func recoveryWritersShareOneDirectory() throws {
        // Intent: the production writers -- checkpoint writer, session lock, audit log --
        //   all land under the recovery directory this one value names.
        // Why it exists: before this value the three co-located only because each leaf
        //   happened to resolve the same default, so nothing tied them together.
        // Scenario: spec-first write of a full recovery directory on a temporary root.
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makeTemporaryInstancePaths(identity: .production, root: root)
        let writer = CheckpointWriter()

        // The lock goes first because it is what creates the recovery directory, in the app
        // as here: the checkpoint writer creates no directory of its own.
        try writeSessionLockFile(paths: paths)
        writer.write(to: paths.lightCheckpointFile, async: false, encode: { Data("light".utf8) })
        writer.write(to: paths.enrichedCheckpointFile, async: false, encode: { Data("enriched".utf8) })
        try IpcAuditLogWriter(directory: paths.ipcAuditDirectory).prepare()

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: paths.recoveryDirectory.path
        )
        #expect(Set(contents).isSuperset(of: [
            "last-light.json",
            "last-enriched.json",
            "session.json",
            "ipc-audit.jsonl",
        ]), "recovery directory held \(contents)")
        #expect(sessionLockIsPresent(paths: paths))
    }

    @Test("scrollback replay cleanup removes only this identity's directory")
    func replayCleanupRemovesOnlyThisIdentity() throws {
        // Intent: replay files for two live identities occupy disjoint directories,
        //   and launch cleanup removes only the caller's own.
        // Why it exists: launch cleanup removes an entire replay directory, so a
        //   shared path lets one instance erase another instance's live files.
        // Scenario: slot 1 launches while slot 2 is already serving panes and must
        //   clean only its own abandoned replay files.
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let slot1 = makeTemporaryInstancePaths(
            identity: try #require(DanTermInstanceIdentity(developmentSlot: 1)),
            root: root
        )
        let slot2 = makeTemporaryInstancePaths(
            identity: try #require(DanTermInstanceIdentity(developmentSlot: 2)),
            root: root
        )
        #expect(slot1.scrollbackReplayDirectory != slot2.scrollbackReplayDirectory)

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: slot1.scrollbackReplayDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: slot2.scrollbackReplayDirectory,
            withIntermediateDirectories: true
        )
        let survivor = slot2.scrollbackReplayDirectory.appendingPathComponent("live.txt")
        try Data("live".utf8).write(to: survivor)

        slot1.removeStaleScrollbackReplayDirectory()

        #expect(fileManager.fileExists(atPath: slot1.scrollbackReplayDirectory.path) == false)
        #expect(fileManager.fileExists(atPath: survivor.path))
    }
}
