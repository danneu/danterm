// Coverage for the pane-kind chip: the mapping from a pane's agent lifecycle to
// a chip, and the two projections that carry it to the sidebar and the pane
// toolbar. Chip drawing is not here -- the core only decides which chip.
import DanTermProtocol
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
        #expect(ChipKind(agent: .attached(session: codex, activity: storedActivity(.waiting))) == .codex)
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
            #expect(ChipKind(agent: .attached(session: claude, activity: storedActivity(activity))) == .claude)
        }
    }

    @Test("a sidebar tab row shows its focused pane's chip")
    func sidebarTabCarriesFocusedPaneChip() throws {
        var model = makeModel()
        createTab(&model)
        let tab = try #require(selectedTab(in: model))
        let sessionId = try #require(model.pane(tab.paneTree.focusedPaneId)?.session?.id)
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
        let originalPaneId = tab.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: originalPaneId, direction: .horizontal))
        let focusedPaneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
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
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
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

        #expect(tabPaneChips(tab, unreadByPane: [:]).isEmpty)
    }

    @Test("a split tab's strip lists every pane in tree order, focus flagged")
    func splitTabStripListsPanesInOrder() throws {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let secondPaneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        update(&model, .splitPane(paneId: secondPaneId, direction: .vertical))
        let thirdPaneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId

        let tab = try #require(selectedTab(in: model))
        let strip = tabPaneChips(tab, unreadByPane: [:])

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
        let firstPaneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
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
        let firstPaneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let sessionId = try #require(model.pane(firstPaneId)?.session?.id)
        let claude = try #require(AgentSession(kind: "claude", sessionId: "session-1"))

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(claude)))

        let tab = try #require(selectedTab(in: model))
        #expect(tabPaneChips(tab, unreadByPane: [:]).map(\.kind) == [.claude, .terminal])
        // The row's own chip still speaks for the focused pane alone.
        #expect(chipKind(of: tab.id, in: desiredSidebar(in: model)) == .terminal)
    }

    // Intent: a pane that has rung a bell while its agent is mid-turn reports
    //   the alert and the working state, both of them.
    // Why it exists: the chip used to carry one collapsed state, so an alert
    //   on a working pane erased the fact that the agent was still running.
    //   Two independent facts need two fields; this is the bug in one line.
    @Test("an alerting pane with a working agent reports both facts")
    func alertAndActivityAreIndependent() throws {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let sessionId = try #require(model.pane(firstPaneId)?.session?.id)
        let claude = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(claude)))
        update(
            &model,
            .sessionReport(
                sessionId: sessionId,
                report: .agentActivityChanged(session: claude, activity: .working)))
        model.alerts.append(
            AlertModel(
                id: AlertId(rawValue: UUID()), kind: .bell, paneId: firstPaneId,
                title: "bell", body: "", createdAt: Date(timeIntervalSince1970: 0), isUnread: true))

        let tab = try #require(selectedTab(in: model))
        let chips = tabPaneChips(tab, unreadByPane: unreadAlertTally(for: model).byPane)

        #expect(chips.first?.hasAlert == true)
        #expect(chips.first?.agent == .working)
    }

    // Why it exists: the agent mark speaks only for what the hooks reported.
    //   Idle, unreported, and no agent at all are three ways of having nothing
    //   to say, and each of them must leave the mark off.
    @Test("the agent mark follows the reported activity and is otherwise quiet")
    func agentMarkFollowsReportedActivity() throws {
        let claude = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        func mark(_ activity: AgentActivity?) -> PaneAgentMark {
            paneAgentMark(agent: .attached(session: claude, activity: storedActivity(activity)))
        }

        #expect(mark(.waiting) == .waiting)
        #expect(mark(.working) == .working)
        #expect(mark(.idle) == .quiet)
        #expect(mark(nil) == .quiet)
        #expect(paneAgentMark(agent: .none) == .quiet)
    }

    // Why it exists: nothing else in the tab's projection moves when one pane's
    //   agent starts or stops working, so if the state did not ride along in
    //   `paneChips` the row would never reload and the dot would never appear.
    @Test("a pane's activity change restates the strip through the projection")
    func activityChangeReachesTheSidebarProjection() throws {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let tab = try #require(selectedTab(in: model))
        let sessionId = try #require(model.pane(firstPaneId)?.session?.id)
        let claude = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(claude)))

        let before = try #require(paneChips(of: tab.id, in: desiredSidebar(in: model)))
        #expect(before.first?.agent == .quiet)

        update(
            &model,
            .sessionReport(
                sessionId: sessionId,
                report: .agentActivityChanged(session: claude, activity: .working)))

        let after = try #require(paneChips(of: tab.id, in: desiredSidebar(in: model)))
        #expect(after.first?.agent == .working)
        #expect(after != before)
    }

    // Why it exists: the tab row's own alert badge counts the whole tab, so the
    //   strip is the only thing that says which pane rang. It reads the same
    //   tally the badge does, and this pins the two to the same pane.
    @Test("an unread alert marks the pane that raised it, not its neighbors")
    func alertMarksOnlyItsOwnPane() throws {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let tab = try #require(selectedTab(in: model))
        model.alerts.append(
            AlertModel(
                id: AlertId(rawValue: UUID()), kind: .bell, paneId: firstPaneId,
                title: "bell", body: "", createdAt: Date(timeIntervalSince1970: 0), isUnread: true))

        let strip = tabPaneChips(tab, unreadByPane: unreadAlertTally(for: model).byPane)

        #expect(strip.map(\.hasAlert) == [true, false])
        #expect(strip.map(\.agent) == [.quiet, .quiet])
    }

    private func chipKind(of tabId: TabId, in projection: SidebarProjection) -> ChipKind? {
        projection.groups.flatMap(\.tabs).first { $0.id == tabId }?.chipKind
    }

    private func paneChips(of tabId: TabId, in projection: SidebarProjection) -> [TabPaneChip]? {
        projection.groups.flatMap(\.tabs).first { $0.id == tabId }?.paneChips
    }
}
