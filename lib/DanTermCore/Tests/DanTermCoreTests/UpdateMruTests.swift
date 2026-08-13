// Swift Testing migration of the legacy `tests/UpdateMruTests.swift` harness
// suite. Pins MRU tab switcher behavior: the per-Msg mruOrder invariants
// (createTab inserts at the front, selectTab hoists when not cycling and
// freezes while cycling, closeTab + sessionCreationFailed + deleteGroup
// reconcile), the bypass-path coverage via movePaneToNewTab, and the four
// cycle handlers (mruCycleStepped / Committed / Canceled / OneShot) plus
// the restore-time reconciliation defer. The two `guard let ... else { throw }`
// unwraps over a `frozenOrder` first-element and an `mruCycle` snapshot
// convert to `Issue.record + return` because both bindings use guarded
// chained expressions (`.dropFirst().first` / `cycle.cursorIndex <
// cycle.frozenOrder.count`) that `#require` cannot pin down.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateMruTests {
    /// Build a model that has gone through update(.createTab) N times so mruOrder
    /// is populated naturally. Returns ids in creation order; the last-created
    /// tab is selectedTabId.
    static func buildModelWithTabs(_ count: Int) -> (model: AppModel, tabIds: [TabId]) {
        var model = makeModel()
        var ids: [TabId] = []
        for _ in 0..<count {
            _ = update(&model, .createTabInSelectedGroup())
            ids.append(model.selectedTabId!)
        }
        return (model, ids)
    }

    // MARK: - MRU invariants under existing handlers

    @Test("createTab populates mruOrder with the new tab")
    func createTabPopulatesMruOrderWithNewTab() {
        // Intent: createTab inserts the new tab at mruOrder front and
        //   re-hoists each subsequent createTab.
        // Why it exists: pins the MRU insertion contract.
        // Scenario: spec-first createTab MRU.
        var model = makeModel()
        _ = update(&model, .createTabInSelectedGroup())
        let firstId = model.selectedTabId!
        #expect(model.mruOrder.count == 1)
        #expect(model.mruOrder.first == firstId)

        _ = update(&model, .createTabInSelectedGroup())
        let secondId = model.selectedTabId!
        #expect(model.mruOrder.count == 2)
        #expect(model.mruOrder.first == secondId, "newly selected tab is hoisted to front")
        #expect(model.mruOrder.contains(firstId))
    }

    @Test("selectTab moves selected to mruOrder index 0 when not cycling")
    func selectTabHoistsWhenNotCycling() {
        // Intent: selectTab outside a cycle hoists the selected tab to
        //   mruOrder index 0.
        // Why it exists: pins the per-selection hoist.
        // Scenario: spec-first hoist.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0

        _ = update(&model, .selectTab(id: ids[0]))
        #expect(model.mruOrder.first == ids[0], "ids[0] hoisted to front")
    }

    @Test("selectTab does NOT reorder mruOrder when cycling")
    func selectTabDoesNotReorderWhileCycling() {
        // Intent: selectTab during an active cycle freezes mruOrder.
        // Why it exists: pins the freeze invariant the cycle relies on.
        // Scenario: spec-first cycle freeze.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0
        let frozenSnapshot = model.mruOrder
        #expect(frozenSnapshot.count == 3, "preconditioned: 3 tabs in MRU")
        model.mruCycle = MruCycleState(frozenOrder: frozenSnapshot, cursorIndex: 1)

        _ = update(&model, .selectTab(id: ids[0]))
        #expect(model.mruOrder == frozenSnapshot, "mruOrder must not change while cycling")
    }

    @Test("closeTab removes the tab from mruOrder")
    func closeTabRemovesTabFromMruOrder() {
        // Intent: closeTab prunes its id from mruOrder.
        // Why it exists: pins the per-tab MRU prune.
        // Scenario: spec-first close prune.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0

        _ = update(&model, .closeTab(id: ids[1]))
        #expect(!model.mruOrder.contains(ids[1]), "closed tab pruned from mruOrder")
        #expect(model.mruOrder.contains(ids[0]) && model.mruOrder.contains(ids[2]))
    }

    @Test("paneBecameFirstResponder does not change mruOrder")
    func paneBecameFirstResponderDoesNotChangeMruOrder() {
        // Intent: pane focus changes do NOT touch mruOrder.
        // Why it exists: pins the per-pane scope (tab focus is the MRU
        //   trigger, not pane focus).
        // Scenario: spec-first pane-focus no MRU change.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0
        let snapshot = model.mruOrder
        let focusedPane = model.groups[0].tabs.first { $0.id == ids[2] }!.paneTree.focusedPaneId

        _ = update(&model, .paneBecameFirstResponder(paneId: focusedPane))
        #expect(model.mruOrder == snapshot, "pane focus must not move tab in MRU")
    }

    // MARK: - Reconciliation across bypass paths

    @Test("movePaneToNewTab — new tab appears in mruOrder")
    func movePaneToNewTabAppearsInMruOrder() {
        // Intent: a movePaneToNewTab adds the new tab id to mruOrder.
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
        let countBefore = model.mruOrder.count

        _ = update(&model, .movePaneToNewTab(paneId: panes[1], inGroupId: groupId, atIndex: 0))
        let newTabId = model.selectedTabId!
        #expect(model.mruOrder.count == countBefore + 1)
        #expect(model.mruOrder.contains(newTabId), "new tab id appears in mruOrder")
    }

    @Test("sessionCreationFailed prunes the failed tab from mruOrder")
    func sessionCreationFailedPrunesFailedTabFromMruOrder() {
        // Intent: sessionCreationFailed removes the failed tab from
        //   mruOrder.
        // Why it exists: pins the failure-path MRU prune.
        // Scenario: spec-first failure prune.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0
        let failedTabId = ids[1]
        let failedPaneId = model.groups[0].tabs.first { $0.id == failedTabId }!.paneTree.focusedPaneId

        let sessionId = model.pane(failedPaneId)!.session!.id
        _ = update(&model, .sessionCreationFailed(sessionId: sessionId))
        #expect(!model.mruOrder.contains(failedTabId), "failed-tab id pruned")
    }

    @Test("deleteGroup(moveTabs: false) prunes deleted tab ids")
    func deleteGroupMoveTabsFalsePrunesDeletedTabIds() {
        // Intent: deleteGroup(moveTabs: false) prunes destroyed tab ids
        //   from mruOrder.
        // Why it exists: pins the per-group MRU prune.
        // Scenario: spec-first deleteGroup destructive MRU prune.
        var model = makeModel()
        _ = update(&model, .createGroup(name: "Other"))
        let groups = model.groups
        _ = update(&model, .createTab(inGroupId: groups[0].id))
        let tabA = model.selectedTabId!
        _ = update(&model, .createTab(inGroupId: groups[1].id))
        let tabB = model.selectedTabId!
        #expect(model.mruOrder.contains(tabA) && model.mruOrder.contains(tabB))

        _ = update(&model, .deleteGroup(id: groups[1].id, moveTabs: false))
        #expect(!model.mruOrder.contains(tabB), "tabB pruned")
        #expect(model.mruOrder.contains(tabA), "tabA preserved")
    }

    @Test("deleteGroup(moveTabs: true) keeps moved tabs in mruOrder")
    func deleteGroupMoveTabsTrueKeepsMovedTabsInMruOrder() {
        // Intent: deleteGroup(moveTabs: true) preserves the moved tab in
        //   mruOrder.
        // Why it exists: pins the moveTabs branch MRU preservation.
        // Scenario: spec-first deleteGroup move MRU.
        var model = makeModel()
        _ = update(&model, .createGroup(name: "Other"))
        let groups = model.groups
        _ = update(&model, .createTab(inGroupId: groups[0].id))
        let tabA = model.selectedTabId!
        _ = update(&model, .createTab(inGroupId: groups[1].id))
        let tabB = model.selectedTabId!

        _ = update(&model, .deleteGroup(id: groups[1].id, moveTabs: true))
        #expect(model.mruOrder.contains(tabA))
        #expect(model.mruOrder.contains(tabB), "moved tab still present")
    }

    // MARK: - Cycle handlers

    @Test("mruCycleStepped on empty mruOrder is a no-op")
    func mruCycleSteppedOnEmptyMruOrderNoOp() {
        // Intent: mruCycleStepped on an empty mruOrder is a no-op.
        // Why it exists: pins the empty-state guard.
        // Scenario: spec-first empty MRU step.
        var model = makeModel()
        #expect(model.mruOrder.isEmpty, "preconditioned: no tabs")

        let commands = update(&model, .mruCycleStepped(direction: .older))
        #expect(model.mruCycle == nil, "no cycle started")
        #expect(commands.count == 0, "no commands emitted")
    }

    @Test("mruCycleStepped(.older) from idle starts cycle at cursorIndex 1")
    func mruCycleSteppedOlderFromIdleStartsAtIndex1() {
        // Intent: stepping older from idle starts a cycle with cursor at
        //   index 1 and frozenOrder == current mruOrder.
        // Why it exists: pins the cycle-start contract.
        // Scenario: spec-first start step.
        let (m0, _) = Self.buildModelWithTabs(3)
        var model = m0
        let snapshot = model.mruOrder

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

    @Test("mruCycleCommitted with cursorIndex > 0 selects target and reorders MRU")
    func mruCycleCommittedWithCursorIndexGT0SelectsAndReorders() {
        // Intent: commit at a non-zero cursor selects the target and hoists it.
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
        #expect(model.mruOrder.first == target, "chosen tab hoisted to MRU front")
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

    @Test("mruCycleCanceled clears cycle without changing selection")
    func mruCycleCanceledClearsCycleWithoutChangingSelection() {
        // Intent: cancel clears the cycle, keeps the selection, and
        //   leaves mruOrder frozen.
        // Why it exists: pins the cancel side effects.
        // Scenario: spec-first cancel.
        let (m0, _) = Self.buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId!
        let initialMru = model.mruOrder
        _ = update(&model, .mruCycleStepped(direction: .older))
        _ = update(&model, .mruCycleStepped(direction: .older))

        let commands = update(&model, .mruCycleCanceled)
        #expect(model.selectedTabId! == initiallySelected, "selection unchanged")
        #expect(model.mruCycle == nil)
        #expect(model.mruOrder == initialMru, "mruOrder unchanged")
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
        guard let nextOlderTarget = model.mruOrder.dropFirst().first else {
            Issue.record("expected at least 2 tabs in MRU")
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

    @Test("restore-time reconciliation: empty mruOrder fills on next update()")
    func restoreTimeReconciliationEmptyMruOrderFills() {
        // Intent: after restore, an empty mruOrder is filled on the next
        //   update() call (selected tab hoisted, all live tabs present).
        // Why it exists: pins the defer reconcile.
        // Scenario: spec-first restore reconcile.
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.selectedTabId = ids[1]
        model.mruOrder = []

        _ = update(&model, .selectTab(id: ids[1]))
        #expect(model.mruOrder.count == 3)
        #expect(model.mruOrder.first == ids[1], "selected hoisted to front")
        #expect(Set(model.mruOrder) == Set(ids))
    }
}
