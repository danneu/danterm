// UI regressions for inline-rename edit state surviving NSOutlineView row teardown.
// Pins the 2026-06-11 "tab spawned with no title" incident: a rename left live while
// its row was torn down by a group collapse strands an editable cell (isEditable=true,
// stuck field-editor display state) in the outline view's reuse pool; the next inserted
// tab row dequeues that cell and renders a blank title forever, even though the model
// title (and the cell's own stringValue) stay correct. These tests drive the real
// SidebarView executor, so they need the WindowServer like the rest of the UI harness.
import Cocoa

func sidebarRenameRecycleTests() {
    print("SidebarRenameRecycle")

    uiTest("collapsing the edited row's group ends the inline rename") {
        // Intent: after a setGroupCollapsed op removes the row being renamed, the
        //   edit is over: re-expanding the group must show a non-editable title
        //   field with the model title, and no live field editor.
        // Why it exists: collapseItem tears down the edited cell without any
        //   NSTextFieldDelegate callback (AppKit aborts, it does not commit), so
        //   none of the rename finish paths run unless the executor ends the edit
        //   itself. A cell left editable here is the poison that later blanks a
        //   freshly inserted tab row (see the recycle test below).
        // Scenario: 2026-06-11 incident -- a `danterm tab new` tab rendered with an
        //   empty sidebar title while `danterm ls` showed the correct model title;
        //   AX inspection found the row's title field stuck editable.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let groupA = GroupId(); let groupB = GroupId()
        let edited = TabId(); let anchor = TabId()
        let initial = renameRecycleModel([
            (groupA, "A", false, [(edited, "alpha")]),
            (groupB, "B", false, [(anchor, "anchor")]),
        ])
        let initialProjection = applyRenameRecycleModel(initial, to: sidebar, outline: outline, old: nil)

        sidebar.beginRenamingTab(edited)
        let editedRow = try renameRecycleRow(for: edited, in: outline)
        let editedCell = outline.view(atColumn: 0, row: editedRow, makeIfNecessary: false) as! NSTableCellView
        try uiExpect(editedCell.textField?.currentEditor() != nil,
            "precondition: rename should attach a live field editor")
        try uiExpect(runtime.viewLocalState.sidebarRenameTarget == .tab(edited),
            "precondition: rename should mirror into the sidecar")

        // Collapse the edited row's group through the production pipeline
        // (guard -> ops -> executor), exactly as reconcileSidebar drives it.
        let collapsed = renameRecycleModel([
            (groupA, "A", true, [(edited, "alpha")]),
            (groupB, "B", false, [(anchor, "anchor")]),
        ])
        let collapsedProjection = applyRenameRecycleTransition(
            old: initialProjection, newModel: collapsed,
            to: sidebar, outline: outline, runtime: runtime)

        let expanded = renameRecycleModel([
            (groupA, "A", false, [(edited, "alpha")]),
            (groupB, "B", false, [(anchor, "anchor")]),
        ])
        _ = applyRenameRecycleTransition(
            old: collapsedProjection, newModel: expanded,
            to: sidebar, outline: outline, runtime: runtime)

        let row = try renameRecycleRow(for: edited, in: outline)
        let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as! NSTableCellView
        try uiExpect(cell.textField?.isEditable == false,
            "re-shown row must not still be editable after collapse ended its rename")
        try uiExpect(cell.textField?.currentEditor() == nil,
            "re-shown row must not have a live field editor")
        try uiExpect(cell.textField?.stringValue == "alpha",
            "re-shown row must display the model title")
    }

    uiTest("Cmd-T while a rename is live ends the edit instead of stranding it") {
        // Intent: a reconcile that inserts a tab and moves the sidebar selection
        //   (what Cmd-T produces) while an inline rename is live must end the
        //   rename cleanly: title field back to non-editable, sidecar cleared.
        // Why it exists: applyRestoreSelection's selectRowIndexes aborts the live
        //   field editor with NO NSTextFieldDelegate callback, so none of the
        //   rename finish paths run. The cell is left isEditable=true, and an
        //   editable NSTextField reports no intrinsic width -- its layout goes
        //   ambiguous, and when that cell (in place, or recycled into a new tab
        //   row later) is re-solved it can collapse to ~2pt and render an empty
        //   title. This is the production strand path that needs no collapse and
        //   no deliberate rename-cancel: any selection-moving reconcile triggers it.
        // Scenario: 2026-06-11 incident, second half -- AX inspection of the live
        //   app found the blank tab's title field editable with frame 2x18 while
        //   stringValue held the correct title.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId()
        let edited = TabId(); let other = TabId(); let spawned = TabId()
        let initial = renameRecycleModel(
            [(group, "G", false, [(edited, "alpha"), (other, "beta")])],
            selected: edited)
        let initialProjection = applyRenameRecycleModel(initial, to: sidebar, outline: outline, old: nil)

        sidebar.beginRenamingTab(edited)
        let editedRow = try renameRecycleRow(for: edited, in: outline)
        let editedCell = outline.view(atColumn: 0, row: editedRow, makeIfNecessary: false) as! NSTableCellView
        try uiExpect(editedCell.textField?.currentEditor() != nil,
            "precondition: rename should attach a live field editor")

        // Cmd-T: new tab appended, selection moves to it.
        let afterCmdT = renameRecycleModel(
            [(group, "G", false, [(edited, "alpha"), (other, "beta"), (spawned, "Terminal")])],
            selected: spawned)
        _ = applyRenameRecycleTransition(
            old: initialProjection, newModel: afterCmdT,
            to: sidebar, outline: outline, runtime: runtime)

        try uiExpect(editedCell.textField?.isEditable == false,
            "selection moving away must end the rename, not strand an editable cell")
        try uiExpect(runtime.viewLocalState.sidebarRenameTarget == nil,
            "selection moving away must clear the rename sidecar")
    }

    uiTest("a tab row inserted after a collapse-stranded rename shows its title") {
        // Intent: a new tab inserted after an edited row was torn down by a group
        //   collapse gets a clean cell: non-editable title field, no field editor,
        //   title text visible.
        // Why it exists: makeTabCell dequeues recycled "TabCell" views without
        //   resetting rename state, so one stranded edit poisons every future row
        //   that draws the recycled cell -- the user-visible half of the incident.
        // Scenario: same 2026-06-11 incident as above; the blank tab was the new
        //   `danterm tab new` row that dequeued the stranded cell.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let groupA = GroupId(); let groupB = GroupId()
        let edited = TabId(); let anchor = TabId(); let spawned = TabId()
        let initial = renameRecycleModel([
            (groupA, "A", false, [(edited, "alpha")]),
            (groupB, "B", false, [(anchor, "anchor")]),
        ])
        let initialProjection = applyRenameRecycleModel(initial, to: sidebar, outline: outline, old: nil)

        sidebar.beginRenamingTab(edited)
        let editedRow = try renameRecycleRow(for: edited, in: outline)
        let editedCell = outline.view(atColumn: 0, row: editedRow, makeIfNecessary: false) as! NSTableCellView
        try uiExpect(editedCell.textField?.currentEditor() != nil,
            "precondition: rename should attach a live field editor")

        let collapsed = renameRecycleModel([
            (groupA, "A", true, [(edited, "alpha")]),
            (groupB, "B", false, [(anchor, "anchor")]),
        ])
        let collapsedProjection = applyRenameRecycleTransition(
            old: initialProjection, newModel: collapsed,
            to: sidebar, outline: outline, runtime: runtime)

        // Spawn a new tab in the other group -- the insertTab op makes a cell,
        // and NSOutlineView may hand back the stranded one from its reuse pool.
        let spawnedModel = renameRecycleModel([
            (groupA, "A", true, [(edited, "alpha")]),
            (groupB, "B", false, [(anchor, "anchor"), (spawned, "fresh tab")]),
        ])
        _ = applyRenameRecycleTransition(
            old: collapsedProjection, newModel: spawnedModel,
            to: sidebar, outline: outline, runtime: runtime)

        let row = try renameRecycleRow(for: spawned, in: outline)
        let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as! NSTableCellView
        try uiExpect(cell.textField?.isEditable == false,
            "freshly inserted tab row must not inherit rename editability from a recycled cell")
        try uiExpect(cell.textField?.currentEditor() == nil,
            "freshly inserted tab row must not have a live field editor")
        try uiExpect(cell.textField?.stringValue == "fresh tab",
            "freshly inserted tab row must display the model title")
    }
}

// MARK: - Harness helpers (local: the selection-cache test helpers are file-private)

private func makeRenameRecycleHarness() -> (SidebarView, NSOutlineView, NSWindow, AppRuntime) {
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
    let outline = findRenameRecycleOutlineView(in: sidebar)!
    return (sidebar, outline, window, runtime)
}

private func renameRecycleModel(
    _ groups: [(GroupId, String, Bool, [(TabId, String)])],
    selected: TabId? = nil
) -> AppModel {
    AppModel(
        groups: groups.map { groupId, name, isCollapsed, tabs in
            GroupModel(
                id: groupId,
                name: name,
                isCollapsed: isCollapsed,
                tabs: tabs.map { tabId, title in
                    let paneId = PaneId()
                    var pane = PaneModel(id: paneId)
                    pane.title = title
                    return TabModel(id: tabId, focusedPaneId: paneId, rootNode: .leaf(pane))
                }
            )
        },
        selectedTabId: selected
    )
}

@discardableResult
private func applyRenameRecycleModel(
    _ model: AppModel,
    to sidebar: SidebarView,
    outline: NSOutlineView,
    old: SidebarProjection?
) -> SidebarProjection {
    let projection = desiredSidebar(in: model)
    sidebar.applySidebarOps(
        computeSidebarRowOps(old: old, new: projection),
        model: model,
        clearActiveRename: false)
    materializeRenameRecycleRows(sidebar, outline: outline)
    return projection
}

/// Mirror reconcileSidebar's production pipeline: guard the raw ops with the
/// runtime's rename sidecar, clear the sidecar when the guard says so, apply,
/// then advance the cache (returned for the next transition).
@discardableResult
private func applyRenameRecycleTransition(
    old oldProjection: SidebarProjection,
    newModel: AppModel,
    to sidebar: SidebarView,
    outline: NSOutlineView,
    runtime: AppRuntime
) -> SidebarProjection {
    let newProjection = desiredSidebar(in: newModel)
    let rawOps = computeSidebarRowOps(old: oldProjection, new: newProjection)
    let guarded = guardSidebarRenameOps(
        ops: rawOps,
        renameTarget: runtime.viewLocalState.sidebarRenameTarget,
        new: newProjection)
    if guarded.clearRename {
        runtime.viewLocalState.sidebarRenameTarget = nil
    }
    sidebar.applySidebarOps(
        guarded.ops, model: newModel, clearActiveRename: guarded.clearRename)
    materializeRenameRecycleRows(sidebar, outline: outline)
    return advanceSidebarCache(
        old: oldProjection, new: newProjection,
        suppressedRenameTarget: runtime.viewLocalState.sidebarRenameTarget)
}

private func materializeRenameRecycleRows(_ sidebar: SidebarView, outline: NSOutlineView) {
    sidebar.layoutSubtreeIfNeeded()
    outline.layoutSubtreeIfNeeded()
    for row in 0..<outline.numberOfRows {
        _ = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
        _ = outline.rowView(atRow: row, makeIfNecessary: true)
    }
}

private func renameRecycleRow(
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

private func findRenameRecycleOutlineView(in view: NSView) -> NSOutlineView? {
    if let outline = view as? NSOutlineView { return outline }
    for subview in view.subviews {
        if let found = findRenameRecycleOutlineView(in: subview) {
            return found
        }
    }
    return nil
}
