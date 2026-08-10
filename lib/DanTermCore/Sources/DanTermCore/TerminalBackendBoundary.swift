// Backend-neutral terminal events and their translation into product messages.
// These value-only contracts let the terminal adapter report product behavior
// without importing AppKit.

/// Product-level events one pane session may emit to DanTerm's model loop.
enum TerminalSessionEvent: Equatable {
    case titleChanged(String)
    case cwdChanged(String?)
    case bell
    case paneSemanticsChanged(PaneSemanticTransition)
    case desktopNotification(title: String, body: String)
    case progress(ProgressState?)
    case searchStarted(String)
    case searchTotal(Int?)
    case searchSelected(Int?)
    case becameFirstResponder
    case closeRequested
}

/// Translates the closed session-event vocabulary into the existing pane messages.
func terminalMessages(for event: TerminalSessionEvent, paneId: PaneId) -> [Msg] {
    switch event {
    case .titleChanged(let title):
        return [.sessionTitle(paneId: paneId, title: title)]
    case .cwdChanged(let cwd):
        return [.sessionCwd(paneId: paneId, cwd: cwd)]
    case .bell:
        return [.sessionBell(paneId: paneId)]
    case .paneSemanticsChanged(let transition):
        guard transition.didChange else { return [] }
        switch transition.event {
        case .commandStarted(let command):
            return [.commandStarted(paneId: paneId, command: command)]
        case .commandEnded:
            return [.commandEnded(paneId: paneId)]
        case .remoteDetected:
            return [.remoteSessionStarted(paneId: paneId)]
        case .remoteIdentityReported(let session):
            return [.remoteSessionReported(paneId: paneId, session: session)]
        case .connectionEnded:
            return [.remoteSessionEnded(paneId: paneId)]
        case .agentAttached(let session):
            return [.agentSessionChanged(paneId: paneId, session: session)]
        case .agentDetached:
            return [.agentSessionChanged(paneId: paneId, session: nil)]
        case .integrationReady, .agentActivityChanged, .paneTornDown:
            return []
        }
    case .desktopNotification(let title, let body):
        return [.desktopNotification(paneId: paneId, title: title, body: body)]
    case .progress(let state):
        return [.sessionProgress(paneId: paneId, state: state)]
    case .searchStarted(let needle):
        return [.searchStarted(paneId: paneId, needle: needle)]
    case .searchTotal(let total):
        return [.searchTotalReported(paneId: paneId, total: total)]
    case .searchSelected(let selected):
        return [.searchSelectionReported(paneId: paneId, selected: selected)]
    case .becameFirstResponder:
        return [.paneBecameFirstResponder(paneId: paneId)]
    case .closeRequested:
        return [.sessionClosed(paneId: paneId)]
    }
}
