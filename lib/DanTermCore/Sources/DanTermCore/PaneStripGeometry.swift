// Pure pane-strip fitting. AppKit supplies chip and text metrics; this file
// decides the maximal visible run without reaching into fonts or appearance.

import Foundation

/// The contiguous chip run a pane strip shows and the pane count it elides.
struct PaneStripPlan: Equatable {
    let visible: Range<Int>
    let hidden: Int
}

/// Fits a maximal chip run and slides it only far enough to retain focus.
func paneStripPlan(
    chips: [TabPaneChip],
    width: CGFloat,
    chipWidth: CGFloat,
    spacing: CGFloat,
    overflowLabelWidth: (Int) -> CGFloat
) -> PaneStripPlan {
    let total = chips.count
    guard total > 0, width > 0 else {
        return PaneStripPlan(visible: 0..<0, hidden: total)
    }

    let slot = chipWidth + spacing
    var count = min(total, max(1, Int(floor((width + spacing) / slot))))
    while count > 1 {
        let hidden = total - count
        let labelWidth = hidden > 0 ? overflowLabelWidth(hidden) : 0
        let used = CGFloat(count) * slot - spacing
            + (labelWidth > 0 ? spacing + labelWidth : 0)
        if used <= width { break }
        count -= 1
    }

    let focusedIndex = chips.firstIndex(where: \.isFocused) ?? 0
    let start = focusedIndex >= count
        ? min(focusedIndex - count + 1, total - count)
        : 0
    return PaneStripPlan(visible: start..<(start + count), hidden: total - count)
}
