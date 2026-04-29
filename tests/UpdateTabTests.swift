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

    test("testNextTabNoOpAtLastTab") {
        var model = makeModel()
        createTab(&model)
        let lastTabId = model.groups[0].tabs[0].id

        let effects = update(&model, .selectAdjacentTab(direction: .next))
        try expectEqual(effects.count, 0, "should be no-op at last tab")
        try expectEqual(model.selectedTabId, lastTabId)
    }

    test("testPrevTabNoOpAtFirstTab") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id

        let effects = update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(effects.count, 0, "should be no-op at first tab")
        try expectEqual(model.selectedTabId, firstTabId)
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
    }

    // MARK: - Tab Color

    test("testSetTabColor") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let effects = update(&model, .setTabColor(tabId: tabId, color: .red))
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
        update(&model, .setTabColor(tabId: tabId, color: .blue))

        let effects = update(&model, .setTabColor(tabId: tabId, color: nil))
        try expect(model.groups[0].tabs[0].color == nil, "color should be nil")
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0, tid == tabId { return true }
            return false
        }, "should emit updateSidebarTabRow")
    }

    test("testSetTabColorToggleSameColor") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .setTabColor(tabId: tabId, color: .red))
        try expectEqual(model.groups[0].tabs[0].color, .red)

        // Re-applying the same color clears it (toggle).
        let effects = update(&model, .setTabColor(tabId: tabId, color: .red))
        try expect(model.groups[0].tabs[0].color == nil, "re-applying same color should clear it")
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0, tid == tabId { return true }
            return false
        }, "should emit updateSidebarTabRow")
    }

    test("testSetTabColorReplaceDifferent") {
        // Sanity: setting a different color replaces, not toggles off.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .setTabColor(tabId: tabId, color: .red))

        update(&model, .setTabColor(tabId: tabId, color: .blue))
        try expectEqual(model.groups[0].tabs[0].color, .blue)
    }

    test("testSetTabColorInvalidTab") {
        var model = makeModel()
        createTab(&model)
        let bogusId = TabId()

        let effects = update(&model, .setTabColor(tabId: bogusId, color: .green))
        try expectEqual(effects.count, 2, "should emit updateSidebarTabRow + scheduleCheckpoint")
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
}
