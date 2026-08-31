// Model-driven pane divider interaction and presentation. This view reports
// gestures; it never owns or mutates the split ratio or pane frames.
import Cocoa

/// Gives each model split one stable gesture and accessibility surface.
final class PaneDividerView: NSView {
    private static let hitThickness: CGFloat = 7

    let splitId: SplitId
    private(set) var placement: PaneDividerPlacement?
    var onRatioChanged: ((SplitId, SplitRatio) -> Void)?
    private var dragOffset: CGFloat?

    init(splitId: SplitId) {
        self.splitId = splitId
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Applies the model-produced divider placement without deriving geometry from views.
    func apply(placement: PaneDividerPlacement, in containerBounds: NSRect) {
        let visualFrame = NSRect(placement.frame)
        let hitFrame: NSRect
        switch placement.direction {
        case .horizontal:
            hitFrame = NSRect(
                x: visualFrame.midX - Self.hitThickness / 2,
                y: visualFrame.minY,
                width: Self.hitThickness,
                height: visualFrame.height
            ).intersection(containerBounds)
        case .vertical:
            hitFrame = NSRect(
                x: visualFrame.minX,
                y: visualFrame.midY - Self.hitThickness / 2,
                width: visualFrame.width,
                height: Self.hitThickness
            ).intersection(containerBounds)
        }
        guard self.placement != placement || frame != hitFrame else { return }

        self.placement = placement
        setAccessibilityOrientation(placement.direction == .horizontal ? .vertical : .horizontal)
        setAccessibilityValue(NSNumber(value: Double(placement.ratio.value)))
        if frame != hitFrame {
            frame = hitFrame
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let placement else { return }
        NSColor.separatorColor.setFill()
        let thickness = PaneLayoutMetrics.standard.dividerThickness
        let separator: NSRect
        switch placement.direction {
        case .horizontal:
            separator = NSRect(
                x: bounds.midX - thickness / 2,
                y: bounds.minY,
                width: thickness,
                height: bounds.height
            )
        case .vertical:
            separator = NSRect(
                x: bounds.minX,
                y: bounds.midY - thickness / 2,
                width: bounds.width,
                height: thickness
            )
        }
        separator.fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let placement else { return }
        addCursorRect(
            bounds,
            cursor: placement.direction == .horizontal ? .resizeLeftRight : .resizeUpDown
        )
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            resetToEvenSplit()
        }
        guard let placement, let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        dragOffset = switch placement.direction {
        case .horizontal: point.x - placement.frame.minX
        case .vertical: point.y - placement.frame.maxY
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let placement, let superview, let dragOffset else { return }
        var point = superview.convert(event.locationInWindow, from: nil)
        switch placement.direction {
        case .horizontal: point.x -= dragOffset
        case .vertical: point.y -= dragOffset
        }
        drag(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
    }

    /// Reports one ratio for one drag event and leaves movement to the model round trip.
    func drag(to position: NSPoint) {
        guard let placement else { return }
        let axisPosition = placement.direction == .horizontal ? position.x : position.y
        let ratio = paneSplitRatio(
            forDividerPosition: axisPosition,
            in: placement.splitBounds,
            direction: placement.direction
        )
        onRatioChanged?(splitId, ratio)
    }

    /// Reports the existing double-click behavior without changing presentation directly.
    func resetToEvenSplit() {
        onRatioChanged?(splitId, 0.5)
    }
}
