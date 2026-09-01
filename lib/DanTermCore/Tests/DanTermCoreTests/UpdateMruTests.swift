// Swift Testing migration of the legacy `tests/UpdateMruTests.swift` harness
// suite. Pins MRU tab switcher behavior at the surface a user can see -- which
// tab the switcher would list first, and which tab a cycle lands on -- rather
// than at any stored order: recency lives on each tab as a focus stamp, and the
// order is derived only when a cycle freezes it. Covered here: the per-Msg
// recency rules (createTab leads, selectTab leads when it changes the
// selection, closeTab + sessionCreationFailed + deleteGroup drop the removed
// tabs), the bypass-path coverage via movePaneToNewTab, and the four cycle
// handlers (mruCycleStepped / Committed / Canceled / OneShot) plus the
// restore-time order. The two `guard let ... else { throw }` unwraps over a
// `frozenOrder` first-element and an `mruCycle` snapshot convert to
// `Issue.record + return` because both bindings use guarded chained expressions
// (`.dropFirst().first` / `cycle.cursorIndex < cycle.frozenOrder.count`) that
// `#require` cannot pin down.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateMruTests {
    /// Build a model that has gone through update(.createTab) N times so focus
    /// history is populated naturally. Returns ids in creation order; the
    /// last-created tab is selectedTabId.
    static func buildModelWithTabs(_ count: Int) -> (model: AppModel, tabIds: [TabId]) {
        var model = makeModel()
        var ids: [TabId] = []
        for _ in 0..<count {
            _ = update(&model, .createTabInSelectedGroup())
            ids.append(model.selectedTabId!)
        }
        return (model, ids)
    }

    // MARK: - Recency under existing handlers

    @Test("createTab leads the switcher order with the new tab")
    func createTabLeadsSwitcherOrderWithNewTab() {
        // Intent: each createTab selects the new tab, so the switcher lists it
        //   first and the tab it displaced second.
        // Why it exists: pins the recency contract creating a tab relies on.
        // Scenario: spec-first createTab recency.
        var model = makeModel()
        _ = update(&model, .createTabInSelectedGroup())
        let firstId = model.selectedTabId!
        #expect(switcherOrder(of: model) == [firstId])

        _ = update(&model, .createTabInSelectedGroup())
        let secondId = model.selectedTabId!
        #expect(switcherOrder(of: model) == [secondId, firstId], "newly selected tab leads")
    }

    @Test("selectTab makes the selected tab the switcher's first entry")
    func selectTabLeadsSwitcherOrder() {
        // Intent: selecting a tab outside a cycle makes it the most recent.
        // Why it exists: pins the per-selection recency stamp.
        // Scenario: spec-first hoist.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0

        _ = update(&model, .selectTab(id: ids[0]))
        #expect(switcherOrder(of: model).first == ids[0], "ids[0] leads")
    }

    @Test("selectTab does NOT change the order an active cycle froze")
    func selectTabDoesNotReorderWhileCycling() {
        // Intent: a selection change during an active cycle leaves the cycle's
        //   frozen order alone.
        // Why it exists: pins the freeze the cmd-tab UX depends on, so the
        //   switcher rows keep their positions while the user steps.
        // Scenario: spec-first cycle freeze.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0
        _ = update(&model, .mruCycleStepped(direction: .older))
        let frozen = model.mruCycle?.frozenOrder ?? []
        #expect(frozen.count == 3, "preconditioned: 3 tabs in the frozen order")

        _ = update(&model, .selectTab(id: ids[0]))
        #expect(model.mruCycle?.frozenOrder == frozen, "the frozen order must not change")
    }

    @Test("a selection made mid-cycle still counts as recency")
    func midCycleSelectionStampsRecency() {
        // Intent: a `.selectTab` that lands while a cycle is active records
        //   recency like any other selection, so the next cycle's order shows
        //   it behind whatever was selected afterwards.
        // Why it exists: the cycle freezes an order, it does not suspend
        //   history -- a tab genuinely focused mid-cycle must not fall back
        //   behind tabs the user has not touched since.
        // Scenario: spec-first; start a cycle, select A through another input,
        //   cancel, then select B outside any cycle. The next cycle reads
        //   B, A, ...
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0
        let tabA = ids[0]
        let tabB = ids[1]

        _ = update(&model, .mruCycleStepped(direction: .older))
        _ = update(&model, .selectTab(id: tabA))
        _ = update(&model, .mruCycleCanceled)
        _ = update(&model, .selectTab(id: tabB))

        #expect(switcherOrder(of: model) == [tabB, tabA, ids[2]])
    }

    @Test("closeTab drops the tab from the switcher order")
    func closeTabDropsTabFromSwitcherOrder() {
        // Intent: a closed tab contributes nothing to a later order.
        // Why it exists: pins that recency dies with the tab.
        // Scenario: spec-first close prune.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0

        _ = update(&model, .closeTab(id: ids[1]))
        let order = switcherOrder(of: model)
        #expect(!order.contains(ids[1]), "closed tab dropped")
        #expect(order.contains(ids[0]) && order.contains(ids[2]))
    }

    @Test("paneBecameFirstResponder does not change the switcher order")
    func paneBecameFirstResponderDoesNotChangeSwitcherOrder() {
        // Intent: pane focus changes do NOT touch tab recency.
        // Why it exists: pins the per-pane scope (tab focus is the MRU
        //   trigger, not pane focus).
        // Scenario: spec-first pane-focus no MRU change.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0
        let snapshot = switcherOrder(of: model)
        let focusedPane = model.groups[0].tabs.first { $0.id == ids[2] }!.paneTree.focusedPaneId

        _ = update(&model, .paneBecameFirstResponder(paneId: focusedPane))
        #expect(switcherOrder(of: model) == snapshot, "pane focus must not move a tab in MRU")
    }

    // MARK: - Reconciliation across bypass paths

    @Test("movePaneToNewTab — the new tab enters the switcher order")
    func movePaneToNewTabEntersSwitcherOrder() {
        // Intent: a movePaneToNewTab puts the new tab in the switcher order.
        // Why it exists: pins the bypass-path reconcile so the new tab
        //   appears in the switcher.
        // Scenario: spec-first extract MRU.
        let (m0, _) = Self.buildModelWithTabs(2)
        var model = m0
        let firstTab = model.groups[0].tabs[0]
        _ = update(&model, .selectTab(id: firstTab.id))
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        let panes = allPaneIds(model.groups[0].tabs[0].paneTree.root)
        #expect(panes.count == 2, "split should produce 2 panes in source tab")
        let groupId = model.groups[0].id
        let countBefore = switcherOrder(of: model).count

        _ = update(&model, .movePaneToNewTab(paneId: panes[1], inGroupId: groupId, atIndex: 0))
        let newTabId = model.selectedTabId!
        let order = switcherOrder(of: model)
        #expect(order.count == countBefore + 1)
        #expect(order.first == newTabId, "the new tab is the most recent")
    }

    @Test("a background tab created into a tab-less model becomes selected")
    func backgroundTabIntoEmptyModelBecomesSelected() throws {
        // Intent: with no tabs and no selection, a background-created tab is
        //   selected anyway.
        // Why it exists: "background" means "do not steal a live selection".
        //   With nothing selected there is nothing to steal, and leaving the
        //   selection nil beside a live tab breaks the selection invariant.
        // Scenario: spec-first; IPC creates a background tab in the launch
        //   window before the first tab exists.
        var model = makeModel()
        #expect(model.selectedTabId == nil)

        createTab(&model, background: true)

        let created = try #require(model.groups[0].tabs.first?.id)
        #expect(model.selectedTabId == created)
        #expect(switcherOrder(of: model).first == created)
    }

    @Test("sessionCreationFailed drops the failed tab from the switcher order")
    func sessionCreationFailedDropsFailedTab() {
        // Intent: sessionCreationFailed removes the failed tab from the order.
        // Why it exists: pins the failure-path prune.
        // Scenario: spec-first failure prune.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0
        let failedTabId = ids[1]
        let failedPaneId = model.groups[0].tabs.first { $0.id == failedTabId }!.paneTree.focusedPaneId

        let sessionId = model.pane(failedPaneId)!.session!.id
        _ = update(&model, .sessionCreationFailed(sessionId: sessionId))
        #expect(!switcherOrder(of: model).contains(failedTabId), "failed-tab id dropped")
    }

    @Test("deleteGroup(moveTabs: false) drops the destroyed tab ids")
    func deleteGroupMoveTabsFalseDropsDestroyedTabIds() {
        // Intent: deleteGroup(moveTabs: false) drops destroyed tab ids from
        //   the switcher order.
        // Why it exists: pins the per-group prune.
        // Scenario: spec-first deleteGroup destructive prune.
        var model = makeModel()
        _ = update(&model, .createGroup(name: "Other"))
        let groups = model.groups
        _ = update(&model, .createTab(inGroupId: groups[0].id))
        let tabA = model.selectedTabId!
        _ = update(&model, .createTab(inGroupId: groups[1].id))
        let tabB = model.selectedTabId!
        let orderBefore = switcherOrder(of: model)
        #expect(orderBefore.contains(tabA) && orderBefore.contains(tabB))

        _ = update(&model, .deleteGroup(id: groups[1].id, moveTabs: false))
        let order = switcherOrder(of: model)
        #expect(!order.contains(tabB), "tabB dropped")
        #expect(order.contains(tabA), "tabA preserved")
    }

    @Test("deleteGroup(moveTabs: true) keeps the moved tab in the switcher order")
    func deleteGroupMoveTabsTrueKeepsMovedTab() {
        // Intent: deleteGroup(moveTabs: true) preserves the moved tab in the
        //   switcher order.
        // Why it exists: pins the moveTabs branch preservation.
        // Scenario: spec-first deleteGroup move MRU.
        var model = makeModel()
        _ = update(&model, .createGroup(name: "Other"))
        let groups = model.groups
        _ = update(&model, .createTab(inGroupId: groups[0].id))
        let tabA = model.selectedTabId!
        _ = update(&model, .createTab(inGroupId: groups[1].id))
        let tabB = model.selectedTabId!

        _ = update(&model, .deleteGroup(id: groups[1].id, moveTabs: true))
        let order = switcherOrder(of: model)
        #expect(order.contains(tabA))
        #expect(order.contains(tabB), "moved tab still present")
    }

    // MARK: - Cycle handlers

    @Test("mruCycleStepped with no tabs is a no-op")
    func mruCycleSteppedWithNoTabsIsNoOp() {
        // Intent: mruCycleStepped with no tabs at all is a no-op.
        // Why it exists: pins the empty-state guard.
        // Scenario: spec-first empty MRU step.
        var model = makeModel()
        #expect(!model.hasAnyTab, "preconditioned: no tabs")

        let commands = update(&model, .mruCycleStepped(direction: .older))
        #expect(model.mruCycle == nil, "no cycle started")
        #expect(commands.count == 0, "no commands emitted")
    }

    @Test("mruCycleStepped(.older) from idle starts cycle at cursorIndex 1")
    func mruCycleSteppedOlderFromIdleStartsAtIndex1() {
        // Intent: stepping older from idle starts a cycle whose frozen order
        //   is the current recency order, cursor at index 1.
        // Why it exists: pins the cycle-start contract.
        // Scenario: spec-first start step.
        let (m0, _) = Self.buildModelWithTabs(3)
        var model = m0
        let snapshot = switcherOrder(of: model)

        let commands = update(&model, .mruCycleStepped(direction: .older))
        #expect(model.mruCycle != nil, "cycle started")
        #expect((model.mruCycle?.frozenOrder ?? []) == snapshot)
        #expect((model.mruCycle?.cursorIndex ?? -1) == 1)
        #expect(commands.isEmpty, "step emits no commands; the switcher reconciles from mruCycle")
    }

    @Test("mruCycleStepped(.newer) from idle wraps to last index")
    func mruCycleSteppedNewerFromIdleWrapsToLast() {
        // Intent: stepping newer from idle wraps to the last index
        //   (cmd-shift-tab parity).
        // Why it exists: pins the wrap-from-idle rule.
        // Scenario: spec-first newer from idle.
        let (m0, _) = Self.buildModelWithTabs(4)
        var model = m0
        let commands = update(&model, .mruCycleStepped(direction: .newer))
        #expect(model.mruCycle != nil, "cycle started")
        #expect((model.mruCycle?.cursorIndex ?? -1) == 3, "wrapped to last index")
        #expect(commands.isEmpty, "step emits no commands; the switcher reconciles from mruCycle")
    }

    @Test("repeated mruCycleStepped(.older) advances and wraps")
    func repeatedMruCycleSteppedOlderAdvancesAndWraps() {
        // Intent: repeated older steps advance until the end, then wrap
        //   to 0.
        // Why it exists: pins the wrap-past-end rule.
        // Scenario: spec-first repeat older.
        let (m0, _) = Self.buildModelWithTabs(3)
        var model = m0
        _ = update(&model, .mruCycleStepped(direction: .older))
        _ = update(&model, .mruCycleStepped(direction: .older))
        #expect((model.mruCycle?.cursorIndex ?? -1) == 2)
        _ = update(&model, .mruCycleStepped(direction: .older))
        #expect((model.mruCycle?.cursorIndex ?? -1) == 0, "wrapped past last")
        _ = update(&model, .mruCycleStepped(direction: .older))
        #expect((model.mruCycle?.cursorIndex ?? -1) == 1)
    }

    @Test("mruCycleStepped(.newer) retreats and wraps at 0")
    func mruCycleSteppedNewerRetreatsAndWrapsAt0() {
        // Intent: stepping newer retreats and wraps from 0 to last.
        // Why it exists: pins the reverse wrap rule.
        // Scenario: spec-first reverse wrap.
        let (m0, _) = Self.buildModelWithTabs(3)
        var model = m0
        _ = update(&model, .mruCycleStepped(direction: .older))
        _ = update(&model, .mruCycleStepped(direction: .older))
        #expect((model.mruCycle?.cursorIndex ?? -1) == 2)
        _ = update(&model, .mruCycleStepped(direction: .newer))
        #expect((model.mruCycle?.cursorIndex ?? -1) == 1)
        _ = update(&model, .mruCycleStepped(direction: .newer))
        #expect((model.mruCycle?.cursorIndex ?? -1) == 0)
        _ = update(&model, .mruCycleStepped(direction: .newer))
        #expect((model.mruCycle?.cursorIndex ?? -1) == 2, "wrapped past 0 to last")
    }

    @Test("single-tab MRU: stepping stays at index 0")
    func singleTabMruSteppingStaysAtIndex0() {
        // Intent: with one tab, stepping in either direction stays at
        //   index 0.
        // Why it exists: pins the degenerate-case loop.
        // Scenario: spec-first single tab cycle.
        let (m0, _) = Self.buildModelWithTabs(1)
        var model = m0
        _ = update(&model, .mruCycleStepped(direction: .older))
        #expect((model.mruCycle?.cursorIndex ?? -1) == 0)
        _ = update(&model, .mruCycleStepped(direction: .newer))
        #expect((model.mruCycle?.cursorIndex ?? -1) == 0)
    }

    @Test("mruCycleCommitted with cursorIndex > 0 selects the target and leads with it")
    func mruCycleCommittedWithCursorIndexGT0SelectsAndLeads() {
        // Intent: commit at a non-zero cursor selects the target, which then
        //   leads the next cycle's order.
        // Why it exists: pins the commit semantics.
        // Scenario: spec-first commit move.
        let (m0, _) = Self.buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId!

        _ = update(&model, .mruCycleStepped(direction: .older))
        guard let target = model.mruCycle?.frozenOrder.dropFirst().first else {
            Issue.record("expected frozenOrder to have at least 2 entries")
            return
        }
        #expect(target != initiallySelected)

        update(&model, .mruCycleCommitted)
        #expect(model.selectedTabId! == target, "target tab focused")
        #expect(model.mruCycle == nil, "cycle cleared")
        #expect(switcherOrder(of: model).first == target, "chosen tab is the most recent")
    }

    @Test("mruCycleCommitted at cursorIndex 0 is a focus no-op")
    func mruCycleCommittedAtCursorIndex0IsFocusNoOp() {
        // Intent: commit at index 0 keeps selection and clears the cycle.
        // Why it exists: pins the no-op-on-self-commit rule.
        // Scenario: spec-first self commit.
        let (m0, _) = Self.buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId!
        _ = update(&model, .mruCycleStepped(direction: .older))
        _ = update(&model, .mruCycleStepped(direction: .newer))
        #expect((model.mruCycle?.cursorIndex ?? -1) == 0)

        let commands = update(&model, .mruCycleCommitted)
        #expect(model.selectedTabId! == initiallySelected, "selection unchanged")
        #expect(model.mruCycle == nil, "cycle cleared -> reconcileSwitcher hides the panel")
        #expect(commands.isEmpty, "a no-op commit emits no commands")
    }

    @Test("mruCycleCanceled clears cycle without changing selection or order")
    func mruCycleCanceledClearsCycleWithoutChangingSelection() {
        // Intent: cancel clears the cycle, keeps the selection, and leaves the
        //   recency order as it was before the cycle started.
        // Why it exists: pins the cancel side effects.
        // Scenario: spec-first cancel.
        let (m0, _) = Self.buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId!
        let initialOrder = switcherOrder(of: model)
        _ = update(&model, .mruCycleStepped(direction: .older))
        _ = update(&model, .mruCycleStepped(direction: .older))

        let commands = update(&model, .mruCycleCanceled)
        #expect(model.selectedTabId! == initiallySelected, "selection unchanged")
        #expect(model.mruCycle == nil)
        #expect(switcherOrder(of: model) == initialOrder, "recency order unchanged")
        #expect(commands.isEmpty, "cancel emits no commands; mruCycle == nil -> reconcileSwitcher hides the panel")
    }

    @Test("mruCycleOneShot is equivalent to step + commit")
    func mruCycleOneShotIsEquivalentToStepCommit() {
        // Intent: mruCycleOneShot(.older) jumps to the next-older tab
        //   and does not leave a cycle behind.
        // Why it exists: pins the one-shot equivalence.
        // Scenario: spec-first one-shot.
        let (m0, _) = Self.buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId!
        guard let nextOlderTarget = switcherOrder(of: model).dropFirst().first else {
            Issue.record("expected at least 2 tabs in the switcher order")
            return
        }

        update(&model, .mruCycleOneShot(direction: .older))
        #expect(model.selectedTabId! == nextOlderTarget, "jumped to next-older tab")
        #expect(initiallySelected != nextOlderTarget)
        #expect(model.mruCycle == nil, "cycle does not linger")
    }

    @Test("tab removed during active cycle: commit selects a live tab")
    func tabRemovedDuringActiveCycleCommitSelectsLiveTab() {
        // Intent: if the cursor's frozen target is destroyed mid-cycle,
        //   commit lands on a live tab (resolveLiveCycle).
        // Why it exists: pins the live remap on commit.
        // Scenario: spec-first live remap.
        let (m0, ids) = Self.buildModelWithTabs(4)
        var model = m0
        _ = update(&model, .mruCycleStepped(direction: .older))
        _ = update(&model, .mruCycleStepped(direction: .older))
        guard let cycle = model.mruCycle, cycle.cursorIndex < cycle.frozenOrder.count else {
            Issue.record("cycle not in expected state")
            return
        }
        let cursorTarget = cycle.frozenOrder[cycle.cursorIndex]
        #expect(cursorTarget == ids[1])

        _ = update(&model, .closeTab(id: ids[1]))
        #expect(!model.groups[0].tabs.contains { $0.id == ids[1] }, "tab is gone")
        #expect(model.mruCycle != nil, "cycle still active (frozenOrder kept)")

        update(&model, .mruCycleCommitted)
        #expect(model.selectedTabId != nil)
        #expect(model.selectedTabId! != ids[1], "did not select the deleted tab")
        let live = Set(model.groups.flatMap(\.tabs).map(\.id))
        #expect(live.contains(model.selectedTabId!), "selection is live")
        #expect(model.mruCycle == nil)
    }

    @Test("a restored model with no focus history cycles selected-then-flattened")
    func restoredModelWithNoFocusHistoryCyclesSelectedThenFlattened() {
        // Intent: with no focus history at all, the switcher order is the
        //   selected tab followed by the remaining tabs in flattened order.
        // Why it exists: a restore brings back tabs nobody has focused this
        //   run, and the switcher must still offer every one of them in a
        //   stable order rather than an arbitrary one.
        // Scenario: spec-first restore; three tabs, the middle one selected.
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.selectedTabId = ids[1]

        _ = update(&model, .selectTab(id: ids[1]))
        #expect(switcherOrder(of: model) == [ids[1], ids[0], ids[2]])
    }
}
