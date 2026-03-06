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

    test("testCloseLastPaneShowsConfirmation") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .closePane(paneId: paneId))
        try expectEqual(effects.count, 1)
        try expect(hasEffect(effects) {
            if case .showTerminateConfirmation = $0 { return true }
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
            if case .showTerminateConfirmation = $0 { return true }
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
}
