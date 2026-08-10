// Swift Testing migration of the legacy `tests/CheckpointTests.swift` harness
// suite. Pins .scheduleCheckpoint emission across mutating handlers,
// non-mutating-no-emission cases, snapshot fidelity (toSnapshot drops
// isZoomed), and the mergeCheckpoints rules (enriched scrollback grafted into
// light's pane map; light structure wins; metadata from light; empty enriched).
// All pure update()/codec assertions -- no disk I/O. The session-lock round-trip
// and recovery-path-helper tests moved to DanTermSupport's RecoveryStoreTests in
// the Phase 4 persistence split, taking the FileManager/temp-dir machinery with
// them; what stays here touches no filesystem and needs no env seams.
import Foundation
import Testing

@testable import DanTermCore

private func makeRestore(_ paneSnapshots: [PaneId: PaneSnapshot], model: AppModel) -> ValidatedAppRestore {
    ValidatedAppRestore(snapshot: toSnapshot(model), model: model, paneSnapshots: paneSnapshots)
}

private func paneSnap(_ id: PaneId, title: String, cwd: String? = nil, scrollback: String? = nil, theme: String? = nil) -> PaneSnapshot {
    PaneSnapshot(id: id.rawValue.uuidString, title: title, cwd: cwd, command: nil, scrollback: scrollback, theme: theme)
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

    @Test("sessionTitle emits scheduleCheckpoint")
    func sessionTitleEmitsScheduleCheckpoint() {
        // Intent: sessionTitle emits scheduleCheckpoint.
        // Why it exists: pins session metadata persistence.
        // Scenario: spec-first sessionTitle emit.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let commands = update(&model, .sessionTitle(paneId: paneId, title: "new title"))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "sessionTitle should emit scheduleCheckpoint")
    }

    @Test("sessionCwd emits scheduleCheckpoint")
    func sessionCwdEmitsScheduleCheckpoint() {
        // Intent: sessionCwd emits scheduleCheckpoint.
        // Why it exists: pins cwd-update persistence.
        // Scenario: spec-first sessionCwd emit.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let commands = update(&model, .sessionCwd(paneId: paneId, cwd: "/tmp"))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "sessionCwd should emit scheduleCheckpoint")
    }

    @Test("commandStarted emits scheduleCheckpoint")
    func commandStartedEmitsScheduleCheckpoint() {
        // Intent: commandStarted emits scheduleCheckpoint.
        // Why it exists: pins command-start persistence.
        // Scenario: spec-first commandStarted emit.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        var stream = PaneSemanticStream()
        let commands = update(&model, .paneSemanticsChanged(
            paneId: paneId,
            event: stream.apply(.commandStarted("ls")).event
        ))
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "commandStarted should emit scheduleCheckpoint")
    }

    @Test("command-ended checkpoint decision reads the live pane-state view")
    func commandEndedCheckpointReadsLivePaneState() throws {
        // Intent: one semantic event produces different checkpoint behavior from
        //   different views of the pane owner's current state.
        // Why it exists: prevents message payloads from becoming a second owner
        //   of pane semantics after update() gains its live-state view.
        // Scenario: spec-first comparison of an attached-agent pane and a local pane.
        var attachedModel = makeModel()
        createTab(&attachedModel)
        let paneId = attachedModel.groups[0].tabs[0].focusedPaneId
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        let attachedView = LivePaneStateView(semanticsByPaneId: [
            paneId: PaneSemanticState(agent: .attached(session: agent, activity: .idle)),
        ])
        let localView = LivePaneStateView()

        var localModel = attachedModel
        let attachedCommands = update(
            &attachedModel,
            .paneSemanticsChanged(paneId: paneId, event: .commandEnded(exitStatus: 0)),
            livePaneState: attachedView
        )
        let localCommands = update(
            &localModel,
            .paneSemanticsChanged(paneId: paneId, event: .commandEnded(exitStatus: 0)),
            livePaneState: localView
        )

        #expect(hasEffect(attachedCommands) { if case .scheduleCheckpoint = $0 { true } else { false } })
        #expect(localCommands.isEmpty)
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
        let commands = update(&model, .toggleZoomPane(paneId: nil))
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

    @Test("sessionBell does not emit scheduleCheckpoint")
    func sessionBellDoesNotEmitScheduleCheckpoint() {
        // Intent: sessionBell (which creates alerts but no structural
        //   model change) does NOT emit scheduleCheckpoint.
        // Why it exists: pins the alerts-are-transient rule.
        // Scenario: spec-first sessionBell no-emit.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let commands = update(&model, .sessionBell(paneId: paneId))
        #expect(!hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
            "sessionBell should not emit scheduleCheckpoint")
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
        update(&model, .toggleZoomPane(paneId: nil))
        let tab = selectedTab(in: model)!
        #expect(tab.isZoomed, "tab should be zoomed before snapshot")

        let snapshot = toSnapshot(model)
        let restored = try #require(validateAndBuild(snapshot), "snapshot round-trip failed")
        let restoredTab = selectedTab(in: restored)!
        #expect(!restoredTab.isZoomed, "restored tab should not be zoomed")
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
