// Covers how an incoming alert is split across the three notification slots:
// who it came from (title), where that pane lives (subtitle), and what was said
// (body). The body is the sender's own words and must survive untouched -- the
// rejected alternative was prefixing it with the sender name, which would have
// left the stored alert disagreeing with what the sender actually wrote.
import Foundation
import Testing

@testable import DanTermCore

@Suite("Alert presentation")
struct AlertPresentationTests {
    /// Emit a desktop notification into a background tab's pane and return the
    /// resulting command, since a focused pane in an active app is suppressed.
    private func notification(
        _ model: inout AppModel,
        paneId: PaneId,
        title: String,
        body: String,
        semantics: PaneSemanticState = PaneSemanticState()
    ) -> (title: String, subtitle: String?, body: String)? {
        let commands = update(
            &model,
            .desktopNotification(paneId: paneId, title: title, body: body),
            livePaneState: LivePaneStateView(semanticsByPaneId: [paneId: semantics])
        )
        for command in commands {
            if case .sendNotification(_, _, let title, let subtitle, let body) = command {
                return (title, subtitle, body)
            }
        }
        return nil
    }

    @Test("OSC 777 title becomes the notification title and the body is untouched")
    func senderTitleFillsTitleSlot() {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        createTab(&model)

        let sent = notification(&model, paneId: paneId, title: "claude", body: "Build finished")

        #expect(sent?.title == "claude")
        #expect(sent?.body == "Build finished")
    }

    @Test("live agent and command identity precede sender and pane titles")
    func liveSemanticTitleTiersPrecedeTerminalTitles() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .sessionTitle(paneId: paneId, title: "pane-title"))
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        var commandState = PaneSemanticState(command: .running("swift test"))

        let command = alertPresentation(
            senderTitle: "sender",
            paneId: paneId,
            livePaneState: LivePaneStateView(semanticsByPaneId: [paneId: commandState]),
            in: model
        )
        commandState.agent = .attached(session: agent, activity: .waiting)
        let attached = alertPresentation(
            senderTitle: "sender",
            paneId: paneId,
            livePaneState: LivePaneStateView(semanticsByPaneId: [paneId: commandState]),
            in: model
        )

        #expect(command.title == "swift test")
        #expect(attached.title == "Codex thread-1")
    }

    @Test("desktop alert storage and delivery share the live semantic title")
    func desktopAlertUsesSemanticTitleEndToEnd() {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        createTab(&model)
        let semantics = PaneSemanticState(command: .running("swift test"))

        let sent = notification(
            &model,
            paneId: paneId,
            title: "sender",
            body: "Done",
            semantics: semantics
        )

        #expect(sent?.title == "swift test")
        #expect(model.alerts.first?.title == "swift test")
    }

    // OSC 9 carries no title field at all (Terminal.dispatchOSC9 passes empty
    // bytes), so without a fallback the banner shows a blank bold line and the
    // alerts popover renders an empty title field.
    @Test("OSC 9 with no sender title falls back to the pane title")
    func emptySenderTitleFallsBackToPaneTitle() {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .sessionTitle(paneId: paneId, title: "codex"))
        createTab(&model)

        let sent = notification(&model, paneId: paneId, title: "", body: "Ready for review")

        #expect(sent?.title == "codex")
        #expect(sent?.body == "Ready for review")
    }

    @Test("The stored alert carries the same resolved title as the banner")
    func storedAlertMatchesBanner() {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .sessionTitle(paneId: paneId, title: "codex"))
        createTab(&model)

        let sent = notification(&model, paneId: paneId, title: "", body: "Ready for review")

        #expect(model.alerts.first?.title == sent?.title)
        #expect(model.alerts.first?.body == "Ready for review")
    }

    @Test("A named tab becomes the subtitle")
    func namedTabFillsSubtitleSlot() {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .renameTab(id: tabId, name: "danterm"))
        createTab(&model)

        let sent = notification(&model, paneId: paneId, title: "claude", body: "Build finished")

        #expect(sent?.subtitle == "danterm")
    }

    // An unnamed single-pane tab derives its own title from that pane, so the
    // location line would repeat the title slot verbatim.
    @Test("A subtitle that would repeat the title is dropped")
    func redundantSubtitleIsDropped() {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .sessionTitle(paneId: paneId, title: "codex"))
        createTab(&model)

        let sent = notification(&model, paneId: paneId, title: "", body: "Ready for review")

        #expect(sent?.subtitle == nil)
    }

    @Test("A split tab names which pane sent the alert")
    func splitTabSubtitleCarriesPanePosition() {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let firstPaneId = model.groups[0].tabs[0].focusedPaneId
        update(&model, .renameTab(id: tabId, name: "danterm"))
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let paneIds = allPaneIds(model.groups[0].tabs[0].rootNode)
        #expect(paneIds.count == 2)
        createTab(&model)

        let first = notification(&model, paneId: paneIds[0], title: "claude", body: "one")
        let second = notification(&model, paneId: paneIds[1], title: "claude", body: "two")

        #expect(first?.subtitle == "danterm - pane 1")
        #expect(second?.subtitle == "danterm - pane 2")
    }
}
