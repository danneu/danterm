// Swift Testing suite for what launch decides about the previous session before AppKit
// starts: the session-lock handshake that detects a crash and claims this launch's lock,
// and the checkpoint load with its skip rule, every tier combination the recovery
// directory can hold, and the full write-relaunch-merge flow driven through the
// production writers. Behavior only: every assertion reads a returned value or the disk,
// never a helper's shape.
import DanTermProtocol
import Foundation
import Testing

@testable import DanTerm

/// Build a model whose tabs each own one pane, so a test can talk about "two panes"
/// without reaching into the pane tree at every assertion.
private func makeRecoveryModel(tabs: Int) -> AppModel {
    var model = AppModel(groups: [GroupModel(id: GroupId(rawValue: UUID()), name: "General")])
    for _ in 0..<tabs { _ = update(&model, .createTabInSelectedGroup()) }
    return model
}

/// Encode a checkpoint the way the app does: a capture turned into bytes by its own
/// encoder. Tests write these through `CheckpointWriter`, the production writer.
private func checkpointBytes(
    _ model: AppModel,
    scrollback: [PaneId: String] = [:]
) throws -> Data {
    let capture = CheckpointCapture(
        snapshot: toSnapshot(model),
        scrollbackReads: scrollback.mapValues { text in { text } }
    )
    return try capture.encoder()()
}

/// Rewrite a valid checkpoint's version field so it decodes but is refused, which is
/// how an upgraded app meets a checkpoint the previous version left behind.
private func withUnsupportedVersion(_ data: Data) throws -> Data {
    var object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["version"] = appInitFileVersion + 1
    return try JSONSerialization.data(withJSONObject: object)
}

/// The scrollback a test hands the enriched tier. It ends in a newline because a
/// pane's history always does, so the text that comes back is the text that went in.
private let enrichedScrollback = "enriched\n"

/// Every scrollback string the restore carries, which is what the merge assertions count.
private func scrollbackTexts(_ restore: ValidatedAppRestore) -> [String] {
    restore.paneSnapshots.values.compactMap(\.scrollback).sorted()
}

private struct RecoveryFixture {
    let instance = TemporaryInstancePaths()
    private let writer = CheckpointWriter()

    func writeLight(_ data: Data) {
        writer.write(to: instance.paths.lightCheckpointFile, async: false, encode: { data })
    }

    func writeEnriched(_ data: Data) {
        writer.write(to: instance.paths.enrichedCheckpointFile, async: false, encode: { data })
    }

    func read(
        startup: StartupPolicy = .promptForRecovery,
        hasInitSnapshot: Bool = false
    ) -> ValidatedAppRestore? {
        loadLaunchCheckpoints(
            paths: instance.paths,
            startup: startup,
            hasInitSnapshot: hasInitSnapshot
        )
    }

    func handshake() -> SessionLockHandshake {
        claimSessionLock(paths: instance.paths)
    }

    var lockExists: Bool {
        FileManager.default.fileExists(atPath: instance.paths.sessionLockFile.path)
    }

    /// Puts arbitrary bytes where the lock belongs, which is how a lock written by a
    /// build with a different `SessionLock` shape reaches the next launch.
    func writeRawLock(_ bytes: Data) throws {
        try FileManager.default.createDirectory(
            at: instance.paths.recoveryDirectory,
            withIntermediateDirectories: true
        )
        try bytes.write(to: instance.paths.sessionLockFile)
    }

    func remove() { instance.remove() }
}

@Suite struct LaunchRecoveryTests {
    @Test("an untouched recovery directory offers no restore and creates nothing")
    func emptyRecoveryDirectoryReportsNothing() {
        // Intent: a first launch finds no checkpoint and leaves no file behind.
        // Why it exists: the load runs on every launch, so a load that created its own
        //   directory would leave a trail no later reader could tell from a real session.
        // Scenario: spec-first first launch on an empty temporary root.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }

        #expect(fixture.read() == nil)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.instance.paths.recoveryDirectory.path
        ))
    }

    @Test("a session lock alone means crashed with nothing to restore")
    func sessionLockAloneMeansCrashed() throws {
        // Intent: the lock decides "crashed", and it decides nothing about restore.
        // Why it exists: crash detection and checkpoint loading are independent; a crash
        //   before the first checkpoint must still prompt rather than silently restore.
        // Scenario: spec-first kill with no checkpoint yet written.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        try writeSessionLockFile(paths: fixture.instance.paths)

        #expect(fixture.handshake().previousSessionCrashed)
        #expect(fixture.read() == nil)
    }

    @Test("a lock whose contents cannot be understood still means crashed")
    func unreadableLockContentsMeanCrashed() throws {
        // Intent: any bytes at the lock's path report a crash -- invalid JSON, and an
        //   empty file.
        // Why it exists: the decision used to decode the file, so a lock left by a build
        //   whose payload shape had changed read as a clean exit and the session was lost
        //   with no prompt. Existence is the contract; the contents are diagnostics.
        // Scenario: spec-first first launch after a format change, over a crashed session.
        for bytes in [Data("{ not json".utf8), Data()] {
            let fixture = RecoveryFixture()
            defer { fixture.remove() }
            try fixture.writeRawLock(bytes)

            #expect(fixture.handshake().previousSessionCrashed,
                "\(bytes.count) bytes at the lock path must still report a crash")
        }
    }

    @Test("a recovery directory that cannot be inspected means crashed")
    func unsearchableRecoveryDirectoryMeansCrashed() throws {
        // Intent: a lookup that fails for any reason other than "no such file" reports a
        //   crash, while a confirmed absence still reports a clean exit.
        // Why it exists: failing safe is the point of the query. A location we cannot
        //   inspect may well hold a lock, and calling that clean discards the previous
        //   session without asking.
        // Scenario: spec-first launch with a regular file where the recovery directory
        //   belongs, so the lock path cannot be resolved at all.
        let absent = RecoveryFixture()
        defer { absent.remove() }
        #expect(absent.handshake().previousSessionCrashed == false,
            "an absent directory is a confirmed absence, so it reads as a clean exit")

        let blocked = RecoveryFixture()
        defer { blocked.remove() }
        try FileManager.default.createDirectory(
            at: blocked.instance.paths.recoveryDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a directory".utf8)
            .write(to: blocked.instance.paths.recoveryDirectory)

        #expect(blocked.handshake().previousSessionCrashed)
    }

    @Test("the handshake claims this launch's lock before it returns")
    func handshakeClaimsTheLockItself() {
        // Intent: a launch that finds no lock reports a clean previous exit and still
        //   leaves its own lock on disk by the time the handshake returns.
        // Why it exists: the claim used to sit at the end of AppKit startup, so a crash
        //   anywhere between launch and the window -- reading `--init`, loading
        //   checkpoints, building the view tree -- left nothing behind, and the next
        //   launch reported a clean exit for a run that crashed.
        // Scenario: spec-first launch after a clean exit.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }

        let handshake = fixture.handshake()

        #expect(handshake.previousSessionCrashed == false)
        #expect(handshake.claimFailure == nil)
        #expect(fixture.lockExists, "the claim happens inside the handshake, not later")
    }

    @Test("the handshake reports the previous lock even though it overwrites it")
    func handshakeReadsBeforeItClaims() throws {
        // Intent: the read of the previous launch's lock happens before this launch's
        //   claim overwrites it.
        // Why it exists: both halves touch one path, so an implementation that claimed
        //   first would erase the fact it is supposed to report.
        // Scenario: spec-first relaunch after a crash.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        try writeSessionLockFile(paths: fixture.instance.paths)

        let handshake = fixture.handshake()

        #expect(handshake.previousSessionCrashed)
        #expect(fixture.lockExists, "this launch's own lock replaced the previous one")
    }

    @Test("a light checkpoint alone restores the light tier")
    func lightCheckpointAloneRestores() throws {
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        fixture.writeLight(try checkpointBytes(makeRecoveryModel(tabs: 2)))

        let restore = try #require(fixture.read())

        #expect(restore.model.groups[0].tabs.count == 2)
    }

    @Test("an enriched checkpoint alone restores the enriched tier")
    func enrichedCheckpointAloneRestores() throws {
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        let model = makeRecoveryModel(tabs: 1)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        fixture.writeEnriched(
            try checkpointBytes(model, scrollback: [paneId: enrichedScrollback])
        )

        let restore = try #require(fixture.read())

        #expect(restore.model.groups[0].tabs.count == 1)
        #expect(scrollbackTexts(restore) == [enrichedScrollback])
    }

    @Test("both tiers merge: structure from light, scrollback from enriched")
    func bothTiersMergeLightStructureWithEnrichedScrollback() throws {
        // Intent: the merge keeps light's structure and grafts enriched scrollback onto
        //   the panes the two share, leaving a light-only pane without scrollback.
        // Why it exists: the light tier is written far more often, so an older enriched
        //   tier must never resurrect a tab the user already closed.
        // Scenario: spec-first crash one tab after the last enriched checkpoint.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        var model = makeRecoveryModel(tabs: 1)
        let firstPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        fixture.writeEnriched(
            try checkpointBytes(model, scrollback: [firstPaneId: enrichedScrollback])
        )
        _ = update(&model, .createTabInSelectedGroup())
        fixture.writeLight(try checkpointBytes(model))

        let restore = try #require(fixture.read())

        #expect(restore.model.groups[0].tabs.count == 2)
        #expect(restore.paneSnapshots.count == 2)
        #expect(scrollbackTexts(restore) == [enrichedScrollback])
    }

    @Test("a corrupt tier behaves as an absent one")
    func corruptTierBehavesAsAbsent() throws {
        // Intent: garbage in one tier leaves the other tier's restore intact.
        // Why it exists: a checkpoint interrupted mid-write must cost the session its
        //   scrollback at worst, never its whole structure.
        // Scenario: spec-first kill during an enriched write.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        fixture.writeLight(try checkpointBytes(makeRecoveryModel(tabs: 2)))
        fixture.writeEnriched(Data("{ not json".utf8))

        let restore = try #require(fixture.read())

        #expect(restore.model.groups[0].tabs.count == 2)
        #expect(scrollbackTexts(restore).isEmpty)
    }

    @Test("an unsupported checkpoint version behaves as an absent tier")
    func unsupportedVersionBehavesAsAbsent() throws {
        // Intent: a checkpoint from another format version is refused, not adapted.
        // Why it exists: DanTerm keeps no version-dispatch fork, so the first launch
        //   after a format change must fall through instead of restoring nonsense.
        // Scenario: spec-first upgrade over an old light checkpoint.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        fixture.writeLight(try withUnsupportedVersion(checkpointBytes(makeRecoveryModel(tabs: 3))))
        fixture.writeEnriched(try checkpointBytes(makeRecoveryModel(tabs: 1)))

        let restore = try #require(fixture.read())

        #expect(restore.model.groups[0].tabs.count == 1)
    }

    @Test("a fresh startup policy loads no checkpoint")
    func freshStartupReadsNothing() throws {
        // Intent: `--fresh` skips the checkpoint load.
        // Why it exists: a pool slot launched fresh must not inherit another run's
        //   session.
        // Scenario: spec-first `--fresh` launch over a full recovery directory.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        try writeSessionLockFile(paths: fixture.instance.paths)
        fixture.writeLight(try checkpointBytes(makeRecoveryModel(tabs: 2)))

        #expect(fixture.read(startup: .fresh) == nil)
    }

    @Test("an explicit init snapshot loads no checkpoint")
    func initSnapshotReadsNothing() throws {
        // Intent: `--init` wins over recovery outright.
        // Why it exists: a caller that names the session it wants must not be prompted
        //   to replace it with the previous one.
        // Scenario: spec-first `--init` launch over a full recovery directory.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        try writeSessionLockFile(paths: fixture.instance.paths)
        fixture.writeLight(try checkpointBytes(makeRecoveryModel(tabs: 2)))

        #expect(fixture.read(hasInitSnapshot: true) == nil)
    }

    @Test("a fresh or init launch after a clean exit still claims the lock")
    func skippedRecoveryStillClaimsTheLock() throws {
        // Intent: launching with `--fresh`, and launching with an `--init` snapshot, each
        //   from a recovery directory holding no lock, offers no restore and reports no
        //   crash -- and still leaves this launch's lock on disk.
        // Why it exists: the lock read used to sit inside the skipped checkpoint load, so
        //   a skipped launch claimed nothing and a crash during that run went undetected.
        //   The other skip-rule tests all start with a lock already present, so they pass
        //   even against an implementation that skips the claim too.
        // Scenario: spec-first `--fresh` and `--init` launches after a clean exit.
        for hasInitSnapshot in [false, true] {
            let fixture = RecoveryFixture()
            defer { fixture.remove() }
            fixture.writeLight(try checkpointBytes(makeRecoveryModel(tabs: 2)))

            let handshake = fixture.handshake()
            let restore = fixture.read(
                startup: hasInitSnapshot ? .promptForRecovery : .fresh,
                hasInitSnapshot: hasInitSnapshot
            )

            #expect(restore == nil)
            #expect(handshake.previousSessionCrashed == false)
            #expect(fixture.lockExists,
                "a launch that skips recovery still claims its lock")
        }
    }

    @Test("one paths value carries a crashed session from the writers to the launch read")
    func writtenSessionSurvivesRelaunchThroughOnePathsValue() throws {
        // Intent: the files the production writers leave behind are exactly the files the
        //   launch read finds, through a single instance-paths value.
        // Why it exists: before that value the writers and the reader only agreed because
        //   each resolved the same default separately; nothing tied them together.
        // Scenario: spec-first crash after both checkpoint tiers and the lock were written.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        var model = makeRecoveryModel(tabs: 1)
        let firstPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        fixture.writeEnriched(
            try checkpointBytes(model, scrollback: [firstPaneId: enrichedScrollback])
        )
        _ = update(&model, .createTabInSelectedGroup())
        fixture.writeLight(try checkpointBytes(model))
        try writeSessionLockFile(paths: fixture.instance.paths)

        let handshake = fixture.handshake()
        let restore = try #require(fixture.read())

        #expect(handshake.previousSessionCrashed)
        #expect(restore.model.groups[0].tabs.count == 2)
        #expect(scrollbackTexts(restore) == [enrichedScrollback])
    }
}
