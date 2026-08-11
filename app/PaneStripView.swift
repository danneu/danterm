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
final class PaneStripView: NSView {
    var chips: [TabPaneChip] = [] {
        didSet {
            guard chips != oldValue else { return }
            needsDisplay = true
        }
    }

    private let edge = ChipArtwork.paneRowSize
    private let spacing: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
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
            x += edge + spacing
        }

        guard plan.hidden > 0 else { return }
        let label = overflowLabel(count: plan.hidden)
        let size = label.size()
        label.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
    }
}
