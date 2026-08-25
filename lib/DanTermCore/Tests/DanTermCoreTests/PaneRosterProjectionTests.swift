// Behavioral coverage for the pure Model -> PaneRoster projection: the pane
// order it walks, the tab title it resolves, and which model changes it does and
// does not react to.
//
// The wire encoding of the roster value itself is asserted in DanTermProtocol's
// PaneRosterTests; this file is only about what the model projects.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

struct PaneRosterProjectionTests {
    // Ported from the phone-side `projectPaneList` tests that this projection
    // replaces, so the phone keeps seeing the same order and the same titles.
    @Test("Nested split leaves appear once in display order with tab state")
    func nestedSplitLeavesAppearOnceInOrder() {
        var model = makeRosterModel(tabCount: 2)
        let firstTab = model.groups[0].tabs[0]
        let paneA = firstTab.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let ordered = allPaneIds(model.groups[0].tabs[0].paneTree.root)
        model.groups[0].tabs[0].customTitle = "Pinned"
        model.selectedTabId = model.groups[0].tabs[1].id

        let roster = paneRoster(in: model)

        #expect(roster.panes.map(\.paneId) == ordered + [model.groups[0].tabs[1].paneTree.focusedPaneId])
        #expect(roster.panes.map(\.tabTitle).prefix(2) == ["Pinned", "Pinned"])
        #expect(roster.panes.map(\.isSelectedTab) == [false, false, true])
        #expect(roster.panes.map(\.isFocused).filter { $0 }.count == 2)
        #expect(roster.panes.allSatisfy { $0.groupName == "Work" })
    }

    // Ported from the phone-side title-fallback test: custom title, then a
    // terminal title that is not the placeholder, then the running command.
    @Test("Tab title falls back from custom title to terminal title to running command")
    func tabTitleFallbackChain() {
        var model = makeRosterModel(tabCount: 3)
        setFocusedSession(&model, tab: 0, title: "shell", command: "ignored")
        model.groups[0].tabs[0].customTitle = "Custom"
        setFocusedSession(&model, tab: 1, title: "project", command: "ignored")
        setFocusedSession(&model, tab: 2, title: "Terminal", command: "htop")

        let roster = paneRoster(in: model)

        #expect(roster.panes.map(\.tabTitle) == ["Custom", "project", "htop"])
        #expect(roster.panes.map(\.paneTitle) == ["shell", "project", "Terminal"])
    }

    @Test("A pane with no terminal session reports the placeholder title")
    func placeholderTitleWithoutSession() {
        let model = makeRosterModel()

        let roster = paneRoster(in: model)

        #expect(roster.panes.map(\.paneTitle) == ["Terminal"])
        #expect(roster.panes.map(\.tabTitle) == ["Terminal"])
    }

    @Test("A pane reports the chip its attached agent earns")
    func chipFollowsTheAttachedAgent() {
        // Intent: the roster resolves an agent kind to a chip, including the
        //   collapse of every agent DanTerm ships no mark for onto the generic one.
        // Why it exists: this is the only place the collapse happens, so a client
        //   that drew the wrong mark would have no second classification to blame.
        // Scenario: three panes -- a plain shell, Claude, and an agent DanTerm has
        //   never heard of.
        var model = makeRosterModel(tabCount: 3)
        attachAgent(&model, tab: 1, kind: "claude")
        attachAgent(&model, tab: 2, kind: "someagent")

        #expect(paneRoster(in: model).panes.map(\.chip) == [.terminal, .claude, .agent])

        attachAgent(&model, tab: 1, kind: "codex")

        #expect(paneRoster(in: model).panes.map(\.chip) == [.terminal, .codex, .agent])
    }

    @Test("Roster-relevant changes move the projection")
    func rosterRelevantChangesMoveTheProjection() {
        // Every case starts from the same model value, so a difference can only
        // come from the mutation and never from freshly minted ids.
        let base = makeRosterModel(tabCount: 2)
        let baseline = paneRoster(in: base)

        var model = base
        model.groups[0].name = "Renamed"
        #expect(paneRoster(in: model) != baseline)

        model = base
        model.groups[0].tabs[0].customTitle = "Pinned"
        #expect(paneRoster(in: model) != baseline)

        model = base
        setFocusedSession(&model, tab: 0, title: "vim")
        #expect(paneRoster(in: model) != baseline)

        model = base
        model.selectedTabId = model.groups[0].tabs[1].id
        #expect(paneRoster(in: model) != baseline)

        model = base
        update(&model, .splitPane(paneId: model.groups[0].tabs[0].paneTree.focusedPaneId, direction: .vertical))
        #expect(paneRoster(in: model) != baseline)

        // Attaching an agent changes the pane's chip, which is roster state now that
        // the roster carries it. Measured against a model that already holds the
        // session, so the agent is the only difference.
        model = base
        setFocusedSession(&model, tab: 0, title: "vim")
        let withSession = paneRoster(in: model)
        attachAgent(&model, tab: 0, kind: "codex")
        #expect(paneRoster(in: model) != withSession)
    }

    @Test("Non-roster changes leave the projection alone")
    func nonRosterChangesLeaveTheProjectionAlone() {
        var model = makeRosterModel()
        setFocusedSession(&model, tab: 0, title: "vim")
        attachAgent(&model, tab: 0, kind: "codex")
        let baseline = paneRoster(in: model)

        mutateFocusedSession(&model, tab: 0) { $0.cwd = "/Users/testhome/code" }
        #expect(paneRoster(in: model) == baseline)

        // The chip says which agent is attached, not what it is doing, so activity
        // must not push a roster to every subscriber on each turn.
        mutateFocusedSession(&model, tab: 0) {
            $0.agent = .attached(
                session: AgentSession(kind: "codex", sessionId: "thread-1")!,
                activity: storedActivity(.waiting)
            )
        }
        #expect(paneRoster(in: model) == baseline)

        model.groups[0].tabs[0].todos = [
            TodoItem(id: TodoId(), text: "ship it", isDone: false),
        ]
        #expect(paneRoster(in: model) == baseline)

        model.groups[0].isCollapsed = true
        #expect(paneRoster(in: model) == baseline)
    }

    @Test("Every roster title is normalized on the wire, one text source per case")
    func rosterTitlesAreNormalizedOnTheWire() {
        // Intent: the group name, the pane title, and the tab title through each
        //   of its fallbacks leave the projection with no control, bidi override,
        //   or stray whitespace.
        // Why it exists: the roster is display-only text a client shows verbatim,
        //   and an implementation can prepare one source and miss another.
        // Scenario: a newline, a C1 control, and a bidi override in the raw text.
        let raw = "a\nb\u{85}c\u{202E}d "
        let normalized = "a b cd"

        var model = makeRosterModel()
        model.groups[0].name = raw
        #expect(paneRoster(in: model).panes.map(\.groupName) == [normalized])

        model = makeRosterModel()
        setFocusedSession(&model, tab: 0, title: raw)
        #expect(paneRoster(in: model).panes.map(\.paneTitle) == [normalized])
        #expect(paneRoster(in: model).panes.map(\.tabTitle) == [normalized])

        model = makeRosterModel()
        model.groups[0].tabs[0].customTitle = raw
        #expect(paneRoster(in: model).panes.map(\.tabTitle) == [normalized])

        model = makeRosterModel()
        setFocusedSession(&model, tab: 0, title: "Terminal", command: raw)
        #expect(paneRoster(in: model).panes.map(\.tabTitle) == [normalized])
    }

    @Test("The IPC encoding and the checkpoint snapshot keep the verbatim title")
    func machineSurfacesKeepTheVerbatimTitle() throws {
        // Why it exists: normalizing for the roster must not leak into the
        //   surfaces IPC targets panes by and checkpoints restore from.
        let raw = "a\nb\u{85}c\u{202E}d "
        var model = makeRosterModel()
        setFocusedSession(&model, tab: 0, title: raw)

        let encoded = IpcEntityEncoder(home: "/Users/testhome").list(model)
        let tab = try #require(encoded["groups"]?.asArray?.first?["tabs"]?.asArray?.first)
        #expect(tab["rootNode"]?["pane"]?["title"]?.asString == raw)

        let snapshot = toSnapshot(model, home: "/Users/testhome")
        guard case .leaf(let pane) = snapshot.groups[0].tabs[0].rootNode else {
            Issue.record("expected a single-pane leaf")
            return
        }
        #expect(pane.title == raw)
    }
}

// MARK: - Fixtures

/// One group of single-pane tabs, first tab selected, so a test can state the
/// roster field it changes without building a tree by hand.
private func makeRosterModel(tabCount: Int = 1) -> AppModel {
    var tabs: [TabModel] = []
    for _ in 0..<tabCount {
        let paneId = PaneId()
        tabs.append(TabModel(
            id: TabId(),
            paneTree: PaneTree(root: .leaf(PaneModel(id: paneId)), focusedPaneId: paneId)
        ))
    }
    var model = AppModel(groups: [GroupModel(id: GroupId(), name: "Work", tabs: tabs)])
    model.selectedTabId = tabs.first?.id
    return model
}

private func setFocusedSession(
    _ model: inout AppModel,
    tab index: Int,
    title: String,
    command: String? = nil
) {
    mutateFocusedPane(&model, tab: index) { pane in
        var session = pane.session ?? SessionModel(id: SessionId())
        session.title = title
        session.command = command.map { CommandLifecycle.running($0) } ?? .idle
        pane.session = session
    }
}

/// Attaches an agent of `kind` to a tab's focused pane, creating the terminal
/// session first when the pane has none, so a chip test can name only the agent.
private func attachAgent(_ model: inout AppModel, tab index: Int, kind: String) {
    mutateFocusedPane(&model, tab: index) { pane in
        var session = pane.session ?? SessionModel(id: SessionId())
        session.agent = .attached(
            session: AgentSession(kind: kind, sessionId: "thread-1")!,
            activity: nil
        )
        pane.session = session
    }
}

private func mutateFocusedSession(
    _ model: inout AppModel,
    tab index: Int,
    _ body: (inout SessionModel) -> Void
) {
    mutateFocusedPane(&model, tab: index) { pane in
        guard var session = pane.session else { return }
        body(&session)
        pane.session = session
    }
}

private func mutateFocusedPane(
    _ model: inout AppModel,
    tab index: Int,
    _ body: (inout PaneModel) -> Void
) {
    let paneId = model.groups[0].tabs[index].paneTree.focusedPaneId
    model.groups[0].tabs[index].paneTree.updatePane(paneId) { pane in
        body(&pane)
    }
}
