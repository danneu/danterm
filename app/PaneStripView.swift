// The chip strip a multi-pane tab row shows on its second line.
//
// One view that draws every chip itself, rather than a stack of ChipViews: the
// chips are fixed-size and the row is not, so a stack has no way to fit twelve
// panes into a narrow sidebar and breaks a width constraint instead (which is
// what stretched one chip into a smear). Here the strip is told its width and
// decides what fits, so no pane count can overflow the row.
//
// Only layout and drawing live here. Which panes exist and which one is focused
// is a model fact, decided by `tabPaneChips` in the core.

import AppKit
import ChipArtwork

/// A tab row's pane enumeration, drawn to fit whatever width it is given.
///
/// Shows a contiguous run of chips and, when they do not all fit, a `+N`
/// count of the ones left out. The run always contains the focused pane --
/// the strip exists to answer "which pane am I in", so that chip is the one
/// thing it may never elide.
///
/// Each chip may carry two state dots, one per trailing corner: red at the top
/// for a pane with an unread alert, and at the bottom green for an agent
/// waiting on a prompt or amber for one mid-turn. They are the same ringed dot
/// and differ only in hue and in corner, so a pane that is both alerting and
/// running an agent draws both. Which facts a pane has is decided in the core
/// by `tabPaneChips`, not here.
final class PaneStripView: NSView {
    var chips: [TabPaneChip] = [] {
        didSet {
            guard chips != oldValue else { return }
            needsDisplay = true
        }
    }

    /// What the strip should punch its dot rings out of, or nil for the
    /// appearance's fixed neutral.
    ///
    /// The strip cannot work this out for itself: a selected row is painted by
    /// AppKit in a color that depends on selection *and* emphasis, and neither
    /// reaches the cell through the sidebar projection. `SidebarRowView` is the
    /// one object that knows what it painted, so it pushes the answer down.
    var rowBackground: NSColor? {
        didSet {
            guard rowBackground != oldValue else { return }
            needsDisplay = true
        }
    }

    private let edge = ChipArtwork.paneRowSize
    private let spacing: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // State dots bleed a point past the chips they mark, and past the
        // strip's own bounds at the top, bottom, and trailing edges. Set explicitly
        // rather than left to the default so the bleed does not depend on
        // whether AppKit decided to back this view with a layer.
        clipsToBounds = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: edge)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: edge)
    }

    // NSView: the strip repaints on an appearance change for the same reason a
    // ChipView does -- it holds no resolved colors of its own.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { needsDisplay = true }
    }

    /// Which chips fit in `width`, and where the run starts.
    ///
    /// The pure core owns the fitting rule. This view supplies the chip and
    /// overflow-label metrics that tie the result to its painted geometry.
    func plan(width: CGFloat) -> PaneStripPlan {
        paneStripPlan(
            chips: chips,
            width: width,
            chipWidth: edge,
            spacing: spacing,
            overflowLabelWidth: overflowLabelWidth)
    }

    private func overflowLabelWidth(count: Int) -> CGFloat {
        overflowLabel(count: count).size().width
    }

    private func overflowLabel(count: Int) -> NSAttributedString {
        let appearance: ChipAppearance =
            effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        let palette = ChipStyle.paneStrip(isActive: false)
            .palette(for: .terminal, appearance: appearance)
        return NSAttributedString(
            string: "+\(count)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor(cgColor: palette.foreground) ?? .secondaryLabelColor,
            ])
    }

    /// The two corners a chip's state dots take. Separate corners because the
    /// two facts are independent: a pane can be alerting and running an agent
    /// at once, and each mark has to survive the other.
    enum MarkCorner {
        case topTrailing
        case bottomTrailing
    }

    /// Where one of a chip's state dots lands.
    ///
    /// The dot deliberately bleeds past the chip's corner: the strip's own
    /// margins have room for it, and a dot held fully inside a 12pt chip would
    /// cover a third of the mark that identifies the pane. That bleed is what
    /// `clipsToBounds = false` is for, so it has to stay bounded -- internal so
    /// the harness can hold this to the budget.
    func markRect(_ corner: MarkCorner, on chip: NSRect) -> NSRect {
        let scale = edge / ChipArtwork.paneRowSize
        let diameter = ChipArtwork.stateDotGeometry.diameter * scale
        let bleed = ChipArtwork.stateDotBleed * scale
        // A flipped strip's visual top is its minY, so the two corners swap.
        let top = isFlipped ? chip.minY - bleed : chip.maxY + bleed - diameter
        let bottom = isFlipped ? chip.maxY + bleed - diameter : chip.minY - bleed
        return NSRect(
            x: chip.maxX + bleed - diameter,
            y: corner == .topTrailing ? top : bottom,
            width: diameter,
            height: diameter)
    }

    private func agentDotColor(
        for mark: PaneAgentMark, palette: ChipPaneListPalette
    ) -> CGColor? {
        switch mark {
        case .quiet: return nil
        case .waiting: return palette.waitingDot
        case .working: return palette.busyDot
        }
    }

    /// Paints a chip's state dots, each ringed so it reads against the mark, the
    /// chip, and the row it overhangs alike. Every dot gets the same diameter
    /// and the same ring; only hue and corner tell them apart.
    private func drawStateDots(
        _ chipModel: TabPaneChip,
        on chip: NSRect,
        in context: CGContext,
        appearance: ChipAppearance
    ) {
        let palette = appearance == .light ? ChipArtwork.paneListLight : ChipArtwork.paneListDark
        if chipModel.hasAlert {
            fillMark(
                palette.alertDot, in: markRect(.topTrailing, on: chip),
                into: context, palette: palette)
        }
        if let color = agentDotColor(for: chipModel.agent, palette: palette) {
            fillMark(
                color, in: markRect(.bottomTrailing, on: chip),
                into: context, palette: palette)
        }
    }

    private func fillMark(
        _ color: CGColor, in dot: NSRect, into context: CGContext, palette: ChipPaneListPalette
    ) {
        context.saveGState()
        let ring = ChipArtwork.stateDotGeometry.ringWidth * (edge / ChipArtwork.paneRowSize)
        // The ring matches the row it sits on, so it reads as a gap around
        // the dot rather than as a halo of its own. Over the chip it does
        // the separating; over the row it disappears.
        context.setFillColor(rowBackground?.cgColor ?? palette.stateDotRing)
        context.fillEllipse(in: dot.insetBy(dx: -ring, dy: -ring))
        context.setFillColor(color)
        context.fillEllipse(in: dot)
        context.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !chips.isEmpty else { return }
        let plan = plan(width: bounds.width)
        guard !plan.visible.isEmpty else { return }

        let appearance: ChipAppearance =
            effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        var x: CGFloat = 0
        for chip in chips[plan.visible] {
            let rect = NSRect(x: x, y: (bounds.height - edge) / 2, width: edge, height: edge)
            ChipRenderer.draw(
                chip.kind.artwork,
                in: context,
                rect: rect,
                palette: ChipStyle.paneStrip(isActive: chip.isFocused)
                    .palette(for: chip.kind, appearance: appearance),
                flipped: isFlipped)
            drawStateDots(chip, on: rect, in: context, appearance: appearance)
            x += edge + spacing
        }

        guard plan.hidden > 0 else { return }
        // The count is deliberately unmarked: it stands for panes the row could
        // not show, and a dot on it would claim to summarize states it is not
        // reporting. The `+N` itself is the signal to widen the sidebar.
        let label = overflowLabel(count: plan.hidden)
        let size = label.size()
        label.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
    }
}
