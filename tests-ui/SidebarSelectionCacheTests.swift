// UI regressions for SidebarView cache identity and AppKit row selection restore.
import Cocoa

func sidebarSelectionCacheTests() {
    print("SidebarSelectionCache")

    uiTest("real sidebar executor preserves selected-row highlight after cross-group move") {
        let (sidebar, outline, window) = makeSidebarSelectionHarness()
        defer { window.close() }

        let groupA = GroupId()
        let groupB = GroupId()
        let first = TabId()
        let moved = TabId()
        let trailing = TabId()
        let oldModel = sidebarSelectionModel([
            (groupA, "A", [first]),
            (groupB, "B", [moved, trailing]),
        ], selected: first)
        let oldProjection = applyInitialSidebarModel(oldModel, to: sidebar, outline: outline)

        try uiExpect(sidebarVisibleTabIds(in: outline).contains(moved),
            "initial rows should contain moved tab")
        let sourceRow = try sidebarRow(for: moved, in: outline)
        outline.selectRowIndexes(IndexSet(integer: sourceRow), byExtendingSelection: false)

        let newModel = sidebarSelectionModel([
            (groupA, "A", [moved, first]),
            (groupB, "B", [trailing]),
        ], selected: moved)
        applySidebarTransition(old: oldProjection, newModel: newModel, to: sidebar, outline: outline)

        let visible = sidebarVisibleTabIds(in: outline)
        try uiExpect(visible.first == moved, "moved tab should be first visible tab")
        try assertSidebarSelectedTab(moved, in: outline)
    }

    uiTest("real sidebar executor keeps survivor highlighted after close following cache-drifting move") {
        let (sidebar, outline, window) = makeSidebarSelectionHarness()
        defer { window.close() }

        let groupA = GroupId()
        let groupB = GroupId()
        let anchor = TabId()
        let closed = TabId()
        let survivor = TabId()
        let trailing = TabId()
        let oldModel = sidebarSelectionModel([
            (groupA, "A", [anchor]),
            (groupB, "B", [closed, survivor, trailing]),
        ], selected: anchor)
        let oldProjection = applyInitialSidebarModel(oldModel, to: sidebar, outline: outline)

        let movedModel = sidebarSelectionModel([
            (groupA, "A", [closed, survivor, anchor]),
            (groupB, "B", [trailing]),
        ], selected: closed)
        let movedProjection = applySidebarTransition(
            old: oldProjection,
            newModel: movedModel,
            to: sidebar,
            outline: outline)
        try assertSidebarSelectedTab(closed, in: outline)

        let closedModel = sidebarSelectionModel([
            (groupA, "A", [survivor, anchor]),
            (groupB, "B", [trailing]),
        ], selected: survivor)
        applySidebarTransition(old: movedProjection, newModel: closedModel, to: sidebar, outline: outline)

        let visible = sidebarVisibleTabIds(in: outline)
        try uiExpect(!visible.contains(closed), "closed tab should no longer be visible")
        try assertSidebarSelectedTab(survivor, in: outline)
    }
}

private func makeSidebarSelectionHarness() -> (SidebarView, NSOutlineView, NSWindow) {
    let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 420))
    let window = NSWindow(
        contentRect: sidebar.frame,
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    window.contentView = sidebar
    window.layoutIfNeeded()
    let outline = findSidebarOutlineView(in: sidebar)!
    return (sidebar, outline, window)
}

@discardableResult
private func applyInitialSidebarModel(
    _ model: AppModel,
    to sidebar: SidebarView,
    outline: NSOutlineView
) -> SidebarProjection {
    let projection = desiredSidebar(in: model)
    sidebar.applySidebarOps(
        computeSidebarRowOps(old: nil, new: projection),
        model: model,
        clearActiveRename: false)
    materializeSidebarRows(sidebar, outline: outline)
    return projection
}

@discardableResult
private func applySidebarTransition(
    old oldProjection: SidebarProjection,
    newModel: AppModel,
    to sidebar: SidebarView,
    outline: NSOutlineView
) -> SidebarProjection {
    let newProjection = desiredSidebar(in: newModel)
    sidebar.applySidebarOps(
        computeSidebarRowOps(old: oldProjection, new: newProjection),
        model: newModel,
        clearActiveRename: false)
    materializeSidebarRows(sidebar, outline: outline)
    return newProjection
}

private func materializeSidebarRows(_ sidebar: SidebarView, outline: NSOutlineView) {
    sidebar.layoutSubtreeIfNeeded()
    outline.layoutSubtreeIfNeeded()
    for row in 0..<outline.numberOfRows {
        _ = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
        _ = outline.rowView(atRow: row, makeIfNecessary: true)
    }
}

private func assertSidebarSelectedTab(
    _ tabId: TabId,
    in outline: NSOutlineView,
    file: String = #file,
    line: Int = #line
) throws {
    let row = try sidebarRow(for: tabId, in: outline, file: file, line: line)
    try uiExpect(outline.selectedRowIndexes.contains(row), "selected rows should contain tab row", file: file, line: line)
    let rowView = outline.rowView(atRow: row, makeIfNecessary: true)
    try uiExpect(rowView?.isSelected == true, "materialized row view should be selected", file: file, line: line)
    guard let item = outline.item(atRow: row) as? SidebarItem,
          case .tab(let tab) = item.kind,
          tab.id == tabId
    else {
        throw UITestFailure(message: "outline item at selected row should be the tab (\(file):\(line))")
    }
}

private func sidebarRow(
    for tabId: TabId,
    in outline: NSOutlineView,
    file: String = #file,
    line: Int = #line
) throws -> Int {
    for row in 0..<outline.numberOfRows {
        guard let item = outline.item(atRow: row) as? SidebarItem,
              case .tab(let tab) = item.kind,
              tab.id == tabId
        else { continue }
        return row
    }
    throw UITestFailure(message: "missing row for tab \(tabId) (\(file):\(line))")
}

private func sidebarVisibleTabIds(in outline: NSOutlineView) -> [TabId] {
    (0..<outline.numberOfRows).compactMap { row in
        guard let item = outline.item(atRow: row) as? SidebarItem,
              case .tab(let tab) = item.kind
        else { return nil }
        return tab.id
    }
}

private func findSidebarOutlineView(in view: NSView) -> NSOutlineView? {
    if let outline = view as? NSOutlineView { return outline }
    for subview in view.subviews {
        if let found = findSidebarOutlineView(in: subview) {
            return found
        }
    }
    return nil
}

private func sidebarSelectionModel(
    _ groups: [(GroupId, String, [TabId])],
    selected selectedTabId: TabId?
) -> AppModel {
    AppModel(
        groups: groups.map { groupId, name, tabIds in
            GroupModel(
                id: groupId,
                name: name,
                tabs: tabIds.map(sidebarSelectionTab)
            )
        },
        selectedTabId: selectedTabId
    )
}

private func sidebarSelectionTab(_ id: TabId) -> TabModel {
    let paneId = PaneId()
    return TabModel(
        id: id,
        focusedPaneId: paneId,
        rootNode: .leaf(PaneModel(id: paneId))
    )
}
