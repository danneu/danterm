// UI regressions for the rule that a sidebar cell paints its projection: the row's
// contents are a function of the projection whose row op was applied to it, never of
// a model read at draw time. The tab test drives the deferred-reload path (a rename
// suppresses a row op, then the cell is reconfigured) and the group test drives a
// group row through collapse, unread, and tab-count changes. Both need the real
// SidebarView executor, so they need the WindowServer like the rest of the harness.
import Cocoa
import ChipArtwork
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

// The runner calls this from `@MainActor main()`, so the body is main-actor in
// fact. Saying so lets the closures below reach AppKit cell state.
@MainActor
func sidebarProjectionRowTests() async {
    print("SidebarProjectionRow")

    await uiTest("badge hit testing returns only the tab with a visible badge") {
        // Intent: a point inside a visible tab alert badge resolves that tab, and
        //   the same point resolves nothing after the badge is hidden.
        // Why it exists: the old badge tests built a fake cell from identifier
        //   strings, so they did not exercise the outline view's click consumer.
        // Scenario: spec-first -- a tab's bell is cleared while its row stays
        //   materialized under the pointer.
        let (sidebar, outline, window, _, driver) = makeProjectionRowHarness()
        defer { window.close() }

        let group = GroupId()
        let tab = TabId()
        let pane = PaneId()
        var model = AppModel(
            groups: [GroupModel(id: group, name: "G", tabs: [
                projectionRowTab(id: tab, title: "ringing", paneId: pane),
            ])],
            selectedTabId: tab)
        model.alerts = [sidebarBellAlert(paneId: pane)]
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)

        let cell: SidebarTabCellView = try sidebarCell(for: .tab(tab), in: outline)
        try uiExpect(cell.alertBadge.isHidden == false,
            "alerted tab should have a visible badge")
        let badge = cell.alertBadge
        let badgePoint = outline.convert(
            NSPoint(x: badge.bounds.midX, y: badge.bounds.midY), from: badge)
        try uiExpect(outline.tabForBadgeHit(at: badgePoint) == tab,
            "a point inside the visible badge should resolve its tab")

        model.alerts = []
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)

        try uiExpect(outline.tabForBadgeHit(at: badgePoint) == nil,
            "the badge point should resolve nothing after the badge is hidden")
    }

    await uiTest("clearing a jump key restores its title lane after rename") {
        // Intent: a hidden stored jump badge reserves no width, while an active
        //   rename keeps its current title lane until the deferred repaint lands.
        // Why it exists: storing the badge permanently is safe only if hiding it
        //   collapses its arranged-subview width without resizing a live editor.
        // Scenario: spec-first -- jump mode ends normally, then ends again while
        //   the user is renaming the same tab.
        let (sidebar, outline, window, _, driver) = makeProjectionRowHarness()
        defer { window.close() }

        let group = GroupId()
        let tab = TabId()
        var model = AppModel(
            groups: [GroupModel(id: group, name: "G", tabs: [
                projectionRowTab(id: tab, title: "a title with useful width"),
            ])],
            selectedTabId: tab)
        model.jumpMode = JumpModeState(keyMap: [tab: "a"])
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)
        let cell: SidebarTabCellView = try sidebarCell(for: .tab(tab), in: outline)
        window.contentView?.layoutSubtreeIfNeeded()
        let badgedWidth = projectionRowTitleLaneWidth(cell)

        model.jumpMode = nil
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)
        window.contentView?.layoutSubtreeIfNeeded()
        let clearedWidth = projectionRowTitleLaneWidth(cell)
        try uiExpect(clearedWidth >= badgedWidth + 20,
            "clearing the jump key should return the badge width to the title lane")

        model.jumpMode = JumpModeState(keyMap: [tab: "a"])
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)
        beginRenameThroughModel(
            .tab(tab), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)
        window.contentView?.layoutSubtreeIfNeeded()
        let editingWidth = projectionRowTitleLaneWidth(cell)

        model.jumpMode = nil
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)
        window.contentView?.layoutSubtreeIfNeeded()
        try uiExpect(abs(projectionRowTitleLaneWidth(cell) - editingWidth) <= 0.5,
            "clearing the jump key during rename should not resize the title lane")

        guard let editor = cell.titleField.currentEditor() as? NSTextView else {
            throw UITestFailure(message: "rename should still own the field editor")
        }
        _ = sidebar.control(
            cell.titleField, textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)
        window.contentView?.layoutSubtreeIfNeeded()
        try uiExpect(projectionRowTitleLaneWidth(cell) >= editingWidth + 20,
            "the deferred repaint should return the badge width after rename ends")
    }

    await uiTest("a materialized tab paints every scalar projection field") {
        // Intent: one apply paints the tab title, pane strip, chip, alert badge,
        //   jump badge, and color stripe from the supplied projection.
        // Why it exists: typed access removes silent lookup failures only if each
        //   stored child remains part of the cell's single total paint path.
        // Scenario: spec-first -- a row arrives with every scalar decoration set.
        let (sidebar, outline, window, _, driver) = makeProjectionRowHarness()
        defer { window.close() }

        let group = GroupId()
        let tab = TabId()
        var model = AppModel(groups: [
            GroupModel(id: group, name: "G", tabs: [
                projectionRowTab(id: tab, title: "model title"),
            ]),
        ])
        model.groups[0].tabs[0].customTitle = "painted title"
        model.groups[0].tabs[0].color = .purple
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        model.groups[0].tabs[0].paneTree.updatePane(paneId) { pane in
            pane.session?.cwd = "working directory that must not paint"
            pane.session?.agent = .attached(
                session: AgentSession(kind: "codex", sessionId: "paint-test")!,
                activity: nil)
        }
        model.jumpMode = JumpModeState(keyMap: [tab: "q"])
        model.alerts = (0..<3).map { _ in sidebarBellAlert(paneId: paneId) }
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)

        let cell: SidebarTabCellView = try sidebarCell(for: .tab(tab), in: outline)
        try uiExpect(cell.titleField.stringValue == "painted title",
            "the title should come from the projection")
        try uiExpect(cell.paneStrip.chips.count == 1,
            "the second line should show the tab's sole pane")
        try uiExpect(cell.paneStrip.chips[0].paneId == paneId,
            "the pane strip should identify the sole pane")
        try uiExpect(cell.paneStrip.chips[0].isFocused,
            "the sole pane should be focused")
        try uiExpect(
            projectionRowTextFields(in: cell).allSatisfy {
                $0.stringValue != "working directory that must not paint"
            },
            "the working directory should not appear anywhere in the sidebar row")
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

    await uiTest("a reload suppressed by rename leaves the whole row on its old projection") {
        // Intent: while a rename suppresses a tab's reload, reconfiguring that cell
        //   redraws the projection the row last applied -- title, alert badge, and
        //   pane strip alike -- and a later reconcile converges all three.
        // Why it exists: the cell used to re-derive its badge and strip from a live
        //   `currentModel` read, so a suppressed reload still painted the newer model
        //   and the retained-projection retry was a no-op that looked correct.
        // Scenario: the user renames a split tab while its second pane rings a bell
        //   and its focused pane reports a new title, then ends the rename.
        let (sidebar, outline, window, _, driver) = makeProjectionRowHarness()
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
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)

        let cell: SidebarTabCellView = try sidebarCell(for: .tab(edited), in: outline)
        try uiExpect(cell.textField?.stringValue == "alpha",
            "precondition: the row should start on the old title")
        try uiExpect(cell.alertBadge.isHidden,
            "precondition: the row should start with no visible alert badge")
        try uiExpect(cell.paneStrip.chips.map(\.hasAlert) == [false, false],
            "precondition: neither pane should start marked")

        beginRenameThroughModel(
            .tab(edited), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)
        try uiExpect(cell.textField?.currentEditor() != nil,
            "precondition: rename should attach a live field editor")

        // The model moves under the suppressed row: new focused-pane title, and a
        // bell on the other pane (which moves both the badge and the strip).
        model.groups[0].tabs[0] = projectionRowSplitTab(
            id: edited, panes: [(paneA, "alpha updated"), (paneB, "beta")], focused: paneA)
        model.alerts = [sidebarBellAlert(paneId: paneB)]
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)

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
        try uiExpect(cell.paneStrip.chips.map(\.hasAlert) == [false, false],
            "a reconfigure after a suppressed reload must not paint the newer strip")

        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)

        let converged: SidebarTabCellView = try sidebarCell(
            for: .tab(edited), in: outline)
        try uiExpect(converged.textField?.stringValue == "alpha updated",
            "the retained projection should re-fire the reload and converge the title")
        try uiExpect(
            converged.alertBadge.isHidden == false && converged.alertBadge.stringValue == "1",
            "the retained projection should re-fire the reload and converge the badge")
        try uiExpect(converged.paneStrip.chips.map(\.hasAlert) == [false, true],
            "the retained projection should re-fire the reload and converge the strip")
        try uiExpect(converged.paneStrip.chips.map(\.agent) == [.quiet, .quiet],
            "a bell says nothing about either pane's agent")
    }

    await uiTest("a group row draws its caret and both badges from the applied projection") {
        // Intent: collapse state, unread count, and tab count reach a group cell only
        //   through the projection its row ops carried, in both collapsed and
        //   expanded states.
        // Why it exists: the group cell used to rescan the whole alert list and count
        //   `group.tabs` off a live model, so nothing pinned the caret and the two
        //   badges to the row ops that were actually applied.
        // Scenario: spec-first -- a group collapses while gaining a tab and a bell,
        //   then expands again.
        let (sidebar, outline, window, _, driver) = makeProjectionRowHarness()
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
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)

        try assertProjectionRowGroup(
            groupA, in: outline, caret: "chevron.down",
            title: "A", hidesSeparator: true,
            bell: nil, tabCount: nil, label: "initial expanded group")

        model.groups[0].isCollapsed = true
        model.groups[0].tabs.append(
            projectionRowTab(id: added, title: "three", paneId: addedPane))
        model.alerts = [sidebarBellAlert(paneId: addedPane)]
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)

        try assertProjectionRowGroup(
            groupA, in: outline, caret: "chevron.right",
            title: "A", hidesSeparator: true,
            bell: "1", tabCount: "3", label: "collapsed group")

        model.groups[0].isCollapsed = false
        _ = applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)

        try assertProjectionRowGroup(
            groupA, in: outline, caret: "chevron.down",
            title: "A", hidesSeparator: true,
            bell: nil, tabCount: nil, label: "re-expanded group")
    }

    await uiTest("a missed collapse paint is retained and retried through the group painter") {
        // Intent: a visible group row whose collapse paint cannot fetch its cell is
        //   retained, then converges through the normal group repaint on the next pass.
        // Why it exists: the collapse-only painter bypassed updateGroupRow's dropped-row
        //   result, so the reconcile cache could accept chrome that never reached a cell.
        // Scenario: spec-first -- AppKit temporarily returns no cell while a group
        //   collapses, gains a third tab, and rings, then returns it on the retry.
        let (sidebar, outline, window, _, driver) = makeProjectionRowHarness()
        defer { window.close() }

        var fixture = projectionRowGroupInteractionFixture()
        var initialModel = fixture.model
        initialModel.groups[0].tabs.removeLast()
        initialModel.alerts = []
        _ = applySidebarTestModel(
            initialModel, using: driver, to: sidebar, outline: outline)

        forceNextUnmaterializedCell(forGroup: fixture.groupId, in: sidebar, outline: outline)
        fixture.model.groups[0].isCollapsed = true
        let missed = applySidebarTestModel(
            fixture.model, using: driver, to: sidebar, outline: outline)

        try uiExpect(missed.unappliedGroupIds == [fixture.groupId],
            "a missed collapse paint should retain the group for retry")

        let retried = applySidebarTestModel(
            fixture.model, using: driver, to: sidebar, outline: outline)
        try uiExpect(retried.unappliedGroupIds.isEmpty,
            "the next pass should apply the retained group paint")
        try assertProjectionRowGroup(
            fixture.groupId, in: outline, caret: "chevron.right",
            title: "A", hidesSeparator: true,
            bell: "1", tabCount: "3", label: "retried collapsed group")
    }

    await uiTest("the disclosure path paints group chrome from the reconciled projection") {
        // Intent: disclosure collapse and expand leave the caret, bell, and tab count
        //   on the projection produced by the synchronous toggle reconcile.
        // Why it exists: deleting the delegate's second painter is safe only while the
        //   delegate send remains the one path that updates all group chrome.
        // Scenario: spec-first -- the disclosure triangle collapses and expands a
        //   ringing three-tab group.
        let (sidebar, outline, window, runtime, driver) = makeProjectionRowHarness()
        defer { window.close() }

        var fixture = projectionRowGroupInteractionFixture()
        _ = applySidebarTestModel(
            fixture.model, using: driver, to: sidebar, outline: outline)
        runtime.onSend = { msg in
            guard case .toggleGroupCollapse(let groupId) = msg,
                  let index = fixture.model.groups.firstIndex(where: { $0.id == groupId })
            else { return }
            fixture.model.groups[index].isCollapsed.toggle()
            _ = applySidebarTestModel(
                fixture.model, using: driver, to: sidebar, outline: outline)
        }
        let item = try projectionRowGroupItem(fixture.groupId, in: outline)

        outline.collapseItem(item)
        try assertProjectionRowGroup(
            fixture.groupId, in: outline, caret: "chevron.right",
            title: "A", hidesSeparator: true,
            bell: "1", tabCount: "3", label: "disclosure-collapsed group")

        outline.expandItem(item)
        try assertProjectionRowGroup(
            fixture.groupId, in: outline, caret: "chevron.down",
            title: "A", hidesSeparator: true,
            bell: nil, tabCount: nil, label: "disclosure-expanded group")
    }

    await uiTest("the caret button paints group chrome from the reconciled projection") {
        // Intent: caret-button collapse and expand leave the caret, bell, and tab count
        //   on the projection produced by the synchronous toggle reconcile.
        // Why it exists: the custom caret enters the same AppKit delegate path as the
        //   disclosure triangle and must not need its own collapse-state painter.
        // Scenario: spec-first -- the caret button collapses and expands a ringing
        //   three-tab group.
        let (sidebar, outline, window, runtime, driver) = makeProjectionRowHarness()
        defer { window.close() }

        var fixture = projectionRowGroupInteractionFixture()
        _ = applySidebarTestModel(
            fixture.model, using: driver, to: sidebar, outline: outline)
        runtime.onSend = { msg in
            guard case .toggleGroupCollapse(let groupId) = msg,
                  let index = fixture.model.groups.firstIndex(where: { $0.id == groupId })
            else { return }
            fixture.model.groups[index].isCollapsed.toggle()
            _ = applySidebarTestModel(
                fixture.model, using: driver, to: sidebar, outline: outline)
        }

        let expanded: SidebarGroupCellView = try sidebarCell(
            for: .group(fixture.groupId), in: outline)
        expanded.caretButton.performClick(nil)
        try assertProjectionRowGroup(
            fixture.groupId, in: outline, caret: "chevron.right",
            title: "A", hidesSeparator: true,
            bell: "1", tabCount: "3", label: "caret-collapsed group")

        let collapsed: SidebarGroupCellView = try sidebarCell(
            for: .group(fixture.groupId), in: outline)
        collapsed.caretButton.performClick(nil)
        try assertProjectionRowGroup(
            fixture.groupId, in: outline, caret: "chevron.down",
            title: "A", hidesSeparator: true,
            bell: nil, tabCount: nil, label: "caret-expanded group")
    }
}

// MARK: - Harness helpers

@MainActor
private func makeProjectionRowHarness() -> (
    SidebarView, SidebarOutlineView, NSWindow, RecordingAppRuntime, SidebarReconcileDriver
) {
    let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 420))
    let runtime = makeUITestRuntime()
    sidebar.runtime = runtime
    let window = NSWindow(
        contentRect: sidebar.frame,
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = sidebar
    window.layoutIfNeeded()
    let outline = sidebarOutlineView(in: sidebar) as! SidebarOutlineView
    return (sidebar, outline, window, runtime, SidebarReconcileDriver())
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

private func projectionRowTitleLaneWidth(_ cell: SidebarTabCellView) -> CGFloat {
    cell.leadingStack.bounds.maxX - cell.titleField.frame.minX
}

private func projectionRowTextFields(in root: NSView) -> [NSTextField] {
    root.subviews.flatMap { view in
        (view as? NSTextField).map { [$0] } ?? projectionRowTextFields(in: view)
    }
}

private func projectionRowGroupInteractionFixture() -> (
    model: AppModel, groupId: GroupId
) {
    let group = GroupId(); let anchorGroup = GroupId()
    let first = TabId(); let second = TabId(); let third = TabId(); let anchor = TabId()
    let ringingPane = PaneId()
    var model = AppModel(
        groups: [
            GroupModel(id: group, name: "A", tabs: [
                projectionRowTab(id: first, title: "one"),
                projectionRowTab(id: second, title: "two"),
                projectionRowTab(id: third, title: "three", paneId: ringingPane),
            ]),
            GroupModel(id: anchorGroup, name: "B", tabs: [
                projectionRowTab(id: anchor, title: "anchor"),
            ]),
        ],
        selectedTabId: first)
    model.alerts = [sidebarBellAlert(paneId: ringingPane)]
    return (model, group)
}

private func projectionRowGroupItem(
    _ groupId: GroupId,
    in outline: NSOutlineView
) throws -> SidebarItem {
    let cell: SidebarGroupCellView = try sidebarCell(
        for: .group(groupId), in: outline)
    let row = outline.row(for: cell)
    guard row >= 0, let item = outline.item(atRow: row) as? SidebarItem else {
        throw UITestFailure(message: "missing item for group \(groupId)")
    }
    return item
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
    let cell: SidebarGroupCellView = try sidebarCell(
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
