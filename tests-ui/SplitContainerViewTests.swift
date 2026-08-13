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
        let wrapperB = try requireWrapper(runtime, paneB)
        try uiExpect(wrapper.isDescendant(of: container), "first split detached the original wrapper")
        try uiExpect(wrapperB.isDescendant(of: container), "first split did not mount the new wrapper")
        try uiExpect(wrapper.frame.width > 0 && wrapperB.frame.width > 0, "first split left a pane with zero width")
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

    uiTest("pane focus reconciliation repairs the 2026-08-12 split incident") {
        // Intent: after an incremental split strands AppKit first responder, the
        //   model-selected new pane receives focus before the event completes.
        // Why it exists: this is the AppKit regression from the 2026-08-12 report
        //   where the first keystroke after splitting reached no pane.
        // Scenario: pane A owns focus, a foreground split reparents both wrappers
        //   and chooses pane B, then the focus pass repairs the stranded window.
        let paneA = PaneId(), paneB = PaneId(), tabId = TabId()
        let oldRoot = SplitNodeModel.leaf(PaneModel(id: paneA))
        let newRoot = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)), second: .leaf(PaneModel(id: paneB)),
            ratio: 0.5
        )
        let oldTab = TabModel(id: tabId, paneTree: PaneTree(root: oldRoot, focusedPaneId: paneA))
        let runtime = AppRuntime(model: AppModel(
            groups: [GroupModel(id: GroupId(), name: "General", tabs: [oldTab])],
            selectedTabId: tabId
        ))
        let terminalA = FocusableTerminalView()
        let terminalB = FocusableTerminalView()
        runtime.sessions[paneA] = terminalA
        runtime.sessions[paneB] = terminalB
        let container = persistentContainer(root: oldRoot, runtime: runtime)
        let window = focusTestWindow(content: container)
        defer { window.close() }
        runtime.window = window
        container.rebuild()
        container.ensureLaidOut()
        try uiExpect(window.makeFirstResponder(terminalA), "window refused pane A")

        guard let patch = computeContainerTreePatch(
            old: containerShapeNode(oldRoot), new: containerShapeNode(newRoot)
        ) else { throw UITestFailure(message: "missing split patch") }
        container.applyTreePatch(patch, rootNode: newRoot)
        container.ensureLaidOut()
        try uiExpect(runtime.paneFocusClaimant() == .none,
            "split should expose the stranded AppKit responder mechanism")

        runtime.model.groups[0].tabs[0].paneTree = PaneTree(
            root: newRoot, focusedPaneId: paneB)
        runtime.reconcilePaneFocus()

        try uiExpect(window.firstResponder === terminalB,
            "declarative focus pass did not repair the new pane")
        guard let keyEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "x", charactersIgnoringModifiers: "x",
            isARepeat: false, keyCode: 7
        ) else { throw UITestFailure(message: "could not create key event") }
        window.sendEvent(keyEvent)
        try uiExpect(terminalB.receivedCharacters == ["x"],
            "the first key event did not reach the repaired pane")
    }

    uiTest("pane focus reconciliation repairs a reparented search field") {
        // Intent: an active search field remains the desired responder across a
        //   pane-tree patch even though AppKit discards its field editor.
        // Why it exists: search ownership is the second pane-local focus target;
        //   treating every active search as field-owned would steal focus from a
        //   terminal the user deliberately returned to.
        // Scenario: pane A's field owns focus, pane B is added, and reconciliation
        //   restores the same field from the model-declared owner.
        let paneA = PaneId(), paneB = PaneId(), tabId = TabId()
        let oldRoot = SplitNodeModel.leaf(PaneModel(id: paneA))
        let newRoot = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)), second: .leaf(PaneModel(id: paneB)),
            ratio: 0.5
        )
        let tab = TabModel(id: tabId, paneTree: PaneTree(root: oldRoot, focusedPaneId: paneA))
        var model = AppModel(
            groups: [GroupModel(id: GroupId(), name: "General", tabs: [tab])],
            selectedTabId: tabId
        )
        model.searchState[paneA] = SearchModel(needle: "hit")
        let runtime = AppRuntime(model: model)
        runtime.sessions[paneA] = FocusableTerminalView()
        runtime.sessions[paneB] = FocusableTerminalView()
        let container = persistentContainer(root: oldRoot, runtime: runtime)
        let window = focusTestWindow(content: container)
        defer { window.close() }
        runtime.window = window
        container.rebuild()
        container.ensureLaidOut()
        let wrapper = try requireWrapper(runtime, paneA)
        wrapper.showSearchOverlay(search: model.searchState[paneA]!, runtime: runtime)
        let field = wrapper.searchOverlay!.searchField
        try uiExpect(window.makeFirstResponder(field), "window refused the search field")

        guard let patch = computeContainerTreePatch(
            old: containerShapeNode(oldRoot), new: containerShapeNode(newRoot)
        ) else { throw UITestFailure(message: "missing split patch") }
        container.applyTreePatch(patch, rootNode: newRoot)
        container.ensureLaidOut()
        runtime.model.groups[0].tabs[0].paneTree = PaneTree(root: newRoot)
        runtime.reconcilePaneFocus()

        try uiExpect(field.currentEditor() === window.firstResponder,
            "declarative focus pass did not restore the search field editor")
    }

    uiTest("pane focus claimant distinguishes pane, field editor, window, and non-pane focus") {
        // Intent: claimant detection resolves pane terminal and search controls,
        //   treats the window as unclaimed, and preserves deliberate non-pane focus.
        // Why it exists: AppKit puts a shared field editor in firstResponder, so
        //   checking only responder classes would misclassify sidebar-like editors.
        // Scenario: one window cycles through every claimant kind.
        let paneId = PaneId(), tabId = TabId()
        let root = SplitNodeModel.leaf(PaneModel(id: paneId))
        let tab = TabModel(id: tabId, paneTree: PaneTree(root: root, focusedPaneId: paneId))
        var model = AppModel(
            groups: [GroupModel(id: GroupId(), name: "General", tabs: [tab])],
            selectedTabId: tabId
        )
        model.searchState[paneId] = SearchModel()
        let runtime = AppRuntime(model: model)
        let terminal = FocusableTerminalView()
        runtime.sessions[paneId] = terminal
        let container = persistentContainer(root: root, runtime: runtime)
        let nonPaneField = NSTextField(string: "sidebar")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        content.addSubview(container)
        content.addSubview(nonPaneField)
        let window = focusTestWindow(content: content)
        defer { window.close() }
        runtime.window = window
        container.rebuild()
        container.ensureLaidOut()
        let wrapper = try requireWrapper(runtime, paneId)
        wrapper.showSearchOverlay(search: model.searchState[paneId]!, runtime: runtime)
        let searchField = wrapper.searchOverlay!.searchField

        try uiExpect(window.makeFirstResponder(terminal), "window refused terminal")
        try uiExpect(runtime.paneFocusClaimant() == .pane(.terminal(paneId)),
            "terminal claimant was not resolved")
        runtime.reconcilePaneFocus()
        try uiExpect(searchField.currentEditor() === window.firstResponder,
            "reconciliation did not replace the wrong pane-owned claimant")

        try uiExpect(window.makeFirstResponder(searchField), "window refused pane search field")
        try uiExpect(runtime.paneFocusClaimant() == .pane(.searchField(paneId)),
            "pane field editor was not resolved to its control")

        window.makeFirstResponder(nil)
        try uiExpect(runtime.paneFocusClaimant() == .none, "window should mean unclaimed focus")

        try uiExpect(window.makeFirstResponder(nonPaneField), "window refused non-pane field")
        try uiExpect(runtime.paneFocusClaimant() == .nonPane,
            "non-pane field editor should remain a deliberate claimant")
        runtime.model.searchState[paneId]?.focusOwner = .terminal
        let savedResponder = window.firstResponder
        runtime.reconcilePaneFocus()
        try uiExpect(window.firstResponder === savedResponder,
            "reconciliation stole a deliberate non-pane claimant")
    }

    uiTest("pane focus query encodes every live claimant shape") {
        let paneId = PaneId(rawValue: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)

        try uiExpect(paneFocusInfoResult(.pane(.terminal(paneId))) == .object([
            "focus": .object([
                "type": .string("terminal"),
                "paneId": .string("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"),
            ]),
        ]), "terminal focus JSON changed")
        try uiExpect(paneFocusInfoResult(.pane(.searchField(paneId))) == .object([
            "focus": .object([
                "type": .string("searchField"),
                "paneId": .string("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"),
            ]),
        ]), "search-field focus JSON changed")
        try uiExpect(paneFocusInfoResult(.nonPane) == .object([
            "focus": .object(["type": .string("nonPane")]),
        ]), "non-pane focus JSON changed")
        try uiExpect(paneFocusInfoResult(.none) == .object([
            "focus": .object(["type": .string("none")]),
        ]), "unclaimed focus JSON changed")
    }

    uiTest("nested zoom fills the container and unzoom restores every pane") {
        // Intent: zooming a nested pane expands it through every ancestor split,
        //   then unzoom restores all three panes with usable geometry.
        // Why it exists: the first incremental implementation left a stale root
        //   child detached, then hid another branch without relaying out the tree.
        // Scenario: the split, split, zoom, unzoom regression reported on 2026-08-11.
        let paneA = PaneId(), paneB = PaneId(), paneC = PaneId()
        let runtime = AppRuntime()
        runtime.sessions[paneA] = TerminalView()
        runtime.sessions[paneB] = TerminalView()
        runtime.sessions[paneC] = TerminalView()
        let root = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal, first: .leaf(PaneModel(id: paneA)),
            second: .split(
                id: SplitId(), direction: .horizontal,
                first: .leaf(PaneModel(id: paneB)), second: .leaf(PaneModel(id: paneC)), ratio: 0.5),
            ratio: 0.5)
        let container = persistentContainer(root: root, runtime: runtime)
        container.rebuild()
        container.ensureLaidOut()
        let wrapperA = try requireWrapper(runtime, paneA)
        let wrapperB = try requireWrapper(runtime, paneB)
        let wrapperC = try requireWrapper(runtime, paneC)

        container.setZoomedPane(paneB)
        container.ensureLaidOut()

        try uiExpect(
            isEffectivelyHidden(wrapperA) && !isEffectivelyHidden(wrapperB) && isEffectivelyHidden(wrapperC),
            "zoom should present only the focused pane")
        try uiExpect(wrapperB.frame.width > 790, "zoomed pane should fill the container width, got \(wrapperB.frame.width)")
        try uiExpect(wrapperB.isDescendant(of: container), "focused wrapper left the container hierarchy")
        try uiExpect(wrapperA.isDescendant(of: container) && wrapperC.isDescendant(of: container), "zoom removed a sibling wrapper")

        container.setZoomedPane(nil)
        container.ensureLaidOut()

        try uiExpect(
            !isEffectivelyHidden(wrapperA) && !isEffectivelyHidden(wrapperB) && !isEffectivelyHidden(wrapperC),
            "unzoom should restore every wrapper")
        try uiExpect(
            [wrapperA, wrapperB, wrapperC].allSatisfy { $0.frame.width > 0 },
            "unzoom should restore nonzero geometry for every pane")
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

@MainActor
private func focusTestWindow(content: NSView) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = content
    return window
}

private final class FocusableTerminalView: TerminalView {
    private(set) var receivedCharacters: [String] = []

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        receivedCharacters.append(event.characters ?? "")
    }
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

private func isEffectivelyHidden(_ view: NSView) -> Bool {
    var current: NSView? = view
    while let candidate = current {
        if candidate.isHidden { return true }
        current = candidate.superview
    }
    return false
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
