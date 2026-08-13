// Swift Testing coverage for checkpoint snapshot fidelity and merge rules. Projection-derived
// scheduling behavior lives in CheckpointCaptureTests; this suite keeps the persisted codec
// contract and the enriched-scrollback merge independent of runtime disk I/O.
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
    // MARK: - Snapshot fidelity

    @Test("toSnapshot does not persist isZoomed — restored tabs are always unzoomed")
    func toSnapshotDoesNotPersistIsZoomed() throws {
        // Intent: snapshot round-trip clears isZoomed; restored tabs
        //   are always unzoomed.
        // Why it exists: pins the transient-zoom rule for restore.
        // Scenario: spec-first restore unzoom.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        update(&model, .toggleZoomPane(paneId: nil))
        let tab = selectedTab(in: model)!
        #expect(tab.paneTree.isZoomed, "tab should be zoomed before snapshot")

        let snapshot = toSnapshot(model)
        let restored = try #require(validateAndBuild(snapshot), "snapshot round-trip failed")
        let restoredTab = selectedTab(in: restored)!
        #expect(!restoredTab.paneTree.isZoomed, "restored tab should not be zoomed")
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
