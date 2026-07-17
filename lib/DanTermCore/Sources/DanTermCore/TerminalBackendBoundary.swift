// Backend-neutral terminal events and backend selection. These value-only contracts
// let adapters report product behavior without importing AppKit or GhosttyKit.

/// Product-level events one pane session may emit to DanTerm's model loop.
enum TerminalSessionEvent: Equatable {
    case titleChanged(String)
    case cwdChanged(String)
    case bell
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

/// Development backends selectable for one DanTerm process.
enum TerminalBackendKind: String, Equatable {
    case ghostty
    case swift
}

/// Explains an invalid development backend value instead of silently falling back.
enum TerminalBackendSelectionError: Error, Equatable {
    case unsupported(String)
}

/// Resolves the launch-only backend selection without reading ambient process state.
func resolveTerminalBackend(_ value: String?) throws -> TerminalBackendKind {
    guard let value, value.isEmpty == false else { return .ghostty }
    guard let backend = TerminalBackendKind(rawValue: value) else {
        throw TerminalBackendSelectionError.unsupported(value)
    }
    return backend
}

/// Translates the closed session-event vocabulary into the existing pane messages.
func terminalMessage(for event: TerminalSessionEvent, paneId: PaneId) -> Msg {
    switch event {
    case .titleChanged(let title):
        return .surfaceTitle(paneId: paneId, title: title)
    case .cwdChanged(let cwd):
        return .surfaceCwd(paneId: paneId, cwd: cwd)
    case .bell:
        return .surfaceBell(paneId: paneId)
    case .desktopNotification(let title, let body):
        return .desktopNotification(paneId: paneId, title: title, body: body)
    case .progress(let state):
        return .surfaceProgress(paneId: paneId, state: state)
    case .searchStarted(let needle):
        return .ghosttyStartSearch(paneId: paneId, needle: needle)
    case .searchTotal(let total):
        return .ghosttySearchTotal(paneId: paneId, total: total)
    case .searchSelected(let selected):
        return .ghosttySearchSelected(paneId: paneId, selected: selected)
    case .becameFirstResponder:
        return .paneBecameFirstResponder(paneId: paneId)
    case .closeRequested:
        return .surfaceClosed(paneId: paneId)
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
