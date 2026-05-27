// UI-harness tests for SplitContainerView's first-reveal layout lifecycle.
import Cocoa

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
        surfaceLookup: { _ in nil },
        runtime: runtime,
        isZoomed: false,
        hasSplits: true,
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

private func splitRatioChangedMessages(_ messages: [Msg]) -> [(SplitId, CGFloat)] {
    var result: [(SplitId, CGFloat)] = []
    for message in messages {
        if case .splitRatioChanged(let splitId, let ratio) = message {
            result.append((splitId, ratio))
        }
    }
    return result
}
