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

        assertSessionMessage(.titleChanged("vim"), paneId: paneId) {
            if case .sessionTitle(let id, let title) = $0 { return id == paneId && title == "vim" }
            return false
        }
        assertSessionMessage(.cwdChanged("/tmp"), paneId: paneId) {
            if case .sessionCwd(let id, let cwd) = $0 { return id == paneId && cwd == "/tmp" }
            return false
        }
        assertSessionMessage(.cwdChanged(nil), paneId: paneId) {
            if case .sessionCwd(let id, let cwd) = $0 { return id == paneId && cwd == nil }
            return false
        }
        assertSessionMessage(.bell, paneId: paneId) {
            if case .sessionBell(let id) = $0 { return id == paneId }
            return false
        }
        assertSessionMessage(.paneLifecycleChanged(transition(for: .commandStarted("echo ok"))), paneId: paneId) {
            if case .paneLifecycleChanged(let id, let event) = $0 {
                return id == paneId && event == .commandStarted("echo ok")
            }
            return false
        }
        assertSessionMessage(.paneLifecycleChanged(transition(for: .commandEnded(exitStatus: 7), after: [.commandStarted("echo ok")])), paneId: paneId) {
            if case .paneLifecycleChanged(let id, let event) = $0 {
                return id == paneId && event == .commandEnded(exitStatus: 7)
            }
            return false
        }
        assertSessionMessage(.paneLifecycleChanged(transition(for: .remoteDetected)), paneId: paneId) {
            if case .paneLifecycleChanged(let id, let event) = $0 {
                return id == paneId && event == .remoteDetected
            }
            return false
        }
        assertSessionMessage(.paneLifecycleChanged(transition(for: .remoteIdentityReported(RemoteSession(user: "dan", host: "caja")))), paneId: paneId) {
            if case .paneLifecycleChanged(let id, let event) = $0 {
                return id == paneId
                    && event == .remoteIdentityReported(RemoteSession(user: "dan", host: "caja"))
            }
            return false
        }
        assertSessionMessage(.desktopNotification(title: "Build", body: "Done"), paneId: paneId) {
            if case .desktopNotification(let id, let title, let body) = $0 {
                return id == paneId && title == "Build" && body == "Done"
            }
            return false
        }
        assertSessionMessage(.progress(.pause(percent: 42)), paneId: paneId) {
            if case .sessionProgress(let id, let state) = $0 {
                return id == paneId && state == .pause(percent: 42)
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
        assertSessionMessage(.becameFirstResponder, paneId: paneId) {
            if case .paneBecameFirstResponder(let id) = $0 { return id == paneId }
            return false
        }
        assertSessionMessage(.closeRequested, paneId: paneId) {
            if case .sessionClosed(let id) = $0 { return id == paneId }
            return false
        }
    }

    @Test("changed lifecycle transitions cross the boundary as one message")
    func changedLifecycleTransitionsCrossBoundaryAsOneMessage() throws {
        let rawPaneId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let paneId = PaneId(rawValue: rawPaneId)
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))

        assertSessionMessage(.paneLifecycleChanged(transition(for: .integrationReady)), paneId: paneId) {
            if case .paneLifecycleChanged(let id, let event) = $0 {
                return id == paneId && event == .integrationReady
            }
            return false
        }
        assertSessionMessage(.paneLifecycleChanged(transition(
            for: .agentActivityChanged(session: agent, activity: .waiting),
            after: [.agentAttached(agent)]
        )), paneId: paneId) {
            if case .paneLifecycleChanged(let id, let event) = $0 {
                return id == paneId
                    && event == .agentActivityChanged(session: agent, activity: .waiting)
            }
            return false
        }
        #expect(terminalMessages(
            for: .paneLifecycleChanged(transition(
                for: .agentActivityChanged(session: agent, activity: .waiting),
                after: [.agentAttached(agent), .agentActivityChanged(session: agent, activity: .waiting)]
            )),
            paneId: paneId
        ).isEmpty)
        #expect(terminalMessages(
            for: .paneLifecycleChanged(transition(
                for: .remoteDetected,
                after: [.remoteIdentityReported(RemoteSession(user: "dan", host: "caja"))]
            )),
            paneId: paneId
        ).isEmpty)
        assertSessionMessage(.paneLifecycleChanged(transition(for: .connectionEnded, after: [.remoteDetected])), paneId: paneId) {
            if case .paneLifecycleChanged(let id, let event) = $0 {
                return id == paneId && event == .connectionEnded
            }
            return false
        }
        assertSessionMessage(.paneLifecycleChanged(transition(for: .agentAttached(agent))), paneId: paneId) {
            if case .paneLifecycleChanged(let id, let event) = $0 {
                return id == paneId && event == .agentAttached(agent)
            }
            return false
        }
        assertSessionMessage(.paneLifecycleChanged(transition(for: .agentDetached(agent), after: [.agentAttached(agent)])), paneId: paneId) {
            if case .paneLifecycleChanged(let id, let event) = $0 {
                return id == paneId && event == .agentDetached(agent)
            }
            return false
        }
    }

}

private func assertSessionMessage(
    _ event: TerminalSessionEvent,
    paneId: PaneId,
    matches: (Msg) -> Bool
) {
    let messages = terminalMessages(
        for: event,
        paneId: paneId
    )
    #expect(messages.count == 1)
    #expect(messages.first.map(matches) == true)
}

private func transition(
    for event: PaneLifecycleEvent,
    after preceding: [PaneLifecycleEvent] = []
) -> PaneLifecycleTransition {
    var stream = PaneLifecycleStream()
    for event in preceding {
        _ = stream.apply(event)
    }
    return stream.apply(event)
}
