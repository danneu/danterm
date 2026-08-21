// UI regressions for sidebar context-menu enablement. These tests exercise real
// detached NSMenus after AppKit validation so manually disabled items cannot be
// re-enabled by autoenablesItems drift.
import Cocoa
import ChipArtwork
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

@MainActor
func sidebarContextMenuTests() async {
    print("SidebarContextMenu")

    await uiTest("single group keeps Delete Group disabled after menu update") {
        // Intent: a single-group sidebar context menu keeps Delete Group disabled
        //   even after AppKit's menu validation pass.
        // Why it exists: pins the drift-audit bug where `isEnabled = false` was
        //   overwritten because the detached NSMenu still had autoenablesItems on.
        // Scenario: drift-audit incident -- right-clicking the only group showed
        //   Delete Group as enabled, but clicking it silently no-oped in update.
        let (sidebar, model) = makeSidebarContextMenuHarness(groupCount: 1)

        let menu = try uiRequire(sidebar.contextMenu(forGroupId: model.groups[0].id),
            "expected group context menu")
        menu.update()

        let deleteItem = try onlyContextMenuItem(menu, titled: "Delete Group")
        try uiExpect(deleteItem.isEnabled == false,
            "Delete Group should stay disabled when only one group exists")
    }

    await uiTest("multiple groups keep Delete Group enabled after menu update") {
        let (sidebar, model) = makeSidebarContextMenuHarness(groupCount: 2)

        let menu = try uiRequire(sidebar.contextMenu(forGroupId: model.groups[0].id),
            "expected group context menu")
        menu.update()

        let deleteItem = try onlyContextMenuItem(menu, titled: "Delete Group")
        try uiExpect(deleteItem.isEnabled,
            "Delete Group should be enabled when multiple groups exist")
    }

    await uiTest("a right-click on a tab marks the clicked row so AppKit outlines it") {
        // Intent: after a right-click on a sidebar tab, the outline view knows
        //   which row was clicked.
        // Why it exists: AppKit draws the context-menu outline only from
        //   NSOutlineView's inherited menu(for:), which is also what sets
        //   clickedRow. An override that builds the menu itself and never
        //   delegates leaves clickedRow at -1 and the row undrawn, so a menu
        //   straddling two tabs gives no sign which tab it acts on.
        // Scenario: the user right-clicks the second tab in a group.
        let (sidebar, outline, window) = makeSidebarRightClickHarness()
        defer { window.close() }

        try uiExpect(outline.numberOfRows >= 2,
            "precondition: two tabs should give at least 2 rows, got \(outline.numberOfRows)")
        let tabRow = outline.numberOfRows - 1
        let rowRect = outline.rect(ofRow: tabRow)
        try uiExpect(rowRect.height > 0, "precondition: the last row should have a frame")
        let point = outline.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1)
        else {
            throw UITestFailure(message: "could not synthesize a right-click event")
        }
        let menu = try uiRequire(outline.menu(for: event), "a tab row should yield a context menu")
        _ = try onlyContextMenuItem(menu, titled: "Rename Tab")

        try uiExpect(outline.clickedRow == tabRow,
            "clickedRow should be the right-clicked row \(tabRow), got \(outline.clickedRow)")
        try uiExpect(outline.menu == nil,
            "the outline view should hold no menu once menu(for:) returns")
        _ = sidebar
    }

    await uiTest("group menu items dispatch their message for the clicked group") {
        // Intent: firing a group context-menu item sends the message that item
        //   names, carrying the group the menu was built for.
        // Why it exists: the item's action and its payload used to be set
        //   independently, so a mis-paired item would act on the wrong entity or
        //   on nothing. This pins the dispatch each item performs.
        // Scenario: the user right-clicks a group and picks New Tab, then
        //   Delete Group.
        let (sidebar, runtime, model) = makeSidebarGroupMenuHarness(groupCount: 2)
        let groupId = model.groups[0].id
        let menu = try uiRequire(sidebar.contextMenu(forGroupId: groupId),
            "expected group context menu")

        try fireContextMenuItem(onlyContextMenuItem(menu, titled: "New Tab"))
        guard case .createTab(let newTabGroupId, _, _, _) = try onlySentMessage(runtime) else {
            throw UITestFailure(message: "New Tab sent \(runtime.sentMessages)")
        }
        try uiExpect(newTabGroupId == groupId,
            "New Tab should target the clicked group, got \(newTabGroupId)")

        runtime.sentMessages = []
        try fireContextMenuItem(onlyContextMenuItem(menu, titled: "Delete Group"))
        guard case .requestDeleteGroup(let deletedId) = try onlySentMessage(runtime) else {
            throw UITestFailure(message: "Delete Group sent \(runtime.sentMessages)")
        }
        try uiExpect(deletedId == groupId,
            "Delete Group should target the clicked group, got \(deletedId)")
    }

    await uiTest("Rename Group sends its message after menu tracking ends") {
        // Intent: Rename Group dispatches on a later main-queue turn, not from
        //   the menu action itself.
        // Why it exists: the model's rename begin drives a reconcile pass that
        //   installs a field editor while AppKit is still tearing the menu down,
        //   so the hop off menu tracking is load-bearing.
        // Scenario: the user right-clicks a group and picks Rename Group.
        let (sidebar, runtime, model) = makeSidebarGroupMenuHarness(groupCount: 2)
        let groupId = model.groups[0].id
        let menu = try uiRequire(sidebar.contextMenu(forGroupId: groupId),
            "expected group context menu")

        try fireContextMenuItem(onlyContextMenuItem(menu, titled: "Rename Group"))
        try uiExpect(runtime.sentMessages.isEmpty,
            "Rename Group dispatched synchronously: \(runtime.sentMessages)")

        try await pumpMainQueue(untilTrue: { !runtime.sentMessages.isEmpty })
        guard case .beginSidebarRename(.group(let renamedId)) = try onlySentMessage(runtime) else {
            throw UITestFailure(message: "Rename Group sent \(runtime.sentMessages)")
        }
        try uiExpect(renamedId == groupId,
            "Rename Group should target the clicked group, got \(renamedId)")
    }

    await uiTest("tab menu items dispatch their message for the selected tabs") {
        // Intent: firing each batch item in the tab context menu sends that
        //   item's message carrying the multi-select resolution.
        // Why it exists: every batch item used to carry the same untyped id box,
        //   so an item wired to the wrong handler still ran. This pins which
        //   message each item sends and which ids it carries.
        // Scenario: the user selects two tabs, right-clicks one of them, and
        //   works through the menu.
        let fx = try makeSidebarTabMenuHarness()
        let menu = try uiRequire(
            fx.sidebar.contextMenu(forTabId: fx.tabIds[0], clickedRow: fx.clickedRow),
            "expected tab context menu")
        let selected = [fx.tabIds[0], fx.tabIds[1]]

        try fireContextMenuItem(onlyContextMenuItem(menu, titledPrefix: "Clear Custom Title"))
        guard case .clearCustomTitles(let clearedTitleIds) = try onlySentMessage(fx.runtime) else {
            throw UITestFailure(message: "Clear Custom Title sent \(fx.runtime.sentMessages)")
        }
        try uiExpect(clearedTitleIds == selected,
            "Clear Custom Title should target the selection, got \(clearedTitleIds)")

        let colorSubmenu = try uiRequire(
            onlyContextMenuItem(menu, titledPrefix: "Color").submenu,
            "expected a Color submenu")

        fx.runtime.sentMessages = []
        try fireContextMenuItem(onlyContextMenuItem(colorSubmenu, titled: "Red"))
        guard case .requestSetTabColors(let swatchIds, let swatchColor)
            = try onlySentMessage(fx.runtime) else {
            throw UITestFailure(message: "Red swatch sent \(fx.runtime.sentMessages)")
        }
        try uiExpect(swatchIds == selected && swatchColor == .red,
            "the Red swatch should set red on the selection, got \(swatchIds) \(String(describing: swatchColor))")

        fx.runtime.sentMessages = []
        try fireContextMenuItem(onlyContextMenuItem(colorSubmenu, titled: "Clear Color"))
        guard case .requestSetTabColors(let clearedColorIds, let clearedColor)
            = try onlySentMessage(fx.runtime) else {
            throw UITestFailure(message: "Clear Color sent \(fx.runtime.sentMessages)")
        }
        try uiExpect(clearedColorIds == selected && clearedColor == nil,
            "Clear Color should clear the selection, got \(clearedColorIds) \(String(describing: clearedColor))")

        fx.runtime.sentMessages = []
        try fireContextMenuItem(onlyContextMenuItem(menu, titledPrefix: "Clear Alerts"))
        guard case .clearAlertsForTabs(let alertIds) = try onlySentMessage(fx.runtime) else {
            throw UITestFailure(message: "Clear Alerts sent \(fx.runtime.sentMessages)")
        }
        try uiExpect(alertIds == selected,
            "Clear Alerts should target the selection, got \(alertIds)")

        fx.runtime.sentMessages = []
        try fireContextMenuItem(onlyContextMenuItem(menu, titledPrefix: "Move to New Group"))
        guard case .extractTabsToNewGroupInteractively(let extractedIds, let groupName)
            = try onlySentMessage(fx.runtime) else {
            throw UITestFailure(message: "Move to New Group sent \(fx.runtime.sentMessages)")
        }
        try uiExpect(extractedIds == selected && !groupName.isEmpty,
            "Move to New Group should extract the selection, got \(extractedIds) \"\(groupName)\"")

        fx.runtime.sentMessages = []
        try fireContextMenuItem(onlyContextMenuItem(menu, titledPrefix: "Close"))
        guard case .requestCloseTabs(let closedIds) = try onlySentMessage(fx.runtime) else {
            throw UITestFailure(message: "Close sent \(fx.runtime.sentMessages)")
        }
        try uiExpect(closedIds == selected,
            "Close should target the selection, got \(closedIds)")
    }

    await uiTest("Rename Tab targets the clicked row and sends after menu tracking ends") {
        // Intent: Rename Tab acts on the clicked row alone, and dispatches on a
        //   later main-queue turn like Rename Group does.
        // Why it exists: Rename Tab is the one item that ignores the multi-select
        //   resolution, and it shares the rename hop off menu tracking.
        // Scenario: the user selects two tabs and picks Rename Tab on one of them.
        let fx = try makeSidebarTabMenuHarness()
        let menu = try uiRequire(
            fx.sidebar.contextMenu(forTabId: fx.tabIds[0], clickedRow: fx.clickedRow),
            "expected tab context menu")

        try fireContextMenuItem(onlyContextMenuItem(menu, titled: "Rename Tab"))
        try uiExpect(fx.runtime.sentMessages.isEmpty,
            "Rename Tab dispatched synchronously: \(fx.runtime.sentMessages)")

        try await pumpMainQueue(untilTrue: { !fx.runtime.sentMessages.isEmpty })
        guard case .beginSidebarRename(.tab(let renamedId)) = try onlySentMessage(fx.runtime) else {
            throw UITestFailure(message: "Rename Tab sent \(fx.runtime.sentMessages)")
        }
        try uiExpect(renamedId == fx.tabIds[0],
            "Rename Tab should target the clicked tab, got \(renamedId)")
    }
}

/// Sidebar in a real window with one group holding two tabs, rows materialized,
/// so a synthesized right-click lands on a known row index (row 0 is the group).
@MainActor
private func makeSidebarRightClickHarness() -> (SidebarView, NSOutlineView, NSWindow) {
    let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 420))
    sidebar.runtime = makeUITestRuntime()
    let window = NSWindow(
        contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = sidebar
    window.layoutIfNeeded()

    let tabs = (0..<2).map { index -> TabModel in
        let paneId = PaneId()
        var pane = PaneModel(id: paneId)
        pane.session = SessionModel(id: SessionId(), title: "tab \(index)")
        return TabModel(id: TabId(), paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId))
    }
    let model = AppModel(
        groups: [GroupModel(id: GroupId(), name: "Group", tabs: tabs)],
        selectedTabId: tabs[0].id)
    let driver = SidebarReconcileDriver()
    _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: sidebarOutlineView(in: sidebar)!)

    let outline = sidebarOutlineView(in: sidebar)!
    return (sidebar, outline, window)
}

@MainActor
private func makeSidebarContextMenuHarness(groupCount: Int) -> (SidebarView, AppModel) {
    let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 420))
    let groups = (0..<groupCount).map { index in
        GroupModel(id: GroupId(), name: "Group \(index + 1)")
    }
    let model = AppModel(groups: groups)
    let driver = SidebarReconcileDriver()
    _ = applySidebarTestModel(
        model,
        using: driver,
        to: sidebar,
        outline: sidebarOutlineView(in: sidebar)!)
    return (sidebar, model)
}

/// Group-menu harness with a recording runtime, so firing an item is observable
/// as a dispatched message.
@MainActor
private func makeSidebarGroupMenuHarness(
    groupCount: Int
) -> (sidebar: SidebarView, runtime: RecordingAppRuntime, model: AppModel) {
    let (sidebar, model) = makeSidebarContextMenuHarness(groupCount: groupCount)
    let runtime = makeUITestRuntime()
    sidebar.runtime = runtime
    return (sidebar, runtime, model)
}

/// Tab-menu harness: three tabs in one group, the first two selected and the
/// first one clicked. The fixture gives every conditional item a reason to
/// appear -- a custom title, a color, and an unread alert -- and the third,
/// unselected tab keeps `Move to New Group` from extracting every live tab.
@MainActor
private func makeSidebarTabMenuHarness() throws -> (
    sidebar: SidebarView, runtime: RecordingAppRuntime, tabIds: [TabId], clickedRow: Int
) {
    let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 420))
    let runtime = makeUITestRuntime()
    sidebar.runtime = runtime

    var panes: [PaneId] = []
    let tabs = (0..<3).map { index -> TabModel in
        let paneId = PaneId()
        panes.append(paneId)
        var pane = PaneModel(id: paneId)
        pane.session = SessionModel(id: SessionId(), title: "tab \(index)")
        return TabModel(
            id: TabId(),
            customTitle: "custom \(index)",
            paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId),
            color: .blue)
    }
    var model = AppModel(
        groups: [GroupModel(id: GroupId(), name: "Group", tabs: tabs)],
        selectedTabId: tabs[0].id)
    model.alerts = [sidebarBellAlert(paneId: panes[0])]

    let outline = sidebarOutlineView(in: sidebar)!
    _ = applySidebarTestModel(
        model, using: SidebarReconcileDriver(), to: sidebar, outline: outline)

    let tabIds = tabs.map(\.id)
    let clickedRow = try sidebarTabRow(for: tabIds[0], in: outline)
    let secondRow = try sidebarTabRow(for: tabIds[1], in: outline)
    outline.selectRowIndexes(IndexSet([clickedRow, secondRow]), byExtendingSelection: false)

    return (sidebar, runtime, tabIds, clickedRow)
}

/// Fires a menu item the way AppKit does, through its own target and action.
@MainActor
private func fireContextMenuItem(_ item: NSMenuItem) throws {
    guard let target = item.target as? NSObject, let action = item.action else {
        throw UITestFailure(message: "\"\(item.title)\" has no target/action")
    }
    target.perform(action, with: item)
}

/// Reads the single message a fired item dispatched, so a test that expects one
/// dispatch fails loudly on zero or many.
@MainActor
private func onlySentMessage(_ runtime: RecordingAppRuntime) throws -> Msg {
    try uiExpect(runtime.sentMessages.count == 1,
        "expected exactly one message, got \(runtime.sentMessages)")
    return runtime.sentMessages[0]
}

private func uiRequire<T>(
    _ value: T?,
    _ message: String,
    file: String = #file,
    line: Int = #line
) throws -> T {
    guard let value else {
        throw UITestFailure(message: "\(message) (\(file):\(line))")
    }
    return value
}

private func onlyContextMenuItem(_ menu: NSMenu, titled title: String) throws -> NSMenuItem {
    let matches = menu.items.filter { $0.title == title }
    try uiExpect(matches.count == 1, "expected exactly one \"\(title)\" item, got \(matches.count)")
    return matches[0]
}

/// Finds an item whose title carries the multi-select "(N tabs)" suffix, so a
/// test names the action without restating the suffix rule.
private func onlyContextMenuItem(
    _ menu: NSMenu, titledPrefix prefix: String
) throws -> NSMenuItem {
    let matches = menu.items.filter { $0.title.hasPrefix(prefix) }
    try uiExpect(matches.count == 1,
        "expected exactly one item starting with \"\(prefix)\", got \(matches.map(\.title))")
    return matches[0]
}
