// The window behavior DanTerm's hand-rolled dialog panels share: the utility
// chrome, the centering over the app window, and the resize that fits the panel
// to its content. The panels' content -- what they draw and what they answer --
// stays in each subclass; nothing about a confirmation or a notice belongs here.
import Cocoa

/// The common surface behind `ConfirmationPanel` and `NoticePanel`, so the rule
/// that a dialog resize holds its top edge is stated once, next to the
/// precondition that makes one layout pass enough.
///
/// That precondition binds every subclass: the content must state the width it
/// wraps to before layout runs. A subclass whose content reports a width back
/// upward has no fixed point for `sizeToContent()` to find, and a single pass
/// would stop mid-negotiation.
class DialogPanel: NSPanel {
    init() {
        // A placeholder rect. The panel's real size comes from its content, so
        // no dimension is stated here.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        // A native alert has no title bar text; the heading in the content is
        // the whole title, and repeating it above would say it twice.
        title = ""
        isReleasedWhenClosed = false
        level = .floating
        isExcludedFromWindowsMenu = true  // keep out of the Window menu's auto window list
        hidesOnDeactivate = false
    }

    /// Positions the panel centered over the main app window when there is one.
    func center(on window: NSWindow?) {
        guard let window else {
            center()
            return
        }
        setFrameOrigin(NSPoint(
            x: window.frame.midX - frame.width / 2,
            y: window.frame.midY - frame.height / 2
        ))
    }

    /// Resizes the panel to fit its content while holding the title bar still.
    /// A refresh that grows the copy must not walk the panel up the screen or
    /// out from under the pointer, so the top edge is the fixed point.
    ///
    /// One measurement, then one placement. The first pass is exact because
    /// every wrapping label already knows the width it wraps to, so the fitting
    /// size cannot change once the panel is resized to it; the second pass only
    /// settles the subviews into the new frame, so the caller is left owing no
    /// layout.
    func sizeToContent() {
        guard let contentView else { return }
        let top = frame.maxY
        contentView.layoutSubtreeIfNeeded()
        let wanted = frameRect(forContentRect: NSRect(origin: .zero, size: contentView.fittingSize))
        setFrame(
            NSRect(
                x: frame.minX, y: top - wanted.height,
                width: wanted.width, height: wanted.height
            ),
            display: true
        )
        contentView.layoutSubtreeIfNeeded()
    }
}
