// Runtime-side coverage for the rule that only delivered user input ends an agent
// wait: the on-demand read a pane makes at input origin, the fast path that drops an
// occurrence which can retract nothing, and the wait a dispatched input command carries.
import DanTermProtocol
import Foundation
import Testing
@testable import DanTerm

@MainActor
struct AppRuntimeWaitRetractionTests {
    /// Creates one pane with an attached agent and returns the ids the tests address it by.
    private func makeWaitingPane(
        _ runtime: AppRuntime
    ) throws -> (paneId: PaneId, sessionId: SessionId, agent: AgentSession) {
        runtime.send(.createTabInSelectedGroup())
        let paneId = try #require(runtime.model.allPaneIds.first {
            runtime.model.pane($0)?.session != nil
        })
        let sessionId = try #require(runtime.model.pane(paneId)?.session?.id)
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        runtime.send(.sessionReport(sessionId: sessionId, report: .agentAttached(agent)))
        runtime.send(.sessionReport(
            sessionId: sessionId,
            report: .agentActivityChanged(session: agent, activity: .waiting)
        ))
        return (paneId, sessionId, agent)
    }

    private func waitGeneration(
        _ runtime: AppRuntime,
        _ paneId: PaneId
    ) -> AgentWaitGeneration? {
        runtime.model.pane(paneId)?.session?.agent.currentWaitGeneration
    }

    @Test("a pane reads its current wait on demand, without waiting for a view sweep")
    func paneReadsItsWaitOnDemand() throws {
        // Intent: the closure the runtime installs answers with the wait the model holds
        //   at the moment it is called, including a wait admitted since the last sweep.
        // Why it exists: activity reports defer their view sweep by a coalesce window, so
        //   a copy pushed down to the pane would still name the previous wait exactly when
        //   a question has just been asked -- and the keystroke that dismisses it would
        //   retract nothing.
        // Scenario: an agent reports `waiting` and the user types before any sweep runs.
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let pane = try makeWaitingPane(runtime)

        let read = try #require(ports.session.currentAgentWaitGeneration)
        #expect(read() == waitGeneration(runtime, pane.paneId))

        runtime.send(.sessionReport(
            sessionId: pane.sessionId,
            report: .agentActivityChanged(session: pane.agent, activity: .waiting)
        ))
        #expect(read() == waitGeneration(runtime, pane.paneId))
    }

    @Test("a delivered occurrence retracts only the wait it names")
    func occurrenceRetractsOnlyTheWaitItNames() throws {
        // Intent: the occurrence the pane reports reaches the model as a retraction when
        //   it names the live wait, and changes nothing when it names an older one.
        // Why it exists: the runtime drops a non-retracting occurrence before `send()`
        //   snapshots the whole model, and that fast path must decide exactly what the
        //   reducer would decide -- typing is the highest-rate event a pane produces.
        // Scenario: the user answers one question, and a stale occurrence from an earlier
        //   input lands after the agent has asked a second one.
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let pane = try makeWaitingPane(runtime)
        let live = try #require(waitGeneration(runtime, pane.paneId))
        let onEvent = try #require(ports.session.onEvent)

        onEvent(.report(.userInputDelivered(waitGeneration: live)))
        #expect(waitGeneration(runtime, pane.paneId) == nil)
        #expect(runtime.model.pane(pane.paneId)?.session?.agent == .attached(
            session: pane.agent,
            activity: nil
        ))

        runtime.send(.sessionReport(
            sessionId: pane.sessionId,
            report: .agentActivityChanged(session: pane.agent, activity: .waiting)
        ))
        let renewed = try #require(waitGeneration(runtime, pane.paneId))
        onEvent(.report(.userInputDelivered(waitGeneration: live)))
        #expect(waitGeneration(runtime, pane.paneId) == renewed)
    }

    @Test("a dispatched input command carries its wait to the pane")
    func inputCommandCarriesItsWait() throws {
        // Intent: the wait `update()` stamped on an input command reaches the session that
        //   writes the bytes.
        // Why it exists: scripted input snapshots its wait in pure dispatch, so the value
        //   is only useful if the command interpreter hands it on unchanged.
        // Scenario: `danterm pane input -- Escape` on a pane whose agent is waiting.
        let ports = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(ports)
        defer { runtime.shutdown() }
        let pane = try makeWaitingPane(runtime)
        let live = try #require(waitGeneration(runtime, pane.paneId))

        runtime.perform(.sendInputKey(
            paneId: pane.paneId,
            key: .named(.escape),
            mods: KeyMods(),
            submissionId: InputSubmissionId(rawValue: UUID()),
            waitGeneration: live
        ))

        #expect(ports.session.submittedWaitGenerations == [live])
    }
}
