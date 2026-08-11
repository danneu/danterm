// UI-harness tests for SplitContainerView's first-reveal layout lifecycle.
import Cocoa

@MainActor
func splitContainerViewTests() {
    print("SplitContainerView")

    uiTest("rebuild arms ratio guard and ensureLaidOut applies stored ratio") {
        // Intent: rebuilding a split container constructs the view tree with the
        //   resize-feedback guard armed, and first reveal applies the stored ratio.
        // Why it exists: pins the deferred-layout lifecycle so hidden restored tabs
        //   do not run DanTerm's explicit ratio pass until they are visible.
        // Scenario: a split tab is restored in the background, then selected for
        //   the first time. Spec-first -- no incident to cite.
        let splitId = SplitId()
        let container = makeSplitContainer(splitId: splitId, ratio: 0.7)

        container.rebuild()
        let splitView = try onlyPaneSplitView(in: container)
        try uiExpect(splitView.isApplyingRatio, "rebuild should leave isApplyingRatio armed")

        container.ensureLaidOut()

        try uiExpect(!splitView.isApplyingRatio, "ensureLaidOut should release isApplyingRatio")
        try uiExpect(firstSubviewRatio(in: splitView, expectedTotal: 800, expectedRatio: 0.7), "first subview should match stored ratio")
    }

    uiTest("deferred container suppresses split resize feedback") {
        // Intent: a constructed-but-not-revealed split container does not emit
        //   split-ratio feedback when AppKit lays it out.
        // Why it exists: guards the deferral window where hidden mounted views may
        //   still receive layout and resize notifications.
        // Scenario: a hidden split tab is restored, AppKit performs layout before
        //   the user ever selects that tab. Spec-first -- no incident to cite.
        let splitId = SplitId()
        let runtime = AppRuntime()
        let container = makeSplitContainer(splitId: splitId, ratio: 0.7, runtime: runtime)

        container.rebuild()
        container.layoutSubtreeIfNeeded()
        let splitView = try onlyPaneSplitView(in: container)
        splitView.splitViewDidResizeSubviews(Notification(name: NSSplitView.didResizeSubviewsNotification, object: splitView))

        try uiExpect(splitRatioChangedMessages(runtime.sentMessages).isEmpty, "deferred layout should not send splitRatioChanged")
        try uiExpect(abs(splitView.ratio - 0.7) < 0.0001, "stored ratio should remain 0.7, got \(splitView.ratio)")
    }

    uiTest("ensureLaidOut is idempotent") {
        // Intent: first-reveal layout is a one-shot operation for a container build.
        // Why it exists: reconcile emits setVisible(true) for the selected tab on
        //   every pass, so repeated calls must be no-ops after first reveal.
        // Scenario: a visible split tab is reconciled repeatedly after its first
        //   reveal. Spec-first -- no incident to cite.
        let splitId = SplitId()
        let runtime = AppRuntime()
        let container = makeSplitContainer(splitId: splitId, ratio: 0.7, runtime: runtime)

        container.rebuild()
        let splitView = try onlyPaneSplitView(in: container)
        container.ensureLaidOut()
        let firstWidth = splitView.arrangedSubviews[0].frame.width
        let messageCount = splitRatioChangedMessages(runtime.sentMessages).count

        container.ensureLaidOut()

        try uiExpect(abs(splitView.arrangedSubviews[0].frame.width - firstWidth) < 0.5, "second ensureLaidOut should keep the divider stable")
        try uiExpect(splitRatioChangedMessages(runtime.sentMessages).count == messageCount, "second ensureLaidOut should not send splitRatioChanged")
    }

    uiTest("nested split containers arm guards and apply each stored ratio") {
        // Intent: nested split containers apply every split node's stored ratio and
        //   release the resize-feedback guard for every realized PaneSplitView.
        // Why it exists: pins the exhaustive nested-split behavior that lets the
        //   split view lookup mechanism change without losing inner split nodes.
        // Scenario: a restored tab contains a horizontal split whose second pane
        //   is split vertically, then the tab is revealed. Spec-first -- no
        //   incident to cite.
        let outerSplitId = SplitId()
        let innerSplitId = SplitId()
        let container = makeNestedSplitContainer(
            outerSplitId: outerSplitId,
            innerSplitId: innerSplitId,
            outerRatio: 0.65,
            innerRatio: 0.7
        )

        container.rebuild()
        let splitViews = paneSplitViews(in: container)
        try uiExpect(splitViews.count == 2, "expected two PaneSplitViews, got \(splitViews.count)")
        try uiExpect(splitViews.allSatisfy(\.isApplyingRatio), "rebuild should leave every split guard armed")

        container.ensureLaidOut()
        let splitViewsById = Dictionary(uniqueKeysWithValues: paneSplitViews(in: container).map { ($0.splitId, $0) })
        try uiExpect(splitViewsById.count == 2, "expected two indexed PaneSplitViews, got \(splitViewsById.count)")
        try uiExpect(splitViewsById[outerSplitId] != nil, "missing outer PaneSplitView")
        try uiExpect(splitViewsById[innerSplitId] != nil, "missing inner PaneSplitView")

        let outerSplitView = splitViewsById[outerSplitId]!
        let innerSplitView = splitViewsById[innerSplitId]!
        try uiExpect(!outerSplitView.isApplyingRatio && !innerSplitView.isApplyingRatio, "ensureLaidOut should release every split guard")
        try uiExpect(firstSubviewRatio(in: outerSplitView, expectedRatio: 0.65), "outer split should match stored ratio")
        try uiExpect(firstSubviewRatio(in: innerSplitView, expectedRatio: 0.7), "inner split should match stored ratio")
    }

    uiTest("container rebuild reparents the same pane wrapper") {
        // Intent: rebuilding pane containers preserves both the terminal session
        //   and its runtime-owned wrapper host.
        // Why it exists: pane moves, splits, and zoom toggles must preserve
        //   toolbar and search-overlay identity with the terminal host.
        // Scenario: the incremental-container reconciliation performance fix.
        let paneId = PaneId()
        let terminal = TerminalView()
        let runtime = AppRuntime()
        runtime.sessions[paneId] = terminal
        let root = SplitNodeModel.leaf(PaneModel(id: paneId))
        let container = SplitContainerView(
            rootNode: root,
            wrapperLookup: { id in id == paneId ? runtime.paneHost(for: id)?.wrapper : nil },
            runtime: runtime,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )

        container.rebuild()
        let firstWrapper = terminal.paneWrapper
        container.rebuild()
        let secondWrapper = terminal.paneWrapper

        try uiExpect(terminal.hostView === terminal, "session host identity changed")
        try uiExpect(firstWrapper != nil && secondWrapper != nil, "rebuild should mount both wrappers")
        try uiExpect(firstWrapper === secondWrapper, "rebuild should preserve wrapper chrome")
    }

    uiTest("tree patch preserves wrapper and search overlay without ratio feedback") {
        // Intent: splitting a pane patches one live tree while preserving the
        //   pane wrapper, its search overlay, and every stored split ratio.
        // Why it exists: the old whole-tab rebuild discarded pane chrome and
        //   could feed layout-produced divider positions back into the model.
        // Scenario: the incremental-container reconciliation performance fix.
        let paneA = PaneId(), paneB = PaneId(), splitId = SplitId()
        let terminalA = TerminalView(), terminalB = TerminalView()
        let runtime = AppRuntime()
        runtime.sessions[paneA] = terminalA
        runtime.sessions[paneB] = terminalB
        let oldRoot = SplitNodeModel.leaf(PaneModel(id: paneA))
        let newRoot = SplitNodeModel.split(
            id: splitId,
            direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)),
            second: .leaf(PaneModel(id: paneB)),
            ratio: 0.7
        )
        let container = persistentContainer(root: oldRoot, runtime: runtime)
        container.rebuild()
        container.ensureLaidOut()
        let wrapper = try requireWrapper(runtime, paneA)
        wrapper.showSearchOverlay(search: SearchModel(needle: "needle"), runtime: runtime)
        let overlay = wrapper.searchOverlay
        let todoAnchor = wrapper.todoButtonView
        guard let patch = computeContainerTreePatch(
            old: containerShapeNode(oldRoot),
            new: containerShapeNode(newRoot)
        ) else { throw UITestFailure(message: "missing split patch") }

        container.applyTreePatch(patch, rootNode: newRoot)
        container.ensureLaidOut()

        try uiExpect(runtime.findPaneWrapper(for: paneA) === wrapper, "split replaced the original wrapper")
        try uiExpect(wrapper.searchOverlay === overlay, "split replaced the active search overlay")
        try uiExpect(wrapper.todoButtonView === todoAnchor, "split replaced the TODO popover anchor")
        try uiExpect(paneSplitViews(in: container).count == 1, "split patch should create one split view")
        try uiExpect(splitRatioChangedMessages(runtime.sentMessages).isEmpty, "patch layout emitted split-ratio feedback")

        let swappedRoot = SplitNodeModel.split(
            id: splitId,
            direction: .horizontal,
            first: .leaf(PaneModel(id: paneB)),
            second: .leaf(PaneModel(id: paneA)),
            ratio: 0.7
        )
        guard let swapPatch = computeContainerTreePatch(
            old: containerShapeNode(newRoot),
            new: containerShapeNode(swappedRoot)
        ) else { throw UITestFailure(message: "missing swap patch") }
        container.applyTreePatch(swapPatch, rootNode: swappedRoot)
        container.ensureLaidOut()

        guard let closePatch = computeContainerTreePatch(
            old: containerShapeNode(swappedRoot),
            new: containerShapeNode(.leaf(PaneModel(id: paneA)))
        ) else { throw UITestFailure(message: "missing close patch") }
        container.applyTreePatch(closePatch, rootNode: .leaf(PaneModel(id: paneA)))
        container.ensureLaidOut()

        try uiExpect(runtime.findPaneWrapper(for: paneA) === wrapper, "swap or sibling close replaced the wrapper")
        try uiExpect(wrapper.searchOverlay === overlay, "swap or sibling close replaced the search overlay")
        try uiExpect(wrapper.todoButtonView === todoAnchor, "swap or sibling close replaced the TODO anchor")
        try uiExpect(splitRatioChangedMessages(runtime.sentMessages).isEmpty, "swap or close layout emitted split-ratio feedback")
    }

    uiTest("zoom presents one pane without removing sibling wrappers") {
        // Intent: zoom hides branches outside the focused pane and unzoom restores
        //   them without removing either wrapper from the mounted hierarchy.
        // Why it exists: zoom used to rebuild a collapsed one-leaf container.
        // Scenario: the incremental-container reconciliation performance fix.
        let paneA = PaneId(), paneB = PaneId()
        let runtime = AppRuntime()
        runtime.sessions[paneA] = TerminalView()
        runtime.sessions[paneB] = TerminalView()
        let root = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)), second: .leaf(PaneModel(id: paneB)), ratio: 0.5)
        let container = persistentContainer(root: root, runtime: runtime)
        container.rebuild()
        let wrapperA = try requireWrapper(runtime, paneA)
        let wrapperB = try requireWrapper(runtime, paneB)

        container.setZoomedPane(paneA)

        try uiExpect(!wrapperA.isHidden && wrapperB.isHidden, "zoom should present only the focused pane")
        try uiExpect(wrapperA.isDescendant(of: container), "focused wrapper left the container hierarchy")
        try uiExpect(wrapperB.isDescendant(of: container), "hidden sibling wrapper left the container hierarchy")

        container.setZoomedPane(nil)

        try uiExpect(!wrapperA.isHidden && !wrapperB.isHidden, "unzoom should restore both wrappers")
    }

    uiTest("cross-tab patches preserve a moved wrapper in either patch order") {
        // Intent: moving a pane between tabs reparents its one wrapper even when
        //   the destination patch runs before the source patch.
        // Why it exists: container op order follows dictionary iteration, so one
        //   tab must not tear a wrapper back out of its new parent.
        // Scenario: the incremental-container reconciliation performance fix.
        let paneA = PaneId(), paneB = PaneId(), paneC = PaneId()
        let runtime = AppRuntime()
        runtime.sessions[paneA] = TerminalView()
        runtime.sessions[paneB] = TerminalView()
        runtime.sessions[paneC] = TerminalView()
        let sourceOld = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)), second: .leaf(PaneModel(id: paneB)), ratio: 0.5)
        let sourceNew = SplitNodeModel.leaf(PaneModel(id: paneB))
        let destinationOld = SplitNodeModel.leaf(PaneModel(id: paneC))
        let destinationNew = SplitNodeModel.split(
            id: SplitId(), direction: .vertical,
            first: .leaf(PaneModel(id: paneC)), second: .leaf(PaneModel(id: paneA)), ratio: 0.5)
        let source = persistentContainer(root: sourceOld, runtime: runtime)
        let destination = persistentContainer(root: destinationOld, runtime: runtime)
        source.rebuild()
        destination.rebuild()
        let movedWrapper = try requireWrapper(runtime, paneA)
        guard let sourcePatch = computeContainerTreePatch(
            old: containerShapeNode(sourceOld), new: containerShapeNode(sourceNew)),
              let destinationPatch = computeContainerTreePatch(
                old: containerShapeNode(destinationOld), new: containerShapeNode(destinationNew)) else {
            throw UITestFailure(message: "missing cross-tab patches")
        }

        destination.applyTreePatch(destinationPatch, rootNode: destinationNew)
        source.applyTreePatch(sourcePatch, rootNode: sourceNew)

        try uiExpect(runtime.findPaneWrapper(for: paneA) === movedWrapper, "move replaced the pane wrapper")
        try uiExpect(movedWrapper.isDescendant(of: destination), "source patch detached the moved wrapper from its destination")
    }

    uiTest("removing the runtime host releases pane chrome") {
        // Intent: removing a pane's session-lifetime host releases its wrapper
        //   once no container parents that wrapper.
        // Why it exists: the ownership inversion must not trade rebuild churn for
        //   a runtime-owned wrapper leak.
        // Scenario: the incremental-container reconciliation performance fix.
        let paneId = PaneId()
        let runtime = AppRuntime()
        weak var hostObserver: PaneHost?
        weak var wrapperObserver: PaneWrapperView?

        autoreleasepool {
            runtime.sessions[paneId] = TerminalView()
            hostObserver = runtime.paneHost(for: paneId)
            wrapperObserver = hostObserver?.wrapper
            runtime.paneHosts.removeValue(forKey: paneId)
            runtime.sessions.removeValue(forKey: paneId)
        }

        try uiExpect(hostObserver == nil, "runtime released its host but the host stayed alive")
        try uiExpect(wrapperObserver == nil, "runtime released its host but the wrapper stayed alive")
    }
}

/// Builds a container whose wrapper lookup goes through the runtime lifetime root.
@MainActor
private func persistentContainer(root: SplitNodeModel, runtime: AppRuntime) -> SplitContainerView {
    SplitContainerView(
        rootNode: root,
        wrapperLookup: { [weak runtime] paneId in runtime?.paneHost(for: paneId)?.wrapper },
        runtime: runtime,
        frame: NSRect(x: 0, y: 0, width: 800, height: 600)
    )
}

/// Unwraps one runtime-owned pane wrapper for identity assertions.
@MainActor
private func requireWrapper(_ runtime: AppRuntime, _ paneId: PaneId) throws -> PaneWrapperView {
    guard let wrapper = runtime.findPaneWrapper(for: paneId) else {
        throw UITestFailure(message: "missing wrapper for \(paneId)")
    }
    return wrapper
}

private func makeSplitContainer(splitId: SplitId, ratio: CGFloat, runtime: AppRuntime? = nil) -> SplitContainerView {
    let root = SplitNodeModel.split(
        id: splitId,
        direction: .horizontal,
        first: .leaf(PaneModel(id: PaneId())),
        second: .leaf(PaneModel(id: PaneId())),
        ratio: ratio
    )
    return SplitContainerView(
        rootNode: root,
        wrapperLookup: { _ in nil },
        runtime: runtime,
        frame: NSRect(x: 0, y: 0, width: 800, height: 600)
    )
}

private func makeNestedSplitContainer(outerSplitId: SplitId, innerSplitId: SplitId, outerRatio: CGFloat, innerRatio: CGFloat) -> SplitContainerView {
    let root = SplitNodeModel.split(
        id: outerSplitId,
        direction: .horizontal,
        first: .leaf(PaneModel(id: PaneId())),
        second: .split(
            id: innerSplitId,
            direction: .vertical,
            first: .leaf(PaneModel(id: PaneId())),
            second: .leaf(PaneModel(id: PaneId())),
            ratio: innerRatio
        ),
        ratio: outerRatio
    )
    return SplitContainerView(
        rootNode: root,
        wrapperLookup: { _ in nil },
        runtime: nil,
        frame: NSRect(x: 0, y: 0, width: 800, height: 600)
    )
}

private func onlyPaneSplitView(in view: NSView) throws -> PaneSplitView {
    let splitViews = paneSplitViews(in: view)
    try uiExpect(splitViews.count == 1, "expected exactly one PaneSplitView, got \(splitViews.count)")
    return splitViews[0]
}

private func paneSplitViews(in view: NSView) -> [PaneSplitView] {
    var result: [PaneSplitView] = []
    if let splitView = view as? PaneSplitView {
        result.append(splitView)
    }
    for subview in view.subviews {
        result.append(contentsOf: paneSplitViews(in: subview))
    }
    return result
}

private func firstSubviewRatio(in splitView: PaneSplitView, expectedTotal: CGFloat, expectedRatio: CGFloat) -> Bool {
    guard splitView.arrangedSubviews.count == 2 else { return false }
    let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    let first = splitView.isVertical ? splitView.arrangedSubviews[0].frame.width : splitView.arrangedSubviews[0].frame.height
    return abs(total - expectedTotal) < 0.5 && abs(first - expectedTotal * expectedRatio) < 2
}

private func firstSubviewRatio(in splitView: PaneSplitView, expectedRatio: CGFloat) -> Bool {
    guard splitView.arrangedSubviews.count == 2 else { return false }
    let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    guard total > 0 else { return false }
    let first = splitView.isVertical ? splitView.arrangedSubviews[0].frame.width : splitView.arrangedSubviews[0].frame.height
    return abs(first - total * expectedRatio) < 2
}

private func splitRatioChangedMessages(_ messages: [Msg]) -> [(SplitId, CGFloat)] {
    var result: [(SplitId, CGFloat)] = []
    for message in messages {
        if case .splitRatioChanged(let splitId, let ratio) = message {
            result.append((splitId, ratio))
        }
    }
    return result
}
