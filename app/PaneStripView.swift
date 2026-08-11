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

/// A tab row's pane enumeration, drawn to fit whatever width it is given.
///
/// Shows a contiguous run of chips and, when they do not all fit, a `+N`
/// count of the ones left out. The run always contains the focused pane --
/// the strip exists to answer "which pane am I in", so that chip is the one
/// thing it may never elide.
///
/// Each chip may carry one state dot on its corner: red for a pane that wants
/// you, a smaller and dimmer amber for one whose agent is mid-turn. Which of
/// those a pane gets is decided in the core by `paneChipState`, not here.
final class PaneStripView: NSView {
    var chips: [TabPaneChip] = [] {
        didSet {
            guard chips != oldValue else { return }
            needsDisplay = true
        }
    }

    /// What the strip should punch its attention rings out of, or nil for the
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
        // strip's own bounds at the top and trailing edges. Set explicitly
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

    /// What the strip shows at a given width: a contiguous run of chips and the
    /// number of panes that run leaves out.
    struct Plan: Equatable {
        let visible: Range<Int>
        let hidden: Int
    }

    /// Which chips fit in `width`, and where the run starts.
    ///
    /// The count is solved by iteration rather than algebra because the `+N`
    /// label's own width depends on N: dropping one more chip can widen the
    /// label enough to force dropping another. It terminates because the
    /// candidate count strictly decreases.
    ///
    /// Internal so the UI harness can test the fitting directly -- the whole
    /// point of this view is that no pane count overflows the row, which is a
    /// claim about this function.
    func plan(width: CGFloat) -> Plan {
        let total = chips.count
        guard total > 0, width > 0 else { return Plan(visible: 0..<0, hidden: total) }
        let slot = edge + spacing

        var count = min(total, max(1, Int(floor((width + spacing) / slot))))
        while count > 1 {
            let label = count < total ? overflowLabel(count: total - count).size().width : 0
            // The run's own width has no trailing gap; the label pays for one.
            let used = CGFloat(count) * slot - spacing + (label > 0 ? spacing + label : 0)
            if used <= width { break }
            count -= 1
        }

        // Slide the run forward only as far as it takes to keep the focused
        // chip inside it, so the strip still reads left to right.
        let activeIndex = chips.firstIndex(where: \.isFocused) ?? 0
        var start = 0
        if activeIndex >= count {
            start = min(activeIndex - count + 1, total - count)
        }
        return Plan(visible: start..<(start + count), hidden: total - count)
    }

    /// The `+N` label's width. Internal for the harness test that checks the
    /// planned run fits, which has to account for the label the same way.
    func overflowLabelWidth(count: Int) -> CGFloat {
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

    private func dotSize(for state: PaneChipState) -> ChipStateDotSize? {
        switch state {
        case .quiet: return nil
        case .attention: return ChipArtwork.attentionDotSize
        case .busy: return ChipArtwork.busyDotSize
        }
    }

    /// Where a chip's state dot lands, or nil for a pane with nothing to say.
    ///
    /// The dot deliberately bleeds past the chip's top-right corner: the strip's
    /// own margins have room for it, and a dot held fully inside a 12pt chip
    /// would cover a third of the mark that identifies the pane. That bleed is
    /// what `clipsToBounds = false` is for, so it has to stay bounded --
    /// internal so the harness can hold this to the budget.
    func stateDotRect(_ state: PaneChipState, on chip: NSRect) -> NSRect? {
        guard let size = dotSize(for: state) else { return nil }
        let scale = edge / ChipArtwork.paneRowSize
        let diameter = size.diameter * scale
        let bleed = ChipArtwork.stateDotBleed * scale
        return NSRect(
            x: chip.maxX + bleed - diameter,
            y: isFlipped ? chip.minY - bleed : chip.maxY + bleed - diameter,
            width: diameter,
            height: diameter)
    }

    /// Paints one chip's state dot, ringed so it reads against the mark, the
    /// chip, and the row it overhangs alike. Only the attention dot is ringed;
    /// busy is muted on purpose and a ring would undo that.
    private func drawStateDot(
        _ state: PaneChipState,
        on chip: NSRect,
        in context: CGContext,
        appearance: ChipAppearance
    ) {
        guard let size = dotSize(for: state), let dot = stateDotRect(state, on: chip) else { return }
        let palette = appearance == .light ? ChipArtwork.paneListLight : ChipArtwork.paneListDark

        context.saveGState()
        if size.ringWidth > 0 {
            let ring = size.ringWidth * (edge / ChipArtwork.paneRowSize)
            // The ring matches the row it sits on, so it reads as a gap around
            // the dot rather than as a halo of its own. Over the chip it does
            // the separating; over the row it disappears.
            context.setFillColor(rowBackground?.cgColor ?? palette.stateDotRing)
            context.fillEllipse(in: dot.insetBy(dx: -ring, dy: -ring))
        }
        context.setAlpha(size.alpha)
        context.setFillColor(state == .attention ? palette.attentionDot : palette.busyDot)
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
            drawStateDot(chip.state, on: rect, in: context, appearance: appearance)
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
