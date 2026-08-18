// Pins the backend-neutral pane-session event vocabulary and its exhaustive
// translation into DanTerm messages.
import Foundation
import Testing

@testable import DanTermCore

struct TerminalBackendBoundaryTests {
    @Test("session events translate to the complete pane-scoped Msg vocabulary")
    func sessionEventsTranslateToMessages() {
        // Intent: every terminal-session event translates to the matching pane-scoped Msg.
        // Why it exists: the closed event enum is the contract future backends implement;
        //   a missing or misrouted case would silently change product behavior.
        // Scenario: spec-first adapter contract covering metadata, alerts, search, focus,
        //   and process-close events from one pane.
        let paneId = PaneId(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let sessionId = SessionId(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        assertSessionMessage(.report(.title("vim")), sessionId: sessionId, paneId: paneId) {
            if case .sessionReport(let id, .title(let title)) = $0 {
                return id == sessionId && title == "vim"
            }
            return false
        }
        assertSessionMessage(.report(.cwd("/tmp")), sessionId: sessionId, paneId: paneId) {
            if case .sessionReport(let id, .cwd(let cwd)) = $0 {
                return id == sessionId && cwd == "/tmp"
            }
            return false
        }
        assertSessionMessage(.report(.cwd(nil)), sessionId: sessionId, paneId: paneId) {
            if case .sessionReport(let id, .cwd(let cwd)) = $0 {
                return id == sessionId && cwd == nil
            }
            return false
        }
        assertSessionMessage(.bell, sessionId: sessionId, paneId: paneId) {
            if case .sessionBell(let id) = $0 { return id == sessionId }
            return false
        }
        assertSessionMessage(.report(.commandStarted("echo ok")), sessionId: sessionId, paneId: paneId) {
            if case .sessionReport(let id, let report) = $0 {
                return id == sessionId && report == .commandStarted("echo ok")
            }
            return false
        }
        assertSessionMessage(.report(.commandEnded(exitStatus: 7)), sessionId: sessionId, paneId: paneId) {
            if case .sessionReport(let id, let report) = $0 {
                return id == sessionId && report == .commandEnded(exitStatus: 7)
            }
            return false
        }
        assertSessionMessage(
            .report(.connectionDeclared(.remote(identity: nil))),
            sessionId: sessionId,
            paneId: paneId
        ) {
            if case .sessionReport(let id, let report) = $0 {
                return id == sessionId && report == .connectionDeclared(.remote(identity: nil))
            }
            return false
        }
        assertSessionMessage(.report(.connectionDeclared(.remote(identity:
            RemoteSession(user: "dan", host: "caja")
        ))), sessionId: sessionId, paneId: paneId) {
            if case .sessionReport(let id, let report) = $0 {
                return id == sessionId
                    && report == .connectionDeclared(.remote(identity:
                        RemoteSession(user: "dan", host: "caja")
                    ))
            }
            return false
        }
        assertSessionMessage(.desktopNotification(title: "Build", body: "Done"), sessionId: sessionId, paneId: paneId) {
            if case .sessionNotification(let id, let title, let body) = $0 {
                return id == sessionId && title == "Build" && body == "Done"
            }
            return false
        }
        assertSessionMessage(.report(.progress(.pause(percent: 42))), sessionId: sessionId, paneId: paneId) {
            if case .sessionReport(let id, .progress(let state)) = $0 {
                return id == sessionId && state == .pause(percent: 42)
            }
            return false
        }
        assertSessionMessage(.searchStarted("needle"), paneId: paneId) {
            if case .searchStarted(let id, let needle) = $0 { return id == paneId && needle == "needle" }
            return false
        }
        assertSessionMessage(.searchTotal(7), paneId: paneId) {
            if case .searchTotalReported(let id, let total) = $0 { return id == paneId && total == 7 }
            return false
        }
        assertSessionMessage(.searchSelected(nil), paneId: paneId) {
            if case .searchSelectionReported(let id, let selected) = $0 { return id == paneId && selected == nil }
            return false
        }
        assertSessionMessage(.clickedToFocus, paneId: paneId) {
            if case .paneBecameFirstResponder(let id) = $0 { return id == paneId }
            return false
        }
        assertSessionMessage(.processStarted, sessionId: sessionId, paneId: paneId) {
            if case .sessionProcessStarted(let id) = $0 { return id == sessionId }
            return false
        }
        assertSessionMessage(.processExited, sessionId: sessionId, paneId: paneId) {
            if case .sessionProcessExited(let id) = $0 { return id == sessionId }
            return false
        }
        assertSessionMessage(.processLaunchFailed, sessionId: sessionId, paneId: paneId) {
            if case .sessionCreationFailed(let id) = $0 { return id == sessionId }
            return false
        }
        assertSessionMessage(.closeRequested, sessionId: sessionId, paneId: paneId) {
            if case .sessionEnded(let id) = $0 { return id == sessionId }
            return false
        }
    }

    @Test("lifecycle reports cross the boundary as one message")
    func lifecycleReportsCrossBoundaryAsOneMessage() throws {
        let rawPaneId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let paneId = PaneId(rawValue: rawPaneId)
        let sessionId = SessionId()
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))

        assertSessionMessage(.report(.integrationReady), sessionId: sessionId, paneId: paneId) {
            if case .sessionReport(let id, let report) = $0 {
                return id == sessionId && report == .integrationReady
            }
            return false
        }
        assertSessionMessage(.report(
            .agentActivityChanged(session: agent, activity: .waiting)
        ), sessionId: sessionId, paneId: paneId) {
            if case .sessionReport(let id, let report) = $0 {
                return id == sessionId
                    && report == .agentActivityChanged(session: agent, activity: .waiting)
            }
            return false
        }
        assertSessionMessage(.report(.connectionDeclared(.local)), sessionId: sessionId, paneId: paneId) {
            if case .sessionReport(let id, let report) = $0 {
                return id == sessionId && report == .connectionDeclared(.local)
            }
            return false
        }
        assertSessionMessage(.report(.agentAttached(agent)), sessionId: sessionId, paneId: paneId) {
            if case .sessionReport(let id, let report) = $0 {
                return id == sessionId && report == .agentAttached(agent)
            }
            return false
        }
        assertSessionMessage(.report(.agentDetached(agent)), sessionId: sessionId, paneId: paneId) {
            if case .sessionReport(let id, let report) = $0 {
                return id == sessionId && report == .agentDetached(agent)
            }
            return false
        }
    }

}

private func assertSessionMessage(
    _ event: TerminalSessionEvent,
    sessionId: SessionId = SessionId(),
    paneId: PaneId,
    matches: (Msg) -> Bool
) {
    let messages = terminalMessages(
        for: event,
        sessionId: sessionId,
        paneId: paneId
    )
    #expect(messages.count == 1)
    #expect(messages.first.map(matches) == true)
}
