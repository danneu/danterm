import Foundation

func tabTests() {
    print("Tab Tests...")

    test("testCreateTabAddsToDefaultGroup") {
        var model = makeModel()
        let effects = createTab(&model)

        try expectEqual(model.groups[0].tabs.count, 1)
        try expectEqual(model.panes.count, 1)
        try expect(model.selectedTabId == model.groups[0].tabs[0].id)
        try expect(hasEffect(effects) {
            if case .createSurface = $0 { return true }
            return false
        }, "should emit createSurface")
        try expect(hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should emit rebuildContentView")
    }

    test("testCreateTabInheritsWorkingDirectory") {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = model.groups[0].tabs[0].focusedPaneId
        model.panes[firstPaneId]?.cwd = "/tmp/test"

        let effects = createTab(&model)
        let createEffect = effects.first(where: {
            if case .createSurface = $0 { return true }
            return false
        })
        try expect(createEffect != nil, "should have createSurface effect")
        if case .createSurface(_, let cwd, _) = createEffect! {
            try expectEqual(cwd, "/tmp/test", "cwd should inherit")
        }
    }

    test("testSelectTabDefocusesOldPanes") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id

        createTab(&model)

        let effects = update(&model, .selectTab(id: firstTabId))

        let secondPaneId = model.groups[0].tabs[1].focusedPaneId
        try expect(hasEffect(effects) {
            if case .focusSurface(let pid, false) = $0, pid == secondPaneId { return true }
            return false
        }, "should defocus second tab's pane")
        try expectEqual(model.selectedTabId, firstTabId)
    }

    test("testSelectTabClearsBell") {
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        createTab(&model)
        let tabBId = model.groups[0].tabs[1].id
        let tabBPaneId = model.groups[0].tabs[1].focusedPaneId

        // Select tab A so tab B's pane is in the background
        update(&model, .selectTab(id: tabAId))

        // Set bell on background tab's pane via production path
        update(&model, .surfaceBell(paneId: tabBPaneId))
        try expect(model.alerts.contains { $0.paneId == tabBPaneId && $0.isUnread }, "should have unread alert on background pane")

        // Select tab B — alert should be marked read
        update(&model, .selectTab(id: tabBId))
        try expect(!model.alerts.contains { $0.paneId == tabBPaneId && $0.isUnread }, "selecting tab should mark alerts read")
    }

    test("testCloseLastPaneShowsConfirmation") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .closePane(paneId: paneId))
        try expectEqual(effects.count, 1)
        try expect(hasEffect(effects) {
            if case .showTerminateConfirmation(let count) = $0, count == 1 { return true }
            return false
        }, "should show confirmation when closing last pane")
        try expect(model.pendingConfirmation == .terminate, "quit confirmation should be pending")
        try expectEqual(model.groups[0].tabs.count, 1, "model should be unchanged")
        try expect(model.panes[paneId] != nil, "pane should still exist")
    }

    test("testCloseLastTabShowsConfirmation") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let effects = update(&model, .closeTab(id: tabId))
        try expectEqual(effects.count, 1)
        try expect(hasEffect(effects) {
            if case .showTerminateConfirmation(let count) = $0, count == 1 { return true }
            return false
        }, "should show confirmation when closing last tab")
        try expect(model.pendingConfirmation == .terminate, "quit confirmation should be pending")
        try expectEqual(model.groups[0].tabs.count, 1, "model should be unchanged")
    }

    test("testCreateTabInSpecificGroup") {
        var model = makeModel()
        let _ = update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id

        createTab(&model, inGroupId: workGroupId)

        try expectEqual(model.groups[0].tabs.count, 0, "General should have no tabs")
        try expectEqual(model.groups[1].tabs.count, 2, "Work should have auto-created tab + explicit tab")
    }

    test("testCreateTabInsertsAfterCurrentTab") {
        var model = makeModel()
        createTab(&model) // tab A
        createTab(&model) // tab B (inserted after A)
        createTab(&model) // tab C (inserted after B)
        let tabAId = model.groups[0].tabs[0].id
        let tabBId = model.groups[0].tabs[1].id
        let tabCId = model.groups[0].tabs[2].id

        // Select tab A, then create a new tab — should insert after A, not at end
        update(&model, .selectTab(id: tabAId))
        createTab(&model) // tab D
        let tabDId = model.groups[0].tabs[1].id

        try expectEqual(model.groups[0].tabs.count, 4)
        try expectEqual(model.groups[0].tabs[0].id, tabAId, "tab A should be first")
        try expectEqual(model.groups[0].tabs[1].id, tabDId, "new tab D should be after A")
        try expectEqual(model.groups[0].tabs[2].id, tabBId, "tab B should shift right")
        try expectEqual(model.groups[0].tabs[3].id, tabCId, "tab C should shift right")
    }

    test("testCreateTabAtGroupEndAppendsRegardlessOfSelection") {
        var model = makeModel()
        createTab(&model) // tab A
        createTab(&model) // tab B
        createTab(&model) // tab C
        let tabAId = model.groups[0].tabs[0].id
        let tabBId = model.groups[0].tabs[1].id
        let tabCId = model.groups[0].tabs[2].id

        // Select the middle tab — atGroupEnd must still append, not insert after B.
        update(&model, .selectTab(id: tabBId))
        update(&model, .createTab(inGroupId: nil, position: .atGroupEnd))
        let tabDId = model.groups[0].tabs[3].id

        try expectEqual(model.groups[0].tabs.count, 4)
        try expectEqual(model.groups[0].tabs[0].id, tabAId, "tab A stays first")
        try expectEqual(model.groups[0].tabs[1].id, tabBId, "tab B keeps its slot")
        try expectEqual(model.groups[0].tabs[2].id, tabCId, "tab C keeps its slot")
        try expectEqual(model.groups[0].tabs[3].id, tabDId, "new tab lands at end")
        try expectEqual(model.selectedTabId, tabDId, "newly created tab is selected")
    }

    test("testCreateTabAtGroupEndUsesSelectedTabsGroupWhenNoneSpecified") {
        var model = makeModel()
        // makeModel() leaves the default "General" group empty.
        // createGroup auto-creates a tab in the new group, so Work begins
        // with one tab; add two more so we can pick a non-tail selection.
        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        update(&model, .createTab(inGroupId: workGroupId))
        update(&model, .createTab(inGroupId: workGroupId))
        let workTab1 = model.groups[1].tabs[0].id
        let workTab2 = model.groups[1].tabs[1].id

        // Select the middle Work tab. atGroupEnd with inGroupId: nil should
        // resolve to "the selected tab's group" and append there.
        update(&model, .selectTab(id: workTab2))
        update(&model, .createTab(inGroupId: nil, position: .atGroupEnd))

        try expectEqual(model.groups[0].tabs.count, 0, "default group untouched")
        try expectEqual(model.groups[1].tabs.count, 4, "work group grows by one")
        try expectEqual(model.groups[1].tabs[0].id, workTab1, "first work tab unchanged")
        try expectEqual(model.groups[1].tabs[1].id, workTab2, "selected work tab unchanged")
        try expectEqual(model.groups[1].tabs.last?.id, model.selectedTabId, "new tab is last and selected")
    }

    test("testSelectTabAlreadySelected") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let effects = update(&model, .selectTab(id: tabId))
        try expectEqual(effects.count, 0, "selecting already-selected tab should return no effects")
    }

    // MARK: - Adjacent Tab Navigation

    test("testNextTabWithinSameGroup") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: firstTabId))

        let effects = update(&model, .selectAdjacentTab(direction: .next))
        try expectEqual(model.selectedTabId, secondTabId)
        try expect(effects.count > 0, "should have effects")
    }

    test("testPrevTabWithinSameGroup") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: secondTabId))

        let effects = update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(model.selectedTabId, firstTabId)
        try expect(effects.count > 0, "should have effects")
    }

    test("testNextTabAcrossGroups") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let secondTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: firstTabId))

        let effects = update(&model, .selectAdjacentTab(direction: .next))
        try expectEqual(model.selectedTabId, secondTabId)
        try expect(effects.count > 0, "should have effects")
    }

    test("testPrevTabAcrossGroups") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let secondTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: secondTabId))

        let effects = update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(model.selectedTabId, firstTabId)
        try expect(effects.count > 0, "should have effects")
    }

    test("testNextTabNoOpWithSingleTab") {
        var model = makeModel()
        createTab(&model)
        let lastTabId = model.groups[0].tabs[0].id

        let effects = update(&model, .selectAdjacentTab(direction: .next))
        try expectEqual(effects.count, 0, "wrap to self should be no-op")
        try expectEqual(model.selectedTabId, lastTabId)
    }

    test("testPrevTabNoOpWithSingleTab") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id

        let effects = update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(effects.count, 0, "wrap to self should be no-op")
        try expectEqual(model.selectedTabId, firstTabId)
    }

    test("testNextTabWrapsFromLastToFirst") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let lastTabId  = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: lastTabId))

        let effects = update(&model, .selectAdjacentTab(direction: .next))
        try expectEqual(model.selectedTabId, firstTabId)
        try expect(effects.count > 0, "should have effects")
    }

    test("testPrevTabWrapsFromFirstToLast") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let lastTabId  = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: firstTabId))

        let effects = update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(model.selectedTabId, lastTabId)
        try expect(effects.count > 0, "should have effects")
    }

    test("testNextTabWrapsAcrossGroups") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let lastTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: lastTabId))

        update(&model, .selectAdjacentTab(direction: .next))
        try expectEqual(model.selectedTabId, firstTabId)
    }

    test("testPrevTabWrapsAcrossGroups") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let lastTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: firstTabId))

        update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(model.selectedTabId, lastTabId)
    }

    // Locks in the "collapsed groups are not skipped" non-goal of the wrap
    // change: prev/next must still reach into collapsed groups, matching the
    // existing non-wrap navigation policy.
    test("testPrevTabWrapsIntoCollapsedGroup") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let collapsedGroupId = model.groups[1].id
        let lastTabId = model.groups[1].tabs[0].id
        update(&model, .toggleGroupCollapse(groupId: collapsedGroupId))
        update(&model, .selectTab(id: firstTabId))

        update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(model.selectedTabId, lastTabId,
            "wrap should reach tabs in collapsed groups")
    }

    test("testNextTabNoOpWithNoTabs") {
        var model = makeModel()
        let effects = update(&model, .selectAdjacentTab(direction: .next))
        try expectEqual(effects.count, 0)
    }

    test("testPrevTabNoOpWithNoTabs") {
        var model = makeModel()
        let effects = update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(effects.count, 0)
    }

    // MARK: - requestCloseTab

    test("testRequestCloseTabSinglePaneClosesDirectly") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id

        let effects = update(&model, .requestCloseTab(id: firstTabId))
        try expectEqual(model.groups[0].tabs.count, 1, "tab should be removed")
        try expect(hasEffect(effects) {
            if case .destroySurface = $0 { return true }
            return false
        }, "should emit destroySurface")
        try expect(!hasEffect(effects) {
            if case .showCloseTabConfirmation = $0 { return true }
            return false
        }, "should not show confirmation for single-pane tab")
    }

    test("testRequestCloseTabMultiPaneShowsConfirmation") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))

        // Split to get 2 panes
        update(&model, .splitPane(direction: .horizontal))

        let effects = update(&model, .requestCloseTab(id: firstTabId))
        try expectEqual(model.groups[0].tabs.count, 2, "tab should NOT be removed yet")
        try expect(hasEffect(effects) {
            if case .showCloseTabConfirmation(let tid, _, let count, let last) = $0 {
                return tid == firstTabId && count == 2 && !last
            }
            return false
        }, "should show confirmation with correct args")
        try expect(model.pendingConfirmation == .closeTab, "close-tab confirmation should be pending")
    }

    test("testRequestCloseTabMultiPaneSetsPending") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitPane(direction: .horizontal))

        let effects = update(&model, .requestCloseTab(id: firstTabId))

        try expectEqual(effects.count, 1)
        if case .showCloseTabConfirmation = effects[0] {
            // good
        } else {
            throw TestFailure(message: "expected showCloseTabConfirmation")
        }
        try expect(model.pendingConfirmation == .closeTab, "close-tab confirmation should be pending")
    }

    test("testRequestCloseTabWhileCloseTabPendingIsNoOp") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitPane(direction: .horizontal))
        model.pendingConfirmation = .closeTab

        let effects = update(&model, .requestCloseTab(id: firstTabId))

        try expectEqual(effects.count, 0, "requestCloseTab should be blocked by pending close-tab confirmation")
    }

    test("testRequestCloseTabWhileQuitPendingIsNoOp") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitPane(direction: .horizontal))
        model.pendingConfirmation = .terminate

        let effects = update(&model, .requestCloseTab(id: firstTabId))

        try expectEqual(effects.count, 0, "requestCloseTab should be blocked by pending quit confirmation")
        try expect(!hasEffect(effects) {
            if case .showCloseTabConfirmation = $0 { return true }
            return false
        }, "should not emit close-tab confirmation")
    }

    test("testConfirmCloseTabClearsPendingAndDispatches") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitPane(direction: .horizontal))
        let paneIds = paneIdsForTab(firstTabId, in: model)
        model.pendingConfirmation = .closeTab

        let effects = update(&model, .confirmCloseTab(id: firstTabId))

        try expect(model.pendingConfirmation == nil, "confirm should clear pending confirmation")
        try expect(!model.groups[0].tabs.contains { $0.id == firstTabId }, "tab should be removed")
        for paneId in paneIds {
            try expect(hasEffect(effects) {
                if case .destroySurface(let pid) = $0, pid == paneId { return true }
                return false
            }, "should destroy each pane in the tab")
        }
    }

    test("testConfirmCloseTabLastMultiPaneRoutesToTerminate") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .splitPane(direction: .horizontal))
        let paneIds = paneIdsForTab(tabId, in: model)
        model.pendingConfirmation = .closeTab

        let effects = update(&model, .confirmCloseTab(id: tabId))

        try expectEqual(effects.count, 1)
        if case .showTerminateConfirmation = effects[0] {
            // good
        } else {
            throw TestFailure(message: "expected showTerminateConfirmation")
        }
        for paneId in paneIds {
            try expect(!hasEffect(effects) {
                if case .destroySurface(let pid) = $0, pid == paneId { return true }
                return false
            }, "should not destroy panes before quit confirmation")
            try expect(model.panes[paneId] != nil, "pane should still exist")
        }
        try expect(model.groups[0].tabs.contains { $0.id == tabId }, "tab should still exist")
        try expect(model.pendingConfirmation == .terminate, "quit confirmation should be pending")
    }

    test("testCancelCloseTabClearsPending") {
        var model = makeModel()
        createTab(&model)
        model.pendingConfirmation = .closeTab

        let effects = update(&model, .cancelCloseTab)

        try expectEqual(effects.count, 0, "cancel should produce no effects")
        try expect(model.pendingConfirmation == nil, "cancel should clear pending confirmation")
    }

    test("testRequestCloseTabSinglePaneLastTabShowsTerminateConfirmation") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let effects = update(&model, .requestCloseTab(id: tabId))
        try expectEqual(model.groups[0].tabs.count, 1, "tab should NOT be removed")
        try expect(hasEffect(effects) {
            if case .showTerminateConfirmation(let count) = $0, count == 1 { return true }
            return false
        }, "should show terminate confirmation for last single-pane tab")
        try expect(model.pendingConfirmation == .terminate, "quit confirmation should be pending")
    }

    // MARK: - Tab Color

    test("testSetTabColor") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let effects = update(&model, .setTabColors(tabIds: [tabId], color: .red))
        try expectEqual(model.groups[0].tabs[0].color, .red)
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0, tid == tabId { return true }
            return false
        }, "should emit updateSidebarTabRow")
    }

    test("testSetTabColorClear") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .setTabColors(tabIds: [tabId], color: .blue))

        let effects = update(&model, .setTabColors(tabIds: [tabId], color: nil))
        try expect(model.groups[0].tabs[0].color == nil, "color should be nil")
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0, tid == tabId { return true }
            return false
        }, "should emit updateSidebarTabRow")
    }

    test("testSetTabColorReplaceDifferent") {
        // Setting a different color replaces. Toggle-off (re-apply clears)
        // is no longer Msg-layer behavior; see resolveColorForBatch tests.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .setTabColors(tabIds: [tabId], color: .red))

        update(&model, .setTabColors(tabIds: [tabId], color: .blue))
        try expectEqual(model.groups[0].tabs[0].color, .blue)
    }

    test("testCloseTabNonSelected") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id

        createTab(&model)
        let secondTabId = model.groups[0].tabs[1].id
        // secondTabId is now selected

        let effects = update(&model, .closeTab(id: firstTabId))
        try expectEqual(model.selectedTabId, secondTabId, "selection should remain on second tab")
        try expectEqual(model.groups[0].tabs.count, 1)
        // Should not have rebuildContentView since we didn't close the selected tab
        try expect(!hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should not rebuild content view when closing non-selected tab")
    }

    // MARK: - Close Tab Selects Previous

    test("testCloseMiddleTabSelectsPrevious") {
        var model = makeModel()
        createTab(&model) // tab A
        createTab(&model) // tab B
        createTab(&model) // tab C
        let tabAId = model.groups[0].tabs[0].id
        let tabBId = model.groups[0].tabs[1].id

        // Select tab B (middle), then close it
        update(&model, .selectTab(id: tabBId))
        update(&model, .closeTab(id: tabBId))

        try expectEqual(model.selectedTabId, tabAId, "closing middle tab should select predecessor")
        try expectEqual(model.groups[0].tabs.count, 2)
    }

    test("testCloseFirstTabSelectsNext") {
        var model = makeModel()
        createTab(&model) // tab A
        createTab(&model) // tab B
        let tabAId = model.groups[0].tabs[0].id
        let tabBId = model.groups[0].tabs[1].id

        // Select tab A (first), then close it
        update(&model, .selectTab(id: tabAId))
        update(&model, .closeTab(id: tabAId))

        try expectEqual(model.selectedTabId, tabBId, "closing first tab should select successor")
        try expectEqual(model.groups[0].tabs.count, 1)
    }

    test("testCloseTabCrossGroupSelectsPrevious") {
        var model = makeModel()
        // General group gets tab A
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id

        // Create Work group (auto-creates tab B)
        update(&model, .createGroup(name: "Work"))
        let tabBId = model.groups[1].tabs[0].id

        // Select tab B (in Work group), then close it
        update(&model, .selectTab(id: tabBId))
        update(&model, .closeTab(id: tabBId))

        // Work group should be pruned (was its only tab), selection goes to tab A
        try expectEqual(model.groups.count, 1, "Work group should be pruned")
        try expectEqual(model.selectedTabId, tabAId, "should select predecessor across group boundary")
    }

    // MARK: - setTabColors (batch from multi-select context menu)

    test("testSetTabColorsAppliesToAll") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)

        update(&model, .setTabColors(tabIds: ids, color: .blue))

        try expect(model.groups[0].tabs.allSatisfy { $0.color == .blue },
            "every selected tab gets the new color")
    }

    test("testSetTabColorsAlwaysReplaces") {
        // The Msg layer always replaces, never toggles. Toggle-off
        // (re-apply same color clears) is dispatcher-side UX via
        // resolveColorForBatch -- not part of .setTabColors semantics.
        var model = makeModel()
        createTab(&model) // tab1 -- gets red below
        createTab(&model) // tab2 -- stays uncolored
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        update(&model, .setTabColors(tabIds: [id1], color: .red))
        try expectEqual(model.groups[0].tabs[0].color, .red)

        // Re-apply red to both via batch -- both end up red.
        update(&model, .setTabColors(tabIds: [id1, id2], color: .red))
        try expectEqual(model.groups[0].tabs[0].color, .red)
        try expectEqual(model.groups[0].tabs[1].color, .red)
    }

    test("testSetTabColorsClearsWithNil") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)
        update(&model, .setTabColors(tabIds: ids, color: .green))

        update(&model, .setTabColors(tabIds: ids, color: nil))
        try expect(model.groups[0].tabs.allSatisfy { $0.color == nil },
            "nil color clears all selected")
    }

    test("testSetTabColorsDedupesAndIgnoresStale") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        let stale = TabId()

        let effects = update(&model, .setTabColors(
            tabIds: [id1, id1, stale, id2], color: .purple))

        try expectEqual(model.groups[0].tabs[0].color, .purple)
        try expectEqual(model.groups[0].tabs[1].color, .purple)
        // updateSidebarTabRow per valid id (2) + scheduleCheckpoint (1)
        try expectEqual(effects.count, 3,
            "no double-dispatch for duplicates; stale dropped")
    }

    test("testSetTabColorsAllStaleIsNoop") {
        var model = makeModel()
        createTab(&model)
        let snapshot = model.groups
        let stale1 = TabId()
        let stale2 = TabId()

        let effects = update(&model, .setTabColors(
            tabIds: [stale1, stale2], color: .red))

        try expectEqual(model.groups, snapshot)
        try expectEqual(effects.count, 0)
    }
}
