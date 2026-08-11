// UI-harness tests for PaneWrapperView's unified pane context menu
// (makePaneMenu): composition per entry point, item enablement from model
// state, action routing, and menu-lifetime retention of the ephemeral wrapper.
import Cocoa

@MainActor
func paneWrapperViewTests() {
    print("PaneWrapperView")

    uiTest("includeClipboard menu has full composition, all enabled") {
        // Intent: the terminal right-click menu (includeClipboard: true) is the
        //   toolbar menu plus a Copy/Paste clipboard section on top, with every
        //   item enabled when the pane has a selection, cwd, agent session, and
        //   splits.
        // Why it exists: pins the unified-menu contract -- one builder serves
        //   all three entry points and only the terminal entry point gets
        //   clipboard items. Spec-first.
        let fx = makePaneMenuFixture()
        fx.terminal.hasSelection = true

        let menu = fx.wrapper.makePaneMenu(includeClipboard: true)

        let items = nonSeparatorItems(menu)
        try uiExpect(
            items.map(\.title) == [
                "Copy", "Paste", "Split Right", "Split Down",
                "Copy cwd", "Copy Pane ID", "Copy Agent Session ID",
                "Zoom Pane", "Close Pane",
            ],
            "unexpected titles: \(items.map(\.title))")
        try uiExpect(items.allSatisfy(\.isEnabled), "all items should be enabled, got \(items.map { ($0.title, $0.isEnabled) })")
    }

    uiTest("includeClipboard menu disables Copy without a selection") {
        // Intent: without a terminal selection, Copy is present but disabled,
        //   and the menu's shape (item count) is identical to the with-selection
        //   menu.
        // Why it exists: pins the user decision that Copy is disabled rather
        //   than hidden, so the terminal menu's shape is stable. The old inline
        //   terminal menu hid Copy entirely. Spec-first.
        let fx = makePaneMenuFixture()
        fx.terminal.hasSelection = true
        let withSelectionCount = fx.wrapper.makePaneMenu(includeClipboard: true).items.count

        fx.terminal.hasSelection = false
        let menu = fx.wrapper.makePaneMenu(includeClipboard: true)

        let copy = try onlyItem(menu, titled: "Copy")
        try uiExpect(!copy.isEnabled, "Copy should be disabled without a selection")
        try uiExpect(menu.items.count == withSelectionCount,
                     "menu shape should be selection-independent: \(menu.items.count) vs \(withSelectionCount)")
    }

    uiTest("toolbar menu has no clipboard items") {
        // Intent: includeClipboard: false and the no-arg default both produce
        //   today's toolbar menu composition, with no Copy/Paste items.
        // Why it exists: pins that the toolbar "..." button and drag-handle
        //   right-click menus are unchanged by the unification. Spec-first.
        let fx = makePaneMenuFixture()
        fx.terminal.hasSelection = true

        let expectedTitles = [
            "Split Right", "Split Down",
            "Copy cwd", "Copy Pane ID", "Copy Agent Session ID",
            "Zoom Pane", "Close Pane",
        ]
        for menu in [fx.wrapper.makePaneMenu(includeClipboard: false), fx.wrapper.makePaneMenu()] {
            let items = nonSeparatorItems(menu)
            try uiExpect(items.map(\.title) == expectedTitles, "unexpected titles: \(items.map(\.title))")
        }
    }

    uiTest("menu actions route to the clicked pane and its terminal") {
        // Intent: performing menu items dispatches the right effects -- Copy and
        //   Paste act on the pane's terminal view; Split Right, Close Pane, and
        //   Zoom send pane-scoped messages carrying this pane's id.
        // Why it exists: pins behavioral routing (not target/selector identity),
        //   including that Zoom is pane-scoped (.toggleZoomPane(paneId:)) so a
        //   stale menu acts on the pane it was built for, not whatever tab is
        //   selected when the action fires. Spec-first.
        let fx = makePaneMenuFixture()
        fx.terminal.hasSelection = true
        let menu = fx.wrapper.makePaneMenu(includeClipboard: true)

        for title in ["Copy", "Paste", "Split Right", "Zoom Pane", "Close Pane"] {
            let item = try onlyItem(menu, titled: title)
            _ = item.target?.perform(item.action, with: item)
        }

        try uiExpect(fx.terminal.performedActions == ["copySelection", "pasteClipboard"],
                     "clipboard items should act on the terminal, got \(fx.terminal.performedActions)")
        var sawSplit = false, sawZoom = false, sawClose = false
        for msg in fx.runtime.sentMessages {
            switch msg {
            case .splitPane(let paneId, let direction, _, _):
                sawSplit = paneId == fx.paneId && direction == .horizontal
            case .toggleZoomPane(let paneId):
                sawZoom = paneId == fx.paneId
            case .requestClosePane(let paneId):
                sawClose = paneId == fx.paneId
            default:
                break
            }
        }
        try uiExpect(sawSplit, "Split Right should send .splitPane(paneId:, .horizontal)")
        try uiExpect(sawZoom, "Zoom should send .toggleZoomPane(paneId:) scoped to this pane")
        try uiExpect(sawClose, "Close Pane should send .requestClosePane(paneId:)")
    }

    uiTest("model-dependent items follow pane state") {
        // Intent: a pane with no cwd gets a disabled Copy cwd item; a pane with
        //   no agent session gets no Copy Agent Session ID item at all.
        // Why it exists: pins the two model-driven item states on the unified
        //   menu's terminal entry point (previously toolbar-menu-only behavior).
        //   Spec-first.
        let fx = makePaneMenuFixture(cwd: nil, agentSession: nil)

        let menu = fx.wrapper.makePaneMenu(includeClipboard: true)

        let copyCwd = try onlyItem(menu, titled: "Copy cwd")
        try uiExpect(!copyCwd.isEnabled, "Copy cwd should be disabled when the pane has no cwd")
        try uiExpect(menu.items.allSatisfy { $0.title != "Copy Agent Session ID" },
                     "agent session item should be absent when the pane has no agent session")
    }

    uiTest("agent menu visibility and copied id follow the session model") {
        let agent = AgentSession(kind: "claude", sessionId: "snapshot-session")!
        let fx = makePaneMenuFixture(agentSession: agent)
        fx.wrapper.menuPasteboard = NSPasteboard(
            name: .init("com.danterm.tests.agent-session.\(UUID().uuidString)")
        )

        let attachedMenu = fx.wrapper.makePaneMenu(includeClipboard: true)
        let copy = try onlyItem(attachedMenu, titled: "Copy Agent Session ID")
        _ = copy.target?.perform(copy.action, with: copy)
        try uiExpect(
            fx.wrapper.menuPasteboard.string(forType: .string) == "snapshot-session",
            "copied id should come from the session model"
        )

        let sessionId = fx.runtime.model.pane(fx.paneId)!.session!.id
        fx.runtime.model.updateSession(sessionId) {
            reduceSession(&$0, report: .agentDetached(agent))
        }
        let detachedMenu = fx.wrapper.makePaneMenu(includeClipboard: true)
        try uiExpect(
            detachedMenu.items.allSatisfy { $0.title != "Copy Agent Session ID" },
            "agent item should disappear after the snapshot detaches"
        )
    }

    uiTest("Copy Pane ID copies the wrapper's full pane UUID") {
        let fx = makePaneMenuFixture()
        fx.wrapper.menuPasteboard = NSPasteboard(
            name: .init("com.danterm.tests.pane-id.\(UUID().uuidString)")
        )

        let menu = fx.wrapper.makePaneMenu(includeClipboard: true)
        let copy = try onlyItem(menu, titled: "Copy Pane ID")
        _ = copy.target?.perform(copy.action, with: copy)

        try uiExpect(
            fx.wrapper.menuPasteboard.string(forType: .string) == fx.paneId.rawValue.uuidString,
            "Copy Pane ID should copy the pane represented by this menu"
        )
    }

    uiTest("zoom item reflects zoom and split state") {
        // Intent: a single-pane unzoomed wrapper shows a disabled "Zoom Pane";
        //   a zoomed wrapper shows an enabled "Unzoom Pane".
        // Why it exists: pins the zoom affordance states on the unified menu
        //   so the terminal right-click matches the toolbar menu. Spec-first.
        let single = makePaneMenuFixture(isZoomed: false, hasSplits: false)
        let zoomItem = try onlyItem(single.wrapper.makePaneMenu(includeClipboard: true), titled: "Zoom Pane")
        try uiExpect(!zoomItem.isEnabled, "Zoom Pane should be disabled with no splits and not zoomed")

        let zoomed = makePaneMenuFixture(isZoomed: true, hasSplits: true)
        let unzoomItem = try onlyItem(zoomed.wrapper.makePaneMenu(includeClipboard: true), titled: "Unzoom Pane")
        try uiExpect(unzoomItem.isEnabled, "Unzoom Pane should be enabled while zoomed")
    }

    uiTest("init points the terminal back at its wrapper") {
        // Intent: after PaneWrapperView.init, terminalView.paneWrapper === the
        //   wrapper.
        // Why it exists: TerminalView.menu(for:) reaches its menu through this
        //   back-pointer; this pins the seam the terminal right-click relies on.
        //   Spec-first.
        let fx = makePaneMenuFixture()
        try uiExpect(fx.terminal.paneWrapper === fx.wrapper, "terminalView.paneWrapper should point at the wrapper")
    }

    uiTest("menu keeps the wrapper alive and actions still fire after teardown") {
        // Intent: a built menu strongly retains the ephemeral wrapper, so its
        //   actions still dispatch after a reconcile releases the wrapper while
        //   the menu is tracking.
        // Why it exists: NSMenuItem.target is weak; without a strong anchor a
        //   reconcile mid-track deallocates the wrapper and every action becomes
        //   a silent no-op (latent in the old toolbar menu too). Spec-first.
        // The wrapper is constructed and released inside an autoreleasepool:
        // AppKit init paths routinely autorelease view references, and without
        // draining them the wrapper would survive anyway and the pre-fix run
        // would silently pass.
        let model = makeSinglePaneModel()
        let runtime = AppRuntime(model: model.model)
        let terminal = TerminalView()
        var menu: NSMenu?
        weak var observer: PaneWrapperView?

        autoreleasepool {
            let wrapper = PaneWrapperView(
                paneId: model.paneId, terminalView: terminal,
                isZoomed: false, hasSplits: true, runtime: runtime)
            observer = wrapper
            menu = wrapper.makePaneMenu(includeClipboard: true)
        }

        try uiExpect(observer != nil, "menu items should be retaining the wrapper after the pool drains")
        guard let menu else { throw UITestFailure(message: "menu missing") }
        let close = try onlyItem(menu, titled: "Close Pane")
        _ = close.target?.perform(close.action, with: close)
        var sawClose = false
        for msg in runtime.sentMessages {
            if case .requestClosePane(let paneId) = msg, paneId == model.paneId { sawClose = true }
        }
        try uiExpect(sawClose, "Close Pane should still dispatch after the wrapper's owner released it")
    }
}

// MARK: - Fixtures

private struct PaneMenuFixture {
    let wrapper: PaneWrapperView
    let runtime: AppRuntime
    let terminal: TerminalView
    let paneId: PaneId
}

/// One group / one tab / one pane-under-test (plus a sibling leaf when
/// hasSplits) so model-driven items (Copy cwd, agent session) see real state.
private func makeSinglePaneModel(
    cwd: String? = "/tmp/project",
    hasSplits: Bool = true
) -> (model: AppModel, paneId: PaneId) {
    let paneId = PaneId()
    var pane = PaneModel(id: paneId, session: SessionModel(id: SessionId()))
    pane.cwd = cwd

    let rootNode: SplitNodeModel = hasSplits
        ? .split(id: SplitId(), direction: .horizontal,
                 first: .leaf(pane),
                 second: .leaf(PaneModel(id: PaneId(), session: SessionModel(id: SessionId()))),
                 ratio: 0.5)
        : .leaf(pane)
    let tab = TabModel(id: TabId(), customTitle: nil, focusedPaneId: paneId, rootNode: rootNode)
    let group = GroupModel(id: GroupId(), name: "g", tabs: [tab])
    var model = AppModel(groups: [group])
    model.selectedTabId = tab.id
    return (model, paneId)
}

@MainActor
private func makePaneMenuFixture(
    cwd: String? = "/tmp/project",
    agentSession: AgentSession? = AgentSession(kind: "claude", sessionId: "abc123"),
    isZoomed: Bool = false,
    hasSplits: Bool = true
) -> PaneMenuFixture {
    let (model, paneId) = makeSinglePaneModel(cwd: cwd, hasSplits: hasSplits)
    let runtime = AppRuntime(model: model)
    let terminal = TerminalView()
    if let agentSession, let sessionId = runtime.model.pane(paneId)?.session?.id {
        runtime.model.updateSession(sessionId) {
            reduceSession(&$0, report: .agentAttached(agentSession))
        }
    }
    let wrapper = PaneWrapperView(
        paneId: paneId, terminalView: terminal,
        isZoomed: isZoomed, hasSplits: hasSplits, runtime: runtime)
    return PaneMenuFixture(wrapper: wrapper, runtime: runtime, terminal: terminal, paneId: paneId)
}

private func nonSeparatorItems(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.filter { !$0.isSeparatorItem }
}

private func onlyItem(_ menu: NSMenu, titled title: String) throws -> NSMenuItem {
    let matches = menu.items.filter { $0.title == title }
    try uiExpect(matches.count == 1, "expected exactly one \"\(title)\" item, got \(matches.count)")
    return matches[0]
}
