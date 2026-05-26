// Tests for session persistence: .scheduleCheckpoint emission, session lock
// round-tripping, and recovery path helpers.
import Foundation

// mergeCheckpoints now operates on the validated pair: it only reads each
// restore's `paneSnapshots` map and copies light's `model`/`snapshot`. These
// helpers build a ValidatedAppRestore from an explicit pane map + a model whose
// identity the "structure wins" assertions check.
private func makeRestore(_ paneSnapshots: [PaneId: PaneSnapshot], model: AppModel) -> ValidatedAppRestore {
    ValidatedAppRestore(snapshot: toSnapshot(model), model: model, paneSnapshots: paneSnapshots)
}

private func paneSnap(_ id: PaneId, title: String, cwd: String? = nil, scrollback: String? = nil, theme: String? = nil) -> PaneSnapshot {
    PaneSnapshot(id: id.rawValue.uuidString, title: title, cwd: cwd, launch: nil, scrollback: scrollback, theme: theme)
}

func checkpointTests() {
    print("Checkpoint Tests...")

    // MARK: - scheduleCheckpoint emission

    test("createTab emits scheduleCheckpoint") {
        var model = makeModel()
        let commands = update(&model, .createTab(inGroupId: nil))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "createTab should emit scheduleCheckpoint")
    }

    test("selectTab emits scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let commands = update(&model, .selectTab(id: tabId))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "selectTab should emit scheduleCheckpoint")
    }

    test("closeTab emits scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let commands = update(&model, .closeTab(id: tabId))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "closeTab should emit scheduleCheckpoint")
    }

    test("splitPane emits scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .splitPane(direction: .horizontal))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "splitPane should emit scheduleCheckpoint")
    }

    test("closePane emits scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let tab = selectedTab(in: model)!
        let paneToClose = allPaneIds(tab.rootNode).last!
        let commands = update(&model, .closePane(paneId: paneToClose))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "closePane should emit scheduleCheckpoint")
    }

    test("surfaceTitle emits scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let commands = update(&model, .surfaceTitle(paneId: paneId, title: "new title"))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "surfaceTitle should emit scheduleCheckpoint")
    }

    test("surfaceCwd emits scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let commands = update(&model, .surfaceCwd(paneId: paneId, cwd: "/tmp"))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "surfaceCwd should emit scheduleCheckpoint")
    }

    test("commandStarted emits scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let commands = update(&model, .commandStarted(paneId: paneId, command: "ls"))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "commandStarted should emit scheduleCheckpoint")
    }

    test("renameTab emits scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let commands = update(&model, .renameTab(id: tabId, name: "MyTab"))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "renameTab should emit scheduleCheckpoint")
    }

    test("setTabColors emits scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let commands = update(&model, .setTabColors(tabIds: [tabId], color: .red))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "setTabColors should emit scheduleCheckpoint")
    }

    test("renameGroup emits scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .renameGroup(id: model.groups[0].id, name: "Renamed"))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "renameGroup should emit scheduleCheckpoint")
    }

    test("toggleGroupCollapse emits scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .toggleGroupCollapse(groupId: model.groups[0].id))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "toggleGroupCollapse should emit scheduleCheckpoint")
    }

    test("toggleZoomPane does not emit scheduleCheckpoint — zoom is transient") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let commands = update(&model, .toggleZoomPane)
        try expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "toggleZoomPane should not emit scheduleCheckpoint")
    }

    test("splitRatioChanged emits scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let tab = selectedTab(in: model)!
        guard case .split(let splitId, _, _, _, _) = tab.rootNode else {
            throw TestFailure(message: "expected split node")
        }
        let commands = update(&model, .splitRatioChanged(splitId: splitId, ratio: 0.3))
        try expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "splitRatioChanged should emit scheduleCheckpoint")
    }

    // MARK: - Non-mutating cases do NOT emit scheduleCheckpoint

    test("requestCloseTab does not emit scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let commands = update(&model, .requestCloseTab(id: tabId))
        try expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "requestCloseTab should not emit scheduleCheckpoint")
    }

    test("exportState does not emit scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .exportState)
        try expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "exportState should not emit scheduleCheckpoint")
    }

    test("appBecameActive does not emit scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .appBecameActive)
        try expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "appBecameActive should not emit scheduleCheckpoint")
    }

    test("appResignedActive does not emit scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .appResignedActive)
        try expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "appResignedActive should not emit scheduleCheckpoint")
    }

    test("surfaceBell does not emit scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        // Bell on non-focused pane of non-selected tab
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let commands = update(&model, .surfaceBell(paneId: paneId))
        try expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "surfaceBell should not emit scheduleCheckpoint")
    }

    test("cancelTerminate does not emit scheduleCheckpoint") {
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .cancelTerminate)
        try expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                   "cancelTerminate should not emit scheduleCheckpoint")
    }

    // MARK: - Snapshot fidelity

    test("toSnapshot does not persist isZoomed — restored tabs are always unzoomed") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        update(&model, .toggleZoomPane)
        let tab = selectedTab(in: model)!
        try expect(tab.isZoomed, "tab should be zoomed before snapshot")

        // Round-trip through snapshot
        let snapshot = toSnapshot(model)
        guard let restored = validateAndBuild(snapshot) else {
            throw TestFailure(message: "snapshot round-trip failed")
        }
        let restoredTab = selectedTab(in: restored)!
        try expect(!restoredTab.isZoomed, "restored tab should not be zoomed")
    }

    // MARK: - Session Lock round-trip

    test("SessionLock round-trips through write/read helpers") {
        // Write a session lock and read it back
        writeSessionLockFile()
        guard let lock = readSessionLockFile() else {
            throw TestFailure(message: "readSessionLockFile returned nil after write")
        }
        try expectEqual(lock.pid, ProcessInfo.processInfo.processIdentifier, "pid should match")
        // Verify timestamp is recent (within last 5 seconds)
        let age = Date().timeIntervalSince(lock.startedAt)
        try expect(age >= 0 && age < 5, "startedAt should be recent, age was \(age)")
        // Clean up
        deleteSessionLockFile()
        let deleted = readSessionLockFile()
        try expect(deleted == nil, "lock should be nil after delete")
    }

    // MARK: - Recovery path helpers

    test("recoveryDirectoryURL is namespaced by bundle identifier") {
        // Dev and Prod bundles must map to distinct recovery directories so
        // launching DanTerm Dev never reads DanTerm.app's session files.
        let prodURL = recoveryDirectoryURL(bundleId: "com.danneu.danterm")
        let devURL  = recoveryDirectoryURL(bundleId: "com.danneu.danterm-dev")
        try expect(prodURL != devURL, "prod and dev paths must differ, both were \(prodURL.path)")
        try expect(prodURL.path.hasSuffix("/Library/Application Support/com.danneu.danterm/Recovery"),
                   "prod path wrong: \(prodURL.path)")
        try expect(devURL.path.hasSuffix("/Library/Application Support/com.danneu.danterm-dev/Recovery"),
                   "dev path wrong: \(devURL.path)")
    }

    test("lightCheckpointURL ends with last-light.json") {
        let url = lightCheckpointURL()
        try expect(url.lastPathComponent == "last-light.json", "expected last-light.json, got \(url.lastPathComponent)")
    }

    test("enrichedCheckpointURL ends with last-enriched.json") {
        let url = enrichedCheckpointURL()
        try expect(url.lastPathComponent == "last-enriched.json", "expected last-enriched.json, got \(url.lastPathComponent)")
    }

    test("sessionLockURL ends with session.json") {
        let url = sessionLockURL()
        try expect(url.lastPathComponent == "session.json", "expected session.json, got \(url.lastPathComponent)")
    }

    // MARK: - mergeCheckpoints (single-format, on the validated pair)

    test("mergeCheckpoints grafts enriched scrollback into light's pane map by id") {
        let p1 = PaneId()
        let light = makeRestore([p1: paneSnap(p1, title: "light-title", cwd: "/light")], model: makeModel())
        let enriched = makeRestore([p1: paneSnap(p1, title: "old-title", cwd: "/old", scrollback: "saved scrollback")], model: makeModel())
        let merged = mergeCheckpoints(light: light, enriched: enriched)
        try expectEqual(merged.paneSnapshots.count, 1, "should have 1 pane")
        try expectEqual(merged.paneSnapshots[p1]?.title, "light-title", "title should come from light")
        try expectEqual(merged.paneSnapshots[p1]?.cwd, "/light", "cwd should come from light")
        try expectEqual(merged.paneSnapshots[p1]?.scrollback, "saved scrollback", "scrollback should come from enriched")
    }

    test("mergeCheckpoints — pane in light but not enriched gets nil scrollback") {
        let p1 = PaneId()
        let light = makeRestore([p1: paneSnap(p1, title: "new", cwd: "/new")], model: makeModel())
        let enriched = makeRestore([:], model: makeModel())
        let merged = mergeCheckpoints(light: light, enriched: enriched)
        try expectEqual(merged.paneSnapshots.count, 1, "should have 1 pane")
        try expect(merged.paneSnapshots[p1]?.scrollback == nil, "new pane should have nil scrollback")
    }

    test("mergeCheckpoints — pane in enriched but not light is discarded; light structure wins") {
        let enrichedOnly = PaneId()
        // light: a one-group model with no panes; enriched: a different (two-group) model.
        var enrichedModel = makeModel()
        enrichedModel.groups.append(GroupModel(id: GroupId(), name: "Extra"))
        let light = makeRestore([:], model: makeModel())
        let enriched = makeRestore([enrichedOnly: paneSnap(enrichedOnly, title: "old", scrollback: "old scrollback")], model: enrichedModel)
        let merged = mergeCheckpoints(light: light, enriched: enriched)
        try expect(merged.paneSnapshots[enrichedOnly] == nil, "enriched-only pane should not appear")
        try expectEqual(merged.paneSnapshots.count, 0, "only light's panes survive")
        try expectEqual(merged.model.groups.count, light.model.groups.count, "model/structure comes from light")
    }

    test("mergeCheckpoints — light metadata wins over enriched") {
        let p1 = PaneId()
        let light = makeRestore([p1: paneSnap(p1, title: "fresh-title", cwd: "/fresh")], model: makeModel())
        let enriched = makeRestore([p1: paneSnap(p1, title: "stale-title", cwd: "/stale", scrollback: "text")], model: makeModel())
        let merged = mergeCheckpoints(light: light, enriched: enriched)
        try expectEqual(merged.paneSnapshots[p1]?.title, "fresh-title", "title from light")
        try expectEqual(merged.paneSnapshots[p1]?.cwd, "/fresh", "cwd from light")
        try expectEqual(merged.paneSnapshots[p1]?.scrollback, "text", "scrollback from enriched")
    }

    test("mergeCheckpoints — empty enriched panes returns light unchanged") {
        let p1 = PaneId()
        let light = makeRestore([p1: paneSnap(p1, title: "t", cwd: "/c")], model: makeModel())
        let enriched = makeRestore([:], model: makeModel())
        let merged = mergeCheckpoints(light: light, enriched: enriched)
        try expectEqual(merged.paneSnapshots.count, 1, "pane count matches light")
        try expect(merged.paneSnapshots[p1]?.scrollback == nil, "no scrollback available")
        try expectEqual(merged.paneSnapshots[p1]?.title, "t", "metadata unchanged")
    }
}
