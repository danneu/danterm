// Swift Testing suite for `CheckpointCapture` -- the value the main actor takes from live state
// and the deferred work that turns it into checkpoint bytes. Two claims live here: the capture
// performs no pane read (that is what lets the expensive half run on the checkpoint queue), and
// a pane's text can only ever be written against the model snapshot captured beside it. Both are
// properties of the value alone, which is why they are testable here rather than against a
// live AppRuntime; the queue placement that completes the story is a lint over `app/`.
import Foundation
import Testing

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

/// Decode a capture's encoded bytes back through the real codec and read scrollback per pane.
/// Going through `loadValidatedInitFile` rather than inspecting the snapshot keeps these tests
/// honest about what actually lands on disk.
private func decodeScrollback(_ data: Data) throws -> [PaneId: String] {
    let restore = try loadValidatedInitFile(from: data)
    return restore.paneSnapshots.compactMapValues(\.scrollback)
}

/// Decode a light capture through the real codec so projection and policy tests assert the
/// bytes that would reach disk, not a parallel interpretation of the projection fields.
/// Shared with `LightCheckpointPolicyTests`, which decides which capture reaches the writer.
func decodeLightCapture(_ capture: CheckpointCapture) throws -> ValidatedAppRestore {
    try loadValidatedInitFile(from: capture.encoder()())
}

/// Build a stable-home light projection so persisted-facet tests compare only the mutation
/// under test, never the machine running the suite.
private func lightProjection(_ model: AppModel) -> LightCheckpointProjection {
    LightCheckpointProjection(snapshot: toSnapshot(model, home: "/Users/testhome"))
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
    #expect(lightProjection(changed) != lightProjection(baseline), context,
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
    #expect(lightProjection(changed) == lightProjection(baseline), context,
            sourceLocation: sourceLocation)
}

@Suite struct LightCheckpointProjectionTests {
    @Test("every persisted model facet changes the projection")
    func persistedModelFacetsChangeProjection() {
        // Intent: representative mutations for every persisted model facet change projection
        //   equality, so runtime scheduling follows persistence automatically.
        // Why it exists: a new or refactored update path must not depend on hand-maintained
        //   scheduling commands to make structure, metadata, appearance, or todos durable.
        // Scenario: one model accumulates each persisted facet and advances its comparison
        //   baseline after every mutation.
        var model = makeModel()
        var previous = lightProjection(model)

        createTab(&model)
        var current = lightProjection(model)
        #expect(current != previous, "tab and pane structure")
        previous = current

        let firstTabId = model.groups[0].tabs[0].id
        createTab(&model)
        current = lightProjection(model)
        #expect(current != previous, "selected tab and added structure")
        previous = current

        update(&model, .selectTab(id: firstTabId))
        current = lightProjection(model)
        #expect(current != previous, "selected tab")
        previous = current

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneIds = allPaneIds(model.groups[0].tabs[0].paneTree.root)
        current = lightProjection(model)
        #expect(current != previous, "split structure and focused pane")
        previous = current

        update(&model, .paneBecameFirstResponder(paneId: paneIds[0]))
        current = lightProjection(model)
        #expect(current != previous, "focused pane")
        previous = current

        update(&model, .renameTab(id: firstTabId, name: "Build"))
        current = lightProjection(model)
        #expect(current != previous, "tab title")
        previous = current

        update(&model, .renameGroup(id: model.groups[0].id, name: "Project"))
        current = lightProjection(model)
        #expect(current != previous, "group title")
        previous = current

        update(&model, .toggleGroupCollapse(groupId: model.groups[0].id))
        current = lightProjection(model)
        #expect(current != previous, "group collapse")
        previous = current

        update(&model, .setTabColors(tabIds: [firstTabId], color: .purple))
        current = lightProjection(model)
        #expect(current != previous, "tab color")
        previous = current

        update(&model, .sessionReport(
            sessionId: sessionId(for: paneIds[0], in: model),
            report: .title("swift")
        ))
        current = lightProjection(model)
        #expect(current != previous, "pane title")
        previous = current

        update(&model, .sessionReport(
            sessionId: sessionId(for: paneIds[0], in: model),
            report: .cwd("/tmp/project")
        ))
        current = lightProjection(model)
        #expect(current != previous, "pane cwd")
        previous = current

        update(&model, .setPaneTheme(paneId: paneIds[0], themeName: "Nord"))
        current = lightProjection(model)
        #expect(current != previous, "pane theme")
        previous = current

        update(&model, .adjustPaneFontSize(paneId: paneIds[0], steps: 1))
        current = lightProjection(model)
        #expect(current != previous, "pane font steps")
        previous = current

        update(&model, .addTodo(owner: .pane(paneIds[0]), text: "pane task"))
        current = lightProjection(model)
        #expect(current != previous, "pane todos")
        previous = current

        update(&model, .addTodo(owner: .tab(firstTabId), text: "tab task"))
        current = lightProjection(model)
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
        let baseline = lightProjection(model)
        // The policy the runtime would be holding: a transient facet must leave it with
        // nothing to hand the writer, not merely leave the projection equal.
        var policy = LightCheckpointPolicy(covering: baseline)

        // The tab's own focused pane, so the request is zoom and nothing else:
        // zooming a pane that does not hold focus also moves focus, which is a
        // persisted fact and legitimately changes the projection.
        update(&model, .toggleZoomPane(paneId: searchPane))
        #expect(lightProjection(model) == baseline, "zoom")

        update(&model, .sessionReport(sessionId: sessionId(for: selectedPane, in: model), report: .progress(.set(percent: 50))))
        #expect(lightProjection(model) == baseline, "progress")

        update(&model, .sessionBell(sessionId: sessionId(for: backgroundPane, in: model)))
        #expect(model.alerts.isEmpty == false)
        #expect(lightProjection(model) == baseline, "alerts")

        update(&model, .clearAlertsForTabs(tabIds: [model.groups[0].tabs[0].id]))
        #expect(lightProjection(model) == baseline, "alert clearing")

        update(&model, .startSearch)
        update(&model, .searchNeedleChanged(paneId: searchPane, needle: "hit"))
        update(&model, .paneBecameFirstResponder(paneId: searchPane))
        #expect(model.pane(searchPane)?.live.search?.focusOwner == .terminal)
        #expect(lightProjection(model) == baseline, "search")

        let selectedSessionId = sessionId(for: selectedPane, in: model)
        update(&model, .sessionProcessStarted(sessionId: selectedSessionId))
        #expect(model.pane(selectedPane)?.session?.processPhase == .running)
        #expect(lightProjection(model) == baseline, "spawn-to-running lifecycle")
        #expect(policy.capture(lightProjection(model)) == nil)

        update(&model, .sessionReport(
            sessionId: selectedSessionId,
            report: .connectionDeclared(.remote(identity: RemoteSession(user: "dan", host: "host")))
        ))
        #expect(lightProjection(model) == baseline, "remote connection lifecycle")
        #expect(policy.capture(lightProjection(model)) == nil)

        update(&model, .sessionReport(
            sessionId: selectedSessionId,
            report: .connectionDeclared(.local)
        ))
        #expect(lightProjection(model) == baseline, "local connection lifecycle")
        #expect(policy.capture(lightProjection(model)) == nil)
    }

    @Test("lifecycle recovery values alone change the projection")
    func lifecycleRecoveryValuesChangeProjection() throws {
        var (model, paneIds) = makeModelWithPanes(1)
        let paneId = paneIds[0]
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        let baseline = lightProjection(model)
        update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted("swift test")))
        let withCommand = lightProjection(model)
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(agent)))
        let withAgent = lightProjection(model)

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

@Suite struct CheckpointCaptureTests {
    @Test("building a capture performs no pane read")
    func capturePerformsNoRead() throws {
        // Intent: `CheckpointCapture.init` and `encoder()` read nothing; every pane read happens
        //   when the returned work runs.
        // Why it exists: a periodic checkpoint must perform no scrollback projection,
        //   truncation, or encoding on the main thread. Holding reads rather than text is what
        //   lets the capture defer that cost; eagerly resolving panes here would put it back on
        //   the main thread with every other test still passing.
        // Scenario: spec-first. A capture is built and its encoder requested; neither may run
        //   the pane's read closure.
        let (model, paneIds) = makeModelWithPanes(1)
        let reads = Recorder(0)

        let capture = CheckpointCapture(
            snapshot: toSnapshot(model),
            scrollbackReads: [paneIds[0]: {
                reads.value += 1
                return "hello\n"
            }]
        )
        #expect(reads.value == 0, "constructing a capture must not read any pane")

        let encode = capture.encoder()
        #expect(reads.value == 0, "requesting the encoder must not read any pane")

        _ = try encode()
        #expect(reads.value == 1, "running the encode must perform the pane read exactly once")
    }

    @Test("a capture's panes are written against the snapshot captured beside them")
    func capturePairsScrollbackWithItsOwnSnapshot() throws {
        // Intent: two captures taken at different moments encode independently -- each pane's
        //   text lands in the snapshot it was captured with, whatever order the encodes run in.
        // Why it exists: concurrent checkpoints must keep each pane's scrollback paired with
        //   the model snapshot captured beside it. One capture can still be encoding when the
        //   next is taken, and a pane can close in between; carrying the halves separately could
        //   write a later model against earlier text. Bundling them makes that unrepresentable.
        // Scenario: spec-first. Capture A sees two panes; a pane then closes and capture B sees
        //   one. B encodes first, A second -- the reverse of capture order.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabs = model.groups[0].tabs
        let survivingPane = tabs[0].paneTree.focusedPaneId
        let closingPane = tabs[1].paneTree.focusedPaneId

        let captureA = CheckpointCapture(
            snapshot: toSnapshot(model),
            scrollbackReads: [
                survivingPane: { "surviving pane, capture A\n" },
                closingPane: { "closing pane, capture A\n" },
            ]
        )

        update(&model, .closeTab(id: tabs[1].id))
        let captureB = CheckpointCapture(
            snapshot: toSnapshot(model),
            scrollbackReads: [survivingPane: { "surviving pane, capture B\n" }]
        )

        let fromB = try decodeScrollback(captureB.encoder()())
        let fromA = try decodeScrollback(captureA.encoder()())

        #expect(fromA[survivingPane] == "surviving pane, capture A\n")
        #expect(fromA[closingPane] == "closing pane, capture A\n",
                "capture A predates the close, so its payload still carries the closed pane")
        #expect(fromB[survivingPane] == "surviving pane, capture B\n")
        #expect(fromB[closingPane] == nil,
                "capture B postdates the close, so the closed pane is absent from its model")
    }

    @Test("a capture drops panes its snapshot does not contain")
    func captureIgnoresReadsWithoutALeaf() throws {
        // Intent: a read for a pane the snapshot has no leaf for contributes nothing.
        // Why it exists: the capture's two halves are taken from separate live structures --
        //   the model and the live session table -- and nothing forces them to agree. The graft
        //   is keyed by leaf, so a stale session is dropped rather than resurrected; this pins
        //   that direction of the mismatch, the one that could otherwise write a pane the model
        //   no longer knows about.
        // Scenario: spec-first. A read is supplied for a pane id that is in no tab.
        let (model, paneIds) = makeModelWithPanes(1)
        let capture = CheckpointCapture(
            snapshot: toSnapshot(model),
            scrollbackReads: [
                paneIds[0]: { "live\n" },
                PaneId(): { "stale\n" },
            ]
        )

        let scrollback = try decodeScrollback(capture.encoder()())
        #expect(scrollback.count == 1)
        #expect(scrollback[paneIds[0]] == "live\n")
    }

    @Test("a capture with no reads encodes the light checkpoint's payload")
    func captureWithoutReadsMatchesTheLightCheckpoint() throws {
        // Intent: an empty read set makes the graft the identity, so the bytes are exactly the
        //   scrollback-free init file the light checkpoint has always written.
        // Why it exists: export and both checkpoint tiers share `graftScrollback`, and the light
        //   tier is the frequent one. A traversal that fails to preserve a new snapshot field
        //   would silently drop it from each written form. The model below populates the optional
        //   fields precisely so this notices.
        // Scenario: spec-first. Light checkpoint bytes, via a capture and via `toInitFile`.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        model.groups[0].isCollapsed = true
        model.groups[0].tabs[0].customTitle = "renamed"
        model.groups[0].tabs[0].color = .purple
        model.groups[0].tabs[0].todos = [TodoItem(id: UUID(), text: "tab todo", isDone: true)]
        if case .leaf(var pane) = model.groups[0].tabs[0].paneTree.root {
            pane.session?.titleState = .declared("vim")
            pane.session?.cwd = "/tmp/work"
            pane.theme = "Dracula"
            pane.todos = [TodoItem(id: UUID(), text: "pane todo", isDone: false)]
            model.groups[0].tabs[0].paneTree = PaneTree(root: .leaf(pane))
        } else {
            Issue.record("a fresh tab should be a single leaf")
            return
        }
        let capture = CheckpointCapture(snapshot: toSnapshot(model), scrollbackReads: [:])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let expected = try encoder.encode(toInitFile(model))

        #expect(try capture.encoder()() == expected)
    }

    @Test("a light capture preserves command and agent recovery state")
    func lightCapturePreservesLifecycleRecoveryState() throws {
        var (model, paneIds) = makeModelWithPanes(1)
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let sessionId = try #require(model.pane(paneIds[0])?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted("swift test")))
        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(agent)))
        let capture = CheckpointCapture(
            snapshot: toSnapshot(model),
            scrollbackReads: [:]
        )

        let restore = try loadValidatedInitFile(from: capture.encoder()())
        let pane = try #require(restore.paneSnapshots[paneIds[0]])
        #expect(pane.command == "swift test")
        #expect(pane.agentSession?.kind == "claude")
        #expect(pane.agentSession?.sessionId == "session-1")
        #expect(pane.scrollback == nil)
    }

    @Test("the capture normalizes without cutting the bounded pane result again")
    func captureOnlyNormalizesBoundedScrollback() throws {
        // Intent: capture trims boundary whitespace and adds one final newline without applying
        //   another line or character budget.
        // Why it exists: the engine owns the one positional cut; a downstream cut would restore
        //   the duplicate policy owner this pipeline removes.
        // Scenario: a bounded two-line result reaches storage intact after normalization.
        let (model, paneIds) = makeModelWithPanes(1)

        let capture = CheckpointCapture(
            snapshot: toSnapshot(model),
            scrollbackReads: [paneIds[0]: { "  first\nsecond  " }]
        )
        let scrollback = try decodeScrollback(capture.encoder()())

        #expect(scrollback[paneIds[0]] == "first\nsecond\n")
    }
}
