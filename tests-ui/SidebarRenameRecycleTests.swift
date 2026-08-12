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

    uiTest("a resized sidebar row immediately resizes its materialized cell") {
        // Intent: a hosted cell follows the row's complete bounds as soon as AppKit
        //   changes the row frame, without requiring a later layout pass.
        // Why it exists: NSOutlineView can resize an NSTableRowView without scheduling
        //   layout on that row, leaving an already-materialized cell stale.
        // Scenario: the sidebar row grows from 200 to 300 points after its cell exists,
        //   through the same setFrameSize hook AppKit uses during sidebar resizing.
        let row = SidebarRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let cell = NSTableCellView(frame: row.bounds)
        row.addSubview(cell)

        row.setFrameSize(NSSize(width: 300, height: 40))

        try uiExpect(cell.frame == row.bounds,
            "materialized cell should follow the resized row without a layout pass")
    }

    uiTest("sidebar cells and accessories track the visible content width") {
        // Intent: group and tab cells span the clip view, and their trailing
        //   accessories keep the declared inset at initial, narrow, and wide sizes.
        // Why it exists: NSOutlineView can resize a row while leaving its already-
        //   materialized cell at the old width, which strands accessories beside titles.
        // Scenario: a visible legacy scroller narrows the content area while the user
        //   drags the sidebar through its supported 200...300 point range.
        let (sidebar, outline, window, _) = makeRenameRecycleHarness()
        defer { window.close() }

        let groupA = GroupId(); let groupB = GroupId()
        let tab = TabId(); let anchor = TabId()
        let overflowTabs = (0..<12).map { _ in
            (TabId(), "overflow")
        }
        var model = renameRecycleModel([
            (groupA, "Primary", false, [(tab, "short")] + overflowTabs),
            (groupB, "Secondary", false, [(anchor, "anchor")]),
        ], selected: tab)
        model.alerts = [renameRecycleBellAlert(paneId: model.groups[0].tabs[0].focusedPaneId)]

        let scroll = findRenameRecycleScrollView(in: sidebar)!
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        _ = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)

        for width in [260.0, 200.0, 300.0] {
            window.setContentSize(NSSize(width: width, height: 140))
            materializeRenameRecycleRows(sidebar, outline: outline)

            let groupCell = try renameRecycleCell(for: .group(groupA), in: outline)
            let tabCell = try renameRecycleCell(for: .tab(tab), in: outline)
            try expectCellFillsVisibleContent(groupCell, scroll: scroll, label: "group at \(width)")
            try expectCellFillsVisibleContent(tabCell, scroll: scroll, label: "tab at \(width)")
            try expectAccessoryTrailingInset(
                in: groupCell, identifier: "groupCaretButton", inset: 2,
                scroll: scroll, label: "group at \(width)")
            try expectAccessoryTrailingInset(
                in: tabCell, identifier: "bellDot", inset: 2,
                scroll: scroll, label: "tab at \(width)")
        }
    }

    uiTest("titles and inline rename do not move the accessory lane") {
        // Intent: short and long titles truncate before a visible alert badge and
        //   preserve its trailing alignment through rename commit and cancellation.
        // Why it exists: title intrinsic size and field-editor teardown must not become
        //   accidental authorities for accessory placement.
        // Scenario: the user renames a badged tab at the narrow sidebar limit, commits
        //   a long draft, then starts another rename and cancels it.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        window.setContentSize(NSSize(width: 200, height: 180))
        let groupA = GroupId(); let groupB = GroupId()
        let tab = TabId(); let anchor = TabId()
        var model = renameRecycleModel([
            (groupA, "Primary", false, [(tab, "short")]),
            (groupB, "Secondary", false, [(anchor, "anchor")]),
        ], selected: tab)
        model.alerts = [renameRecycleBellAlert(paneId: model.groups[0].tabs[0].focusedPaneId)]
        var projection = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        let scroll = findRenameRecycleScrollView(in: sidebar)!
        let cell = try renameRecycleCell(for: .tab(tab), in: outline)
        guard let titleField = cell.textField else {
            throw UITestFailure(message: "tab cell should have a title field")
        }

        try expectTabTitlePrecedesAccessory(in: cell)
        try expectAccessoryTrailingInset(
            in: cell, identifier: "bellDot", inset: 2,
            scroll: scroll, label: "short display title")

        sidebar.beginRenamingTab(tab)
        let longTitle = String(repeating: "long title ", count: 12)
        titleField.stringValue = longTitle
        window.contentView?.layoutSubtreeIfNeeded()
        try expectTabTitlePrecedesAccessory(in: cell)
        try expectAccessoryTrailingInset(
            in: cell, identifier: "bellDot", inset: 2,
            scroll: scroll, label: "long rename draft")
        guard let commitEditor = titleField.currentEditor() as? NSTextView else {
            throw UITestFailure(message: "rename should install a field editor")
        }
        _ = sidebar.control(
            titleField, textView: commitEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        model.groups[0].tabs[0].customTitle = longTitle
        projection = applyRenameRecycleTransition(
            old: projection, newModel: model,
            to: sidebar, outline: outline, runtime: runtime)
        materializeRenameRecycleRows(sidebar, outline: outline)
        try uiExpect(titleField.stringValue == longTitle,
            "committed long title should reach display mode")
        try expectTabTitlePrecedesAccessory(in: cell)
        try expectAccessoryTrailingInset(
            in: cell, identifier: "bellDot", inset: 2,
            scroll: scroll, label: "after rename commit")

        sidebar.beginRenamingTab(tab)
        titleField.stringValue = "cancelled draft"
        guard let cancelEditor = titleField.currentEditor() as? NSTextView else {
            throw UITestFailure(message: "second rename should install a field editor")
        }
        _ = sidebar.control(
            titleField, textView: cancelEditor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        materializeRenameRecycleRows(sidebar, outline: outline)
        try uiExpect(titleField.stringValue == longTitle,
            "rename cancellation should restore the committed title")
        try expectTabTitlePrecedesAccessory(in: cell)
        try expectAccessoryTrailingInset(
            in: cell, identifier: "bellDot", inset: 2,
            scroll: scroll, label: "after rename cancellation")

        model.groups[0].tabs[0].customTitle = "changed"
        _ = applyRenameRecycleTransition(
            old: projection, newModel: model,
            to: sidebar, outline: outline, runtime: runtime)
        materializeRenameRecycleRows(sidebar, outline: outline)
        try expectAccessoryTrailingInset(
            in: cell, identifier: "bellDot", inset: 2,
            scroll: scroll, label: "after title change")
    }

    uiTest("tab and group rename fields retain their title lanes") {
        // Intent: editable tab and group title fields keep useful horizontal space,
        //   including when the tab shares its leading lane with a jump badge.
        // Why it exists: NSTextField loses intrinsic horizontal width while editable;
        //   a title lane constrained only by an upper bound can collapse to about 2pt.
        // Scenario: the 2026-07-17 incident showed a correct title string in a nearly
        //   zero-width field after inline rename state became stranded.
        let (sidebar, outline, window, _) = makeRenameRecycleHarness()
        defer { window.close() }

        let groupA = GroupId(); let groupB = GroupId()
        let tab = TabId(); let anchor = TabId()
        var model = renameRecycleModel([
            (groupA, "A useful group title", false, [(tab, "a useful tab title")]),
            (groupB, "Anchor", false, [(anchor, "anchor")]),
        ], selected: tab)
        model.jumpMode = JumpModeState(keyMap: [tab: "a"])
        _ = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)

        sidebar.beginRenamingTab(tab)
        let tabCell = try renameRecycleCell(for: .tab(tab), in: outline)
        tabCell.textField?.frame.size.width = 0
        tabCell.textField?.invalidateIntrinsicContentSize()
        window.contentView?.layoutSubtreeIfNeeded()
        try uiExpect((tabCell.textField?.frame.width ?? 0) > 80,
            "editable tab title should retain useful width beside its jump badge")

        window.makeFirstResponder(nil)
        sidebar.beginRenamingGroup(groupA)
        let groupCell = try renameRecycleCell(for: .group(groupA), in: outline)
        groupCell.textField?.frame.size.width = 0
        groupCell.textField?.invalidateIntrinsicContentSize()
        window.contentView?.layoutSubtreeIfNeeded()
        try uiExpect((groupCell.textField?.frame.width ?? 0) > 80,
            "editable group title should retain useful width beside its accessories")
    }

    uiTest("committing an inline group rename dispatches the group rename once") {
        // Intent: Enter on a live group inline rename renames that group exactly
        //   once, and returns the title field to display state.
        // Why it exists: this is the only test that drives the group branch of the
        //   AssociatedKeys.renameTarget commit path. Every other behavioral test in
        //   this suite renames a tab, and the one group test asserts layout lanes
        //   only, so a group-only regression in that path would go unseen.
        // Scenario: the user double-clicks a group row, types a new name, and
        //   presses Enter.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId(); let other = GroupId()
        let tab = TabId(); let anchor = TabId()
        let model = renameRecycleModel([
            (group, "Primary", false, [(tab, "alpha")]),
            (other, "Secondary", false, [(anchor, "beta")]),
        ], selected: tab)
        _ = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)

        sidebar.beginRenamingGroup(group)
        let cell = try renameRecycleCell(for: .group(group), in: outline)
        guard let titleField = cell.textField else {
            throw UITestFailure(message: "group cell should have a title field")
        }
        titleField.stringValue = "Release work"
        guard let editor = titleField.currentEditor() as? NSTextView else {
            throw UITestFailure(message: "group rename should install a field editor")
        }

        _ = sidebar.control(
            titleField, textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:)))

        let renameMessages = runtime.sentMessages.filter {
            if case .renameGroup(let id, let name) = $0 {
                return id == group && name == "Release work"
            }
            return false
        }
        try uiExpect(renameMessages.count == 1,
            "committing a group rename should dispatch exactly one renameGroup message")
        try uiExpect(runtime.viewLocalState.sidebarRenameTarget == nil,
            "committing a group rename should clear rename ownership")
        try uiExpect(titleField.isEditable == false,
            "committing a group rename should return the title field to display state")
    }

    uiTest("pointer click-away commits a live rename exactly once") {
        // Intent: an outline pointer interaction commits the current draft before
        //   AppKit can discard the editor, without producing duplicate rename sends.
        // Why it exists: direct-click ordering can remove the field editor before
        //   selection reconciliation, bypassing the normal delegate completion path.
        // Scenario: the user edits a tab title and clicks another sidebar row.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId(); let tab = TabId(); let other = TabId()
        let model = renameRecycleModel(
            [(group, "G", false, [(tab, "alpha"), (other, "beta")])],
            selected: tab)
        _ = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        sidebar.beginRenamingTab(tab)
        let cell = try renameRecycleCell(for: .tab(tab), in: outline)
        cell.textField?.stringValue = "renamed"

        sidebar.finishActiveRenameForPointerInteraction()

        let renameMessages = runtime.sentMessages.filter {
            if case .renameTab(let id, let name) = $0 {
                return id == tab && name == "renamed"
            }
            return false
        }
        try uiExpect(renameMessages.count == 1,
            "pointer click-away should dispatch exactly one rename message")
        try uiExpect(sidebar.activeRenameTarget == nil,
            "pointer click-away should synchronously clear rename ownership")
        try uiExpect(cell.textField?.isEditable == false,
            "pointer click-away should return the title field to display state")
    }

    uiTest("group commit cancel and click-away each end ownership once") {
        // Intent: group Enter commits, Escape cancels, and click-away commits with
        //   the same exactly-once ownership rules as tab rename.
        // Why it exists: group rename skips empty commits and uses a different message,
        //   so tab coverage cannot prove its delegate paths.
        // Scenario: three successive edits of one group exercise every user exit.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let groupA = GroupId(); let groupB = GroupId()
        let tabA = TabId(); let tabB = TabId()
        let model = renameRecycleModel([
            (groupA, "A", false, [(tabA, "alpha")]),
            (groupB, "B", false, [(tabB, "beta")]),
        ])
        _ = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        let field = try renameRecycleCell(for: .group(groupA), in: outline).textField!

        sidebar.beginRenamingGroup(groupA)
        field.stringValue = "committed"
        let commitStart = runtime.sentMessages.count
        let commitEditor = try requireRenameRecycleEditor(field)
        _ = sidebar.control(
            field, textView: commitEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        let commitMessages = Array(runtime.sentMessages[commitStart...])
        try uiExpect(commitMessages.count == 2,
            "group Enter should send rename then rename-ended")
        guard case .renameGroup(let committedId, let committedName) = commitMessages[0],
              case .sidebarRenameEnded = commitMessages[1] else {
            throw UITestFailure(message: "group Enter sent the wrong message order")
        }
        try uiExpect(committedId == groupA && committedName == "committed",
            "group Enter should commit the trimmed draft")
        try uiExpect(sidebar.activeRenameTarget == nil,
            "group Enter should clear ownership")

        sidebar.beginRenamingGroup(groupA)
        field.stringValue = "cancelled"
        let cancelStart = runtime.sentMessages.count
        let cancelEditor = try requireRenameRecycleEditor(field)
        _ = sidebar.control(
            field, textView: cancelEditor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        let cancelMessages = Array(runtime.sentMessages[cancelStart...])
        try uiExpect(cancelMessages.count == 1,
            "group Escape should send only rename-ended")
        guard case .sidebarRenameEnded = cancelMessages[0] else {
            throw UITestFailure(message: "group Escape should not send renameGroup")
        }
        try uiExpect(sidebar.activeRenameTarget == nil,
            "group Escape should clear ownership")

        sidebar.beginRenamingGroup(groupA)
        field.stringValue = "click away"
        let clickStart = runtime.sentMessages.count
        sidebar.finishActiveRenameForPointerInteraction()
        let clickMessages = Array(runtime.sentMessages[clickStart...])
        try uiExpect(clickMessages.count == 1,
            "group click-away should dispatch exactly once")
        guard case .renameGroup(let clickedId, let clickedName) = clickMessages[0] else {
            throw UITestFailure(message: "group click-away should send renameGroup")
        }
        try uiExpect(clickedId == groupA && clickedName == "click away",
            "group click-away should commit its draft")
        try uiExpect(sidebar.activeRenameTarget == nil,
            "group click-away should clear ownership")
        try uiExpect(field.isEditable == false,
            "every group exit should restore display state")
    }

    uiTest("reconcile cancels a rename whose field editor AppKit discarded") {
        // Intent: rename ownership and the editable field are normalized when AppKit has
        //   removed the field editor, even if sidebar selection already matches.
        // Why it exists: selection's no-op fast path previously trusted stale ownership and
        //   skipped cleanup, leaving stale editable state able to collapse the title.
        // Scenario: a direct row click changes selection, AppKit discards the editor,
        //   and the following reconcile observes the already-matching selection.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId(); let tab = TabId(); let other = TabId()
        let model = renameRecycleModel(
            [(group, "G", false, [(tab, "alpha"), (other, "beta")])],
            selected: tab)
        let projection = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        sidebar.beginRenamingTab(tab)
        let cell = try renameRecycleCell(for: .tab(tab), in: outline)
        cell.textField?.stringValue = "stale draft"
        cell.textField?.abortEditing()
        try uiExpect(cell.textField?.currentEditor() == nil,
            "precondition: AppKit should have discarded the field editor")

        _ = applyRenameRecycleTransition(
            old: projection, newModel: model,
            to: sidebar, outline: outline, runtime: runtime)

        try uiExpect(sidebar.activeRenameTarget == nil,
            "abandoned editor should clear the authoritative rename target")
        try uiExpect(cell.textField?.isEditable == false,
            "abandoned editor should return the title field to display state")
        try uiExpect(cell.textField?.stringValue == "alpha",
            "abandoned editor should restore the model title instead of stale draft text")
    }

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
        try uiExpect(sidebar.activeRenameTarget == .tab(edited),
            "precondition: the view should own the tab rename")

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
        //   rename cleanly: title field back to non-editable, ownership cleared.
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
        try uiExpect(sidebar.activeRenameTarget == nil,
            "selection moving away must clear rename ownership")
    }

    uiTest("cosmetic sweep with unchanged selection leaves inline rename intact") {
        // Intent: an empty-op reconcile whose selection target already matches the
        //   live view leaves an active inline rename alone.
        // Why it exists: the selection no-op guard must bail before redundant
        //   NSOutlineView reselection can interfere with the field editor.
        // Scenario: a pane churns cosmetic updates while the user is editing a tab
        //   title in the sidebar.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId()
        let edited = TabId()
        let other = TabId()
        let model = renameRecycleModel(
            [(group, "G", false, [(edited, "alpha"), (other, "beta")])],
            selected: edited)
        let projection = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)

        sidebar.beginRenamingTab(edited)
        let editedRow = try renameRecycleRow(for: edited, in: outline)
        let editedCell = outline.view(atColumn: 0, row: editedRow, makeIfNecessary: false) as! NSTableCellView
        try uiExpect(editedCell.textField?.currentEditor() != nil,
            "precondition: rename should attach a live field editor")
        try uiExpect(sidebar.activeRenameTarget == .tab(edited),
            "precondition: the view should own the tab rename")

        _ = applyRenameRecycleTransition(
            old: projection, newModel: model,
            to: sidebar, outline: outline, runtime: runtime)

        try uiExpect(editedCell.textField?.currentEditor() != nil,
            "cosmetic sweep should leave the live field editor attached")
        try uiExpect(sidebar.activeRenameTarget == .tab(edited),
            "cosmetic sweep should preserve rename ownership")
    }

    uiTest("selection-ending rename resync retains a dropped tab reload") {
        // Intent: the inline resync that runs after a selection change ends a live
        //   rename feeds dropped row ids into the sidebar cache advance.
        // Why it exists: covers the direct updateTabRow call site in
        //   applyRestoreSelection, not just explicit reloadTab row ops.
        // Scenario: Cmd-T changes selection while the edited tab also has a pending
        //   row-attr update, and the resync cell fetch is transiently unavailable.
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

        let afterCmdT = renameRecycleModel(
            [(group, "G", false, [(edited, "alpha updated"), (other, "beta"), (spawned, "Terminal")])],
            selected: spawned)
        sidebar.testForceNextNilCellTabIds.insert(edited)
        let dropped = applyRenameRecycleTransitionResult(
            old: initialProjection, newModel: afterCmdT,
            to: sidebar, outline: outline, runtime: runtime)

        try uiExpect(dropped.droppedTabs == Set([edited]),
            "rename resync should report the dropped edited tab")
        try uiExpect(sidebar.activeRenameTarget == nil,
            "selection-moving reconcile should still clear rename ownership")
        try uiExpect(editedCell.textField?.stringValue == "alpha",
            "dropped resync should leave the old edited-row title visible")

        let repainted = applyRenameRecycleTransitionResult(
            old: dropped.advancedProjection, newModel: afterCmdT,
            to: sidebar, outline: outline, runtime: runtime)

        let updatedRow = try renameRecycleRow(for: edited, in: outline)
        let updatedCell = outline.view(atColumn: 0, row: updatedRow, makeIfNecessary: false) as! NSTableCellView
        try uiExpect(repainted.droppedTabs.isEmpty,
            "retry should fetch and paint the edited tab row")
        try uiExpect(updatedCell.textField?.stringValue == "alpha updated",
            "retry should repaint the edited row from the live model")
    }

    uiTest("group structural exits end the exact live rename") {
        // Intent: removal, a full row rebuild, and selection movement each end a
        //   live group rename and restore its field from model-backed display state.
        // Why it exists: group editors cross different outline teardown paths than
        //   tab editors and must obey the same single-owner exit invariant.
        // Scenario: three independent reconciles invalidate an edited group row.
        enum Exit {
            case removal
            case rebuild
            case selection
        }

        for exit in [Exit.removal, .rebuild, .selection] {
            let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
            let groupA = GroupId(); let groupB = GroupId(); let groupC = GroupId()
            let tabA = TabId(); let tabB = TabId(); let tabC = TabId()
            let initial = renameRecycleModel([
                (groupA, "A", false, [(tabA, "alpha")]),
                (groupB, "B", false, [(tabB, "beta")]),
                (groupC, "C", false, [(tabC, "gamma")]),
            ], selected: tabA)
            let projection = applyRenameRecycleModel(
                initial, to: sidebar, outline: outline, old: nil)
            sidebar.beginRenamingGroup(groupA)
            let field = try renameRecycleCell(for: .group(groupA), in: outline).textField!
            field.stringValue = "stale draft"

            let next: AppModel
            switch exit {
            case .removal:
                next = renameRecycleModel([
                    (groupB, "B", false, [(tabB, "beta")]),
                    (groupC, "C", false, [(tabC, "gamma")]),
                ], selected: tabB)
            case .rebuild:
                next = renameRecycleModel([
                    (groupA, "A", false, [(tabA, "alpha")]),
                ], selected: tabA)
            case .selection:
                next = renameRecycleModel([
                    (groupA, "A", false, [(tabA, "alpha")]),
                    (groupB, "B", false, [(tabB, "beta")]),
                    (groupC, "C", false, [(tabC, "gamma")]),
                ], selected: tabB)
            }

            _ = applyRenameRecycleTransition(
                old: projection, newModel: next,
                to: sidebar, outline: outline, runtime: runtime)

            try uiExpect(sidebar.activeRenameTarget == nil,
                "\(exit) should clear the group rename session")
            try uiExpect(field.isEditable == false,
                "\(exit) should restore the group field to display state")
            try uiExpect(field.currentEditor() == nil,
                "\(exit) should remove the group field editor")
            try uiExpect(field.stringValue == "A",
                "\(exit) should restore the model-backed group name")
            window.close()
        }
    }

    uiTest("starting another rename commits the prior field before owning the successor") {
        // Intent: replacement commits the prior draft once, then transfers ownership
        //   to the successor field; a stale callback from the prior field is inert.
        // Why it exists: the old field and runtime sidecar were separate owners, so a
        //   late callback could clear or complete a newer edit session.
        // Scenario: the user edits one tab, starts renaming another, and AppKit then
        //   delivers a delayed end-editing callback for the first field.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId(); let first = TabId(); let second = TabId()
        let model = renameRecycleModel(
            [(group, "G", false, [(first, "alpha"), (second, "beta")])],
            selected: first)
        _ = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        sidebar.beginRenamingTab(first)
        let firstField = try renameRecycleCell(for: .tab(first), in: outline).textField!
        firstField.stringValue = "first draft"
        var targetDuringPriorDispatch: RenameTarget?
        runtime.onSend = { msg in
            if case .renameTab(let id, _) = msg, id == first {
                targetDuringPriorDispatch = sidebar.activeRenameTarget
            }
        }

        sidebar.beginRenamingTab(second)
        runtime.onSend = nil

        let firstRenames = runtime.sentMessages.filter {
            if case .renameTab(let id, let name) = $0 {
                return id == first && name == "first draft"
            }
            return false
        }
        try uiExpect(firstRenames.count == 1,
            "replacement should commit the prior draft exactly once")
        try uiExpect(targetDuringPriorDispatch == nil,
            "successor ownership must not exist while the prior rename dispatches")
        try uiExpect(sidebar.activeRenameTarget == .tab(second),
            "successor should become active only after the prior commit")

        _ = sidebar.control(firstField, textShouldEndEditing: NSTextView())
        _ = sidebar.control(NSTextField(), textShouldEndEditing: NSTextView())

        try uiExpect(sidebar.activeRenameTarget == .tab(second),
            "stale prior-field callback must not clear the successor session")
        let afterStaleCallback = runtime.sentMessages.filter {
            if case .renameTab(let id, _) = $0 { return id == first }
            return false
        }
        try uiExpect(afterStaleCallback.count == 1,
            "stale prior-field callback must not dispatch a second rename")
    }

    uiTest("reuse reset clears an abandoned session without a reconcile") {
        // Intent: resetting a reused cell clears the session that owns its field even
        //   when AppKit discarded the editor without a delegate callback.
        // Why it exists: cell reuse is the last ownership boundary before stale edit
        //   state can paint a different row.
        // Scenario: AppKit aborts a tab editor and immediately returns its cell for reuse.
        let (sidebar, outline, window, _) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId(); let tab = TabId()
        let model = renameRecycleModel([(group, "G", false, [(tab, "alpha")])])
        _ = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        sidebar.beginRenamingTab(tab)
        let cell = try renameRecycleCell(for: .tab(tab), in: outline)
        cell.textField?.abortEditing()

        sidebar.testResetRecycledRenameState(cell)

        try uiExpect(sidebar.activeRenameTarget == nil,
            "reuse reset should clear ownership of the discarded editor")
        try uiExpect(cell.textField?.isEditable == false,
            "reuse reset should restore display state")
    }

    uiTest("a reconfigured group caret acts on its latest typed group") {
        // Intent: a reused group row's caret expands or collapses the group assigned by
        //   its latest configuration.
        // Why it exists: reusable controls must not retain action identity from a prior row.
        // Scenario: a cell first paints group A, is reconfigured for group B, then its
        //   caret is invoked.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let groupA = GroupId(); let groupB = GroupId()
        let tabA = TabId(); let tabB = TabId()
        let model = renameRecycleModel([
            (groupA, "A", false, [(tabA, "alpha")]),
            (groupB, "B", false, [(tabB, "beta")]),
        ])
        let projection = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        let cell = try renameRecycleCell(for: .group(groupA), in: outline)
        let groupBProjection = projection.groups.first { $0.id == groupB }!

        sidebar.testConfigureGroupCell(cell, group: groupBProjection)
        guard let stack = cell.subviews.first(where: {
            $0.identifier?.rawValue == "groupAccessoryStack"
        }) as? NSStackView,
        let caret = stack.arrangedSubviews.first(where: {
            $0.identifier?.rawValue == "groupCaretButton"
        }) as? NSButton else {
            throw UITestFailure(message: "group cell should contain a caret")
        }
        caret.performClick(nil)

        try uiExpect(runtime.sentMessages.contains {
            if case .toggleGroupCollapse(let id) = $0 { return id == groupB }
            return false
        }, "reconfigured caret should act on group B")
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
        var spawnedModel = renameRecycleModel([
            (groupA, "A", true, [(edited, "alpha")]),
            (groupB, "B", false, [(anchor, "anchor"), (spawned, "fresh tab")]),
        ])
        spawnedModel.alerts = [renameRecycleBellAlert(
            paneId: spawnedModel.groups[1].tabs[1].focusedPaneId)]
        _ = applyRenameRecycleTransition(
            old: collapsedProjection, newModel: spawnedModel,
            to: sidebar, outline: outline, runtime: runtime)

        let row = try renameRecycleRow(for: spawned, in: outline)
        let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as! NSTableCellView
        try uiExpect(cell === editedCell,
            "precondition: the inserted row should reuse the edited cell")
        try uiExpect(cell.textField?.isEditable == false,
            "freshly inserted tab row must not inherit rename editability from a recycled cell")
        try uiExpect(cell.textField?.currentEditor() == nil,
            "freshly inserted tab row must not have a live field editor")
        try uiExpect(cell.textField?.stringValue == "fresh tab",
            "freshly inserted tab row must display the model title")
        let scroll = findRenameRecycleScrollView(in: sidebar)!
        try expectCellFillsVisibleContent(cell, scroll: scroll, label: "recycled tab")
        try expectAccessoryTrailingInset(
            in: cell, identifier: "bellDot", inset: 2,
            scroll: scroll, label: "recycled tab")
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
                    pane.session = SessionModel(id: SessionId(), title: title)
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
        projection: projection,
        renameTargetToEnd: nil)
    materializeRenameRecycleRows(sidebar, outline: outline)
    return projection
}

/// Mirrors reconcileSidebar's production pipeline: read the target from the
/// view-owned session, guard and apply the raw ops, then advance the cache.
@discardableResult
private func applyRenameRecycleTransition(
    old oldProjection: SidebarProjection,
    newModel: AppModel,
    to sidebar: SidebarView,
    outline: NSOutlineView,
    runtime: AppRuntime
) -> SidebarProjection {
    applyRenameRecycleTransitionResult(
        old: oldProjection, newModel: newModel,
        to: sidebar, outline: outline, runtime: runtime
    ).advancedProjection
}

@discardableResult
private func applyRenameRecycleTransitionResult(
    old oldProjection: SidebarProjection,
    newModel: AppModel,
    to sidebar: SidebarView,
    outline: NSOutlineView,
    runtime: AppRuntime
) -> (
    advancedProjection: SidebarProjection,
    droppedTabs: Set<TabId>,
    droppedGroups: Set<GroupId>
) {
    let newProjection = desiredSidebar(in: newModel)
    let rawOps = computeSidebarRowOps(old: oldProjection, new: newProjection)
    let guarded = guardSidebarRenameOps(
        ops: rawOps,
        renameTarget: sidebar.activeRenameTarget,
        new: newProjection)
    let dropped = sidebar.applySidebarOps(
        guarded.ops, model: newModel, projection: newProjection,
        renameTargetToEnd: guarded.clearRename ? sidebar.activeRenameTarget : nil)
    materializeRenameRecycleRows(sidebar, outline: outline)
    let advanced = advanceSidebarCache(
        old: oldProjection, new: newProjection,
        suppressedRenameTarget: sidebar.activeRenameTarget,
        unappliedTabIds: dropped.tabs,
        unappliedGroupIds: dropped.groups)
    return (advanced, dropped.tabs, dropped.groups)
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

private func renameRecycleCell(
    for target: RenameTarget,
    in outline: NSOutlineView,
    file: String = #file,
    line: Int = #line
) throws -> NSTableCellView {
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
                atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
        else { continue }
        return cell
    }
    throw UITestFailure(message: "missing cell for \(target) (\(file):\(line))")
}

private func requireRenameRecycleEditor(_ field: NSTextField) throws -> NSTextView {
    guard let editor = field.currentEditor() as? NSTextView else {
        throw UITestFailure(message: "rename should install a field editor")
    }
    return editor
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

/// Finds the production scroll view without exposing it on SidebarView solely for tests.
private func findRenameRecycleScrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for subview in view.subviews {
        if let found = findRenameRecycleScrollView(in: subview) {
            return found
        }
    }
    return nil
}

/// Builds the unread alert needed to keep the tab's trailing badge visible.
private func renameRecycleBellAlert(paneId: PaneId) -> AlertModel {
    AlertModel(
        id: AlertId(),
        kind: .bell,
        paneId: paneId,
        title: "Bell",
        body: "",
        createdAt: Date(timeIntervalSince1970: 0),
        isUnread: true)
}

/// Compares a materialized cell with the clip view in one coordinate space.
private func expectCellFillsVisibleContent(
    _ cell: NSTableCellView,
    scroll: NSScrollView,
    label: String
) throws {
    let clip = scroll.contentView
    let frame = clip.convert(cell.bounds, from: cell)
    try uiExpect(abs(frame.minX - clip.bounds.minX) < 0.5,
        "\(label) cell should meet the visible leading edge")
    try uiExpect(abs(frame.maxX - clip.bounds.maxX) < 0.5,
        "\(label) cell should meet the visible trailing edge")
}

/// Verifies a cell-relative accessory keeps its production trailing inset from the clip view.
private func expectAccessoryTrailingInset(
    in cell: NSTableCellView,
    identifier: String,
    inset: CGFloat,
    scroll: NSScrollView,
    label: String
) throws {
    guard let accessory = findRenameRecycleDescendant(
        in: cell, identifier: NSUserInterfaceItemIdentifier(identifier))
    else {
        throw UITestFailure(message: "missing \(identifier)")
    }
    let clip = scroll.contentView
    let frame = clip.convert(accessory.bounds, from: accessory)
    let actualInset = clip.bounds.maxX - frame.maxX
    try uiExpect(abs(actualInset - inset) <= 0.5,
        "\(label) accessory should keep inset \(inset), got \(actualInset)")
}

/// Finds an identified control inside the cell's nested stack-view hierarchy.
private func findRenameRecycleDescendant(
    in view: NSView,
    identifier: NSUserInterfaceItemIdentifier
) -> NSView? {
    if view.identifier == identifier { return view }
    for subview in view.subviews {
        if let found = findRenameRecycleDescendant(in: subview, identifier: identifier) {
            return found
        }
    }
    return nil
}

/// Pins truncation behavior without depending on the title's exact rendered width.
private func expectTabTitlePrecedesAccessory(in cell: NSTableCellView) throws {
    guard let leading = cell.subviews.first(where: {
        $0.identifier?.rawValue == "tabLeadingStack"
    }), let accessory = cell.subviews.first(where: {
        $0.identifier?.rawValue == "tabAccessoryStack"
    }) else {
        throw UITestFailure(message: "missing tab title or accessory lane")
    }
    try uiExpect(leading.frame.maxX <= accessory.frame.minX + 0.5,
        "tab title lane should truncate before the accessory lane")
}
