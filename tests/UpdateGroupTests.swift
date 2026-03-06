import Foundation

func groupTests() {
    print("Group Tests...")

    test("testCreateGroupAndMoveTab") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Work"))
        try expectEqual(model.groups.count, 2)
        try expectEqual(model.groups[1].name, "Work")
        try expectEqual(model.groups[1].tabs.count, 1, "new group should have auto-created tab")

        let workGroupId = model.groups[1].id
        update(&model, .moveTab(tabId: tabId, toGroupId: workGroupId, atIndex: 0))

        try expectEqual(model.groups[0].tabs.count, 0, "General should have no tabs")
        try expectEqual(model.groups[1].tabs.count, 2, "Work should have auto-created tab + moved tab")
        try expectEqual(model.groups[1].tabs[0].id, tabId)
    }

    test("testDeleteGroupMovesTabs") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Temp"))
        let tempGroupId = model.groups[1].id
        let autoTabId = model.groups[1].tabs[0].id
        update(&model, .moveTab(tabId: tabId, toGroupId: tempGroupId, atIndex: 0))

        try expectEqual(model.groups[0].tabs.count, 0)
        try expectEqual(model.groups[1].tabs.count, 2)

        update(&model, .deleteGroup(id: tempGroupId, moveTabs: true))
        try expectEqual(model.groups.count, 1, "only General should remain")
        try expectEqual(model.groups[0].tabs.count, 2, "both tabs should be moved to General")
        try expect(model.groups[0].tabs.contains(where: { $0.id == tabId }), "original tab should be in General")
        try expect(model.groups[0].tabs.contains(where: { $0.id == autoTabId }), "auto-created tab should be in General")
    }

    test("testDeleteGroupClosesTabs") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabId1 = model.groups[0].tabs[0].id
        let tabId2 = model.groups[0].tabs[1].id

        update(&model, .createGroup(name: "Temp"))
        let tempGroupId = model.groups[1].id
        // Temp has 1 auto-created tab

        // Move first tab to Temp (now Temp has 2 tabs)
        update(&model, .moveTab(tabId: tabId1, toGroupId: tempGroupId, atIndex: 0))

        // Delete Temp without moving tabs — destroys both tabs in Temp
        let effects = update(&model, .deleteGroup(id: tempGroupId, moveTabs: false))
        try expectEqual(model.groups.count, 1, "only General should remain")
        try expect(hasEffect(effects) {
            if case .destroySurface = $0 { return true }
            return false
        }, "should emit destroySurface for closed panes")
        // tabId2 should still be around
        try expectEqual(model.groups[0].tabs.count, 1)
        try expectEqual(model.groups[0].tabs[0].id, tabId2)
    }

    test("testDeleteGroupShowsConfirmationIfLast") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Only"))
        let onlyGroupId = model.groups[1].id
        update(&model, .moveTab(tabId: tabId, toGroupId: onlyGroupId, atIndex: 0))

        // General has no tabs, Only has the only tab + auto-created tab
        let effects = update(&model, .deleteGroup(id: onlyGroupId, moveTabs: false))
        try expectEqual(effects.count, 1)
        try expect(hasEffect(effects) {
            if case .showTerminateConfirmation = $0 { return true }
            return false
        }, "should show confirmation when deleting group with all tabs")
        try expectEqual(model.groups.count, 2, "model should be unchanged")
    }

    test("testDeleteDefaultGroupNoOp") {
        var model = makeModel()
        let defaultGroupId = model.groups[0].id

        let effects = update(&model, .deleteGroup(id: defaultGroupId, moveTabs: true))
        try expectEqual(effects.count, 0, "deleting default group should be no-op")
        try expectEqual(model.groups.count, 1)
    }

    test("testRenameGroup") {
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        let effects = update(&model, .renameGroup(id: workId, name: "Projects"))
        try expectEqual(model.groups[1].name, "Projects")
        try expect(hasEffect(effects) {
            if case .reloadSidebar = $0 { return true }
            return false
        }, "should emit reloadSidebar")
    }

    test("testReorderGroup") {
        var model = makeModel()
        update(&model, .createGroup(name: "A"))
        update(&model, .createGroup(name: "B"))
        let bGroupId = model.groups[2].id

        // Move B to index 1 (right after General)
        let effects = update(&model, .reorderGroup(groupId: bGroupId, toIndex: 1))
        try expectEqual(model.groups[0].name, "General")
        try expectEqual(model.groups[1].name, "B")
        try expectEqual(model.groups[2].name, "A")
        try expect(hasEffect(effects) {
            if case .reloadSidebar = $0 { return true }
            return false
        }, "should emit reloadSidebar")
    }

    test("testReorderDefaultGroupNoOp") {
        var model = makeModel()
        update(&model, .createGroup(name: "A"))
        let defaultGroupId = model.groups[0].id

        let effects = update(&model, .reorderGroup(groupId: defaultGroupId, toIndex: 1))
        try expectEqual(effects.count, 0, "reordering default group should be no-op")
        try expectEqual(model.groups[0].name, "General")
    }

    test("testToggleGroupCollapse") {
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        try expectEqual(model.groups[1].isCollapsed, false)
        let effects1 = update(&model, .toggleGroupCollapse(groupId: workId))
        try expectEqual(model.groups[1].isCollapsed, true)
        try expectEqual(effects1.count, 0, "toggleGroupCollapse should return no effects")

        let effects2 = update(&model, .toggleGroupCollapse(groupId: workId))
        try expectEqual(model.groups[1].isCollapsed, false)
        try expectEqual(effects2.count, 0)
    }

    test("testCreateGroupCreatesTabAndFocuses") {
        var model = makeModel()
        createTab(&model) // existing tab in General
        let oldSelectedTabId = model.selectedTabId

        let effects = update(&model, .createGroup(name: "Work"))
        let workGroup = model.groups[1]

        try expectEqual(workGroup.tabs.count, 1, "new group should have one tab")
        let newTab = workGroup.tabs[0]
        try expectEqual(model.selectedTabId, newTab.id, "new tab should be selected")
        try expect(model.selectedTabId != oldSelectedTabId, "selection should have changed")
        try expect(model.panes[newTab.focusedPaneId] != nil, "pane should exist in model")

        try expect(hasEffect(effects) {
            if case .createSurface = $0 { return true }
            return false
        }, "should emit createSurface for the new tab's pane")
        try expect(hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should emit rebuildContentView")
        try expect(hasEffect(effects) {
            if case .reloadSidebar = $0 { return true }
            return false
        }, "should emit reloadSidebar")
    }

    test("testMoveTabClampsIndex") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Target"))
        let targetId = model.groups[1].id
        // Target has 1 auto-created tab

        // Move with atIndex way beyond count — should clamp to end
        update(&model, .moveTab(tabId: tabId, toGroupId: targetId, atIndex: 999))
        try expectEqual(model.groups[1].tabs.count, 2, "should have auto-created tab + moved tab")
        try expectEqual(model.groups[1].tabs[1].id, tabId, "tab should land at clamped end index")
    }

    test("moveTab within same group adjusts for removal offset") {
        var model = makeModel()
        createTab(&model) // tab A
        createTab(&model) // tab B
        createTab(&model) // tab C
        let groupId = model.groups[0].id
        let a = model.groups[0].tabs[0].id
        let b = model.groups[0].tabs[1].id
        let c = model.groups[0].tabs[2].id

        // Drag A to after B (outline view proposes child index 2)
        update(&model, .moveTab(tabId: a, toGroupId: groupId, atIndex: 2))
        try expectEqual(model.groups[0].tabs[0].id, b, "B should be first")
        try expectEqual(model.groups[0].tabs[1].id, a, "A should be second")
        try expectEqual(model.groups[0].tabs[2].id, c, "C should be third")
    }

    test("moveTab with negative atIndex clamps to 0") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Target"))
        let targetId = model.groups[1].id

        update(&model, .moveTab(tabId: tabId, toGroupId: targetId, atIndex: -1))
        try expectEqual(model.groups[1].tabs[0].id, tabId, "tab should land at clamped index 0")
    }
}
