// Backend-neutral terminal events and their translation into product messages.
// These value-only contracts let the terminal adapter report product behavior
// without importing AppKit.

/// Product-level events one pane session may emit to DanTerm's model loop.
enum TerminalSessionEvent: Equatable {
    case bell
    case report(SessionReport)
    case desktopNotification(title: String, body: String)
    case searchStarted(String)
    case searchTotal(Int?)
    case searchSelected(Int?)
    case clickedToFocus
    case processStarted
    case processExited
    case processLaunchFailed
    case closeRequested
}

/// Translates the closed session-event vocabulary into model messages.
func terminalMessages(
    for event: TerminalSessionEvent,
    sessionId: SessionId,
    paneId: PaneId
) -> [Msg] {
    switch event {
    case .bell:
        return [.sessionBell(sessionId: sessionId)]
    case .report(let report):
        return [.sessionReport(sessionId: sessionId, report: report)]
    case .desktopNotification(let title, let body):
        return [.sessionNotification(sessionId: sessionId, title: title, body: body)]
    case .searchStarted(let needle):
        return [.searchStarted(paneId: paneId, needle: needle)]
    case .searchTotal(let total):
        return [.searchTotalReported(paneId: paneId, total: total)]
    case .searchSelected(let selected):
        return [.searchSelectionReported(paneId: paneId, selected: selected)]
    case .clickedToFocus:
        return [.paneBecameFirstResponder(paneId: paneId)]
    case .processStarted:
        return [.sessionProcessStarted(sessionId: sessionId)]
    case .processExited:
        return [.sessionProcessExited(sessionId: sessionId)]
    case .processLaunchFailed:
        return [.sessionCreationFailed(sessionId: sessionId)]
    case .closeRequested:
        return [.sessionEnded(sessionId: sessionId)]
    }
}
