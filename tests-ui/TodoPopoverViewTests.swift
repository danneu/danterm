// UI-harness tests for TodoPopoverView's pane-scoped row rendering, message
// routing, compose/edit modes, keyboard paths, pasteboard payloads, and focus
// restoration across model re-apply.
import Cocoa

/// Runs pane-scoped todo popover coverage in the AppKit UI harness.
@MainActor
func todoPopoverViewTests() {
    print("TodoPopoverView")

    uiTest("apply renders pane todo rows in projection order") {
        // Intent: the pane popover renders one TodoRow per projected todo, in
        //   order, with the expected row identifiers and display titles.
        // Why it exists: pins the view binding for the pane-scoped TODO
        //   surface now that it is compiled in the UI harness. Spec-first.
        // Scenario: a pane with two open tasks and one completed task opens
        //   its TODO popover.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }

        let rows = materializedTodoRows(fx)

        try uiExpect(rows.map { $0.identifier?.rawValue } == ["TodoRow", "TodoRow", "TodoRow"],
                     "unexpected row identifiers: \(rows.map { $0.identifier?.rawValue ?? "nil" })")
        try uiExpect(rowTextValues(rows) == ["Pane alpha", "Pane beta", "Pane done"],
                     "unexpected row text: \(rowTextValues(rows))")
    }

    uiTest("empty list shows empty label and clear button follows completion") {
        // Intent: empty pane lists show the empty-state label and hide the
        //   scroll view; the Clear completed button follows hasCompleted.
        // Why it exists: pins the pane popover's empty-state branch separately
        //   from row rendering. Spec-first.
        // Scenario: a pane first has no tasks, then reconciles to one
        //   completed task.
        let fx = makePaneTodoFixture(todos: [])
        defer { fx.window.close() }

        let emptyLabel = try onlyLabel(titled: "No tasks yet", in: fx.vc.view)
        let clearButton = try onlyTodoButton(titled: "Clear completed", in: fx.vc.view)
        try uiExpect(!isEffectivelyHidden(emptyLabel), "empty label should be visible for an empty list")
        try uiExpect(isEffectivelyHidden(fx.scrollView), "scroll view should be hidden for an empty list")
        try uiExpect(clearButton.isHidden, "clear button should be hidden without completed todos")

        let model = modelByReplacingTodos(fx.model, paneId: fx.paneId, todos: [
            TodoItem(id: fx.doneId, text: "Pane done", isDone: true),
        ])
        fx.vc.apply(desiredPaneTodoPopover(paneId: fx.paneId, in: model)!)
        settlePaneTodoFixture(fx)

        try uiExpect(isEffectivelyHidden(emptyLabel), "empty label should hide once rows exist")
        try uiExpect(!isEffectivelyHidden(fx.scrollView), "scroll view should show once rows exist")
        try uiExpect(!clearButton.isHidden, "clear button should be visible with completed todos")
    }

    uiTest("row checkbox sends toggleTodoDone and restores prior selection") {
        // Intent: a row checkbox dispatches the pane-scoped toggle message and
        //   re-selects the row that was selected before the mutation.
        // Why it exists: pins the post-send selection restoration path against
        //   a harness re-apply, matching production send timing. Spec-first.
        // Scenario: the user has "Pane beta" selected and checks "Pane alpha".
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        installPaneTodoReapplyHook(fx)
        let selectedRow = try rowIndex(titled: "Pane beta", in: fx)
        fx.table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)

        let row = try todoRow(titled: "Pane alpha", in: fx)
        row.view.checkbox.performClick(nil)
        settlePaneTodoFixture(fx)

        try expectSingleMessage(fx.runtime, "toggle pane todo") { msg in
            if case .toggleTodoDone(.pane(let paneId), let todoId) = msg {
                return paneId == fx.paneId && todoId.rawValue == fx.openId
            }
            return false
        }
        try uiExpect(try selectedRowTitle(in: fx) == "Pane beta",
                     "selection should return to Pane beta after checkbox mutation")
    }

    uiTest("row delete button sends deleteTodo") {
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }

        let row = try todoRow(titled: "Pane alpha", in: fx)
        row.view.deleteButton.performClick(nil)

        try expectSingleMessage(fx.runtime, "delete pane todo") { msg in
            if case .deleteTodo(.pane(let paneId), let todoId) = msg {
                return paneId == fx.paneId && todoId.rawValue == fx.openId
            }
            return false
        }
    }

    uiTest("clear completed sends clearCompletedTodos") {
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }

        try onlyTodoButton(titled: "Clear completed", in: fx.vc.view).performClick(nil)

        try expectSingleMessage(fx.runtime, "clear completed pane todos") { msg in
            if case .clearCompletedTodos(.pane(let paneId)) = msg { return paneId == fx.paneId }
            return false
        }
    }

    uiTest("non-empty compose submit sends addTodo and clears field") {
        // Intent: Return in the compose field trims, sends a pane add message,
        //   and clears the compose draft.
        // Why it exists: pins the NSTextViewDelegate submit path at the AppKit
        //   entry point. Spec-first.
        // Scenario: the user enters a new pane task with surrounding
        //   whitespace and presses Return.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        let compose = try visibleTodoInput(in: fx)
        compose.string = "  New pane task  "

        let handled = fx.vc.textView(compose.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        try uiExpect(handled, "compose newline should be handled")
        try expectSingleMessage(fx.runtime, "add pane todo") { msg in
            if case .addTodo(.pane(let paneId), let text) = msg {
                return paneId == fx.paneId && text == "New pane task"
            }
            return false
        }
        try uiExpect(compose.string.isEmpty, "compose field should be cleared")
    }

    uiTest("whitespace compose submit sends nothing") {
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        let compose = try visibleTodoInput(in: fx)
        compose.string = " \n  "

        let handled = fx.vc.textView(compose.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        try uiExpect(handled, "compose newline should still be handled")
        try uiExpect(fx.runtime.sentMessages.isEmpty, "whitespace compose submit should send no messages")
    }

    uiTest("Return on a selected row enters edit mode with item text and focus") {
        // Intent: Return in list mode swaps to editor mode for the selected
        //   row, pre-fills the edit input, and focuses that input.
        // Why it exists: pins the pane-specific edit transition and first
        //   responder route. Spec-first.
        // Scenario: the user selects a pane task row and presses Return.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }

        try enterEdit(rowTitle: "Pane alpha", in: fx)

        let editInput = try visibleTodoInput(in: fx)
        try uiExpect(editInput.string == "Pane alpha", "edit input should be prefilled")
        try uiExpect(isEffectivelyHidden(fx.scrollView), "scroll view should be hidden in edit mode")
        try uiExpect(hiddenTodoInputs(in: fx).count == 1, "compose input should be hidden in edit mode")
        try uiExpect(fx.window.firstResponder === editInput.textView, "edit input should be first responder")
    }

    uiTest("save sends trimmed editTodoText and returns to selected list row") {
        // Intent: Save commits edits to the pane item, returns to list mode,
        //   re-selects the edited row, and focuses the table.
        // Why it exists: pins the button path through saveEditThenReturnToList.
        //   Spec-first.
        // Scenario: the user edits an existing pane task and clicks Save.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        try enterEdit(rowTitle: "Pane alpha", in: fx)
        let editInput = try visibleTodoInput(in: fx)
        editInput.string = "  Pane changed  "

        try onlyTodoButton(titled: "Save", in: fx.vc.view).performClick(nil)

        try expectSingleMessage(fx.runtime, "edit pane todo") { msg in
            if case .editTodoText(.pane(let paneId), let todoId, let text) = msg {
                return paneId == fx.paneId && todoId.rawValue == fx.openId && text == "Pane changed"
            }
            return false
        }
        try uiExpect(!isEffectivelyHidden(fx.scrollView), "scroll view should be visible after saving")
        try uiExpect(try selectedRowTitle(in: fx) == "Pane alpha", "edited row should be re-selected")
        try uiExpect(fx.window.firstResponder === fx.table, "table should be first responder after save")
    }

    uiTest("whitespace-only save is rejected and stays editing") {
        // Intent: Save rejects an edit draft that trims to empty and keeps the
        //   editor focused.
        // Why it exists: pins local validation before dispatch. Spec-first.
        // Scenario: the user clears the entire edit field and clicks Save.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        try enterEdit(rowTitle: "Pane alpha", in: fx)
        let editInput = try visibleTodoInput(in: fx)
        editInput.string = " \n "

        try onlyTodoButton(titled: "Save", in: fx.vc.view).performClick(nil)

        try uiExpect(fx.runtime.sentMessages.isEmpty, "empty edit should send no message")
        try uiExpect(try visibleTodoInput(in: fx) === editInput, "editor should remain visible")
        try uiExpect(fx.window.firstResponder === editInput.textView, "edit input should regain focus")
    }

    uiTest("cancel exits edit mode without sending and reselects target") {
        // Intent: Cancel abandons the active edit, returns to list mode, and
        //   re-selects the row that was being edited.
        // Why it exists: pins editor cancellation as view-local state only.
        //   Spec-first.
        // Scenario: the user enters edit mode and clicks Cancel.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        try enterEdit(rowTitle: "Pane beta", in: fx)

        try onlyTodoButton(titled: "Cancel", in: fx.vc.view).performClick(nil)

        try uiExpect(fx.runtime.sentMessages.isEmpty, "cancel should send no messages")
        try uiExpect(!isEffectivelyHidden(fx.scrollView), "scroll view should be visible after cancel")
        try uiExpect(try selectedRowTitle(in: fx) == "Pane beta", "edit target should be re-selected")
    }

    uiTest("apply mid-edit preserves draft when target still exists") {
        // Intent: reconcile preserves an in-progress edit draft when the same
        //   todo target survives in the new projection.
        // Why it exists: pins the pane side of the open-popover draft
        //   preservation contract. Spec-first.
        // Scenario: model data refreshes while the user is editing a pane task.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        try enterEdit(rowTitle: "Pane alpha", in: fx)
        let editInput = try visibleTodoInput(in: fx)
        editInput.string = "draft survives"

        var todos = fx.model.pane(fx.paneId)!.todos
        todos[0].text = "server text"
        let model = modelByReplacingTodos(fx.model, paneId: fx.paneId, todos: todos)
        fx.vc.apply(desiredPaneTodoPopover(paneId: fx.paneId, in: model)!)
        settlePaneTodoFixture(fx)

        try uiExpect(try visibleTodoInput(in: fx).string == "draft survives",
                     "edit draft should survive reconcile")
        try uiExpect(isEffectivelyHidden(fx.scrollView), "scroll view should remain hidden in edit mode")
    }

    uiTest("apply mid-edit exits when target is gone and selects nearest row") {
        // Intent: reconcile leaves edit mode when the edited todo disappears,
        //   then selects the nearest remaining row.
        // Why it exists: pins stale-target cleanup for open pane popovers.
        //   Spec-first.
        // Scenario: a task is deleted elsewhere while the user is editing it.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        try enterEdit(rowTitle: "Pane alpha", in: fx)

        let model = modelByReplacingTodos(
            fx.model,
            paneId: fx.paneId,
            todos: Array(fx.model.pane(fx.paneId)!.todos.dropFirst()))
        fx.vc.apply(desiredPaneTodoPopover(paneId: fx.paneId, in: model)!)
        settlePaneTodoFixture(fx)

        try uiExpect(!isEffectivelyHidden(fx.scrollView), "scroll view should be visible after stale target disappears")
        try uiExpect(try selectedRowTitle(in: fx) == "Pane beta", "nearest remaining row should be selected")
    }

    uiTest("Cmd-Backspace deletes selected row and selects nearest survivor") {
        // Intent: Cmd-Backspace dispatches delete for the selected row and
        //   moves selection to the nearest row after a production-like reapply.
        // Why it exists: pins the pane list keyboard route through
        //   deleteSelectedTodo. Spec-first.
        // Scenario: the user selects the middle row, presses plain Backspace
        //   first, then Cmd-Backspace.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        installPaneTodoReapplyHook(fx)
        let row = try rowIndex(titled: "Pane beta", in: fx)
        fx.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        fx.table.keyDown(with: keyDownEvent(characters: "\u{8}", modifiers: [], keyCode: 51, window: fx.window))
        try uiExpect(fx.runtime.sentMessages.isEmpty, "plain Backspace should not dispatch")

        fx.table.keyDown(with: keyDownEvent(characters: "\u{8}", modifiers: [.command], keyCode: 51, window: fx.window))
        settlePaneTodoFixture(fx)

        try expectSingleMessage(fx.runtime, "keyboard delete pane todo") { msg in
            if case .deleteTodo(.pane(let paneId), let todoId) = msg {
                return paneId == fx.paneId && todoId.rawValue == fx.secondOpenId
            }
            return false
        }
        try uiExpect(try selectedRowTitle(in: fx) == "Pane done",
                     "selection should move to the nearest surviving row")
    }

    uiTest("Shift-J sends reorderTodo to the next index") {
        // Intent: Shift-J reorders the selected row down one slot; Cmd-J is
        //   ignored by the strict modifier classifier.
        // Why it exists: pins the pane list keyboard route through
        //   reorderSelectedTodo while leaving drop-side routing out of scope.
        //   Spec-first.
        // Scenario: the user selects the first row and presses Cmd-J, then
        //   Shift-J.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        let row = try rowIndex(titled: "Pane alpha", in: fx)
        fx.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        fx.table.keyDown(with: keyDownEvent(characters: "j", modifiers: [.command], keyCode: 38, window: fx.window))
        try uiExpect(fx.runtime.sentMessages.isEmpty, "Cmd-J should not dispatch")

        fx.table.keyDown(with: keyDownEvent(characters: "J", modifiers: [.shift], keyCode: 38, window: fx.window))

        try expectSingleMessage(fx.runtime, "keyboard reorder pane todo") { msg in
            if case .reorderTodo(.pane(let paneId), let todoId, let toIndex) = msg {
                return paneId == fx.paneId && todoId.rawValue == fx.openId && toIndex == 1
            }
            return false
        }
    }

    uiTest("Escape in list mode sends toggleTodoPopover") {
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }

        fx.table.cancelOperation(nil)

        try expectSingleMessage(fx.runtime, "list escape dismiss") { msg in
            if case .toggleTodoPopover(.pane(let paneId)) = msg { return paneId == fx.paneId }
            return false
        }
    }

    uiTest("Escape in compose focuses list when possible and dismisses empty lists") {
        // Intent: Escape from compose moves focus to the list when a row exists;
        //   with an empty list, it dismisses the popover instead.
        // Why it exists: pins the two branches of focusListFromInput from the
        //   text delegate entry point. Spec-first.
        // Scenario: the user presses Escape in compose on a populated pane and
        //   on an empty pane.
        do {
            let fx = makePaneTodoFixture()
            defer { fx.window.close() }
            let compose = try visibleTodoInput(in: fx)

            let handled = fx.vc.textView(compose.textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))

            try uiExpect(handled, "compose escape should be handled")
            try uiExpect(fx.runtime.sentMessages.isEmpty, "populated compose escape should not dismiss")
            try uiExpect(fx.table.selectedRow >= 0, "populated compose escape should select a row")
            try uiExpect(fx.window.firstResponder === fx.table, "populated compose escape should focus the table")
        }

        do {
            let fx = makePaneTodoFixture(todos: [])
            defer { fx.window.close() }
            let compose = try visibleTodoInput(in: fx)

            let handled = fx.vc.textView(compose.textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))

            try uiExpect(handled, "empty compose escape should be handled")
            try expectSingleMessage(fx.runtime, "empty compose escape dismiss") { msg in
                if case .toggleTodoPopover(.pane(let paneId)) = msg { return paneId == fx.paneId }
                return false
            }
        }
    }

    uiTest("pasteboardWriterForRow emits pane todo UUID string") {
        // Intent: item rows write a bare UUID string for the pane todo drag
        //   pasteboard type.
        // Why it exists: pins the supported drag payload without testing an
        //   NSDraggingInfo drop fake. Spec-first.
        // Scenario: AppKit asks the table for the drag payload of a todo row.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        let row = try rowIndex(titled: "Pane alpha", in: fx)
        let type = NSPasteboard.PasteboardType("com.danneu.danterm.todo-row")

        guard let item = fx.vc.tableView(fx.table, pasteboardWriterForRow: row) as? NSPasteboardItem else {
            throw UITestFailure(message: "missing pasteboard item")
        }

        try uiExpect(item.string(forType: type) == fx.openId.uuidString,
                     "drag payload should be the row todo UUID")
    }

    uiTest("apply preserves compose focus and draft") {
        // Intent: applying a fresh projection while compose is first responder
        //   keeps compose focused and preserves its draft.
        // Why it exists: pins the compose branch of restoreFirstResponder for
        //   model refreshes. Spec-first.
        // Scenario: model data refreshes while the user is typing a new pane
        //   task.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        let compose = try visibleTodoInput(in: fx)
        compose.string = "compose draft"
        fx.window.makeFirstResponder(compose.textView)

        var todos = fx.model.pane(fx.paneId)!.todos
        todos[1].text = "Pane beta refreshed"
        let model = modelByReplacingTodos(fx.model, paneId: fx.paneId, todos: todos)
        fx.vc.apply(desiredPaneTodoPopover(paneId: fx.paneId, in: model)!)
        settlePaneTodoFixture(fx)

        let visible = try visibleTodoInput(in: fx)
        try uiExpect(visible === compose, "compose input should remain visible")
        try uiExpect(visible.string == "compose draft", "compose draft should survive apply")
        try uiExpect(fx.window.firstResponder === compose.textView, "compose input should remain first responder")
    }

    uiTest("apply preserves table focus or falls back to compose when rows empty") {
        // Intent: applying while the table is focused keeps table focus when
        //   the selected item survives; if the list empties, focus moves to
        //   compose.
        // Why it exists: pins the table branch of restoreFirstResponder,
        //   including its empty-list fallback. Spec-first.
        // Scenario: a selected row survives one refresh, then all rows are
        //   removed by another refresh.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        let row = try rowIndex(titled: "Pane beta", in: fx)
        fx.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        fx.window.makeFirstResponder(fx.table)

        var todos = fx.model.pane(fx.paneId)!.todos
        todos[1].text = "Pane beta refreshed"
        var model = modelByReplacingTodos(fx.model, paneId: fx.paneId, todos: todos)
        fx.vc.apply(desiredPaneTodoPopover(paneId: fx.paneId, in: model)!)
        settlePaneTodoFixture(fx)

        try uiExpect(fx.window.firstResponder === fx.table, "table should remain first responder while selection survives")
        try uiExpect(try selectedRowTitle(in: fx) == "Pane beta refreshed",
                     "selected row should survive the refresh")

        model = modelByReplacingTodos(model, paneId: fx.paneId, todos: [])
        fx.vc.apply(desiredPaneTodoPopover(paneId: fx.paneId, in: model)!)
        settlePaneTodoFixture(fx)

        let compose = try visibleTodoInput(in: fx)
        try uiExpect(fx.window.firstResponder === compose.textView,
                     "empty refresh should move focus back to compose")
    }

    uiTest("Cmd-N while editing saves, clears compose draft, and focuses compose") {
        // Intent: Cmd-N in edit mode saves the edit, clears the compose draft,
        //   exits edit mode, and focuses compose through the root key-equivalent
        //   hook.
        // Why it exists: pins saveEditThenFocusCompose on the pane controller,
        //   including the view-level performKeyEquivalent route. Spec-first.
        // Scenario: the user has a stale compose draft, edits a row, then
        //   presses Cmd-N to save and start a fresh task.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        installPaneTodoReapplyHook(fx)
        let compose = try visibleTodoInput(in: fx)
        compose.string = "draft to clear"
        fx.vc.textDidChange(Notification(name: NSText.didChangeNotification, object: compose.textView))
        try enterEdit(rowTitle: "Pane alpha", in: fx)
        let editInput = try visibleTodoInput(in: fx)
        editInput.string = "  Pane renamed  "

        let handled = fx.vc.view.performKeyEquivalent(
            with: keyDownEvent(characters: "n", modifiers: [.command], keyCode: 45, window: fx.window))
        settlePaneTodoFixture(fx)

        try uiExpect(handled, "Cmd-N should be handled by the popover root view")
        try expectSingleMessage(fx.runtime, "Cmd-N save edit") { msg in
            if case .editTodoText(.pane(let paneId), let todoId, let text) = msg {
                return paneId == fx.paneId && todoId.rawValue == fx.openId && text == "Pane renamed"
            }
            return false
        }
        let visible = try visibleTodoInput(in: fx)
        try uiExpect(visible.string.isEmpty, "compose draft should be cleared")
        try uiExpect(fx.window.firstResponder === visible.textView, "compose input should be first responder")
    }

    uiTest("shortcut help closes before pane parent disappears") {
        // Intent: the pane popover closes its shortcut-help child before the
        //   parent popover disappears.
        // Why it exists: pins the nested-popover lifetime invariant that the
        //   shared controller base now owns. Spec-first.
        // Scenario: a pane TODO popover opens shortcut help, then the parent
        //   begins closing.
        let fx = makePaneTodoFixture()
        defer { fx.window.close() }
        let parentPopover = NSPopover()
        fx.runtime.todoPopover = parentPopover
        fx.window.orderFrontRegardless()

        fx.vc.toggleShortcutHelp(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        try uiExpect(fx.vc.hasShortcutHelpPopover, "shortcut help should open with a parent popover handle")

        fx.vc.viewWillDisappear()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        try uiExpect(!fx.vc.hasShortcutHelpPopover, "shortcut help should close before the pane parent disappears")
    }
}

private struct PaneTodoFixture {
    let vc: TodoPopoverViewController
    let runtime: AppRuntime
    let window: NSWindow
    let model: AppModel
    let paneId: PaneId
    let table: NSTableView
    let scrollView: NSScrollView
    let openId: UUID
    let secondOpenId: UUID
    let doneId: UUID
}

private func makePaneTodoFixture(todos: [TodoItem]? = nil) -> PaneTodoFixture {
    let tabId = TabId()
    let paneId = PaneId()
    let openId = UUID(uuidString: "00000000-0000-0000-0000-000000001001")!
    let secondOpenId = UUID(uuidString: "00000000-0000-0000-0000-000000001002")!
    let doneId = UUID(uuidString: "00000000-0000-0000-0000-000000001003")!

    var pane = PaneModel(id: paneId)
    pane.todos = todos ?? [
        TodoItem(id: openId, text: "Pane alpha", isDone: false),
        TodoItem(id: secondOpenId, text: "Pane beta", isDone: false),
        TodoItem(id: doneId, text: "Pane done", isDone: true),
    ]

    let tab = TabModel(id: tabId, customTitle: nil, paneTree: PaneTree(root: .leaf(pane), focusedPaneId: paneId))
    let group = GroupModel(id: GroupId(), name: "Group", tabs: [tab])
    var model = AppModel(groups: [group])
    model.selectedTabId = tabId

    let runtime = AppRuntime(model: model)
    let vc = TodoPopoverViewController(paneId: paneId, runtime: runtime)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    window.contentView = vc.view
    vc.apply(desiredPaneTodoPopover(paneId: paneId, in: model)!)
    window.layoutIfNeeded()
    vc.view.layoutSubtreeIfNeeded()
    let table = findTodoTable(in: vc.view)!
    let scrollView = findTodoScrollView(in: vc.view, table: table)!
    materializeTodoRows(table)
    return PaneTodoFixture(
        vc: vc,
        runtime: runtime,
        window: window,
        model: model,
        paneId: paneId,
        table: table,
        scrollView: scrollView,
        openId: openId,
        secondOpenId: secondOpenId,
        doneId: doneId)
}

private func settlePaneTodoFixture(_ fx: PaneTodoFixture) {
    fx.window.layoutIfNeeded()
    fx.vc.view.layoutSubtreeIfNeeded()
    fx.table.layoutSubtreeIfNeeded()
    materializeTodoRows(fx.table)
}

@discardableResult
private func materializedTodoRows(_ fx: PaneTodoFixture) -> [NSView] {
    settlePaneTodoFixture(fx)
    return (0..<fx.table.numberOfRows).compactMap {
        fx.table.view(atColumn: 0, row: $0, makeIfNecessary: true)
    }
}

private func materializeTodoRows(_ table: NSTableView) {
    table.layoutSubtreeIfNeeded()
    for row in 0..<table.numberOfRows {
        _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        _ = table.rowView(atRow: row, makeIfNecessary: true)
    }
}

private func findTodoTable(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for subview in view.subviews {
        if let found = findTodoTable(in: subview) { return found }
    }
    return nil
}

private func findTodoScrollView(in view: NSView, table: NSTableView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView, scrollView.documentView === table { return scrollView }
    for subview in view.subviews {
        if let found = findTodoScrollView(in: subview, table: table) { return found }
    }
    return nil
}

private func rowTextValues(_ rows: [NSView]) -> [String] {
    rows.compactMap { firstTextValue(in: $0) }
}

private func firstTextValue(in view: NSView) -> String? {
    if let textField = view as? NSTextField, !textField.stringValue.isEmpty {
        return textField.stringValue
    }
    for subview in view.subviews {
        if let found = firstTextValue(in: subview) { return found }
    }
    return nil
}

private func allSubviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
    var result: [T] = []
    if let typed = view as? T { result.append(typed) }
    for subview in view.subviews {
        result.append(contentsOf: allSubviews(of: type, in: subview))
    }
    return result
}

private func isEffectivelyHidden(_ view: NSView) -> Bool {
    var current: NSView? = view
    while let candidate = current {
        if candidate.isHidden { return true }
        current = candidate.superview
    }
    return false
}

private func visibleTodoInput(in fx: PaneTodoFixture) throws -> TodoInputView {
    let visible = allSubviews(of: TodoInputView.self, in: fx.vc.view)
        .filter { !isEffectivelyHidden($0) }
    try uiExpect(visible.count == 1, "expected exactly one visible todo input, got \(visible.count)")
    return visible[0]
}

private func hiddenTodoInputs(in fx: PaneTodoFixture) -> [TodoInputView] {
    allSubviews(of: TodoInputView.self, in: fx.vc.view)
        .filter { isEffectivelyHidden($0) }
}

private func onlyTodoButton(titled title: String, in view: NSView) throws -> NSButton {
    let matches = allSubviews(of: NSButton.self, in: view).filter { $0.title == title }
    try uiExpect(matches.count == 1, "expected one button titled \(title), got \(matches.count)")
    return matches[0]
}

private func onlyLabel(titled title: String, in view: NSView) throws -> NSTextField {
    let matches = allSubviews(of: NSTextField.self, in: view).filter { $0.stringValue == title }
    try uiExpect(matches.count == 1, "expected one label titled \(title), got \(matches.count)")
    return matches[0]
}

private func todoRow(titled title: String, in fx: PaneTodoFixture) throws -> (index: Int, view: TodoRowView) {
    let rows = materializedTodoRows(fx)
    for (index, row) in rows.enumerated() {
        guard let todoRow = row as? TodoRowView else { continue }
        if todoRow.textField.stringValue == title {
            return (index, todoRow)
        }
    }
    throw UITestFailure(message: "missing todo row titled \(title)")
}

private func rowIndex(titled title: String, in fx: PaneTodoFixture) throws -> Int {
    let rows = materializedTodoRows(fx)
    for (index, row) in rows.enumerated() {
        if firstTextValue(in: row) == title { return index }
    }
    throw UITestFailure(message: "missing row titled \(title)")
}

private func rowTitle(at row: Int, in fx: PaneTodoFixture) throws -> String {
    let rows = materializedTodoRows(fx)
    guard rows.indices.contains(row), let title = firstTextValue(in: rows[row]) else {
        throw UITestFailure(message: "missing row title at \(row)")
    }
    return title
}

private func selectedRowTitle(in fx: PaneTodoFixture) throws -> String {
    try rowTitle(at: fx.table.selectedRow, in: fx)
}

private func enterEdit(rowTitle: String, in fx: PaneTodoFixture) throws {
    let row = try rowIndex(titled: rowTitle, in: fx)
    fx.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    fx.table.keyDown(with: keyDownEvent(characters: "\r", modifiers: [], keyCode: 36, window: fx.window))
    settlePaneTodoFixture(fx)
}

private func keyDownEvent(
    characters: String,
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16,
    window: NSWindow
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters.lowercased(),
        isARepeat: false,
        keyCode: keyCode)!
}

private func expectSingleMessage(
    _ runtime: AppRuntime,
    _ description: String,
    matches: (Msg) -> Bool
) throws {
    try uiExpect(runtime.sentMessages.count == 1,
                 "expected one message for \(description), got \(runtime.sentMessages.count)")
    guard let msg = runtime.sentMessages.first else { return }
    try uiExpect(matches(msg), "unexpected message for \(description): \(String(describing: msg))")
}

private func modelByReplacingTodos(_ model: AppModel, paneId: PaneId, todos: [TodoItem]) -> AppModel {
    var copy = model
    copy.updatePane(paneId) { pane in
        pane.todos = todos
    }
    return copy
}

private func installPaneTodoReapplyHook(_ fx: PaneTodoFixture) {
    let baseModel = fx.model
    let paneId = fx.paneId
    fx.runtime.onSend = { [weak vc = fx.vc] msg in
        var model = baseModel
        model.updatePane(paneId) { pane in
            applyPaneTodoMessage(msg, paneId: paneId, pane: &pane)
        }
        if let projection = desiredPaneTodoPopover(paneId: paneId, in: model) {
            vc?.apply(projection)
        }
    }
}

private func applyPaneTodoMessage(_ msg: Msg, paneId: PaneId, pane: inout PaneModel) {
    switch msg {
    case .toggleTodoDone(.pane(let targetPaneId), let todoId) where targetPaneId == paneId:
        guard let index = pane.todos.firstIndex(where: { $0.id == todoId }) else { return }
        pane.todos[index].isDone.toggle()
    case .editTodoText(.pane(let targetPaneId), let todoId, let text) where targetPaneId == paneId:
        guard let index = pane.todos.firstIndex(where: { $0.id == todoId }) else { return }
        pane.todos[index].text = text
    case .deleteTodo(.pane(let targetPaneId), let todoId) where targetPaneId == paneId:
        pane.todos.removeAll { $0.id == todoId }
    case .reorderTodo(.pane(let targetPaneId), let todoId, let toIndex) where targetPaneId == paneId:
        guard let fromIndex = pane.todos.firstIndex(where: { $0.id == todoId }),
              toIndex >= 0,
              toIndex <= pane.todos.count else { return }
        let clampedTo = min(toIndex, pane.todos.count - 1)
        guard fromIndex != clampedTo else { return }
        let item = pane.todos.remove(at: fromIndex)
        pane.todos.insert(item, at: min(clampedTo, pane.todos.count))
    case .clearCompletedTodos(.pane(let targetPaneId)) where targetPaneId == paneId:
        pane.todos.removeAll { $0.isDone }
    default:
        break
    }
}
