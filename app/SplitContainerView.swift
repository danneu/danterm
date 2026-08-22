// Flat AppKit host for one tab's persistent pane wrappers and divider strips.
// The pure core owns all pane geometry; no nested AppKit layout belongs here.
import Cocoa

/// Presents one model split tree without giving AppKit a second geometry model.
class SplitContainerView: NSView {
    private(set) var rootNode: SplitNodeModel
    private let wrapperLookup: (PaneId) -> PaneWrapperView?
    weak var runtime: AppRuntime?
    private var dividerViews: [SplitId: PaneDividerView] = [:]
    private var zoomedPaneId: PaneId?

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

    /// Reconciles all direct children for a new or restored tab.
    func rebuild() {
        applyModelLayout()
    }

    /// Applies the next model tree without rebuilding surviving pane wrappers.
    func setRootNode(_ newRootNode: SplitNodeModel) {
        rootNode = newRootNode
        applyModelLayout()
    }

    /// Selects the pure zoom layout without detaching or pinning any wrapper.
    func setZoomedPane(_ paneId: PaneId?) {
        guard zoomedPaneId != paneId else { return }
        zoomedPaneId = paneId
        applyModelLayout()
    }

    /// Keeps the old reveal call idempotent while hidden tabs now lay out eagerly.
    func ensureLaidOut() {
        applyModelLayout()
    }

    override func layout() {
        super.layout()
        applyModelLayout()
    }

    /// Answers geometry questions (pane drop targeting) from the layout this view
    /// presents, derived from the bounds at the moment of the call -- so a caller
    /// cannot read pane rectangles that a pending AppKit layout pass has stranded.
    func currentPaneLayout() -> PaneLayout {
        paneLayout(in: PaneLayoutRect(bounds), tree: rootNode, zoomedPaneId: zoomedPaneId)
    }

    /// Answers geometry questions about the whole arranged tab, independent of zoom.
    func currentArrangedPaneLayout() -> PaneLayout {
        paneLayout(in: PaneLayoutRect(bounds), tree: rootNode, zoomedPaneId: nil)
    }

    private func applyModelLayout() {
        let layout = currentPaneLayout()
        reconcilePanes(with: layout)
        reconcileDividers(with: layout)
    }

    private func reconcilePanes(with layout: PaneLayout) {
        let desiredPaneIds = Set(allPaneIds(rootNode))
        let mountedWrappers = Dictionary(uniqueKeysWithValues: subviews.compactMap { view in
            (view as? PaneWrapperView).map { ($0.paneId, $0) }
        })
        for (paneId, wrapper) in mountedWrappers where desiredPaneIds.contains(paneId) == false {
            wrapper.removeFromSuperview()
        }

        for paneId in desiredPaneIds {
            guard let view = mountedWrappers[paneId] ?? wrapperLookup(paneId) else { continue }

            let shouldHide = layout.hiddenPaneIds.contains(paneId)
            if view.isHidden != shouldHide {
                view.isHidden = shouldHide
            }
            if let rect = layout.paneFrames[paneId] {
                setFrameIfNeeded(NSRect(rect), on: view)
            }
            if view.superview !== self {
                view.translatesAutoresizingMaskIntoConstraints = true
                addSubview(view)
            }
        }
    }

    private func reconcileDividers(with layout: PaneLayout) {
        for splitId in dividerViews.keys where layout.dividers[splitId] == nil {
            dividerViews.removeValue(forKey: splitId)?.removeFromSuperview()
        }

        for (splitId, placement) in layout.dividers {
            let divider: PaneDividerView
            if let existing = dividerViews[splitId] {
                divider = existing
            } else {
                divider = PaneDividerView(splitId: splitId)
                divider.onRatioChanged = { [weak self] splitId, ratio in
                    self?.runtime?.send(.splitRatioChanged(splitId: splitId, ratio: ratio))
                }
                dividerViews[splitId] = divider
            }
            divider.apply(placement: placement, in: bounds)
            if divider.superview !== self {
                addSubview(divider, positioned: .above, relativeTo: nil)
            }
        }
    }

    private func setFrameIfNeeded(_ frame: NSRect, on view: NSView) {
        guard view.frame != frame else { return }
        view.frame = frame
    }
}
