// Tests for tab-level TODO list messages: add, toggle, edit, delete, reorder,
// clear completed, popover toggle (with mutual exclusion vs the pane popover),
// and close-tab/close-pane confirmations that gate on the tab + pane todo
// rollup.
import Foundation

func updateTabTodoTests() {
    print("Tab TODO tests:")

    func makeTwoPaneTabForMoveTests() -> (model: AppModel, tabId: TabId, paneA: PaneId, paneB: PaneId) {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let paneA = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let paneOrder = allPaneIds(selectedTab(in: model)!.rootNode)
        return (model, tabId, paneOrder[0], paneOrder[1])
    }

    // MARK: - addTabTodo

    test("addTabTodo appends to the tab and leaves panes/other tabs untouched") {
        var model = makeModel()
        createTab(&model) // tab A
        createTab(&model) // tab B (selected)
        let tabA = model.groups[0].tabs[0]
        let tabB = model.groups[0].tabs[1]
        let paneA = tabA.focusedPaneId

        update(&model, .addTodo(paneId: paneA, text: "pane task"))
        let effects = update(&model, .addTabTodo(tabId: tabA.id, text: "tab task"))

        let updatedTabA = tabById(tabA.id, in: model)!
        try expectEqual(updatedTabA.todos.count, 1)
        try expectEqual(updatedTabA.todos[0].text, "tab task")
        try expectEqual(updatedTabA.todos[0].isDone, false)

        // Pane todos untouched
        try expectEqual(model.pane(paneA)!.todos.count, 1)
        try expectEqual(model.pane(paneA)!.todos[0].text, "pane task")

        // Tab B has no todos
        try expectEqual(tabById(tabB.id, in: model)!.todos.count, 0)

        try expect(hasEffect(effects) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "expected scheduleCheckpoint")
    }

    test("addTabTodo trims whitespace and rejects empty") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "  hello  "))
        try expectEqual(tabById(tabId, in: model)!.todos[0].text, "hello")
        update(&model, .addTabTodo(tabId: tabId, text: ""))
        update(&model, .addTabTodo(tabId: tabId, text: "   "))
        try expectEqual(tabById(tabId, in: model)!.todos.count, 1)
    }

    // MARK: - toggleTabTodoDone

    test("toggleTabTodoDone flips only the matched item") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "A"))
        update(&model, .addTabTodo(tabId: tabId, text: "B"))
        let idA = tabById(tabId, in: model)!.todos[0].id
        update(&model, .toggleTabTodoDone(tabId: tabId, todoId: idA))
        try expectEqual(tabById(tabId, in: model)!.todos[0].isDone, true)
        try expectEqual(tabById(tabId, in: model)!.todos[1].isDone, false)
    }

    test("setTabTodoDone sets explicit value") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "A"))
        let idA = tabById(tabId, in: model)!.todos[0].id
        update(&model, .setTabTodoDone(tabId: tabId, todoId: idA, isDone: true))
        try expectEqual(tabById(tabId, in: model)!.todos[0].isDone, true)
        // Setting to the same value is a no-op (no checkpoint)
        let effects = update(&model, .setTabTodoDone(tabId: tabId, todoId: idA, isDone: true))
        try expect(effects.isEmpty, "no-op when value unchanged")
    }

    // MARK: - editTabTodoText

    test("editTabTodoText trims and replaces text; rejects empty") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "old"))
        let idA = tabById(tabId, in: model)!.todos[0].id
        update(&model, .editTabTodoText(tabId: tabId, todoId: idA, text: "  new  "))
        try expectEqual(tabById(tabId, in: model)!.todos[0].text, "new")
        update(&model, .editTabTodoText(tabId: tabId, todoId: idA, text: "   "))
        try expectEqual(tabById(tabId, in: model)!.todos[0].text, "new")
    }

    // MARK: - deleteTabTodo

    test("deleteTabTodo removes by id") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "A"))
        update(&model, .addTabTodo(tabId: tabId, text: "B"))
        let idA = tabById(tabId, in: model)!.todos[0].id
        update(&model, .deleteTabTodo(tabId: tabId, todoId: idA))
        try expectEqual(tabById(tabId, in: model)!.todos.count, 1)
        try expectEqual(tabById(tabId, in: model)!.todos[0].text, "B")
    }

    // MARK: - reorderTabTodo

    test("reorderTabTodo moves item; clamps out-of-bounds") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "A"))
        update(&model, .addTabTodo(tabId: tabId, text: "B"))
        update(&model, .addTabTodo(tabId: tabId, text: "C"))
        let idC = tabById(tabId, in: model)!.todos[2].id
        update(&model, .reorderTabTodo(tabId: tabId, todoId: idC, toIndex: 0))
        try expectEqual(tabById(tabId, in: model)!.todos.map(\.text), ["C", "A", "B"])

        let idA = tabById(tabId, in: model)!.todos[1].id
        let effects = update(&model, .reorderTabTodo(tabId: tabId, todoId: idA, toIndex: 99))
        try expect(effects.isEmpty, "out of bounds is no-op")
    }

    // MARK: - moveTodo

    test("moveTodo pane -> tab inserts at index and removes from pane") {
        var (model, tabId, paneA, _) = makeTwoPaneTabForMoveTests()
        update(&model, .addTabTodo(tabId: tabId, text: "tab A"))
        update(&model, .addTabTodo(tabId: tabId, text: "tab B"))
        update(&model, .addTodo(paneId: paneA, text: "pane task"))
        let todoId = model.pane(paneA)!.todos[0].id

        update(&model, .moveTodo(from: .pane(paneA), todoId: todoId, to: .tab(tabId), atIndex: 1))

        try expectEqual(tabById(tabId, in: model)!.todos.map(\.text), ["tab A", "pane task", "tab B"])
        try expectEqual(model.pane(paneA)!.todos.count, 0)
    }

    test("moveTodo tab -> pane inserts at index and removes from tab") {
        var (model, tabId, paneA, _) = makeTwoPaneTabForMoveTests()
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        update(&model, .addTodo(paneId: paneA, text: "pane A"))
        update(&model, .addTodo(paneId: paneA, text: "pane B"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(paneA), atIndex: 1))

        try expectEqual(tabById(tabId, in: model)!.todos.count, 0)
        try expectEqual(model.pane(paneA)!.todos.map(\.text), ["pane A", "tab task", "pane B"])
    }

    test("moveTodo pane -> pane removes from source pane and inserts into dest pane") {
        var (model, _, paneA, paneB) = makeTwoPaneTabForMoveTests()
        update(&model, .addTodo(paneId: paneA, text: "source"))
        update(&model, .addTodo(paneId: paneB, text: "dest A"))
        let todoId = model.pane(paneA)!.todos[0].id

        update(&model, .moveTodo(from: .pane(paneA), todoId: todoId, to: .pane(paneB), atIndex: 0))

        try expectEqual(model.pane(paneA)!.todos.count, 0)
        try expectEqual(model.pane(paneB)!.todos.map(\.text), ["source", "dest A"])
    }

    test("moveTodo with atIndex > destination.count clamps to count") {
        var (model, tabId, paneA, _) = makeTwoPaneTabForMoveTests()
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        update(&model, .addTodo(paneId: paneA, text: "pane A"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(paneA), atIndex: 99))

        try expectEqual(model.pane(paneA)!.todos.map(\.text), ["pane A", "tab task"])
    }

    test("moveTodo with atIndex < 0 clamps to 0") {
        var (model, tabId, paneA, _) = makeTwoPaneTabForMoveTests()
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        update(&model, .addTodo(paneId: paneA, text: "pane A"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(paneA), atIndex: -5))

        try expectEqual(model.pane(paneA)!.todos.map(\.text), ["tab task", "pane A"])
    }

    test("moveTodo where source == destination is a no-op") {
        var (model, tabId, _, _) = makeTwoPaneTabForMoveTests()
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        let effects = update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .tab(tabId), atIndex: 0))

        try expect(effects.isEmpty, "same bucket should not checkpoint")
        try expectEqual(tabById(tabId, in: model)!.todos.map(\.text), ["tab task"])
    }

    test("moveTodo with unknown todoId is a no-op") {
        var (model, tabId, paneA, _) = makeTwoPaneTabForMoveTests()
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))

        let effects = update(&model, .moveTodo(from: .tab(tabId), todoId: UUID(), to: .pane(paneA), atIndex: 0))

        try expect(effects.isEmpty, "unknown todo should not checkpoint")
        try expectEqual(tabById(tabId, in: model)!.todos.map(\.text), ["tab task"])
        try expectEqual(model.pane(paneA)!.todos.count, 0)
    }

    test("moveTodo with missing destination pane is a no-op and leaves source intact") {
        var (model, tabId, _, _) = makeTwoPaneTabForMoveTests()
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        let effects = update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(PaneId()), atIndex: 0))

        try expect(effects.isEmpty, "missing destination should not checkpoint")
        try expectEqual(tabById(tabId, in: model)!.todos.map(\.text), ["tab task"])
    }

    test("moveTodo across different tabs is a no-op and leaves source intact") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabA = model.groups[0].tabs[0]
        let tabB = model.groups[0].tabs[1]
        update(&model, .addTabTodo(tabId: tabA.id, text: "tab A task"))
        let todoId = tabById(tabA.id, in: model)!.todos[0].id

        let effects = update(&model, .moveTodo(from: .tab(tabA.id), todoId: todoId, to: .tab(tabB.id), atIndex: 0))

        try expect(effects.isEmpty, "cross-tab move should not checkpoint")
        try expectEqual(tabById(tabA.id, in: model)!.todos.map(\.text), ["tab A task"])
        try expectEqual(tabById(tabB.id, in: model)!.todos.count, 0)
    }

    test("moveTodo returns scheduleCheckpoint on success") {
        var (model, tabId, paneA, _) = makeTwoPaneTabForMoveTests()
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        let effects = update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(paneA), atIndex: 0))

        try expect(hasEffect(effects) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "expected scheduleCheckpoint")
    }

    // MARK: - clearCompletedTabTodos

    test("clearCompletedTabTodos removes only done items") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "done"))
        update(&model, .addTabTodo(tabId: tabId, text: "pending"))
        let idDone = tabById(tabId, in: model)!.todos[0].id
        update(&model, .toggleTabTodoDone(tabId: tabId, todoId: idDone))
        update(&model, .clearCompletedTabTodos(tabId: tabId))
        try expectEqual(tabById(tabId, in: model)!.todos.count, 1)
        try expectEqual(tabById(tabId, in: model)!.todos[0].text, "pending")
    }

    // MARK: - popover scope transitions

    test("toggleTodoPopoverForTab while pane popover is open swaps to tab") {
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        let paneId = tab.focusedPaneId
        update(&model, .toggleTodoPopover(paneId: paneId))
        try expectEqual(model.todoPopover, .pane(paneId))

        let effects = update(&model, .toggleTodoPopoverForTab(tabId: tab.id))
        try expectEqual(model.todoPopover, .tab(tab.id))
        try expect(hasEffect(effects) {
            if case .dismissTodoPopover = $0 { return true }
            return false
        }, "expected dismissTodoPopover")
        try expect(hasEffect(effects) {
            if case .showTodoPopoverForTab(let tid) = $0 { return tid == tab.id }
            return false
        }, "expected showTodoPopoverForTab")
    }

    test("toggleTodoPopoverForTab while same tab is open closes the popover") {
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        update(&model, .toggleTodoPopoverForTab(tabId: tab.id))
        try expectEqual(model.todoPopover, .tab(tab.id))

        let effects = update(&model, .toggleTodoPopoverForTab(tabId: tab.id))
        try expect(model.todoPopover == nil, "should clear scope")
        try expect(hasEffect(effects) {
            if case .dismissTodoPopoverForTab = $0 { return true }
            return false
        }, "expected dismissTodoPopoverForTab")
    }

    test("toggleTodoPopover while tab popover is open swaps to pane") {
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        let paneId = tab.focusedPaneId
        update(&model, .toggleTodoPopoverForTab(tabId: tab.id))
        try expectEqual(model.todoPopover, .tab(tab.id))

        let effects = update(&model, .toggleTodoPopover(paneId: paneId))
        try expectEqual(model.todoPopover, .pane(paneId))
        try expect(hasEffect(effects) {
            if case .dismissTodoPopoverForTab = $0 { return true }
            return false
        }, "expected dismissTodoPopoverForTab")
        try expect(hasEffect(effects) {
            if case .showTodoPopover(let pid) = $0 { return pid == paneId }
            return false
        }, "expected showTodoPopover")
    }

    test("toggleTodoPopover while same pane is open closes the popover") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .toggleTodoPopover(paneId: paneId))
        let effects = update(&model, .toggleTodoPopover(paneId: paneId))
        try expect(model.todoPopover == nil)
        try expect(hasEffect(effects) {
            if case .dismissTodoPopover = $0 { return true }
            return false
        }, "expected dismissTodoPopover")
    }

    test("removing the active tab while its tab popover is open emits dismissTodoPopoverForTab") {
        var model = makeModel()
        createTab(&model) // tab A
        createTab(&model) // tab B (so closing A doesn't trigger terminate)
        let tabAId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: tabAId))
        update(&model, .toggleTodoPopoverForTab(tabId: tabAId))
        try expectEqual(model.todoPopover, .tab(tabAId))

        let effects = update(&model, .closeTab(id: tabAId))
        try expect(model.todoPopover == nil, "scope should be cleared")
        try expect(hasEffect(effects) {
            if case .dismissTodoPopoverForTab = $0 { return true }
            return false
        }, "expected dismissTodoPopoverForTab")
    }

    // MARK: - close-tab confirmation rollup

    test("requestCloseTab on single-pane tab with no todos closes directly") {
        var model = makeModel()
        createTab(&model)
        createTab(&model) // second tab so close doesn't trigger terminate
        let firstTabId = model.groups[0].tabs[0].id
        let effects = update(&model, .requestCloseTab(id: firstTabId))
        try expect(!hasEffect(effects) {
            if case .showCloseTabConfirmation = $0 { return true }
            return false
        }, "no confirmation for empty tab")
        try expectEqual(model.groups[0].tabs.count, 1, "tab should be removed")
    }

    test("requestCloseTab on single-pane tab with uncompleted tab todos shows confirmation") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: firstTabId, text: "pending"))

        let effects = update(&model, .requestCloseTab(id: firstTabId))
        try expect(hasEffect(effects) {
            if case .showCloseTabConfirmation(let tid, _, let pc, _, let utc) = $0 {
                return tid == firstTabId && pc == 1 && utc == 1
            }
            return false
        }, "expected confirmation with uncompletedTodoCount=1")
        try expectEqual(model.groups[0].tabs.count, 2, "tab not yet removed")
    }

    test("requestCloseTab on single-pane tab with uncompleted pane todos only shows confirmation") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTab = model.groups[0].tabs[0]
        update(&model, .addTodo(paneId: firstTab.focusedPaneId, text: "pane task"))

        let effects = update(&model, .requestCloseTab(id: firstTab.id))
        try expect(hasEffect(effects) {
            if case .showCloseTabConfirmation(_, _, _, _, let utc) = $0 { return utc == 1 }
            return false
        }, "expected confirmation with rollup pane todos")
    }

    test("requestCloseTab on multi-pane tab with mixed todos rolls up the count") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        let paneA = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let paneB = selectedTab(in: model)!.focusedPaneId

        update(&model, .addTabTodo(tabId: firstTabId, text: "tab one"))
        update(&model, .addTabTodo(tabId: firstTabId, text: "tab two"))
        update(&model, .addTodo(paneId: paneA, text: "pane A 1"))
        update(&model, .addTodo(paneId: paneB, text: "pane B 1"))
        update(&model, .addTodo(paneId: paneB, text: "pane B 2 done"))
        let lastB = model.pane(paneB)!.todos.last!.id
        update(&model, .toggleTodoDone(paneId: paneB, todoId: lastB))

        let effects = update(&model, .requestCloseTab(id: firstTabId))
        try expect(hasEffect(effects) {
            if case .showCloseTabConfirmation(_, _, let pc, _, let utc) = $0 {
                return pc == 2 && utc == 4
            }
            return false
        }, "expected paneCount=2 and uncompletedTodoCount=4")
    }

    test("confirmCloseTab on a tab with todos clears pending and closes") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: firstTabId, text: "pending"))
        update(&model, .requestCloseTab(id: firstTabId))
        try expectEqual(model.pendingConfirmation, .closeTab)

        update(&model, .confirmCloseTab(id: firstTabId))
        try expect(model.pendingConfirmation == nil, "pending should clear")
        try expectEqual(model.groups[0].tabs.count, 1, "tab should be removed")
    }

    // MARK: - requestClosePane rollup gating

    test("requestClosePane on last pane with uncompleted tab todos routes through close-tab confirmation") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTab = model.groups[0].tabs[0]
        update(&model, .addTabTodo(tabId: firstTab.id, text: "tab task"))

        let effects = update(&model, .requestClosePane(paneId: firstTab.focusedPaneId))
        try expect(hasEffect(effects) {
            if case .showCloseTabConfirmation(let tid, _, let pc, _, let utc) = $0 {
                return tid == firstTab.id && pc == 1 && utc == 1
            }
            return false
        }, "expected close-tab confirmation")
        try expect(!hasEffect(effects) {
            if case .showClosePaneConfirmation = $0 { return true }
            return false
        }, "should not show pane-level confirmation")
        try expect(model.pane(firstTab.focusedPaneId) != nil, "pane not yet removed")
    }

    test("requestClosePane on non-last pane with no pane todos but tab todos closes silently") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTab = model.groups[0].tabs[0]
        update(&model, .selectTab(id: firstTab.id))
        let paneA = firstTab.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let paneB = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTabTodo(tabId: firstTab.id, text: "tab task"))

        let effects = update(&model, .requestClosePane(paneId: paneB))
        try expect(!hasEffect(effects) {
            if case .showCloseTabConfirmation = $0 { return true }
            return false
        }, "no close-tab confirmation: tab still alive")
        try expect(!hasEffect(effects) {
            if case .showClosePaneConfirmation = $0 { return true }
            return false
        }, "no pane confirmation: pane has no todos")
        try expect(model.pane(paneB) == nil, "pane should be removed")
    }

    test("requestClosePane on last pane with tab + pane uncompleted todos prefers close-tab confirmation") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTab = model.groups[0].tabs[0]
        let paneA = firstTab.focusedPaneId
        update(&model, .addTabTodo(tabId: firstTab.id, text: "tab task"))
        update(&model, .addTodo(paneId: paneA, text: "pane task"))

        let effects = update(&model, .requestClosePane(paneId: paneA))
        try expect(hasEffect(effects) {
            if case .showCloseTabConfirmation(_, _, _, _, let utc) = $0 { return utc == 2 }
            return false
        }, "expected close-tab rollup of 2")
        try expect(!hasEffect(effects) {
            if case .showClosePaneConfirmation = $0 { return true }
            return false
        }, "should not also show pane confirmation")
    }

    test("requestClosePane on last pane with only pane todos still routes through close-tab confirmation") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTab = model.groups[0].tabs[0]
        let paneA = firstTab.focusedPaneId
        update(&model, .addTodo(paneId: paneA, text: "pane only"))

        let effects = update(&model, .requestClosePane(paneId: paneA))
        try expect(hasEffect(effects) {
            if case .showCloseTabConfirmation(_, _, _, _, let utc) = $0 { return utc == 1 }
            return false
        }, "expected close-tab confirmation with rollup 1")
    }
}
