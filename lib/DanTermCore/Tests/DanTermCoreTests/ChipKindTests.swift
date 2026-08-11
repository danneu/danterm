// Coverage for the pane-kind chip: the mapping from a pane's agent lifecycle to
// a chip, and the two projections that carry it to the sidebar and the pane
// toolbar. Chip drawing is not here -- the core only decides which chip.
import Foundation
import Testing

@testable import DanTermCore

struct ChipKindTests {
    @Test("an unattached pane is a plain terminal chip")
    func unattachedPaneIsTerminal() {
        #expect(ChipKind(agent: .none) == .terminal)
    }

    @Test("a known agent kind selects its own chip")
    func knownAgentKindsSelectTheirChip() throws {
        let claude = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let codex = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))

        #expect(ChipKind(agent: .attached(session: claude, activity: nil)) == .claude)
        #expect(ChipKind(agent: .attached(session: codex, activity: .waiting)) == .codex)
    }

    // Why it exists: hook strings are untrusted and open-ended, so any kind
    //   outside the shipped artwork must still resolve to a drawable chip. It
    //   must not be the terminal chip: a pane running an agent DanTerm cannot
    //   name is still not a plain shell, and the sidebar has no room to say so
    //   in words.
    @Test("an agent kind with no chip of its own uses the generic agent chip")
    func unknownAgentKindUsesGenericAgentChip() throws {
        let other = try #require(AgentSession(kind: "aider", sessionId: "run-1"))

        #expect(ChipKind(agent: .attached(session: other, activity: nil)) == .agent)
    }

    // Why it exists: activity is a separate axis from identity -- a busy Claude
    //   pane must not change chips mid-turn.
    @Test("agent activity does not change the chip")
    func activityDoesNotChangeChip() throws {
        let claude = try #require(AgentSession(kind: "claude", sessionId: "session-1"))

        for activity: AgentActivity? in [nil, .working, .waiting, .idle] {
            #expect(ChipKind(agent: .attached(session: claude, activity: activity)) == .claude)
        }
    }

    @Test("a sidebar tab row shows its focused pane's chip")
    func sidebarTabCarriesFocusedPaneChip() throws {
        var model = makeModel()
        createTab(&model)
        let tab = try #require(selectedTab(in: model))
        let sessionId = try #require(model.pane(tab.focusedPaneId)?.session?.id)
        let claude = try #require(AgentSession(kind: "claude", sessionId: "session-1"))

        #expect(chipKind(of: tab.id, in: desiredSidebar(in: model)) == .terminal)

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(claude)))

        #expect(chipKind(of: tab.id, in: desiredSidebar(in: model)) == .claude)
    }

    // Why it exists: a tab's row speaks for the focused pane only, so an agent
    //   in an unfocused split must not claim the row's chip.
    @Test("an agent in an unfocused split does not change the tab's chip")
    func unfocusedSplitDoesNotChangeTabChip() throws {
        var model = makeModel()
        createTab(&model)
        let tab = try #require(selectedTab(in: model))
        let originalPaneId = tab.focusedPaneId
        update(&model, .splitPane(paneId: originalPaneId, direction: .horizontal))
        let focusedPaneId = try #require(selectedTab(in: model)).focusedPaneId
        #expect(focusedPaneId != originalPaneId)
        let sessionId = try #require(model.pane(originalPaneId)?.session?.id)
        let claude = try #require(AgentSession(kind: "claude", sessionId: "session-1"))

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(claude)))

        #expect(chipKind(of: tab.id, in: desiredSidebar(in: model)) == .terminal)
    }

    @Test("a pane toolbar render carries that pane's own chip")
    func paneToolbarCarriesPaneChip() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        let codex = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))

        #expect(desiredPaneToolbar(in: model)[paneId]?.chipKind == .terminal)

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(codex)))

        #expect(desiredPaneToolbar(in: model)[paneId]?.chipKind == .codex)
    }

    // Why it exists: the row's second line is a cwd until the tab splits, so an
    //   empty strip is the signal that the cwd still owns that line.
    @Test("a single-pane tab has no pane strip")
    func singlePaneTabHasNoStrip() throws {
        var model = makeModel()
        createTab(&model)
        let tab = try #require(selectedTab(in: model))

        #expect(tabPaneChips(tab, alerts: []).isEmpty)
    }

    @Test("a split tab's strip lists every pane in tree order, focus flagged")
    func splitTabStripListsPanesInOrder() throws {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = try #require(selectedTab(in: model)).focusedPaneId
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let secondPaneId = try #require(selectedTab(in: model)).focusedPaneId
        update(&model, .splitPane(paneId: secondPaneId, direction: .vertical))
        let thirdPaneId = try #require(selectedTab(in: model)).focusedPaneId

        let tab = try #require(selectedTab(in: model))
        let strip = tabPaneChips(tab, alerts: [])

        #expect(strip.map(\.paneId) == [firstPaneId, secondPaneId, thirdPaneId])
        #expect(strip.map(\.isFocused) == [false, false, true])
    }

    // Why it exists: a focus move inside a tab changes no other projected field,
    //   so without the strip in the projection the row would never reload and
    //   the highlight would sit on the pane you just left.
    @Test("moving focus between panes restyles the strip through the projection")
    func focusMoveReachesTheSidebarProjection() throws {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = try #require(selectedTab(in: model)).focusedPaneId
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let tab = try #require(selectedTab(in: model))

        let before = try #require(paneChips(of: tab.id, in: desiredSidebar(in: model)))
        #expect(before.first(where: \.isFocused)?.paneId != firstPaneId)

        update(&model, .paneBecameFirstResponder(paneId: firstPaneId))

        let after = try #require(paneChips(of: tab.id, in: desiredSidebar(in: model)))
        #expect(after.first(where: \.isFocused)?.paneId == firstPaneId)
        #expect(after != before)
    }

    // Why it exists: the strip drops brand color for a shared palette, so the
    //   kind is the only thing left that tells one pane from another in it.
    @Test("a pane strip reports each pane's own kind, not the tab's")
    func stripReportsEachPanesOwnKind() throws {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = try #require(selectedTab(in: model)).focusedPaneId
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let sessionId = try #require(model.pane(firstPaneId)?.session?.id)
        let claude = try #require(AgentSession(kind: "claude", sessionId: "session-1"))

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(claude)))

        let tab = try #require(selectedTab(in: model))
        #expect(tabPaneChips(tab, alerts: []).map(\.kind) == [.claude, .terminal])
        // The row's own chip still speaks for the focused pane alone.
        #expect(chipKind(of: tab.id, in: desiredSidebar(in: model)) == .terminal)
    }

    // Why it exists: the five facts behind a chip collapse onto one dot, and the
    //   collapse is the policy -- an unread alert and an agent blocked on a
    //   prompt are the same message to the reader, and neither an idle agent nor
    //   one that has reported nothing has anything to say.
    @Test("a pane's alert and activity collapse onto one state")
    func paneStateCollapsesAlertAndActivity() throws {
        let claude = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        func state(_ activity: AgentActivity?, alert: Bool = false) -> PaneChipState {
            paneChipState(agent: .attached(session: claude, activity: activity), hasUnreadAlert: alert)
        }

        #expect(state(.waiting) == .attention)
        #expect(state(.working) == .busy)
        #expect(state(.idle) == .quiet)
        #expect(state(nil) == .quiet)
        #expect(paneChipState(agent: .none, hasUnreadAlert: false) == .quiet)
    }

    // Why it exists: a bell rings while an agent is mid-turn, so the two states
    //   genuinely coincide and the chip has one dot to spend. Attention has to
    //   win, or a busy pane could ring and show no change at all.
    @Test("an unread alert outranks a working agent for the one dot")
    func alertOutranksWorking() throws {
        let claude = try #require(AgentSession(kind: "claude", sessionId: "session-1"))

        #expect(
            paneChipState(agent: .attached(session: claude, activity: .working), hasUnreadAlert: true)
                == .attention)
        // Also for a pane with no agent at all: a shell can ring the bell.
        #expect(paneChipState(agent: .none, hasUnreadAlert: true) == .attention)
    }

    // Why it exists: nothing else in the tab's projection moves when one pane's
    //   agent starts or stops working, so if the state did not ride along in
    //   `paneChips` the row would never reload and the dot would never appear.
    @Test("a pane's activity change restates the strip through the projection")
    func activityChangeReachesTheSidebarProjection() throws {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = try #require(selectedTab(in: model)).focusedPaneId
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let tab = try #require(selectedTab(in: model))
        let sessionId = try #require(model.pane(firstPaneId)?.session?.id)
        let claude = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(claude)))

        let before = try #require(paneChips(of: tab.id, in: desiredSidebar(in: model)))
        #expect(before.first?.state == .quiet)

        update(
            &model,
            .sessionReport(
                sessionId: sessionId,
                report: .agentActivityChanged(session: claude, activity: .working)))

        let after = try #require(paneChips(of: tab.id, in: desiredSidebar(in: model)))
        #expect(after.first?.state == .busy)
        #expect(after != before)
    }

    // Why it exists: the tab row's own alert badge counts the whole tab, so the
    //   strip is the only thing that says which pane rang. It reads the same
    //   tally the badge does, and this pins the two to the same pane.
    @Test("an unread alert marks the pane that raised it, not its neighbors")
    func alertMarksOnlyItsOwnPane() throws {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = try #require(selectedTab(in: model)).focusedPaneId
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let tab = try #require(selectedTab(in: model))
        model.alerts.append(
            AlertModel(
                id: AlertId(rawValue: UUID()), kind: .bell, paneId: firstPaneId,
                title: "bell", body: "", createdAt: Date(timeIntervalSince1970: 0), isUnread: true))

        let strip = tabPaneChips(tab, alerts: model.alerts)

        #expect(strip.map(\.state) == [.attention, .quiet])
        // Both overloads must agree, or the sidebar's hot path and the cell's
        // cold path would draw different strips for the same model.
        #expect(tabPaneChips(tab, unreadByPane: unreadAlertTally(for: model).byPane) == strip)
    }

    private func chipKind(of tabId: TabId, in projection: SidebarProjection) -> ChipKind? {
        projection.groups.flatMap(\.tabs).first { $0.id == tabId }?.chipKind
    }

    private func paneChips(of tabId: TabId, in projection: SidebarProjection) -> [TabPaneChip]? {
        projection.groups.flatMap(\.tabs).first { $0.id == tabId }?.paneChips
    }
}
