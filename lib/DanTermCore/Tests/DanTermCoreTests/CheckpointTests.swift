// Swift Testing migration of the legacy `tests/CheckpointTests.swift` harness
// suite. Pins .scheduleCheckpoint emission across mutating handlers,
// non-mutating-no-emission cases, snapshot fidelity (toSnapshot drops
// isZoomed), the session-lock write/read/delete round-trip, recovery path
// helpers, and the mergeCheckpoints rules (enriched scrollback grafted into
// light's pane map; light structure wins; metadata from light; empty
// enriched). The SessionLock round-trip test points CoreEnv.recoveryDir at a
// per-test temp dir, so the suite never touches the real ~/Library/Application
// Support/<bundle>/Recovery/ path -- it's parallel-safe by construction (no
// .serialized needed). It also freezes CoreEnv.now and asserts the persisted
// startedAt, proving both env seams are honored.
import Foundation
import Testing

@testable import DanTermCore

private func makeRestore(_ paneSnapshots: [PaneId: PaneSnapshot], model: AppModel) -> ValidatedAppRestore {
    ValidatedAppRestore(snapshot: toSnapshot(model), model: model, paneSnapshots: paneSnapshots)
}

private func paneSnap(_ id: PaneId, title: String, cwd: String? = nil, scrollback: String? = nil, theme: String? = nil) -> PaneSnapshot {
    PaneSnapshot(id: id.rawValue.uuidString, title: title, cwd: cwd, launch: nil, scrollback: scrollback, theme: theme)
}

/// Build a unique-per-test recovery directory under the OS temp dir. The
/// caller's defer removes it, so the suite remains hermetic.
private func makeTestRecoveryDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-checkpoint-\(UUID().uuidString)", isDirectory: true)
}

@Suite struct CheckpointTests {
    // MARK: - scheduleCheckpoint emission

    @Test("createTab emits scheduleCheckpoint")
    func createTabEmitsScheduleCheckpoint() {
        // Intent: createTab emits scheduleCheckpoint.
        // Why it exists: pins the per-mutation persistence.
        // Scenario: spec-first emit.
        var model = makeModel()
        let commands = update(&model, .createTab(inGroupId: nil))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "createTab should emit scheduleCheckpoint")
    }

    @Test("selectTab emits scheduleCheckpoint")
    func selectTabEmitsScheduleCheckpoint() {
        // Intent: selectTab emits scheduleCheckpoint.
        // Why it exists: pins the per-selection persistence.
        // Scenario: spec-first selectTab emit.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let commands = update(&model, .selectTab(id: tabId))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "selectTab should emit scheduleCheckpoint")
    }

    @Test("closeTab emits scheduleCheckpoint")
    func closeTabEmitsScheduleCheckpoint() {
        // Intent: closeTab emits scheduleCheckpoint.
        // Why it exists: pins close-tab persistence.
        // Scenario: spec-first closeTab emit.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let commands = update(&model, .closeTab(id: tabId))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "closeTab should emit scheduleCheckpoint")
    }

    @Test("splitPane emits scheduleCheckpoint")
    func splitPaneEmitsScheduleCheckpoint() {
        // Intent: splitPane emits scheduleCheckpoint.
        // Why it exists: pins splitPane persistence.
        // Scenario: spec-first splitPane emit.
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .splitPane(direction: .horizontal))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "splitPane should emit scheduleCheckpoint")
    }

    @Test("closePane emits scheduleCheckpoint")
    func closePaneEmitsScheduleCheckpoint() {
        // Intent: closePane emits scheduleCheckpoint.
        // Why it exists: pins closePane persistence.
        // Scenario: spec-first closePane emit.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let tab = selectedTab(in: model)!
        let paneToClose = allPaneIds(tab.rootNode).last!
        let commands = update(&model, .closePane(paneId: paneToClose))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "closePane should emit scheduleCheckpoint")
    }

    @Test("surfaceTitle emits scheduleCheckpoint")
    func surfaceTitleEmitsScheduleCheckpoint() {
        // Intent: surfaceTitle emits scheduleCheckpoint.
        // Why it exists: pins surface metadata persistence.
        // Scenario: spec-first surfaceTitle emit.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let commands = update(&model, .surfaceTitle(paneId: paneId, title: "new title"))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "surfaceTitle should emit scheduleCheckpoint")
    }

    @Test("surfaceCwd emits scheduleCheckpoint")
    func surfaceCwdEmitsScheduleCheckpoint() {
        // Intent: surfaceCwd emits scheduleCheckpoint.
        // Why it exists: pins cwd-update persistence.
        // Scenario: spec-first surfaceCwd emit.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let commands = update(&model, .surfaceCwd(paneId: paneId, cwd: "/tmp"))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "surfaceCwd should emit scheduleCheckpoint")
    }

    @Test("commandStarted emits scheduleCheckpoint")
    func commandStartedEmitsScheduleCheckpoint() {
        // Intent: commandStarted emits scheduleCheckpoint.
        // Why it exists: pins command-start persistence.
        // Scenario: spec-first commandStarted emit.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let commands = update(&model, .commandStarted(paneId: paneId, command: "ls"))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "commandStarted should emit scheduleCheckpoint")
    }

    @Test("renameTab emits scheduleCheckpoint")
    func renameTabEmitsScheduleCheckpoint() {
        // Intent: renameTab emits scheduleCheckpoint.
        // Why it exists: pins rename persistence.
        // Scenario: spec-first renameTab emit.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let commands = update(&model, .renameTab(id: tabId, name: "MyTab"))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "renameTab should emit scheduleCheckpoint")
    }

    @Test("setTabColors emits scheduleCheckpoint")
    func setTabColorsEmitsScheduleCheckpoint() {
        // Intent: setTabColors emits scheduleCheckpoint.
        // Why it exists: pins color-change persistence.
        // Scenario: spec-first setTabColors emit.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let commands = update(&model, .setTabColors(tabIds: [tabId], color: .red))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "setTabColors should emit scheduleCheckpoint")
    }

    @Test("renameGroup emits scheduleCheckpoint")
    func renameGroupEmitsScheduleCheckpoint() {
        // Intent: renameGroup emits scheduleCheckpoint.
        // Why it exists: pins group-rename persistence.
        // Scenario: spec-first renameGroup emit.
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .renameGroup(id: model.groups[0].id, name: "Renamed"))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "renameGroup should emit scheduleCheckpoint")
    }

    @Test("toggleGroupCollapse emits scheduleCheckpoint")
    func toggleGroupCollapseEmitsScheduleCheckpoint() {
        // Intent: toggleGroupCollapse emits scheduleCheckpoint.
        // Why it exists: pins collapse-state persistence.
        // Scenario: spec-first toggleGroupCollapse emit.
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .toggleGroupCollapse(groupId: model.groups[0].id))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "toggleGroupCollapse should emit scheduleCheckpoint")
    }

    @Test("toggleZoomPane does not emit scheduleCheckpoint — zoom is transient")
    func toggleZoomPaneDoesNotEmitScheduleCheckpoint() {
        // Intent: toggleZoomPane does NOT emit scheduleCheckpoint
        //   (zoom is a transient view-state).
        // Why it exists: pins the transient-vs-persistent boundary.
        // Scenario: spec-first transient zoom.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let commands = update(&model, .toggleZoomPane)
        #expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "toggleZoomPane should not emit scheduleCheckpoint")
    }

    @Test("splitRatioChanged emits scheduleCheckpoint")
    func splitRatioChangedEmitsScheduleCheckpoint() {
        // Intent: splitRatioChanged emits scheduleCheckpoint.
        // Why it exists: pins divider-drag persistence.
        // Scenario: spec-first splitRatioChanged emit.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let tab = selectedTab(in: model)!
        guard case .split(let splitId, _, _, _, _) = tab.rootNode else {
            Issue.record("expected split node")
            return
        }
        let commands = update(&model, .splitRatioChanged(splitId: splitId, ratio: 0.3))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "splitRatioChanged should emit scheduleCheckpoint")
    }

    // MARK: - Non-mutating cases do NOT emit scheduleCheckpoint

    @Test("requestCloseTab does not emit scheduleCheckpoint")
    func requestCloseTabDoesNotEmitScheduleCheckpoint() {
        // Intent: requestCloseTab is non-mutating; no checkpoint.
        // Why it exists: pins the non-mutating boundary.
        // Scenario: spec-first requestCloseTab no-emit.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let commands = update(&model, .requestCloseTab(id: tabId))
        #expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "requestCloseTab should not emit scheduleCheckpoint")
    }

    @Test("exportState does not emit scheduleCheckpoint")
    func exportStateDoesNotEmitScheduleCheckpoint() {
        // Intent: exportState is non-mutating; no checkpoint.
        // Why it exists: pins the boundary for read-only exports.
        // Scenario: spec-first exportState no-emit.
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .exportState)
        #expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "exportState should not emit scheduleCheckpoint")
    }

    @Test("appBecameActive does not emit scheduleCheckpoint")
    func appBecameActiveDoesNotEmitScheduleCheckpoint() {
        // Intent: appBecameActive is non-mutating; no checkpoint.
        // Why it exists: pins the lifecycle no-checkpoint rule.
        // Scenario: spec-first appBecameActive no-emit.
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .appBecameActive)
        #expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "appBecameActive should not emit scheduleCheckpoint")
    }

    @Test("appResignedActive does not emit scheduleCheckpoint")
    func appResignedActiveDoesNotEmitScheduleCheckpoint() {
        // Intent: appResignedActive is non-mutating; no checkpoint.
        // Why it exists: pins the symmetric lifecycle rule.
        // Scenario: spec-first appResignedActive no-emit.
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .appResignedActive)
        #expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "appResignedActive should not emit scheduleCheckpoint")
    }

    @Test("surfaceBell does not emit scheduleCheckpoint")
    func surfaceBellDoesNotEmitScheduleCheckpoint() {
        // Intent: surfaceBell (which creates alerts but no structural
        //   model change) does NOT emit scheduleCheckpoint.
        // Why it exists: pins the alerts-are-transient rule.
        // Scenario: spec-first surfaceBell no-emit.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let commands = update(&model, .surfaceBell(paneId: paneId))
        #expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "surfaceBell should not emit scheduleCheckpoint")
    }

    @Test("cancelTerminate does not emit scheduleCheckpoint")
    func cancelTerminateDoesNotEmitScheduleCheckpoint() {
        // Intent: cancelTerminate is non-mutating; no checkpoint.
        // Why it exists: pins the no-emit on cancel.
        // Scenario: spec-first cancelTerminate no-emit.
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .cancelTerminate)
        #expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "cancelTerminate should not emit scheduleCheckpoint")
    }

    // MARK: - Snapshot fidelity

    @Test("toSnapshot does not persist isZoomed — restored tabs are always unzoomed")
    func toSnapshotDoesNotPersistIsZoomed() throws {
        // Intent: snapshot round-trip clears isZoomed; restored tabs
        //   are always unzoomed.
        // Why it exists: pins the transient-zoom rule for restore.
        // Scenario: spec-first restore unzoom.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        update(&model, .toggleZoomPane)
        let tab = selectedTab(in: model)!
        #expect(tab.isZoomed, "tab should be zoomed before snapshot")

        let snapshot = toSnapshot(model)
        let restored = try #require(validateAndBuild(snapshot), "snapshot round-trip failed")
        let restoredTab = selectedTab(in: restored)!
        #expect(!restoredTab.isZoomed, "restored tab should not be zoomed")
    }

    // MARK: - Session Lock round-trip

    @Test("SessionLock round-trips through write/read helpers")
    func sessionLockRoundTripsThroughWriteReadHelpers() throws {
        // Intent: writeSessionLockFile creates a session.json on disk
        //   that readSessionLockFile parses back into a SessionLock;
        //   deleteSessionLockFile removes it.
        // Why it exists: pins the lock-file I/O contract end to end.
        //   The injectable CoreEnv is pointed at a per-test temp dir and
        //   frozen clock so the suite is hermetic + parallel-safe. The
        //   on-disk fileExists assertions verify the recovery-dir seam;
        //   the startedAt assertion verifies the now seam.
        // Scenario: spec-first session-lock I/O at a per-test temp dir.
        let recoveryDir = makeTestRecoveryDir()
        let frozenNow = Date(timeIntervalSince1970: 1_700_000_000)
        let testEnv = makeTestEnv(recoveryDir: recoveryDir, now: frozenNow)
        defer { try? FileManager.default.removeItem(at: recoveryDir) }

        writeSessionLockFile(env: testEnv)
        let sessionJSONPath = recoveryDir.appendingPathComponent("session.json").path
        #expect(FileManager.default.fileExists(atPath: sessionJSONPath),
            "writeSessionLockFile should create session.json under the temp dir")
        let lock = try #require(readSessionLockFile(env: testEnv),
            "readSessionLockFile returned nil after write")
        #expect(lock.pid == ProcessInfo.processInfo.processIdentifier, "pid should match")
        #expect(lock.startedAt == frozenNow, "startedAt should use env.now")
        deleteSessionLockFile(env: testEnv)
        #expect(!FileManager.default.fileExists(atPath: sessionJSONPath),
            "deleteSessionLockFile should remove the temp session.json")
        let deleted = readSessionLockFile(env: testEnv)
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
        let prodURL = recoveryDirectoryURL(bundleId: "com.danneu.danterm")
        let devURL  = recoveryDirectoryURL(bundleId: "com.danneu.danterm-dev")
        #expect(prodURL != devURL, "prod and dev paths must differ, both were \(prodURL.path)")
        #expect(prodURL.path.hasSuffix("/Library/Application Support/com.danneu.danterm/Recovery"),
            "prod path wrong: \(prodURL.path)")
        #expect(devURL.path.hasSuffix("/Library/Application Support/com.danneu.danterm-dev/Recovery"),
            "dev path wrong: \(devURL.path)")
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

    // MARK: - mergeCheckpoints (single-format, on the validated pair)

    @Test("mergeCheckpoints grafts enriched scrollback into light's pane map by id")
    func mergeCheckpointsGraftsEnrichedScrollbackIntoLight() {
        // Intent: enriched scrollback grafts into light's pane map by
        //   id; light's title/cwd win over enriched.
        // Why it exists: pins the merge precedence.
        // Scenario: spec-first merge graft.
        let p1 = PaneId()
        let light = makeRestore([p1: paneSnap(p1, title: "light-title", cwd: "/light")], model: makeModel())
        let enriched = makeRestore([p1: paneSnap(p1, title: "old-title", cwd: "/old", scrollback: "saved scrollback")], model: makeModel())
        let merged = mergeCheckpoints(light: light, enriched: enriched)
        #expect(merged.paneSnapshots.count == 1, "should have 1 pane")
        #expect(merged.paneSnapshots[p1]?.title == "light-title", "title should come from light")
        #expect(merged.paneSnapshots[p1]?.cwd == "/light", "cwd should come from light")
        #expect(merged.paneSnapshots[p1]?.scrollback == "saved scrollback", "scrollback should come from enriched")
    }

    @Test("mergeCheckpoints — pane in light but not enriched gets nil scrollback")
    func mergeCheckpointsLightOnlyPaneGetsNilScrollback() {
        // Intent: a pane present in light but missing from enriched
        //   gets nil scrollback (no graft).
        // Why it exists: pins the missing-enriched branch.
        // Scenario: spec-first light-only.
        let p1 = PaneId()
        let light = makeRestore([p1: paneSnap(p1, title: "new", cwd: "/new")], model: makeModel())
        let enriched = makeRestore([:], model: makeModel())
        let merged = mergeCheckpoints(light: light, enriched: enriched)
        #expect(merged.paneSnapshots.count == 1, "should have 1 pane")
        #expect(merged.paneSnapshots[p1]?.scrollback == nil, "new pane should have nil scrollback")
    }

    @Test("mergeCheckpoints — pane in enriched but not light is discarded; light structure wins")
    func mergeCheckpointsEnrichedOnlyDiscardedLightStructureWins() {
        // Intent: a pane present in enriched but not in light is
        //   discarded; the model/structure comes from light.
        // Why it exists: pins the "light wins" structure rule.
        // Scenario: spec-first enriched-only discard.
        let enrichedOnly = PaneId()
        var enrichedModel = makeModel()
        enrichedModel.groups.append(GroupModel(id: GroupId(), name: "Extra"))
        let light = makeRestore([:], model: makeModel())
        let enriched = makeRestore([enrichedOnly: paneSnap(enrichedOnly, title: "old", scrollback: "old scrollback")], model: enrichedModel)
        let merged = mergeCheckpoints(light: light, enriched: enriched)
        #expect(merged.paneSnapshots[enrichedOnly] == nil, "enriched-only pane should not appear")
        #expect(merged.paneSnapshots.count == 0, "only light's panes survive")
        #expect(merged.model.groups.count == light.model.groups.count, "model/structure comes from light")
    }

    @Test("mergeCheckpoints — light metadata wins over enriched")
    func mergeCheckpointsLightMetadataWinsOverEnriched() {
        // Intent: light's title/cwd win even when enriched supplies
        //   stale values.
        // Why it exists: pins the field-level precedence.
        // Scenario: spec-first metadata precedence.
        let p1 = PaneId()
        let light = makeRestore([p1: paneSnap(p1, title: "fresh-title", cwd: "/fresh")], model: makeModel())
        let enriched = makeRestore([p1: paneSnap(p1, title: "stale-title", cwd: "/stale", scrollback: "text")], model: makeModel())
        let merged = mergeCheckpoints(light: light, enriched: enriched)
        #expect(merged.paneSnapshots[p1]?.title == "fresh-title", "title from light")
        #expect(merged.paneSnapshots[p1]?.cwd == "/fresh", "cwd from light")
        #expect(merged.paneSnapshots[p1]?.scrollback == "text", "scrollback from enriched")
    }

    @Test("mergeCheckpoints — empty enriched panes returns light unchanged")
    func mergeCheckpointsEmptyEnrichedReturnsLightUnchanged() {
        // Intent: empty enriched produces a merge equal to light (no
        //   scrollback added).
        // Why it exists: pins the no-op-on-empty branch.
        // Scenario: spec-first empty enriched.
        let p1 = PaneId()
        let light = makeRestore([p1: paneSnap(p1, title: "t", cwd: "/c")], model: makeModel())
        let enriched = makeRestore([:], model: makeModel())
        let merged = mergeCheckpoints(light: light, enriched: enriched)
        #expect(merged.paneSnapshots.count == 1, "pane count matches light")
        #expect(merged.paneSnapshots[p1]?.scrollback == nil, "no scrollback available")
        #expect(merged.paneSnapshots[p1]?.title == "t", "metadata unchanged")
    }
}
