// The one conversion between the core's `PaneLayoutRect` and AppKit's `NSRect`.
// Every AppKit site that consumes model pane geometry -- the split container,
// the divider strips, the drag coordinator -- shares these two initializers, so
// the mapping from model coordinates to view coordinates is stated once.
import Cocoa

extension NSRect {
    init(_ rect: PaneLayoutRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}

extension PaneLayoutRect {
    init(_ rect: NSRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}
