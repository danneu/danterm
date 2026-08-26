// The one button type used in a pane toolbar, and the sole owner of the
// affordance every one of those buttons owes the user: a pointing-hand cursor
// over the toolbar's open-hand drag area, and content that lifts to full
// strength while the pointer is inside it. Nothing about a particular button --
// glyph, tooltip, layout -- belongs here; that is each call site's business.
import Cocoa

/// Base class for every button in a pane toolbar. Subclass it (rather than
/// `NSButton`) so a new toolbar button cannot ship without hover feedback and a
/// click cursor: the drag handle spans the whole toolbar with an open-hand
/// cursor, so a button that adds no cursor rect of its own reads as part of the
/// grab area instead of as a control.
class PaneToolbarButton: NSButton {
    /// Resting strength for toolbar content, matching the fade AppKit applies
    /// to `labelColor` for `secondaryLabelColor`. Hover paints full strength.
    private static let restingAlpha: CGFloat = 0.55

    private var trackingArea: NSTrackingArea?
    /// True while the pointer is inside this button in the key window.
    private(set) var isHovered = false

    // Paints the resting tint from the start, so no call site has to remember
    // the color a toolbar button rests at.
    override init(frame: NSRect) {
        super.init(frame: frame)
        applyToolbarTint()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isEnabled: Bool {
        didSet {
            applyToolbarTint()
            window?.invalidateCursorRects(for: self)
        }
    }

    /// The color to paint content whose full-strength color is `color`. Hover is
    /// the toolbar's one statement of "this is clickable", so it is a step in
    /// strength rather than a change of hue: a neutral glyph and a colored TODO
    /// count both drop their resting fade on the same event.
    final func toolbarTint(_ color: NSColor) -> NSColor {
        isHovered && isEnabled ? color : color.withAlphaComponent(Self.restingAlpha)
    }

    /// Paints this button's content for the current hover and enabled state.
    /// Override it when a subclass tints its own subviews instead of using
    /// `contentTintColor`, and route every color through `toolbarTint` so the
    /// whole toolbar lifts by the same amount.
    func applyToolbarTint() {
        contentTintColor = toolbarTint(.labelColor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        applyToolbarTint()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        applyToolbarTint()
    }
}
