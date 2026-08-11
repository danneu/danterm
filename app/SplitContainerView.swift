// AppKit host for one tab's persistent pane wrappers and keyed split-view tree.
// Full construction belongs to new/restored tabs; live structural edits patch this tree.
import Cocoa

/// Realizes one tab's split tree while preserving surviving pane and split view identity.
class SplitContainerView: NSView {
    private(set) var rootNode: SplitNodeModel
    private let wrapperLookup: (PaneId) -> PaneWrapperView?
    weak var runtime: AppRuntime?
    private var rootView: NSView?
    private var rootConstraints: [NSLayoutConstraint] = []
    private var hasBeenLaidOut = false
    private var isApplyingTreePatch = false
    private var pendingRatioIds: Set<SplitId> = []
    private var leafViews: [PaneId: NSView] = [:]
    private var splitViews: [SplitId: PaneSplitView] = [:]
    private var zoomedPaneId: PaneId?
    private var zoomedWrapper: PaneWrapperView?
    private var zoomedWrapperOrigin: (splitId: SplitId, index: Int)?
    private var zoomConstraints: [NSLayoutConstraint] = []

    init(
        rootNode: SplitNodeModel,
        wrapperLookup: @escaping (PaneId) -> PaneWrapperView?,
        runtime: AppRuntime?,
        frame: NSRect
    ) {
        self.rootNode = rootNode
        self.wrapperLookup = wrapperLookup
        self.runtime = runtime
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Constructs the complete hierarchy for a new or restored tab.
    func rebuild() {
        isApplyingTreePatch = true
        defer { isApplyingTreePatch = false }
        for subview in subviews {
            subview.removeFromSuperview()
        }
        NSLayoutConstraint.deactivate(rootConstraints)
        rootConstraints.removeAll(keepingCapacity: true)
        rootView = nil
        leafViews.removeAll(keepingCapacity: true)
        splitViews.removeAll(keepingCapacity: true)

        installRoot(buildView(for: rootNode))
        pendingRatioIds = Set(splitViews.keys)
        hasBeenLaidOut = false
        applyZoomVisibility()
    }

    /// Applies a pure keyed patch without recreating surviving wrappers or split views.
    func applyTreePatch(_ patch: ContainerTreePatch, rootNode newRootNode: SplitNodeModel) {
        isApplyingTreePatch = true
        defer { isApplyingTreePatch = false }
        let presentedZoom = zoomedPaneId
        removeZoomPresentation()

        for splitId in patch.changedSplitIds where splitViews[splitId] == nil {
            guard let spec = patch.desiredSplits[splitId] else { continue }
            splitViews[splitId] = makeSplitView(
                splitId: splitId,
                direction: spec.direction,
                ratio: ratio(for: splitId, in: newRootNode) ?? 0.5
            )
        }

        // Detach the old root before it can become a child of the desired root.
        // Removing it after reparenting would remove that live child a second time.
        if patch.rootChanged {
            NSLayoutConstraint.deactivate(rootConstraints)
            rootConstraints.removeAll(keepingCapacity: true)
            rootView?.removeFromSuperview()
            rootView = nil
        }

        var refsToDetach: Set<ContainerNodeRef> = []
        for splitId in patch.changedSplitIds {
            guard let spec = patch.desiredSplits[splitId] else { continue }
            refsToDetach.insert(spec.first)
            refsToDetach.insert(spec.second)
        }
        if patch.rootChanged {
            refsToDetach.insert(patch.desiredRoot)
        }
        for ref in refsToDetach {
            if let view = view(for: ref) {
                detach(view)
            }
        }

        for splitId in patch.changedSplitIds {
            guard let splitView = splitViews[splitId],
                  let spec = patch.desiredSplits[splitId] else { continue }
            for child in splitView.arrangedSubviews {
                splitView.removeArrangedSubview(child)
                child.removeFromSuperview()
            }
            splitView.isVertical = spec.direction == .horizontal
            splitView.ratio = ratio(for: splitId, in: newRootNode) ?? splitView.ratio
            splitView.isApplyingRatio = true
            if let first = view(for: spec.first), let second = view(for: spec.second) {
                attach(first, to: splitView)
                attach(second, to: splitView)
            }
        }

        if patch.rootChanged, let desiredRoot = view(for: patch.desiredRoot) {
            installRoot(desiredRoot)
        }

        for splitId in patch.removedSplitIds {
            splitViews.removeValue(forKey: splitId)?.removeFromSuperview()
        }
        rootNode = newRootNode
        let desiredPaneIds = Set(allPaneIds(newRootNode))
        for paneId in leafViews.keys where !desiredPaneIds.contains(paneId) {
            let staleView = leafViews.removeValue(forKey: paneId)
            if let staleView, staleView.isDescendant(of: self) {
                staleView.removeFromSuperview()
            }
        }
        pendingRatioIds.formUnion(patch.changedSplitIds)
        hasBeenLaidOut = false
        if let presentedZoom {
            presentZoomedPane(presentedZoom)
        }
    }

    /// Changes zoom presentation while leaving the complete split hierarchy mounted.
    func setZoomedPane(_ paneId: PaneId?) {
        guard zoomedPaneId != paneId else { return }
        removeZoomPresentation()
        zoomedPaneId = paneId
        if let paneId {
            presentZoomedPane(paneId)
        } else {
            pendingRatioIds.formUnion(splitViews.keys)
        }
        hasBeenLaidOut = false
    }

    /// Applies stored ratios after a build or patch without emitting model writes.
    func ensureLaidOut() {
        guard !hasBeenLaidOut else { return }
        isApplyingTreePatch = true
        defer { isApplyingTreePatch = false }
        needsLayout = true
        layoutSubtreeIfNeeded()
        applyPendingRatios(for: rootNode)
        pendingRatioIds.removeAll(keepingCapacity: true)
        for splitView in splitViews.values {
            splitView.isApplyingRatio = false
        }
        hasBeenLaidOut = true
    }

    private func buildView(for node: SplitNodeModel) -> NSView {
        switch node {
        case .leaf(let pane):
            let view = wrapperLookup(pane.id) ?? NSView()
            view.frame = .zero
            leafViews[pane.id] = view
            return view
        case .split(let splitId, let direction, let first, let second, let ratio):
            let splitView = makeSplitView(
                splitId: splitId,
                direction: direction,
                ratio: ratio
            )
            splitViews[splitId] = splitView
            attach(buildView(for: first), to: splitView)
            attach(buildView(for: second), to: splitView)
            return splitView
        }
    }

    private func makeSplitView(
        splitId: SplitId,
        direction: SplitNodeModel.Direction,
        ratio: CGFloat
    ) -> PaneSplitView {
        let splitView = PaneSplitView(splitId: splitId, ratio: ratio)
        splitView.frame = bounds
        splitView.shouldSuppressRatioFeedback = { [weak self] in
            guard let self else { return true }
            return self.isApplyingTreePatch || !self.hasBeenLaidOut
        }
        splitView.onRatioChanged = { [weak self] splitId, ratio in
            self?.runtime?.send(.splitRatioChanged(splitId: splitId, ratio: ratio))
        }
        splitView.isVertical = direction == .horizontal
        splitView.dividerStyle = .thin
        splitView.delegate = splitView
        splitView.isApplyingRatio = true
        return splitView
    }

    private func attach(_ view: NSView, to splitView: PaneSplitView) {
        if view.bounds.isEmpty {
            view.frame = splitView.bounds
        }
        view.translatesAutoresizingMaskIntoConstraints = true
        splitView.addArrangedSubview(view)
        let index = splitView.arrangedSubviews.count - 1
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: index)
    }

    private func detach(_ view: NSView) {
        if let splitView = view.superview as? PaneSplitView {
            splitView.removeArrangedSubview(view)
        }
        view.removeFromSuperview()
    }

    private func installRoot(_ view: NSView) {
        rootView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        rootConstraints = [
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        NSLayoutConstraint.activate(rootConstraints)
    }

    private func view(for ref: ContainerNodeRef) -> NSView? {
        switch ref {
        case .pane(let paneId):
            if let view = leafViews[paneId] { return view }
            guard let wrapper = wrapperLookup(paneId) else { return nil }
            leafViews[paneId] = wrapper
            return wrapper
        case .split(let splitId):
            return splitViews[splitId]
        }
    }

    private func ratio(for splitId: SplitId, in node: SplitNodeModel) -> CGFloat? {
        switch node {
        case .leaf:
            return nil
        case .split(let id, _, let first, let second, let ratio):
            if id == splitId { return ratio }
            return self.ratio(for: splitId, in: first) ?? self.ratio(for: splitId, in: second)
        }
    }

    private func applyPendingRatios(for node: SplitNodeModel) {
        guard case .split(let splitId, _, let first, let second, _) = node else { return }
        if pendingRatioIds.contains(splitId), let splitView = splitViews[splitId] {
            splitView.applyRatio()
            splitView.layoutSubtreeIfNeeded()
        }
        applyPendingRatios(for: first)
        applyPendingRatios(for: second)
    }

    private func applyZoomVisibility() {
        guard let zoomedPaneId else { return }
        presentZoomedPane(zoomedPaneId)
    }

    private func presentZoomedPane(_ paneId: PaneId) {
        guard zoomedWrapper == nil,
              let wrapper = leafViews[paneId] as? PaneWrapperView,
              let splitView = wrapper.superview as? PaneSplitView,
              let index = splitView.arrangedSubviews.firstIndex(of: wrapper) else { return }
        zoomedWrapperOrigin = (splitView.splitId, index)
        splitView.removeArrangedSubview(wrapper)
        wrapper.removeFromSuperview()
        rootView?.isHidden = true
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wrapper)
        zoomConstraints = [
            wrapper.topAnchor.constraint(equalTo: topAnchor),
            wrapper.bottomAnchor.constraint(equalTo: bottomAnchor),
            wrapper.leadingAnchor.constraint(equalTo: leadingAnchor),
            wrapper.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        NSLayoutConstraint.activate(zoomConstraints)
        zoomedWrapper = wrapper
    }

    private func removeZoomPresentation() {
        guard let wrapper = zoomedWrapper,
              let origin = zoomedWrapperOrigin,
              let splitView = splitViews[origin.splitId] else { return }
        NSLayoutConstraint.deactivate(zoomConstraints)
        zoomConstraints.removeAll(keepingCapacity: true)
        wrapper.removeFromSuperview()
        wrapper.translatesAutoresizingMaskIntoConstraints = true
        splitView.insertArrangedSubview(wrapper, at: origin.index)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: origin.index)
        rootView?.isHidden = false
        zoomedWrapper = nil
        zoomedWrapperOrigin = nil
    }
}
