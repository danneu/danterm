// UI regressions for sidebar context-menu enablement. These tests exercise real
// detached NSMenus after AppKit validation so manually disabled items cannot be
// re-enabled by autoenablesItems drift.
import Cocoa

func sidebarContextMenuTests() {
    print("SidebarContextMenu")

    uiTest("single group keeps Delete Group disabled after menu update") {
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

    uiTest("multiple groups keep Delete Group enabled after menu update") {
        let (sidebar, model) = makeSidebarContextMenuHarness(groupCount: 2)

        let menu = try uiRequire(sidebar.contextMenu(forGroupId: model.groups[0].id),
            "expected group context menu")
        menu.update()

        let deleteItem = try onlyContextMenuItem(menu, titled: "Delete Group")
        try uiExpect(deleteItem.isEnabled,
            "Delete Group should be enabled when multiple groups exist")
    }

    uiTest("a right-click on a tab marks the clicked row so AppKit outlines it") {
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
}

/// Sidebar in a real window with one group holding two tabs, rows materialized,
/// so a synthesized right-click lands on a known row index (row 0 is the group).
private func makeSidebarRightClickHarness() -> (SidebarView, NSOutlineView, NSWindow) {
    let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 420))
    sidebar.runtime = AppRuntime()
    let window = NSWindow(
        contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
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
    let projection = desiredSidebar(in: model)
    sidebar.applySidebarOps(
        computeSidebarRowOps(old: nil, new: projection),
        projection: projection, renameTargetToEnd: nil)

    let outline = findSidebarOutlineView(in: sidebar)!
    sidebar.layoutSubtreeIfNeeded()
    outline.layoutSubtreeIfNeeded()
    for row in 0..<outline.numberOfRows {
        _ = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
        _ = outline.rowView(atRow: row, makeIfNecessary: true)
    }
    return (sidebar, outline, window)
}

private func findSidebarOutlineView(in view: NSView) -> NSOutlineView? {
    if let outline = view as? NSOutlineView { return outline }
    for subview in view.subviews {
        if let found = findSidebarOutlineView(in: subview) { return found }
    }
    return nil
}

private func makeSidebarContextMenuHarness(groupCount: Int) -> (SidebarView, AppModel) {
    let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 420))
    let groups = (0..<groupCount).map { index in
        GroupModel(id: GroupId(), name: "Group \(index + 1)")
    }
    let model = AppModel(groups: groups)
    let projection = desiredSidebar(in: model)
    sidebar.applySidebarOps(
        computeSidebarRowOps(old: nil, new: projection),
        projection: projection,
        renameTargetToEnd: nil)
    return (sidebar, model)
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
