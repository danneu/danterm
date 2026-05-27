// Transparent overlay that shows drop zone preview during pane drag operations.
// Always returns nil from hitTest so it never intercepts mouse events.

import Cocoa

class PaneDragOverlayView: NSView {
    private var highlightRect: NSRect?
    private var intent: PaneDropIntent?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func update(rect: NSRect, intent: PaneDropIntent) {
        self.highlightRect = rect
        self.intent = intent
        // Invalidate the whole view because the highlight moves between panes, so the
        // previous rounded rect must be erased too. The draw itself is cheap.
        needsDisplay = true
    }

    func clear() {
        highlightRect = nil
        intent = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = highlightRect, let intent = intent else { return }

        let color: NSColor
        if intent == .swap {
            NSColor.systemGreen.withAlphaComponent(0.2).setFill()
            color = NSColor.systemGreen.withAlphaComponent(0.5)
        } else {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            color = NSColor.controlAccentColor.withAlphaComponent(0.5)
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.fill()

        color.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    // Transparent to mouse events — never intercept clicks or drags.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
