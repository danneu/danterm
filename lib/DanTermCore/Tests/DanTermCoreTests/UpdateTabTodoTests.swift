// Swift Testing migration of the legacy `tests/UpdateTabTodoTests.swift`
// harness suite. Pins the tab-level TODO Msg surface: addTabTodo /
// toggleTabTodoDone / setTabTodoDone / editTabTodoText / deleteTabTodo /
// reorderTabTodo / clearCompletedTabTodos, the moveTodo paths (pane->tab,
// tab->pane, pane->pane, atIndex clamps in both directions, source ==
// destination no-op, unknown todo no-op, missing destination no-op,
// cross-tab no-op, successful moves), the popover scope
// transitions (toggleTodoPopoverForTab + toggleTodoPopover mutual
// exclusion, same-scope close, dismiss on tab removal), and the close-tab
// + close-pane confirmation rollup against the tab/pane todo counts.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateTabTodoTests {
    static func makeTwoPaneTabForMoveTests() -> (model: AppModel, tabId: TabId, paneA: PaneId, paneB: PaneId) {
        var model = makeModel()
        createTab(&model)
        let tabId = selectedTab(in: model)!.id
        let paneA = selectedTab(in: model)!.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let paneOrder = allPaneIds(selectedTab(in: model)!.rootNode)
        return (model, tabId, paneOrder[0], paneOrder[1])
    }

    // MARK: - addTabTodo

    @Test("addTabTodo appends to the tab and leaves panes/other tabs untouched")
    func addTabTodoAppendsAndLeavesOthersUntouched() {
        // Intent: addTabTodo appends to that tab's todos and leaves pane todos and
        //   sibling tabs untouched.
        // Why it exists: pins the bare append + persistence path.
        // Scenario: spec-first addTabTodo.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabA = model.groups[0].tabs[0]
        let tabB = model.groups[0].tabs[1]
        let paneA = tabA.focusedPaneId

        update(&model, .addTodo(paneId: paneA, text: "pane task"))
        update(&model, .addTabTodo(tabId: tabA.id, text: "tab task"))

        let updatedTabA = tabById(tabA.id, in: model)!
        #expect(updatedTabA.todos.count == 1)
        #expect(updatedTabA.todos[0].text == "tab task")
        #expect(updatedTabA.todos[0].isDone == false)

        #expect(model.pane(paneA)!.todos.count == 1)
        #expect(model.pane(paneA)!.todos[0].text == "pane task")

        #expect(tabById(tabB.id, in: model)!.todos.count == 0)

    }

    @Test("addTabTodo trims whitespace and rejects empty")
    func addTabTodoTrimsWhitespaceRejectsEmpty() {
        // Intent: addTabTodo trims whitespace and rejects empty /
        //   whitespace-only text.
        // Why it exists: pins the validation rules.
        // Scenario: spec-first trim + reject.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "  hello  "))
        #expect(tabById(tabId, in: model)!.todos[0].text == "hello")
        update(&model, .addTabTodo(tabId: tabId, text: ""))
        update(&model, .addTabTodo(tabId: tabId, text: "   "))
        #expect(tabById(tabId, in: model)!.todos.count == 1)
    }

    // MARK: - toggleTabTodoDone

    @Test("toggleTabTodoDone flips only the matched item")
    func toggleTabTodoDoneFlipsMatchedOnly() {
        // Intent: toggleTabTodoDone flips isDone on the matched item
        //   only.
        // Why it exists: pins per-item scope.
        // Scenario: spec-first toggle.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "A"))
        update(&model, .addTabTodo(tabId: tabId, text: "B"))
        let idA = tabById(tabId, in: model)!.todos[0].id
        update(&model, .toggleTabTodoDone(tabId: tabId, todoId: idA))
        #expect(tabById(tabId, in: model)!.todos[0].isDone == true)
        #expect(tabById(tabId, in: model)!.todos[1].isDone == false)
    }

    @Test("setTabTodoDone sets explicit value")
    func setTabTodoDoneSetsExplicitValue() {
        // Intent: setTabTodoDone explicitly assigns isDone; same-value
        //   is a no-op.
        // Why it exists: pins the idempotence guard.
        // Scenario: spec-first set + no-op.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "A"))
        let idA = tabById(tabId, in: model)!.todos[0].id
        update(&model, .setTabTodoDone(tabId: tabId, todoId: idA, isDone: true))
        #expect(tabById(tabId, in: model)!.todos[0].isDone == true)
        let commands = update(&model, .setTabTodoDone(tabId: tabId, todoId: idA, isDone: true))
        #expect(commands.isEmpty, "no-op when value unchanged")
    }

    // MARK: - editTabTodoText

    @Test("editTabTodoText trims and replaces text; rejects empty")
    func editTabTodoTextTrimsAndReplacesRejectsEmpty() {
        // Intent: editTabTodoText trims and replaces; whitespace-only
        //   is rejected.
        // Why it exists: pins the edit validation.
        // Scenario: spec-first edit + reject.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "old"))
        let idA = tabById(tabId, in: model)!.todos[0].id
        update(&model, .editTabTodoText(tabId: tabId, todoId: idA, text: "  new  "))
        #expect(tabById(tabId, in: model)!.todos[0].text == "new")
        update(&model, .editTabTodoText(tabId: tabId, todoId: idA, text: "   "))
        #expect(tabById(tabId, in: model)!.todos[0].text == "new")
    }

    // MARK: - deleteTabTodo

    @Test("deleteTabTodo removes by id")
    func deleteTabTodoRemovesById() {
        // Intent: deleteTabTodo removes the matching item.
        // Why it exists: pins the bare delete path.
        // Scenario: spec-first delete.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "A"))
        update(&model, .addTabTodo(tabId: tabId, text: "B"))
        let idA = tabById(tabId, in: model)!.todos[0].id
        update(&model, .deleteTabTodo(tabId: tabId, todoId: idA))
        #expect(tabById(tabId, in: model)!.todos.count == 1)
        #expect(tabById(tabId, in: model)!.todos[0].text == "B")
    }

    // MARK: - reorderTabTodo

    @Test("reorderTabTodo moves item; clamps out-of-bounds")
    func reorderTabTodoMovesItemClampsOutOfBounds() {
        // Intent: reorderTabTodo moves the item; out-of-bounds toIndex
        //   is a no-op.
        // Why it exists: pins the reorder math + clamp.
        // Scenario: spec-first reorder + OOB.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "A"))
        update(&model, .addTabTodo(tabId: tabId, text: "B"))
        update(&model, .addTabTodo(tabId: tabId, text: "C"))
        let idC = tabById(tabId, in: model)!.todos[2].id
        update(&model, .reorderTabTodo(tabId: tabId, todoId: idC, toIndex: 0))
        #expect(tabById(tabId, in: model)!.todos.map(\.text) == ["C", "A", "B"])

        let idA = tabById(tabId, in: model)!.todos[1].id
        let commands = update(&model, .reorderTabTodo(tabId: tabId, todoId: idA, toIndex: 99))
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
        update(&model, .addTabTodo(tabId: tabId, text: "tab A"))
        update(&model, .addTabTodo(tabId: tabId, text: "tab B"))
        update(&model, .addTodo(paneId: paneA, text: "pane task"))
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
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        update(&model, .addTodo(paneId: paneA, text: "pane A"))
        update(&model, .addTodo(paneId: paneA, text: "pane B"))
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
        update(&model, .addTodo(paneId: paneA, text: "source"))
        update(&model, .addTodo(paneId: paneB, text: "dest A"))
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
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        update(&model, .addTodo(paneId: paneA, text: "pane A"))
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
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        update(&model, .addTodo(paneId: paneA, text: "pane A"))
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
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
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
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))

        let commands = update(&model, .moveTodo(from: .tab(tabId), todoId: UUID(), to: .pane(paneA), atIndex: 0))

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
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
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
        update(&model, .addTabTodo(tabId: tabA.id, text: "tab A task"))
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
        update(&model, .addTabTodo(tabId: tabId, text: "tab task"))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(paneA), atIndex: 0))

        #expect(tabById(tabId, in: model)!.todos.isEmpty)
        #expect(model.pane(paneA)!.todos.map(\.text) == ["tab task"])
    }

    // MARK: - clearCompletedTabTodos

    @Test("clearCompletedTabTodos removes only done items")
    func clearCompletedTabTodosRemovesOnlyDone() {
        // Intent: clearCompletedTabTodos removes only done items.
        // Why it exists: pins the clear-completed scope.
        // Scenario: spec-first clear completed.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: tabId, text: "done"))
        update(&model, .addTabTodo(tabId: tabId, text: "pending"))
        let idDone = tabById(tabId, in: model)!.todos[0].id
        update(&model, .toggleTabTodoDone(tabId: tabId, todoId: idDone))
        update(&model, .clearCompletedTabTodos(tabId: tabId))
        #expect(tabById(tabId, in: model)!.todos.count == 1)
        #expect(tabById(tabId, in: model)!.todos[0].text == "pending")
    }

    // MARK: - popover scope transitions

    @Test("toggleTodoPopoverForTab while pane popover is open swaps to tab")
    func toggleTodoPopoverForTabWhilePaneOpenSwapsToTab() {
        // Intent: opening the tab popover while the pane popover is
        //   open swaps scope; dismiss + show commands are emitted.
        // Why it exists: pins mutual-exclusion between pane and tab
        //   popovers.
        // Scenario: spec-first pane -> tab swap.
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        let paneId = tab.focusedPaneId
        update(&model, .toggleTodoPopover(paneId: paneId))
        #expect(model.todoPopover == .pane(paneId))

        let commands = update(&model, .toggleTodoPopoverForTab(tabId: tab.id))
        #expect(model.todoPopover == .tab(tab.id))
        #expect(hasEffect(commands) {
            if case .dismissTodoPopover = $0 { return true }
            return false
        }, "expected dismissTodoPopover")
        #expect(hasEffect(commands) {
            if case .showTodoPopoverForTab(let tid) = $0 { return tid == tab.id }
            return false
        }, "expected showTodoPopoverForTab")
    }

    @Test("toggleTodoPopoverForTab while same tab is open closes the popover")
    func toggleTodoPopoverForTabWhileSameTabClosesPopover() {
        // Intent: re-toggling the tab popover on the same tab closes
        //   it.
        // Why it exists: pins the same-scope close rule.
        // Scenario: spec-first same-tab close.
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        update(&model, .toggleTodoPopoverForTab(tabId: tab.id))
        #expect(model.todoPopover == .tab(tab.id))

        let commands = update(&model, .toggleTodoPopoverForTab(tabId: tab.id))
        #expect(model.todoPopover == nil, "should clear scope")
        #expect(hasEffect(commands) {
            if case .dismissTodoPopoverForTab = $0 { return true }
            return false
        }, "expected dismissTodoPopoverForTab")
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
        let paneId = tab.focusedPaneId
        update(&model, .toggleTodoPopoverForTab(tabId: tab.id))
        #expect(model.todoPopover == .tab(tab.id))

        let commands = update(&model, .toggleTodoPopover(paneId: paneId))
        #expect(model.todoPopover == .pane(paneId))
        #expect(hasEffect(commands) {
            if case .dismissTodoPopoverForTab = $0 { return true }
            return false
        }, "expected dismissTodoPopoverForTab")
        #expect(hasEffect(commands) {
            if case .showTodoPopover(let pid) = $0 { return pid == paneId }
            return false
        }, "expected showTodoPopover")
    }

    @Test("toggleTodoPopover while same pane is open closes the popover")
    func toggleTodoPopoverWhileSamePaneClosesPopover() {
        // Intent: re-toggling the pane popover on the same pane closes
        //   it.
        // Why it exists: pins the same-scope close rule (pane).
        // Scenario: spec-first same-pane close.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .toggleTodoPopover(paneId: paneId))
        let commands = update(&model, .toggleTodoPopover(paneId: paneId))
        #expect(model.todoPopover == nil)
        #expect(hasEffect(commands) {
            if case .dismissTodoPopover = $0 { return true }
            return false
        }, "expected dismissTodoPopover")
    }

    @Test("removing the active tab while its tab popover is open emits dismissTodoPopoverForTab")
    func removingActiveTabWhilePopoverOpenEmitsDismiss() {
        // Intent: closing the tab whose tab popover is open clears
        //   scope and emits dismissTodoPopoverForTab.
        // Why it exists: pins the auto-dismiss rule on tab removal.
        // Scenario: spec-first tab close auto-dismiss.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: tabAId))
        update(&model, .toggleTodoPopoverForTab(tabId: tabAId))
        #expect(model.todoPopover == .tab(tabAId))

        let commands = update(&model, .closeTab(id: tabAId))
        #expect(model.todoPopover == nil, "scope should be cleared")
        #expect(hasEffect(commands) {
            if case .dismissTodoPopoverForTab = $0 { return true }
            return false
        }, "expected dismissTodoPopoverForTab")
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
        let commands = update(&model, .requestCloseTab(id: firstTabId))
        #expect(!hasEffect(commands) {
            if case .showCloseTabConfirmation = $0 { return true }
            return false
        }, "no confirmation for empty tab")
        #expect(model.groups[0].tabs.count == 1, "tab should be removed")
    }

    @Test("requestCloseTab on single-pane tab with uncompleted tab todos shows confirmation")
    func requestCloseTabSinglePaneTabTodosShowsConfirmation() {
        // Intent: a single-pane tab with uncompleted tab todos
        //   surfaces showCloseTabConfirmation with utc=1.
        // Why it exists: pins the confirmation rollup for tab-level
        //   todos.
        // Scenario: spec-first tab todo confirm.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: firstTabId, text: "pending"))

        let commands = update(&model, .requestCloseTab(id: firstTabId))
        #expect(hasEffect(commands) {
            if case .showCloseTabConfirmation(let tid, _, let pc, _, let utc) = $0 {
                return tid == firstTabId && pc == 1 && utc == 1
            }
            return false
        }, "expected confirmation with uncompletedTodoCount=1")
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
        update(&model, .addTodo(paneId: firstTab.focusedPaneId, text: "pane task"))

        let commands = update(&model, .requestCloseTab(id: firstTab.id))
        #expect(hasEffect(commands) {
            if case .showCloseTabConfirmation(_, _, _, _, let utc) = $0 { return utc == 1 }
            return false
        }, "expected confirmation with rollup pane todos")
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

        let commands = update(&model, .requestCloseTab(id: firstTabId))
        #expect(hasEffect(commands) {
            if case .showCloseTabConfirmation(_, _, let pc, _, let utc) = $0 {
                return pc == 2 && utc == 4
            }
            return false
        }, "expected paneCount=2 and uncompletedTodoCount=4")
    }

    @Test("confirmCloseTab on a tab with todos clears pending and closes")
    func confirmCloseTabWithTodosClearsPendingAndCloses() {
        // Intent: confirmCloseTab clears pendingConfirmation and
        //   removes the tab.
        // Why it exists: pins the confirm path with todos.
        // Scenario: spec-first confirm + remove.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .addTabTodo(tabId: firstTabId, text: "pending"))
        update(&model, .requestCloseTab(id: firstTabId))
        #expect(model.pendingConfirmation == .closeTab)

        update(&model, .confirmCloseTab(id: firstTabId))
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
        update(&model, .addTabTodo(tabId: firstTab.id, text: "tab task"))

        let commands = update(&model, .requestClosePane(paneId: firstTab.focusedPaneId))
        #expect(hasEffect(commands) {
            if case .showCloseTabConfirmation(let tid, _, let pc, _, let utc) = $0 {
                return tid == firstTab.id && pc == 1 && utc == 1
            }
            return false
        }, "expected close-tab confirmation")
        #expect(!hasEffect(commands) {
            if case .showClosePaneConfirmation = $0 { return true }
            return false
        }, "should not show pane-level confirmation")
        #expect(model.pane(firstTab.focusedPaneId) != nil, "pane not yet removed")
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
        let paneA = firstTab.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let paneB = selectedTab(in: model)!.focusedPaneId
        update(&model, .addTabTodo(tabId: firstTab.id, text: "tab task"))

        let commands = update(&model, .requestClosePane(paneId: paneB))
        #expect(!hasEffect(commands) {
            if case .showCloseTabConfirmation = $0 { return true }
            return false
        }, "no close-tab confirmation: tab still alive")
        #expect(!hasEffect(commands) {
            if case .showClosePaneConfirmation = $0 { return true }
            return false
        }, "no pane confirmation: pane has no todos")
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
        let paneA = firstTab.focusedPaneId
        update(&model, .addTabTodo(tabId: firstTab.id, text: "tab task"))
        update(&model, .addTodo(paneId: paneA, text: "pane task"))

        let commands = update(&model, .requestClosePane(paneId: paneA))
        #expect(hasEffect(commands) {
            if case .showCloseTabConfirmation(_, _, _, _, let utc) = $0 { return utc == 2 }
            return false
        }, "expected close-tab rollup of 2")
        #expect(!hasEffect(commands) {
            if case .showClosePaneConfirmation = $0 { return true }
            return false
        }, "should not also show pane confirmation")
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
        let paneA = firstTab.focusedPaneId
        update(&model, .addTodo(paneId: paneA, text: "pane only"))

        let commands = update(&model, .requestClosePane(paneId: paneA))
        #expect(hasEffect(commands) {
            if case .showCloseTabConfirmation(_, _, _, _, let utc) = $0 { return utc == 1 }
            return false
        }, "expected close-tab confirmation with rollup 1")
    }
}
