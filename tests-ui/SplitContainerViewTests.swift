// UI-harness tests for model-owned pane geometry in the flat tab container.
import Cocoa
import PaneProcessLifecycle

@MainActor
func splitContainerViewTests() {
    print("SplitContainerView")

    uiTest("nested panes and dividers are direct model-laid-out children") {
        let paneA = PaneId(), paneB = PaneId(), paneC = PaneId()
        let runtime = AppRuntime()
        runtime.installTerminalSession(TerminalView(), paneId: paneA)
        runtime.installTerminalSession(TerminalView(), paneId: paneB)
        runtime.installTerminalSession(TerminalView(), paneId: paneC)
        let root = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)),
            second: .split(
                id: SplitId(), direction: .vertical,
                first: .leaf(PaneModel(id: paneB)),
                second: .leaf(PaneModel(id: paneC)), ratio: 0.7),
            ratio: 0.65)
        let container = persistentContainer(root: root, runtime: runtime)

        container.rebuild()

        let wrappers = try [paneA, paneB, paneC].map { try requireWrapper(runtime, $0) }
        try uiExpect(wrappers.allSatisfy { $0.superview === container },
            "every pane wrapper must be a direct container child")
        try uiExpect(container.subviews.compactMap { $0 as? PaneDividerView }.count == 2,
            "every split must have one direct divider")
        let expected = paneLayout(
            in: PaneLayoutRect(x: 0, y: 0, width: 800, height: 600),
            tree: root,
            zoomedPaneId: nil
        )
        for wrapper in wrappers {
            let expectedFrame = expected.paneFrames[wrapper.paneId]!
            try uiExpect(wrapper.frame == NSRect(
                x: expectedFrame.x, y: expectedFrame.y,
                width: expectedFrame.width, height: expectedFrame.height),
                "wrapper frame did not come from the pure layout")
        }
        try uiExpect(splitRatioChangedMessages(runtime.sentMessages).isEmpty,
            "layout must not report ratios back to the model")
    }

    uiTest("hidden and visible containers use identical geometry") {
        let splitId = SplitId()
        let visible = makeSplitContainer(splitId: splitId, ratio: 0.7)
        let hidden = makeSplitContainer(splitId: splitId, ratio: 0.7)
        hidden.isHidden = true

        visible.rebuild()
        hidden.rebuild()

        try uiExpect(paneDividerViews(in: visible).map(\.placement) ==
            paneDividerViews(in: hidden).map(\.placement),
            "visibility changed model-owned geometry")
    }

    uiTest("reapplying layout writes no pane frame and emits no ratio") {
        let paneA = PaneId(), paneB = PaneId(), splitId = SplitId()
        let runtime = AppRuntime()
        let terminalA = FrameRecordingTerminalView()
        let terminalB = FrameRecordingTerminalView()
        runtime.installTerminalSession(terminalA, paneId: paneA)
        runtime.installTerminalSession(terminalB, paneId: paneB)
        let root = SplitNodeModel.split(
            id: splitId, direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)), second: .leaf(PaneModel(id: paneB)),
            ratio: 0.7)
        let container = persistentContainer(root: root, runtime: runtime)
        container.rebuild()
        container.layoutSubtreeIfNeeded()
        let counts = (terminalA.frameSizes.count, terminalB.frameSizes.count)

        container.ensureLaidOut()
        container.layoutSubtreeIfNeeded()

        try uiExpect(terminalA.frameSizes.count == counts.0 && terminalB.frameSizes.count == counts.1,
            "unchanged layout wrote a terminal frame again")
        try uiExpect(splitRatioChangedMessages(runtime.sentMessages).isEmpty,
            "unchanged layout emitted ratio feedback")
    }

    uiTest("Claude Code 2026-08-16 nested split submits only true model slots") {
        // Intent: splitting one column submits one new grid for each affected pane
        //   and none for the untouched sibling, whether the tab is visible or hidden.
        // Why it exists: the 2026-08-16 Claude Code incident submitted a temporary
        //   container-wide grid before the nested pane reached its true column width.
        // Scenario: an even left-right split gains an even top-bottom split on the right.
        for hidden in [false, true] {
            let paneA = PaneId(), paneB = PaneId(), paneC = PaneId()
            let outerSplit = SplitId(), nestedSplit = SplitId()
            let controllerA = TerminalPaneSessionController()
            let controllerB = TerminalPaneSessionController()
            let controllerC = TerminalPaneSessionController()
            let runtime = AppRuntime()
            runtime.installTerminalSession(SwiftTerminalSessionView(controller: controllerA, fontSize: 13), paneId: paneA)
            runtime.installTerminalSession(SwiftTerminalSessionView(controller: controllerB, fontSize: 13), paneId: paneB)
            runtime.installTerminalSession(SwiftTerminalSessionView(controller: controllerC, fontSize: 13), paneId: paneC)
            let oldRoot = SplitNodeModel.split(
                id: outerSplit, direction: .horizontal,
                first: .leaf(PaneModel(id: paneA)), second: .leaf(PaneModel(id: paneB)),
                ratio: 0.5)
            let newRoot = SplitNodeModel.split(
                id: outerSplit, direction: .horizontal,
                first: .leaf(PaneModel(id: paneA)),
                second: .split(
                    id: nestedSplit, direction: .vertical,
                    first: .leaf(PaneModel(id: paneB)),
                    second: .leaf(PaneModel(id: paneC)), ratio: 0.5),
                ratio: 0.5)
            let container = persistentContainer(root: oldRoot, runtime: runtime)
            container.isHidden = hidden
            let window = focusTestWindow(content: container)
            defer { window.close() }
            container.rebuild()
            container.layoutSubtreeIfNeeded()
            let beforeA = controllerA.gridDimensions.count
            let beforeB = controllerB.gridDimensions.count
            let columnCount = controllerB.gridDimensions.last?.columns
            container.setRootNode(newRoot)
            container.layoutSubtreeIfNeeded()

            try uiExpect(controllerA.gridDimensions.count == beforeA,
                "untouched sibling received a grid during nested split")
            try uiExpect(controllerB.gridDimensions.count == beforeB + 1,
                "existing affected pane should receive exactly one true grid: before \(beforeB), after \(controllerB.gridDimensions.count)")
            try uiExpect(controllerC.gridDimensions.count == 1,
                "new pane should receive exactly one grid and no placeholder: \(controllerC.gridDimensions)")
            try uiExpect(controllerB.gridDimensions.last?.columns == columnCount &&
                controllerC.gridDimensions.last?.columns == columnCount,
                "nested panes received a container-wide column count")
        }
    }

    uiTest("only divider gestures change ratios and the model round trip moves them") {
        // Intent: resize, zoom, reveal, and minimum clamping emit no ratio message;
        //   a drag emits one clamped ratio and moves only through returned model layout.
        // Why it exists: AppKit layout used to overwrite stored ratios after a
        //   minimum clamp and deferred divider motion behind the reconcile timer.
        // Scenario: an extreme ratio shrinks below two minima, grows, then receives a drag.
        let paneA = PaneId(), paneB = PaneId(), splitId = SplitId()
        let runtime = AppRuntime()
        runtime.installTerminalSession(TerminalView(), paneId: paneA)
        runtime.installTerminalSession(TerminalView(), paneId: paneB)
        var root = SplitNodeModel.split(
            id: splitId, direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)), second: .leaf(PaneModel(id: paneB)),
            ratio: 0.9)
        let container = persistentContainer(root: root, runtime: runtime)
        container.rebuild()
        container.frame.size.width = 151
        container.layoutSubtreeIfNeeded()
        container.frame.size.width = 1001
        container.layoutSubtreeIfNeeded()
        container.setZoomedPane(paneA)
        container.setZoomedPane(nil)
        container.isHidden = true
        container.ensureLaidOut()
        try uiExpect(splitRatioChangedMessages(runtime.sentMessages).isEmpty,
            "non-gesture presentation wrote a ratio into the model")

        let divider = try onlyPaneDivider(in: container)
        let oldFrame = divider.frame
        runtime.onSend = { message in
            guard case .splitRatioChanged(let id, let ratio) = message, id == splitId else { return }
            root = replacingRatio(in: root, with: ratio)
            container.setRootNode(root)
        }
        divider.drag(to: NSPoint(x: 20, y: 100))

        let messages = splitRatioChangedMessages(runtime.sentMessages)
        try uiExpect(messages.count == 1 && messages[0].1 == 0.1,
            "drag should emit one ratio clamped by the pure layout inverse")
        try uiExpect(divider.frame != oldFrame,
            "divider did not move within the synchronous model round trip")
    }

    uiTest("divider hit area and accessibility value follow clamped layout") {
        let paneA = PaneId(), paneB = PaneId(), splitId = SplitId()
        let runtime = AppRuntime()
        runtime.installTerminalSession(TerminalView(), paneId: paneA)
        runtime.installTerminalSession(TerminalView(), paneId: paneB)
        let root = SplitNodeModel.split(
            id: splitId, direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)), second: .leaf(PaneModel(id: paneB)),
            ratio: 0.99)
        let container = persistentContainer(root: root, runtime: runtime)
        container.frame.size.width = 301
        container.rebuild()
        let divider = try onlyPaneDivider(in: container)
        let inside = NSPoint(x: divider.frame.midX, y: divider.frame.midY)
        let outside = NSPoint(x: divider.frame.minX - 1, y: divider.frame.midY)

        try uiExpect(container.hitTest(inside) === divider,
            "divider did not own its interaction strip")
        try uiExpect(container.hitTest(outside) is PaneWrapperView,
            "pane just outside the strip did not win hit testing")
        try uiExpect((divider.accessibilityValue() as? NSNumber)?.doubleValue == 2.0 / 3.0,
            "accessibility value did not report the clamped model layout")
    }

    uiTest("known wrapper rect derives its terminal grid after fixed chrome") {
        let paneId = PaneId()
        let controller = TerminalPaneSessionController()
        let terminal = SwiftTerminalSessionView(controller: controller, fontSize: 13)
        let runtime = AppRuntime()
        runtime.installTerminalSession(terminal, paneId: paneId)
        let container = persistentContainer(
            root: .leaf(PaneModel(id: paneId)), runtime: runtime)
        container.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = container
        defer { window.close() }

        container.rebuild()
        container.layoutSubtreeIfNeeded()

        try uiExpect(controller.gridDimensions.last == TerminalDimensions(columns: 12, rows: 10),
            "100x200 wrapper did not subtract fixed chrome: \(controller.gridDimensions)")
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
        runtime.installTerminalSession(terminal, paneId: paneId)
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

    uiTest("tree update preserves wrapper and search overlay without ratio feedback") {
        // Intent: splitting a pane updates one live tree while preserving the
        //   pane wrapper, its search overlay, and every stored split ratio.
        // Why it exists: the old whole-tab rebuild discarded pane chrome and
        //   could feed layout-produced divider positions back into the model.
        // Scenario: the incremental-container reconciliation performance fix.
        let paneA = PaneId(), paneB = PaneId(), splitId = SplitId()
        let terminalA = TerminalView(), terminalB = TerminalView()
        let runtime = AppRuntime()
        runtime.installTerminalSession(terminalA, paneId: paneA)
        runtime.installTerminalSession(terminalB, paneId: paneB)
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
        container.setRootNode(newRoot)
        container.ensureLaidOut()

        try uiExpect(runtime.findPaneWrapper(for: paneA) === wrapper, "split replaced the original wrapper")
        let wrapperB = try requireWrapper(runtime, paneB)
        try uiExpect(wrapper.isDescendant(of: container), "first split detached the original wrapper")
        try uiExpect(wrapperB.isDescendant(of: container), "first split did not mount the new wrapper")
        try uiExpect(wrapper.frame.width > 0 && wrapperB.frame.width > 0, "first split left a pane with zero width")
        try uiExpect(wrapper.searchOverlay === overlay, "split replaced the active search overlay")
        try uiExpect(wrapper.todoButtonView === todoAnchor, "split replaced the TODO popover anchor")
        try uiExpect(paneDividerViews(in: container).count == 1, "split should create one divider")
        try uiExpect(splitRatioChangedMessages(runtime.sentMessages).isEmpty, "tree layout emitted split-ratio feedback")

        let swappedRoot = SplitNodeModel.split(
            id: splitId,
            direction: .horizontal,
            first: .leaf(PaneModel(id: paneB)),
            second: .leaf(PaneModel(id: paneA)),
            ratio: 0.7
        )
        container.setRootNode(swappedRoot)
        container.ensureLaidOut()

        container.setRootNode(.leaf(PaneModel(id: paneA)))
        container.ensureLaidOut()

        try uiExpect(runtime.findPaneWrapper(for: paneA) === wrapper, "swap or sibling close replaced the wrapper")
        try uiExpect(wrapper.searchOverlay === overlay, "swap or sibling close replaced the search overlay")
        try uiExpect(wrapper.todoButtonView === todoAnchor, "swap or sibling close replaced the TODO anchor")
        try uiExpect(splitRatioChangedMessages(runtime.sentMessages).isEmpty, "swap or close layout emitted split-ratio feedback")
    }

    uiTest("flat split preserves focus before reconciliation selects the new pane") {
        // Intent: a structural split keeps the existing responder mounted, then
        //   the model-selected new pane receives focus in the same reconcile.
        // Why it exists: the 2026-08-12 incident stranded first responder while
        //   nested split views reparented the focused wrapper.
        // Scenario: pane A owns focus, a foreground split adds pane B without
        //   reparenting A, then the focus pass selects B.
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
        runtime.installTerminalSession(terminalA, paneId: paneA)
        runtime.installTerminalSession(terminalB, paneId: paneB)
        let container = persistentContainer(root: oldRoot, runtime: runtime)
        let window = focusTestWindow(content: container)
        defer { window.close() }
        runtime.window = window
        container.rebuild()
        container.ensureLaidOut()
        try uiExpect(window.makeFirstResponder(terminalA), "window refused pane A")

        container.setRootNode(newRoot)
        container.ensureLaidOut()
        try uiExpect(window.firstResponder === terminalA,
            "flat split should keep the existing terminal responder mounted")

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
        //   pane-tree update even though AppKit discards its field editor.
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
        runtime.installTerminalSession(FocusableTerminalView(), paneId: paneA)
        runtime.installTerminalSession(FocusableTerminalView(), paneId: paneB)
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

        container.setRootNode(newRoot)
        container.ensureLaidOut()
        runtime.model.groups[0].tabs[0].paneTree = PaneTree(root: newRoot)
        runtime.reconcilePaneFocus()

        try uiExpect(field.currentEditor() === window.firstResponder,
            "declarative focus pass did not restore the search field editor")
    }

    uiTest("a click in a pane's search field reports field focus for that pane") {
        // Intent: the gesture that hands a search field key focus reports it,
        //   for the focused pane and for one the user clicks into cold.
        // Why it exists: focus reports come from interaction sites now. Without
        //   this one the model only learns of field ownership at the first
        //   keystroke, and any sweep in between repairs focus back to the
        //   terminal the user just clicked away from.
        // Scenario: two panes with open search overlays, each field clicked.
        //   The fields are driven outside a window: AppKit's own mouse tracking
        //   inside NSSearchField blocks on real events the harness cannot post.
        let paneA = PaneId(), paneB = PaneId(), tabId = TabId()
        let root = SplitNodeModel.split(
            id: SplitId(), direction: .horizontal,
            first: .leaf(PaneModel(id: paneA)), second: .leaf(PaneModel(id: paneB)),
            ratio: 0.5
        )
        let tab = TabModel(id: tabId, paneTree: PaneTree(root: root, focusedPaneId: paneA))
        var model = AppModel(
            groups: [GroupModel(id: GroupId(), name: "General", tabs: [tab])],
            selectedTabId: tabId
        )
        model.searchState[paneA] = SearchModel(needle: "hit")
        model.searchState[paneB] = SearchModel(needle: "hit")
        let runtime = AppRuntime(model: model)

        for paneId in [paneA, paneB] {
            runtime.sentMessages = []
            let overlay = SearchOverlayView(paneId: paneId, runtime: runtime)

            overlay.searchField.mouseDown(with: try makeSearchFieldClick())

            try uiExpect(runtime.sentMessages.count == 1,
                "one field click should report once, got \(runtime.sentMessages)")
            guard case .searchFieldBecameFirstResponder(let reported) =
                runtime.sentMessages.first else {
                throw UITestFailure(message: "field click reported \(runtime.sentMessages)")
            }
            try uiExpect(reported == paneId, "the field click reported the wrong pane")
        }
    }

    uiTest("the focus pass's search-field repair dispatches nothing") {
        // Intent: a sweep that repairs the responder to a pane's search field
        //   originates no Msg.
        // Why it exists: I1 -- a reconcile pass that sends re-enters the whole
        //   sweep from inside itself, against caches the outer pass has not
        //   advanced. The search-field arm is the half a terminal-only proof
        //   would leave uncovered.
        // Scenario: the model names pane A's field, the responder sits on the
        //   terminal, and the pass moves it.
        let paneId = PaneId(), tabId = TabId()
        let root = SplitNodeModel.leaf(PaneModel(id: paneId))
        let tab = TabModel(id: tabId, paneTree: PaneTree(root: root, focusedPaneId: paneId))
        var model = AppModel(
            groups: [GroupModel(id: GroupId(), name: "General", tabs: [tab])],
            selectedTabId: tabId
        )
        model.searchState[paneId] = SearchModel(needle: "hit")
        let runtime = AppRuntime(model: model)
        let terminal = FocusableTerminalView()
        runtime.installTerminalSession(terminal, paneId: paneId)
        let container = persistentContainer(root: root, runtime: runtime)
        let window = focusTestWindow(content: container)
        defer { window.close() }
        runtime.window = window
        container.rebuild()
        container.ensureLaidOut()
        let wrapper = try requireWrapper(runtime, paneId)
        wrapper.showSearchOverlay(search: model.searchState[paneId]!, runtime: runtime)
        try uiExpect(window.makeFirstResponder(terminal), "window refused the terminal")
        runtime.sentMessages = []

        runtime.reconcilePaneFocus()

        try uiExpect(runtime.paneFocusClaimant() == .pane(.searchField(paneId)),
            "the pass did not repair the responder to the search field")
        try uiExpect(runtime.sentMessages.isEmpty,
            "the search-field repair originated \(runtime.sentMessages)")
        try uiExpect(runtime.model.searchState[paneId]?.focusOwner == .field,
            "the repair changed search focus ownership")
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
        runtime.installTerminalSession(terminal, paneId: paneId)
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
        let controllerA = TerminalPaneSessionController()
        let controllerB = TerminalPaneSessionController()
        let controllerC = TerminalPaneSessionController()
        let runtime = AppRuntime()
        runtime.installTerminalSession(SwiftTerminalSessionView(controller: controllerA, fontSize: 13), paneId: paneA)
        runtime.installTerminalSession(SwiftTerminalSessionView(controller: controllerB, fontSize: 13), paneId: paneB)
        runtime.installTerminalSession(SwiftTerminalSessionView(controller: controllerC, fontSize: 13), paneId: paneC)
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
        let beforeA = controllerA.gridDimensions.count
        let beforeC = controllerC.gridDimensions.count

        container.setZoomedPane(paneB)
        container.ensureLaidOut()

        try uiExpect(
            isEffectivelyHidden(wrapperA) && !isEffectivelyHidden(wrapperB) && isEffectivelyHidden(wrapperC),
            "zoom should present only the focused pane")
        try uiExpect(wrapperB.frame.width > 790, "zoomed pane should fill the container width, got \(wrapperB.frame.width)")
        try uiExpect(wrapperB.isDescendant(of: container), "focused wrapper left the container hierarchy")
        try uiExpect(wrapperA.isDescendant(of: container) && wrapperC.isDescendant(of: container), "zoom removed a sibling wrapper")
        try uiExpect(
            controllerA.gridDimensions.count == beforeA && controllerC.gridDimensions.count == beforeC,
            "zoom submitted a grid for a pane it hid")

        container.setZoomedPane(nil)
        container.ensureLaidOut()

        try uiExpect(
            !isEffectivelyHidden(wrapperA) && !isEffectivelyHidden(wrapperB) && !isEffectivelyHidden(wrapperC),
            "unzoom should restore every wrapper")
        try uiExpect(
            [wrapperA, wrapperB, wrapperC].allSatisfy { $0.frame.width > 0 },
            "unzoom should restore nonzero geometry for every pane")
    }

    uiTest("cross-tab tree updates preserve a moved wrapper in either order") {
        // Intent: moving a pane between tabs reparents its one wrapper even when
        //   the destination update runs before the source update.
        // Why it exists: container op order follows dictionary iteration, so one
        //   tab must not tear a wrapper back out of its new parent.
        // Scenario: the incremental-container reconciliation performance fix.
        let paneA = PaneId(), paneB = PaneId(), paneC = PaneId()
        let runtime = AppRuntime()
        runtime.installTerminalSession(TerminalView(), paneId: paneA)
        runtime.installTerminalSession(TerminalView(), paneId: paneB)
        runtime.installTerminalSession(TerminalView(), paneId: paneC)
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
        destination.setRootNode(destinationNew)
        source.setRootNode(sourceNew)

        try uiExpect(runtime.findPaneWrapper(for: paneA) === movedWrapper, "move replaced the pane wrapper")
        try uiExpect(movedWrapper.isDescendant(of: destination), "source update detached the moved wrapper from its destination")
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
            runtime.installTerminalSession(TerminalView(), paneId: paneId)
            hostObserver = runtime.paneHost(for: paneId)
            wrapperObserver = hostObserver?.wrapper
            runtime.tearDownSession(paneId)
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

/// One left-button press on a search field, built without a window so the click
/// can be delivered directly to the production view.
private func makeSearchFieldClick() throws -> NSEvent {
    guard let event = NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 20, y: 10), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1
    ) else { throw UITestFailure(message: "could not create a mouse event") }
    return event
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

private func paneDividerViews(in view: NSView) -> [PaneDividerView] {
    view.subviews.compactMap { $0 as? PaneDividerView }
}

private func onlyPaneDivider(in view: NSView) throws -> PaneDividerView {
    let dividers = paneDividerViews(in: view)
    try uiExpect(dividers.count == 1, "expected one divider, got \(dividers.count)")
    return dividers[0]
}

private func replacingRatio(in node: SplitNodeModel, with ratio: CGFloat) -> SplitNodeModel {
    guard case .split(let id, let direction, let first, let second, _) = node else {
        return node
    }
    return .split(id: id, direction: direction, first: first, second: second, ratio: ratio)
}

private func isEffectivelyHidden(_ view: NSView) -> Bool {
    var current: NSView? = view
    while let candidate = current {
        if candidate.isHidden { return true }
        current = candidate.superview
    }
    return false
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

private final class FrameRecordingTerminalView: TerminalView {
    private(set) var frameSizes: [NSSize] = []

    override func setFrameSize(_ newSize: NSSize) {
        frameSizes.append(newSize)
        super.setFrameSize(newSize)
    }
}
