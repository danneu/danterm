// Swift Testing migration of the legacy `tests/UpdateTodoTests.swift` harness
// suite. Pins the owner-parameterized TODO Msg surface plus pure helpers,
// requestClosePane confirmation gating, closePane popover cleanup,
// toggleTodoPopover open/close + stale-pane race guard, the
// reconcileTodoPopover eligibility rules (clear on selected-tab change or
// zoom-hidden pane, preserve on eligible shape/focus changes and the open
// message), splitPane child-with-empty-todos rule, and the
// classifyInputAction / classifyListAction / firstSelectableRow /
// nextSelectableRow / sectionLocalIndex pure helpers.
import Foundation
import Testing

@testable import DanTermCore

private struct SectionRow {
    let isHeader: Bool
    let section: String?
}

enum TodoOwnerKind: String, CaseIterable, Sendable {
    case pane
    case tab
}

func makeTodoOwnerFixture(_ kind: TodoOwnerKind) -> (model: AppModel, owner: TodoOwner) {
    var model = makeModel()
    createTab(&model)
    let tab = selectedTab(in: model)!
    let owner: TodoOwner = switch kind {
    case .pane: .pane(tab.paneTree.focusedPaneId)
    case .tab: .tab(tab.id)
    }
    return (model, owner)
}

@Suite struct UpdateTodoTests {
    @Test("every todo mutation has the same owner-independent behavior", arguments: TodoOwnerKind.allCases)
    func todoMutationsAreOwnerIndependent(kind: TodoOwnerKind) {
        var (model, owner) = makeTodoOwnerFixture(kind)

        update(&model, .addTodo(owner: owner, text: "  A  "))
        update(&model, .addTodo(owner: owner, text: "B"))
        update(&model, .addTodo(owner: owner, text: "C"))
        let ids = model.todos(for: owner)!.map(\.id)
        #expect(model.todos(for: owner)!.map(\.text) == ["A", "B", "C"])

        update(&model, .toggleTodoDone(owner: owner, todoId: ids[0]))
        #expect(model.todos(for: owner)![0].isDone)
        update(&model, .setTodoDone(owner: owner, todoId: ids[0], isDone: false))
        #expect(model.todos(for: owner)![0].isDone == false)
        update(&model, .editTodoText(owner: owner, todoId: ids[1], text: "  edited  "))
        #expect(model.todos(for: owner)![1].text == "edited")
        update(&model, .reorderTodo(owner: owner, todoId: ids[2], toIndex: 0))
        #expect(model.todos(for: owner)!.map(\.text) == ["C", "A", "edited"])

        update(&model, .setTodoDone(owner: owner, todoId: ids[0], isDone: true))
        update(&model, .clearCompletedTodos(owner: owner))
        #expect(model.todos(for: owner)!.map(\.text) == ["C", "edited"])
        update(&model, .deleteTodo(owner: owner, todoId: ids[1]))
        #expect(model.todos(for: owner)!.map(\.text) == ["C"])
    }

    @Test("every todo verb is inert for an unknown owner", arguments: TodoOwnerKind.allCases)
    func todoVerbsAreInertForUnknownOwner(kind: TodoOwnerKind) {
        var (model, knownOwner) = makeTodoOwnerFixture(kind)
        let unknownOwner: TodoOwner = switch kind {
        case .pane: .pane(PaneId())
        case .tab: .tab(TabId())
        }
        let todoId = TodoId()
        let baseline = model
        let messages: [Msg] = [
            .addTodo(owner: unknownOwner, text: "task"),
            .toggleTodoDone(owner: unknownOwner, todoId: todoId),
            .setTodoDone(owner: unknownOwner, todoId: todoId, isDone: true),
            .editTodoText(owner: unknownOwner, todoId: todoId, text: "changed"),
            .deleteTodo(owner: unknownOwner, todoId: todoId),
            .reorderTodo(owner: unknownOwner, todoId: todoId, toIndex: 0),
            .clearCompletedTodos(owner: unknownOwner),
            .moveTodo(from: unknownOwner, todoId: todoId, to: knownOwner, atIndex: 0),
            .moveTodo(from: knownOwner, todoId: todoId, to: unknownOwner, atIndex: 0),
            .toggleTodoPopover(owner: unknownOwner),
        ]

        for message in messages {
            model = baseline
            let commands = update(&model, message)
            #expect(model == baseline)
            #expect(commands.isEmpty)
        }
    }

    @Test("todo popover toggling has the same owner-independent behavior", arguments: TodoOwnerKind.allCases)
    func todoPopoverTogglingIsOwnerIndependent(kind: TodoOwnerKind) {
        var (model, owner) = makeTodoOwnerFixture(kind)

        let openCommands = update(&model, .toggleTodoPopover(owner: owner))
        #expect(model.todoPopover == owner)
        #expect(desiredTodoPopover(in: model) != nil)
        #expect(openCommands.isEmpty)

        let closeCommands = update(&model, .toggleTodoPopover(owner: owner))
        #expect(model.todoPopover == nil)
        #expect(desiredTodoPopover(in: model) == nil)
        #expect(closeCommands.isEmpty)
    }

    @Test("todo popover requests require a visible anchor", arguments: TodoOwnerKind.allCases)
    func todoPopoverRequestRequiresVisibleAnchor(kind: TodoOwnerKind) throws {
        var model = makeModel()
        createTab(&model)
        let selectedId = try #require(model.selectedTabId)
        createTab(&model, background: true)
        let background = try #require(model.groups[0].tabs.first { $0.id != selectedId })
        let owner: TodoOwner = switch kind {
        case .pane: .pane(background.paneTree.focusedPaneId)
        case .tab: .tab(background.id)
        }

        #expect(update(&model, .toggleTodoPopover(owner: owner)).isEmpty)
        #expect(model.todoPopover == nil)
        #expect(desiredTodoPopover(in: model) == nil)
    }

    @Test("zoom retracts a pane popover whose anchor becomes hidden")
    func zoomRetractsHiddenPanePopover() throws {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        _ = update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let zoomedPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        _ = update(&model, .toggleTodoPopover(owner: .pane(firstPaneId)))
        #expect(model.todoPopover == .pane(firstPaneId))

        _ = update(&model, .toggleZoomPane(paneId: zoomedPaneId))

        #expect(model.todoPopover == nil)
        #expect(desiredTodoPopover(in: model) == nil)
    }

    // MARK: - addTodo

    @Test("addTodo creates item with correct text and isDone false")
    func addTodoCreatesItemWithCorrectFields() {
        // Intent: addTodo appends a new item with the given text and isDone=false.
        // Why it exists: pins the bare add path.
        // Scenario: spec-first add.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "run tests"))
        #expect(model.pane(paneId)!.todos.count == 1)
        #expect(model.pane(paneId)!.todos[0].text == "run tests")
        #expect(model.pane(paneId)!.todos[0].isDone == false)
    }

    @Test("addTodo trims whitespace")
    func addTodoTrimsWhitespace() {
        // Intent: addTodo trims surrounding whitespace.
        // Why it exists: pins the trim rule.
        // Scenario: spec-first trim.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "  hello  "))
        #expect(model.pane(paneId)!.todos[0].text == "hello")
    }

    @Test("addTodo rejects empty and whitespace-only text")
    func addTodoRejectsEmptyAndWhitespace() {
        // Intent: addTodo rejects empty and whitespace-only text.
        // Why it exists: pins the reject rule.
        // Scenario: spec-first reject empty.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: ""))
        update(&model, .addTodo(owner: .pane(paneId), text: "   "))
        #expect(model.pane(paneId)!.todos.count == 0)
    }

    // MARK: - toggleTodoDone

    @Test("toggleTodoDone flips isDone")
    func toggleTodoDoneFlipsIsDone() {
        // Intent: toggleTodoDone flips isDone; toggling back inverts again.
        // Why it exists: pins the toggle path and persistence.
        // Scenario: spec-first toggle round-trip.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "task"))
        let todoId = model.pane(paneId)!.todos[0].id
        update(&model, .toggleTodoDone(owner: .pane(paneId), todoId: todoId))
        #expect(model.pane(paneId)!.todos[0].isDone == true)
        update(&model, .toggleTodoDone(owner: .pane(paneId), todoId: todoId))
        #expect(model.pane(paneId)!.todos[0].isDone == false)
    }

    @Test("setTodoDone sets explicit value; same value is a no-op")
    func setTodoDoneSetsExplicitValueNoOpWhenUnchanged() {
        // Intent: setTodoDone(paneId:todoId:isDone:) assigns isDone explicitly, but
        //   returns no commands when the value is already what was requested.
        // Why it exists: pins the value-unchanged guard the item-3 fold relies on
        //   -- the rewrite reads the pane once and bails on `isDone != isDone`
        //   before mutating, so the no-op contract must be locked first.
        // Scenario: spec-first -- no incident; the pane-level arm mirrors the
        //   corresponding tab-owner behavior.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "task"))
        let todoId = model.pane(paneId)!.todos[0].id

        update(&model, .setTodoDone(owner: .pane(paneId), todoId: todoId, isDone: true))
        #expect(model.pane(paneId)!.todos[0].isDone == true)

        let noopCommands = update(&model, .setTodoDone(owner: .pane(paneId), todoId: todoId, isDone: true))
        #expect(noopCommands.isEmpty, "no-op when value unchanged")
    }

    // MARK: - editTodoText

    @Test("editTodoText updates text")
    func editTodoTextUpdatesText() {
        // Intent: editTodoText replaces the matched item's text.
        // Why it exists: pins the bare edit path.
        // Scenario: spec-first edit.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "old"))
        let todoId = model.pane(paneId)!.todos[0].id
        update(&model, .editTodoText(owner: .pane(paneId), todoId: todoId, text: "new"))
        #expect(model.pane(paneId)!.todos[0].text == "new")
    }

    @Test("editTodoText rejects empty text")
    func editTodoTextRejectsEmptyText() {
        // Intent: editTodoText rejects empty and whitespace-only
        //   text (the original text is preserved).
        // Why it exists: pins the reject rule for edits.
        // Scenario: spec-first edit reject.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "keep"))
        let todoId = model.pane(paneId)!.todos[0].id
        update(&model, .editTodoText(owner: .pane(paneId), todoId: todoId, text: ""))
        #expect(model.pane(paneId)!.todos[0].text == "keep")
        update(&model, .editTodoText(owner: .pane(paneId), todoId: todoId, text: "   "))
        #expect(model.pane(paneId)!.todos[0].text == "keep")
    }

    // MARK: - deleteTodo

    @Test("deleteTodo removes the correct item")
    func deleteTodoRemovesCorrectItem() {
        // Intent: deleteTodo removes the matched item; remaining items
        //   keep their order.
        // Why it exists: pins the bare delete path.
        // Scenario: spec-first delete.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "A"))
        update(&model, .addTodo(owner: .pane(paneId), text: "B"))
        let idA = model.pane(paneId)!.todos[0].id
        update(&model, .deleteTodo(owner: .pane(paneId), todoId: idA))
        #expect(model.pane(paneId)!.todos.count == 1)
        #expect(model.pane(paneId)!.todos[0].text == "B")
    }

    // MARK: - reorderTodo

    @Test("reorderTodo moves item to correct position")
    func reorderTodoMovesItemToCorrectPosition() {
        // Intent: reorderTodo moves the matched item to the requested
        //   index.
        // Why it exists: pins the reorder path.
        // Scenario: spec-first reorder.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "A"))
        update(&model, .addTodo(owner: .pane(paneId), text: "B"))
        update(&model, .addTodo(owner: .pane(paneId), text: "C"))
        let idC = model.pane(paneId)!.todos[2].id
        update(&model, .reorderTodo(owner: .pane(paneId), todoId: idC, toIndex: 0))
        #expect(model.pane(paneId)!.todos.map(\.text) == ["C", "A", "B"])
    }

    @Test("reorderTodo no-ops on same position")
    func reorderTodoNoOpsOnSamePosition() {
        // Intent: reorderTodo to the same position is a no-op (no
        //   commands).
        // Why it exists: pins the idempotence guard.
        // Scenario: spec-first reorder no-op.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "A"))
        update(&model, .addTodo(owner: .pane(paneId), text: "B"))
        let idA = model.pane(paneId)!.todos[0].id
        let commands = update(&model, .reorderTodo(owner: .pane(paneId), todoId: idA, toIndex: 0))
        #expect(model.pane(paneId)!.todos.map(\.text) == ["A", "B"])
        #expect(commands.isEmpty)
    }

    @Test("reorderTodo clamps out-of-bounds index")
    func reorderTodoClampsOutOfBoundsIndex() {
        // Intent: an out-of-bounds toIndex is rejected (no-op).
        // Why it exists: pins the OOB guard.
        // Scenario: spec-first reorder OOB.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "A"))
        update(&model, .addTodo(owner: .pane(paneId), text: "B"))
        let idA = model.pane(paneId)!.todos[0].id
        let commands = update(&model, .reorderTodo(owner: .pane(paneId), todoId: idA, toIndex: 99))
        #expect(commands.isEmpty, "out of bounds should be no-op")
    }

    // MARK: - clearCompletedTodos

    @Test("clearCompletedTodos removes only done items")
    func clearCompletedTodosRemovesOnlyDoneItems() {
        // Intent: clearCompletedTodos removes only items with
        //   isDone=true.
        // Why it exists: pins the clear-completed scope.
        // Scenario: spec-first clear completed.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "done"))
        update(&model, .addTodo(owner: .pane(paneId), text: "pending"))
        update(&model, .addTodo(owner: .pane(paneId), text: "also done"))
        let idDone = model.pane(paneId)!.todos[0].id
        let idAlsoDone = model.pane(paneId)!.todos[2].id
        update(&model, .toggleTodoDone(owner: .pane(paneId), todoId: idDone))
        update(&model, .toggleTodoDone(owner: .pane(paneId), todoId: idAlsoDone))
        update(&model, .clearCompletedTodos(owner: .pane(paneId)))
        #expect(model.pane(paneId)!.todos.count == 1)
        #expect(model.pane(paneId)!.todos[0].text == "pending")
    }

    // MARK: - requestClosePane

    @Test("requestClosePane with uncompleted todos on a non-last pane emits per-pane confirmation")
    func requestClosePaneNonLastWithTodosEmitsPerPaneConfirmation() {
        // Intent: a non-last pane close with uncompleted todos
        //   emits the unified close confirmation for that pane.
        // Why it exists: pins the per-pane confirmation path
        //   (distinct from the close-tab routing).
        // Scenario: spec-first pane confirm.
        var model = makeModel()
        createTab(&model)
        let firstPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        update(&model, .addTodo(owner: .pane(firstPaneId), text: "incomplete task"))
        _ = update(&model, .requestClosePane(paneId: firstPaneId))
        #expect(testConfirmationKind(model.pendingConfirmation) == .pane(firstPaneId))
        #expect(desiredConfirmation(in: model)?.informativeText ==
            "This pane has 1 unfinished task.")
        #expect(model.pane(firstPaneId) != nil, "pane should not be removed")
    }

    @Test("requestClosePane with all todos completed proceeds to closePane")
    func requestClosePaneAllTodosCompletedProceedsToClose() {
        // Intent: requestClosePane with all todos completed proceeds
        //   to closePane (no confirmation).
        // Why it exists: pins the no-confirm fast path.
        // Scenario: spec-first all-completed close.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.paneTree.focusedPaneId
        model.selectedTabId = tab.id
        update(&model, .addTodo(owner: .pane(paneId), text: "task"))
        let todoId = model.pane(paneId)!.todos[0].id
        update(&model, .toggleTodoDone(owner: .pane(paneId), todoId: todoId))
        let liveBefore = Set(model.allPaneIds)
        update(&model, .requestClosePane(paneId: paneId))
        #expect(model.pane(paneId) == nil, "pane should be removed")
        #expect(sessionsToTearDown(liveSessionIds: liveBefore, model: model) == Set([paneId]),
            "closed pane's session is torn down")
    }

    @Test("requestClosePane with no todos proceeds to closePane")
    func requestClosePaneWithNoTodosProceedsToClose() {
        // Intent: requestClosePane with no todos closes the pane
        //   directly.
        // Why it exists: pins the no-todos fast path.
        // Scenario: spec-first no-todos close.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tab = model.groups[0].tabs[0]
        let paneId = tab.paneTree.focusedPaneId
        model.selectedTabId = tab.id
        let liveBefore = Set(model.allPaneIds)
        update(&model, .requestClosePane(paneId: paneId))
        #expect(model.pane(paneId) == nil, "pane should be removed")
        #expect(sessionsToTearDown(liveSessionIds: liveBefore, model: model) == Set([paneId]),
            "closed pane's session is torn down")
    }

    // MARK: - closePane + popover cleanup

    @Test("closePane clears todoPopover without a presentation command")
    func closePaneClearsTodoPopoverWithoutCommand() {
        // Intent: closePane on the popover-target pane clears the
        //   model.todoPopover without issuing presentation work.
        // Why it exists: pins the popover-cleanup contract.
        // Scenario: spec-first popover dismiss on close.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        model.todoPopover = .pane(paneId)
        let commands = update(&model, .closePane(paneId: paneId))
        #expect(model.todoPopover == nil, "todoPopover should be nil")
        #expect(commands.isEmpty)
    }

    // MARK: - toggleTodoPopover

    @Test("toggleTodoPopover opens and closes correctly")
    func toggleTodoPopoverOpensAndClosesCorrectly() {
        // Intent: toggleTodoPopover opens the popover for a fresh
        //   pane and closes it on re-toggle.
        // Why it exists: pins the bare open/close path.
        // Scenario: spec-first open + close.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let openEffects = update(&model, .toggleTodoPopover(owner: .pane(paneId)))
        #expect(model.todoPopover == .pane(paneId))
        #expect(openEffects.isEmpty)
        let closeEffects = update(&model, .toggleTodoPopover(owner: .pane(paneId)))
        #expect(model.todoPopover == nil, "should be nil after close")
        #expect(closeEffects.isEmpty)
    }

    // MARK: - todoPopoverClosed race guard

    @Test("todoPopoverClosed for stale pane does not clobber active popover")
    func todoPopoverClosedStalePaneDoesNotClobber() {
        // Intent: a stale todoPopoverClosed event for a different
        //   pane does NOT clear the active popover.
        // Why it exists: pins the race guard for AppKit popover
        //   dismissal events.
        // Scenario: spec-first stale-close guard.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        let tab = selectedTab(in: model)!
        let paneB = tab.paneTree.focusedPaneId
        model.todoPopover = .pane(paneB)
        let paneA = paneId
        update(&model, .todoPopoverClosed(owner: .pane(paneA)))
        #expect(model.todoPopover == .pane(paneB), "paneB popover should still be open")
    }

    // MARK: - reconcileTodoPopover

    @Test("reconcileTodoPopover clears pane and tab popovers on selected-tab change")
    func reconcileTodoPopoverClearsOnSelectedTabChange() {
        // Intent: selectedTab change clears both pane and tab
        //   popovers.
        // Why it exists: pins the selected-tab clear rule.
        // Scenario: spec-first cross-tab clear (pane + tab variants).
        func check(_ scopeFor: (TabId, PaneId) -> TodoOwner, _ label: String) {
            var model = makeModel()
            createTab(&model)
            let firstTab = selectedTab(in: model)!
            createTab(&model, background: true)
            let secondTab = model.groups[0].tabs.first { $0.id != firstTab.id }!
            model.todoPopover = scopeFor(firstTab.id, firstTab.paneTree.focusedPaneId)

            update(&model, .selectTab(id: secondTab.id))

            #expect(model.todoPopover == nil, "\(label) popover should clear when selected tab changes")
        }

        check({ _, paneId in .pane(paneId) }, "pane")
        check({ tabId, _ in .tab(tabId) }, "tab")
    }

    @Test("reconcileTodoPopover preserves eligible pane and tab anchors on shape change")
    func reconcileTodoPopoverPreservesSelectedTabShapeChange() {
        // Intent: a structural edit preserves both surviving pane and tab anchors.
        // Why it exists: persistent wrappers and chrome keep both anchors available.
        // Scenario: the incremental-container reconciliation performance fix.
        var paneModel = makeModel()
        createTab(&paneModel)
        let paneTab = selectedTab(in: paneModel)!
        let paneId = paneTab.paneTree.focusedPaneId
        paneModel.todoPopover = .pane(paneId)

        update(&paneModel, .splitPane(paneId: paneId, direction: .horizontal))

        #expect(paneModel.todoPopover == .pane(paneId))

        var tabModel = makeModel()
        createTab(&tabModel)
        let tab = selectedTab(in: tabModel)!
        tabModel.todoPopover = .tab(tab.id)

        update(&tabModel, .splitPane(paneId: tab.paneTree.focusedPaneId, direction: .horizontal))

        #expect(tabModel.todoPopover == .tab(tab.id))
    }

    @Test("reconcileTodoPopover preserves pane popover on same-tab focus change")
    func reconcileTodoPopoverPreservesOnSameTabFocusChange() {
        // Intent: same-tab focus changes preserve the pane popover.
        // Why it exists: pins the no-clear-on-focus-change rule.
        // Scenario: spec-first same-tab focus.
        var model = makeModel()
        createTab(&model)
        let firstPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let secondPaneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .paneBecameFirstResponder(paneId: firstPaneId))
        model.todoPopover = .pane(firstPaneId)

        update(&model, .paneBecameFirstResponder(paneId: secondPaneId))

        #expect(model.todoPopover == .pane(firstPaneId))
    }

    @Test("reconcileTodoPopover preserves pane popover on background-tab shape change")
    func reconcileTodoPopoverPreservesOnBackgroundTabShapeChange() {
        // Intent: background-tab structural changes preserve the
        //   selected tab's pane popover.
        // Why it exists: pins the per-tab scope.
        // Scenario: spec-first background change.
        var model = makeModel()
        createTab(&model)
        let selected = selectedTab(in: model)!
        createTab(&model, background: true)
        let background = model.groups[0].tabs.first { $0.id != selected.id }!
        model.todoPopover = .pane(selected.paneTree.focusedPaneId)

        update(&model, .splitPane(paneId: background.paneTree.focusedPaneId, direction: .horizontal))

        #expect(model.selectedTabId == selected.id)
        #expect(model.todoPopover == .pane(selected.paneTree.focusedPaneId))
    }

    @Test("reconcileTodoPopover preserves popover opened by the current message")
    func reconcileTodoPopoverPreservesOpenedByCurrentMessage() {
        // Intent: the popover opened by the current Msg survives the
        //   reconcile pass.
        // Why it exists: pins the open-by-current-message preservation
        //   (prevents the same-tick clear loop).
        // Scenario: spec-first open + survive.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

        update(&model, .toggleTodoPopover(owner: .pane(paneId)))

        #expect(model.todoPopover == .pane(paneId))
    }

    // MARK: - splitPane starts empty

    @Test("splitPane starts child with empty todos")
    func splitPaneStartsChildWithEmptyTodos() {
        // Intent: a split's new pane starts with an empty todos list;
        //   the parent's todos are unaffected.
        // Why it exists: pins the no-inherit rule for todos.
        // Scenario: spec-first split empty todos.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: "parent task"))
        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        let tab = selectedTab(in: model)!
        let newPaneId = tab.paneTree.focusedPaneId
        #expect(newPaneId != paneId, "new pane should have different ID")
        #expect(model.pane(newPaneId)!.todos.count == 0, "new pane should have empty todos")
        #expect(model.pane(paneId)!.todos.count == 1)
    }

    // MARK: - classifyInputAction

    @Test("enter submits")
    func enterSubmits() {
        // Intent: enter key (with or without editing) maps to .submit.
        // Why it exists: pins the enter handler.
        // Scenario: spec-first enter.
        #expect(classifyInputAction(key: .enter, isEditing: false, fieldEmpty: true) == .submit)
        #expect(classifyInputAction(key: .enter, isEditing: true, fieldEmpty: false) == .submit)
    }

    @Test("shiftEnter inserts newline")
    func shiftEnterInsertsNewline() {
        // Intent: shift-enter inserts a newline regardless of editing
        //   state.
        // Why it exists: pins the shift-enter handler.
        // Scenario: spec-first shift-enter.
        #expect(classifyInputAction(key: .shiftEnter, isEditing: false, fieldEmpty: true) == .insertNewline)
        #expect(classifyInputAction(key: .shiftEnter, isEditing: true, fieldEmpty: false) == .insertNewline)
    }

    @Test("escape while editing → cancelEdit")
    func escapeWhileEditingCancelEdit() {
        // Intent: escape while editing maps to .cancelEdit (regardless
        //   of field empty/full).
        // Why it exists: pins the escape-edit handler.
        // Scenario: spec-first escape edit.
        #expect(classifyInputAction(key: .escape, isEditing: true, fieldEmpty: false) == .cancelEdit)
        #expect(classifyInputAction(key: .escape, isEditing: true, fieldEmpty: true) == .cancelEdit)
    }

    @Test("escape while not editing → dismiss")
    func escapeWhileNotEditingDismiss() {
        // Intent: escape outside edit maps to .dismiss.
        // Why it exists: pins the escape-dismiss handler.
        // Scenario: spec-first escape dismiss.
        #expect(classifyInputAction(key: .escape, isEditing: false, fieldEmpty: true) == .dismiss)
        #expect(classifyInputAction(key: .escape, isEditing: false, fieldEmpty: false) == .dismiss)
    }

    @Test("backspace on empty field in edit mode → cancelEdit")
    func backspaceOnEmptyFieldInEditModeCancelEdit() {
        // Intent: backspace on empty field in edit mode cancels.
        // Why it exists: pins the edit-on-empty-backspace rule.
        // Scenario: spec-first empty backspace.
        #expect(classifyInputAction(key: .backspace, isEditing: true, fieldEmpty: true) == .cancelEdit)
    }

    @Test("backspace on non-empty field in edit mode → unhandled")
    func backspaceOnNonEmptyFieldInEditModeUnhandled() {
        // Intent: backspace on non-empty edit field is unhandled (let
        //   text editor consume).
        // Why it exists: pins the no-shadow rule.
        // Scenario: spec-first non-empty backspace.
        #expect(classifyInputAction(key: .backspace, isEditing: true, fieldEmpty: false) == .unhandled)
    }

    @Test("backspace when not editing → unhandled")
    func backspaceWhenNotEditingUnhandled() {
        // Intent: backspace outside edit is unhandled.
        // Why it exists: pins the no-handler-outside-edit rule.
        // Scenario: spec-first non-edit backspace.
        #expect(classifyInputAction(key: .backspace, isEditing: false, fieldEmpty: true) == .unhandled)
        #expect(classifyInputAction(key: .backspace, isEditing: false, fieldEmpty: false) == .unhandled)
    }

    @Test("tab while not editing → moveFocusForward")
    func tabWhileNotEditingMoveFocusForward() {
        // Intent: tab outside edit moves focus forward.
        // Why it exists: pins the tab-focus handler outside edit.
        // Scenario: spec-first tab outside.
        #expect(classifyInputAction(key: .tab, isEditing: false, fieldEmpty: true) == .moveFocusForward)
    }

    @Test("tab while editing → moveFocusForward")
    func tabWhileEditingMoveFocusForward() {
        // Intent: tab inside edit still moves focus forward.
        // Why it exists: pins the tab-focus rule (focus override).
        // Scenario: spec-first tab inside edit.
        #expect(classifyInputAction(key: .tab, isEditing: true, fieldEmpty: false) == .moveFocusForward)
    }

    @Test("backtab while editing → moveFocusBackward")
    func backtabWhileEditingMoveFocusBackward() {
        // Intent: backtab inside edit moves focus backward.
        // Why it exists: pins the symmetric back-tab rule inside edit.
        // Scenario: spec-first backtab inside edit.
        #expect(classifyInputAction(key: .backtab, isEditing: true, fieldEmpty: false) == .moveFocusBackward)
    }

    @Test("backtab while not editing → moveFocusBackward")
    func backtabWhileNotEditingMoveFocusBackward() {
        // Intent: backtab outside edit moves focus backward.
        // Why it exists: pins the symmetric rule outside edit.
        // Scenario: spec-first backtab outside.
        #expect(classifyInputAction(key: .backtab, isEditing: false, fieldEmpty: true) == .moveFocusBackward)
    }

    @Test("other → unhandled")
    func otherUnhandled() {
        // Intent: any non-recognized key is unhandled.
        // Why it exists: pins the fall-through default.
        // Scenario: spec-first other unhandled.
        #expect(classifyInputAction(key: .other, isEditing: false, fieldEmpty: false) == .unhandled)
        #expect(classifyInputAction(key: .other, isEditing: true, fieldEmpty: true) == .unhandled)
    }

    // MARK: - classifyListAction

    @Test("list navigation keys move selection")
    func listNavigationKeysMoveSelection() {
        // Intent: j / down arrow / k / up arrow map to
        //   moveSelection(delta: +1/-1).
        // Why it exists: pins the list navigation surface.
        // Scenario: spec-first list nav.
        #expect(classifyListAction(key: .j, modifiers: KeyModifiers()) == .moveSelection(delta: 1))
        #expect(classifyListAction(key: .downArrow, modifiers: KeyModifiers()) == .moveSelection(delta: 1))
        #expect(classifyListAction(key: .k, modifiers: KeyModifiers()) == .moveSelection(delta: -1))
        #expect(classifyListAction(key: .upArrow, modifiers: KeyModifiers()) == .moveSelection(delta: -1))
    }

    @Test("list tab focuses input and enter enters edit")
    func listTabFocusesInputEnterEntersEdit() {
        // Intent: tab in the list focuses the input; enter enters
        //   edit mode.
        // Why it exists: pins the list mode transitions.
        // Scenario: spec-first tab/enter.
        #expect(classifyListAction(key: .tab, modifiers: KeyModifiers()) == .focusInput)
        #expect(classifyListAction(key: .enter, modifiers: KeyModifiers()) == .enterEdit)
    }

    @Test("list space toggles done")
    func listSpaceTogglesDone() {
        // Intent: space toggles isDone on the selected row.
        // Why it exists: pins the space handler.
        // Scenario: spec-first space.
        #expect(classifyListAction(key: .space, modifiers: KeyModifiers()) == .toggleDone)
    }

    @Test("list cmd backspace deletes row")
    func listCmdBackspaceDeletesRow() {
        // Intent: cmd-backspace deletes the row; plain backspace is
        //   unhandled.
        // Why it exists: pins the modifier-strict delete.
        // Scenario: spec-first cmd-backspace.
        #expect(classifyListAction(key: .backspace, modifiers: [.command]) == .deleteRow)
        #expect(classifyListAction(key: .backspace, modifiers: KeyModifiers()) == .unhandled)
    }

    @Test("list shift j and shift k reorder")
    func listShiftJAndShiftKReorder() {
        // Intent: shift-j / shift-k reorder by +1 / -1.
        // Why it exists: pins the reorder shortcut.
        // Scenario: spec-first shift-j/k.
        #expect(classifyListAction(key: .j, modifiers: [.shift]) == .reorder(delta: 1))
        #expect(classifyListAction(key: .k, modifiers: [.shift]) == .reorder(delta: -1))
    }

    @Test("list shift h moves bucket left")
    func listShiftHMovesBucketLeft() {
        // Intent: shift-h moves the selected todo's bucket left.
        // Why it exists: pins the bucket-move shortcut.
        // Scenario: spec-first shift-h.
        #expect(classifyListAction(key: .h, modifiers: [.shift]) == .moveBucket(delta: -1))
    }

    @Test("list shift l moves bucket right")
    func listShiftLMovesBucketRight() {
        // Intent: shift-l moves the selected todo's bucket right.
        // Why it exists: pins the symmetric bucket-move shortcut.
        // Scenario: spec-first shift-l.
        #expect(classifyListAction(key: .l, modifiers: [.shift]) == .moveBucket(delta: 1))
    }

    @Test("list cmd shift h is unhandled")
    func listCmdShiftHIsUnhandled() {
        // Intent: cmd-shift-h is reserved (unhandled).
        // Why it exists: pins the modifier-set-strict rule.
        // Scenario: spec-first cmd-shift-h.
        #expect(classifyListAction(key: .h, modifiers: [.command, .shift]) == .unhandled)
    }

    @Test("list cmd shift l is unhandled")
    func listCmdShiftLIsUnhandled() {
        // Intent: cmd-shift-l is reserved.
        // Why it exists: pins the symmetric reserved combo.
        // Scenario: spec-first cmd-shift-l.
        #expect(classifyListAction(key: .l, modifiers: [.command, .shift]) == .unhandled)
    }

    @Test("list cmd slash shows shortcut help")
    func listCmdSlashShowsShortcutHelp() {
        // Intent: cmd-slash (with optional shift) shows the shortcut
        //   help.
        // Why it exists: pins the help shortcut.
        // Scenario: spec-first cmd-slash.
        #expect(classifyListAction(key: .slash, modifiers: [.command]) == .showShortcutHelp)
        #expect(classifyListAction(key: .slash, modifiers: [.command, .shift]) == .showShortcutHelp)
    }

    @Test("list slash without command is unhandled")
    func listSlashWithoutCommandIsUnhandled() {
        // Intent: slash without cmd is unhandled.
        // Why it exists: pins the modifier-strict rule.
        // Scenario: spec-first slash no-cmd.
        #expect(classifyListAction(key: .slash, modifiers: KeyModifiers()) == .unhandled)
        #expect(classifyListAction(key: .slash, modifiers: [.shift]) == .unhandled)
    }

    @Test("list plain h is unhandled")
    func listPlainHIsUnhandled() {
        // Intent: plain h is unhandled (no bucket move without shift).
        // Why it exists: pins the modifier-required rule for bucket
        //   shortcuts.
        // Scenario: spec-first plain h.
        #expect(classifyListAction(key: .h, modifiers: KeyModifiers()) == .unhandled)
    }

    @Test("list cmd n focuses input")
    func listCmdNFocusesInput() {
        // Intent: cmd-n focuses the input.
        // Why it exists: pins the cmd-n shortcut.
        // Scenario: spec-first cmd-n.
        #expect(classifyListAction(key: .n, modifiers: [.command]) == .focusInput)
    }

    @Test("list shift tab focuses input")
    func listShiftTabFocusesInput() {
        // Intent: shift-tab and shift-backtab focus the input.
        // Why it exists: pins the symmetric input-focus shortcuts.
        // Scenario: spec-first shift-tab.
        #expect(classifyListAction(key: .backtab, modifiers: [.shift]) == .focusInput)
        #expect(classifyListAction(key: .tab, modifiers: [.shift]) == .focusInput)
    }

    @Test("list unmodified text keys are unhandled")
    func listUnmodifiedTextKeysAreUnhandled() {
        // Intent: unmodified printable / other keys are unhandled.
        // Why it exists: pins the fall-through.
        // Scenario: spec-first unmodified text.
        #expect(classifyListAction(key: .n, modifiers: KeyModifiers()) == .unhandled)
        #expect(classifyListAction(key: .other, modifiers: KeyModifiers()) == .unhandled)
    }

    // MARK: - selectable row helpers

    @Test("firstSelectableRow finds the first selectable row")
    func firstSelectableRowFindsFirstSelectable() {
        // Intent: firstSelectableRow returns the first index where
        //   canSelect is true, else nil.
        // Why it exists: pins the search primitive.
        // Scenario: spec-first first-selectable.
        #expect(firstSelectableRow(in: [Int](), canSelect: { _ in true }) == nil)
        #expect(firstSelectableRow(in: [false, false], canSelect: { $0 }) == nil)
        #expect(firstSelectableRow(in: [false, true, true], canSelect: { $0 }) == 1)
        #expect(firstSelectableRow(in: [true, true], canSelect: { $0 }) == 0)
    }

    @Test("nextSelectableRow skips unselectable rows without wrapping")
    func nextSelectableRowSkipsUnselectableNoWrapping() {
        // Intent: nextSelectableRow steps in the given direction
        //   skipping unselectable rows; nil at the edge.
        // Why it exists: pins the no-wrap navigation rule.
        // Scenario: spec-first step nav.
        let rows = [true, false, true, false, true]
        #expect(nextSelectableRow(in: rows, from: 0, delta: 1, canSelect: { $0 }) == 2)
        #expect(nextSelectableRow(in: rows, from: 2, delta: 1, canSelect: { $0 }) == 4)
        #expect(nextSelectableRow(in: rows, from: 4, delta: 1, canSelect: { $0 }) == nil)
        #expect(nextSelectableRow(in: rows, from: 4, delta: -1, canSelect: { $0 }) == 2)
        #expect(nextSelectableRow(in: rows, from: 2, delta: -1, canSelect: { $0 }) == 0)
        #expect(nextSelectableRow(in: rows, from: 0, delta: -1, canSelect: { $0 }) == nil)
    }

    @Test("nextSelectableRow crosses sections while skipping headers")
    func nextSelectableRowCrossesSectionsSkippingHeaders() {
        // Intent: nextSelectableRow crosses sections while skipping
        //   header rows.
        // Why it exists: pins the cross-section navigation rule.
        // Scenario: spec-first cross-section.
        let rows = [false, true, false, true]
        #expect(nextSelectableRow(in: rows, from: 1, delta: 1, canSelect: { $0 }) == 3)
        #expect(nextSelectableRow(in: rows, from: 3, delta: -1, canSelect: { $0 }) == 1)
    }

    // MARK: - sectionLocalIndex

    @Test("sectionLocalIndex returns nil for headers")
    func sectionLocalIndexReturnsNilForHeaders() {
        // Intent: sectionLocalIndex returns nil at a header row.
        // Why it exists: pins the header-skip rule.
        // Scenario: spec-first header skip.
        let rows = [SectionRow(isHeader: true, section: "tab"), SectionRow(isHeader: false, section: "tab")]
        #expect(sectionLocalIndex(rows: rows, at: 0, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }) == nil)
    }

    @Test("sectionLocalIndex returns section-relative positions")
    func sectionLocalIndexReturnsSectionRelativePositions() {
        // Intent: sectionLocalIndex returns position within the current
        //   section (after header).
        // Why it exists: pins the section-relative math.
        // Scenario: spec-first section-relative.
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
        #expect(sectionLocalIndex(rows: rows, at: 1, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }) == 0)
        #expect(sectionLocalIndex(rows: rows, at: 2, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }) == 1)
        #expect(sectionLocalIndex(rows: rows, at: 4, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }) == 0)
        #expect(sectionLocalIndex(rows: rows, at: 5, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }) == 1)
        #expect(sectionLocalIndex(rows: rows, at: 7, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }) == 0)
    }

    @Test("sectionLocalIndex handles a single flat section")
    func sectionLocalIndexHandlesSingleFlatSection() {
        // Intent: with nil sectionId (no headers), section-local
        //   index equals the absolute index.
        // Why it exists: pins the flat-list base case.
        // Scenario: spec-first flat section.
        let rows = [
            SectionRow(isHeader: false, section: nil),
            SectionRow(isHeader: false, section: nil),
            SectionRow(isHeader: false, section: nil),
        ]
        #expect(sectionLocalIndex(rows: rows, at: 0, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }) == 0)
        #expect(sectionLocalIndex(rows: rows, at: 2, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }) == 2)
    }

    @Test("sectionLocalIndex supports clamped reorder destinations")
    func sectionLocalIndexSupportsClampedReorderDestinations() {
        // Intent: a clamped reorder destination row in the same
        //   section returns its expected local index.
        // Why it exists: pins the reorder-clamp math.
        // Scenario: spec-first reorder clamp.
        let rows = [
            SectionRow(isHeader: true, section: "pane"),
            SectionRow(isHeader: false, section: "pane"),
            SectionRow(isHeader: false, section: "pane"),
            SectionRow(isHeader: false, section: "pane"),
            SectionRow(isHeader: true, section: "next"),
            SectionRow(isHeader: false, section: "next"),
        ]
        let clampedDestinationRow = 3
        #expect(sectionLocalIndex(rows: rows, at: clampedDestinationRow, isHeader: { $0.isHeader }, sectionId: { $0.section.map(AnyHashable.init) }) == 2)
    }
}
