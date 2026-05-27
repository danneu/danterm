// AppKit view layer for rendering one tab's SplitNodeModel as nested PaneSplitViews
// that host each pane's PaneWrapperView. Construction is eager so restored tabs stay
// mounted, but DanTerm's explicit layout and split-ratio pass is deferred until first
// reveal through ensureLaidOut(), keeping launch restore from laying out every hidden
// tab. The model decides which tab is visible; this file realizes that tree and
// positions split dividers.
import Cocoa

class SplitContainerView: NSView {
    let rootNode: SplitNodeModel
    let surfaceLookup: (PaneId) -> TerminalView?
    let isZoomed: Bool
    let hasSplits: Bool
    weak var runtime: AppRuntime?
    private var hasBeenLaidOut = false

    init(rootNode: SplitNodeModel, surfaceLookup: @escaping (PaneId) -> TerminalView?, runtime: AppRuntime?, isZoomed: Bool, hasSplits: Bool, frame: NSRect) {
        self.rootNode = rootNode
        self.surfaceLookup = surfaceLookup
        self.isZoomed = isZoomed
        self.hasSplits = hasSplits
        self.runtime = runtime
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // Builds the split tree and arms the resize-feedback guard for the deferral
    // window. First-reveal layout is applied by ensureLaidOut().
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

        setApplyingRatio(true, in: self)
        hasBeenLaidOut = false
    }

    /// Applies stored split ratios exactly once, when the container is first revealed.
    func ensureLaidOut() {
        guard !hasBeenLaidOut else { return }
        layoutSubtreeIfNeeded()
        applyRatios(for: rootNode)
        setApplyingRatio(false, in: self)
        hasBeenLaidOut = true
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
        case .leaf(let pane):
            let paneId = pane.id
            if let terminalView = surfaceLookup(paneId) {
                terminalView.frame = .zero
                let wrapper = PaneWrapperView(paneId: paneId, terminalView: terminalView, isZoomed: isZoomed, hasSplits: hasSplits, runtime: runtime)
                return wrapper
            }
            // Fallback: empty view (should not happen)
            return NSView()

        case .split(let id, let direction, let first, let second, let ratio):
            let splitView = PaneSplitView(splitId: id, ratio: ratio)
            splitView.onRatioChanged = { [weak self] splitId, ratio in
                self?.runtime?.send(.splitRatioChanged(splitId: splitId, ratio: ratio))
            }
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

    private func setApplyingRatio(_ value: Bool, in view: NSView) {
        if let paneSplit = view as? PaneSplitView {
            paneSplit.isApplyingRatio = value
        }
        for sub in view.subviews {
            setApplyingRatio(value, in: sub)
        }
    }
}
