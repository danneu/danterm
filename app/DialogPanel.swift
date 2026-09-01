// The window behavior DanTerm's hand-rolled dialog panels share: the utility
// chrome, the centering over the app window, and the resize that fits the panel
// to its content. The panels' content -- what they draw and what they answer --
// stays in each subclass; nothing about a confirmation or a notice belongs here.
import Cocoa

/// The width a dialog gives its text column, and the width it states unless its
/// buttons need more. Every heading, sentence, and list wraps inside it, and the
/// window's width is it plus padding.
let dialogTextColumnWidth: CGFloat = 460

/// The inset between a dialog's content and its column, on every side.
let dialogPanelPadding: CGFloat = 20

/// The common surface behind `ConfirmationPanel` and `NoticePanel`, so the rule
/// that a dialog resize holds its top edge is stated once, next to the
/// precondition that makes one layout pass enough.
///
/// That precondition binds every subclass: the content must state the width it
/// wraps to before layout runs. A subclass whose content reports a width back
/// upward has no fixed point for `sizeToContent()` to find, and a single pass
/// would stop mid-negotiation. So the precondition is not left to each subclass
/// to remember -- a subclass hands its column over with `statesWidth`, and
/// `sizeToContent()` settles the width itself before it measures anything.
class DialogPanel: NSPanel {
    /// The one constraint that states the content width, plus everything that
    /// has to be told the number before the layout runs. Nil until a subclass
    /// registers, which every DanTerm dialog does in its `buildUI`.
    private var statedWidth: StatedWidth?

    /// What `sizeToContent()` needs to settle a dialog's width in one pass: the
    /// constraint that carries it, the floor it starts from, the labels that
    /// wrap inside it, and the button row that can push it wider.
    private struct StatedWidth {
        let constraint: NSLayoutConstraint
        let base: CGFloat
        let wrapping: [NSTextField]
        let actionRow: DialogActionRow
    }

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

    /// Registers the width a subclass's content is laid out at. `constraint`
    /// must be the column's own width constraint: it is assigned, not solved,
    /// so nothing below it can report a width back up. Every label in
    /// `wrapping` is told the same width, which is what makes a long line grow
    /// the panel's height instead of its width.
    func statesWidth(
        _ constraint: NSLayoutConstraint,
        base: CGFloat = dialogTextColumnWidth,
        wrapping: [NSTextField],
        actionRow: DialogActionRow
    ) {
        for label in wrapping {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
        }
        statedWidth = StatedWidth(
            constraint: constraint, base: base, wrapping: wrapping, actionRow: actionRow)
    }

    /// Takes the settled width for a subclass that lays something out at a width
    /// derived from it -- the confirmation panel's command list, which sits
    /// inside a scroller's channel. The wrapping labels are already handled.
    func contentWidthDidChange(to width: CGFloat) {}

    /// Settles the content width and applies it, so nothing below the column
    /// negotiates one. `sizeToContent()` calls it before it measures; a
    /// subclass that must build content at the width -- the confirmation
    /// panel's command items, which are laid out at a width they are told --
    /// calls it first and reads the number back from what it registered.
    ///
    /// The width is derived from the text
    /// column and the button row -- a button never wraps, so asking the row how
    /// wide it must be closes no loop -- and then held inside what the display
    /// can show. The bound is a computed minimum rather than a constraint the
    /// solver has to break, because a bound AppKit breaks for us is not a bound.
    func settleWidth() {
        guard let stated = statedWidth else { return }
        let onScreen = (screen ?? NSScreen.main)?.visibleFrame.width ?? stated.base
        let widest = max(stated.base, onScreen - 2 * dialogPanelPadding)
        let width = min(max(stated.base, stated.actionRow.requiredWidth), widest)
        stated.constraint.constant = width
        for label in stated.wrapping {
            label.preferredMaxLayoutWidth = width
        }
        contentWidthDidChange(to: width)
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
        settleWidth()
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
