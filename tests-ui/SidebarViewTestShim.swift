// Minimal test-only symbols needed to compile the real app/ views in the UI
// harness. See the app-file section of test-ui.sh's compile list.
import Cocoa
import DanTermProtocol

final class AppRuntime {
    var model: AppModel
    var viewLocalState = ViewLocalState()
    var sentMessages: [Msg] = []
    var todoPopover: NSPopover?
    var tabTodoPopover: NSPopover?
    var onSend: ((Msg) -> Void)?
    var focusedPaneSurfaces: [PaneId] = []
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

    func focusPaneSurface(_ paneId: PaneId) {
        focusedPaneSurfaces.append(paneId)
    }

    /// ThemeBrowserView close-button hook. Production toggles the panel in and
    /// out of the content area; the harness only counts invocations.
    func toggleThemeBrowser() { themeBrowserToggles += 1 }
}

class TerminalView: NSView, TerminalSession {
    weak var paneWrapper: PaneWrapperView?
    var hasSelection = false
    var performedActions: [String] = []
    var hostView: NSView { self }
    var state = TerminalSessionState(scrollbarEnabled: true, cellHeight: 0, scrollPosition: nil)
    weak var stateObserver: (any TerminalSessionStateObserver)?
    var onEvent: ((TerminalSessionEvent) -> Void)?
    var onPrimaryHistoryMutation: ((String) -> Void)?

    func copySelection() {
        performedActions.append("copySelection")
    }

    func pasteClipboard() {
        performedActions.append("pasteClipboard")
    }

    func sendText(_ text: String) {}
    func sendInputText(_ text: String) {}
    func sendInputKey(_ key: KeyName, modifiers: KeyMods) {}
    func setFocused(_ focused: Bool) {}
    func setVisible(_ visible: Bool) {}
    func setDisplayID(_ displayID: UInt32) {}
    func setScrollbarEnabled(_ enabled: Bool) {}
    func refreshBackingProperties() {}
    func applyTheme(_ themeName: String) {}
    func clearTheme() {}
    func startSearch() {}
    func setSearchNeedle(_ needle: String) {}
    func navigateSearch(_ direction: SearchDirection) {}
    func endSearch() {}
    func readViewportText() -> String? { nil }
    func readFullHistoryText() -> String? { nil }
    func readPrimaryHistoryText() -> String? { nil }
    func scroll(toRow row: Int) {}
    func requestClose() {}
    func setFocusBorder(_ focused: Bool, hasBell: Bool) {}
    func fenceForApplicationExit() {}
    func tearDown() {}
}

class ScrollableTerminalView: NSView {
    init(terminalSession: any TerminalSession) {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}
