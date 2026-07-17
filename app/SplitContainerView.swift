// AppKit view layer for rendering one tab's SplitNodeModel as nested PaneSplitViews
// that host each pane's PaneWrapperView. Construction is eager so restored tabs stay
// mounted, but DanTerm's explicit layout and split-ratio pass is deferred until first
// reveal through ensureLaidOut(), keeping launch restore from laying out every hidden
// tab. The model decides which tab is visible; this file realizes that tree and
// positions split dividers.
import Cocoa

class SplitContainerView: NSView {
    let rootNode: SplitNodeModel
    let surfaceLookup: (PaneId) -> (any TerminalSession)?
    let isZoomed: Bool
    let hasSplits: Bool
    weak var runtime: AppRuntime?
    private var hasBeenLaidOut = false
    /// Split views built for the current tree, kept so deferred ratio application
    /// can address each split by id without re-searching the AppKit hierarchy.
    private var splitViews: [SplitId: PaneSplitView] = [:]

    init(rootNode: SplitNodeModel, surfaceLookup: @escaping (PaneId) -> (any TerminalSession)?, runtime: AppRuntime?, isZoomed: Bool, hasSplits: Bool, frame: NSRect) {
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
        splitViews.removeAll(keepingCapacity: true)

        let view = buildView(for: rootNode)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)

        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        setApplyingRatio(true)
        hasBeenLaidOut = false
    }

    /// Applies stored split ratios exactly once, when the container is first revealed.
    func ensureLaidOut() {
        guard !hasBeenLaidOut else { return }
        layoutSubtreeIfNeeded()
        applyRatios(for: rootNode)
        setApplyingRatio(false)
        hasBeenLaidOut = true
    }

    private func applyRatios(for node: SplitNodeModel) {
        guard case .split(let id, _, let first, let second, _) = node else { return }
        if let paneSplit = splitViews[id] {
            paneSplit.applyRatio()
            paneSplit.layoutSubtreeIfNeeded()
        }
        applyRatios(for: first)
        applyRatios(for: second)
    }

    private func buildView(for node: SplitNodeModel) -> NSView {
        switch node {
        case .leaf(let pane):
            let paneId = pane.id
            if let terminalSession = surfaceLookup(paneId) {
                terminalSession.hostView.frame = .zero
                let wrapper = PaneWrapperView(paneId: paneId, terminalView: terminalSession, isZoomed: isZoomed, hasSplits: hasSplits, runtime: runtime)
                return wrapper
            }
            // Fallback: empty view (should not happen)
            return NSView()

        case .split(let id, let direction, let first, let second, let ratio):
            let splitView = PaneSplitView(splitId: id, ratio: ratio)
            splitViews[id] = splitView
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

    private func setApplyingRatio(_ value: Bool) {
        for splitView in splitViews.values {
            splitView.isApplyingRatio = value
        }
    }
}
