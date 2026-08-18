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
        model.alerts = [sidebarBellAlert(
            paneId: model.groups[0].tabs[0].paneTree.focusedPaneId)]

        let scroll = findRenameRecycleScrollView(in: sidebar)!
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        _ = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)

        for width in [260.0, 200.0, 300.0] {
            window.setContentSize(NSSize(width: width, height: 140))
            materializeSidebarRows(sidebar, outline: outline)

            let groupCell: SidebarGroupCellView = try sidebarCell(
                for: .group(groupA), in: outline)
            let tabCell: SidebarTabCellView = try sidebarCell(
                for: .tab(tab), in: outline)
            try expectCellFillsVisibleContent(groupCell, scroll: scroll, label: "group at \(width)")
            try expectCellFillsVisibleContent(tabCell, scroll: scroll, label: "tab at \(width)")
            try expectAccessoryTrailingInset(
                groupCell.caretButton, inset: 2,
                scroll: scroll, label: "group at \(width)")
            try expectAccessoryTrailingInset(
                tabCell.alertBadge, inset: 2,
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
        model.alerts = [sidebarBellAlert(
            paneId: model.groups[0].tabs[0].paneTree.focusedPaneId)]
        var projection = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        let scroll = findRenameRecycleScrollView(in: sidebar)!
        let cell: SidebarTabCellView = try sidebarCell(for: .tab(tab), in: outline)
        let titleField = cell.titleField

        try expectTabTitlePrecedesAccessory(in: cell)
        try expectAccessoryTrailingInset(
            cell.alertBadge, inset: 2,
            scroll: scroll, label: "short display title")

        beginRenameThroughModel(
            .tab(tab), in: &model, driver: projection,
            sidebar: sidebar, outline: outline)
        // No trailing space: a display title is normalized on its way out of the
        // projection, so one would not survive the commit and the assertion below
        // would be about trimming rather than about row recycling.
        let longTitle = String(repeating: "long title ", count: 12) + "end"
        titleField.stringValue = longTitle
        window.contentView?.layoutSubtreeIfNeeded()
        try expectTabTitlePrecedesAccessory(in: cell)
        try expectAccessoryTrailingInset(
            cell.alertBadge, inset: 2,
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
            to: sidebar, outline: outline)
        materializeSidebarRows(sidebar, outline: outline)
        try uiExpect(titleField.stringValue == longTitle,
            "committed long title should reach display mode")
        try expectTabTitlePrecedesAccessory(in: cell)
        try expectAccessoryTrailingInset(
            cell.alertBadge, inset: 2,
            scroll: scroll, label: "after rename commit")

        beginRenameThroughModel(
            .tab(tab), in: &model, driver: projection,
            sidebar: sidebar, outline: outline)
        titleField.stringValue = "cancelled draft"
        guard let cancelEditor = titleField.currentEditor() as? NSTextView else {
            throw UITestFailure(message: "second rename should install a field editor")
        }
        _ = sidebar.control(
            titleField, textView: cancelEditor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        materializeSidebarRows(sidebar, outline: outline)
        try uiExpect(titleField.stringValue == longTitle,
            "rename cancellation should restore the committed title")
        try expectTabTitlePrecedesAccessory(in: cell)
        try expectAccessoryTrailingInset(
            cell.alertBadge, inset: 2,
            scroll: scroll, label: "after rename cancellation")

        model.groups[0].tabs[0].customTitle = "changed"
        _ = applyRenameRecycleTransition(
            old: projection, newModel: model,
            to: sidebar, outline: outline)
        materializeSidebarRows(sidebar, outline: outline)
        try expectAccessoryTrailingInset(
            cell.alertBadge, inset: 2,
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
        let driver = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)

        beginRenameThroughModel(
            .tab(tab), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)
        let tabCell: SidebarTabCellView = try sidebarCell(for: .tab(tab), in: outline)
        tabCell.titleField.frame.size.width = 0
        tabCell.titleField.invalidateIntrinsicContentSize()
        window.contentView?.layoutSubtreeIfNeeded()
        try uiExpect(tabCell.titleField.frame.width > 80,
            "editable tab title should retain useful width beside its jump badge")

        window.makeFirstResponder(nil)
        beginRenameThroughModel(
            .group(groupA), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)
        let groupCell: SidebarGroupCellView = try sidebarCell(
            for: .group(groupA), in: outline)
        groupCell.titleField.frame.size.width = 0
        groupCell.titleField.invalidateIntrinsicContentSize()
        window.contentView?.layoutSubtreeIfNeeded()
        try uiExpect(groupCell.titleField.frame.width > 80,
            "editable group title should retain useful width beside its accessories")
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
        var model = renameRecycleModel(
            [(group, "G", false, [(tab, "alpha"), (other, "beta")])],
            selected: tab)
        let driver = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        beginRenameThroughModel(
            .tab(tab), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)
        let cell: SidebarTabCellView = try sidebarCell(for: .tab(tab), in: outline)
        cell.titleField.stringValue = "renamed"

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
        try uiExpect(cell.titleField.isEditable == false,
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
        var model = renameRecycleModel([
            (groupA, "A", false, [(tabA, "alpha")]),
            (groupB, "B", false, [(tabB, "beta")]),
        ])
        let driver = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        let groupCell: SidebarGroupCellView = try sidebarCell(
            for: .group(groupA), in: outline)
        let field = groupCell.titleField

        beginRenameThroughModel(
            .group(groupA), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)
        field.stringValue = "committed"
        let commitStart = runtime.sentMessages.count
        let commitEditor = try requireRenameRecycleEditor(field)
        _ = sidebar.control(
            field, textView: commitEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try uiExpect(runtime.sentMessages.count == commitStart,
            "the delegate must not dispatch on AppKit's own callback stack")
        try pumpMainQueue(untilTrue: { runtime.sentMessages.count == commitStart + 2 })
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

        beginRenameThroughModel(
            .group(groupA), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)
        field.stringValue = "cancelled"
        let cancelStart = runtime.sentMessages.count
        let cancelEditor = try requireRenameRecycleEditor(field)
        _ = sidebar.control(
            field, textView: cancelEditor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        try pumpMainQueue(untilTrue: { runtime.sentMessages.count == cancelStart + 1 })
        let cancelMessages = Array(runtime.sentMessages[cancelStart...])
        try uiExpect(cancelMessages.count == 1,
            "group Escape should send only rename-ended")
        guard case .sidebarRenameEnded = cancelMessages[0] else {
            throw UITestFailure(message: "group Escape should not send renameGroup")
        }
        try uiExpect(sidebar.activeRenameTarget == nil,
            "group Escape should clear ownership")

        beginRenameThroughModel(
            .group(groupA), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)
        field.stringValue = "click away"
        let clickStart = runtime.sentMessages.count
        sidebar.finishActiveRenameForPointerInteraction()
        let clickMessages = Array(runtime.sentMessages[clickStart...])
        try uiExpect(clickMessages.count == 2,
            "group click-away should send one rename and one ownership end")
        guard case .renameGroup(let clickedId, let clickedName) = clickMessages[0],
              case .sidebarRenameEnded = clickMessages[1] else {
            throw UITestFailure(message: "group click-away sent the wrong messages")
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
        var model = renameRecycleModel(
            [(group, "G", false, [(tab, "alpha"), (other, "beta")])],
            selected: tab)
        let projection = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        beginRenameThroughModel(
            .tab(tab), in: &model, driver: projection,
            sidebar: sidebar, outline: outline)
        let cell: SidebarTabCellView = try sidebarCell(for: .tab(tab), in: outline)
        cell.titleField.stringValue = "stale draft"
        cell.titleField.abortEditing()
        try uiExpect(cell.titleField.currentEditor() == nil,
            "precondition: AppKit should have discarded the field editor")

        _ = applyRenameRecycleTransition(
            old: projection, newModel: model,
            to: sidebar, outline: outline)

        try uiExpect(sidebar.activeRenameTarget == nil,
            "abandoned editor should clear the authoritative rename target")
        try uiExpect(cell.titleField.isEditable == false,
            "abandoned editor should return the title field to display state")
        try uiExpect(cell.titleField.stringValue == "alpha",
            "abandoned editor should restore the model title instead of stale draft text")
    }

    uiTest("a pointer interaction reports an abandoned editor's end in the same turn") {
        // Intent: the pointer path dispatches the rename end synchronously even on
        //   its abandoned-editor branch, with no run-loop turn in between.
        // Why it exists: that branch used to defer through DispatchQueue.main,
        //   which is what made the reconcile exits observable only after a pump.
        //   Ending a rename the user ended has a turn to dispatch in.
        // Scenario: AppKit discards the field editor, then the user clicks the
        //   outline.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId(); let tab = TabId(); let other = TabId()
        var model = renameRecycleModel(
            [(group, "G", false, [(tab, "alpha"), (other, "beta")])],
            selected: tab)
        let driver = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        beginRenameThroughModel(
            .tab(tab), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)
        let cell: SidebarTabCellView = try sidebarCell(for: .tab(tab), in: outline)
        cell.titleField.abortEditing()
        try uiExpect(cell.titleField.currentEditor() == nil,
            "precondition: AppKit should have discarded the field editor")

        sidebar.finishActiveRenameForPointerInteraction()

        try uiExpect(reportsRenameEnded(runtime.sentMessages),
            "the pointer path should send the end without a run-loop turn")
        try uiExpect(sidebar.activeRenameTarget == nil,
            "the abandoned session should be gone")
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
        var initial = renameRecycleModel([
            (groupA, "A", false, [(edited, "alpha")]),
            (groupB, "B", false, [(anchor, "anchor")]),
        ])
        let initialProjection = applyRenameRecycleModel(initial, to: sidebar, outline: outline, old: nil)

        beginRenameThroughModel(
            .tab(edited), in: &initial, driver: initialProjection,
            sidebar: sidebar, outline: outline)
        let editedRow = try sidebarTabRow(for: edited, in: outline)
        let editedCell = outline.view(
            atColumn: 0, row: editedRow,
            makeIfNecessary: false) as! SidebarTabCellView
        try uiExpect(editedCell.titleField.currentEditor() != nil,
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
            to: sidebar, outline: outline)

        let expanded = renameRecycleModel([
            (groupA, "A", false, [(edited, "alpha")]),
            (groupB, "B", false, [(anchor, "anchor")]),
        ])
        _ = applyRenameRecycleTransition(
            old: collapsedProjection, newModel: expanded,
            to: sidebar, outline: outline)

        let row = try sidebarTabRow(for: edited, in: outline)
        let cell = outline.view(
            atColumn: 0, row: row,
            makeIfNecessary: true) as! SidebarTabCellView
        try uiExpect(cell.titleField.isEditable == false,
            "re-shown row must not still be editable after collapse ended its rename")
        try uiExpect(cell.titleField.currentEditor() == nil,
            "re-shown row must not have a live field editor")
        try uiExpect(cell.titleField.stringValue == "alpha",
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
        var initial = renameRecycleModel(
            [(group, "G", false, [(edited, "alpha"), (other, "beta")])],
            selected: edited)
        let initialProjection = applyRenameRecycleModel(initial, to: sidebar, outline: outline, old: nil)

        beginRenameThroughModel(
            .tab(edited), in: &initial, driver: initialProjection,
            sidebar: sidebar, outline: outline)
        let editedRow = try sidebarTabRow(for: edited, in: outline)
        let editedCell = outline.view(
            atColumn: 0, row: editedRow,
            makeIfNecessary: false) as! SidebarTabCellView
        try uiExpect(editedCell.titleField.currentEditor() != nil,
            "precondition: rename should attach a live field editor")

        // Cmd-T: new tab appended, selection moves to it.
        let afterCmdT = renameRecycleModel(
            [(group, "G", false, [(edited, "alpha"), (other, "beta"), (spawned, "Terminal")])],
            selected: spawned)
        _ = applyRenameRecycleTransition(
            old: initialProjection, newModel: afterCmdT,
            to: sidebar, outline: outline)

        try uiExpect(editedCell.titleField.isEditable == false,
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
        var model = renameRecycleModel(
            [(group, "G", false, [(edited, "alpha"), (other, "beta")])],
            selected: edited)
        let projection = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)

        beginRenameThroughModel(
            .tab(edited), in: &model, driver: projection,
            sidebar: sidebar, outline: outline)
        let editedRow = try sidebarTabRow(for: edited, in: outline)
        let editedCell = outline.view(
            atColumn: 0, row: editedRow,
            makeIfNecessary: false) as! SidebarTabCellView
        try uiExpect(editedCell.titleField.currentEditor() != nil,
            "precondition: rename should attach a live field editor")
        try uiExpect(sidebar.activeRenameTarget == .tab(edited),
            "precondition: the view should own the tab rename")

        _ = applyRenameRecycleTransition(
            old: projection, newModel: model,
            to: sidebar, outline: outline)

        try uiExpect(editedCell.titleField.currentEditor() != nil,
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
        var initial = renameRecycleModel(
            [(group, "G", false, [(edited, "alpha"), (other, "beta")])],
            selected: edited)
        let initialProjection = applyRenameRecycleModel(initial, to: sidebar, outline: outline, old: nil)

        beginRenameThroughModel(
            .tab(edited), in: &initial, driver: initialProjection,
            sidebar: sidebar, outline: outline)
        let editedRow = try sidebarTabRow(for: edited, in: outline)
        let editedCell = outline.view(
            atColumn: 0, row: editedRow,
            makeIfNecessary: false) as! SidebarTabCellView
        try uiExpect(editedCell.titleField.currentEditor() != nil,
            "precondition: rename should attach a live field editor")

        let afterCmdT = renameRecycleModel(
            [(group, "G", false, [(edited, "alpha updated"), (other, "beta"), (spawned, "Terminal")])],
            selected: spawned)
        sidebar.testForceNextNilCellTabIds.insert(edited)
        let dropped = applyRenameRecycleTransitionResult(
            old: initialProjection, newModel: afterCmdT,
            to: sidebar, outline: outline)

        try uiExpect(dropped.droppedTabs == Set([edited]),
            "rename resync should report the dropped edited tab")
        try uiExpect(sidebar.activeRenameTarget == nil,
            "selection-moving reconcile should still clear rename ownership")
        try uiExpect(editedCell.titleField.stringValue == "alpha",
            "dropped resync should leave the old edited-row title visible")

        let repainted = applyRenameRecycleTransitionResult(
            old: dropped.driver, newModel: afterCmdT,
            to: sidebar, outline: outline)

        let updatedRow = try sidebarTabRow(for: edited, in: outline)
        let updatedCell = outline.view(
            atColumn: 0, row: updatedRow,
            makeIfNecessary: false) as! SidebarTabCellView
        try uiExpect(repainted.droppedTabs.isEmpty,
            "retry should fetch and paint the edited tab row")
        try uiExpect(updatedCell.titleField.stringValue == "alpha updated",
            "retry should repaint the edited row from the live model")
    }

    uiTest("group structural exits end the exact live rename") {
        // Intent: removal, a full row rebuild, and selection movement each end a
        //   live group rename, report the end into the outbox, and restore the
        //   field from model-backed display state.
        // Why it exists: group editors cross different outline teardown paths than
        //   tab editors and must obey the same single-owner exit invariant. The
        //   report is also what closes the model-level chokepoint's gap: it clears
        //   sidebarRenameTarget only for a target that left the model, so rebuild
        //   and selection would otherwise strand a live rename in the model.
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
            var initial = renameRecycleModel([
                (groupA, "A", false, [(tabA, "alpha")]),
                (groupB, "B", false, [(tabB, "beta")]),
                (groupC, "C", false, [(tabC, "gamma")]),
            ], selected: tabA)
            let projection = applyRenameRecycleModel(
                initial, to: sidebar, outline: outline, old: nil)
            beginRenameThroughModel(
                .group(groupA), in: &initial, driver: projection,
                sidebar: sidebar, outline: outline)
            let cell: SidebarGroupCellView = try sidebarCell(
                for: .group(groupA), in: outline)
            let field = cell.titleField
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

            _ = applyRenameRecycleTransitionResult(
                old: projection, newModel: next,
                to: sidebar, outline: outline)

            try uiExpect(sidebar.activeRenameTarget == nil,
                "\(exit) should clear the group rename session")
            try uiExpect(runtime.sentMessages.isEmpty,
                "\(exit) should report the end rather than send it from the pass")
            try pumpMainQueue(untilTrue: { reportsRenameEnded(runtime.sentMessages) })
            try uiExpect(field.isEditable == false,
                "\(exit) should restore the group field to display state")
            try uiExpect(field.currentEditor() == nil,
                "\(exit) should remove the group field editor")
            try uiExpect(field.stringValue == "A",
                "\(exit) should restore the model-backed group name")
            window.close()
        }
    }

    uiTest("a double-click asks the model to begin the clicked row's rename") {
        // Intent: double-clicking a tab row or a group header asks the model to
        //   begin that rename, rather than opening an editor the model has no
        //   record of.
        // Why it exists: this path used to call straight into the view, so the
        //   session it opened was invisible to every reader of the model.
        // Scenario: the user double-clicks a tab row, then a group header.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId(); let sibling = GroupId()
        let tab = TabId(); let other = TabId()
        let model = renameRecycleModel([
            (group, "G", false, [(tab, "alpha")]),
            (sibling, "H", false, [(other, "beta")]),
        ], selected: tab)
        _ = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)

        sidebar.doubleClickRow(try sidebarTabRow(for: tab, in: outline))
        let groupCell: SidebarGroupCellView = try sidebarCell(for: .group(group), in: outline)
        sidebar.doubleClickRow(outline.row(for: groupCell))

        let begun: [RenameTarget] = runtime.sentMessages.compactMap {
            if case .beginSidebarRename(let target) = $0 { return target }
            return nil
        }
        try uiExpect(begun == [.tab(tab), .group(group)],
            "each double-click should ask the model to begin its own row's rename")
        try uiExpect(sidebar.activeRenameTarget == nil,
            "a double-click must not open an editor on its own")
    }

    uiTest("renaming a row whose editor a recycle destroyed opens an editor again") {
        // Intent: a second rename of a row opens an editor even when the view
        //   gave the first session up without the model hearing about it.
        // Why it exists: the reuse-pool branch tears the session down inside
        //   AppKit's row traversal, where it cannot report. If a session were
        //   identified by the row it edits, the model's pending request would
        //   still name that row, the pass would see no change, and renaming the
        //   row would do nothing for the rest of the session.
        // Scenario: the user renames a tab, scrolls the row out of view and back
        //   (which recycles its cell), then renames the same tab again.
        let (sidebar, outline, window, _) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId(); let edited = TabId(); let other = TabId()
        var model = renameRecycleModel(
            [(group, "G", false, [(edited, "alpha"), (other, "beta")])],
            selected: edited)
        let driver = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)

        beginRenameThroughModel(
            .tab(edited), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)
        let cell: SidebarTabCellView = try sidebarCell(for: .tab(edited), in: outline)
        try uiExpect(cell.titleField.currentEditor() != nil,
            "precondition: the first rename should attach a field editor")

        // The reuse-pool branch of viewFor:, which a scroll reaches with no
        // reconcile pass anywhere on the stack.
        sidebar.testResetRecycledRenameState(cell)
        try uiExpect(sidebar.activeRenameTarget == nil,
            "precondition: the recycle should leave the view owning no session")

        beginRenameThroughModel(
            .tab(edited), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)

        try uiExpect(sidebar.activeRenameTarget == .tab(edited),
            "a second rename of the same row should hand the editor back")
        let reopened: SidebarTabCellView = try sidebarCell(for: .tab(edited), in: outline)
        try uiExpect(reopened.titleField.currentEditor() != nil,
            "the reopened rename should attach a live field editor")
    }

    uiTest("a begin the pass cannot honor records no open session") {
        // Intent: when the requested row has no cell to hand a field editor to,
        //   the pass reports the end of that rename, and no later pass opens it.
        // Why it exists: the model records the request before the pass runs, so
        //   an unhonored request would leave the model claiming a session that
        //   is not on screen.
        // Scenario: a rename is requested for a tab inside a collapsed group,
        //   and for a tab whose row sits far below the visible sidebar.
        enum Unopenable {
            case collapsedGroup
            case unmountedRow
        }

        for unopenable in [Unopenable.collapsedGroup, .unmountedRow] {
            let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
            let group = GroupId(); let sibling = GroupId()
            let hidden = TabId(); let other = TabId()
            // The unmounted case needs a row AppKit has no reason to make a cell
            // for: one short window, and the target far down a long list.
            let filler = unopenable == .unmountedRow
                ? (0..<80).map { (TabId(), "filler \($0)") }
                : []
            var model = renameRecycleModel([
                (group, "G", unopenable == .collapsedGroup,
                 filler + [(hidden, "alpha")]),
                (sibling, "H", false, [(other, "beta")]),
            ], selected: other)
            let driver = SidebarReconcileDriver()
            let materialize = unopenable == .collapsedGroup
            if !materialize { window.setContentSize(NSSize(width: 260, height: 60)) }
            _ = applySidebarTestModel(
                model, using: driver, to: sidebar, outline: outline,
                materializeRows: materialize)

            let requestedSession = recordRenameBegin(.tab(hidden), in: &model)
            _ = applySidebarTestModel(
                model, using: driver, to: sidebar, outline: outline,
                materializeRows: materialize)

            try uiExpect(sidebar.activeRenameTarget == nil,
                "\(unopenable) should leave no editor open")
            try uiExpect(runtime.sentMessages.isEmpty,
                "\(unopenable) should report the end rather than send it from the pass")

            // The end names the request, which is what retracts it in the model
            // (update() drops the pending request only for the session it names).
            try pumpMainQueue(untilTrue: { !runtime.sentMessages.isEmpty })
            let ended: [RenameSessionId] = runtime.sentMessages.compactMap {
                if case .sidebarRenameEnded(let session) = $0 { return session }
                return nil
            }
            try uiExpect(ended == [requestedSession],
                "\(unopenable) should report the end of the rename it could not open")

            model.sidebarRename = nil
            let delivered = runtime.sentMessages.count
            _ = applySidebarTestModel(
                model, using: driver, to: sidebar, outline: outline,
                materializeRows: materialize)
            try uiExpect(runtime.sentMessages.count == delivered
                    && sidebar.activeRenameTarget == nil,
                "\(unopenable) must not resurrect the session in a later pass")
            window.close()
        }
    }

    uiTest("collapsing the group that holds an edited tab reports the rename end") {
        // Intent: a group collapse that hides the edited tab row ends the rename
        //   and reports it back through the pass, like the other structural exits.
        // Why it exists: only a tab rename can reach this cause -- collapsing a
        //   group keeps its own row visible -- so no other scenario covers it, and
        //   this is the exit that stranded an editable cell in the reuse pool.
        // Scenario: a tab is being renamed when its containing group collapses.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        // Two groups: single-group mode has no caret, so it emits no collapse op.
        let group = GroupId(); let sibling = GroupId()
        let edited = TabId(); let other = TabId()
        var expanded = renameRecycleModel([
            (group, "G", false, [(edited, "alpha")]),
            (sibling, "H", false, [(other, "beta")]),
        ], selected: edited)
        let driver = applyRenameRecycleModel(
            expanded, to: sidebar, outline: outline, old: nil)
        beginRenameThroughModel(
            .tab(edited), in: &expanded, driver: driver,
            sidebar: sidebar, outline: outline)
        let cell: SidebarTabCellView = try sidebarCell(for: .tab(edited), in: outline)
        let field = cell.titleField
        field.stringValue = "stale draft"

        let collapsed = renameRecycleModel([
            (group, "G", true, [(edited, "alpha")]),
            (sibling, "H", false, [(other, "beta")]),
        ], selected: edited)
        _ = applyRenameRecycleTransitionResult(
            old: driver, newModel: collapsed, to: sidebar, outline: outline)

        try uiExpect(sidebar.activeRenameTarget == nil,
            "collapse should clear the tab rename session")
        try uiExpect(runtime.sentMessages.isEmpty,
            "collapse should report the end rather than send it from the pass")
        try pumpMainQueue(untilTrue: { reportsRenameEnded(runtime.sentMessages) })
        try uiExpect(field.isEditable == false,
            "collapse should restore the tab field to display state")
        try uiExpect(field.stringValue == "alpha",
            "collapse should restore the model-backed tab title")
    }

    uiTest("a reported follow-up finds the projection cache already advanced") {
        // Intent: by the time a follow-up is handed back, the driver has stored the
        //   projection the pass applied, so the follow-up's own sweep diffs against
        //   the new state and has nothing left to do.
        // Why it exists: this is the reason the fact returns instead of being sent
        //   mid-pass -- a nested sweep would diff the new model against a cache the
        //   outer pass had not advanced, and issue row ops against a mid-mutation
        //   outline.
        // Scenario: a rebuild ends a live group rename, then the sweep the reported
        //   follow-up would trigger runs against the same model.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let groupA = GroupId(); let groupB = GroupId()
        let tabA = TabId(); let tabB = TabId()
        var initial = renameRecycleModel([
            (groupA, "A", false, [(tabA, "alpha")]),
            (groupB, "B", false, [(tabB, "beta")]),
        ], selected: tabA)
        let driver = applyRenameRecycleModel(
            initial, to: sidebar, outline: outline, old: nil)
        beginRenameThroughModel(
            .group(groupA), in: &initial, driver: driver,
            sidebar: sidebar, outline: outline)
        let cell: SidebarGroupCellView = try sidebarCell(for: .group(groupA), in: outline)
        cell.titleField.stringValue = "stale draft"

        let rebuilt = renameRecycleModel(
            [(groupA, "A", false, [(tabA, "alpha")])], selected: tabA)
        let first = applyRenameRecycleTransitionResult(
            old: driver, newModel: rebuilt, to: sidebar, outline: outline)
        try uiExpect(runtime.sentMessages.isEmpty,
            "neither sweep should dispatch a message from inside itself")
        try pumpMainQueue(untilTrue: { reportsRenameEnded(runtime.sentMessages) })
        try uiExpect(first.advancedProjection.groups.map(\.id) == [groupA],
            "the cache the pass stored should already be the rebuilt projection")

        // The sweep the reported follow-up drives, run the way the runtime runs it:
        // after the outer pass returned.
        let delivered = runtime.sentMessages.count
        _ = applyRenameRecycleTransitionResult(
            old: driver, newModel: rebuilt, to: sidebar, outline: outline)
        pumpMainQueueOnce()
        try uiExpect(runtime.sentMessages.count == delivered,
            "the follow-up's own sweep should see an advanced cache and report nothing")
        try uiExpect(cell.titleField.stringValue == "A",
            "the edited row should show its model-backed name after both sweeps")
    }

    uiTest("a pass handing the rename to a successor row reports the prior commit") {
        // Intent: when the model moves a live rename to another row, the pass
        //   commits the predecessor's draft and ends its ownership through the same
        //   return channel, then leaves the successor's editor active.
        // Why it exists: this exit sent synchronously from mid-traversal, which is
        //   the re-entrancy hazard the channel exists to remove; a bare "a rename
        //   ended" flag could not carry the draft the commit needs.
        // Scenario: the sidebar projection's rename target moves from a row being
        //   edited to a sibling row.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId(); let first = TabId(); let second = TabId()
        var initial = renameRecycleModel(
            [(group, "G", false, [(first, "alpha"), (second, "beta")])],
            selected: first)
        let driver = applyRenameRecycleModel(
            initial, to: sidebar, outline: outline, old: nil)
        beginRenameThroughModel(
            .tab(first), in: &initial, driver: driver,
            sidebar: sidebar, outline: outline)
        let firstCell: SidebarTabCellView = try sidebarCell(for: .tab(first), in: outline)
        firstCell.titleField.stringValue = "first draft"

        var handoff = initial
        recordRenameBegin(.tab(second), in: &handoff)
        _ = applyRenameRecycleTransitionResult(
            old: driver, newModel: handoff, to: sidebar, outline: outline)

        try uiExpect(runtime.sentMessages.isEmpty,
            "the handoff should report both messages rather than send them mid-pass")
        try pumpMainQueue(untilTrue: { reportsRenameEnded(runtime.sentMessages) })
        var committedName: String??
        for msg in runtime.sentMessages {
            if case .renameTab(let id, let name) = msg, id == first { committedName = name }
        }
        try uiExpect(committedName == "first draft",
            "the predecessor's commit should carry its draft text")
        try uiExpect(sidebar.activeRenameTarget == .tab(second),
            "the successor row should own the live editor")
    }

    uiTest("a replaced rename commits the prior draft once and ignores its stale field") {
        // Intent: taking the editor to a successor row commits the prior draft
        //   exactly once, and a late callback from the prior field neither ends
        //   the successor session nor commits a second time.
        // Why it exists: the old field and the session record were separate
        //   owners, so a late callback could clear or complete a newer session.
        // Scenario: the user edits one tab, starts renaming another, and AppKit
        //   then delivers a delayed end-editing callback for the first field.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId(); let first = TabId(); let second = TabId()
        var model = renameRecycleModel(
            [(group, "G", false, [(first, "alpha"), (second, "beta")])],
            selected: first)
        let driver = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        beginRenameThroughModel(
            .tab(first), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)
        let firstCell: SidebarTabCellView = try sidebarCell(
            for: .tab(first), in: outline)
        let firstField = firstCell.titleField
        firstField.stringValue = "first draft"

        beginRenameThroughModel(
            .tab(second), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)

        try uiExpect(runtime.sentMessages.isEmpty,
            "the pass should report the prior commit rather than send it")
        try pumpMainQueue(untilTrue: { reportsRenameEnded(runtime.sentMessages) })
        let firstRenames = runtime.sentMessages.filter {
            if case .renameTab(let id, let name) = $0 {
                return id == first && name == "first draft"
            }
            return false
        }
        try uiExpect(firstRenames.count == 1,
            "replacement should commit the prior draft exactly once")
        try uiExpect(sidebar.activeRenameTarget == .tab(second),
            "the successor row should own the live editor")

        let delivered = runtime.sentMessages.count
        _ = sidebar.control(firstField, textShouldEndEditing: NSTextView())
        _ = sidebar.control(NSTextField(), textShouldEndEditing: NSTextView())
        pumpMainQueueOnce()

        try uiExpect(sidebar.activeRenameTarget == .tab(second),
            "stale prior-field callback must not clear the successor session")
        try uiExpect(runtime.sentMessages.count == delivered,
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
        var model = renameRecycleModel([(group, "G", false, [(tab, "alpha")])])
        let driver = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        beginRenameThroughModel(
            .tab(tab), in: &model, driver: driver,
            sidebar: sidebar, outline: outline)
        let cell: SidebarTabCellView = try sidebarCell(for: .tab(tab), in: outline)
        cell.titleField.abortEditing()

        sidebar.testResetRecycledRenameState(cell)

        try uiExpect(sidebar.activeRenameTarget == nil,
            "reuse reset should clear ownership of the discarded editor")
        try uiExpect(cell.titleField.isEditable == false,
            "reuse reset should restore display state")
    }

    uiTest("a recycle with no pass on the stack still reports the rename end") {
        // Intent: the reuse-pool teardown -- the one path with no pass to return a
        //   fact to and no interaction to ride -- reaches the model on the next
        //   main-queue turn, and reaches it from off the reporting stack.
        // Why it exists: this teardown used to clear the session silently, so the
        //   model went on claiming a rename that was no longer on screen, and a
        //   second rename of that row opened nothing.
        // Scenario: the user renames a tab and scrolls its row out of view, which
        //   hands the cell to the reuse pool with AppKit mid-traversal.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let group = GroupId(); let tab = TabId()
        var model = renameRecycleModel([(group, "G", false, [(tab, "alpha")])])
        let driver = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
        let session = recordRenameBegin(.tab(tab), in: &model)
        applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)
        let cell: SidebarTabCellView = try sidebarCell(for: .tab(tab), in: outline)
        try uiExpect(cell.titleField.currentEditor() != nil,
            "precondition: the rename should attach a field editor")

        sidebar.testResetRecycledRenameState(cell)

        // The AR1 window, observed on purpose: AppKit is still walking its rows
        // here, so the end may not be dispatched on this stack.
        try uiExpect(runtime.sentMessages.isEmpty,
            "the recycle must not dispatch inside AppKit's row traversal")
        try pumpMainQueue(untilTrue: { !runtime.sentMessages.isEmpty })
        try uiExpect(endedSessions(runtime.sentMessages) == [session],
            "the recycle should report the end of the session it gave up")
    }

    uiTest("a rename end survives the sidebar being released before delivery") {
        // Intent: an end reported with no send frame open still reaches the model
        //   when the view that reported it is gone by the time the drain runs.
        // Why it exists: the click-away path used to deliver on a main-queue hop
        //   captured on the view itself, so a view released first dropped the end
        //   and the model kept claiming the session.
        // Scenario: a window closes and drops its sidebar in the same turn that a
        //   rename teardown reported.
        let runtime = AppRuntime()
        var session: RenameSessionId?
        weak var reporter: SidebarView?
        autoreleasepool {
            let (sidebar, outline, window, _) = makeRenameRecycleHarness(runtime: runtime)
            window.isReleasedWhenClosed = false
            let group = GroupId(); let tab = TabId()
            var model = renameRecycleModel([(group, "G", false, [(tab, "alpha")])])
            let driver = applyRenameRecycleModel(model, to: sidebar, outline: outline, old: nil)
            session = recordRenameBegin(.tab(tab), in: &model)
            applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)
            let cell: SidebarTabCellView? = try? sidebarCell(for: .tab(tab), in: outline)
            cell.map { sidebar.testResetRecycledRenameState($0) }
            reporter = sidebar
            window.makeFirstResponder(nil)
            window.contentView = NSView()
            window.orderOut(nil)
        }

        try uiExpect(reporter == nil,
            "precondition: the reporting view should be gone before the drain runs")
        try pumpMainQueue(untilTrue: { !runtime.sentMessages.isEmpty })
        try uiExpect(endedSessions(runtime.sentMessages) == [session],
            "the outbox should deliver the end after its reporter is gone")
    }

    uiTest("a recycled group caret acts on the group in its new row") {
        // Intent: a reused group row's caret expands or collapses the group that
        //   the outline row now represents.
        // Why it exists: reusable controls must not retain action identity from a
        //   prior row or from a projection copied into the view.
        // Scenario: group A's cell is reapplied and reparented onto group B's real
        //   row, then its caret is invoked.
        let (sidebar, outline, window, runtime) = makeRenameRecycleHarness()
        defer { window.close() }

        let groupA = GroupId(); let groupB = GroupId()
        let tabA = TabId(); let tabB = TabId()
        let model = renameRecycleModel([
            (groupA, "A", false, [(tabA, "alpha")]),
            (groupB, "B", false, [(tabB, "beta")]),
        ])
        _ = applyRenameRecycleModel(
            model, to: sidebar, outline: outline, old: nil)
        let oldCell: SidebarGroupCellView = try sidebarCell(
            for: .group(groupA), in: outline)
        let replacedCell: SidebarGroupCellView = try sidebarCell(
            for: .group(groupB), in: outline)
        let groupBProjection = desiredSidebar(in: model).groups.first { $0.id == groupB }!
        let groupBRow = outline.row(for: replacedCell)
        guard let rowView = outline.rowView(
            atRow: groupBRow, makeIfNecessary: false) as? SidebarRowView else {
            throw UITestFailure(message: "group B should have a materialized row")
        }
        replacedCell.removeFromSuperview()
        oldCell.removeFromSuperview()
        oldCell.apply(groupBProjection, isEditingTitle: false)
        rowView.addSubview(oldCell)
        oldCell.frame = rowView.bounds
        oldCell.caretButton.performClick(nil)

        try uiExpect(runtime.sentMessages.contains {
            if case .toggleGroupCollapse(let id) = $0 { return id == groupB }
            return false
        }, "recycled caret should act on the group in its new row")
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
        var initial = renameRecycleModel([
            (groupA, "A", false, [(edited, "alpha")]),
            (groupB, "B", false, [(anchor, "anchor")]),
        ])
        let initialProjection = applyRenameRecycleModel(initial, to: sidebar, outline: outline, old: nil)

        beginRenameThroughModel(
            .tab(edited), in: &initial, driver: initialProjection,
            sidebar: sidebar, outline: outline)
        let editedRow = try sidebarTabRow(for: edited, in: outline)
        let editedCell = outline.view(
            atColumn: 0, row: editedRow,
            makeIfNecessary: false) as! SidebarTabCellView
        try uiExpect(editedCell.titleField.currentEditor() != nil,
            "precondition: rename should attach a live field editor")

        let collapsed = renameRecycleModel([
            (groupA, "A", true, [(edited, "alpha")]),
            (groupB, "B", false, [(anchor, "anchor")]),
        ])
        let collapsedProjection = applyRenameRecycleTransition(
            old: initialProjection, newModel: collapsed,
            to: sidebar, outline: outline)

        // Spawn a new tab in the other group -- the insertTab op makes a cell,
        // and NSOutlineView may hand back the stranded one from its reuse pool.
        var spawnedModel = renameRecycleModel([
            (groupA, "A", true, [(edited, "alpha")]),
            (groupB, "B", false, [(anchor, "anchor"), (spawned, "fresh tab")]),
        ])
        spawnedModel.alerts = [sidebarBellAlert(
            paneId: spawnedModel.groups[1].tabs[1].paneTree.focusedPaneId)]
        _ = applyRenameRecycleTransition(
            old: collapsedProjection, newModel: spawnedModel,
            to: sidebar, outline: outline)

        let row = try sidebarTabRow(for: spawned, in: outline)
        let cell = outline.view(
            atColumn: 0, row: row,
            makeIfNecessary: true) as! SidebarTabCellView
        try uiExpect(cell === editedCell,
            "precondition: the inserted row should reuse the edited cell")
        try uiExpect(cell.titleField.isEditable == false,
            "freshly inserted tab row must not inherit rename editability from a recycled cell")
        try uiExpect(cell.titleField.currentEditor() == nil,
            "freshly inserted tab row must not have a live field editor")
        try uiExpect(cell.titleField.stringValue == "fresh tab",
            "freshly inserted tab row must display the model title")
        let scroll = findRenameRecycleScrollView(in: sidebar)!
        try expectCellFillsVisibleContent(cell, scroll: scroll, label: "recycled tab")
        try expectAccessoryTrailingInset(
            cell.alertBadge, inset: 2,
            scroll: scroll, label: "recycled tab")
    }
}
// MARK: - Harness helpers (local: the selection-cache test helpers are file-private)

private func makeRenameRecycleHarness(
    runtime: AppRuntime = AppRuntime()
) -> (SidebarView, NSOutlineView, NSWindow, AppRuntime) {
    let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 420))
    sidebar.runtime = runtime
    let window = NSWindow(
        contentRect: sidebar.frame,
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    window.contentView = sidebar
    window.layoutIfNeeded()
    let outline = sidebarOutlineView(in: sidebar)!
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
                    return TabModel(id: tabId, paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId))
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
    old: SidebarReconcileDriver?
) -> SidebarReconcileDriver {
    let driver = old ?? SidebarReconcileDriver()
    applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)
    return driver
}

@discardableResult
private func applyRenameRecycleTransition(
    old driver: SidebarReconcileDriver,
    newModel: AppModel,
    to sidebar: SidebarView,
    outline: NSOutlineView
) -> SidebarReconcileDriver {
    _ = applySidebarTestModel(newModel, using: driver, to: sidebar, outline: outline)
    return driver
}

@discardableResult
private func applyRenameRecycleTransitionResult(
    old driver: SidebarReconcileDriver,
    newModel: AppModel,
    to sidebar: SidebarView,
    outline: NSOutlineView
) -> (
    driver: SidebarReconcileDriver,
    advancedProjection: SidebarProjection,
    droppedTabs: Set<TabId>,
    droppedGroups: Set<GroupId>
) {
    let result = applySidebarTestModel(
        newModel, using: driver, to: sidebar, outline: outline)
    return (
        driver,
        result.appliedProjection,
        result.unappliedTabIds,
        result.unappliedGroupIds)
}

/// The sessions whose ends reached the model, in delivery order.
private func endedSessions(_ messages: [Msg]) -> [RenameSessionId] {
    messages.compactMap {
        if case .sidebarRenameEnded(let session) = $0 { return session }
        return nil
    }
}

/// Reports whether the end of rename ownership reached the model.
private func reportsRenameEnded(_ messages: [Msg]) -> Bool {
    messages.contains {
        if case .sidebarRenameEnded = $0 { return true }
        return false
    }
}

private func requireRenameRecycleEditor(_ field: NSTextField) throws -> NSTextView {
    guard let editor = field.currentEditor() as? NSTextView else {
        throw UITestFailure(message: "rename should install a field editor")
    }
    return editor
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
    _ accessory: NSView,
    inset: CGFloat,
    scroll: NSScrollView,
    label: String
) throws {
    let clip = scroll.contentView
    let frame = clip.convert(accessory.bounds, from: accessory)
    let actualInset = clip.bounds.maxX - frame.maxX
    try uiExpect(abs(actualInset - inset) <= 0.5,
        "\(label) accessory should keep inset \(inset), got \(actualInset)")
}

/// Pins truncation behavior without depending on the title's exact rendered width.
private func expectTabTitlePrecedesAccessory(in cell: SidebarTabCellView) throws {
    try uiExpect(cell.leadingStack.frame.maxX <= cell.accessoryStack.frame.minX + 0.5,
        "tab title lane should truncate before the accessory lane")
}
