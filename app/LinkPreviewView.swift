// Passive URL preview pill shown over a terminal pane during libghostty link hover.
import Cocoa

/// Small value type that keeps link-preview frame math independent of AppKit view state.
enum LinkPreviewSide {
    case left
    case right
}

/// Mirrors Ghostty's browser-style dodge: only the fixed left pill footprint moves the preview right.
func linkPreviewDodgeSide(pointer: NSPoint, leftPillFrame: NSRect) -> LinkPreviewSide {
    leftPillFrame.contains(pointer) ? .right : .left
}

/// Keeps the bottom-edge anchor and width cap testable without constructing an NSView.
func linkPreviewFrame(side: LinkPreviewSide, fittingSize: NSSize, containerWidth: CGFloat) -> NSRect {
    let containerWidth = max(0, containerWidth)
    let width = min(max(0, fittingSize.width), containerWidth)
    let height = max(0, fittingSize.height)
    let x = side == .left ? 0 : max(0, containerWidth - width)
    return NSRect(x: x, y: 0, width: width, height: height)
}

/// Terminal-owned chrome for hovered link destinations, deliberately non-interactive
/// so pointer events continue through to libghostty.
class LinkPreviewView: NSView {
    private static let padding: CGFloat = 5
    private static let cornerRadius: CGFloat = 9

    let label = NSTextField(labelWithString: "")
    private var side: LinkPreviewSide = .left

    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = true

        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.usesSingleLineMode = true
        addSubview(label)

        updateRoundedCorners()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func layout() {
        super.layout()
        layoutLabel()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Display a URL, resetting the pill to its default left-side anchor.
    func show(url: String) {
        label.stringValue = url
        side = .left
        isHidden = false
    }

    /// Hide the preview without removing it from the pane.
    func hide() {
        isHidden = true
    }

    /// Recompute the pill and label frames for the hosting terminal bounds.
    func layoutPill(in bounds: NSRect) {
        guard !isHidden else { return }
        frame = linkPreviewFrame(side: side, fittingSize: pillFittingSize(), containerWidth: bounds.width)
        updateRoundedCorners()
        layoutLabel()
    }

    /// Update the dodge side from the pointer position and relayout in pane bounds.
    func pointerMoved(to point: NSPoint, in bounds: NSRect) {
        guard !isHidden else { return }
        let leftFrame = linkPreviewFrame(side: .left, fittingSize: pillFittingSize(), containerWidth: bounds.width)
        side = linkPreviewDodgeSide(pointer: point, leftPillFrame: leftFrame)
        layoutPill(in: bounds)
    }

    private func pillFittingSize() -> NSSize {
        let font = label.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let labelSize = NSAttributedString(string: label.stringValue, attributes: [.font: font]).size()
        return NSSize(
            width: ceil(labelSize.width) + Self.padding * 2,
            height: ceil(labelSize.height) + Self.padding * 2
        )
    }

    private func layoutLabel() {
        let inset = Self.padding
        label.frame = NSRect(
            x: inset,
            y: inset,
            width: max(0, bounds.width - inset * 2),
            height: max(0, bounds.height - inset * 2)
        )
    }

    private func updateRoundedCorners() {
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.maskedCorners = side == .left ? [.layerMaxXMaxYCorner] : [.layerMinXMaxYCorner]
    }
}
