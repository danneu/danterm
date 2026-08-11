// Behavioral coverage for session-keyed lifecycle reports at the pure model boundary.
import Foundation
import Testing

@testable import DanTermCore

struct SessionReportTests {
    @Test("lifecycle reports reduce into their identified session")
    func lifecycleReportsReduceIntoSession() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)?.focusedPaneId)
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
        let paneId = try #require(selectedTab(in: model)?.focusedPaneId)
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

    @Test("unknown session termination callbacks are dropped")
    func unknownSessionTerminationCallbacksAreDropped() {
        for message: Msg in [
            .sessionEnded(sessionId: SessionId()),
            .sessionCreationFailed(sessionId: SessionId()),
        ] {
            var model = makeModel()
            createTab(&model)
            let before = model

            let commands = update(&model, message)

            #expect(model == before)
            #expect(commands.isEmpty)
        }
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
        #expect(SessionReport.remoteIdentityReported(
            RemoteSession(user: half, host: otherHalf)
        ).isAdmitted)
        #expect(SessionReport.remoteIdentityReported(
            RemoteSession(user: half + "x", host: otherHalf)
        ).isAdmitted == false)
    }

    @Test("repeated waiting activity emits one background alert")
    func repeatedWaitingActivityEmitsOneAlert() throws {
        var model = makeModel()
        createTab(&model)
        let backgroundPaneId = try #require(selectedTab(in: model)?.focusedPaneId)
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
}
