// Tests for MRU tab switcher logic in update(). Covers the chokepoint
// reconcile behavior across all tab mutation paths plus the four cycle
// handlers (mruCycleStepped/Committed/Canceled/OneShot).

import Foundation

func updateMruTests() {
    print("Update MRU Tests...")

    // Build a model that has gone through update(.createTab) N times so mruOrder
    // is populated naturally. Returns ids in creation order; the last-created
    // tab is selectedTabId.
    func buildModelWithTabs(_ count: Int) -> (model: AppModel, tabIds: [TabId]) {
        var model = makeModel()
        var ids: [TabId] = []
        for _ in 0..<count {
            _ = update(&model, .createTab(inGroupId: nil))
            ids.append(model.selectedTabId!)
        }
        return (model, ids)
    }

    // MARK: - MRU invariants under existing handlers

    test("createTab populates mruOrder with the new tab") {
        var model = makeModel()
        _ = update(&model, .createTab(inGroupId: nil))
        let firstId = model.selectedTabId!
        try expectEqual(model.mruOrder.count, 1)
        try expect(model.mruOrder.first == firstId)

        _ = update(&model, .createTab(inGroupId: nil))
        let secondId = model.selectedTabId!
        try expectEqual(model.mruOrder.count, 2)
        try expect(model.mruOrder.first == secondId, "newly selected tab is hoisted to front")
        try expect(model.mruOrder.contains(firstId))
    }

    test("selectTab moves selected to mruOrder index 0 when not cycling") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0  // selected = ids[2]; mruOrder front = ids[2]

        _ = update(&model, .selectTab(id: ids[0]))
        try expect(model.mruOrder.first == ids[0], "ids[0] hoisted to front")
    }

    test("selectTab does NOT reorder mruOrder when cycling") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0
        let frozenSnapshot = model.mruOrder
        try expect(frozenSnapshot.count == 3, "preconditioned: 3 tabs in MRU")
        model.mruCycle = MruCycleState(frozenOrder: frozenSnapshot, cursorIndex: 1)

        _ = update(&model, .selectTab(id: ids[0]))
        try expectEqual(model.mruOrder, frozenSnapshot, "mruOrder must not change while cycling")
    }

    test("closeTab removes the tab from mruOrder") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0

        _ = update(&model, .closeTab(id: ids[1]))
        try expect(!model.mruOrder.contains(ids[1]), "closed tab pruned from mruOrder")
        try expect(model.mruOrder.contains(ids[0]) && model.mruOrder.contains(ids[2]))
    }

    test("paneBecameFirstResponder does not change mruOrder") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0
        let snapshot = model.mruOrder
        let focusedPane = model.groups[0].tabs.first { $0.id == ids[2] }!.focusedPaneId

        _ = update(&model, .paneBecameFirstResponder(paneId: focusedPane))
        try expectEqual(model.mruOrder, snapshot, "pane focus must not move tab in MRU")
    }

    // MARK: - Reconciliation across bypass paths

    test("movePaneToNewTab — new tab appears in mruOrder") {
        let (m0, _) = buildModelWithTabs(2)
        var model = m0
        let firstTab = model.groups[0].tabs[0]
        _ = update(&model, .selectTab(id: firstTab.id))
        _ = update(&model, .splitPane(paneId: nil, direction: .horizontal))
        let panes = allPaneIds(model.groups[0].tabs[0].rootNode)
        try expect(panes.count == 2, "split should produce 2 panes in source tab")
        let groupId = model.groups[0].id
        let countBefore = model.mruOrder.count

        _ = update(&model, .movePaneToNewTab(paneId: panes[1], inGroupId: groupId, atIndex: 0))
        let newTabId = model.selectedTabId!
        try expectEqual(model.mruOrder.count, countBefore + 1)
        try expect(model.mruOrder.contains(newTabId), "new tab id appears in mruOrder")
    }

    test("surfaceCreationFailed prunes the failed tab from mruOrder") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0
        let failedTabId = ids[1]
        let failedPaneId = model.groups[0].tabs.first { $0.id == failedTabId }!.focusedPaneId

        _ = update(&model, .surfaceCreationFailed(paneId: failedPaneId))
        try expect(!model.mruOrder.contains(failedTabId), "failed-tab id pruned")
    }

    test("deleteGroup(moveTabs: false) prunes deleted tab ids") {
        var model = makeModel()
        _ = update(&model, .createGroup(name: "Other"))
        let groups = model.groups
        _ = update(&model, .createTab(inGroupId: groups[0].id))
        let tabA = model.selectedTabId!
        _ = update(&model, .createTab(inGroupId: groups[1].id))
        let tabB = model.selectedTabId!
        try expect(model.mruOrder.contains(tabA) && model.mruOrder.contains(tabB))

        _ = update(&model, .deleteGroup(id: groups[1].id, moveTabs: false))
        try expect(!model.mruOrder.contains(tabB), "tabB pruned")
        try expect(model.mruOrder.contains(tabA), "tabA preserved")
    }

    test("deleteGroup(moveTabs: true) keeps moved tabs in mruOrder") {
        var model = makeModel()
        _ = update(&model, .createGroup(name: "Other"))
        let groups = model.groups
        _ = update(&model, .createTab(inGroupId: groups[0].id))
        let tabA = model.selectedTabId!
        _ = update(&model, .createTab(inGroupId: groups[1].id))
        let tabB = model.selectedTabId!

        _ = update(&model, .deleteGroup(id: groups[1].id, moveTabs: true))
        try expect(model.mruOrder.contains(tabA))
        try expect(model.mruOrder.contains(tabB), "moved tab still present")
    }

    // MARK: - Cycle handlers

    test("mruCycleStepped on empty mruOrder is a no-op") {
        var model = makeModel()
        try expect(model.mruOrder.isEmpty, "preconditioned: no tabs")

        let commands = update(&model, .mruCycleStepped(direction: .older))
        try expect(model.mruCycle == nil, "no cycle started")
        try expectEqual(commands.count, 0, "no commands emitted")
    }

    test("mruCycleStepped(.older) from idle starts cycle at cursorIndex 1") {
        let (m0, _) = buildModelWithTabs(3)
        var model = m0
        let snapshot = model.mruOrder

        let commands = update(&model, .mruCycleStepped(direction: .older))
        try expect(model.mruCycle != nil, "cycle started")
        try expectEqual(model.mruCycle?.frozenOrder ?? [], snapshot)
        try expectEqual(model.mruCycle?.cursorIndex ?? -1, 1)
        try expect(commands.isEmpty, "step emits no commands; the switcher reconciles from mruCycle")
    }

    test("mruCycleStepped(.newer) from idle wraps to last index") {
        let (m0, _) = buildModelWithTabs(4)
        var model = m0
        // Like cmd-shift-tab on macOS: summoning with the reverse direction
        // jumps straight to the least-recently-used tab.
        let commands = update(&model, .mruCycleStepped(direction: .newer))
        try expect(model.mruCycle != nil, "cycle started")
        try expectEqual(model.mruCycle?.cursorIndex ?? -1, 3, "wrapped to last index")
        try expect(commands.isEmpty, "step emits no commands; the switcher reconciles from mruCycle")
    }

    test("repeated mruCycleStepped(.older) advances and wraps") {
        let (m0, _) = buildModelWithTabs(3)
        var model = m0
        _ = update(&model, .mruCycleStepped(direction: .older))
        _ = update(&model, .mruCycleStepped(direction: .older))
        try expectEqual(model.mruCycle?.cursorIndex ?? -1, 2)
        // Past the end — wraps back to 0 (full Cmd-Tab parity).
        _ = update(&model, .mruCycleStepped(direction: .older))
        try expectEqual(model.mruCycle?.cursorIndex ?? -1, 0, "wrapped past last")
        _ = update(&model, .mruCycleStepped(direction: .older))
        try expectEqual(model.mruCycle?.cursorIndex ?? -1, 1)
    }

    test("mruCycleStepped(.newer) retreats and wraps at 0") {
        let (m0, _) = buildModelWithTabs(3)
        var model = m0
        _ = update(&model, .mruCycleStepped(direction: .older))
        _ = update(&model, .mruCycleStepped(direction: .older))
        try expectEqual(model.mruCycle?.cursorIndex ?? -1, 2)
        _ = update(&model, .mruCycleStepped(direction: .newer))
        try expectEqual(model.mruCycle?.cursorIndex ?? -1, 1)
        _ = update(&model, .mruCycleStepped(direction: .newer))
        try expectEqual(model.mruCycle?.cursorIndex ?? -1, 0)
        // Past 0 — wraps to last.
        _ = update(&model, .mruCycleStepped(direction: .newer))
        try expectEqual(model.mruCycle?.cursorIndex ?? -1, 2, "wrapped past 0 to last")
    }

    test("single-tab MRU: stepping stays at index 0") {
        let (m0, _) = buildModelWithTabs(1)
        var model = m0
        _ = update(&model, .mruCycleStepped(direction: .older))
        try expectEqual(model.mruCycle?.cursorIndex ?? -1, 0)
        _ = update(&model, .mruCycleStepped(direction: .newer))
        try expectEqual(model.mruCycle?.cursorIndex ?? -1, 0)
    }

    test("mruCycleCommitted with cursorIndex > 0 selects target and reorders MRU") {
        let (m0, _) = buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId!

        _ = update(&model, .mruCycleStepped(direction: .older))
        guard let target = model.mruCycle?.frozenOrder.dropFirst().first else {
            throw TestFailure(message: "expected frozenOrder to have at least 2 entries")
        }
        try expect(target != initiallySelected)

        let commands = update(&model, .mruCycleCommitted)
        try expectEqual(model.selectedTabId!, target, "target tab focused")
        try expect(model.mruCycle == nil, "cycle cleared")
        try expect(model.mruOrder.first == target, "chosen tab hoisted to MRU front")
        // The switcher hides structurally (mruCycle == nil -> reconcileSwitcher) and the
        // tab switch is structural too (reconcileContainers); the commit persists selection.
        try expect(hasEffect(commands) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "commit persists the new selection via scheduleCheckpoint")
    }

    test("mruCycleCommitted at cursorIndex 0 is a focus no-op") {
        let (m0, _) = buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId!
        _ = update(&model, .mruCycleStepped(direction: .older))
        _ = update(&model, .mruCycleStepped(direction: .newer))
        try expectEqual(model.mruCycle?.cursorIndex ?? -1, 0)

        let commands = update(&model, .mruCycleCommitted)
        try expectEqual(model.selectedTabId!, initiallySelected, "selection unchanged")
        try expect(model.mruCycle == nil, "cycle cleared -> reconcileSwitcher hides the panel")
        try expect(commands.isEmpty, "a no-op commit emits no commands")
    }

    test("mruCycleCanceled clears cycle without changing selection") {
        let (m0, _) = buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId!
        let initialMru = model.mruOrder
        _ = update(&model, .mruCycleStepped(direction: .older))
        _ = update(&model, .mruCycleStepped(direction: .older))

        let commands = update(&model, .mruCycleCanceled)
        try expectEqual(model.selectedTabId!, initiallySelected, "selection unchanged")
        try expect(model.mruCycle == nil)
        try expectEqual(model.mruOrder, initialMru, "mruOrder unchanged")
        try expect(commands.isEmpty, "cancel emits no commands; mruCycle == nil -> reconcileSwitcher hides the panel")
    }

    test("mruCycleOneShot is equivalent to step + commit") {
        let (m0, _) = buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId!
        guard let nextOlderTarget = model.mruOrder.dropFirst().first else {
            throw TestFailure(message: "expected at least 2 tabs in MRU")
        }

        let commands = update(&model, .mruCycleOneShot(direction: .older))
        try expectEqual(model.selectedTabId!, nextOlderTarget, "jumped to next-older tab")
        try expect(initiallySelected != nextOlderTarget)
        try expect(model.mruCycle == nil, "cycle does not linger")
        try expect(hasEffect(commands) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "commits the selection (persists via scheduleCheckpoint); the switcher hides via reconcile")
    }

    test("tab removed during active cycle: commit selects a live tab") {
        let (m0, ids) = buildModelWithTabs(4)
        var model = m0
        _ = update(&model, .mruCycleStepped(direction: .older))
        _ = update(&model, .mruCycleStepped(direction: .older))
        guard let cycle = model.mruCycle, cycle.cursorIndex < cycle.frozenOrder.count else {
            throw TestFailure(message: "cycle not in expected state")
        }
        let cursorTarget = cycle.frozenOrder[cycle.cursorIndex]
        try expectEqual(cursorTarget, ids[1])

        // Remove the cursor-target tab while cycling.
        _ = update(&model, .closeTab(id: ids[1]))
        try expect(!model.groups[0].tabs.contains { $0.id == ids[1] }, "tab is gone")
        try expect(model.mruCycle != nil, "cycle still active (frozenOrder kept)")

        let commands = update(&model, .mruCycleCommitted)
        try expect(model.selectedTabId != nil)
        try expect(model.selectedTabId! != ids[1], "did not select the deleted tab")
        let live = Set(model.groups.flatMap(\.tabs).map(\.id))
        try expect(live.contains(model.selectedTabId!), "selection is live")
        try expect(model.mruCycle == nil)
        try expect(hasEffect(commands) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "commits a live tab (persists via scheduleCheckpoint); the switcher hides via reconcile")
    }

    test("restore-time reconciliation: empty mruOrder fills on next update()") {
        // Mimic post-commitRestoreSession state: tabs exist, mruOrder is empty.
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        model.selectedTabId = ids[1]
        model.mruOrder = []

        // Any update() pass triggers the defer reconcile.
        _ = update(&model, .selectTab(id: ids[1]))  // self-select; reconciles via defer
        try expectEqual(model.mruOrder.count, 3)
        try expect(model.mruOrder.first == ids[1], "selected hoisted to front")
        try expect(Set(model.mruOrder) == Set(ids))
    }
}
