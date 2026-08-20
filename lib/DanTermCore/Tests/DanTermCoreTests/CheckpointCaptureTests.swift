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

/// Decode a light capture through the real codec so projection tests assert the bytes that
/// would reach disk, not a parallel interpretation of the projection fields.
private func decodeLightCapture(_ capture: CheckpointCapture) throws -> ValidatedAppRestore {
    try loadValidatedInitFile(from: capture.encoder()())
}

/// Build a stable-home light projection so persisted-facet tests compare only the mutation
/// under test, never the machine running the suite.
private func lightProjection(_ model: AppModel) -> LightCheckpointProjection {
    LightCheckpointProjection(snapshot: toSnapshot(model, home: "/Users/testhome"))
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
        // Intent: zoom, progress, alerts, and search never enter light-checkpoint equality.
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

        update(&model, .searchStarted(paneId: searchPane, needle: "hit"))
        update(&model, .paneBecameFirstResponder(paneId: searchPane))
        #expect(model.pane(searchPane)?.live.search?.focusOwner == .terminal)
        #expect(lightProjection(model) == baseline, "search")
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

    @Test("the write decision follows projection equality")
    func writeDecisionFollowsProjectionEquality() throws {
        // Intent: an unchanged projection produces no capture, while a changed one produces a
        //   capture whose bytes carry that exact projection.
        // Why it exists: scheduling and capture must share one definition of persisted state;
        //   separate derivations can silently drift in either direction.
        // Scenario: a tab title changes after baseline A, then repeats unchanged at baseline B.
        var model = makeModel()
        createTab(&model)
        let baseline = LightCheckpointProjection(snapshot: toSnapshot(model))
        let tabId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabId, name: "persisted title"))
        let changed = LightCheckpointProjection(snapshot: toSnapshot(model))

        #expect(lightCheckpointCapture(current: baseline, baseline: baseline) == nil)
        let capture = try #require(
            lightCheckpointCapture(current: changed, baseline: baseline)
        )
        let restored = try decodeLightCapture(capture)
        #expect(restored.snapshot == changed.snapshot)
        #expect(lightCheckpointCapture(current: changed, baseline: changed) == nil)
    }

    @Test("a reversion while a write is in flight becomes the next write")
    func reversionAfterCaptureBecomesNextWrite() throws {
        // Intent: advancing the baseline when a capture is handed off still detects a later
        //   reversion, so serial writer order ends at the current projection.
        // Why it exists: comparing against the last completed disk write would require callback
        //   coordination and can lose the projection that wins while an earlier encode runs.
        // Scenario: A is on disk, B is captured, then state returns to A before B completes.
        var model = makeModel()
        createTab(&model)
        let projectionA = LightCheckpointProjection(snapshot: toSnapshot(model))
        let tabId = model.groups[0].tabs[0].id
        update(&model, .renameTab(id: tabId, name: "temporary"))
        let projectionB = LightCheckpointProjection(snapshot: toSnapshot(model))

        _ = try #require(lightCheckpointCapture(current: projectionB, baseline: projectionA))
        let reverted = try #require(
            lightCheckpointCapture(current: projectionA, baseline: projectionB)
        )
        #expect(try decodeLightCapture(reverted).snapshot == projectionA.snapshot)
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
            scrollbackReads: [paneIds[0]: { _ in
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
                survivingPane: { _ in "surviving pane, capture A\n" },
                closingPane: { _ in "closing pane, capture A\n" },
            ]
        )

        update(&model, .closeTab(id: tabs[1].id))
        let captureB = CheckpointCapture(
            snapshot: toSnapshot(model),
            scrollbackReads: [survivingPane: { _ in "surviving pane, capture B\n" }]
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
                paneIds[0]: { _ in "live\n" },
                PaneId(): { _ in "stale\n" },
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
        // Why it exists: the two checkpoint tiers now share one pipeline, and the light tier is
        //   the frequent one. Routing it through the capture puts it through `graftScrollback`,
        //   which rebuilds every group and tab field by field -- a field added to a snapshot
        //   struct but not to that rebuild would now be dropped from the light checkpoint too,
        //   silently and on every save. The model below populates the optional fields precisely
        //   so this notices.
        // Scenario: spec-first. Light checkpoint bytes, via a capture and via `toInitFile`.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        model.groups[0].isCollapsed = true
        model.groups[0].tabs[0].customTitle = "renamed"
        model.groups[0].tabs[0].color = .purple
        model.groups[0].tabs[0].todos = [TodoItem(id: UUID(), text: "tab todo", isDone: true)]
        if case .leaf(var pane) = model.groups[0].tabs[0].paneTree.root {
            pane.session?.title = "vim"
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

    @Test("the capture's retention reaches both the pane read and the truncation")
    func captureThreadsOneRetentionThroughBothHalves() throws {
        // Intent: the retention a capture carries is the value handed to each pane's read, and
        //   the same value bounds the cut applied to what comes back.
        // Why it exists: a read given a smaller budget than the cut silently stores less than
        //   the pane is owed, and nothing downstream can tell. `ScrollbackRetention` exists to
        //   make the two agree by construction; this is the test that the capture does not
        //   quietly reintroduce the gap by resolving one half against a different value.
        // Scenario: spec-first. A one-line budget, and a read that reports what it was asked for.
        let (model, paneIds) = makeModelWithPanes(1)
        let retention = ScrollbackRetention(maxLines: 1, maxChars: 400_000)
        let observed = Recorder<ScrollbackRetention?>(nil)

        let capture = CheckpointCapture(
            snapshot: toSnapshot(model),
            scrollbackReads: [paneIds[0]: { asked in
                observed.value = asked
                return "first\nsecond\n"
            }],
            retention: retention
        )
        let scrollback = try decodeScrollback(capture.encoder()())

        #expect(observed.value?.maxLines == 1)
        #expect(observed.value?.maxChars == 400_000)
        #expect(scrollback[paneIds[0]] == "second\n", "the cut applies the same one-line budget")
    }
}
