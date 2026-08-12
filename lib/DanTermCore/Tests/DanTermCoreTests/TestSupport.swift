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
import Synchronization
import Testing
import DanTermProtocol

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

/// The identity a test gets unless it asks for another: production, so a test
/// that never thinks about identity cannot accidentally hold a privilege.
func makeTestEnv(
    now: Date = Date(timeIntervalSince1970: 1_700_000_000),
    idSequence: [UUID] = [],
    homeDirectory: String = "/Users/testhome",
    instanceIdentity: DanTermInstanceIdentity = DanTermInstanceIdentity(
        bundleIdentifier: "com.danneu.danterm"
    )
) -> CoreEnv {
    // CoreEnv's seams are @Sendable, so the cursor into idSequence cannot be a
    // captured `var`. Tests drive it from one thread; the mutex is what lets the
    // closure carry state at all.
    let index = Mutex(0)
    return CoreEnv(
        newId: {
            let next = index.withLock { current -> Int in
                defer { current += 1 }
                return current
            }
            guard next < idSequence.count else {
                Issue.record("makeTestEnv idSequence exhausted at index \(next); add more ids")
                return UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
            }
            return idSequence[next]
        },
        now: { now },
        homeDirectory: { homeDirectory },
        instanceIdentity: { instanceIdentity }
    )
}

/// Create a tab and return the commands (for inspection or ignoring).
@discardableResult
func createTab(_ model: inout AppModel, inGroupId: GroupId? = nil, background: Bool = false) -> [Command] {
    if let inGroupId {
        return update(&model, .createTab(inGroupId: inGroupId, background: background))
    }
    return update(&model, .createTabInSelectedGroup(background: background))
}

func hasEffect(_ commands: [Command], _ check: (Command) -> Bool) -> Bool {
    commands.contains(where: check)
}

func sessionId(for paneId: PaneId, in model: AppModel) -> SessionId {
    guard let sessionId = model.pane(paneId)?.session?.id else {
        preconditionFailure("test pane has no terminal session")
    }
    return sessionId
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
