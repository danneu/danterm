// Swift Testing suite for the checkpoint captures -- the values the main actor takes from live
// state and the deferred work that turns them into bytes. Two claims live here: a capture
// performs no pane read (that is what lets the expensive half run on the checkpoint queue), and
// the session projection's bytes are exactly the init file the model serializes to. Both are
// properties of the values alone, which is why they are testable here rather than against a
// live AppRuntime; the queue placement that completes the story is a lint over `app/`.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

/// Mutable state a `@Sendable` read closure can record into. Unchecked because these tests run
/// the encode inline on the test's own thread -- the deferral is what they assert, not
/// concurrency, so there is no second thread for the box to be shared with.
private final class Recorder<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
/// Build a model with `count` tabs, each owning one pane, and return it with its pane ids in
/// tab order so a test can address panes without reaching through the tree at every assertion.
private func makeModelWithPanes(_ count: Int) -> (AppModel, [PaneId]) {
    var model = makeModel()
    for _ in 0..<count { createTab(&model) }
    let paneIds = model.groups[0].tabs.map(\.paneTree.focusedPaneId)
    return (model, paneIds)
}

/// Decode a scrollback capture's encoded bytes back through the real sidecar codec. Going
/// through `loadScrollbackSidecar` rather than inspecting the capture keeps these tests honest
/// about what actually lands on disk.
private func decodeSidecar(_ data: Data) throws -> [PaneId: String] {
    try #require(loadScrollbackSidecar(from: data))
}

/// Decode an init-file capture through the real codec so projection and policy tests assert the
/// bytes that would reach disk, not a parallel interpretation of the projection fields.
/// Shared with `SessionCheckpointPolicyTests`, which decides which capture reaches the writer.
func decodeInitFileCapture(_ capture: InitFileCapture) throws -> ValidatedAppRestore {
    try loadValidatedInitFile(from: capture.encoder()())
}

/// Build a stable-home session projection so persisted-facet tests compare only the mutation
/// under test, never the machine running the suite.
private func sessionProjection(_ model: AppModel) -> SessionCheckpointProjection {
    SessionCheckpointProjection(snapshot: toSnapshot(model, home: "/Users/testhome"))
}

private func expectProjectionChanges(
    from baseline: AppModel,
    facet: String,
    mutation: (inout AppModel) -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var changed = baseline
    mutation(&changed)
    let context = Comment(rawValue: facet)
    #expect(changed != baseline, context, sourceLocation: sourceLocation)
    #expect(sessionProjection(changed) != sessionProjection(baseline), context,
            sourceLocation: sourceLocation)
}

private func expectProjectionDoesNotChange(
    from baseline: AppModel,
    facet: String,
    mutation: (inout AppModel) -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var changed = baseline
    mutation(&changed)
    let context = Comment(rawValue: facet)
    #expect(changed != baseline, context, sourceLocation: sourceLocation)
    #expect(sessionProjection(changed) == sessionProjection(baseline), context,
            sourceLocation: sourceLocation)
}

@Suite struct SessionCheckpointProjectionTests {
    @Test("every persisted model facet changes the projection")
    func persistedModelFacetsChangeProjection() {
        // Intent: representative mutations for every persisted model facet change projection
        //   equality, so runtime scheduling follows persistence automatically.
        // Why it exists: a new or refactored update path must not depend on hand-maintained
        //   scheduling commands to make structure, metadata, appearance, or todos durable.
        // Scenario: one model accumulates each persisted facet and advances its comparison
        //   baseline after every mutation.
        var model = makeModel()
        var previous = sessionProjection(model)

        createTab(&model)
        var current = sessionProjection(model)
        #expect(current != previous, "tab and pane structure")
        previous = current

        let firstTabId = model.groups[0].tabs[0].id
        createTab(&model)
        current = sessionProjection(model)
        #expect(current != previous, "selected tab and added structure")
        previous = current

        update(&model, .selectTab(id: firstTabId))
        current = sessionProjection(model)
        #expect(current != previous, "selected tab")
        previous = current

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneIds = allPaneIds(model.groups[0].tabs[0].paneTree.root)
        current = sessionProjection(model)
        #expect(current != previous, "split structure and focused pane")
        previous = current

        update(&model, .paneBecameFirstResponder(paneId: paneIds[0]))
        current = sessionProjection(model)
        #expect(current != previous, "focused pane")
        previous = current

        update(&model, .renameTab(id: firstTabId, name: "Build"))
        current = sessionProjection(model)
        #expect(current != previous, "tab title")
        previous = current

        update(&model, .renameGroup(id: model.groups[0].id, name: "Project"))
        current = sessionProjection(model)
        #expect(current != previous, "group title")
        previous = current

        update(&model, .toggleGroupCollapse(groupId: model.groups[0].id))
        current = sessionProjection(model)
        #expect(current != previous, "group collapse")
        previous = current

        update(&model, .sidebarPresentationReported(isCollapsed: false, width: 280))
        current = sessionProjection(model)
        #expect(current != previous, "sidebar presentation")
        previous = current

        update(&model, .setTabColors(tabIds: [firstTabId], color: .purple))
        current = sessionProjection(model)
        #expect(current != previous, "tab color")
        previous = current

        update(&model, .sessionReport(
            sessionId: sessionId(for: paneIds[0], in: model),
            report: .title("swift")
        ))
        current = sessionProjection(model)
        #expect(current != previous, "pane title")
        previous = current

        update(&model, .sessionReport(
            sessionId: sessionId(for: paneIds[0], in: model),
            report: .cwd("/tmp/project")
        ))
        current = sessionProjection(model)
        #expect(current != previous, "pane cwd")
        previous = current

        update(&model, .setPaneTheme(paneId: paneIds[0], themeName: "Nord"))
        current = sessionProjection(model)
        #expect(current != previous, "pane theme")
        previous = current

        update(&model, .adjustPaneFontSize(paneId: paneIds[0], steps: 1))
        current = sessionProjection(model)
        #expect(current != previous, "pane font steps")
        previous = current

        update(&model, .addTodo(owner: .pane(paneIds[0]), text: TodoText("pane task")!))
        current = sessionProjection(model)
        #expect(current != previous, "pane todos")
        previous = current

        update(&model, .addTodo(owner: .tab(firstTabId), text: TodoText("tab task")!))
        current = sessionProjection(model)
        #expect(current != previous, "tab todos")
    }

    @Test("transient model facets leave the projection unchanged")
    func transientModelFacetsLeaveProjectionUnchanged() {
        // Intent: zoom, progress, alerts, search, and session lifecycle state never enter
        //   light-checkpoint equality.
        // Why it exists: projection-derived scheduling must remove the old alert over-schedule
        //   and must not replace it with writes for other live-only state.
        // Scenario: a two-tab model mutates each transient facet while its persisted snapshot
        //   remains fixed.
        var model = makeModel()
        createTab(&model)
        let backgroundPane = model.groups[0].tabs[0].paneTree.focusedPaneId
        createTab(&model)
        let selectedPane = model.groups[0].tabs[1].paneTree.focusedPaneId
        update(&model, .splitFocusedPane(direction: .horizontal))
        let searchPane = model.groups[0].tabs[1].paneTree.focusedPaneId
        let baseline = sessionProjection(model)
        // The policy the runtime would be holding: a transient facet must leave it with
        // nothing to hand the writer, not merely leave the projection equal.
        var policy = SessionCheckpointPolicy(covering: baseline)

        // The tab's own focused pane, so the request is zoom and nothing else:
        // zooming a pane that does not hold focus also moves focus, which is a
        // persisted fact and legitimately changes the projection.
        update(&model, .toggleZoomPane(paneId: searchPane))
        #expect(sessionProjection(model) == baseline, "zoom")

        update(&model, .sessionReport(sessionId: sessionId(for: selectedPane, in: model), report: .progress(.set(percent: 50))))
        #expect(sessionProjection(model) == baseline, "progress")

        update(&model, .sessionBell(sessionId: sessionId(for: backgroundPane, in: model)))
        #expect(model.alerts.isEmpty == false)
        #expect(sessionProjection(model) == baseline, "alerts")

        update(&model, .clearAlertsForTabs(tabIds: [model.groups[0].tabs[0].id]))
        #expect(sessionProjection(model) == baseline, "alert clearing")

        update(&model, .startSearch)
        update(&model, .searchNeedleChanged(paneId: searchPane, needle: "hit"))
        update(&model, .paneBecameFirstResponder(paneId: searchPane))
        #expect(model.pane(searchPane)?.live.search?.focusOwner == .terminal)
        #expect(sessionProjection(model) == baseline, "search")

        let selectedSessionId = sessionId(for: selectedPane, in: model)
        update(&model, .sessionProcessStarted(sessionId: selectedSessionId))
        #expect(model.pane(selectedPane)?.session?.processPhase == .running)
        #expect(sessionProjection(model) == baseline, "spawn-to-running lifecycle")
        #expect(policy.capture(sessionProjection(model)) == nil)

        update(&model, .sessionReport(
            sessionId: selectedSessionId,
            report: .connectionDeclared(.remote(identity: RemoteSession(user: "dan", host: "host")))
        ))
        #expect(sessionProjection(model) == baseline, "remote connection lifecycle")
        #expect(policy.capture(sessionProjection(model)) == nil)

        update(&model, .sessionReport(
            sessionId: selectedSessionId,
            report: .connectionDeclared(.local)
        ))
        #expect(sessionProjection(model) == baseline, "local connection lifecycle")
        #expect(policy.capture(sessionProjection(model)) == nil)
    }

    @Test("lifecycle recovery values alone change the projection")
    func lifecycleRecoveryValuesChangeProjection() throws {
        var (model, paneIds) = makeModelWithPanes(1)
        let paneId = paneIds[0]
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        let baseline = sessionProjection(model)
        update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted("swift test")))
        let withCommand = sessionProjection(model)
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(agent)))
        let withAgent = sessionProjection(model)

        #expect(withCommand != baseline, "command memo")
        #expect(withAgent != withCommand, "agent session")
    }

    @Test("recursive persisted facets independently change the projection")
    func recursivePersistedFacetsIndependentlyChangeProjection() throws {
        // Intent: split ratio and pane grid override each change checkpoint equality alone.
        // Why it exists: the broad persisted-facet test changes several structural fields at
        //   once, so another changed field could hide either omission from `toSnapshot`.
        // Scenario: one split tree is held fixed while its ratio changes, and one pane is held
        //   fixed while it gains a client-owned grid override.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        guard case .split(let splitId, _, _, _, _) = model.groups[0].tabs[0].paneTree.root else {
            Issue.record("fixture should contain one split")
            return
        }
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let grid = try #require(PaneGridOverride(columns: 100, rows: 40))

        expectProjectionChanges(from: model, facet: "split ratio") {
            update(&$0, .splitRatioChanged(splitId: splitId, ratio: 0.3))
        }
        expectProjectionChanges(from: model, facet: "pane grid override") {
            update(&$0, .setPaneGridOverride(paneId: paneId, grid: grid))
        }
    }

    @Test("nested live-only facets independently leave the projection unchanged")
    func nestedLiveOnlyFacetsIndependentlyLeaveProjectionUnchanged() throws {
        // Intent: pane-local and session-local runtime state cannot schedule a checkpoint.
        // Why it exists: these fields sit recursively below persisted pane and session values;
        //   checking only top-level app state would not catch accidental projection membership.
        // Scenario: each live-only field changes from a fresh copy of the same pane model, while
        //   command and agent lifecycle cases hold their persisted recovery memos constant.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let sessionId = sessionId(for: paneId, in: model)

        expectProjectionDoesNotChange(from: model, facet: "notification throttle") {
            $0.updatePane(paneId) { $0.live.lastNotificationTime[.bell] = testEpoch }
        }
        expectProjectionDoesNotChange(from: model, facet: "integration lifecycle") {
            update(&$0, .sessionReport(sessionId: sessionId, report: .integrationReady))
        }
        expectProjectionDoesNotChange(from: model, facet: "launch input lifecycle") {
            $0.updatePane(paneId) { $0.session?.launchInput = .pending }
        }
        expectProjectionDoesNotChange(from: model, facet: "agent wait generation") {
            $0.updatePane(paneId) { pane in
                _ = pane.session?.mintWaitGeneration()
            }
        }

        update(&model, .sessionReport(
            sessionId: sessionId,
            report: .commandStarted("swift test")
        ))
        expectProjectionDoesNotChange(from: model, facet: "command lifecycle after memo") {
            update(&$0, .sessionReport(
                sessionId: sessionId,
                report: .commandEnded(exitStatus: 0)
            ))
        }

        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(agent)))
        expectProjectionDoesNotChange(from: model, facet: "agent activity after memo") {
            update(&$0, .sessionReport(
                sessionId: sessionId,
                report: .agentActivityChanged(session: agent, activity: .working)
            ))
        }
    }
}

@Suite struct ScrollbackCaptureTests {
    @Test("building a capture performs no pane read")
    func capturePerformsNoRead() throws {
        // Intent: `ScrollbackCapture.init` and `encoder()` read nothing; every pane read happens
        //   when the returned work runs.
        // Why it exists: a periodic checkpoint must perform no scrollback projection,
        //   truncation, or encoding on the main thread. Holding reads rather than text is what
        //   lets the capture defer that cost; eagerly resolving panes here would put it back on
        //   the main thread with every other test still passing.
        // Scenario: spec-first. A capture is built and its encoder requested; neither may run
        //   the pane's read closure.
        let (_, paneIds) = makeModelWithPanes(1)
        let reads = Recorder(0)

        let capture = ScrollbackCapture(scrollbackReads: [paneIds[0]: {
            reads.value += 1
            return "hello\n"
        }])
        #expect(reads.value == 0, "constructing a capture must not read any pane")

        let encode = capture.encoder()
        #expect(reads.value == 0, "requesting the encoder must not read any pane")

        _ = try encode()
        #expect(reads.value == 1, "running the encode must perform the pane read exactly once")
    }

    @Test("the capture writes every captured pane's text under its own id")
    func captureKeysTextByPaneId() throws {
        // Intent: two panes captured together each reach the sidecar under their own id, and a
        //   pane whose read returns nothing contributes no entry.
        // Why it exists: the sidecar carries no structure, so the pane id is the only thing
        //   tying a body of text to the pane it came from. A mis-keyed entry is grafted onto
        //   the wrong pane at load, or onto none at all, with nothing else to catch it.
        // Scenario: spec-first. Three panes: two with text, one with an empty read.
        let (_, paneIds) = makeModelWithPanes(3)

        let capture = ScrollbackCapture(scrollbackReads: [
            paneIds[0]: { "first pane\n" },
            paneIds[1]: { "second pane\n" },
            paneIds[2]: { nil },
        ])

        let sidecar = try decodeSidecar(capture.encoder()())
        #expect(sidecar == [paneIds[0]: "first pane\n", paneIds[1]: "second pane\n"])
    }

    @Test("the capture normalizes without cutting the bounded pane result again")
    func captureOnlyNormalizesBoundedScrollback() throws {
        // Intent: capture trims boundary whitespace and adds one final newline without applying
        //   another line or character budget.
        // Why it exists: the engine owns the one positional cut; a downstream cut would restore
        //   the duplicate policy owner this pipeline removes.
        // Scenario: a bounded two-line result reaches storage intact after normalization.
        let (_, paneIds) = makeModelWithPanes(1)

        let capture = ScrollbackCapture(
            scrollbackReads: [paneIds[0]: { "  first\nsecond  " }]
        )
        let sidecar = try decodeSidecar(capture.encoder()())

        #expect(sidecar[paneIds[0]] == "first\nsecond\n")
    }
}

@Suite struct InitFileCaptureTests {
    @Test("the session projection's bytes are the model's init file")
    func sessionProjectionMatchesTheInitFile() throws {
        // Intent: a capture built from a session projection encodes exactly the init file
        //   `toInitFile` produces for the same model -- byte for byte (plan I7, PO8).
        // Why it exists: the session file is the only structure on disk, and export shares its
        //   codec. A traversal that fails to preserve a new snapshot field would silently drop
        //   it from both written forms. The model below populates the optional fields precisely
        //   so this notices.
        // Scenario: spec-first. Session checkpoint bytes, via a capture and via `toInitFile`.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        model.groups[0].isCollapsed = true
        model.groups[0].tabs[0].customTitle = "renamed"
        model.groups[0].tabs[0].color = .purple
        model.groups[0].tabs[0].todos = [TodoItem(id: UUID(), text: TodoText("tab todo")!, isDone: true)]
        if case .leaf(var pane) = model.groups[0].tabs[0].paneTree.root {
            pane.session?.titleState = .declared("vim")
            pane.session?.cwd = "/tmp/work"
            pane.theme = "Dracula"
            pane.todos = [TodoItem(id: UUID(), text: TodoText("pane todo")!, isDone: false)]
            model.groups[0].tabs[0].paneTree = PaneTree(root: .leaf(pane))
        } else {
            Issue.record("a fresh tab should be a single leaf")
            return
        }
        let capture = InitFileCapture(
            sessionProjection: SessionCheckpointProjection(snapshot: toSnapshot(model))
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expected = try encoder.encode(toInitFile(model))

        #expect(try capture.encoder()() == expected)
    }

    @Test("a session capture preserves command and agent recovery state")
    func sessionCapturePreservesLifecycleRecoveryState() throws {
        var (model, paneIds) = makeModelWithPanes(1)
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let sessionId = try #require(model.pane(paneIds[0])?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted("swift test")))
        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(agent)))
        let capture = InitFileCapture(
            sessionProjection: SessionCheckpointProjection(snapshot: toSnapshot(model))
        )

        let restore = try decodeInitFileCapture(capture)
        let pane = try #require(restore.paneSnapshots[paneIds[0]])
        #expect(pane.command == "swift test")
        #expect(pane.agentSession?.kind == "claude")
        #expect(pane.agentSession?.sessionId == "session-1")
        #expect(pane.scrollback == nil)
    }

    @Test("the export capture grafts each pane's text into the leaf its snapshot holds")
    func exportCaptureGraftsTextIntoItsOwnSnapshot() throws {
        // Intent: an init-file capture carrying reads embeds each pane's text in the matching
        //   leaf, and drops a read for a pane its own snapshot has no leaf for.
        // Why it exists: export is the one writer that still puts scrollback inside the init
        //   file, and it captures the model and the live session table separately -- nothing
        //   forces the two to agree. A stale session must be dropped, not resurrected.
        // Scenario: spec-first. A read for the live pane, and one for a pane in no tab.
        let (model, paneIds) = makeModelWithPanes(1)
        let capture = InitFileCapture(
            snapshot: toSnapshot(model),
            scrollbackReads: [
                paneIds[0]: { "live\n" },
                PaneId(): { "stale\n" },
            ]
        )

        let restore = try decodeInitFileCapture(capture)
        let scrollback = restore.paneSnapshots.compactMapValues(\.scrollback)
        #expect(scrollback == [paneIds[0]: "live\n"])
    }
}

