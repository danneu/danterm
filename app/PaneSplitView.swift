// Split-view host that owns one model ratio and suppresses programmatic layout feedback.
import Cocoa

class PaneSplitView: NSSplitView, NSSplitViewDelegate {
    let splitId: SplitId
    var ratio: CGFloat
    var isApplyingRatio: Bool = false
    var shouldSuppressRatioFeedback: (() -> Bool)?
    var onRatioChanged: ((SplitId, CGFloat) -> Void)?

    init(splitId: SplitId, ratio: CGFloat) {
        self.splitId = splitId
        self.ratio = ratio
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func applyRatio() {
        guard arrangedSubviews.count == 2 else { return }
        let totalSize = isVertical ? bounds.width : bounds.height
        guard totalSize > 0 else { return }
        let position = totalSize * ratio
        setPosition(position, ofDividerAt: 0)
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 100
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let totalSize = isVertical ? bounds.width : bounds.height
        return totalSize - 100
    }

    // Double-click on divider resets the split to 50/50.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, arrangedSubviews.count == 2 {
            let point = convert(event.locationInWindow, from: nil)
            let first = arrangedSubviews[0].frame
            let pad: CGFloat = 3
            let onDivider: Bool
            if isVertical {
                onDivider = abs(point.x - first.maxX) <= dividerThickness / 2 + pad
            } else {
                onDivider = abs(point.y - first.maxY) <= dividerThickness / 2 + pad
            }
            if onDivider {
                ratio = 0.5
                applyRatio()
                onRatioChanged?(splitId, ratio)
                return
            }
        }
        super.mouseDown(with: event)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplyingRatio, shouldSuppressRatioFeedback?() != true else { return }
        guard arrangedSubviews.count == 2 else { return }
        let totalSize = isVertical ? bounds.width : bounds.height
        guard totalSize > 0 else { return }
        let firstSize = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
        let newRatio = firstSize / totalSize
        ratio = newRatio
        onRatioChanged?(splitId, newRatio)
    }
}
