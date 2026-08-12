// UI regressions for SidebarView cache identity, AppKit row selection restore, and
// scroll-reveal behavior.
import Cocoa

// The runner calls this from `@MainActor main()`, so the body is main-actor in
// fact. Saying so lets the closures below reach `sidebarBadgeCount`.
@MainActor
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

    uiTest("cosmetic sidebar sweep marks no row for redraw") {
        // Intent: an empty-op sidebar reconcile with unchanged focus leaves every
        //   visible row view clean and does not re-issue the current selection.
        // Why it exists: cosmetic coalesced sweeps used to reassert row emphasis and
        //   restore selection at about 13 Hz, dirtying the whole sidebar.
        // Scenario: a busy pane emits progress/search/split-ratio churn while the
        //   sidebar projection and focused tab are unchanged.
        let (sidebar, outline, window) = makeSidebarSelectionHarness()
        defer { window.close() }

        let tabIds = (0..<8).map { _ in TabId() }
        let model = sidebarOverflowModel(tabIds: tabIds, selected: tabIds[2])
        let projection = applyInitialSidebarModel(model, to: sidebar, outline: outline)
        let selectedRows = outline.selectedRowIndexes

        clearVisibleSidebarRowDisplayFlags(in: outline)
        applySidebarTransition(old: projection, newModel: model, to: sidebar, outline: outline)

        try assertVisibleSidebarRowsDoNotNeedDisplay(in: outline)
        try uiExpect(outline.selectedRowIndexes == selectedRows,
            "cosmetic sweep should preserve the selected row set")
    }

    uiTest("reloadTab sweep with unchanged focus does not redraw unchanged rows") {
        // Intent: a title-only sidebar update changes the affected row without
        //   dirtying every other row view's background/selection layer.
        // Why it exists: reloadTab sweeps still need to refresh the edited cell, but
        //   same-value emphasis assignments should not invalidate row backgrounds.
        // Scenario: an unnamed busy tab streams title/cwd changes while the focused
        //   sidebar row is unchanged.
        let (sidebar, outline, window) = makeSidebarSelectionHarness()
        defer { window.close() }

        let tabIds = (0..<8).map { _ in TabId() }
        let tabs = tabIds.map(sidebarSelectionTab)
        let model = sidebarOverflowModel(tabs: tabs, selected: tabIds[0])
        let projection = applyInitialSidebarModel(model, to: sidebar, outline: outline)

        var changedTabs = tabs
        changedTabs[4].customTitle = "changed"
        let changedModel = sidebarOverflowModel(
            groupId: model.groups[0].id,
            tabs: changedTabs,
            selected: tabIds[0])

        clearVisibleSidebarRowDisplayFlags(in: outline)
        applySidebarTransition(old: projection, newModel: changedModel, to: sidebar, outline: outline)

        let changedRow = try sidebarRow(for: tabIds[4], in: outline)
        try assertVisibleSidebarRowsDoNotNeedDisplay(in: outline, except: [changedRow])
    }

    uiTest("visible painted badge reload reports no dropped row") {
        // Intent: a visible, materialized tab row that paints successfully reports
        //   no unapplied row ids.
        // Why it exists: guards the updateTabRow return polarity that reconcile
        //   uses to decide whether to retain the old sidebar projection.
        // Scenario: a tab alert badge clears while the row is already visible.
        let (sidebar, outline, window) = makeSidebarSelectionHarness()
        defer { window.close() }

        let group = GroupId()
        let tab = TabId()
        let pane = PaneId()
        let model = sidebarAlertModel(groupId: group, tabId: tab, paneId: pane, unread: true)
        let projection = applyInitialSidebarModel(model, to: sidebar, outline: outline)
        try uiExpect(try sidebarBadgeCount(for: tab, in: outline) == 1,
            "precondition: alert badge should be visible")

        let cleared = sidebarAlertModel(groupId: group, tabId: tab, paneId: pane, unread: false)
        let result = applySidebarTransitionResult(
            old: projection, newModel: cleared, to: sidebar, outline: outline)

        try uiExpect(result.droppedTabs.isEmpty, "painted tab row should not report a drop")
        try uiExpect(result.droppedGroups.isEmpty, "painted tab row should not drop groups")
        try uiExpect(try sidebarBadgeCount(for: tab, in: outline) == 0,
            "painted row should show the live cleared badge")
    }

    uiTest("off-screen nil-cell badge reload is not retained") {
        // Intent: a reload for an off-screen tab row does not request cache
        //   retention even when the cell is unavailable.
        // Why it exists: prevents the over-retention case where an ordinary
        //   discarded off-screen cell would re-emit reloadTab every reconcile.
        // Scenario: a sidebar with enough rows to scroll has an off-screen tab
        //   badge clear before the user scrolls it back into view.
        let (sidebar, outline, window) = makeSidebarSelectionHarness()
        defer { window.close() }

        let group = GroupId()
        let tabIds = (0..<30).map { _ in TabId() }
        let panes = tabIds.map { _ in PaneId() }
        let model = sidebarAlertModel(
            groupId: group, tabIds: tabIds, paneIds: panes,
            selected: tabIds[0], unreadPaneIds: [panes[29]])
        let projection = applyInitialSidebarModel(model, to: sidebar, outline: outline)
        try assertSidebarRowOffScreen(29, in: outline)

        let cleared = sidebarAlertModel(
            groupId: group, tabIds: tabIds, paneIds: panes,
            selected: tabIds[0], unreadPaneIds: [])
        sidebar.testForceNextNilCellTabIds.insert(tabIds[29])
        let result = applySidebarTransitionResult(
            old: projection, newModel: cleared, to: sidebar, outline: outline)

        try uiExpect(result.droppedTabs.contains(tabIds[29]) == false,
            "off-screen nil-cell tab should not be retained")
        try uiExpect(result.advancedProjection == desiredSidebar(in: cleared),
            "off-screen nil-cell tab should still advance the cache")
    }

    uiTest("visible nil-cell badge reload is retained and repaints on retry") {
        // Intent: a visible row whose cell cannot be fetched stays pending in the
        //   cache, then the next reconcile re-emits and paints the live badge.
        // Why it exists: pins the app-layer bridge between updateTabRow's dropped
        //   result, applySidebarOps accumulation, and advanceSidebarCache retention.
        // Scenario: an on-screen tab badge clears during a row-op batch where the
        //   cell is transiently unavailable.
        let (sidebar, outline, window) = makeSidebarSelectionHarness()
        defer { window.close() }

        let group = GroupId()
        let tab = TabId()
        let pane = PaneId()
        let model = sidebarAlertModel(groupId: group, tabId: tab, paneId: pane, unread: true)
        let projection = applyInitialSidebarModel(model, to: sidebar, outline: outline)
        let row = try sidebarRow(for: tab, in: outline)
        try assertSidebarRowVisible(row, in: outline)
        try uiExpect(try sidebarBadgeCount(for: tab, in: outline) == 1,
            "precondition: alert badge should be visible")

        let cleared = sidebarAlertModel(groupId: group, tabId: tab, paneId: pane, unread: false)
        sidebar.testForceNextNilCellTabIds.insert(tab)
        let dropped = applySidebarTransitionResult(
            old: projection, newModel: cleared, to: sidebar, outline: outline)

        try uiExpect(dropped.droppedTabs == Set([tab]),
            "visible nil-cell tab should report a dropped paint")
        try uiExpect(try sidebarBadgeCount(for: tab, in: outline) == 1,
            "dropped paint should leave the old badge visible")
        try uiExpect(dropped.advancedProjection != desiredSidebar(in: cleared),
            "dropped paint should retain old attrs in the advanced cache")

        let repainted = applySidebarTransitionResult(
            old: dropped.advancedProjection, newModel: cleared, to: sidebar, outline: outline)

        try uiExpect(repainted.droppedTabs.isEmpty, "retry should fetch and paint the tab row")
        try uiExpect(try sidebarBadgeCount(for: tab, in: outline) == 0,
            "retry should repaint the visible badge from the live model")
        try uiExpect(repainted.advancedProjection == desiredSidebar(in: cleared),
            "cache should converge after the retry paints")
    }

    uiTest("empty-op sweep restores the focused tab as the lead row") {
        // Intent: when the selected set already matches the model, restore still fixes
        //   the lead/last-selected row so range selection anchors on the focused tab.
        // Why it exists: a set-only no-op guard would strand the wrong lead row while
        //   appearing to preserve selection correctly.
        // Scenario: focus remains on the first tab in a multi-selection, but AppKit's
        //   lead row points at another selected tab before reconcile runs.
        let (sidebar, outline, window) = makeSidebarSelectionHarness()
        defer { window.close() }

        let tabIds = (0..<6).map { _ in TabId() }
        let model = sidebarOverflowModel(tabIds: tabIds, selected: tabIds[0])
        let projection = applyInitialSidebarModel(model, to: sidebar, outline: outline)
        let focusRow = try sidebarRow(for: tabIds[0], in: outline)
        let otherRow = try sidebarRow(for: tabIds[5], in: outline)

        outline.selectRowIndexes(IndexSet(integer: focusRow), byExtendingSelection: false)
        outline.selectRowIndexes(IndexSet(integer: otherRow), byExtendingSelection: true)
        try uiExpect(outline.selectedRow == otherRow,
            "precondition: extended selection should make the last row the lead")

        applySidebarTransition(old: projection, newModel: model, to: sidebar, outline: outline)

        var expected = IndexSet(integer: focusRow)
        expected.insert(otherRow)
        try uiExpect(outline.selectedRowIndexes == expected,
            "restore should preserve the selected set")
        try uiExpect(outline.selectedRow == focusRow,
            "restore should make the focused tab the lead row")
    }

    uiTest("focus change re-emphasizes the new row and de-emphasizes the old") {
        // Intent: a focus-only transition updates forced accent drawing for both
        //   affected visible rows.
        // Why it exists: the redraw optimization must not skip emphasis refresh when
        //   the projection is unchanged but model focus moved.
        // Scenario: keyboard focus moves between two existing tabs without any
        //   sidebar row insertion, removal, or reload op.
        let (sidebar, outline, window) = makeSidebarSelectionHarness()
        defer { window.close() }

        let first = TabId()
        let second = TabId()
        let group = GroupId()
        let model = sidebarOverflowModel(
            groupId: group,
            tabIds: [first, second],
            selected: first)
        let projection = applyInitialSidebarModel(model, to: sidebar, outline: outline)

        try uiExpect(try sidebarRowView(for: first, in: outline).forceEmphasizedSelection,
            "precondition: initially focused row should force emphasis")
        try uiExpect(!((try sidebarRowView(for: second, in: outline)).forceEmphasizedSelection),
            "precondition: unfocused row should not force emphasis")

        let focusedSecond = sidebarOverflowModel(
            groupId: group,
            tabIds: [first, second],
            selected: second)
        applySidebarTransition(old: projection, newModel: focusedSecond, to: sidebar, outline: outline)

        try uiExpect(!((try sidebarRowView(for: first, in: outline)).forceEmphasizedSelection),
            "old focused row should stop forcing emphasis")
        try uiExpect(try sidebarRowView(for: second, in: outline).forceEmphasizedSelection,
            "new focused row should force emphasis")
    }
}

func sidebarScrollRevealTests() {
    print("SidebarScrollReveal")

    uiTest("cosmetic reconcile preserves the user's scroll position") {
        // Intent: cosmetic sidebar reconciles leave the user's manual scroll position
        //   alone when the focused tab is unchanged and off-screen.
        // Why it exists: locks down the sidebar stutter regression, where every
        //   reconcile unconditionally revealed the selected tab.
        // Scenario: while a terminal churned tab title/cwd/progress updates, selecting
        //   the top tab and scrolling the overflowing sidebar down snapped row 0 back.
        let (sidebar, outline, window) = makeSidebarSelectionHarness()
        defer { window.close() }

        let tabIds = (0..<30).map { _ in TabId() }
        let model = sidebarOverflowModel(tabIds: tabIds, selected: tabIds[0])
        let projection = applyInitialSidebarModel(model, to: sidebar, outline: outline)

        outline.scrollRowToVisible(29)
        materializeSidebarRows(sidebar, outline: outline)
        try assertSidebarRowOffScreen(0, in: outline)
        let beforeEmptyOps = outline.visibleRect.origin.y

        applySidebarTransition(old: projection, newModel: model, to: sidebar, outline: outline)
        try assertSidebarScrollOrigin(outline.visibleRect.origin.y, matches: beforeEmptyOps)
        try assertSidebarRowOffScreen(0, in: outline)

        var changedTabs = tabIds.map(sidebarSelectionTab)
        changedTabs[15].customTitle = "changed"
        let changedModel = sidebarOverflowModel(
            groupId: model.groups[0].id,
            tabs: changedTabs,
            selected: tabIds[0])
        let beforeReloadTab = outline.visibleRect.origin.y

        applySidebarTransition(old: projection, newModel: changedModel, to: sidebar, outline: outline)
        try assertSidebarScrollOrigin(outline.visibleRect.origin.y, matches: beforeReloadTab)
        try assertSidebarRowOffScreen(0, in: outline)
    }

    uiTest("focus change reveals an off-screen tab, including within a multi-selection") {
        // Intent: a real focus change still reveals the newly focused tab even when the
        //   destination row starts off-screen.
        // Why it exists: guards against over-correcting the stutter by deleting reveal
        //   behavior or keying it only on selection-set membership.
        // Scenario: keyboard-switching to an off-screen tab, or focusing an already
        //   multi-selected off-screen tab, should bring that tab into view.
        let tabIds = (0..<30).map { _ in TabId() }

        do {
            let (sidebar, outline, window) = makeSidebarSelectionHarness()
            defer { window.close() }

            let model = sidebarOverflowModel(tabIds: tabIds, selected: tabIds[0])
            let projection = applyInitialSidebarModel(model, to: sidebar, outline: outline)
            try assertSidebarRowOffScreen(29, in: outline)

            let focusedLast = sidebarOverflowModel(
                groupId: model.groups[0].id,
                tabIds: tabIds,
                selected: tabIds[29])
            applySidebarTransition(old: projection, newModel: focusedLast, to: sidebar, outline: outline)
            try assertSidebarRowVisible(29, in: outline)
        }

        do {
            let (sidebar, outline, window) = makeSidebarSelectionHarness()
            defer { window.close() }

            let model = sidebarOverflowModel(tabIds: tabIds, selected: tabIds[0])
            let projection = applyInitialSidebarModel(model, to: sidebar, outline: outline)
            try assertSidebarRowOffScreen(29, in: outline)

            outline.selectRowIndexes(IndexSet(integer: 29), byExtendingSelection: true)
            try assertSidebarRowOffScreen(29, in: outline)
            let selectedIds = Set(sidebar.selectedTabIds())
            try uiExpect(
                selectedIds == Set([tabIds[0], tabIds[29]]),
                "extended selection should include the first and last tabs")

            let focusedLast = sidebarOverflowModel(
                groupId: model.groups[0].id,
                tabIds: tabIds,
                selected: tabIds[29])
            applySidebarTransition(old: projection, newModel: focusedLast, to: sidebar, outline: outline)
            try assertSidebarRowVisible(29, in: outline)
        }
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
        projection: projection,
        renameTargetToEnd: nil)
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
    applySidebarTransitionResult(
        old: oldProjection, newModel: newModel, to: sidebar, outline: outline
    ).advancedProjection
}

@discardableResult
private func applySidebarTransitionResult(
    old oldProjection: SidebarProjection,
    newModel: AppModel,
    to sidebar: SidebarView,
    outline: NSOutlineView,
    materializeRows: Bool = true
) -> (
    advancedProjection: SidebarProjection,
    droppedTabs: Set<TabId>,
    droppedGroups: Set<GroupId>
) {
    let newProjection = desiredSidebar(in: newModel)
    let dropped = sidebar.applySidebarOps(
        computeSidebarRowOps(old: oldProjection, new: newProjection),
        model: newModel,
        projection: newProjection,
        renameTargetToEnd: nil)
    if materializeRows {
        materializeSidebarRows(sidebar, outline: outline)
    }
    let advanced = advanceSidebarCache(
        old: oldProjection,
        new: newProjection,
        suppressedRenameTarget: nil,
        unappliedTabIds: dropped.tabs,
        unappliedGroupIds: dropped.groups)
    return (advanced, dropped.tabs, dropped.groups)
}

private func materializeSidebarRows(_ sidebar: SidebarView, outline: NSOutlineView) {
    sidebar.layoutSubtreeIfNeeded()
    outline.layoutSubtreeIfNeeded()
    for row in 0..<outline.numberOfRows {
        _ = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
        _ = outline.rowView(atRow: row, makeIfNecessary: true)
    }
}

private func clearVisibleSidebarRowDisplayFlags(in outline: NSOutlineView) {
    outline.displayIfNeeded()
    for row in 0..<outline.numberOfRows {
        guard let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView
        else { continue }
        rowView.needsDisplay = false
    }
}

private func assertVisibleSidebarRowsDoNotNeedDisplay(
    in outline: NSOutlineView,
    except allowedRows: Set<Int> = [],
    file: String = #file,
    line: Int = #line
) throws {
    for row in 0..<outline.numberOfRows {
        if allowedRows.contains(row) { continue }
        guard let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView
        else { continue }
        try uiExpect(!rowView.needsDisplay, "row \(row) should not need display", file: file, line: line)
    }
}

private func sidebarRowView(
    for tabId: TabId,
    in outline: NSOutlineView,
    file: String = #file,
    line: Int = #line
) throws -> SidebarRowView {
    let row = try sidebarRow(for: tabId, in: outline, file: file, line: line)
    guard let rowView = outline.rowView(atRow: row, makeIfNecessary: true) as? SidebarRowView else {
        throw UITestFailure(message: "missing SidebarRowView for tab \(tabId) (\(file):\(line))")
    }
    return rowView
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

private func sidebarOverflowModel(
    groupId: GroupId = GroupId(),
    tabIds: [TabId],
    selected selectedTabId: TabId?
) -> AppModel {
    sidebarOverflowModel(
        groupId: groupId,
        tabs: tabIds.map(sidebarSelectionTab),
        selected: selectedTabId)
}

private func sidebarOverflowModel(
    groupId: GroupId = GroupId(),
    tabs: [TabModel],
    selected selectedTabId: TabId?
) -> AppModel {
    AppModel(
        groups: [
            GroupModel(
                id: groupId,
                name: "Overflow",
                tabs: tabs),
        ],
        selectedTabId: selectedTabId)
}

private func sidebarAlertModel(
    groupId: GroupId,
    tabId: TabId,
    paneId: PaneId,
    unread: Bool,
    selected selectedTabId: TabId? = nil
) -> AppModel {
    sidebarAlertModel(
        groupId: groupId,
        tabIds: [tabId],
        paneIds: [paneId],
        selected: selectedTabId ?? tabId,
        unreadPaneIds: unread ? [paneId] : [])
}

private func sidebarAlertModel(
    groupId: GroupId,
    tabIds: [TabId],
    paneIds: [PaneId],
    selected selectedTabId: TabId?,
    unreadPaneIds: [PaneId]
) -> AppModel {
    var model = AppModel(
        groups: [
            GroupModel(
                id: groupId,
                name: "Alerts",
                tabs: zip(tabIds, paneIds).map { tabId, paneId in
                    TabModel(
                        id: tabId,
                        focusedPaneId: paneId,
                        rootNode: .leaf(PaneModel(id: paneId)))
                }),
        ],
        selectedTabId: selectedTabId)
    model.alerts = unreadPaneIds.map(sidebarBellAlert)
    return model
}

private func sidebarBellAlert(paneId: PaneId) -> AlertModel {
    AlertModel(
        id: AlertId(),
        kind: .bell,
        paneId: paneId,
        title: "Bell",
        body: "",
        createdAt: Date(timeIntervalSince1970: 0),
        isUnread: true)
}

private func sidebarSelectionTab(_ id: TabId) -> TabModel {
    let paneId = PaneId()
    return TabModel(
        id: id,
        focusedPaneId: paneId,
        rootNode: .leaf(PaneModel(id: paneId))
    )
}

@MainActor
private func sidebarBadgeCount(
    for tabId: TabId,
    in outline: NSOutlineView,
    file: String = #file,
    line: Int = #line
) throws -> Int {
    let row = try sidebarRow(for: tabId, in: outline, file: file, line: line)
    guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
    else { throw UITestFailure(message: "missing cell for tab \(tabId) (\(file):\(line))") }
    guard let badge = visibleAlertBadge(in: cell) as? NSTextField else { return 0 }
    return Int(badge.stringValue) ?? -1
}

private func assertSidebarRowOffScreen(
    _ row: Int,
    in outline: NSOutlineView,
    file: String = #file,
    line: Int = #line
) throws {
    try uiExpect(
        !outline.visibleRect.intersects(outline.rect(ofRow: row)),
        "row \(row) should be off-screen",
        file: file,
        line: line)
}

private func assertSidebarRowVisible(
    _ row: Int,
    in outline: NSOutlineView,
    file: String = #file,
    line: Int = #line
) throws {
    try uiExpect(
        outline.visibleRect.intersects(outline.rect(ofRow: row)),
        "row \(row) should be visible",
        file: file,
        line: line)
}

private func assertSidebarScrollOrigin(
    _ actual: CGFloat,
    matches expected: CGFloat,
    file: String = #file,
    line: Int = #line
) throws {
    try uiExpect(
        abs(actual - expected) < 0.5,
        "sidebar scroll origin should remain \(expected), got \(actual)",
        file: file,
        line: line)
}
