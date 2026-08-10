// Backend-neutral terminal events and their translation into product messages.
// These value-only contracts let the terminal adapter report product behavior
// without importing AppKit.

/// Product-level events one pane session may emit to DanTerm's model loop.
enum TerminalSessionEvent: Equatable {
    case titleChanged(String)
    case cwdChanged(String?)
    case bell
    case paneLifecycleChanged(PaneLifecycleTransition)
    case desktopNotification(title: String, body: String)
    case progress(ProgressState?)
    case searchStarted(String)
    case searchTotal(Int?)
    case searchSelected(Int?)
    case becameFirstResponder
    case closeRequested
}

/// Translates the closed session-event vocabulary into the existing pane messages.
func terminalMessages(
    for event: TerminalSessionEvent,
    paneId: PaneId
) -> [Msg] {
    switch event {
    case .titleChanged(let title):
        return [.sessionTitle(paneId: paneId, title: title)]
    case .cwdChanged(let cwd):
        return [.sessionCwd(paneId: paneId, cwd: cwd)]
    case .bell:
        return [.sessionBell(paneId: paneId)]
    case .paneLifecycleChanged(let transition):
        guard transition.didChange else { return [] }
        return [.paneLifecycleChanged(paneId: paneId, event: transition.event)]
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
