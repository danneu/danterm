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
        let commands = update(&model, .addTodo(paneId: paneId, text: "run tests"))
        try expectEqual(model.pane(paneId)!.todos.count, 1)
        try expectEqual(model.pane(paneId)!.todos[0].text, "run tests")
        try expectEqual(model.pane(paneId)!.todos[0].isDone, false)
        try expect(hasEffect(commands) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "expected scheduleCheckpoint")
    }

    test("addTodo trims whitespace") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "  hello  "))
        try expectEqual(model.pane(paneId)!.todos[0].text, "hello")
    }

    test("addTodo rejects empty and whitespace-only text") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: ""))
        update(&model, .addTodo(paneId: paneId, text: "   "))
        try expectEqual(model.pane(paneId)!.todos.count, 0)
    }

    // MARK: - toggleTodoDone

    test("toggleTodoDone flips isDone") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "task"))
        let todoId = model.pane(paneId)!.todos[0].id
        let commands = update(&model, .toggleTodoDone(paneId: paneId, todoId: todoId))
        try expectEqual(model.pane(paneId)!.todos[0].isDone, true)
        try expect(hasEffect(commands) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "expected scheduleCheckpoint")
        // Toggle back
        update(&model, .toggleTodoDone(paneId: paneId, todoId: todoId))
        try expectEqual(model.pane(paneId)!.todos[0].isDone, false)
    }

    // MARK: - editTodoText

    test("editTodoText updates text") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "old"))
        let todoId = model.pane(paneId)!.todos[0].id
        update(&model, .editTodoText(paneId: paneId, todoId: todoId, text: "new"))
        try expectEqual(model.pane(paneId)!.todos[0].text, "new")
    }

    test("editTodoText rejects empty text") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "keep"))
        let todoId = model.pane(paneId)!.todos[0].id
        update(&model, .editTodoText(paneId: paneId, todoId: todoId, text: ""))
        try expectEqual(model.pane(paneId)!.todos[0].text, "keep")
        update(&model, .editTodoText(paneId: paneId, todoId: todoId, text: "   "))
        try expectEqual(model.pane(paneId)!.todos[0].text, "keep")
    }

    // MARK: - deleteTodo

    test("deleteTodo removes the correct item") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "A"))
        update(&model, .addTodo(paneId: paneId, text: "B"))
        let idA = model.pane(paneId)!.todos[0].id
        update(&model, .deleteTodo(paneId: paneId, todoId: idA))
        try expectEqual(model.pane(paneId)!.todos.count, 1)
        try expectEqual(model.pane(paneId)!.todos[0].text, "B")
    }

    // MARK: - reorderTodo

    test("reorderTodo moves item to correct position") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "A"))
        update(&model, .addTodo(paneId: paneId, text: "B"))
        update(&model, .addTodo(paneId: paneId, text: "C"))
        let idC = model.pane(paneId)!.todos[2].id
        // Move C to position 0
        update(&model, .reorderTodo(paneId: paneId, todoId: idC, toIndex: 0))
        try expectEqual(model.pane(paneId)!.todos.map(\.text), ["C", "A", "B"])
    }

    test("reorderTodo no-ops on same position") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "A"))
        update(&model, .addTodo(paneId: paneId, text: "B"))
        let idA = model.pane(paneId)!.todos[0].id
        let commands = update(&model, .reorderTodo(paneId: paneId, todoId: idA, toIndex: 0))
        try expectEqual(model.pane(paneId)!.todos.map(\.text), ["A", "B"])
        try expect(!hasEffect(commands) {
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
        let idA = model.pane(paneId)!.todos[0].id
        // toIndex beyond count is rejected by guard
        let commands = update(&model, .reorderTodo(paneId: paneId, todoId: idA, toIndex: 99))
        // Should be no-op since 99 > count
        try expect(commands.isEmpty, "out of bounds should be no-op")
    }

    // MARK: - clearCompletedTodos

    test("clearCompletedTodos removes only done items") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTodo(paneId: paneId, text: "done"))
        update(&model, .addTodo(paneId: paneId, text: "pending"))
        update(&model, .addTodo(paneId: paneId, text: "also done"))
        let idDone = model.pane(paneId)!.todos[0].id
        let idAlsoDone = model.pane(paneId)!.todos[2].id
        update(&model, .toggleTodoDone(paneId: paneId, todoId: idDone))
        update(&model, .toggleTodoDone(paneId: paneId, todoId: idAlsoDone))
        update(&model, .clearCompletedTodos(paneId: paneId))
        try expectEqual(model.pane(paneId)!.todos.count, 1)
        try expectEqual(model.pane(paneId)!.todos[0].text, "pending")
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
        let commands = update(&model, .requestClosePane(paneId: firstPaneId))
        try expect(hasEffect(commands) {
            if case .showClosePaneConfirmation(let pid, let count) = $0 {
                return pid == firstPaneId && count == 1
            }
            return false
        }, "expected showClosePaneConfirmation with count 1")
        // Pane should still exist
        try expect(model.pane(firstPaneId) != nil, "pane should not be removed")
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
        let todoId = model.pane(paneId)!.todos[0].id
        update(&model, .toggleTodoDone(paneId: paneId, todoId: todoId))
        let liveBefore = Set(model.allPaneIds)
        update(&model, .requestClosePane(paneId: paneId))
        // Pane should be removed (closePane was invoked)
        try expect(model.pane(paneId) == nil, "pane should be removed")
        // Surface teardown is reconcileSurfaceExistence's: the closed pane is selected once gone.
        try expectEqual(surfacesToTearDown(liveSurfaceIds: liveBefore, model: model), Set([paneId]),
            "closed pane's surface is torn down")
    }

    test("requestClosePane with no todos proceeds to closePane") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.focusedPaneId
        model.selectedTabId = tab.id
        let liveBefore = Set(model.allPaneIds)
        update(&model, .requestClosePane(paneId: paneId))
        try expect(model.pane(paneId) == nil, "pane should be removed")
        try expectEqual(surfacesToTearDown(liveSurfaceIds: liveBefore, model: model), Set([paneId]),
            "closed pane's surface is torn down")
    }

    // MARK: - closePane + popover cleanup

    test("closePane clears todoPopover and emits dismissTodoPopover") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        // Split so closing one pane doesn't close the tab (which discards commands)
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        model.todoPopover = .pane(paneId)
        let commands = update(&model, .closePane(paneId: paneId))
        try expect(model.todoPopover == nil, "todoPopover should be nil")
        try expect(hasEffect(commands) {
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
        try expectEqual(model.pane(newPaneId)!.todos.count, 0, "new pane should have empty todos")
        // Parent still has its todo
        try expectEqual(model.pane(paneId)!.todos.count, 1)
    }

    // MARK: - classifyInputAction

    test("enter submits") {
        try expectEqual(classifyInputAction(key: .enter, isEditing: false, fieldEmpty: true), .submit)
        try expectEqual(classifyInputAction(key: .enter, isEditing: true, fieldEmpty: false), .submit)
    }

    test("shiftEnter inserts newline") {
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

    test("tab while not editing → moveFocusForward") {
        try expectEqual(classifyInputAction(key: .tab, isEditing: false, fieldEmpty: true), .moveFocusForward)
    }

    test("tab while editing → moveFocusForward") {
        try expectEqual(classifyInputAction(key: .tab, isEditing: true, fieldEmpty: false), .moveFocusForward)
    }

    test("backtab while editing → moveFocusBackward") {
        try expectEqual(classifyInputAction(key: .backtab, isEditing: true, fieldEmpty: false), .moveFocusBackward)
    }

    test("backtab while not editing → moveFocusBackward") {
        try expectEqual(classifyInputAction(key: .backtab, isEditing: false, fieldEmpty: true), .moveFocusBackward)
    }

    test("other → unhandled") {
        try expectEqual(classifyInputAction(key: .other, isEditing: false, fieldEmpty: false), .unhandled)
        try expectEqual(classifyInputAction(key: .other, isEditing: true, fieldEmpty: true), .unhandled)
    }

    // MARK: - classifyListAction

    test("list navigation keys move selection") {
        try expectEqual(classifyListAction(key: .j, modifiers: KeyModifiers()), .moveSelection(delta: 1))
        try expectEqual(classifyListAction(key: .downArrow, modifiers: KeyModifiers()), .moveSelection(delta: 1))
        try expectEqual(classifyListAction(key: .k, modifiers: KeyModifiers()), .moveSelection(delta: -1))
        try expectEqual(classifyListAction(key: .upArrow, modifiers: KeyModifiers()), .moveSelection(delta: -1))
    }

    test("list tab focuses input and enter enters edit") {
        try expectEqual(classifyListAction(key: .tab, modifiers: KeyModifiers()), .focusInput)
        try expectEqual(classifyListAction(key: .enter, modifiers: KeyModifiers()), .enterEdit)
    }

    test("list space toggles done") {
        try expectEqual(classifyListAction(key: .space, modifiers: KeyModifiers()), .toggleDone)
    }

    test("list cmd backspace deletes row") {
        try expectEqual(classifyListAction(key: .backspace, modifiers: [.command]), .deleteRow)
        try expectEqual(classifyListAction(key: .backspace, modifiers: KeyModifiers()), .unhandled)
    }

    test("list shift j and shift k reorder") {
        try expectEqual(classifyListAction(key: .j, modifiers: [.shift]), .reorder(delta: 1))
        try expectEqual(classifyListAction(key: .k, modifiers: [.shift]), .reorder(delta: -1))
    }

    test("list shift h moves bucket left") {
        try expectEqual(classifyListAction(key: .h, modifiers: [.shift]), .moveBucket(delta: -1))
    }

    test("list shift l moves bucket right") {
        try expectEqual(classifyListAction(key: .l, modifiers: [.shift]), .moveBucket(delta: 1))
    }

    test("list cmd shift h is unhandled") {
        try expectEqual(classifyListAction(key: .h, modifiers: [.command, .shift]), .unhandled)
    }

    test("list cmd shift l is unhandled") {
        try expectEqual(classifyListAction(key: .l, modifiers: [.command, .shift]), .unhandled)
    }

    test("list cmd slash shows shortcut help") {
        try expectEqual(classifyListAction(key: .slash, modifiers: [.command]), .showShortcutHelp)
        try expectEqual(classifyListAction(key: .slash, modifiers: [.command, .shift]), .showShortcutHelp)
    }

    test("list slash without command is unhandled") {
        try expectEqual(classifyListAction(key: .slash, modifiers: KeyModifiers()), .unhandled)
        try expectEqual(classifyListAction(key: .slash, modifiers: [.shift]), .unhandled)
    }

    test("list plain h is unhandled") {
        try expectEqual(classifyListAction(key: .h, modifiers: KeyModifiers()), .unhandled)
    }

    test("list cmd n focuses input") {
        try expectEqual(classifyListAction(key: .n, modifiers: [.command]), .focusInput)
    }

    test("list shift tab focuses input") {
        try expectEqual(classifyListAction(key: .backtab, modifiers: [.shift]), .focusInput)
        try expectEqual(classifyListAction(key: .tab, modifiers: [.shift]), .focusInput)
    }

    test("list unmodified text keys are unhandled") {
        try expectEqual(classifyListAction(key: .n, modifiers: KeyModifiers()), .unhandled)
        try expectEqual(classifyListAction(key: .other, modifiers: KeyModifiers()), .unhandled)
    }

    // MARK: - selectable row helpers

    test("firstSelectableRow finds the first selectable row") {
        try expectEqual(firstSelectableRow(in: [Int](), canSelect: { _ in true }), nil)
        try expectEqual(firstSelectableRow(in: [false, false], canSelect: { $0 }), nil)
        try expectEqual(firstSelectableRow(in: [false, true, true], canSelect: { $0 }), 1)
        try expectEqual(firstSelectableRow(in: [true, true], canSelect: { $0 }), 0)
    }

    test("nextSelectableRow skips unselectable rows without wrapping") {
        let rows = [true, false, true, false, true]
        try expectEqual(nextSelectableRow(in: rows, from: 0, delta: 1, canSelect: { $0 }), 2)
        try expectEqual(nextSelectableRow(in: rows, from: 2, delta: 1, canSelect: { $0 }), 4)
        try expectEqual(nextSelectableRow(in: rows, from: 4, delta: 1, canSelect: { $0 }), nil)
        try expectEqual(nextSelectableRow(in: rows, from: 4, delta: -1, canSelect: { $0 }), 2)
        try expectEqual(nextSelectableRow(in: rows, from: 2, delta: -1, canSelect: { $0 }), 0)
        try expectEqual(nextSelectableRow(in: rows, from: 0, delta: -1, canSelect: { $0 }), nil)
    }

    test("nextSelectableRow crosses sections while skipping headers") {
        let rows = [false, true, false, true]
        try expectEqual(nextSelectableRow(in: rows, from: 1, delta: 1, canSelect: { $0 }), 3)
        try expectEqual(nextSelectableRow(in: rows, from: 3, delta: -1, canSelect: { $0 }), 1)
    }

    // MARK: - sectionLocalIndex

    struct SectionRow {
        let isHeader: Bool
        let section: String?
    }

    test("sectionLocalIndex returns nil for headers") {
        let rows = [SectionRow(isHeader: true, section: "tab"), SectionRow(isHeader: false, section: "tab")]
        try expectEqual(sectionLocalIndex(rows: rows, at: 0, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }), nil)
    }

    test("sectionLocalIndex returns section-relative positions") {
        let rows = [
            SectionRow(isHeader: true, section: "tab"),
            SectionRow(isHeader: false, section: "tab"),
            SectionRow(isHeader: false, section: "tab"),
            SectionRow(isHeader: true, section: "pane-a"),
            SectionRow(isHeader: false, section: "pane-a"),
            SectionRow(isHeader: false, section: "pane-a"),
            SectionRow(isHeader: true, section: "pane-b"),
            SectionRow(isHeader: false, section: "pane-b"),
        ]
        try expectEqual(sectionLocalIndex(rows: rows, at: 1, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }), 0)
        try expectEqual(sectionLocalIndex(rows: rows, at: 2, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }), 1)
        try expectEqual(sectionLocalIndex(rows: rows, at: 4, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }), 0)
        try expectEqual(sectionLocalIndex(rows: rows, at: 5, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }), 1)
        try expectEqual(sectionLocalIndex(rows: rows, at: 7, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }), 0)
    }

    test("sectionLocalIndex handles a single flat section") {
        let rows = [
            SectionRow(isHeader: false, section: nil),
            SectionRow(isHeader: false, section: nil),
            SectionRow(isHeader: false, section: nil),
        ]
        try expectEqual(sectionLocalIndex(rows: rows, at: 0, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }), 0)
        try expectEqual(sectionLocalIndex(rows: rows, at: 2, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }), 2)
    }

    test("sectionLocalIndex supports clamped reorder destinations") {
        let rows = [
            SectionRow(isHeader: true, section: "pane"),
            SectionRow(isHeader: false, section: "pane"),
            SectionRow(isHeader: false, section: "pane"),
            SectionRow(isHeader: false, section: "pane"),
            SectionRow(isHeader: true, section: "next"),
            SectionRow(isHeader: false, section: "next"),
        ]
        let clampedDestinationRow = 3
        try expectEqual(sectionLocalIndex(rows: rows, at: clampedDestinationRow, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }), 2)
    }
}
