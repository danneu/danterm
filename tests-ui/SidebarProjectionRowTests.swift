// UI regressions for the rule that a sidebar cell paints its projection: the row's
// contents are a function of the projection whose row op was applied to it, never of
// a model read at draw time. The tab test drives the deferred-reload path (a rename
// suppresses a row op, then the cell is reconfigured) and the group test drives a
// group row through collapse, unread, and tab-count changes. Both need the real
// SidebarView executor, so they need the WindowServer like the rest of the harness.
import Cocoa

// The runner calls this from `@MainActor main()`, so the body is main-actor in
// fact. Saying so lets the closures below reach AppKit cell state.
@MainActor
func sidebarProjectionRowTests() {
    print("SidebarProjectionRow")

    uiTest("badge hit testing returns only the tab with a visible badge") {
        // Intent: a point inside a visible tab alert badge resolves that tab, and
        //   the same point resolves nothing after the badge is hidden.
        // Why it exists: the old badge tests built a fake cell from identifier
        //   strings, so they did not exercise the outline view's click consumer.
        // Scenario: spec-first -- a tab's bell is cleared while its row stays
        //   materialized under the pointer.
        let (sidebar, outline, window, runtime) = makeProjectionRowHarness()
        defer { window.close() }

        let group = GroupId()
        let tab = TabId()
        let pane = PaneId()
        var model = AppModel(
            groups: [GroupModel(id: group, name: "G", tabs: [
                projectionRowTab(id: tab, title: "ringing", paneId: pane),
            ])],
            selectedTabId: tab)
        model.alerts = [projectionRowBellAlert(paneId: pane)]
        let alertedProjection = applyProjectionRowModel(model, to: sidebar, outline: outline)

        let cell: SidebarTabCellView = try projectionRowCell(for: .tab(tab), in: outline)
        try uiExpect(cell.alertBadge.isHidden == false,
            "alerted tab should have a visible badge")
        let badge = cell.alertBadge
        let badgePoint = outline.convert(
            NSPoint(x: badge.bounds.midX, y: badge.bounds.midY), from: badge)
        try uiExpect(outline.tabForBadgeHit(at: badgePoint) == tab,
            "a point inside the visible badge should resolve its tab")

        model.alerts = []
        _ = applyProjectionRowTransition(
            old: alertedProjection, newModel: model,
            to: sidebar, outline: outline, runtime: runtime)

        try uiExpect(outline.tabForBadgeHit(at: badgePoint) == nil,
            "the badge point should resolve nothing after the badge is hidden")
    }

    uiTest("clearing a jump key restores its title lane after rename") {
        // Intent: a hidden stored jump badge reserves no width, while an active
        //   rename keeps its current title lane until the deferred repaint lands.
        // Why it exists: storing the badge permanently is safe only if hiding it
        //   collapses its arranged-subview width without resizing a live editor.
        // Scenario: spec-first -- jump mode ends normally, then ends again while
        //   the user is renaming the same tab.
        let (sidebar, outline, window, runtime) = makeProjectionRowHarness()
        defer { window.close() }

        let group = GroupId()
        let tab = TabId()
        var model = AppModel(
            groups: [GroupModel(id: group, name: "G", tabs: [
                projectionRowTab(id: tab, title: "a title with useful width"),
            ])],
            selectedTabId: tab)
        model.jumpMode = JumpModeState(keyMap: [tab: "a"])
        var projection = applyProjectionRowModel(model, to: sidebar, outline: outline)
        let cell: SidebarTabCellView = try projectionRowCell(for: .tab(tab), in: outline)
        window.contentView?.layoutSubtreeIfNeeded()
        let badgedWidth = projectionRowTitleLaneWidth(cell)

        model.jumpMode = nil
        projection = applyProjectionRowTransition(
            old: projection, newModel: model,
            to: sidebar, outline: outline, runtime: runtime)
        window.contentView?.layoutSubtreeIfNeeded()
        let clearedWidth = projectionRowTitleLaneWidth(cell)
        try uiExpect(clearedWidth >= badgedWidth + 20,
            "clearing the jump key should return the badge width to the title lane")

        model.jumpMode = JumpModeState(keyMap: [tab: "a"])
        projection = applyProjectionRowTransition(
            old: projection, newModel: model,
            to: sidebar, outline: outline, runtime: runtime)
        sidebar.beginRenamingTab(tab)
        window.contentView?.layoutSubtreeIfNeeded()
        let editingWidth = projectionRowTitleLaneWidth(cell)

        model.jumpMode = nil
        let suppressed = applyProjectionRowTransition(
            old: projection, newModel: model,
            to: sidebar, outline: outline, runtime: runtime)
        window.contentView?.layoutSubtreeIfNeeded()
        try uiExpect(abs(projectionRowTitleLaneWidth(cell) - editingWidth) <= 0.5,
            "clearing the jump key during rename should not resize the title lane")

        guard let editor = cell.titleField.currentEditor() as? NSTextView else {
            throw UITestFailure(message: "rename should still own the field editor")
        }
        _ = sidebar.control(
            cell.titleField, textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        _ = applyProjectionRowTransition(
            old: suppressed, newModel: model,
            to: sidebar, outline: outline, runtime: runtime)
        window.contentView?.layoutSubtreeIfNeeded()
        try uiExpect(projectionRowTitleLaneWidth(cell) >= editingWidth + 20,
            "the deferred repaint should return the badge width after rename ends")
    }

    uiTest("a materialized tab paints every scalar projection field") {
        // Intent: one apply paints the tab title, subtitle, chip, alert badge,
        //   jump badge, and color stripe from the supplied projection.
        // Why it exists: typed access removes silent lookup failures only if each
        //   stored child remains part of the cell's single total paint path.
        // Scenario: spec-first -- a row arrives with every scalar decoration set.
        let (sidebar, outline, window, _) = makeProjectionRowHarness()
        defer { window.close() }

        let group = GroupId()
        let tab = TabId()
        let model = AppModel(groups: [
            GroupModel(id: group, name: "G", tabs: [
                projectionRowTab(id: tab, title: "model title"),
            ]),
        ])
        var projection = desiredSidebar(in: model)
        projection.groups[0].tabs[0].displayTitle = DisplayLine("painted title")
        projection.groups[0].tabs[0].subtitle = DisplayLine("painted subtitle")
        projection.groups[0].tabs[0].unreadAlertCount = 3
        projection.groups[0].tabs[0].jumpKey = "q"
        projection.groups[0].tabs[0].color = .purple
        projection.groups[0].tabs[0].chipKind = .codex
        sidebar.applySidebarOps(
            computeSidebarRowOps(old: nil, new: projection),
            projection: projection, renameTargetToEnd: nil)
        materializeProjectionRows(sidebar, outline: outline)

        let cell: SidebarTabCellView = try projectionRowCell(for: .tab(tab), in: outline)
        try uiExpect(cell.titleField.stringValue == "painted title",
            "the title should come from the projection")
        try uiExpect(
            cell.subtitleField.isHidden == false
                && cell.subtitleField.stringValue == "painted subtitle",
            "the subtitle should come from the projection")
        try uiExpect(cell.chip.kind == .codex,
            "the chip should come from the projection")
        try uiExpect(
            cell.alertBadge.isHidden == false && cell.alertBadge.stringValue == "3",
            "the alert badge should come from the projection")
        try uiExpect(
            cell.jumpBadge.isHidden == false && cell.jumpBadge.stringValue == "Q",
            "the jump badge should come from the projection")
        try uiExpect(
            cell.colorStripe.isHidden == false
                && cell.colorStripe.layer?.backgroundColor == TabColor.purple.nsColor.cgColor,
            "the color stripe should come from the projection")
    }

    uiTest("a reload suppressed by rename leaves the whole row on its old projection") {
        // Intent: while a rename suppresses a tab's reload, reconfiguring that cell
        //   redraws the projection the row last applied -- title, alert badge, and
        //   pane strip alike -- and a later reconcile converges all three.
        // Why it exists: the cell used to re-derive its badge and strip from a live
        //   `currentModel` read, so a suppressed reload still painted the newer model
        //   and the retained-projection retry was a no-op that looked correct.
        // Scenario: the user renames a split tab while its second pane rings a bell
        //   and its focused pane reports a new title, then ends the rename.
        let (sidebar, outline, window, runtime) = makeProjectionRowHarness()
        defer { window.close() }

        let group = GroupId()
        let edited = TabId(); let other = TabId()
        let paneA = PaneId(); let paneB = PaneId()
        var model = AppModel(
            groups: [GroupModel(id: group, name: "G", tabs: [
                projectionRowSplitTab(
                    id: edited, panes: [(paneA, "alpha"), (paneB, "beta")], focused: paneA),
                projectionRowTab(id: other, title: "other"),
            ])],
            selectedTabId: edited)
        let initial = applyProjectionRowModel(model, to: sidebar, outline: outline)

        let cell: SidebarTabCellView = try projectionRowCell(for: .tab(edited), in: outline)
        try uiExpect(cell.textField?.stringValue == "alpha",
            "precondition: the row should start on the old title")
        try uiExpect(cell.alertBadge.isHidden,
            "precondition: the row should start with no visible alert badge")
        try uiExpect(cell.paneStrip.chips.map(\.state) == [.quiet, .quiet],
            "precondition: neither pane should start marked")

        sidebar.beginRenamingTab(edited)
        try uiExpect(cell.textField?.currentEditor() != nil,
            "precondition: rename should attach a live field editor")

        // The model moves under the suppressed row: new focused-pane title, and a
        // bell on the other pane (which moves both the badge and the strip).
        model.groups[0].tabs[0] = projectionRowSplitTab(
            id: edited, panes: [(paneA, "alpha updated"), (paneB, "beta")], focused: paneA)
        model.alerts = [projectionRowBellAlert(paneId: paneB)]
        let suppressed = applyProjectionRowTransition(
            old: initial, newModel: model, to: sidebar, outline: outline, runtime: runtime)

        // Force the reconfigure: without it the row would pass simply by never having
        // been repainted. Ending the rename resyncs the cell from its backing item.
        guard let editor = cell.textField?.currentEditor() as? NSTextView else {
            throw UITestFailure(message: "rename should still own the field editor")
        }
        _ = sidebar.control(
            cell.textField!, textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        try uiExpect(cell.textField?.stringValue == "alpha",
            "a reconfigure after a suppressed reload must redraw the old title")
        try uiExpect(cell.alertBadge.isHidden,
            "a reconfigure after a suppressed reload must not paint the newer badge")
        try uiExpect(cell.paneStrip.chips.map(\.state) == [.quiet, .quiet],
            "a reconfigure after a suppressed reload must not paint the newer strip")

        _ = applyProjectionRowTransition(
            old: suppressed, newModel: model, to: sidebar, outline: outline, runtime: runtime)

        let converged: SidebarTabCellView = try projectionRowCell(
            for: .tab(edited), in: outline)
        try uiExpect(converged.textField?.stringValue == "alpha updated",
            "the retained projection should re-fire the reload and converge the title")
        try uiExpect(
            converged.alertBadge.isHidden == false && converged.alertBadge.stringValue == "1",
            "the retained projection should re-fire the reload and converge the badge")
        try uiExpect(converged.paneStrip.chips.map(\.state) == [.quiet, .attention],
            "the retained projection should re-fire the reload and converge the strip")
    }

    uiTest("a group row draws its caret and both badges from the applied projection") {
        // Intent: collapse state, unread count, and tab count reach a group cell only
        //   through the projection its row ops carried, in both collapsed and
        //   expanded states.
        // Why it exists: the group cell used to rescan the whole alert list and count
        //   `group.tabs` off a live model, so nothing pinned the caret and the two
        //   badges to the row ops that were actually applied.
        // Scenario: spec-first -- a group collapses while gaining a tab and a bell,
        //   then expands again.
        let (sidebar, outline, window, runtime) = makeProjectionRowHarness()
        defer { window.close() }

        let groupA = GroupId(); let groupB = GroupId()
        let first = TabId(); let second = TabId(); let added = TabId(); let anchor = TabId()
        let addedPane = PaneId()
        var model = AppModel(
            groups: [
                GroupModel(id: groupA, name: "A", tabs: [
                    projectionRowTab(id: first, title: "one"),
                    projectionRowTab(id: second, title: "two"),
                ]),
                GroupModel(id: groupB, name: "B", tabs: [
                    projectionRowTab(id: anchor, title: "anchor"),
                ]),
            ],
            selectedTabId: first)
        let expandedProjection = applyProjectionRowModel(model, to: sidebar, outline: outline)

        try assertProjectionRowGroup(
            groupA, in: outline, caret: "chevron.down",
            title: "A", hidesSeparator: true,
            bell: nil, tabCount: nil, label: "initial expanded group")

        model.groups[0].isCollapsed = true
        model.groups[0].tabs.append(
            projectionRowTab(id: added, title: "three", paneId: addedPane))
        model.alerts = [projectionRowBellAlert(paneId: addedPane)]
        let collapsedProjection = applyProjectionRowTransition(
            old: expandedProjection, newModel: model,
            to: sidebar, outline: outline, runtime: runtime)

        try assertProjectionRowGroup(
            groupA, in: outline, caret: "chevron.right",
            title: "A", hidesSeparator: true,
            bell: "1", tabCount: "3", label: "collapsed group")

        model.groups[0].isCollapsed = false
        _ = applyProjectionRowTransition(
            old: collapsedProjection, newModel: model,
            to: sidebar, outline: outline, runtime: runtime)

        try assertProjectionRowGroup(
            groupA, in: outline, caret: "chevron.down",
            title: "A", hidesSeparator: true,
            bell: nil, tabCount: nil, label: "re-expanded group")
    }
}

// MARK: - Harness helpers

private func makeProjectionRowHarness() -> (SidebarView, SidebarOutlineView, NSWindow, AppRuntime) {
    let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 420))
    let runtime = AppRuntime()
    sidebar.runtime = runtime
    let window = NSWindow(
        contentRect: sidebar.frame,
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    window.contentView = sidebar
    window.layoutIfNeeded()
    let outline = findProjectionRowOutlineView(in: sidebar)!
    return (sidebar, outline, window, runtime)
}

private func projectionRowTab(
    id: TabId, title: String, paneId: PaneId = PaneId()
) -> TabModel {
    var pane = PaneModel(id: paneId)
    pane.session = SessionModel(id: SessionId(), title: title)
    return TabModel(id: id, paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId))
}

/// A tab whose panes are chained into a right-leaning split tree, so its row shows
/// a pane strip in place of a cwd subtitle.
private func projectionRowSplitTab(
    id: TabId, panes: [(PaneId, String)], focused: PaneId
) -> TabModel {
    let leaves: [SplitNodeModel] = panes.map { paneId, title in
        var pane = PaneModel(id: paneId)
        pane.session = SessionModel(id: SessionId(), title: title)
        return .leaf(pane)
    }
    let root = leaves.dropFirst().reduce(leaves[0]) { accumulated, next in
        .split(id: SplitId(), direction: .horizontal, first: accumulated, second: next, ratio: 0.5)
    }
    return TabModel(id: id, paneTree: PaneTree(root: root, focusedPaneId: focused))
}

private func projectionRowBellAlert(paneId: PaneId) -> AlertModel {
    AlertModel(
        id: AlertId(), kind: .bell, paneId: paneId,
        title: "bell", body: "", createdAt: Date(timeIntervalSince1970: 0), isUnread: true)
}

@discardableResult
private func applyProjectionRowModel(
    _ model: AppModel,
    to sidebar: SidebarView,
    outline: NSOutlineView
) -> SidebarProjection {
    let projection = desiredSidebar(in: model)
    sidebar.applySidebarOps(
        computeSidebarRowOps(old: nil, new: projection),
        projection: projection,
        renameTargetToEnd: nil)
    materializeProjectionRows(sidebar, outline: outline)
    return projection
}

/// Mirrors reconcileSidebar's production pipeline: guard the raw ops with the
/// view-owned rename target, apply, then advance the cache so a suppressed or
/// dropped row keeps its prior projection for the next transition.
@discardableResult
private func applyProjectionRowTransition(
    old oldProjection: SidebarProjection,
    newModel: AppModel,
    to sidebar: SidebarView,
    outline: NSOutlineView,
    runtime: AppRuntime
) -> SidebarProjection {
    let newProjection = desiredSidebar(in: newModel)
    let guarded = guardSidebarRenameOps(
        ops: computeSidebarRowOps(old: oldProjection, new: newProjection),
        renameTarget: sidebar.activeRenameTarget,
        new: newProjection)
    let dropped = sidebar.applySidebarOps(
        guarded.ops, projection: newProjection,
        renameTargetToEnd: guarded.clearRename ? sidebar.activeRenameTarget : nil)
    materializeProjectionRows(sidebar, outline: outline)
    return advanceSidebarCache(
        old: oldProjection, new: newProjection,
        suppressedRenameTarget: sidebar.activeRenameTarget,
        unappliedTabIds: dropped.tabs,
        unappliedGroupIds: dropped.groups)
}

private func materializeProjectionRows(_ sidebar: SidebarView, outline: NSOutlineView) {
    sidebar.layoutSubtreeIfNeeded()
    outline.layoutSubtreeIfNeeded()
    for row in 0..<outline.numberOfRows {
        _ = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
        _ = outline.rowView(atRow: row, makeIfNecessary: true)
    }
}

private func projectionRowTitleLaneWidth(_ cell: SidebarTabCellView) -> CGFloat {
    cell.leadingStack.bounds.maxX - cell.titleField.frame.minX
}

private func projectionRowCell<Cell: NSTableCellView>(
    for target: RenameTarget,
    in outline: NSOutlineView,
    file: String = #file,
    line: Int = #line
) throws -> Cell {
    for row in 0..<outline.numberOfRows {
        guard let item = outline.item(atRow: row) as? SidebarItem else { continue }
        let matches: Bool = {
            switch (target, item.kind) {
            case (.tab(let expected), .tab(let tab)): return expected == tab.id
            case (.group(let expected), .group(let group)): return expected == group.id
            default: return false
            }
        }()
        guard matches,
              let cell = outline.view(
                atColumn: 0, row: row, makeIfNecessary: true) as? Cell
        else { continue }
        return cell
    }
    throw UITestFailure(message: "missing cell for \(target) (\(file):\(line))")
}

/// Assert a group row's three projection-driven accessories at once. `bell` and
/// `tabCount` are nil when the badge should be hidden.
private func assertProjectionRowGroup(
    _ groupId: GroupId,
    in outline: NSOutlineView,
    caret: String,
    title: String,
    hidesSeparator: Bool,
    bell: String?,
    tabCount: String?,
    label: String,
    file: String = #file,
    line: Int = #line
) throws {
    let cell: SidebarGroupCellView = try projectionRowCell(
        for: .group(groupId), in: outline, file: file, line: line)
    try uiExpect(cell.titleField.stringValue == title,
        "\(label): title should show \(title)", file: file, line: line)
    try uiExpect(cell.separator.isHidden == hidesSeparator,
        "\(label): separator visibility should match the row position", file: file, line: line)
    // SF Symbol images carry no readable name and do not compare equal, so the
    // caret direction is checked against a reference symbol's rendered bitmap.
    let expectedCaret = NSImage(systemSymbolName: caret, accessibilityDescription: "Toggle Group")
    try uiExpect(cell.caretButton.image?.tiffRepresentation == expectedCaret?.tiffRepresentation,
        "\(label): caret should show \(caret)", file: file, line: line)

    let shownBell = cell.alertBadge.isHidden ? nil : cell.alertBadge.stringValue
    try uiExpect(shownBell == bell,
        "\(label): bell badge should show \(bell ?? "nothing")", file: file, line: line)

    let shownCount = cell.tabCountBadge.isHidden ? nil : cell.tabCountBadge.stringValue
    try uiExpect(shownCount == tabCount,
        "\(label): tab-count badge should show \(tabCount ?? "nothing")", file: file, line: line)
}

private func findProjectionRowOutlineView(in view: NSView) -> SidebarOutlineView? {
    if let outline = view as? SidebarOutlineView { return outline }
    for subview in view.subviews {
        if let found = findProjectionRowOutlineView(in: subview) {
            return found
        }
    }
    return nil
}
