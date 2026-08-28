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
//
// The env builders (makeTestEnv, TestClock) did not come from the legacy
// harness: they are the seam CoreEnv exposes, so a test states the ids, time,
// home, and identity it runs against instead of inheriting the process's.
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

/// A clock a test moves by hand, so a test can stand on both sides of a
/// time-based boundary in the reducer (notification throttling) instead of
/// depending on how long two `update()` calls take in wall-clock time.
/// `CoreEnv.now` is `@Sendable`, so the current time lives in a mutex rather
/// than a captured `var`.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = testEpoch) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        current.withLock { $0 += interval }
    }
}

/// The instant a test env reports unless it asks for another. Fixed, so a value
/// a test asserts against is a value it can write down.
let testEpoch = Date(timeIntervalSince1970: 1_700_000_000)

private let testHomeDirectory = "/Users/testhome"
private let testInstanceIdentity = DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm")

/// The env for a test whose clock never has to move: `now` is one constant.
/// The identity a test gets unless it asks for another is production, so a test
/// that never thinks about identity cannot accidentally hold a privilege.
func makeTestEnv(
    now: Date = testEpoch,
    idSequence: [UUID] = [],
    homeDirectory: String = testHomeDirectory,
    instanceIdentity: DanTermInstanceIdentity = testInstanceIdentity
) -> CoreEnv {
    makeTestEnv(
        clock: TestClock(now),
        idSequence: idSequence,
        homeDirectory: homeDirectory,
        instanceIdentity: instanceIdentity
    )
}

/// The env builder a test uses when it needs to move time mid-sequence. The
/// constant-`now` form above is sugar over this one, so both share one body.
func makeTestEnv(
    clock: TestClock,
    idSequence: [UUID] = [],
    homeDirectory: String = testHomeDirectory,
    instanceIdentity: DanTermInstanceIdentity = testInstanceIdentity
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
        now: { clock.now },
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

func pendingAppConfirmation() -> PendingConfirmation {
    PendingConfirmation(
        id: ConfirmationId(),
        kind: .quit
    )
}

func pendingCloseConfirmation(
    for target: CloseTarget,
    in model: AppModel
) -> PendingConfirmation {
    var copy = model
    _ = emitConfirmation(&copy, target: target, env: makeTestEnv(idSequence: [UUID()]))
    guard let pending = copy.pendingConfirmation else {
        preconditionFailure("close-confirmation test target must be live")
    }
    return pending
}

func closePaneTarget(_ paneId: PaneId, quitAuthorized: Bool = false) -> CloseTarget {
    .pane(paneId, quitAuthorized: quitAuthorized)
}

func closeTabTarget(
    _ tabId: TabId,
    in model: AppModel,
    quitAuthorized: Bool = false
) -> CloseTarget {
    guard let tab = tabById(tabId, in: model) else {
        preconditionFailure("close-confirmation test tab must be live")
    }
    return .tab(
        tabId,
        title: DisplayLine(tabDisplayTitle(tab)),
        quitAuthorized: quitAuthorized
    )
}

func closeTabsTarget(_ tabIds: [TabId], quitAuthorized: Bool = false) -> CloseTarget {
    .tabs(tabIds, quitAuthorized: quitAuthorized)
}

enum TestConfirmationKind: Equatable {
    case deleteGroup(GroupId)
    case app
}

func testConfirmationKind(_ pending: PendingConfirmation?) -> TestConfirmationKind? {
    guard let pending else { return nil }
    switch pending.kind {
    case .quit:
        return .app
    case .close:
        return nil
    case .deleteGroup(let groupId, _):
        return .deleteGroup(groupId)
    }
}

func pendingCloseImpact(_ pending: PendingConfirmation?) -> CloseImpact? {
    guard let pending else { return nil }
    switch pending.kind {
    case .close(_, let impact):
        return impact
    case .quit, .deleteGroup:
        return nil
    }
}

func pendingCloseTarget(_ pending: PendingConfirmation?) -> CloseTarget? {
    guard let pending, case .close(let target, _) = pending.kind else { return nil }
    return target
}

func pendingClosePaneId(_ pending: PendingConfirmation?) -> PaneId? {
    guard case .pane(let paneId, _) = pendingCloseTarget(pending) else { return nil }
    return paneId
}

func pendingCloseTabId(_ pending: PendingConfirmation?) -> TabId? {
    guard case .tab(let tabId, _, _) = pendingCloseTarget(pending) else { return nil }
    return tabId
}

func pendingCloseTabIds(_ pending: PendingConfirmation?) -> [TabId]? {
    guard case .tabs(let tabIds, _) = pendingCloseTarget(pending) else { return nil }
    return tabIds
}

func pendingQuitAuthorized(_ pending: PendingConfirmation?) -> Bool? {
    guard let target = pendingCloseTarget(pending) else { return nil }
    switch target {
    case .pane(_, let authorized),
         .tab(_, _, let authorized),
         .tabs(_, let authorized):
        return authorized
    case .otherPanes:
        return false
    }
}

func pendingDeleteGroup(_ pending: PendingConfirmation?) -> DeleteGroupConfirmation? {
    guard let pending, case .deleteGroup(_, let confirmation) = pending.kind else { return nil }
    return confirmation
}

@discardableResult
func confirmPending(_ model: inout AppModel) -> [Command] {
    guard let id = model.pendingConfirmation?.id else {
        Issue.record("expected a pending confirmation")
        return []
    }
    return update(&model, .answerConfirmation(id: id, answer: .confirm))
}

@discardableResult
func cancelPending(_ model: inout AppModel) -> [Command] {
    guard let id = model.pendingConfirmation?.id else {
        Issue.record("expected a pending confirmation")
        return []
    }
    return update(&model, .answerConfirmation(id: id, answer: .cancel))
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

/// Find an embedded PaneSnapshot by its typed pane identity.
func paneSnapshot(_ id: PaneId, in snapshot: AppModelSnapshot) -> PaneSnapshot? {
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
        model.groups[0].tabs.append(TabModel(id: tabId, paneTree: PaneTree(root: .leaf(PaneModel(id: paneId)), focusedPaneId: paneId)))
    }
    return (model, ids)
}

/// Build a two-pane tab and return the tab plus its panes in display order.
/// Used by the TabTodo.swift row/resolver tests in TabTodoTests and by the
/// tab-todo popover projection tests in ProjectionsTests.
func makeTwoPaneTabTodoRowsModel() -> (model: AppModel, tabId: TabId, paneA: PaneId, paneB: PaneId) {
    var model = makeModel()
    createTab(&model)
    let tabId = selectedTab(in: model)!.id
    let paneA = selectedTab(in: model)!.paneTree.focusedPaneId
    update(&model, .splitPane(paneId: paneA, direction: .horizontal))
    let paneOrder = allPaneIds(selectedTab(in: model)!.paneTree.root)
    return (model, tabId, paneOrder[0], paneOrder[1])
}

/// Lifts a reported activity into the form `AgentLifecycle` stores, so a test
/// about chips, projections, or alerts can keep naming the vocabulary a hook
/// uses instead of minting a wait generation it does not care about.
func storedActivity(
    _ activity: AgentActivity?,
    waitGeneration: UInt64 = 1
) -> AgentActivityState? {
    switch activity {
    case .working: .working
    case .waiting: .waiting(generation: AgentWaitGeneration(rawValue: waitGeneration))
    case .idle: .idle
    case nil: nil
    }
}

/// Reads an attached agent's session and reported activity, dropping the wait
/// generation so an assertion pins the vocabulary rather than the scheme that
/// allocates generations.
func attachedAgent(
    _ agent: AgentLifecycle
) -> (session: AgentSession, activity: AgentActivity?)? {
    guard case .attached(let session, let activity) = agent else { return nil }
    return (session, activity?.reported)
}
