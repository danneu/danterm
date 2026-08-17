// Minimal test-only symbols needed to compile the real app/ views in the UI
// harness. See the app-file section of test-ui.sh's compile list.
import Cocoa
import DanTermProtocol

final class AppRuntime {
    // The harness builds with strict concurrency; the shim is nonisolated but the
    // UI tests always construct it on the main thread.
    let schedulingLifecycle = MainActor.assumeIsolated { AppRuntimeSchedulingLifecycle() }
    var model: AppModel
    private(set) var paneHosts: [PaneId: PaneHost] = [:]
    var renderingAvailable = true
    weak var window: NSWindow?
    var sentMessages: [Msg] = []
    var todoPopover: NSPopover?
    var onSend: ((Msg) -> Void)?
    var focusedPaneSessions: [PaneId] = []
    var themeBrowserToggles = 0

    init(model: AppModel = AppModel(groups: [])) {
        self.model = model
    }

    func send(_ msg: Msg) {
        sentMessages.append(msg)
        onSend?(msg)
    }

    // Pane drag API that ToolbarDragHandleView compiles against. The harness
    // never starts a real drag session, so these are inert.
    func startPaneDrag(paneId: PaneId) {}
    func updatePaneDrag(screenPoint: NSPoint) {}
    func endPaneDrag() {}
    func currentPaneDrop() -> (source: PaneId, target: PaneId, intent: PaneDropIntent)? { nil }

    func focusPaneSession(_ paneId: PaneId) {
        focusedPaneSessions.append(paneId)
    }

    /// Mirrors production's install path so UI tests never put a session into the
    /// runtime behind it.
    @MainActor
    func installTerminalSession(_ session: any TerminalSession, paneId: PaneId) {
        paneHosts[paneId] = PaneHost(paneId: paneId, session: session, runtime: self)
    }

    /// Mirrors production's teardown path: a pane leaves the table as a whole record, and
    /// the record destroys what it owns.
    @MainActor
    func tearDownSession(_ paneId: PaneId) {
        paneHosts.removeValue(forKey: paneId)?.tearDown(scheduling: schedulingLifecycle)
    }

    @MainActor
    func paneHost(for paneId: PaneId) -> PaneHost? {
        paneHosts[paneId]
    }

    @MainActor
    func paneSession(for paneId: PaneId) -> (any TerminalSession)? {
        paneHosts[paneId]?.session
    }

    /// Resolves a persistent wrapper through the test host index.
    @MainActor
    func findPaneWrapper(for paneId: PaneId) -> PaneWrapperView? {
        paneHost(for: paneId)?.wrapper
    }

    /// ThemeBrowserView close-button hook. Production toggles the panel in and
    /// out of the content area; the harness only counts invocations.
    func toggleThemeBrowser() { themeBrowserToggles += 1 }

    // PreferencesPanel's "Config file" row. Both reach the filesystem in
    // production, so the harness keeps them inert.
    func openDanTermConfig() {}
    func reloadDanTermConfig() {}
}

final class AppDelegate {
    var runtime: AppRuntime!
    var workspaceLifecycleObserver: WorkspaceLifecycleObserver?
}

class TerminalView: NSView, TerminalSession {
    weak var paneWrapper: PaneWrapperView?
    var hasSelection = false
    var performedActions: [String] = []
    var hostView: NSView { self }
    var state = TerminalSessionState(
        scrollbarEnabled: true, cellHeight: 0, scrollPosition: nil,
        background: NSColor.black.cgColor)
    weak var stateObserver: (any TerminalSessionStateObserver)?
    var onEvent: ((TerminalSessionEvent) -> Void)?
    var onPrimaryHistoryMutation: (() -> Void)?
    var renderingAvailability: [Bool] = []
    var visibility: [Bool] = []
    var revealCount = 0

    /// Drives the session-state channel the way a real theme swap does, so view
    /// chrome that reads state can be tested without the terminal engine.
    func emitState(_ newState: TerminalSessionState) {
        state = newState
        stateObserver?.terminalSessionStateDidChange(newState)
    }

    func copySelection() {
        performedActions.append("copySelection")
    }

    func pasteClipboard() {
        performedActions.append("pasteClipboard")
    }

    func sendText(_ text: String) {}
    func sendInputText(_ text: String) {}
    func sendInputKey(_ key: KeyName, modifiers: KeyMods) {}
    func sendInputWheel(_ direction: InputWheelDirection, column: Int, row: Int) {}
    func setFocused(_ focused: Bool) {}
    func setVisible(_ visible: Bool) {
        if visible, visibility.last == false {
            revealCount += 1
        }
        visibility.append(visible)
    }
    func setRenderingAvailable(_ available: Bool) {
        renderingAvailability.append(available)
    }
    func refreshBackingProperties() {}
    func applyTheme(_ themeName: String) {}
    func clearTheme() {}
    func setFontSize(_ size: Double) {}
    func setFontFamily(_ family: String?) {}
    func setCopyOnSelect(_ enabled: Bool) {}
    func startSearch() {}
    func setSearchNeedle(_ needle: String) {}
    func navigateSearch(_ direction: SearchDirection) {}
    func endSearch() {}
    func readViewportText() -> String? { nil }
    func readRowStructure() -> [TerminalSessionRowStructure]? { nil }
    func readFullHistoryText() -> String? { nil }
    func readPrimaryHistoryText() -> String? { nil }
    func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String? { nil }
    func primaryHistoryTailReader() -> CheckpointScrollbackRead? { nil }
    func scroll(toRow row: Int) {}
    func requestClose() {}
    func fenceForApplicationExit() {}
    func tearDown() {}
}
