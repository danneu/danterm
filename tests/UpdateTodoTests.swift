// Tests for per-pane TODO list messages: add, toggle, edit, delete, reorder,
// clear completed, popover toggle, close confirmation, and snapshot round-trip.
import Foundation

func todoTests() {
    print("TODO tests:")

    // MARK: - addTodo

    test("addTodo creates item with correct text and isDone false") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = update(&model, .addTodo(paneId: paneId, text: "run tests"))
        try expectEqual(model.panes[paneId]!.todos.count, 1)
        try expectEqual(model.panes[paneId]!.todos[0].text, "run tests")
        try expectEqual(model.panes[paneId]!.todos[0].isDone, false)
        try expect(hasEffect(effects) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "expected scheduleCheckpoint")
    }

    test("addTodo trims whitespace") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "  hello  "))
        try expectEqual(model.panes[paneId]!.todos[0].text, "hello")
    }

    test("addTodo rejects empty and whitespace-only text") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: ""))
        update(&model, .addTodo(paneId: paneId, text: "   "))
        try expectEqual(model.panes[paneId]!.todos.count, 0)
    }

    // MARK: - toggleTodoDone

    test("toggleTodoDone flips isDone") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "task"))
        let todoId = model.panes[paneId]!.todos[0].id
        let effects = update(&model, .toggleTodoDone(paneId: paneId, todoId: todoId))
        try expectEqual(model.panes[paneId]!.todos[0].isDone, true)
        try expect(hasEffect(effects) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "expected scheduleCheckpoint")
        // Toggle back
        update(&model, .toggleTodoDone(paneId: paneId, todoId: todoId))
        try expectEqual(model.panes[paneId]!.todos[0].isDone, false)
    }

    // MARK: - editTodoText

    test("editTodoText updates text") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "old"))
        let todoId = model.panes[paneId]!.todos[0].id
        update(&model, .editTodoText(paneId: paneId, todoId: todoId, text: "new"))
        try expectEqual(model.panes[paneId]!.todos[0].text, "new")
    }

    test("editTodoText rejects empty text") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "keep"))
        let todoId = model.panes[paneId]!.todos[0].id
        update(&model, .editTodoText(paneId: paneId, todoId: todoId, text: ""))
        try expectEqual(model.panes[paneId]!.todos[0].text, "keep")
        update(&model, .editTodoText(paneId: paneId, todoId: todoId, text: "   "))
        try expectEqual(model.panes[paneId]!.todos[0].text, "keep")
    }

    // MARK: - deleteTodo

    test("deleteTodo removes the correct item") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "A"))
        update(&model, .addTodo(paneId: paneId, text: "B"))
        let idA = model.panes[paneId]!.todos[0].id
        update(&model, .deleteTodo(paneId: paneId, todoId: idA))
        try expectEqual(model.panes[paneId]!.todos.count, 1)
        try expectEqual(model.panes[paneId]!.todos[0].text, "B")
    }

    // MARK: - reorderTodo

    test("reorderTodo moves item to correct position") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "A"))
        update(&model, .addTodo(paneId: paneId, text: "B"))
        update(&model, .addTodo(paneId: paneId, text: "C"))
        let idC = model.panes[paneId]!.todos[2].id
        // Move C to position 0
        update(&model, .reorderTodo(paneId: paneId, todoId: idC, toIndex: 0))
        try expectEqual(model.panes[paneId]!.todos.map(\.text), ["C", "A", "B"])
    }

    test("reorderTodo no-ops on same position") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "A"))
        update(&model, .addTodo(paneId: paneId, text: "B"))
        let idA = model.panes[paneId]!.todos[0].id
        let effects = update(&model, .reorderTodo(paneId: paneId, todoId: idA, toIndex: 0))
        try expectEqual(model.panes[paneId]!.todos.map(\.text), ["A", "B"])
        try expect(!hasEffect(effects) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "should not checkpoint on no-op reorder")
    }

    test("reorderTodo clamps out-of-bounds index") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "A"))
        update(&model, .addTodo(paneId: paneId, text: "B"))
        let idA = model.panes[paneId]!.todos[0].id
        // toIndex beyond count is rejected by guard
        let effects = update(&model, .reorderTodo(paneId: paneId, todoId: idA, toIndex: 99))
        // Should be no-op since 99 > count
        try expect(effects.isEmpty, "out of bounds should be no-op")
    }

    // MARK: - clearCompletedTodos

    test("clearCompletedTodos removes only done items") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "done"))
        update(&model, .addTodo(paneId: paneId, text: "pending"))
        update(&model, .addTodo(paneId: paneId, text: "also done"))
        let idDone = model.panes[paneId]!.todos[0].id
        let idAlsoDone = model.panes[paneId]!.todos[2].id
        update(&model, .toggleTodoDone(paneId: paneId, todoId: idDone))
        update(&model, .toggleTodoDone(paneId: paneId, todoId: idAlsoDone))
        update(&model, .clearCompletedTodos(paneId: paneId))
        try expectEqual(model.panes[paneId]!.todos.count, 1)
        try expectEqual(model.panes[paneId]!.todos[0].text, "pending")
    }

    // MARK: - requestClosePane

    test("requestClosePane with uncompleted todos on a non-last pane emits per-pane confirmation") {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = selectedTab(in: model)!.focusedPaneId
        // Split so the target pane is not the only pane in the tab; the
        // last-pane gate would otherwise route to close-tab confirmation.
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        update(&model, .addTodo(paneId: firstPaneId, text: "incomplete task"))
        let effects = update(&model, .requestClosePane(paneId: firstPaneId))
        try expect(hasEffect(effects) {
            if case .showClosePaneConfirmation(let pid, let count) = $0 {
                return pid == firstPaneId && count == 1
            }
            return false
        }, "expected showClosePaneConfirmation with count 1")
        // Pane should still exist
        try expect(model.panes[firstPaneId] != nil, "pane should not be removed")
    }

    test("requestClosePane with all todos completed proceeds to closePane") {
        var model = makeModel()
        createTab(&model)
        // Need a second tab so closing doesn't trigger quit confirmation
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        model.selectedTabId = tab.id
        update(&model, .addTodo(paneId: paneId, text: "task"))
        let todoId = model.panes[paneId]!.todos[0].id
        update(&model, .toggleTodoDone(paneId: paneId, todoId: todoId))
        let effects = update(&model, .requestClosePane(paneId: paneId))
        // Pane should be removed (closePane was invoked)
        try expect(model.panes[paneId] == nil, "pane should be removed")
        try expect(hasEffect(effects) {
            if case .destroySurface(let pid) = $0 { return pid == paneId }
            return false
        }, "expected destroySurface")
    }

    test("requestClosePane with no todos proceeds to closePane") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        model.selectedTabId = tab.id
        let effects = update(&model, .requestClosePane(paneId: paneId))
        try expect(model.panes[paneId] == nil, "pane should be removed")
        try expect(hasEffect(effects) {
            if case .destroySurface(let pid) = $0 { return pid == paneId }
            return false
        }, "expected destroySurface")
    }

    // MARK: - closePane + popover cleanup

    test("closePane clears todoPopover and emits dismissTodoPopover") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        // Split so closing one pane doesn't close the tab (which discards effects)
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        model.todoPopover = .pane(paneId)
        let effects = update(&model, .closePane(paneId: paneId))
        try expect(model.todoPopover == nil, "todoPopover should be nil")
        try expect(hasEffect(effects) {
            if case .dismissTodoPopover = $0 { return true }
            return false
        }, "expected dismissTodoPopover")
    }

    // MARK: - toggleTodoPopover

    test("toggleTodoPopover opens and closes correctly") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        // Open
        let openEffects = update(&model, .toggleTodoPopover(paneId: paneId))
        try expectEqual(model.todoPopover, .pane(paneId))
        try expect(hasEffect(openEffects) {
            if case .showTodoPopover(let pid) = $0 { return pid == paneId }
            return false
        }, "expected showTodoPopover")
        // Close
        let closeEffects = update(&model, .toggleTodoPopover(paneId: paneId))
        try expect(model.todoPopover == nil, "should be nil after close")
        try expect(hasEffect(closeEffects) {
            if case .dismissTodoPopover = $0 { return true }
            return false
        }, "expected dismissTodoPopover")
    }

    // MARK: - todoPopoverClosed race guard

    test("todoPopoverClosed for stale pane does not clobber active popover") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        // Split to get a second pane
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        let tab = selectedTab(in: model)!
        let paneB = tab.focusedPaneId
        // Popover is open for pane B
        model.todoPopover = .pane(paneB)
        // Stale close event arrives for pane A
        let paneA = paneId
        update(&model, .todoPopoverClosed(paneId: paneA))
        try expectEqual(model.todoPopover, .pane(paneB), "paneB popover should still be open")
    }

    // MARK: - splitPane starts empty

    test("splitPane starts child with empty todos") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "parent task"))
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        let tab = selectedTab(in: model)!
        // The new pane is the focused one after split
        let newPaneId = tab.focusedPaneId
        try expect(newPaneId != paneId, "new pane should have different ID")
        try expectEqual(model.panes[newPaneId]!.todos.count, 0, "new pane should have empty todos")
        // Parent still has its todo
        try expectEqual(model.panes[paneId]!.todos.count, 1)
    }

    // MARK: - classifyInputAction

    test("enter → submit") {
        try expectEqual(classifyInputAction(key: .enter, isEditing: false, fieldEmpty: true), .submit)
        try expectEqual(classifyInputAction(key: .enter, isEditing: true, fieldEmpty: false), .submit)
    }

    test("shiftEnter → insertNewline") {
        try expectEqual(classifyInputAction(key: .shiftEnter, isEditing: false, fieldEmpty: true), .insertNewline)
        try expectEqual(classifyInputAction(key: .shiftEnter, isEditing: true, fieldEmpty: false), .insertNewline)
    }

    test("escape while editing → cancelEdit") {
        try expectEqual(classifyInputAction(key: .escape, isEditing: true, fieldEmpty: false), .cancelEdit)
        try expectEqual(classifyInputAction(key: .escape, isEditing: true, fieldEmpty: true), .cancelEdit)
    }

    test("escape while not editing → dismiss") {
        try expectEqual(classifyInputAction(key: .escape, isEditing: false, fieldEmpty: true), .dismiss)
        try expectEqual(classifyInputAction(key: .escape, isEditing: false, fieldEmpty: false), .dismiss)
    }

    test("backspace on empty field in edit mode → cancelEdit") {
        try expectEqual(classifyInputAction(key: .backspace, isEditing: true, fieldEmpty: true), .cancelEdit)
    }

    test("backspace on non-empty field in edit mode → unhandled") {
        try expectEqual(classifyInputAction(key: .backspace, isEditing: true, fieldEmpty: false), .unhandled)
    }

    test("backspace when not editing → unhandled") {
        try expectEqual(classifyInputAction(key: .backspace, isEditing: false, fieldEmpty: true), .unhandled)
        try expectEqual(classifyInputAction(key: .backspace, isEditing: false, fieldEmpty: false), .unhandled)
    }

    test("tab → moveFocusForward") {
        try expectEqual(classifyInputAction(key: .tab, isEditing: false, fieldEmpty: true), .moveFocusForward)
        try expectEqual(classifyInputAction(key: .tab, isEditing: true, fieldEmpty: false), .moveFocusForward)
    }

    test("backtab → moveFocusBackward") {
        try expectEqual(classifyInputAction(key: .backtab, isEditing: false, fieldEmpty: true), .moveFocusBackward)
    }

    test("other → unhandled") {
        try expectEqual(classifyInputAction(key: .other, isEditing: false, fieldEmpty: false), .unhandled)
        try expectEqual(classifyInputAction(key: .other, isEditing: true, fieldEmpty: true), .unhandled)
    }
}
