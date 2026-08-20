// Swift Testing suite for the launch-time recovery read -- the decision launch makes
// about the previous session before AppKit starts. It covers the skip rule, crash
// detection, every tier combination the recovery directory can hold, and the full
// write-relaunch-merge flow driven through the production writers. Behavior only:
// every assertion reads the returned value, never a helper's shape.
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
        scrollbackReads: scrollback.mapValues { text in { _ in text } }
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
    ) -> LaunchRecovery {
        readLaunchRecovery(
            paths: instance.paths,
            startup: startup,
            hasInitSnapshot: hasInitSnapshot
        )
    }

    func remove() { instance.remove() }
}

@Suite struct LaunchRecoveryTests {
    @Test("an untouched recovery directory reports nothing and creates nothing")
    func emptyRecoveryDirectoryReportsNothing() {
        // Intent: a first launch reports no crash, no restore, and leaves no file behind.
        // Why it exists: the read runs on every launch, so a read that creates its own
        //   directory would make "nothing was ever saved" indistinguishable from a crash.
        // Scenario: spec-first first launch on an empty temporary root.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }

        let recovery = fixture.read()

        #expect(recovery.previousSessionCrashed == false)
        #expect(recovery.restore == nil)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.instance.paths.recoveryDirectory.path
        ))
    }

    @Test("a session lock alone means crashed with nothing to restore")
    func sessionLockAloneMeansCrashed() {
        // Intent: the lock decides "crashed", and it decides nothing about restore.
        // Why it exists: crash detection and checkpoint loading are independent; a crash
        //   before the first checkpoint must still prompt rather than silently restore.
        // Scenario: spec-first kill with no checkpoint yet written.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        writeSessionLockFile(paths: fixture.instance.paths)

        let recovery = fixture.read()

        #expect(recovery.previousSessionCrashed)
        #expect(recovery.restore == nil)
    }

    @Test("the read never deletes the session lock")
    func readLeavesTheSessionLockInPlace() {
        // Intent: the lock survives the read.
        // Why it exists: the launch write path overwrites the lock atomically later, so
        //   deleting it here would open a window where a startup crash reads as a clean exit.
        // Scenario: spec-first relaunch after a crash.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        writeSessionLockFile(paths: fixture.instance.paths)

        _ = fixture.read()

        #expect(readSessionLockFile(paths: fixture.instance.paths) != nil)
    }

    @Test("a light checkpoint alone restores the light tier")
    func lightCheckpointAloneRestores() throws {
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        fixture.writeLight(try checkpointBytes(makeRecoveryModel(tabs: 2)))

        let restore = try #require(fixture.read().restore)

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

        let restore = try #require(fixture.read().restore)

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

        let restore = try #require(fixture.read().restore)

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

        let restore = try #require(fixture.read().restore)

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

        let restore = try #require(fixture.read().restore)

        #expect(restore.model.groups[0].tabs.count == 1)
    }

    @Test("a fresh startup policy reads nothing")
    func freshStartupReadsNothing() throws {
        // Intent: `--fresh` skips the whole read, lock included.
        // Why it exists: a pool slot launched fresh must not inherit another run's
        //   session or report its crash.
        // Scenario: spec-first `--fresh` launch over a full recovery directory.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        writeSessionLockFile(paths: fixture.instance.paths)
        fixture.writeLight(try checkpointBytes(makeRecoveryModel(tabs: 2)))

        let recovery = fixture.read(startup: .fresh)

        #expect(recovery.previousSessionCrashed == false)
        #expect(recovery.restore == nil)
    }

    @Test("an explicit init snapshot reads nothing")
    func initSnapshotReadsNothing() throws {
        // Intent: `--init` wins over recovery outright.
        // Why it exists: a caller that names the session it wants must not be prompted
        //   to replace it with the previous one.
        // Scenario: spec-first `--init` launch over a full recovery directory.
        let fixture = RecoveryFixture()
        defer { fixture.remove() }
        writeSessionLockFile(paths: fixture.instance.paths)
        fixture.writeLight(try checkpointBytes(makeRecoveryModel(tabs: 2)))

        let recovery = fixture.read(hasInitSnapshot: true)

        #expect(recovery.previousSessionCrashed == false)
        #expect(recovery.restore == nil)
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
        writeSessionLockFile(paths: fixture.instance.paths)

        let recovery = fixture.read()
        let restore = try #require(recovery.restore)

        #expect(recovery.previousSessionCrashed)
        #expect(restore.model.groups[0].tabs.count == 2)
        #expect(scrollbackTexts(restore) == [enrichedScrollback])
    }
}
