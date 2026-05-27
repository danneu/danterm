// Minimal test-only symbols needed to compile SidebarView in the UI harness.
import Cocoa

let paneDragType = NSPasteboard.PasteboardType("com.danterm.pane")

final class AppRuntime {
    var model: AppModel
    var viewLocalState = ViewLocalState()
    var sentMessages: [Msg] = []

    init(model: AppModel = AppModel(groups: [])) {
        self.model = model
    }

    func send(_ msg: Msg) {
        sentMessages.append(msg)
    }
}

class TerminalView: NSView {}

class PaneWrapperView: NSView {
    init(paneId: PaneId, terminalView: TerminalView, isZoomed: Bool, hasSplits: Bool, runtime: AppRuntime?) {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}
