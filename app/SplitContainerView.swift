import Cocoa

class SplitContainerView: NSView {
    let rootNode: SplitNodeModel
    let surfaceLookup: (PaneId) -> TerminalView?
    weak var runtime: AppRuntime?

    init(rootNode: SplitNodeModel, surfaceLookup: @escaping (PaneId) -> TerminalView?, runtime: AppRuntime?, frame: NSRect) {
        self.rootNode = rootNode
        self.surfaceLookup = surfaceLookup
        self.runtime = runtime
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func rebuild() {
        for sub in subviews {
            sub.removeFromSuperview()
        }

        let view = buildView(for: rootNode)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)

        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Force layout from root down, then apply ratios top-down
        layoutSubtreeIfNeeded()
        applyRatios(for: rootNode)
    }

    private func applyRatios(for node: SplitNodeModel) {
        guard case .split(_, _, let first, let second, _) = node else { return }
        if let paneSplit = findPaneSplitView(for: node) {
            paneSplit.applyRatio()
            paneSplit.layoutSubtreeIfNeeded()
        }
        applyRatios(for: first)
        applyRatios(for: second)
    }

    private func findPaneSplitView(for node: SplitNodeModel) -> PaneSplitView? {
        guard case .split(let id, _, _, _, _) = node else { return nil }
        return findPaneSplitViewIn(view: self, id: id)
    }

    private func findPaneSplitViewIn(view: NSView, id: SplitId) -> PaneSplitView? {
        if let psv = view as? PaneSplitView, psv.splitId == id {
            return psv
        }
        for sub in view.subviews {
            if let found = findPaneSplitViewIn(view: sub, id: id) {
                return found
            }
        }
        return nil
    }

    private func buildView(for node: SplitNodeModel) -> NSView {
        switch node {
        case .leaf(let paneId):
            if let terminalView = surfaceLookup(paneId) {
                terminalView.frame = .zero
                return terminalView
            }
            // Fallback: empty view (should not happen)
            return NSView()

        case .split(let id, let direction, let first, let second, let ratio):
            let splitView = PaneSplitView(splitId: id, ratio: ratio, runtime: runtime)
            splitView.isVertical = (direction == .horizontal)
            splitView.dividerStyle = .thin
            splitView.delegate = splitView

            let firstView = buildView(for: first)
            let secondView = buildView(for: second)

            firstView.translatesAutoresizingMaskIntoConstraints = true
            secondView.translatesAutoresizingMaskIntoConstraints = true

            splitView.addArrangedSubview(firstView)
            splitView.addArrangedSubview(secondView)

            splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

            return splitView
        }
    }
}

// MARK: - PaneSplitView

class PaneSplitView: NSSplitView, NSSplitViewDelegate {
    let splitId: SplitId
    var ratio: CGFloat
    weak var runtime: AppRuntime?

    init(splitId: SplitId, ratio: CGFloat, runtime: AppRuntime?) {
        self.splitId = splitId
        self.ratio = ratio
        self.runtime = runtime
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

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard arrangedSubviews.count == 2 else { return }
        let totalSize = isVertical ? bounds.width : bounds.height
        guard totalSize > 0 else { return }
        let firstSize = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
        let newRatio = firstSize / totalSize
        ratio = newRatio
        runtime?.send(.splitRatioChanged(splitId: splitId, ratio: newRatio))
    }
}
