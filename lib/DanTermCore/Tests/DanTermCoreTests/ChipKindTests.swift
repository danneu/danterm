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

    private func chipKind(of tabId: TabId, in projection: SidebarProjection) -> ChipKind? {
        projection.groups.flatMap(\.tabs).first { $0.id == tabId }?.chipKind
    }
}
