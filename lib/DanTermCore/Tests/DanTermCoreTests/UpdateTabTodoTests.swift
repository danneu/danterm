// Swift Testing migration of the legacy `tests/UpdateTabTodoTests.swift`
// harness suite. Pins tab-owner behavior through the shared TODO Msg surface,
// plus the moveTodo paths (pane->tab,
// tab->pane, pane->pane, atIndex clamps in both directions, source ==
// destination no-op, unknown todo no-op, missing destination no-op,
// cross-tab no-op, successful moves), the popover scope
// transitions (owner-scoped toggleTodoPopover mutual
// exclusion, same-scope close, slot clearing on tab removal), and the close-tab
// + close-pane confirmation rollup against the tab/pane todo counts.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateTabTodoTests {
    static func makeTwoPaneTabForMoveTests() -> (model: AppModel, tabId: TabId, paneA: PaneId, paneB: PaneId) {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let paneA = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let paneOrder = allPaneIds(selectedTab(in: model)!.paneTree.root)
        return (model, tabId, paneOrder[0], paneOrder[1])
    }

    // MARK: - Tab-owner mutations

    @Test("addTodo for a tab owner leaves panes and other tabs untouched")
    func addTodoForTabOwnerLeavesOthersUntouched() {
        // Intent: addTodo appends to that tab's todos and leaves pane todos and
        //   sibling tabs untouched.
        // Why it exists: pins the bare append + persistence path.
        // Scenario: spec-first tab-owner add.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabA = model.groups[0].tabs[0]
        let tabB = model.groups[0].tabs[1]
        let paneA = tabA.paneTree.focusedPaneId

        update(&model, .addTodo(owner: .pane(paneA), text: "pane task"))
        update(&model, .addTodo(owner: .tab(tabA.id), text: "tab task"))

        let updatedTabA = tabById(tabA.id, in: model)!
        #expect(updatedTabA.todos.count == 1)
        #expect(updatedTabA.todos[0].text == "tab task")
        #expect(updatedTabA.todos[0].isDone == false)

        #expect(model.pane(paneA)!.todos.count == 1)
        #expect(model.pane(paneA)!.todos[0].text == "pane task")

        #expect(tabById(tabB.id, in: model)!.todos.count == 0)

    }

    @Test("addTodo for a tab owner trims whitespace and rejects empty")
    func addTodoForTabOwnerTrimsWhitespaceRejectsEmpty() {
        // Intent: addTodo trims whitespace and rejects empty /
        //   whitespace-only text.
        // Why it exists: pins the validation rules.
        // Scenario: spec-first trim + reject.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTodo(owner: .tab(tabId), text: "  hello  "))
        #expect(tabById(tabId, in: model)!.todos[0].text == "hello")
        update(&model, .addTodo(owner: .tab(tabId), text: ""))
        update(&model, .addTodo(owner: .tab(tabId), text: "   "))
        #expect(tabById(tabId, in: model)!.todos.count == 1)
    }

    @Test("toggleTodoDone for a tab owner flips only the matched item")
    func toggleTodoDoneForTabOwnerFlipsMatchedOnly() {
        // Intent: toggleTodoDone flips isDone on the matched item
        //   only.
        // Why it exists: pins per-item scope.
        // Scenario: spec-first toggle.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTodo(owner: .tab(tabId), text: "A"))
        update(&model, .addTodo(owner: .tab(tabId), text: "B"))
        let idA = tabById(tabId, in: model)!.todos[0].id
        update(&model, .toggleTodoDone(owner: .tab(tabId), todoId: idA))
        #expect(tabById(tabId, in: model)!.todos[0].isDone == true)
        #expect(tabById(tabId, in: model)!.todos[1].isDone == false)
    }

    @Test("setTodoDone for a tab owner sets the explicit value")
    func setTodoDoneForTabOwnerSetsExplicitValue() {
        // Intent: setTodoDone explicitly assigns isDone; same-value
        //   is a no-op.
        // Why it exists: pins the idempotence guard.
        // Scenario: spec-first set + no-op.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTodo(owner: .tab(tabId), text: "A"))
        let idA = tabById(tabId, in: model)!.todos[0].id
        update(&model, .setTodoDone(owner: .tab(tabId), todoId: idA, isDone: true))
        #expect(tabById(tabId, in: model)!.todos[0].isDone == true)
        let commands = update(&model, .setTodoDone(owner: .tab(tabId), todoId: idA, isDone: true))
        #expect(commands.isEmpty, "no-op when value unchanged")
    }

    @Test("editTodoText for a tab owner trims and replaces text; rejects empty")
    func editTodoTextForTabOwnerTrimsAndReplacesRejectsEmpty() {
        // Intent: editTodoText trims and replaces; whitespace-only
        //   is rejected.
        // Why it exists: pins the edit validation.
        // Scenario: spec-first edit + reject.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTodo(owner: .tab(tabId), text: "old"))
        let idA = tabById(tabId, in: model)!.todos[0].id
        update(&model, .editTodoText(owner: .tab(tabId), todoId: idA, text: "  new  "))
        #expect(tabById(tabId, in: model)!.todos[0].text == "new")
        update(&model, .editTodoText(owner: .tab(tabId), todoId: idA, text: "   "))
        #expect(tabById(tabId, in: model)!.todos[0].text == "new")
    }

    @Test("deleteTodo for a tab owner removes by id")
    func deleteTodoForTabOwnerRemovesById() {
        // Intent: deleteTodo removes the matching item.
        // Why it exists: pins the bare delete path.
        // Scenario: spec-first delete.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTodo(owner: .tab(tabId), text: "A"))
        update(&model, .addTodo(owner: .tab(tabId), text: "B"))
        let idA = tabById(tabId, in: model)!.todos[0].id
        update(&model, .deleteTodo(owner: .tab(tabId), todoId: idA))
        #expect(tabById(tabId, in: model)!.todos.count == 1)
        #expect(tabById(tabId, in: model)!.todos[0].text == "B")
    }

    @Test("reorderTodo for a tab owner moves the item and rejects out-of-bounds")
    func reorderTodoForTabOwnerMovesItemRejectsOutOfBounds() {
        // Intent: reorderTodo moves the item; out-of-bounds toIndex
        //   is a no-op.
        // Why it exists: pins the reorder math + clamp.
        // Scenario: spec-first reorder + OOB.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTodo(owner: .tab(tabId), text: "A"))
        update(&model, .addTodo(owner: .tab(tabId), text: "B"))
        update(&model, .addTodo(owner: .tab(tabId), text: "C"))
        let idC = tabById(tabId, in: model)!.todos[2].id
        update(&model, .reorderTodo(owner: .tab(tabId), todoId: idC, toIndex: 0))
        #expect(tabById(tabId, in: model)!.todos.map(\.text) == ["C", "A", "B"])

        let idA = tabById(tabId, in: model)!.todos[1].id
        let commands = update(&model, .reorderTodo(owner: .tab(tabId), todoId: idA, toIndex: 99))
        #expect(commands.isEmpty, "out of bounds is no-op")
    }

    // MARK: - moveTodo

    @Test("moveTodo pane -> tab inserts at index and removes from pane")
    func moveTodoPaneToTabInsertsAndRemoves() {
        // Intent: moveTodo from pane to tab inserts at the requested
        //   index and removes from the source pane.
        // Why it exists: pins the pane->tab move.
        // Scenario: spec-first pane->tab.
        var (model, tabId, paneA, _) = Self.makeTwoPaneTabForMoveTests()
        update(&model, .addTodo(owner: .tab(tabId), text: "tab A"))
        update(&model, .addTodo(owner: .tab(tabId), text: "tab B"))
        update(&model, .addTodo(owner: .pane(paneA), text: "pane task"))
        let todoId = model.pane(paneA)!.todos[0].id

        update(&model, .moveTodo(from: .pane(paneA), todoId: todoId, to: .tab(tabId), atIndex: 1))

        #expect(tabById(tabId, in: model)!.todos.map(\.text) == ["tab A", "pane task", "tab B"])
        #expect(model.pane(paneA)!.todos.count == 0)
    }

    @Test("moveTodo tab -> pane inserts at index and removes from tab")
    func moveTodoTabToPaneInsertsAndRemoves() {
        // Intent: moveTodo from tab to pane inserts at the requested
        //   index and removes from the source tab.
        // Why it exists: pins the symmetric tab->pane move.
        // Scenario: spec-first tab->pane.
        var (model, tabId, paneA, _) = Self.makeTwoPaneTabForMoveTests()
        update(&model, .addTodo(owner: .tab(tabId), text: "tab task"))
        update(&model, .addTodo(owner: .pane(paneA), text: "pane A"))
        update(&model, .addTodo(owner: .pane(paneA), text: "pane B"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(paneA), atIndex: 1))

        #expect(tabById(tabId, in: model)!.todos.count == 0)
        #expect(model.pane(paneA)!.todos.map(\.text) == ["pane A", "tab task", "pane B"])
    }

    @Test("moveTodo pane -> pane removes from source pane and inserts into dest pane")
    func moveTodoPaneToPaneRemovesAndInserts() {
        // Intent: moveTodo between panes within the same tab.
        // Why it exists: pins the pane->pane move.
        // Scenario: spec-first pane->pane.
        var (model, _, paneA, paneB) = Self.makeTwoPaneTabForMoveTests()
        update(&model, .addTodo(owner: .pane(paneA), text: "source"))
        update(&model, .addTodo(owner: .pane(paneB), text: "dest A"))
        let todoId = model.pane(paneA)!.todos[0].id

        update(&model, .moveTodo(from: .pane(paneA), todoId: todoId, to: .pane(paneB), atIndex: 0))

        #expect(model.pane(paneA)!.todos.count == 0)
        #expect(model.pane(paneB)!.todos.map(\.text) == ["source", "dest A"])
    }

    @Test("moveTodo with atIndex > destination.count clamps to count")
    func moveTodoAtIndexAboveCountClampsToCount() {
        // Intent: atIndex past the destination length clamps to
        //   append.
        // Why it exists: pins the high clamp.
        // Scenario: spec-first high clamp.
        var (model, tabId, paneA, _) = Self.makeTwoPaneTabForMoveTests()
        update(&model, .addTodo(owner: .tab(tabId), text: "tab task"))
        update(&model, .addTodo(owner: .pane(paneA), text: "pane A"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(paneA), atIndex: 99))

        #expect(model.pane(paneA)!.todos.map(\.text) == ["pane A", "tab task"])
    }

    @Test("moveTodo with atIndex < 0 clamps to 0")
    func moveTodoAtIndexNegativeClampsToZero() {
        // Intent: atIndex < 0 clamps to 0 (prepend).
        // Why it exists: pins the low clamp.
        // Scenario: spec-first low clamp.
        var (model, tabId, paneA, _) = Self.makeTwoPaneTabForMoveTests()
        update(&model, .addTodo(owner: .tab(tabId), text: "tab task"))
        update(&model, .addTodo(owner: .pane(paneA), text: "pane A"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(paneA), atIndex: -5))

        #expect(model.pane(paneA)!.todos.map(\.text) == ["tab task", "pane A"])
    }

    @Test("moveTodo where source == destination is a no-op")
    func moveTodoSameSourceDestinationIsNoOp() {
        // Intent: moveTodo where source == destination is a no-op.
        // Why it exists: pins the identity guard.
        // Scenario: spec-first identity guard.
        var (model, tabId, _, _) = Self.makeTwoPaneTabForMoveTests()
        update(&model, .addTodo(owner: .tab(tabId), text: "tab task"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        let commands = update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .tab(tabId), atIndex: 0))

        #expect(commands.isEmpty, "same bucket should not checkpoint")
        #expect(tabById(tabId, in: model)!.todos.map(\.text) == ["tab task"])
    }

    @Test("moveTodo with unknown todoId is a no-op")
    func moveTodoUnknownTodoIdIsNoOp() {
        // Intent: moveTodo with an unknown todoId is a no-op.
        // Why it exists: pins fail-closed for stale todo ids.
        // Scenario: spec-first stale todo.
        var (model, tabId, paneA, _) = Self.makeTwoPaneTabForMoveTests()
        update(&model, .addTodo(owner: .tab(tabId), text: "tab task"))

        let commands = update(&model, .moveTodo(from: .tab(tabId), todoId: TodoId(), to: .pane(paneA), atIndex: 0))

        #expect(commands.isEmpty, "unknown todo should not checkpoint")
        #expect(tabById(tabId, in: model)!.todos.map(\.text) == ["tab task"])
        #expect(model.pane(paneA)!.todos.count == 0)
    }

    @Test("moveTodo with missing destination pane is a no-op and leaves source intact")
    func moveTodoMissingDestinationPaneIsNoOp() {
        // Intent: moveTodo to a missing destination pane is a no-op;
        //   source is intact.
        // Why it exists: pins fail-closed for stale destination panes.
        // Scenario: spec-first stale destination.
        var (model, tabId, _, _) = Self.makeTwoPaneTabForMoveTests()
        update(&model, .addTodo(owner: .tab(tabId), text: "tab task"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        let commands = update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(PaneId()), atIndex: 0))

        #expect(commands.isEmpty, "missing destination should not checkpoint")
        #expect(tabById(tabId, in: model)!.todos.map(\.text) == ["tab task"])
    }

    @Test("moveTodo across different tabs is a no-op and leaves source intact")
    func moveTodoAcrossDifferentTabsIsNoOp() {
        // Intent: moveTodo across different tabs is a no-op.
        // Why it exists: pins the same-tab scope rule.
        // Scenario: spec-first cross-tab no-op.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabA = model.groups[0].tabs[0]
        let tabB = model.groups[0].tabs[1]
        update(&model, .addTodo(owner: .tab(tabA.id), text: "tab A task"))
        let todoId = tabById(tabA.id, in: model)!.todos[0].id

        let commands = update(&model, .moveTodo(from: .tab(tabA.id), todoId: todoId, to: .tab(tabB.id), atIndex: 0))

        #expect(commands.isEmpty, "cross-tab move should not checkpoint")
        #expect(tabById(tabA.id, in: model)!.todos.map(\.text) == ["tab A task"])
        #expect(tabById(tabB.id, in: model)!.todos.count == 0)
    }

    @Test("moveTodo succeeds across todo owners")
    func moveTodoSucceedsAcrossTodoOwners() {
        // Intent: a successful moveTodo transfers the item to its destination.
        // Why it exists: pins the cross-owner mutation path.
        // Scenario: spec-first tab-to-pane move.
        var (model, tabId, paneA, _) = Self.makeTwoPaneTabForMoveTests()
        update(&model, .addTodo(owner: .tab(tabId), text: "tab task"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(paneA), atIndex: 0))

        #expect(tabById(tabId, in: model)!.todos.isEmpty)
        #expect(model.pane(paneA)!.todos.map(\.text) == ["tab task"])
    }

    @Test("clearCompletedTodos for a tab owner removes only done items")
    func clearCompletedTodosForTabOwnerRemovesOnlyDone() {
        // Intent: clearCompletedTodos removes only done items.
        // Why it exists: pins the clear-completed scope.
        // Scenario: spec-first clear completed.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTodo(owner: .tab(tabId), text: "done"))
        update(&model, .addTodo(owner: .tab(tabId), text: "pending"))
        let idDone = tabById(tabId, in: model)!.todos[0].id
        update(&model, .toggleTodoDone(owner: .tab(tabId), todoId: idDone))
        update(&model, .clearCompletedTodos(owner: .tab(tabId)))
        #expect(tabById(tabId, in: model)!.todos.count == 1)
        #expect(tabById(tabId, in: model)!.todos[0].text == "pending")
    }

    // MARK: - popover scope transitions

    @Test("toggleTodoPopover for a tab owner swaps from an open pane popover")
    func toggleTodoPopoverForTabOwnerWhilePaneOpenSwapsToTab() {
        // Intent: opening the tab popover while the pane popover is
        //   open swaps scope; dismiss + show commands are emitted.
        // Why it exists: pins mutual-exclusion between pane and tab
        //   popovers.
        // Scenario: spec-first pane -> tab swap.
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        let paneId = tab.paneTree.focusedPaneId
        update(&model, .toggleTodoPopover(owner: .pane(paneId)))
        #expect(model.todoPopover == .pane(paneId))

        let commands = update(&model, .toggleTodoPopover(owner: .tab(tab.id)))
        #expect(model.todoPopover == .tab(tab.id))
        #expect(commands.isEmpty)
    }

    @Test("toggleTodoPopover for the open tab owner closes the popover")
    func toggleTodoPopoverForOpenTabOwnerClosesPopover() {
        // Intent: re-toggling the tab popover on the same tab closes
        //   it.
        // Why it exists: pins the same-scope close rule.
        // Scenario: spec-first same-tab close.
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        update(&model, .toggleTodoPopover(owner: .tab(tab.id)))
        #expect(model.todoPopover == .tab(tab.id))

        let commands = update(&model, .toggleTodoPopover(owner: .tab(tab.id)))
        #expect(model.todoPopover == nil, "should clear scope")
        #expect(commands.isEmpty)
    }

    @Test("toggleTodoPopover while tab popover is open swaps to pane")
    func toggleTodoPopoverWhileTabPopoverOpenSwapsToPane() {
        // Intent: opening the pane popover while the tab popover is
        //   open swaps scope.
        // Why it exists: pins the symmetric mutual-exclusion.
        // Scenario: spec-first tab -> pane swap.
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        let paneId = tab.paneTree.focusedPaneId
        update(&model, .toggleTodoPopover(owner: .tab(tab.id)))
        #expect(model.todoPopover == .tab(tab.id))

        let commands = update(&model, .toggleTodoPopover(owner: .pane(paneId)))
        #expect(model.todoPopover == .pane(paneId))
        #expect(commands.isEmpty)
    }

    @Test("toggleTodoPopover while same pane is open closes the popover")
    func toggleTodoPopoverWhileSamePaneClosesPopover() {
        // Intent: re-toggling the pane popover on the same pane closes
        //   it.
        // Why it exists: pins the same-scope close rule (pane).
        // Scenario: spec-first same-pane close.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .toggleTodoPopover(owner: .pane(paneId)))
        let commands = update(&model, .toggleTodoPopover(owner: .pane(paneId)))
        #expect(model.todoPopover == nil)
        #expect(commands.isEmpty)
    }

    @Test("removing the active tab clears its tab popover without a presentation command")
    func removingActiveTabWhilePopoverOpenClearsSlot() {
        // Intent: closing the tab whose tab popover is open clears
        //   scope without issuing presentation work.
        // Why it exists: pins the auto-dismiss rule on tab removal.
        // Scenario: spec-first tab close auto-dismiss.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: tabAId))
        update(&model, .toggleTodoPopover(owner: .tab(tabAId)))
        #expect(model.todoPopover == .tab(tabAId))

        let commands = update(&model, .closeTab(id: tabAId))
        #expect(model.todoPopover == nil, "scope should be cleared")
        #expect(commands.isEmpty)
    }

    // MARK: - close-tab confirmation rollup

    @Test("requestCloseTab on single-pane tab with no todos closes directly")
    func requestCloseTabSinglePaneNoTodosCloses() {
        // Intent: closing a single-pane tab with no todos has no
        //   confirmation.
        // Why it exists: pins the no-confirm fast path.
        // Scenario: spec-first direct close.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        _ = update(&model, .requestCloseTab(id: firstTabId))
        #expect(model.pendingConfirmation == nil, "no confirmation for empty tab")
        #expect(model.groups[0].tabs.count == 1, "tab should be removed")
    }

    @Test("requestCloseTab on single-pane tab with uncompleted tab todos shows confirmation")
    func requestCloseTabSinglePaneTabTodosShowsConfirmation() {
        // Intent: a single-pane tab with uncompleted tab todos
        //   surfaces the unified tab confirmation with one unfinished task.
        // Why it exists: pins the confirmation rollup for tab-level
        //   todos.
        // Scenario: spec-first tab todo confirm.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .addTodo(owner: .tab(firstTabId), text: "pending"))

        _ = update(&model, .requestCloseTab(id: firstTabId))
        #expect(testConfirmationKind(model.pendingConfirmation) == .tab(firstTabId))
        #expect(desiredConfirmation(in: model)?.informativeText ==
            "This tab has 1 unfinished task.")
        #expect(model.groups[0].tabs.count == 2, "tab not yet removed")
    }

    @Test("requestCloseTab on single-pane tab with uncompleted pane todos only shows confirmation")
    func requestCloseTabSinglePanePaneTodosShowsConfirmation() {
        // Intent: pane todos also trigger close confirmation.
        // Why it exists: pins the pane-todo rollup into the close-tab
        //   confirmation.
        // Scenario: spec-first pane todo confirm.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTab = model.groups[0].tabs[0]
        update(&model, .addTodo(owner: .pane(firstTab.paneTree.focusedPaneId), text: "pane task"))

        _ = update(&model, .requestCloseTab(id: firstTab.id))
        #expect(pendingCloseImpact(model.pendingConfirmation)?.uncompletedTodoCount == 1,
            "expected confirmation with rollup pane todos")
    }

    @Test("requestCloseTab on multi-pane tab with mixed todos rolls up the count")
    func requestCloseTabMultiPaneMixedTodosRollsUp() {
        // Intent: a multi-pane tab with mixed tab + pane + completed
        //   todos rolls up to the correct paneCount and uncompleted
        //   count.
        // Why it exists: pins the rollup math.
        // Scenario: spec-first mixed rollup.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        let paneA = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let paneB = selectedTab(in: model)!.paneTree.focusedPaneId

        update(&model, .addTodo(owner: .tab(firstTabId), text: "tab one"))
        update(&model, .addTodo(owner: .tab(firstTabId), text: "tab two"))
        update(&model, .addTodo(owner: .pane(paneA), text: "pane A 1"))
        update(&model, .addTodo(owner: .pane(paneB), text: "pane B 1"))
        update(&model, .addTodo(owner: .pane(paneB), text: "pane B 2 done"))
        let lastB = model.pane(paneB)!.todos.last!.id
        update(&model, .toggleTodoDone(owner: .pane(paneB), todoId: lastB))

        _ = update(&model, .requestCloseTab(id: firstTabId))
        #expect(testConfirmationKind(model.pendingConfirmation) == .tab(firstTabId))
        #expect(pendingCloseImpact(model.pendingConfirmation)?.panes.count == 2)
        #expect(pendingCloseImpact(model.pendingConfirmation)?.uncompletedTodoCount == 4)
    }

    @Test("confirming a tab with todos clears pending and closes")
    func confirmTabWithTodosClearsPendingAndCloses() {
        // Intent: unified confirmation clears pendingConfirmation and
        //   removes the tab.
        // Why it exists: pins the confirm path with todos.
        // Scenario: spec-first confirm + remove.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .addTodo(owner: .tab(firstTabId), text: "pending"))
        update(&model, .requestCloseTab(id: firstTabId))
        #expect(testConfirmationKind(model.pendingConfirmation) == .tab(firstTabId))

        confirmPending(&model)
        #expect(model.pendingConfirmation == nil, "pending should clear")
        #expect(model.groups[0].tabs.count == 1, "tab should be removed")
    }

    // MARK: - requestClosePane rollup gating

    @Test("requestClosePane on last pane with uncompleted tab todos routes through close-tab confirmation")
    func requestClosePaneLastPaneTabTodosRoutesToCloseTabConfirm() {
        // Intent: a last-pane close with tab todos surfaces the
        //   close-tab confirmation (not pane).
        // Why it exists: pins the close-tab routing precedence.
        // Scenario: spec-first last-pane -> close-tab.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTab = model.groups[0].tabs[0]
        update(&model, .addTodo(owner: .tab(firstTab.id), text: "tab task"))

        _ = update(&model, .requestClosePane(paneId: firstTab.paneTree.focusedPaneId))
        #expect(testConfirmationKind(model.pendingConfirmation) == .tab(firstTab.id),
            "expected close-tab confirmation")
        #expect(pendingCloseImpact(model.pendingConfirmation)?.uncompletedTodoCount == 1)
        #expect(model.pane(firstTab.paneTree.focusedPaneId) != nil, "pane not yet removed")
    }

    @Test("requestClosePane on non-last pane with no pane todos but tab todos closes silently")
    func requestClosePaneNonLastNoPaneTodosTabTodosClosesSilently() {
        // Intent: a non-last pane close with tab todos but no pane
        //   todos closes silently (no confirmation).
        // Why it exists: pins the no-confirm rule for non-last panes.
        // Scenario: spec-first silent close.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTab = model.groups[0].tabs[0]
        update(&model, .selectTab(id: firstTab.id))
        let paneA = firstTab.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let paneB = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .tab(firstTab.id), text: "tab task"))

        _ = update(&model, .requestClosePane(paneId: paneB))
        #expect(model.pendingConfirmation == nil,
            "no confirmation: the closed pane has no todos")
        #expect(model.pane(paneB) == nil, "pane should be removed")
    }

    @Test("requestClosePane on last pane with tab + pane uncompleted todos prefers close-tab confirmation")
    func requestClosePaneLastPaneBothTodosPrefersCloseTab() {
        // Intent: last-pane close with both tab + pane todos rolls
        //   into a single close-tab confirmation.
        // Why it exists: pins the rollup precedence.
        // Scenario: spec-first both rollup.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTab = model.groups[0].tabs[0]
        let paneA = firstTab.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .tab(firstTab.id), text: "tab task"))
        update(&model, .addTodo(owner: .pane(paneA), text: "pane task"))

        _ = update(&model, .requestClosePane(paneId: paneA))
        #expect(testConfirmationKind(model.pendingConfirmation) == .tab(firstTab.id))
        #expect(pendingCloseImpact(model.pendingConfirmation)?.uncompletedTodoCount == 2,
            "expected close-tab rollup of 2")
    }

    @Test("requestClosePane on last pane with only pane todos still routes through close-tab confirmation")
    func requestClosePaneLastPaneOnlyPaneTodosRoutesToCloseTab() {
        // Intent: pane-only todos on a last pane still route through
        //   the close-tab confirmation (no separate pane confirmation).
        // Why it exists: pins the single-confirmation rule.
        // Scenario: spec-first pane-only -> close-tab.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTab = model.groups[0].tabs[0]
        let paneA = firstTab.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneA), text: "pane only"))

        _ = update(&model, .requestClosePane(paneId: paneA))
        #expect(testConfirmationKind(model.pendingConfirmation) == .tab(firstTab.id))
        #expect(pendingCloseImpact(model.pendingConfirmation)?.uncompletedTodoCount == 1,
            "expected close-tab confirmation with rollup 1")
    }
}
