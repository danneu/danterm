// Behavioral coverage for session-keyed lifecycle reports at the pure model boundary.
import Foundation
import Testing

@testable import DanTermCore

struct SessionReportTests {
    @Test("value reports reduce into their identified session")
    func valueReportsReduceIntoSession() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        update(&model, .sessionReport(sessionId: sessionId, report: .title("vim")))
        update(&model, .sessionReport(sessionId: sessionId, report: .cwd("/tmp/project")))
        update(&model, .sessionReport(
            sessionId: sessionId,
            report: .progress(.set(percent: 42))
        ))

        #expect(model.pane(paneId)?.session?.title == "vim")
        #expect(model.pane(paneId)?.session?.cwd == "/tmp/project")
        #expect(model.pane(paneId)?.session?.progress == .set(percent: 42))
    }

    @Test("lifecycle reports reduce into their identified session")
    func lifecycleReportsReduceIntoSession() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted("swift test")))

        #expect(model.pane(paneId)?.session?.command == .running("swift test"))
        #expect(model.pane(paneId)?.session?.lastCommand == "swift test")
    }

    @Test("unknown session reports are dropped")
    func unknownSessionReportsAreDropped() {
        var model = makeModel()
        createTab(&model)
        let before = model

        let commands = update(
            &model,
            .sessionReport(sessionId: SessionId(), report: .integrationReady)
        )

        #expect(model == before)
        #expect(commands.isEmpty)
    }

    @Test("a replaced session cannot mutate its replacement")
    func replacedSessionReportsAreDropped() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        let staleId = try #require(model.pane(paneId)?.session?.id)
        let replacementId = SessionId()
        model.updatePane(paneId) { $0.session = SessionModel(id: replacementId) }

        let commands = update(
            &model,
            .sessionReport(sessionId: staleId, report: .commandStarted("stale"))
        )

        #expect(model.pane(paneId)?.session?.id == replacementId)
        #expect(model.pane(paneId)?.session?.command == .idle)
        #expect(commands.isEmpty)
    }

    @Test("a replaced session cannot retitle its replacement")
    func replacedSessionTitleReportIsDropped() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        let staleId = try #require(model.pane(paneId)?.session?.id)
        let replacementId = SessionId()
        model.updatePane(paneId) { $0.session = SessionModel(id: replacementId) }

        let commands = update(
            &model,
            .sessionReport(sessionId: staleId, report: .title("stale"))
        )

        #expect(model.pane(paneId)?.session?.id == replacementId)
        #expect(model.pane(paneId)?.session?.title == nil)
        #expect(commands.isEmpty)
    }

    @Test("an unknown session cannot ring a bell")
    func unknownSessionBellIsDropped() {
        assertUnknownSessionCallbackIsDropped { .sessionBell(sessionId: $0) }
    }

    @Test("an unknown session cannot notify")
    func unknownSessionNotificationIsDropped() {
        assertUnknownSessionCallbackIsDropped {
            .sessionNotification(sessionId: $0, title: "Build", body: "Done")
        }
    }

    @Test("an unknown session cannot end a pane")
    func unknownSessionEndIsDropped() {
        assertUnknownSessionCallbackIsDropped { .sessionEnded(sessionId: $0) }
    }

    @Test("an unknown session creation failure cannot close a pane")
    func unknownSessionCreationFailureIsDropped() {
        assertUnknownSessionCallbackIsDropped { .sessionCreationFailed(sessionId: $0) }
    }

    @Test("a replaced session cannot ring a bell")
    func replacedSessionBellIsDropped() throws {
        try assertReplacedSessionCallbackIsDropped { .sessionBell(sessionId: $0) }
    }

    @Test("a replaced session cannot notify")
    func replacedSessionNotificationIsDropped() throws {
        try assertReplacedSessionCallbackIsDropped {
            .sessionNotification(sessionId: $0, title: "Build", body: "Done")
        }
    }

    @Test("a replaced session cannot end its replacement")
    func replacedSessionEndIsDropped() throws {
        try assertReplacedSessionCallbackIsDropped { .sessionEnded(sessionId: $0) }
    }

    @Test("a replaced session creation failure cannot close its replacement")
    func replacedSessionCreationFailureIsDropped() throws {
        try assertReplacedSessionCallbackIsDropped { .sessionCreationFailed(sessionId: $0) }
    }

    @Test("metadata admission accepts the byte limit and rejects one byte over")
    func metadataAdmissionHonorsByteLimit() {
        let limit = TerminalMetadataBounds.maximumValueBytes
        let atLimit = String(repeating: "a", count: limit)
        let overLimit = atLimit + "b"
        let half = String(repeating: "u", count: limit / 2)
        let otherHalf = String(repeating: "h", count: limit - half.utf8.count)

        #expect(SessionReport.commandStarted(atLimit).isAdmitted)
        #expect(SessionReport.commandStarted(overLimit).isAdmitted == false)
        #expect(SessionReport.title(atLimit).isAdmitted)
        #expect(SessionReport.title(overLimit).isAdmitted == false)
        #expect(SessionReport.cwd(atLimit).isAdmitted)
        #expect(SessionReport.cwd(overLimit).isAdmitted == false)
        #expect(SessionReport.connectionDeclared(.remote(identity:
            RemoteSession(user: half, host: otherHalf)
        )).isAdmitted)
        #expect(SessionReport.connectionDeclared(.remote(identity:
            RemoteSession(user: half + "x", host: otherHalf)
        )).isAdmitted == false)
    }

    @Test("repeated waiting activity emits one background alert")
    func repeatedWaitingActivityEmitsOneAlert() throws {
        var model = makeModel()
        createTab(&model)
        let backgroundPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        let sessionId = try #require(model.pane(backgroundPaneId)?.session?.id)
        createTab(&model)
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(agent)))
        update(&model, .sessionReport(
            sessionId: sessionId,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))
        let alertCount = model.alerts.count
        update(&model, .sessionReport(
            sessionId: sessionId,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))

        #expect(model.alerts.count == alertCount)
    }

    @Test("a background session report mutates and alerts for one owning pane")
    func backgroundSessionReportUsesOneOwningPane() throws {
        // Intent: the pane mutated by a session report is also the pane named by
        //   every alert and command that the report produces.
        // Why it exists: separate session lookups can disagree if ownership
        //   changes between them; this pins one end-to-end identity result.
        // Scenario: a waiting report arrives for a pane in a non-selected tab
        //   while the selected tab has two other live sessions.
        var model = makeModel()
        createTab(&model)
        let targetPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        let targetSessionId = try #require(model.pane(targetPaneId)?.session?.id)
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-identity"))

        update(&model, .sessionReport(
            sessionId: targetSessionId,
            report: .agentAttached(agent)
        ))
        let sessionsBefore = Dictionary(uniqueKeysWithValues: model.allPanes.compactMap { pane in
            pane.session.map { (pane.id, $0) }
        })

        let commands = update(&model, .sessionReport(
            sessionId: targetSessionId,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))

        #expect(model.pane(targetPaneId)?.session != sessionsBefore[targetPaneId])
        for pane in model.allPanes where pane.id != targetPaneId {
            #expect(pane.session == sessionsBefore[pane.id])
        }
        #expect(model.alerts.isEmpty == false)
        #expect(model.alerts.allSatisfy { $0.paneId == targetPaneId })
        #expect(commands.isEmpty == false)
        #expect(commands.allSatisfy { command in
            if case .sendNotification(_, let paneId, _, _, _) = command {
                return paneId == targetPaneId
            }
            return false
        })
    }

    private func assertUnknownSessionCallbackIsDropped(_ message: (SessionId) -> Msg) {
        var model = makeModel()
        createTab(&model)
        let before = model

        let commands = update(&model, message(SessionId()))

        #expect(model == before)
        #expect(commands.isEmpty)
    }

    private func assertReplacedSessionCallbackIsDropped(
        _ message: (SessionId) -> Msg
    ) throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        let staleId = try #require(model.pane(paneId)?.session?.id)
        model.updatePane(paneId) { $0.session = SessionModel(id: SessionId()) }
        let before = model

        let commands = update(&model, message(staleId))

        #expect(model == before)
        #expect(commands.isEmpty)
    }
}
