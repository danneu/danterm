// Backend-neutral terminal events and their translation into product messages.
// These value-only contracts let the terminal adapter report product behavior
// without importing AppKit.

/// Product-level events one pane session may emit to DanTerm's model loop.
enum TerminalSessionEvent: Equatable {
    case titleChanged(String)
    case cwdChanged(String?)
    case bell
    case commandStarted(String)
    case commandEnded
    case remoteStarted
    case remoteHost(user: String, host: String)
    case desktopNotification(title: String, body: String)
    case progress(ProgressState?)
    case searchStarted(String)
    case searchTotal(Int?)
    case searchSelected(Int?)
    case becameFirstResponder
    case closeRequested
}

/// Product-level events the process-wide terminal backend may emit.
enum TerminalBackendEvent: Equatable {
    case configReloaded
    case configChanged(prefs: GhosttyPrefs, scrollbarEnabled: Bool)
    case quitRequested
}

/// Translates the closed session-event vocabulary into the existing pane messages.
func terminalMessage(for event: TerminalSessionEvent, paneId: PaneId) -> Msg {
    switch event {
    case .titleChanged(let title):
        return .sessionTitle(paneId: paneId, title: title)
    case .cwdChanged(let cwd):
        return .sessionCwd(paneId: paneId, cwd: cwd)
    case .bell:
        return .sessionBell(paneId: paneId)
    case .commandStarted(let command):
        return .commandStarted(paneId: paneId, command: command)
    case .commandEnded:
        return .commandEnded(paneId: paneId)
    case .remoteStarted:
        return .remoteSessionStarted(paneId: paneId)
    case let .remoteHost(user, host):
        return .remoteSessionReported(
            paneId: paneId,
            session: RemoteSession(user: user, host: host)
        )
    case .desktopNotification(let title, let body):
        return .desktopNotification(paneId: paneId, title: title, body: body)
    case .progress(let state):
        return .sessionProgress(paneId: paneId, state: state)
    case .searchStarted(let needle):
        return .searchStarted(paneId: paneId, needle: needle)
    case .searchTotal(let total):
        return .searchTotalReported(paneId: paneId, total: total)
    case .searchSelected(let selected):
        return .searchSelectionReported(paneId: paneId, selected: selected)
    case .becameFirstResponder:
        return .paneBecameFirstResponder(paneId: paneId)
    case .closeRequested:
        return .sessionClosed(paneId: paneId)
    }
}

/// Translates process-wide backend events into the existing application messages.
func terminalMessage(for event: TerminalBackendEvent) -> Msg {
    switch event {
    case .configReloaded:
        return .ghosttyConfigReloaded
    case .configChanged(let prefs, _):
        return .ghosttyPrefsRefreshed(prefs)
    case .quitRequested:
        return .requestQuit
    }
}
