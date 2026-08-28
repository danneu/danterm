// Behavioral coverage for TabTodo.swift: the tab-todo popover's row model --
// buildTabTodoRows and the TabTodoRow metadata the keyboard navigator reads --
// and the resolvers defined over those rows: resolveTabTodoEditTarget,
// newlyAddedTabTodoTarget, resolveTabTodoDropTarget, resolveTabTodoBucketStep,
// and resolveTabTodoReorderStep. Every test calls a TabTodo.swift function
// directly.
//
// Not here: the desiredTabTodoPopover / desiredPaneTodoPopover projections that
// wrap these rows -- defined in Projections.swift and asserted in
// ProjectionsTests.swift -- and the same rules driven through the `Msg` surface
// (UpdateTabTodoTests.swift).
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct TabTodoTests {
    // MARK: - buildTabTodoRows

    @Test("buildTabTodoRows emits a header for every pane regardless of empty todos")
    func buildTabTodoRowsEmitsHeaderForEveryPane() {
        // Intent: every live pane in the tab gets a paneSectionHeader row.
        // Why it exists: pins the header-coverage invariant the popover
        //   reads to render section labels.
        // Scenario: spec-first header coverage -- two-pane tab, only
        //   paneA has todos; both panes still get headers.
        var (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(owner: .pane(paneA), text: TodoText("pane A task")!))

        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let paneHeaders = rows.compactMap { row -> PaneId? in
            if case .paneSectionHeader(let paneId, _) = row { return paneId }
            return nil
        }

        #expect(paneHeaders == [paneA, paneB])
    }

    @Test("buildTabTodoRows emits placeholders for an empty tab and empty panes")
    func buildTabTodoRowsEmitsPlaceholdersForEmptySections() {
        // Intent: empty tab and empty panes each receive their respective
        //   placeholder row.
        // Why it exists: pins the placeholder shape the popover renders
        //   for the empty state.
        // Scenario: spec-first empty -- the two-pane model with no todos
        //   has the documented header + placeholder sequence.
        let (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let rows = buildTabTodoRows(model: model, tabId: tabId)

        #expect(rows == [
            .tabSectionHeader,
            .tabEmptyPlaceholder,
            .paneSectionHeader(paneId: paneA, title: DisplayLine(model.pane(paneA)!.session?.titleState.declared ?? "Terminal")),
            .paneEmptyPlaceholder(paneId: paneA),
            .paneSectionHeader(paneId: paneB, title: DisplayLine(model.pane(paneB)!.session?.titleState.declared ?? "Terminal")),
            .paneEmptyPlaceholder(paneId: paneB),
        ])
    }

    @Test("buildTabTodoRows emits placeholders only for empty sections")
    func buildTabTodoRowsEmitsPlaceholdersOnlyForEmpty() {
        // Intent: populated sections get no placeholder; empty sections
        //   keep theirs.
        // Why it exists: pins the placeholder-only-when-empty rule.
        // Scenario: spec-first mixed -- tab + paneA populated, paneB
        //   empty; only paneB's placeholder remains.
        var (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("tab task")!))
        update(&model, .addTodo(owner: .pane(paneA), text: TodoText("pane A task")!))

        let rows = buildTabTodoRows(model: model, tabId: tabId)

        #expect(rows.contains(.tabEmptyPlaceholder) == false, "populated tab should not have a placeholder")
        #expect(rows.contains(.paneEmptyPlaceholder(paneId: paneA)) == false, "populated pane should not have a placeholder")
        #expect(rows.contains(.paneEmptyPlaceholder(paneId: paneB)), "empty pane should have a placeholder")
    }

    @Test("buildTabTodoRows places each placeholder immediately after its header")
    func buildTabTodoRowsPlacesPlaceholdersImmediatelyAfterHeader() {
        // Intent: each empty section's placeholder appears at header+1.
        // Why it exists: pins the row-ordering invariant the popover
        //   selection model uses to keep the visible placeholder pinned.
        // Scenario: spec-first ordering -- in the empty model, every
        //   placeholder sits at section header + 1.
        let (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let rows = buildTabTodoRows(model: model, tabId: tabId)

        #expect(rows[0] == .tabSectionHeader)
        #expect(rows[1] == .tabEmptyPlaceholder)
        let paneAHeader = rows.firstIndex { row in
            if case .paneSectionHeader(let paneId, _) = row { return paneId == paneA }
            return false
        }!
        #expect(rows[paneAHeader + 1] == .paneEmptyPlaceholder(paneId: paneA))
        let paneBHeader = rows.firstIndex { row in
            if case .paneSectionHeader(let paneId, _) = row { return paneId == paneB }
            return false
        }!
        #expect(rows[paneBHeader + 1] == .paneEmptyPlaceholder(paneId: paneB))
    }

    @Test("tab todo placeholder rows are non-selectable section members")
    func tabTodoPlaceholdersAreNonSelectableSectionMembers() {
        // Intent: placeholder rows report isHeader=false, isSelectable=
        //   false, no editTarget/itemText, but a valid sectionIdentifier.
        // Why it exists: pins the row metadata the keyboard navigator and
        //   diff stay consistent with.
        // Scenario: spec-first row-metadata sweep -- assert every
        //   placeholder field for the tab and pane variants.
        let paneId = PaneId()

        let tabPlaceholder = TabTodoRow.tabEmptyPlaceholder
        #expect(tabPlaceholder.isHeader == false)
        #expect(tabPlaceholder.isSelectable == false)
        #expect(tabPlaceholder.editTarget == nil)
        #expect(tabPlaceholder.itemText == nil)
        #expect(tabPlaceholder.sectionIdentifier == Optional(AnyHashable("tab")))

        let panePlaceholder = TabTodoRow.paneEmptyPlaceholder(paneId: paneId)
        #expect(panePlaceholder.isHeader == false)
        #expect(panePlaceholder.isSelectable == false)
        #expect(panePlaceholder.editTarget == nil)
        #expect(panePlaceholder.itemText == nil)
        #expect(panePlaceholder.sectionIdentifier == Optional(AnyHashable(paneId)))
    }

    // MARK: - resolveTabTodoEditTarget / newlyAddedTabTodoTarget

    @Test("resolveTabTodoEditTarget follows a todo across tab and pane buckets")
    func resolveTabTodoEditTargetFollowsAcrossBuckets() {
        // Intent: an edit target tracks a todo across moveTodo
        //   transitions between tab and pane buckets.
        // Why it exists: pins the cross-bucket follow that keeps the edit
        //   field anchored to the moved todo.
        // Scenario: spec-first follow -- add a tab todo, move it to a
        //   pane (edit target switches), move it back (switches back).
        var (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("movable")!))
        let todoId = tabById(tabId, in: model)!.todos[0].id

        update(&model, .moveTodo(from: .tab(tabId), todoId: todoId, to: .pane(paneA), atIndex: 0))
        var projection = desiredTabTodoPopover(tabId: tabId, in: model)!
        #expect(
            resolveTabTodoEditTarget(.init(owner: .tab(tabId), id: todoId), in: projection) ==
            .init(owner: .pane(paneA), id: todoId)
        )

        update(&model, .moveTodo(from: .pane(paneA), todoId: todoId, to: .tab(tabId), atIndex: 0))
        projection = desiredTabTodoPopover(tabId: tabId, in: model)!
        #expect(
            resolveTabTodoEditTarget(.init(owner: .pane(paneA), id: todoId), in: projection) ==
            .init(owner: .tab(tabId), id: todoId)
        )
    }

    @Test("resolveTabTodoEditTarget is scoped to the open tab projection")
    func resolveTabTodoEditTargetScopedToOpenTab() {
        // Intent: an edit target from one tab is not resolved against a
        //   different tab's projection.
        // Why it exists: pins the per-tab scope so cross-tab id lookups
        //   never leak across the popover boundary.
        // Scenario: spec-first scope -- tab A's todo, tab B's projection,
        //   resolve returns nil.
        var model = makeModel()
        createTab(&model)
        let tabA = selectedTab(in: model)!.id
        update(&model, .addTodo(owner: .tab(tabA), text: TodoText("outside")!))
        let outsideTodoId = tabById(tabA, in: model)!.todos[0].id
        createTab(&model)
        let tabB = selectedTab(in: model)!.id

        let projection = desiredTabTodoPopover(tabId: tabB, in: model)!

        #expect(resolveTabTodoEditTarget(.init(owner: .tab(tabA), id: outsideTodoId), in: projection) == nil)
    }

    @Test("newlyAddedTabTodoTarget returns the first tab item missing from the captured id set")
    func newlyAddedTabTodoTargetReturnsFirstMissing() {
        // Intent: after adding a tab todo, the helper points at the new
        //   item's id (the first tab id not in the captured set).
        // Why it exists: pins the new-item focus rule the popover uses to
        //   jump edit mode to the just-added row.
        // Scenario: spec-first new-item focus -- capture ids before add,
        //   then assert the helper picks the new id.
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("existing")!))
        let previousProjection = desiredTabTodoPopover(tabId: tabId, in: model)!
        let previousIds = Set(previousProjection.rows.compactMap { row -> TodoId? in
            if case .tabItem(_, let item) = row { return item.id }
            return nil
        })

        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("new")!))
        let updatedProjection = desiredTabTodoPopover(tabId: tabId, in: model)!
        let newTodoId = tabById(tabId, in: model)!.todos[1].id

        #expect(
            newlyAddedTabTodoTarget(previousTabTodoIds: previousIds, in: updatedProjection) ==
            .init(owner: .tab(tabId), id: newTodoId)
        )
    }

    // MARK: - resolveTabTodoDropTarget

    @Test("resolveTabTodoDropTarget .on tabSectionHeader appends to tab")
    func resolveTabTodoDropTargetOnTabHeaderAppends() {
        // Intent: drop .on tabSectionHeader resolves to tab destination,
        //   atIndex == current tab todo count (append).
        // Why it exists: pins the "drop on header -> append" rule.
        // Scenario: spec-first header drop -- two tab todos; drop on the
        //   tab header lands at index 2.
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("tab A")!))
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("tab B")!))
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: 0, dropOperation: .on)

        #expect(target?.destination == .tab(tabId))
        #expect(target?.atIndex == 2)
    }

    @Test("resolveTabTodoDropTarget .on paneSectionHeader appends to pane")
    func resolveTabTodoDropTargetOnPaneHeaderAppends() {
        // Intent: drop .on a pane section header lands at the end of
        //   that pane's todo list.
        // Why it exists: pins the same "drop on header -> append" rule
        //   for the pane variant.
        // Scenario: spec-first pane header drop -- one paneA todo; drop
        //   on the paneA header lands at index 1.
        var (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(owner: .pane(paneA), text: TodoText("pane A")!))
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let headerRow = rows.firstIndex {
            if case .paneSectionHeader(let paneId, _) = $0 { return paneId == paneA }
            return false
        }!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: headerRow, dropOperation: .on)

        #expect(target?.destination == .pane(paneA))
        #expect(target?.atIndex == 1)
    }

    @Test("resolveTabTodoDropTarget .on tabEmptyPlaceholder inserts at tab index 0")
    func resolveTabTodoDropTargetOnTabPlaceholderInsertsAtZero() {
        // Intent: drop .on tabEmptyPlaceholder inserts at the tab's
        //   index 0.
        // Why it exists: pins the empty-section drop rule (placeholder is
        //   the only visible target).
        // Scenario: spec-first empty drop.
        let (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let placeholderRow = rows.firstIndex(of: .tabEmptyPlaceholder)!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: placeholderRow, dropOperation: .on)

        #expect(target?.destination == .tab(tabId))
        #expect(target?.atIndex == 0)
    }

    @Test("resolveTabTodoDropTarget .on paneEmptyPlaceholder inserts at pane index 0")
    func resolveTabTodoDropTargetOnPanePlaceholderInsertsAtZero() {
        // Intent: drop .on paneEmptyPlaceholder inserts at the pane's
        //   index 0.
        // Why it exists: pins the pane variant of the empty-section drop
        //   rule.
        // Scenario: spec-first empty pane drop.
        let (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let placeholderRow = rows.firstIndex(of: .paneEmptyPlaceholder(paneId: paneA))!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: placeholderRow, dropOperation: .on)

        #expect(target?.destination == .pane(paneA))
        #expect(target?.atIndex == 0)
    }

    @Test("resolveTabTodoDropTarget .above first tabItem inserts at tab index 0")
    func resolveTabTodoDropTargetAboveFirstTabItem() {
        // Intent: drop .above the first tab item inserts at tab index 0.
        // Why it exists: pins the "above first item" rule.
        // Scenario: spec-first above-first -- drop above row 1 (first
        //   tab item) lands at tab index 0.
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("tab A")!))
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: 1, dropOperation: .above)

        #expect(target?.destination == .tab(tabId))
        #expect(target?.atIndex == 0)
    }

    @Test("resolveTabTodoDropTarget .above between two tabItems uses local index")
    func resolveTabTodoDropTargetAboveBetweenTabItems() {
        // Intent: drop .above a tabItem N inserts at the destination's
        //   local index N within the tab section.
        // Why it exists: pins the local-index translation that maps row
        //   ordinals to bucket-local indices.
        // Scenario: spec-first local-index -- two tab todos; drop above
        //   row 2 (second tab item) lands at tab index 1.
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("tab A")!))
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("tab B")!))
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: 2, dropOperation: .above)

        #expect(target?.destination == .tab(tabId))
        #expect(target?.atIndex == 1)
    }

    @Test("resolveTabTodoDropTarget .above paneSectionHeader appends to previous section")
    func resolveTabTodoDropTargetAbovePaneHeaderAppendsToPrev() {
        // Intent: drop .above a paneSectionHeader appends to the previous
        //   section (tab section here).
        // Why it exists: pins the "above the boundary between sections"
        //   rule.
        // Scenario: spec-first append-to-prev -- two tab todos; drop
        //   above the first paneSectionHeader lands at tab index 2
        //   (append).
        var (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("tab A")!))
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("tab B")!))
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let firstPaneHeader = rows.firstIndex {
            if case .paneSectionHeader = $0 { return true }
            return false
        }!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: firstPaneHeader, dropOperation: .above)

        #expect(target?.destination == .tab(tabId))
        #expect(target?.atIndex == 2)
    }

    @Test("resolveTabTodoDropTarget .above one-past-end appends to last section")
    func resolveTabTodoDropTargetAboveOnePastEndAppendsToLast() {
        // Intent: drop .above rows.count (one-past-end) appends to the
        //   last visible section.
        // Why it exists: pins the trailing-edge drop rule.
        // Scenario: spec-first one-past-end -- paneB has one todo; drop
        //   above rows.count lands at pane B index 1.
        var (model, tabId, _, paneB) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(owner: .pane(paneB), text: TodoText("pane B")!))
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: rows.count, dropOperation: .above)

        #expect(target?.destination == .pane(paneB))
        #expect(target?.atIndex == 1)
    }

    @Test("resolveTabTodoDropTarget .above tabEmptyPlaceholder inserts at tab index 0")
    func resolveTabTodoDropTargetAboveTabPlaceholderInsertsAtZero() {
        // Intent: drop .above the tab's empty placeholder inserts at tab
        //   index 0.
        // Why it exists: pins the empty-section .above rule.
        // Scenario: spec-first above-empty-tab.
        let (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let placeholderRow = rows.firstIndex(of: .tabEmptyPlaceholder)!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: placeholderRow, dropOperation: .above)

        #expect(target?.destination == .tab(tabId))
        #expect(target?.atIndex == 0)
    }

    @Test("resolveTabTodoDropTarget .above paneEmptyPlaceholder inserts at pane index 0")
    func resolveTabTodoDropTargetAbovePanePlaceholderInsertsAtZero() {
        // Intent: drop .above a pane's empty placeholder inserts at the
        //   pane's index 0.
        // Why it exists: pins the empty-pane .above rule.
        // Scenario: spec-first above-empty-pane.
        let (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)
        let placeholderRow = rows.firstIndex(of: .paneEmptyPlaceholder(paneId: paneA))!

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: placeholderRow, dropOperation: .above)

        #expect(target?.destination == .pane(paneA))
        #expect(target?.atIndex == 0)
    }

    @Test("resolveTabTodoDropTarget .above one-past-end appends to final placeholder section")
    func resolveTabTodoDropTargetAboveOnePastEndAppendsToFinalPlaceholder() {
        // Intent: with the final section empty (placeholder only), .above
        //   one-past-end appends to that placeholder section.
        // Why it exists: pins the trailing-edge rule against the
        //   placeholder boundary, not the underlying todos.
        // Scenario: spec-first one-past-end empty -- both panes empty;
        //   .above rows.count lands at paneB index 0.
        let (model, tabId, _, paneB) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: rows.count, dropOperation: .above)

        #expect(target?.destination == .pane(paneB))
        #expect(target?.atIndex == 0)
    }

    @Test("resolveTabTodoDropTarget .above tabSectionHeader row 0 returns nil")
    func resolveTabTodoDropTargetAboveTabSectionHeaderRow0Nil() {
        // Intent: drop .above the very first row (the tab section header)
        //   yields no valid destination.
        // Why it exists: pins the leading-edge guard.
        // Scenario: spec-first above-row-zero.
        let (model, tabId, _, _) = makeTwoPaneTabTodoRowsModel()
        let rows = buildTabTodoRows(model: model, tabId: tabId)

        let target = resolveTabTodoDropTarget(rows: rows, model: model, tabId: tabId, proposedRow: 0, dropOperation: .above)

        #expect(target == nil)
    }

    // MARK: - resolveTabTodoBucketStep

    @Test("resolveTabTodoBucketStep tab + delta=+1 returns pane0")
    func resolveTabTodoBucketStepTabPlusOneReturnsPane0() {
        // Intent: stepping +1 from the tab bucket returns the first pane.
        // Why it exists: pins the bucket-traversal order the keyboard
        //   shortcuts use.
        // Scenario: spec-first tab -> paneA.
        let (_, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let destination = resolveTabTodoBucketStep(
            current: .init(owner: .tab(tabId), id: TodoId()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            delta: 1
        )

        #expect(destination == .pane(paneA))
    }

    @Test("resolveTabTodoBucketStep pane0 + delta=-1 returns tab")
    func resolveTabTodoBucketStepPane0MinusOneReturnsTab() {
        // Intent: stepping -1 from the first pane returns the tab bucket.
        // Why it exists: pins the reverse direction of the same
        //   traversal.
        // Scenario: spec-first paneA -> tab.
        let (_, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let destination = resolveTabTodoBucketStep(
            current: .init(owner: .pane(paneA), id: TodoId()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            delta: -1
        )

        #expect(destination == .tab(tabId))
    }

    @Test("resolveTabTodoBucketStep tab + delta=-1 stops at start")
    func resolveTabTodoBucketStepTabMinusOneStops() {
        // Intent: stepping -1 from tab returns nil (clamped at start).
        // Why it exists: pins the leading-edge clamp the keyboard
        //   navigator reads to halt.
        // Scenario: spec-first start clamp.
        let (_, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let destination = resolveTabTodoBucketStep(
            current: .init(owner: .tab(tabId), id: TodoId()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            delta: -1
        )

        #expect(destination == nil)
    }

    @Test("resolveTabTodoBucketStep lastPane + delta=+1 stops at end")
    func resolveTabTodoBucketStepLastPanePlusOneStops() {
        // Intent: stepping +1 from the last pane returns nil (clamped at
        //   end).
        // Why it exists: pins the trailing-edge clamp.
        // Scenario: spec-first end clamp.
        let (_, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()

        let destination = resolveTabTodoBucketStep(
            current: .init(owner: .pane(paneB), id: TodoId()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            delta: 1
        )

        #expect(destination == nil)
    }

    // MARK: - resolveTabTodoReorderStep

    @Test("resolveTabTodoReorderStep middle of tab section with delta=+1 reorders down")
    func resolveTabTodoReorderStepTabMiddlePlus1ReordersDown() {
        // Intent: a middle item in the tab section reorders within
        //   section (toIndex = currentIndex + 1).
        // Why it exists: pins the intra-section reorder of cmd-shift-j /
        //   cmd-shift-k.
        // Scenario: spec-first within-section -- delta +1 at index 1
        //   yields .reorderInSection(toIndex: 2).
        let tabId = TabId()

        let step = resolveTabTodoReorderStep(
            current: .init(owner: .tab(tabId), id: TodoId()),
            paneOrder: [PaneId(), PaneId()],
            tabId: tabId,
            currentIndex: 1,
            currentSectionCount: 3,
            destinationSectionCount: { _ in 0 },
            delta: 1
        )

        #expect(step == .reorderInSection(toIndex: 2))
    }

    @Test("resolveTabTodoReorderStep middle of tab section with delta=-1 reorders up")
    func resolveTabTodoReorderStepTabMiddleMinus1ReordersUp() {
        // Intent: delta=-1 in the middle of a section reorders up.
        // Why it exists: pins the symmetric within-section reorder.
        // Scenario: spec-first within-section -- delta -1 at index 1
        //   yields .reorderInSection(toIndex: 0).
        let tabId = TabId()

        let step = resolveTabTodoReorderStep(
            current: .init(owner: .tab(tabId), id: TodoId()),
            paneOrder: [PaneId(), PaneId()],
            tabId: tabId,
            currentIndex: 1,
            currentSectionCount: 3,
            destinationSectionCount: { _ in 0 },
            delta: -1
        )

        #expect(step == .reorderInSection(toIndex: 0))
    }

    @Test("resolveTabTodoReorderStep last tab item with delta=+1 moves to first pane at start")
    func resolveTabTodoReorderStepLastTabPlus1MovesToFirstPane() {
        // Intent: stepping +1 off the end of the tab section crosses
        //   into pane0 at index 0.
        // Why it exists: pins the cross-section transition that
        //   keyboards rely on to escape the section.
        // Scenario: spec-first cross-into-paneA at start.
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .init(owner: .tab(tabId), id: TodoId()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 2,
            currentSectionCount: 3,
            destinationSectionCount: { destination in
                destination == .pane(paneA) ? 2 : 0
            },
            delta: 1
        )

        #expect(step == .moveToBucket(destination: .pane(paneA), atIndex: 0))
    }

    @Test("resolveTabTodoReorderStep last tab item with delta=+1 moves to empty first pane at start")
    func resolveTabTodoReorderStepLastTabPlus1MovesToEmptyFirstPane() {
        // Intent: the same cross-section step works against an empty
        //   destination (index 0 still valid).
        // Why it exists: pins the empty-destination branch.
        // Scenario: spec-first cross-into-empty-paneA.
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .init(owner: .tab(tabId), id: TodoId()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 2,
            currentSectionCount: 3,
            destinationSectionCount: { _ in 0 },
            delta: 1
        )

        #expect(step == .moveToBucket(destination: .pane(paneA), atIndex: 0))
    }

    @Test("resolveTabTodoReorderStep first pane0 item with delta=-1 moves to tab end")
    func resolveTabTodoReorderStepFirstPane0Minus1MovesToTabEnd() {
        // Intent: stepping -1 off the start of paneA crosses into the
        //   tab section at its end (atIndex = destination count).
        // Why it exists: pins the symmetric cross-section transition.
        // Scenario: spec-first cross-into-tab at end (count == 3).
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .init(owner: .pane(paneA), id: TodoId()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 0,
            currentSectionCount: 2,
            destinationSectionCount: { destination in
                destination == .tab(tabId) ? 3 : 0
            },
            delta: -1
        )

        #expect(step == .moveToBucket(destination: .tab(tabId), atIndex: 3))
    }

    @Test("resolveTabTodoReorderStep first pane0 item with delta=-1 moves to empty tab at start")
    func resolveTabTodoReorderStepFirstPane0Minus1MovesToEmptyTabAtStart() {
        // Intent: with the tab section empty, the same backward step
        //   lands at tab index 0.
        // Why it exists: pins the empty-destination branch on the
        //   reverse direction.
        // Scenario: spec-first cross-into-empty-tab.
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .init(owner: .pane(paneA), id: TodoId()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 0,
            currentSectionCount: 2,
            destinationSectionCount: { _ in 0 },
            delta: -1
        )

        #expect(step == .moveToBucket(destination: .tab(tabId), atIndex: 0))
    }

    @Test("resolveTabTodoReorderStep last pane0 item with delta=+1 moves to pane1 start")
    func resolveTabTodoReorderStepLastPane0Plus1MovesToPane1Start() {
        // Intent: stepping +1 off the end of paneA crosses to paneB at
        //   index 0.
        // Why it exists: pins the pane-to-pane transition.
        // Scenario: spec-first paneA -> paneB at start.
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .init(owner: .pane(paneA), id: TodoId()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 3,
            currentSectionCount: 4,
            destinationSectionCount: { destination in
                destination == .pane(paneB) ? 2 : 0
            },
            delta: 1
        )

        #expect(step == .moveToBucket(destination: .pane(paneB), atIndex: 0))
    }

    @Test("resolveTabTodoReorderStep first pane1 item with delta=-1 moves to pane0 end")
    func resolveTabTodoReorderStepFirstPane1Minus1MovesToPane0End() {
        // Intent: stepping -1 off the start of paneB crosses to paneA at
        //   the end (atIndex == paneA count).
        // Why it exists: pins the reverse pane-to-pane transition.
        // Scenario: spec-first paneB -> paneA at end (count == 4).
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .init(owner: .pane(paneB), id: TodoId()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 0,
            currentSectionCount: 2,
            destinationSectionCount: { destination in
                destination == .pane(paneA) ? 4 : 0
            },
            delta: -1
        )

        #expect(step == .moveToBucket(destination: .pane(paneA), atIndex: 4))
    }

    @Test("resolveTabTodoReorderStep first tab item with delta=-1 stops at top")
    func resolveTabTodoReorderStepFirstTabMinus1Stops() {
        // Intent: stepping -1 at the start of the tab section returns
        //   nil (clamped).
        // Why it exists: pins the top-of-list clamp.
        // Scenario: spec-first top clamp.
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .init(owner: .tab(tabId), id: TodoId()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 0,
            currentSectionCount: 3,
            destinationSectionCount: { _ in 0 },
            delta: -1
        )

        #expect(step == nil)
    }

    @Test("resolveTabTodoReorderStep last last-pane item with delta=+1 stops at bottom")
    func resolveTabTodoReorderStepLastLastPanePlus1Stops() {
        // Intent: stepping +1 at the end of the last pane returns nil
        //   (clamped).
        // Why it exists: pins the bottom-of-list clamp.
        // Scenario: spec-first bottom clamp.
        let tabId = TabId()
        let paneA = PaneId()
        let paneB = PaneId()

        let step = resolveTabTodoReorderStep(
            current: .init(owner: .pane(paneB), id: TodoId()),
            paneOrder: [paneA, paneB],
            tabId: tabId,
            currentIndex: 1,
            currentSectionCount: 2,
            destinationSectionCount: { _ in 0 },
            delta: 1
        )

        #expect(step == nil)
    }
}
