// Minimal test-only symbols needed to compile SidebarView in the UI harness.
import Cocoa

let paneDragType = NSPasteboard.PasteboardType("com.danterm.pane")

final class AppRuntime {
    var model: AppModel
    var viewLocalState = ViewLocalState()

    init(model: AppModel = AppModel(groups: [])) {
        self.model = model
    }

    func send(_ msg: Msg) {}
}
