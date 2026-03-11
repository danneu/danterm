// Background layer in WindowChromeView that enables window drag-to-move.
// Returns self for left-mouse-down (unless an interactive subview claims the hit)
// and handles double-click to zoom the window.
import Cocoa

class TitlebarDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
        }
    }

    // Only claim hits for left-mouse-down where no interactive subview (button) would handle it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // Let interactive subviews (buttons) claim the hit first
        for sub in subviews.reversed() {
            if let hit = sub.hitTest(point), hit != self {
                return hit
            }
        }
        return self
    }
}
