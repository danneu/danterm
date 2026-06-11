// Minimal test-only symbols needed to compile SidebarView, PaneWrapperView,
// TodoPopoverView, and TabTodoPopoverView in the UI harness.
import Cocoa

final class AppRuntime {
    var model: AppModel
    var viewLocalState = ViewLocalState()
    var sentMessages: [Msg] = []
    var todoPopover: NSPopover?
    var tabTodoPopover: NSPopover?
    var onSend: ((Msg) -> Void)?
    var focusedPaneSurfaces: [PaneId] = []

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
}

class TerminalView: NSView {
    weak var paneWrapper: PaneWrapperView?
    var hasSelection = false
    var performedActions: [String] = []

    @objc func copySelection(_ sender: Any?) {
        performedActions.append("copySelection")
    }

    @objc func pasteClipboard(_ sender: Any?) {
        performedActions.append("pasteClipboard")
    }
}

class ScrollableTerminalView: NSView {
    init(terminalView: TerminalView) {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}
