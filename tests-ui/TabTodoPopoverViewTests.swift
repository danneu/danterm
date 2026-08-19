// UI-harness tests for TabTodoPopoverView's rendered row model, message
// routing, edit/compose modes, reconcile preservation, and pasteboard payloads.
import Cocoa

@MainActor
func tabTodoPopoverViewTests() {
    print("TabTodoPopoverView")

    uiTest("a pane section header lays out one line and truncates") {
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }

        let rows = materializedTabTodoRows(fx)
        guard let header = rows.first(where: { $0.identifier?.rawValue == "PaneTodoHeader" }),
              let title = header.subviews.compactMap({ $0 as? NSTextField })
                  .first(where: { $0.stringValue == "Left pane" }) else {
            throw UITestFailure(message: "expected a pane section header showing its pane title")
        }
        try assertSingleLine(title, "tab-todo pane section header")
    }

    uiTest("apply renders populated tab and pane sections in row order") {
        // Intent: the popover renders the projection's flattened tab/pane row
        //   sequence with the expected AppKit row identifiers and titles.
        // Why it exists: pins the view binding for the richest untested TODO
        //   surface without naming file-private row classes. Spec-first.
        // Scenario: a tab with its own tasks and two pane sections opens the
        //   tab-level TODO popover.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }

        let rows = materializedTabTodoRows(fx)
        try uiExpect(rows.map { $0.identifier?.rawValue } == [
            "TabTodoHeader", "TodoRow", "TodoRow",
            "PaneTodoHeader", "TodoRow", "PaneTodoHeader", "TodoRow",
        ], "unexpected row identifiers: \(rows.map { $0.identifier?.rawValue ?? "nil" })")
        try uiExpect(rows.compactMap { $0 as? TodoRowView }.count == 4, "expected four todo item rows")
        try uiExpect(rowTextValues(rows) == [
            "This tab", "Tab alpha", "Tab done",
            "Left pane", "Pane alpha", "Right pane", "Pane beta",
        ], "unexpected row text: \(rowTextValues(rows))")
    }

    uiTest("empty tab section renders placeholder and clear button follows tab completion") {
        // Intent: an empty tab section shows its placeholder, and Clear
        //   completed is visible only when tab-level todos include a done item.
        // Why it exists: pins tab-scoped completion visibility separately from
        //   pane-level tasks. Spec-first.
        // Scenario: the same popover first has no tab tasks, then reconciles
        //   to a model with one completed tab task.
        let fx = makeTabTodoFixture(tabTodos: [], firstPaneTodos: [])
        defer { fx.window.close() }

        let rows = materializedTabTodoRows(fx)
        try uiExpect(rows.prefix(2).map { $0.identifier?.rawValue } == ["TabTodoHeader", "TabTodoEmptyRow"],
                     "empty tab should render placeholder after header")
        let clearButton = try onlyTabTodoButton(titled: "Clear completed", in: fx.vc.view)
        try uiExpect(clearButton.isHidden, "clear button should be hidden without completed tab todos")

        var model = fx.model
        model.groups[0].tabs[0].todos = [TodoItem(id: fx.tabDoneId, text: "Tab done", isDone: true)]
        fx.vc.apply(desiredTabTodoPopover(tabId: fx.tabId, in: model)!)
        settleTabTodoFixture(fx)

        try uiExpect(!clearButton.isHidden, "clear button should be visible with completed tab todos")
    }

    uiTest("tab-row checkbox sends explicit setTodoDone") {
        // Intent: a tab task checkbox dispatches the explicit done value with
        //   the row item's owner and todo id.
        // Why it exists: pins the button target/action route independently of
        //   row selection. Spec-first.
        // Scenario: the user checks an open task in the tab section.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }

        let row = try todoRow(titled: "Tab alpha", in: fx)
        row.view.checkbox.performClick(nil)

        try expectSingleMessage(fx.runtime, "set tab todo done") { msg in
            if case .setTodoDone(.tab(let tabId), let todoId, let isDone) = msg {
                return tabId == fx.tabId && todoId.rawValue == fx.tabOpenId && isDone
            }
            return false
        }
    }

    uiTest("pane-row checkbox sends setTodoDone for its pane") {
        // Intent: a pane task checkbox dispatches to the pane owning that row,
        //   carrying the inverted done state.
        // Why it exists: guards against resolving pane rows through selected
        //   tab state instead of row payload. Spec-first.
        // Scenario: the user checks an open task from the first pane section.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }

        let row = try todoRow(titled: "Pane alpha", in: fx)
        row.view.checkbox.performClick(nil)

        try expectSingleMessage(fx.runtime, "set pane todo done") { msg in
            if case .setTodoDone(.pane(let paneId), let todoId, let isDone) = msg {
                return paneId == fx.paneIds[0] && todoId.rawValue == fx.paneOpenId && isDone
            }
            return false
        }
    }

    uiTest("delete buttons route tab and pane rows to their owners") {
        // Intent: delete buttons on tab and pane rows dispatch owner-specific
        //   delete messages.
        // Why it exists: pins the shared TodoRowView reuse so a pane row cannot
        //   accidentally send a tab delete. Spec-first.
        // Scenario: the user deletes one task from the tab section and one from
        //   a pane section.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }

        try todoRow(titled: "Tab alpha", in: fx).view.deleteButton.performClick(nil)
        try todoRow(titled: "Pane alpha", in: fx).view.deleteButton.performClick(nil)

        try uiExpect(fx.runtime.sentMessages.count == 2, "expected two delete messages")
        try uiExpect(message(fx.runtime.sentMessages[0]) {
            if case .deleteTodo(.tab(let tabId), let todoId) = $0 {
                return tabId == fx.tabId && todoId.rawValue == fx.tabOpenId
            }
            return false
        }, "first delete should target tab todo")
        try uiExpect(message(fx.runtime.sentMessages[1]) {
            if case .deleteTodo(.pane(let paneId), let todoId) = $0 {
                return paneId == fx.paneIds[0] && todoId.rawValue == fx.paneOpenId
            }
            return false
        }, "second delete should target pane todo")
    }

    uiTest("clear completed sends owner-scoped clearCompletedTodos") {
        // Intent: the Clear completed button dispatches the shared clear
        //   message with the popover's tab owner.
        // Why it exists: pins that the tab popover button does not call the
        //   pane-level clear command. Spec-first.
        // Scenario: a tab with a completed task shows the control and the user
        //   activates it.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }

        let clearButton = try onlyTabTodoButton(titled: "Clear completed", in: fx.vc.view)
        clearButton.performClick(nil)

        try expectSingleMessage(fx.runtime, "clear completed tab todos") { msg in
            if case .clearCompletedTodos(.tab(let tabId)) = msg { return tabId == fx.tabId }
            return false
        }
    }

    uiTest("non-empty compose submit sends owner-scoped addTodo and clears field") {
        // Intent: Enter in the compose field trims, sends the shared add
        //   message with the tab owner, and clears the compose draft.
        // Why it exists: pins the NSTextViewDelegate submit path without
        //   synthesizing broader keyboard state. Spec-first.
        // Scenario: the user types a new tab task with surrounding whitespace
        //   and presses Return.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        let compose = try visibleTodoInput(in: fx)
        compose.string = "  New tab task  "

        let handled = fx.vc.textView(compose.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        try uiExpect(handled, "compose newline should be handled")
        try expectSingleMessage(fx.runtime, "add tab todo") { msg in
            if case .addTodo(.tab(let tabId), let text) = msg {
                return tabId == fx.tabId && text == "New tab task"
            }
            return false
        }
        try uiExpect(compose.string.isEmpty, "compose field should be cleared")
    }

    uiTest("whitespace compose submit sends nothing") {
        // Intent: whitespace-only compose submits are rejected before dispatch.
        // Why it exists: pins the view's local validation at the AppKit entry
        //   point. Spec-first.
        // Scenario: the user presses Return in a compose field containing only
        //   spaces and newlines.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        let compose = try visibleTodoInput(in: fx)
        compose.string = " \n  "

        let handled = fx.vc.textView(compose.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        try uiExpect(handled, "compose newline should still be handled")
        try uiExpect(fx.runtime.sentMessages.isEmpty, "whitespace compose submit should send no messages")
    }

    uiTest("Return on a selected row enters edit mode with item text") {
        // Intent: Return in list mode switches to editor mode for the selected
        //   row and pre-fills the edit field.
        // Why it exists: pins the minimal key synthesis route through
        //   classifyListAction -> enterEdit. Spec-first.
        // Scenario: the user selects a tab task row and presses Return.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }

        try enterEdit(rowTitle: "Tab alpha", in: fx)

        let editInput = try visibleTodoInput(in: fx)
        try uiExpect(editInput.string == "Tab alpha", "edit input should be prefilled")
        try uiExpect(isEffectivelyHidden(fx.table), "table should be hidden in edit mode")
        try uiExpect(hiddenTodoInputs(in: fx).contains { $0.string != "Tab alpha" },
                     "compose input should be hidden in edit mode")
    }

    uiTest("save button sends trimmed tab and pane edit messages") {
        // Intent: Save commits edits to the selected row's owner and returns to
        //   list mode.
        // Why it exists: pins both tab and pane edit dispatch paths through the
        //   shared editor controls. Spec-first.
        // Scenario: the user edits one tab task and one pane task in separate
        //   popover instances.
        do {
            let fx = makeTabTodoFixture()
            defer { fx.window.close() }
            try enterEdit(rowTitle: "Tab alpha", in: fx)
            let editInput = try visibleTodoInput(in: fx)
            editInput.string = "  Tab changed  "
            try onlyTabTodoButton(titled: "Save", in: fx.vc.view).performClick(nil)

            try expectSingleMessage(fx.runtime, "edit tab todo") { msg in
                if case .editTodoText(.tab(let tabId), let todoId, let text) = msg {
                    return tabId == fx.tabId && todoId.rawValue == fx.tabOpenId && text == "Tab changed"
                }
                return false
            }
            try uiExpect(!isEffectivelyHidden(fx.table), "table should be visible after saving")
        }

        do {
            let fx = makeTabTodoFixture()
            defer { fx.window.close() }
            try enterEdit(rowTitle: "Pane alpha", in: fx)
            let editInput = try visibleTodoInput(in: fx)
            editInput.string = "  Pane changed  "
            try onlyTabTodoButton(titled: "Save", in: fx.vc.view).performClick(nil)

            try expectSingleMessage(fx.runtime, "edit pane todo") { msg in
                if case .editTodoText(.pane(let paneId), let todoId, let text) = msg {
                    return paneId == fx.paneIds[0] && todoId.rawValue == fx.paneOpenId && text == "Pane changed"
                }
                return false
            }
            try uiExpect(!isEffectivelyHidden(fx.table), "table should be visible after saving")
        }
    }

    uiTest("whitespace-only save is rejected and stays editing") {
        // Intent: Save rejects an edit draft that trims to empty and keeps the
        //   editor active.
        // Why it exists: pins validation before dispatch so empty task text is
        //   never sent to update. Spec-first.
        // Scenario: the user deletes the entire edit field and presses Save.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        try enterEdit(rowTitle: "Tab alpha", in: fx)
        let editInput = try visibleTodoInput(in: fx)
        editInput.string = " \n "

        try onlyTabTodoButton(titled: "Save", in: fx.vc.view).performClick(nil)

        try uiExpect(fx.runtime.sentMessages.isEmpty, "empty edit should send no message")
        try uiExpect(try visibleTodoInput(in: fx) === editInput, "editor should remain visible")
        try uiExpect(isEffectivelyHidden(fx.table), "table should remain hidden while edit is rejected")
    }

    uiTest("cancel button exits edit mode without sending") {
        // Intent: Cancel abandons the active edit and returns to list mode
        //   without dispatch.
        // Why it exists: pins editor cancellation as view-local state only.
        //   Spec-first.
        // Scenario: the user enters edit mode and presses Cancel.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        try enterEdit(rowTitle: "Tab alpha", in: fx)

        try onlyTabTodoButton(titled: "Cancel", in: fx.vc.view).performClick(nil)

        try uiExpect(fx.runtime.sentMessages.isEmpty, "cancel should send no messages")
        try uiExpect(!isEffectivelyHidden(fx.table), "table should be visible after cancel")
    }

    uiTest("apply mid-edit preserves draft when target still exists") {
        // Intent: reconcile preserves an in-progress edit draft when the same
        //   todo target survives in the new projection.
        // Why it exists: pins the e7d4576 behavior that open popover contents
        //   reconcile without clobbering local drafts. Spec-first.
        // Scenario: model data refreshes while the user is editing a tab task.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        try enterEdit(rowTitle: "Tab alpha", in: fx)
        let editInput = try visibleTodoInput(in: fx)
        editInput.string = "draft survives"

        var model = fx.model
        model.groups[0].tabs[0].todos[0].text = "server text"
        fx.vc.apply(desiredTabTodoPopover(tabId: fx.tabId, in: model)!)
        settleTabTodoFixture(fx)

        try uiExpect(try visibleTodoInput(in: fx).string == "draft survives",
                     "edit draft should survive reconcile")
        try uiExpect(isEffectivelyHidden(fx.table), "table should remain hidden in edit mode")
    }

    uiTest("apply mid-edit exits edit mode when target is gone") {
        // Intent: reconcile leaves edit mode when the todo being edited no
        //   longer exists in the projection.
        // Why it exists: pins stale-target cleanup for open popovers.
        //   Spec-first.
        // Scenario: a task is deleted elsewhere while the user is editing it.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        try enterEdit(rowTitle: "Tab alpha", in: fx)

        var model = fx.model
        model.groups[0].tabs[0].todos.removeFirst()
        fx.vc.apply(desiredTabTodoPopover(tabId: fx.tabId, in: model)!)
        settleTabTodoFixture(fx)

        try uiExpect(!isEffectivelyHidden(fx.table), "table should be visible after stale edit target disappears")
        try uiExpect(try visibleTodoInput(in: fx).string.isEmpty, "compose field should be visible after exiting edit")
    }

    uiTest("shouldSelectRow focuses pane headers and only selects item rows") {
        // Intent: delegate selection allows item rows, rejects headers and
        //   placeholders, and focuses the pane represented by pane headers.
        // Why it exists: pins the deliberate direct runtime focus side effect
        //   on pane section headers. Spec-first.
        // Scenario: the user clicks normal rows and a pane section header in
        //   the tab-level TODO popover.
        let fx = makeTabTodoFixture(secondPaneTodos: [])
        defer { fx.window.close() }

        let tabHeader = try rowIndex(identifier: "TabTodoHeader", in: fx)
        let tabItem = try rowIndex(titled: "Tab alpha", in: fx)
        let placeholder = try rowIndex(identifier: "TabTodoEmptyRow", in: fx)
        let paneHeader = try rowIndex(titled: "Right pane", in: fx)

        try uiExpect(!fx.vc.tableView(fx.table, shouldSelectRow: tabHeader), "tab header should not select")
        try uiExpect(fx.vc.tableView(fx.table, shouldSelectRow: tabItem), "item row should select")
        try uiExpect(!fx.vc.tableView(fx.table, shouldSelectRow: placeholder), "placeholder should not select")
        try uiExpect(!fx.vc.tableView(fx.table, shouldSelectRow: paneHeader), "pane header should not select")
        try uiExpect(fx.runtime.focusedPaneSessions == [fx.paneIds[1]],
                     "pane header should focus its pane, got \(fx.runtime.focusedPaneSessions)")
    }

    uiTest("pasteboardWriterForRow emits tab and pane drag payloads") {
        // Intent: item rows write drag payload JSON identifying their source
        //   bucket and todo id; non-item rows do not write anything.
        // Why it exists: pins the supported drag surface without testing the
        //   NSDraggingInfo drop fake that remains out of scope. Spec-first.
        // Scenario: AppKit asks the table for pasteboard writers for tab,
        //   pane, header, and placeholder rows.
        let fx = makeTabTodoFixture(secondPaneTodos: [])
        defer { fx.window.close() }

        let tabHeader = try rowIndex(identifier: "TabTodoHeader", in: fx)
        let tabItem = try rowIndex(titled: "Tab alpha", in: fx)
        let paneItem = try rowIndex(titled: "Pane alpha", in: fx)
        let placeholder = try rowIndex(identifier: "TabTodoEmptyRow", in: fx)

        try uiExpect(fx.vc.tableView(fx.table, pasteboardWriterForRow: tabHeader) == nil,
                     "header rows should not write drag payloads")
        try uiExpect(fx.vc.tableView(fx.table, pasteboardWriterForRow: placeholder) == nil,
                     "placeholder rows should not write drag payloads")

        let tabPayload = try dragPayload(row: tabItem, in: fx)
        try uiExpect(tabPayload.kind == "tab", "tab payload kind should be tab")
        try uiExpect(tabPayload.paneId == nil, "tab payload should not carry paneId")
        try uiExpect(tabPayload.todoId == fx.tabOpenId.uuidString, "tab payload todo id mismatch")

        let panePayload = try dragPayload(row: paneItem, in: fx)
        try uiExpect(panePayload.kind == "pane", "pane payload kind should be pane")
        try uiExpect(panePayload.paneId == fx.paneIds[0].rawValue.uuidString, "pane payload pane id mismatch")
        try uiExpect(panePayload.todoId == fx.paneOpenId.uuidString, "pane payload todo id mismatch")
    }

    uiTest("shortcut help closes before tab parent disappears") {
        // Intent: the tab popover closes its shortcut-help child before the
        //   parent popover disappears.
        // Why it exists: pins the nested-popover lifetime invariant that the
        //   shared controller base now owns. Spec-first.
        // Scenario: a tab TODO popover opens shortcut help, then the parent
        //   begins closing.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        let parentPopover = NSPopover()
        fx.runtime.todoPopover = parentPopover
        fx.window.orderFrontRegardless()

        fx.vc.toggleShortcutHelp(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        try uiExpect(fx.vc.hasShortcutHelpPopover, "shortcut help should open with a parent popover handle")

        fx.vc.viewWillDisappear()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))

        try uiExpect(!fx.vc.hasShortcutHelpPopover, "shortcut help should close before the tab parent disappears")
    }

    uiTest("Escape in list mode sends toggleTodoPopover") {
        // Intent: Escape with the list focused dismisses the tab popover
        //   through the toggle message.
        // Why it exists: the pane suite already pins this; the tab suite was
        //   silent about its own dismiss owner. Spec-first.
        // Scenario: the user presses Escape while the tab TODO list is focused.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }

        fx.table.cancelOperation(nil)

        try expectSingleMessage(fx.runtime, "list escape dismiss") { msg in
            if case .toggleTodoPopover(.tab(let tabId)) = msg { return tabId == fx.tabId }
            return false
        }
    }

    uiTest("Cmd-Backspace deletes the selected row and selects the nearest survivor") {
        // Intent: Cmd-Backspace dispatches delete for the selected row and
        //   moves selection to the nearest remaining selectable row.
        // Why it exists: the tab list has non-selectable header and
        //   placeholder rows, so the survivor search has to skip them.
        //   Spec-first.
        // Scenario: the user selects "Tab alpha" and presses Cmd-Backspace.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        installTabTodoReapplyHook(fx)
        let row = try rowIndex(titled: "Tab alpha", in: fx)
        fx.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        fx.window.makeFirstResponder(fx.table)

        let handled = fx.vc.view.performKeyEquivalent(
            with: keyDownEvent(characters: "\u{8}", modifiers: [.command], keyCode: 51, window: fx.window))
        settleTabTodoFixture(fx)

        try uiExpect(handled, "Cmd-Backspace should be handled by the popover root view")
        try expectSingleMessage(fx.runtime, "keyboard delete tab todo") { msg in
            if case .deleteTodo(.tab(let tabId), let todoId) = msg {
                return tabId == fx.tabId && todoId.rawValue == fx.tabOpenId
            }
            return false
        }
        try uiExpect(try selectedRowTitle(in: fx) == "Tab done",
                     "selection should move to the nearest surviving row")
    }

    uiTest("Cmd-N while editing saves, clears the compose draft, and focuses compose") {
        // Intent: Cmd-N in edit mode saves the edit, clears the compose draft,
        //   leaves edit mode, and focuses compose.
        // Why it exists: the pane suite pins this route; the tab suite was
        //   silent even though the tab controller reaches it through a
        //   different key-equivalent branch. Spec-first.
        // Scenario: the user has a stale compose draft, edits a tab task, then
        //   presses Cmd-N.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        installTabTodoReapplyHook(fx)
        let compose = try visibleTodoInput(in: fx)
        compose.string = "draft to clear"
        fx.vc.textDidChange(Notification(name: NSText.didChangeNotification, object: compose.textView))
        try enterEdit(rowTitle: "Tab alpha", in: fx)
        let editInput = try visibleTodoInput(in: fx)
        editInput.string = "  Tab renamed  "

        let handled = fx.vc.view.performKeyEquivalent(
            with: keyDownEvent(characters: "n", modifiers: [.command], keyCode: 45, window: fx.window))
        settleTabTodoFixture(fx)

        try uiExpect(handled, "Cmd-N should be handled by the popover root view")
        try expectSingleMessage(fx.runtime, "Cmd-N save edit") { msg in
            if case .editTodoText(.tab(let tabId), let todoId, let text) = msg {
                return tabId == fx.tabId && todoId.rawValue == fx.tabOpenId && text == "Tab renamed"
            }
            return false
        }
        let visible = try visibleTodoInput(in: fx)
        try uiExpect(visible.string.isEmpty, "compose draft should be cleared")
        try uiExpect(fx.window.firstResponder === visible.textView, "compose input should be first responder")
    }

    uiTest("apply preserves compose focus and draft") {
        // Intent: applying a fresh projection while compose is first responder
        //   keeps compose focused and preserves its draft.
        // Why it exists: pins the compose branch of first-responder restore on
        //   the tab controller, matching the pane suite. Spec-first.
        // Scenario: model data refreshes while the user is typing a new tab
        //   task.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        let compose = try visibleTodoInput(in: fx)
        compose.string = "compose draft"
        fx.window.makeFirstResponder(compose.textView)

        var model = fx.model
        model.groups[0].tabs[0].todos[0].text = "Tab alpha refreshed"
        fx.vc.apply(desiredTabTodoPopover(tabId: fx.tabId, in: model)!)
        settleTabTodoFixture(fx)

        let visible = try visibleTodoInput(in: fx)
        try uiExpect(visible === compose, "compose input should remain visible")
        try uiExpect(visible.string == "compose draft", "compose draft should survive apply")
        try uiExpect(fx.window.firstResponder === compose.textView, "compose input should remain first responder")
    }

    uiTest("apply preserves table focus or falls back to compose when no row is selectable") {
        // Intent: applying while the table is focused keeps table focus when
        //   the selected item survives; when every task disappears, focus
        //   moves to compose.
        // Why it exists: pins the table branch of first-responder restore,
        //   including its fallback, on a list whose remaining rows are all
        //   headers and placeholders. Spec-first.
        // Scenario: a selected tab task survives one refresh, then every task
        //   in the tab and its panes is removed.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        let row = try rowIndex(titled: "Tab alpha", in: fx)
        fx.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        fx.window.makeFirstResponder(fx.table)

        var model = fx.model
        model.groups[0].tabs[0].todos[0].text = "Tab alpha refreshed"
        fx.vc.apply(desiredTabTodoPopover(tabId: fx.tabId, in: model)!)
        settleTabTodoFixture(fx)

        try uiExpect(fx.window.firstResponder === fx.table, "table should remain first responder while selection survives")
        try uiExpect(try selectedRowTitle(in: fx) == "Tab alpha refreshed",
                     "selected row should survive the refresh")

        model.groups[0].tabs[0].todos = []
        for paneId in fx.paneIds {
            model.updatePane(paneId) { $0.todos = [] }
        }
        fx.vc.apply(desiredTabTodoPopover(tabId: fx.tabId, in: model)!)
        settleTabTodoFixture(fx)

        let compose = try visibleTodoInput(in: fx)
        try uiExpect(fx.window.firstResponder === compose.textView,
                     "a list with no selectable row should move focus back to compose")
    }

    uiTest("accepted same-bucket drop reorders the tab section and keeps the dropped todo selected") {
        // Intent: dropping a tab task inside its own section accepts the drop,
        //   dispatches the reorder message with the section-local index, and
        //   leaves the dropped task selected.
        // Why it exists: the drop path decides both which message to send and
        //   what stays selected across the re-entrant apply, and no test
        //   reached it. Spec-first.
        // Scenario: the user drags "Tab alpha" and drops it above "Tab done".
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        installTabTodoReapplyHook(fx)
        let source = try rowIndex(titled: "Tab alpha", in: fx)
        let destination = try rowIndex(titled: "Tab done", in: fx)

        let info = try tabDropInfo(forRow: source, in: fx)
        let accepted = fx.vc.tableView(fx.table, acceptDrop: info, row: destination, dropOperation: .above)
        settleTabTodoFixture(fx)

        try uiExpect(accepted, "same-bucket drop should be accepted")
        try expectSingleMessage(fx.runtime, "tab drop reorder") { msg in
            if case .reorderTodo(.tab(let tabId), let todoId, let toIndex) = msg {
                return tabId == fx.tabId && todoId.rawValue == fx.tabOpenId && toIndex == 1
            }
            return false
        }
        try uiExpect(rowTextValues(materializedTabTodoRows(fx)).prefix(3) == ["This tab", "Tab done", "Tab alpha"],
                     "dropped task should follow Tab done, got \(rowTextValues(materializedTabTodoRows(fx)))")
        try uiExpect(try selectedRowTitle(in: fx) == "Tab alpha", "dropped task should stay selected")
        try uiExpect(try selectedRowDragPayload(in: fx).kind == "tab",
                     "dropped task should still belong to the tab section")
    }

    uiTest("accepted cross-bucket drop moves the todo and selects it under its new owner") {
        // Intent: dropping a tab task into a pane section accepts the drop,
        //   dispatches moveTodo rather than reorderTodo, and selects the task
        //   at its new owner.
        // Why it exists: same-bucket and cross-bucket drops send different
        //   messages and resolve selection against different owners; only a
        //   drop test separates them. Spec-first.
        // Scenario: the user drags "Tab alpha" and drops it above "Pane alpha".
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        installTabTodoReapplyHook(fx)
        let source = try rowIndex(titled: "Tab alpha", in: fx)
        let destination = try rowIndex(titled: "Pane alpha", in: fx)

        let info = try tabDropInfo(forRow: source, in: fx)
        let accepted = fx.vc.tableView(fx.table, acceptDrop: info, row: destination, dropOperation: .above)
        settleTabTodoFixture(fx)

        try uiExpect(accepted, "cross-bucket drop should be accepted")
        try expectSingleMessage(fx.runtime, "tab drop move") { msg in
            if case .moveTodo(.tab(let tabId), let todoId, .pane(let paneId), let atIndex) = msg {
                return tabId == fx.tabId
                    && todoId.rawValue == fx.tabOpenId
                    && paneId == fx.paneIds[0]
                    && atIndex == 0
            }
            return false
        }
        try uiExpect(try selectedRowTitle(in: fx) == "Tab alpha", "moved task should stay selected")
        let payload = try selectedRowDragPayload(in: fx)
        try uiExpect(payload.kind == "pane" && payload.paneId == fx.paneIds[0].rawValue.uuidString,
                     "moved task should be selected under its new pane owner")
    }

    uiTest("Shift-L and Shift-H move the selected todo between buckets and keep it selected") {
        // Intent: the bucket keys move the selected task to the adjacent
        //   section and leave it selected under its new owner in both
        //   directions.
        // Why it exists: bucket moves are the tab popover's only scope-unique
        //   list action, and nothing pinned the message or the selection that
        //   follows it. Spec-first.
        // Scenario: the user selects "Tab alpha", presses Shift-L to push it
        //   into the first pane, then Shift-H to pull it back.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        installTabTodoReapplyHook(fx)
        let row = try rowIndex(titled: "Tab alpha", in: fx)
        fx.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        fx.window.makeFirstResponder(fx.table)

        fx.table.keyDown(with: keyDownEvent(characters: "L", modifiers: [.shift], keyCode: 37, window: fx.window))
        settleTabTodoFixture(fx)

        try uiExpect(fx.runtime.sentMessages.count == 1, "Shift-L should send one message")
        try uiExpect(message(fx.runtime.sentMessages[0]) { msg in
            if case .moveTodo(.tab(let tabId), let todoId, .pane(let paneId), let atIndex) = msg {
                return tabId == fx.tabId
                    && todoId.rawValue == fx.tabOpenId
                    && paneId == fx.paneIds[0]
                    && atIndex == 0
            }
            return false
        }, "Shift-L should move the task into the first pane")
        try uiExpect(try selectedRowTitle(in: fx) == "Tab alpha", "moved task should stay selected")
        try uiExpect(try selectedRowDragPayload(in: fx).paneId == fx.paneIds[0].rawValue.uuidString,
                     "moved task should be selected under the pane it landed in")

        fx.table.keyDown(with: keyDownEvent(characters: "H", modifiers: [.shift], keyCode: 4, window: fx.window))
        settleTabTodoFixture(fx)

        try uiExpect(fx.runtime.sentMessages.count == 2, "Shift-H should send a second message")
        try uiExpect(message(fx.runtime.sentMessages[1]) { msg in
            if case .moveTodo(.pane(let paneId), let todoId, .tab(let tabId), let atIndex) = msg {
                return paneId == fx.paneIds[0]
                    && todoId.rawValue == fx.tabOpenId
                    && tabId == fx.tabId
                    && atIndex == 0
            }
            return false
        }, "Shift-H should move the task back to the tab section")
        try uiExpect(try selectedRowTitle(in: fx) == "Tab alpha", "returned task should stay selected")
        try uiExpect(try selectedRowDragPayload(in: fx).kind == "tab",
                     "returned task should be selected under the tab section")
    }

    uiTest("Cmd-Shift-H and Cmd-Shift-L are swallowed by the tab popover") {
        // Intent: the tab popover claims the Cmd-Shift bucket keys so they
        //   never reach the surrounding app, and dispatches nothing for them.
        // Why it exists: the pane popover deliberately lets the same keys
        //   bubble; only the returned handled flag distinguishes the two.
        //   Spec-first.
        // Scenario: the user presses Cmd-Shift-H and Cmd-Shift-L with a tab
        //   TODO popover open.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }

        let left = fx.vc.view.performKeyEquivalent(
            with: keyDownEvent(characters: "h", modifiers: [.command, .shift], keyCode: 4, window: fx.window))
        let right = fx.vc.view.performKeyEquivalent(
            with: keyDownEvent(characters: "l", modifiers: [.command, .shift], keyCode: 37, window: fx.window))

        try uiExpect(left, "Cmd-Shift-H should be swallowed by the tab popover")
        try uiExpect(right, "Cmd-Shift-L should be swallowed by the tab popover")
        try uiExpect(fx.runtime.sentMessages.isEmpty, "swallowed bucket keys should send nothing")
    }

    uiTest("compose submit selects the newly added tab task") {
        // Intent: after adding a task from compose, the tab popover selects the
        //   row that just appeared.
        // Why it exists: the selection is resolved against the projection the
        //   re-entrant apply installed during send, so it only holds if the
        //   controller reads the new projection after dispatch. Spec-first.
        // Scenario: with "Tab done" selected, the user types a new task in
        //   compose and presses Return.
        let fx = makeTabTodoFixture()
        defer { fx.window.close() }
        installTabTodoReapplyHook(fx)
        let row = try rowIndex(titled: "Tab done", in: fx)
        fx.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let compose = try visibleTodoInput(in: fx)
        compose.string = "Tab gamma"

        _ = fx.vc.textView(compose.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        settleTabTodoFixture(fx)

        try expectSingleMessage(fx.runtime, "add tab todo") { msg in
            if case .addTodo(.tab(let tabId), let text) = msg {
                return tabId == fx.tabId && text == "Tab gamma"
            }
            return false
        }
        try uiExpect(try selectedRowTitle(in: fx) == "Tab gamma",
                     "the newly added task should be selected")
    }
}

private struct TabTodoFixture {
    let vc: TabTodoPopoverViewController
    let runtime: AppRuntime
    let window: NSWindow
    let model: AppModel
    let tabId: TabId
    let paneIds: [PaneId]
    let table: NSTableView
    let tabOpenId: UUID
    let tabDoneId: UUID
    let paneOpenId: UUID
}

private func makeTabTodoFixture(
    tabTodos: [TodoItem]? = nil,
    firstPaneTodos: [TodoItem]? = nil,
    secondPaneTodos: [TodoItem]? = nil
) -> TabTodoFixture {
    let tabId = TabId()
    let firstPaneId = PaneId()
    let secondPaneId = PaneId()
    let tabOpenId = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let tabDoneId = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let paneOpenId = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    let paneSecondId = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!

    var firstPane = PaneModel(id: firstPaneId)
    firstPane.session = SessionModel(id: SessionId(), title: "Left pane")
    firstPane.todos = firstPaneTodos ?? [
        TodoItem(id: paneOpenId, text: "Pane alpha", isDone: false),
    ]

    var secondPane = PaneModel(id: secondPaneId)
    secondPane.session = SessionModel(id: SessionId(), title: "Right pane")
    secondPane.todos = secondPaneTodos ?? [
        TodoItem(id: paneSecondId, text: "Pane beta", isDone: false),
    ]

    let rootNode = SplitNodeModel.split(
        id: SplitId(),
        direction: .horizontal,
        first: .leaf(firstPane),
        second: .leaf(secondPane),
        ratio: 0.5)
    let tab = TabModel(id: tabId, customTitle: nil, paneTree: PaneTree(root: rootNode, focusedPaneId: firstPaneId), todos: tabTodos ?? [
            TodoItem(id: tabOpenId, text: "Tab alpha", isDone: false),
            TodoItem(id: tabDoneId, text: "Tab done", isDone: true),
        ])
    let group = GroupModel(id: GroupId(), name: "Group", tabs: [tab])
    var model = AppModel(groups: [group])
    model.selectedTabId = tabId

    let runtime = AppRuntime(model: model)
    let vc = TabTodoPopoverViewController(tabId: tabId, runtime: runtime)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    window.contentView = vc.view
    vc.apply(desiredTabTodoPopover(tabId: tabId, in: model)!)
    window.layoutIfNeeded()
    vc.view.layoutSubtreeIfNeeded()
    let table = findTabTodoTable(in: vc.view)!
    materializeTabTodoRows(table)
    return TabTodoFixture(
        vc: vc,
        runtime: runtime,
        window: window,
        model: model,
        tabId: tabId,
        paneIds: [firstPaneId, secondPaneId],
        table: table,
        tabOpenId: tabOpenId,
        tabDoneId: tabDoneId,
        paneOpenId: paneOpenId)
}

private func settleTabTodoFixture(_ fx: TabTodoFixture) {
    fx.window.layoutIfNeeded()
    fx.vc.view.layoutSubtreeIfNeeded()
    fx.table.layoutSubtreeIfNeeded()
    materializeTabTodoRows(fx.table)
}

@discardableResult
private func materializedTabTodoRows(_ fx: TabTodoFixture) -> [NSView] {
    settleTabTodoFixture(fx)
    return (0..<fx.table.numberOfRows).compactMap {
        fx.table.view(atColumn: 0, row: $0, makeIfNecessary: true)
    }
}

private func materializeTabTodoRows(_ table: NSTableView) {
    table.layoutSubtreeIfNeeded()
    for row in 0..<table.numberOfRows {
        _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        _ = table.rowView(atRow: row, makeIfNecessary: true)
    }
}

private func findTabTodoTable(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for subview in view.subviews {
        if let found = findTabTodoTable(in: subview) { return found }
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

private func visibleTodoInput(in fx: TabTodoFixture) throws -> TodoInputView {
    let visible = allSubviews(of: TodoInputView.self, in: fx.vc.view)
        .filter { !isEffectivelyHidden($0) }
    try uiExpect(visible.count == 1, "expected exactly one visible todo input, got \(visible.count)")
    return visible[0]
}

private func hiddenTodoInputs(in fx: TabTodoFixture) -> [TodoInputView] {
    allSubviews(of: TodoInputView.self, in: fx.vc.view)
        .filter { isEffectivelyHidden($0) }
}

private func onlyTabTodoButton(titled title: String, in view: NSView) throws -> NSButton {
    let matches = allSubviews(of: NSButton.self, in: view).filter { $0.title == title }
    try uiExpect(matches.count == 1, "expected one button titled \(title), got \(matches.count)")
    return matches[0]
}

private func todoRow(titled title: String, in fx: TabTodoFixture) throws -> (index: Int, view: TodoRowView) {
    let rows = materializedTabTodoRows(fx)
    for (index, row) in rows.enumerated() {
        guard let todoRow = row as? TodoRowView else { continue }
        if todoRow.textField.stringValue == title {
            return (index, todoRow)
        }
    }
    throw UITestFailure(message: "missing todo row titled \(title)")
}

private func rowIndex(titled title: String, in fx: TabTodoFixture) throws -> Int {
    let rows = materializedTabTodoRows(fx)
    for (index, row) in rows.enumerated() {
        if firstTextValue(in: row) == title { return index }
    }
    throw UITestFailure(message: "missing row titled \(title)")
}

private func rowIndex(identifier: String, in fx: TabTodoFixture) throws -> Int {
    let rows = materializedTabTodoRows(fx)
    for (index, row) in rows.enumerated() {
        if row.identifier?.rawValue == identifier { return index }
    }
    throw UITestFailure(message: "missing row identifier \(identifier)")
}

private func enterEdit(rowTitle: String, in fx: TabTodoFixture) throws {
    let row = try rowIndex(titled: rowTitle, in: fx)
    fx.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: fx.window.windowNumber,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36)!
    fx.table.keyDown(with: event)
    settleTabTodoFixture(fx)
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

private func message(_ msg: Msg, matches: (Msg) -> Bool) -> Bool {
    matches(msg)
}

private struct DragPayload {
    let kind: String?
    let paneId: String?
    let todoId: String?
}

private let tabTodoDragType = NSPasteboard.PasteboardType("com.danneu.danterm.tab-todo-row")

private func dragPayload(row: Int, in fx: TabTodoFixture) throws -> DragPayload {
    guard let item = fx.vc.tableView(fx.table, pasteboardWriterForRow: row) as? NSPasteboardItem,
          let json = item.string(forType: tabTodoDragType),
          let data = json.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let source = object["source"] as? [String: Any]
    else {
        throw UITestFailure(message: "missing or invalid drag payload for row \(row)")
    }
    return DragPayload(
        kind: source["kind"] as? String,
        paneId: source["paneId"] as? String,
        todoId: object["todoId"] as? String)
}

private func selectedRowDragPayload(in fx: TabTodoFixture) throws -> DragPayload {
    try dragPayload(row: fx.table.selectedRow, in: fx)
}

/// Round-trip a row's real drag payload back through a dragging-info double, so
/// drop tests exercise the same bytes AppKit would carry.
private func tabDropInfo(forRow row: Int, in fx: TabTodoFixture) throws -> FakeTodoDraggingInfo {
    guard let item = fx.vc.tableView(fx.table, pasteboardWriterForRow: row) as? NSPasteboardItem,
          let json = item.string(forType: tabTodoDragType) else {
        throw UITestFailure(message: "missing drag payload for row \(row)")
    }
    return todoDraggingInfo(type: tabTodoDragType, string: json)
}

private func rowTitle(at row: Int, in fx: TabTodoFixture) throws -> String {
    let rows = materializedTabTodoRows(fx)
    guard rows.indices.contains(row), let title = firstTextValue(in: rows[row]) else {
        throw UITestFailure(message: "missing row title at \(row)")
    }
    return title
}

private func selectedRowTitle(in fx: TabTodoFixture) throws -> String {
    try rowTitle(at: fx.table.selectedRow, in: fx)
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

/// Reproduce production's send timing: reduce the message into a running model
/// and re-apply the resulting projection inside the same `send` frame, so the
/// controller's post-dispatch selection runs against the updated rows.
private func installTabTodoReapplyHook(_ fx: TabTodoFixture) {
    var model = fx.model
    let tabId = fx.tabId
    fx.runtime.onSend = { [weak vc = fx.vc] msg in
        applyTabTodoMessage(msg, tabId: tabId, model: &model)
        if let projection = desiredTabTodoPopover(tabId: tabId, in: model) {
            vc?.apply(projection)
        }
    }
}

private func applyTabTodoMessage(_ msg: Msg, tabId: TabId, model: inout AppModel) {
    func mutate(_ owner: TodoOwner, _ body: (inout [TodoItem]) -> Void) {
        switch owner {
        case .tab(let ownerTabId):
            guard ownerTabId == tabId else { return }
            body(&model.groups[0].tabs[0].todos)
        case .pane(let paneId):
            model.updatePane(paneId) { pane in body(&pane.todos) }
        }
    }

    func insert(_ item: TodoItem, into owner: TodoOwner, at index: Int) {
        mutate(owner) { todos in
            todos.insert(item, at: max(0, min(index, todos.count)))
        }
    }

    switch msg {
    case .addTodo(let owner, let text):
        mutate(owner) { $0.append(TodoItem(id: UUID(), text: text, isDone: false)) }
    case .setTodoDone(let owner, let todoId, let isDone):
        mutate(owner) { todos in
            guard let index = todos.firstIndex(where: { $0.id == todoId }) else { return }
            todos[index].isDone = isDone
        }
    case .toggleTodoDone(let owner, let todoId):
        mutate(owner) { todos in
            guard let index = todos.firstIndex(where: { $0.id == todoId }) else { return }
            todos[index].isDone.toggle()
        }
    case .editTodoText(let owner, let todoId, let text):
        mutate(owner) { todos in
            guard let index = todos.firstIndex(where: { $0.id == todoId }) else { return }
            todos[index].text = text
        }
    case .deleteTodo(let owner, let todoId):
        mutate(owner) { $0.removeAll { $0.id == todoId } }
    case .clearCompletedTodos(let owner):
        mutate(owner) { $0.removeAll { $0.isDone } }
    case .reorderTodo(let owner, let todoId, let toIndex):
        var moved: TodoItem?
        mutate(owner) { todos in
            guard let index = todos.firstIndex(where: { $0.id == todoId }) else { return }
            moved = todos.remove(at: index)
        }
        guard let item = moved else { return }
        insert(item, into: owner, at: toIndex)
    case .moveTodo(let from, let todoId, let to, let atIndex):
        var moved: TodoItem?
        mutate(from) { todos in
            guard let index = todos.firstIndex(where: { $0.id == todoId }) else { return }
            moved = todos.remove(at: index)
        }
        guard let item = moved else { return }
        insert(item, into: to, at: atIndex)
    default:
        break
    }
}
