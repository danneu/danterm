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

        let menu = try uiRequire(sidebar.contextMenu(for: model.groups[0]),
            "expected group context menu")
        menu.update()

        let deleteItem = try onlyContextMenuItem(menu, titled: "Delete Group")
        try uiExpect(deleteItem.isEnabled == false,
            "Delete Group should stay disabled when only one group exists")
    }

    uiTest("multiple groups keep Delete Group enabled after menu update") {
        let (sidebar, model) = makeSidebarContextMenuHarness(groupCount: 2)

        let menu = try uiRequire(sidebar.contextMenu(for: model.groups[0]),
            "expected group context menu")
        menu.update()

        let deleteItem = try onlyContextMenuItem(menu, titled: "Delete Group")
        try uiExpect(deleteItem.isEnabled,
            "Delete Group should be enabled when multiple groups exist")
    }
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
        model: model,
        clearActiveRename: false)
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
