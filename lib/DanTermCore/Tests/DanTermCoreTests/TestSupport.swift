// Shared fixtures for the Swift Testing suites that exercise DanTermCore. The
// model builders (makeModel, createTab), command-effect probe (hasEffect), and
// snapshot readers (paneSnapshots / allPaneSnapshots / paneSnapshot) move here
// verbatim from the legacy `tests/TestHarness.swift` so each migrated suite
// stays behaviorally 1:1 with what it replaced.
//
// The harness PRIMITIVES (`test`/`expect`/`expectEqual`/`TestFailure` and the
// `failures`/`total` globals) intentionally do NOT move -- Swift Testing's
// `#expect` / `#require` / `expectNoDifference` (from swift-custom-dump)
// replace them with framework-native diffs, source-location capture, and
// parallel-safe reporting.
import Foundation
import Testing

@testable import DanTermCore

func makeModel() -> AppModel {
    let generalId = GroupId()
    return AppModel(
        groups: [GroupModel(id: generalId, name: "General")]
    )
}

func makeModel(env: CoreEnv) -> AppModel {
    let generalId = GroupId(rawValue: env.newId())
    return AppModel(
        groups: [GroupModel(id: generalId, name: "General")]
    )
}

func makeTestEnv(
    now: Date = Date(timeIntervalSince1970: 1_700_000_000),
    idSequence: [UUID] = [],
    homeDirectory: String = "/Users/testhome"
) -> CoreEnv {
    var index = 0
    return CoreEnv(
        newId: {
            defer { index += 1 }
            guard index < idSequence.count else {
                Issue.record("makeTestEnv idSequence exhausted at index \(index); add more ids")
                return UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
            }
            return idSequence[index]
        },
        now: { now },
        homeDirectory: { homeDirectory }
    )
}

/// Keeps semantics-independent tests terse while production callers must
/// always supply the pane-owner view explicitly.
@discardableResult
func update(_ model: inout AppModel, _ msg: Msg, env: CoreEnv = .live) -> [Command] {
    update(&model, msg, livePaneState: LivePaneStateView(), env: env)
}

func desiredPaneToolbar(in model: AppModel) -> [PaneId: PaneToolbarRender] {
    desiredPaneToolbar(in: model, livePaneState: LivePaneStateView())
}

func desiredPaneToolbar(
    in model: AppModel,
    tally: UnreadAlertTally
) -> [PaneId: PaneToolbarRender] {
    desiredPaneToolbar(in: model, tally: tally, livePaneState: LivePaneStateView())
}

func desiredPaneConfig(in model: AppModel) -> [PaneId: PaneConfigKey] {
    desiredPaneConfig(in: model, livePaneState: LivePaneStateView())
}

/// Create a tab and return the commands (for inspection or ignoring).
@discardableResult
func createTab(_ model: inout AppModel, inGroupId: GroupId? = nil, background: Bool = false) -> [Command] {
    return update(&model, .createTab(inGroupId: inGroupId, background: background))
}

func hasEffect(_ commands: [Command], _ check: (Command) -> Bool) -> Bool {
    commands.contains(where: check)
}

// MARK: - Snapshot (v3 leaf-embedded) test helpers

/// Collect every leaf's embedded PaneSnapshot from a snapshot split tree.
func paneSnapshots(in node: SplitNodeSnapshot) -> [PaneSnapshot] {
    switch node {
    case .leaf(let ps): return [ps]
    case .split(_, _, let first, let second, _):
        return paneSnapshots(in: first) + paneSnapshots(in: second)
    }
}

/// Every PaneSnapshot embedded across all of a snapshot's tab trees.
func allPaneSnapshots(_ snapshot: AppModelSnapshot) -> [PaneSnapshot] {
    snapshot.groups.flatMap(\.tabs).flatMap { paneSnapshots(in: $0.rootNode) }
}

/// Find an embedded PaneSnapshot by its id string.
func paneSnapshot(_ id: String, in snapshot: AppModelSnapshot) -> PaneSnapshot? {
    allPaneSnapshots(snapshot).first { $0.id == id }
}

/// Build a model with N tabs in one group; returns the tab ids in display order.
/// Used by MRU/cycle tests in ModelOperationsTests and UpdateMruTests.
func makeMruModel(tabCount: Int) -> (model: AppModel, tabIds: [TabId]) {
    var model = makeModel()
    var ids: [TabId] = []
    for _ in 0..<tabCount {
        let paneId = PaneId()
        let tabId = TabId()
        ids.append(tabId)
        model.groups[0].tabs.append(TabModel(id: tabId, focusedPaneId: paneId, rootNode: .leaf(PaneModel(id: paneId))))
    }
    return (model, ids)
}
