// Pins the backend-neutral terminal event vocabulary, its exhaustive translation
// into DanTerm messages, and development backend selection.
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
        assertSessionMessage(.commandStarted("echo ok"), paneId: paneId) {
            if case .commandStarted(let id, let command) = $0 {
                return id == paneId && command == "echo ok"
            }
            return false
        }
        assertSessionMessage(.commandEnded, paneId: paneId) {
            if case .commandEnded(let id) = $0 { return id == paneId }
            return false
        }
        assertSessionMessage(.remoteStarted, paneId: paneId) {
            if case .remoteSessionStarted(let id) = $0 { return id == paneId }
            return false
        }
        assertSessionMessage(.remoteHost(user: "dan", host: "caja"), paneId: paneId) {
            if case .remoteSessionReported(let id, let session) = $0 {
                return id == paneId && session == RemoteSession(user: "dan", host: "caja")
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

    @Test("backend events translate to the complete process-scoped Msg vocabulary")
    func backendEventsTranslateToMessages() {
        // Intent: backend reload, preference-change, and quit events translate to
        //   the existing process-scoped messages.
        // Why it exists: keeps backend callbacks out of AppRuntime while preserving
        //   the exact model/update entry points the Ghostty adapter used directly.
        // Scenario: spec-first app-level callback contract.
        let prefs = GhosttyPrefs(theme: "Dracula", fontSize: "14")

        if case .ghosttyConfigReloaded = terminalMessage(for: TerminalBackendEvent.configReloaded) {
        } else {
            Issue.record("configReloaded translated to the wrong Msg")
        }
        if case .ghosttyPrefsRefreshed(let translated) = terminalMessage(
            for: TerminalBackendEvent.configChanged(prefs: prefs, scrollbarEnabled: false)
        ) {
            #expect(translated == prefs)
        } else {
            Issue.record("configChanged translated to the wrong Msg")
        }
        if case .requestQuit = terminalMessage(for: TerminalBackendEvent.quitRequested) {
        } else {
            Issue.record("quitRequested translated to the wrong Msg")
        }
    }

    @Test("backend selection defaults to Swift and accepts explicit Ghostty")
    func defaultAndGhosttySelection() throws {
        // Intent: an unset or empty DANTERM_TERMINAL_BACKEND selects the Swift
        //   engine, while Ghostty remains reachable only by explicit opt-in.
        // Why it exists: pins the Milestone 9 daily-use flip (2026-07-31); a
        //   silent regression back to Ghostty-by-default would invalidate the
        //   sustained-daily-use evidence the replacement gate requires.
        #expect(try resolveTerminalBackend(nil) == .swift)
        #expect(try resolveTerminalBackend("") == .swift)
        #expect(try resolveTerminalBackend("ghostty") == .ghostty)
    }

    @Test("backend selection exposes Swift without silently falling back")
    func swiftSelection() throws {
        #expect(try resolveTerminalBackend("swift") == .swift)
    }

    @Test("backend selection rejects unknown values")
    func unknownSelection() {
        #expect(throws: TerminalBackendSelectionError.unsupported("other")) {
            try resolveTerminalBackend("other")
        }
    }
}

private func assertSessionMessage(
    _ event: TerminalSessionEvent,
    paneId: PaneId,
    matches: (Msg) -> Bool
) {
    #expect(matches(terminalMessage(for: event, paneId: paneId)))
}
