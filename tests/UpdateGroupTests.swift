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
        update(&model, .moveTabs(tabIds: [tabId], toGroupId: workGroupId, atIndex: 0))

        try expectEqual(model.groups.count, 1, "empty General should be pruned")
        try expectEqual(model.groups[0].id, workGroupId)
        try expectEqual(model.groups[0].tabs.count, 2, "Work should have auto-created tab + moved tab")
        try expectEqual(model.groups[0].tabs[0].id, tabId)
    }

    test("testDeleteGroupMovesTabs") {
        var model = makeModel()
        createTab(&model) // tab1 in General
        createTab(&model) // tab2 in General (keeps General non-empty after moveTab)
        let tab1Id = model.groups[0].tabs[0].id
        let tab2Id = model.groups[0].tabs[1].id

        update(&model, .createGroup(name: "Temp"))
        let tempGroupId = model.groups[1].id
        let autoTabId = model.groups[1].tabs[0].id
        update(&model, .moveTabs(tabIds: [tab1Id], toGroupId: tempGroupId, atIndex: 0))

        try expectEqual(model.groups[0].tabs.count, 1, "General should have 1 tab remaining")
        try expectEqual(model.groups[1].tabs.count, 2, "Temp should have moved tab + auto tab")

        // Deleting Temp should move its tabs to adjacent group (General)
        update(&model, .deleteGroup(id: tempGroupId, moveTabs: true))
        try expectEqual(model.groups.count, 1, "only General should remain")
        try expectEqual(model.groups[0].tabs.count, 3, "all tabs should be in General")
        try expect(model.groups[0].tabs.contains(where: { $0.id == tab1Id }), "moved tab should be in General")
        try expect(model.groups[0].tabs.contains(where: { $0.id == autoTabId }), "auto-created tab should be in General")
        try expect(model.groups[0].tabs.contains(where: { $0.id == tab2Id }), "original tab should be in General")
    }

    test("testDeleteFirstGroupMovesTabsToNext") {
        var model = makeModel()
        createTab(&model)
        let generalId = model.groups[0].id
        let generalTabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Second"))
        let secondGroupId = model.groups[1].id

        // Delete groups[0] (General) — tabs should move to groups[1] (Second)
        update(&model, .deleteGroup(id: generalId, moveTabs: true))
        try expectEqual(model.groups.count, 1, "only Second should remain")
        try expectEqual(model.groups[0].name, "Second")
        try expect(model.groups[0].tabs.contains(where: { $0.id == generalTabId }), "tab should be moved to Second")
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
        update(&model, .moveTabs(tabIds: [tabId1], toGroupId: tempGroupId, atIndex: 0))

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
        // With auto-pruning of empty groups, moving all tabs out of General
        // prunes it, making Only the sole group. Deleting the sole group is a no-op.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Only"))
        let onlyGroupId = model.groups[1].id
        update(&model, .moveTabs(tabIds: [tabId], toGroupId: onlyGroupId, atIndex: 0))

        try expectEqual(model.groups.count, 1, "empty General should be pruned")
        try expectEqual(model.groups[0].id, onlyGroupId)

        let effects = update(&model, .deleteGroup(id: onlyGroupId, moveTabs: false))
        try expectEqual(effects.count, 0, "deleting sole group should be no-op")
        try expectEqual(model.groups.count, 1, "model should be unchanged")
    }

    test("testDeleteLastGroupNoOp") {
        var model = makeModel()
        createTab(&model)
        let onlyGroupId = model.groups[0].id

        let effects = update(&model, .deleteGroup(id: onlyGroupId, moveTabs: true))
        try expectEqual(effects.count, 0, "deleting last remaining group should be no-op")
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

    test("renameGroup rejects empty name") {
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        let effects = update(&model, .renameGroup(id: workId, name: ""))
        try expectEqual(model.groups[1].name, "Work", "name should be unchanged")
        try expectEqual(effects.count, 0, "should emit no effects")
    }

    test("renameGroup rejects whitespace-only name") {
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        let effects = update(&model, .renameGroup(id: workId, name: "   "))
        try expectEqual(model.groups[1].name, "Work", "name should be unchanged")
        try expectEqual(effects.count, 0, "should emit no effects")
    }

    test("renameGroup trims whitespace") {
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        update(&model, .renameGroup(id: workId, name: "  Projects  "))
        try expectEqual(model.groups[1].name, "Projects")
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

    test("testReorderGroupToIndex0") {
        var model = makeModel()
        update(&model, .createGroup(name: "A"))
        let aGroupId = model.groups[1].id

        let effects = update(&model, .reorderGroup(groupId: aGroupId, toIndex: 0))
        try expectEqual(model.groups[0].name, "A", "A should be at index 0")
        try expectEqual(model.groups[1].name, "General")
        try expect(hasEffect(effects) {
            if case .reloadSidebar = $0 { return true }
            return false
        }, "should emit reloadSidebar")
    }

    test("testToggleGroupCollapse") {
        var model = makeModel()
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id

        try expectEqual(model.groups[1].isCollapsed, false)
        let effects1 = update(&model, .toggleGroupCollapse(groupId: workId))
        try expectEqual(model.groups[1].isCollapsed, true)
        try expectEqual(effects1.count, 1, "toggleGroupCollapse should return only scheduleCheckpoint")
        try expect(hasEffect(effects1) { if case .scheduleCheckpoint = $0 { return true }; return false })

        let effects2 = update(&model, .toggleGroupCollapse(groupId: workId))
        try expectEqual(model.groups[1].isCollapsed, false)
        try expectEqual(effects2.count, 1)
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
        update(&model, .moveTabs(tabIds: [tabId], toGroupId: targetId, atIndex: 999))
        // General was emptied and pruned; only Target remains
        let targetGroup = model.groups.first(where: { $0.id == targetId })!
        try expectEqual(targetGroup.tabs.count, 2, "should have auto-created tab + moved tab")
        try expectEqual(targetGroup.tabs[1].id, tabId, "tab should land at clamped end index")
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
        update(&model, .moveTabs(tabIds: [a], toGroupId: groupId, atIndex: 2))
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

        update(&model, .moveTabs(tabIds: [tabId], toGroupId: targetId, atIndex: -1))
        // General was emptied and pruned; only Target remains
        let targetGroup = model.groups.first(where: { $0.id == targetId })!
        try expectEqual(targetGroup.tabs[0].id, tabId, "tab should land at clamped index 0")
    }

    // MARK: - Auto-prune empty groups

    test("testCloseLastTabInGroupRemovesGroup") {
        var model = makeModel()
        createTab(&model) // tab in General

        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id

        // Select General's tab so closing it triggers selection change
        let generalTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: generalTabId))
        let effects = update(&model, .closeTab(id: generalTabId))

        try expectEqual(model.groups.count, 1, "empty General should be pruned")
        try expectEqual(model.groups[0].id, workGroupId, "Work should remain")
        try expect(model.selectedTabId != nil, "some tab should be selected")
        try expect(hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should emit rebuildContentView")
        try expect(hasEffect(effects) {
            if case .reloadSidebar = $0 { return true }
            return false
        }, "should emit reloadSidebar")
    }

    test("testMoveTabLeavingEmptyGroupRemovesIt") {
        var model = makeModel()
        createTab(&model) // only tab in General

        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        let generalTabId = model.groups[0].tabs[0].id

        update(&model, .moveTabs(tabIds: [generalTabId], toGroupId: workGroupId, atIndex: 0))

        try expectEqual(model.groups.count, 1, "empty General should be pruned")
        try expectEqual(model.groups[0].id, workGroupId)
        try expectEqual(model.groups[0].tabs.count, 2, "Work should have both tabs")
    }

    test("testCloseTabInMultiTabGroupKeepsGroup") {
        var model = makeModel()
        createTab(&model) // tab1
        createTab(&model) // tab2
        let tab1Id = model.groups[0].tabs[0].id

        update(&model, .closeTab(id: tab1Id))

        try expectEqual(model.groups.count, 1, "group should still exist")
        try expectEqual(model.groups[0].tabs.count, 1, "one tab should remain")
    }

    test("testMovePaneToNewTabCrossGroupPrunesEmptyGroup") {
        var model = makeModel()
        createTab(&model) // tab1 in General (single pane)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id

        // Move paneA (only pane in General's only tab) to new tab in Work
        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: workGroupId, atIndex: 0))

        try expectEqual(model.groups.count, 1, "empty General should be pruned")
        try expectEqual(model.groups[0].id, workGroupId)
        try expectEqual(model.groups[0].tabs.count, 2, "Work should have auto tab + moved tab")
        try expectEqual(model.selectedTabId, model.groups[0].tabs[0].id, "moved tab should be selected")
    }

    test("testSurfaceCreationFailedPrunesEmptyGroup") {
        var model = makeModel()
        createTab(&model) // tab in General

        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id

        let generalPaneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .surfaceCreationFailed(paneId: generalPaneId))

        try expectEqual(model.groups.count, 1, "empty General should be pruned")
        try expectEqual(model.groups[0].id, workGroupId, "Work should remain")
        try expect(!hasEffect(effects) {
            if case .terminate = $0 { return true }
            return false
        }, "should not terminate — Work group has tabs")
        try expect(hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should emit rebuildContentView")
    }

    test("testExtractSingleTabToNewGroup") {
        var model = makeModel()
        createTab(&model) // tab1
        createTab(&model) // tab2 — keeps source group non-empty after extract
        let tab1Id = model.groups[0].tabs[0].id

        let effects = update(&model, .extractTabsToNewGroup(
            tabIds: [tab1Id], groupName: "Extracted"))

        try expectEqual(model.groups.count, 2, "source group should survive (still has tab2)")
        try expectEqual(model.groups[1].name, "Extracted")
        try expectEqual(model.groups[1].tabs.count, 1)
        try expectEqual(model.groups[1].tabs[0].id, tab1Id)
        try expectEqual(model.groups[0].tabs.count, 1, "source has tab2 left")

        try expectEqual(effects.count, 2, "should emit exactly reloadSidebar + scheduleCheckpoint")
        try expect(hasEffect(effects) {
            if case .reloadSidebar = $0 { return true }; return false
        })
        try expect(hasEffect(effects) {
            if case .scheduleCheckpoint = $0 { return true }; return false
        })
    }

    test("testExtractMultipleTabsSameGroup") {
        var model = makeModel()
        createTab(&model) // tab1
        createTab(&model) // tab2
        createTab(&model) // tab3 — stays in source group
        let tab1Id = model.groups[0].tabs[0].id
        let tab2Id = model.groups[0].tabs[1].id

        let effects = update(&model, .extractTabsToNewGroup(
            tabIds: [tab1Id, tab2Id], groupName: "Extracted"))

        try expectEqual(model.groups.count, 2)
        try expectEqual(model.groups[1].tabs.count, 2)
        try expectEqual(model.groups[1].tabs[0].id, tab1Id, "order preserved")
        try expectEqual(model.groups[1].tabs[1].id, tab2Id, "order preserved")
        try expectEqual(model.groups[0].tabs.count, 1, "tab3 left in source")
        try expectEqual(effects.count, 2)
    }

    test("testExtractMultipleTabsAcrossGroups") {
        var model = makeModel()
        createTab(&model) // generalTab1
        createTab(&model) // generalTab2 — keeps General non-empty
        let general1 = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Work"))
        // Work has its auto-created tab
        let workAuto = model.groups[1].tabs[0].id

        let effects = update(&model, .extractTabsToNewGroup(
            tabIds: [general1, workAuto], groupName: "Extracted"))

        // General had 2 tabs (one extracted) → still has 1, survives
        // Work had 1 tab (extracted) → empty, pruned
        try expectEqual(model.groups.count, 2, "Work pruned, General + Extracted remain")
        try expectEqual(model.groups[0].name, "General")
        try expectEqual(model.groups[1].name, "Extracted")
        try expectEqual(model.groups[1].tabs.count, 2)
        try expectEqual(model.groups[1].tabs[0].id, general1, "input order preserved")
        try expectEqual(model.groups[1].tabs[1].id, workAuto, "input order preserved")
        try expectEqual(effects.count, 2)
    }

    test("testExtractAllTabsFromOnlyGroupIsNoop") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let tab2Id = model.groups[0].tabs[1].id
        let snapshot = model.groups

        let effects = update(&model, .extractTabsToNewGroup(
            tabIds: [tab1Id, tab2Id], groupName: "Extracted"))

        try expectEqual(model.groups.count, 1, "no new group created")
        try expectEqual(model.groups, snapshot, "model.groups unchanged")
        try expectEqual(effects.count, 0, "no-op should emit no effects")
    }

    test("testExtractAllTabsAcrossMultipleGroupsIsNoop") {
        var model = makeModel()
        createTab(&model) // generalTab
        let generalTabId = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Work"))
        let workTabId = model.groups[1].tabs[0].id

        // 2 groups, 1 tab each: extracting both = every live tab.
        let snapshotCount = model.groups.count
        let effects = update(&model, .extractTabsToNewGroup(
            tabIds: [generalTabId, workTabId], groupName: "Extracted"))

        try expectEqual(model.groups.count, snapshotCount,
            "no group destruction; structure preserved")
        try expectEqual(effects.count, 0, "no-op should emit no effects")
    }

    test("testExtractDedupesAndIgnoresStaleIds") {
        var model = makeModel()
        createTab(&model) // tab1
        createTab(&model) // tab2
        createTab(&model) // tab3 — stays
        let tab1Id = model.groups[0].tabs[0].id
        let tab2Id = model.groups[0].tabs[1].id
        let stale = TabId() // never existed

        let effects = update(&model, .extractTabsToNewGroup(
            tabIds: [tab1Id, tab1Id, stale, tab2Id], groupName: "Extracted"))

        try expectEqual(model.groups.count, 2)
        try expectEqual(model.groups[1].tabs.count, 2, "duplicate dropped, stale dropped")
        try expectEqual(model.groups[1].tabs[0].id, tab1Id)
        try expectEqual(model.groups[1].tabs[1].id, tab2Id)
        try expectEqual(effects.count, 2)
    }

    test("testExtractAllStaleIdsIsNoop") {
        var model = makeModel()
        createTab(&model)
        let snapshot = model.groups
        let stale1 = TabId()
        let stale2 = TabId()

        let effects = update(&model, .extractTabsToNewGroup(
            tabIds: [stale1, stale2], groupName: "Extracted"))

        try expectEqual(model.groups, snapshot, "no group created when all ids stale")
        try expectEqual(effects.count, 0)
    }

    test("testExtractPreservesSelectedTabIdWhenFocusedTabIsExtracted") {
        // Spec: focused tab still exists, just under a new group;
        // extract should not move selection.
        var model = makeModel()
        createTab(&model) // tab1
        createTab(&model) // tab2 — auto-focused by createTab
        createTab(&model) // tab3 — kept in source
        let focusedId = model.selectedTabId
        try expect(focusedId != nil)

        update(&model, .extractTabsToNewGroup(
            tabIds: [focusedId!], groupName: "Extracted"))

        try expectEqual(model.selectedTabId, focusedId,
            "selection must not move when the focused tab is extracted")
    }

    test("testExtractPreservesSelectedTabIdWhenOtherTabIsExtracted") {
        var model = makeModel()
        createTab(&model) // tab1
        createTab(&model) // tab2
        createTab(&model) // tab3 — auto-focused
        let focusedId = model.selectedTabId
        let otherId = model.groups[0].tabs[0].id

        update(&model, .extractTabsToNewGroup(
            tabIds: [otherId], groupName: "Extracted"))

        try expectEqual(model.selectedTabId, focusedId,
            "selection must not move when an unrelated tab is extracted")
    }

    // MARK: - moveTabs (batch drag)

    test("testMoveTabsCrossGroup") {
        var model = makeModel()
        createTab(&model) // a0 in General
        createTab(&model) // a1
        createTab(&model) // a2 — keeps General non-empty
        let a0 = model.groups[0].tabs[0].id
        let a1 = model.groups[0].tabs[1].id

        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id
        let b0 = model.groups[1].tabs[0].id // auto-created tab

        // Drop {a0, a1} into Work at index 1 (between b0 and end).
        let effects = update(&model, .moveTabs(
            tabIds: [a0, a1], toGroupId: workId, atIndex: 1))

        try expectEqual(model.groups.count, 2)
        try expectEqual(model.groups[0].name, "General")
        try expectEqual(model.groups[0].tabs.count, 1, "a2 left in General")
        try expectEqual(model.groups[1].tabs.count, 3, "Work has b0 + moved a0,a1")
        try expectEqual(model.groups[1].tabs[0].id, b0)
        try expectEqual(model.groups[1].tabs[1].id, a0, "input order preserved")
        try expectEqual(model.groups[1].tabs[2].id, a1, "input order preserved")

        try expectEqual(effects.count, 2, "exactly reloadSidebar + scheduleCheckpoint")
        try expect(hasEffect(effects) {
            if case .reloadSidebar = $0 { return true }; return false
        })
        try expect(hasEffect(effects) {
            if case .scheduleCheckpoint = $0 { return true }; return false
        })
    }

    test("testMoveTabsIntraGroupShiftDown") {
        // [a0, a1, a2, a3]; move {a1, a2} to atIndex=4 → [a0, a3, a1, a2]
        var model = makeModel()
        for _ in 0..<4 { createTab(&model) }
        let groupId = model.groups[0].id
        let ids = model.groups[0].tabs.map(\.id)
        let a0 = ids[0]; let a1 = ids[1]; let a2 = ids[2]; let a3 = ids[3]

        update(&model, .moveTabs(tabIds: [a1, a2], toGroupId: groupId, atIndex: 4))

        let final = model.groups[0].tabs.map(\.id)
        try expectEqual(final, [a0, a3, a1, a2])
    }

    test("testMoveTabsIntraGroupShiftUp") {
        // [a0, a1, a2, a3]; move {a2, a3} to atIndex=0 → [a2, a3, a0, a1]
        var model = makeModel()
        for _ in 0..<4 { createTab(&model) }
        let groupId = model.groups[0].id
        let ids = model.groups[0].tabs.map(\.id)
        let a0 = ids[0]; let a1 = ids[1]; let a2 = ids[2]; let a3 = ids[3]

        update(&model, .moveTabs(tabIds: [a2, a3], toGroupId: groupId, atIndex: 0))

        let final = model.groups[0].tabs.map(\.id)
        try expectEqual(final, [a2, a3, a0, a1])
    }

    test("testMoveTabsIntraGroupAnchorBetweenSelected") {
        // [a, b, c, d]; move {a, c} to atIndex=3.
        // removedBeforeAnchor = 2 (a@0 and c@2 are < 3) → adjusted = 1.
        // After removal: [b, d]. Insert {a, c} at idx 1 → [b, a, c, d].
        var model = makeModel()
        for _ in 0..<4 { createTab(&model) }
        let groupId = model.groups[0].id
        let ids = model.groups[0].tabs.map(\.id)
        let a = ids[0]; let b = ids[1]; let c = ids[2]; let d = ids[3]

        update(&model, .moveTabs(tabIds: [a, c], toGroupId: groupId, atIndex: 3))

        let final = model.groups[0].tabs.map(\.id)
        try expectEqual(final, [b, a, c, d])
    }

    test("testMoveTabsCrossGroupEmptiesSourceAndPrunes") {
        var model = makeModel()
        createTab(&model) // generalTab — only tab in General
        let generalTab = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id
        let workTab = model.groups[1].tabs[0].id

        update(&model, .moveTabs(tabIds: [generalTab], toGroupId: workId, atIndex: 1))

        try expectEqual(model.groups.count, 1, "empty General pruned")
        try expectEqual(model.groups[0].id, workId)
        try expectEqual(model.groups[0].tabs.map(\.id), [workTab, generalTab])
    }

    test("testMoveTabsDedupesAndIgnoresStaleIds") {
        var model = makeModel()
        createTab(&model) // a0
        createTab(&model) // a1
        createTab(&model) // a2 — keeps source non-empty
        let a0 = model.groups[0].tabs[0].id
        let a1 = model.groups[0].tabs[1].id

        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id
        let workAuto = model.groups[1].tabs[0].id
        let stale = TabId()

        update(&model, .moveTabs(
            tabIds: [a0, a0, stale, a1], toGroupId: workId, atIndex: 1))

        try expectEqual(model.groups[0].tabs.count, 1, "a2 left in General")
        try expectEqual(model.groups[1].tabs.map(\.id), [workAuto, a0, a1],
            "duplicate + stale dropped; rest moved in order")
    }

    test("testMoveTabsAllStaleIdsIsNoop") {
        var model = makeModel()
        createTab(&model)
        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id
        let snapshot = model.groups
        let stale1 = TabId()
        let stale2 = TabId()

        let effects = update(&model, .moveTabs(
            tabIds: [stale1, stale2], toGroupId: workId, atIndex: 0))

        try expectEqual(model.groups, snapshot, "groups unchanged")
        try expectEqual(effects.count, 0)
    }

    test("testMoveTabsClampedAtIndex") {
        var model = makeModel()
        createTab(&model) // a0
        createTab(&model) // a1 — kept in source
        let a0 = model.groups[0].tabs[0].id

        update(&model, .createGroup(name: "Work"))
        let workId = model.groups[1].id
        let workAuto = model.groups[1].tabs[0].id

        // atIndex past end: clamps to append.
        update(&model, .moveTabs(
            tabIds: [a0], toGroupId: workId, atIndex: 999))
        try expectEqual(model.groups[1].tabs.map(\.id), [workAuto, a0],
            "past-end atIndex clamps to append")

        // Now move it back at a negative atIndex: clamps to 0 (prepend).
        update(&model, .moveTabs(
            tabIds: [a0], toGroupId: workId, atIndex: -5))
        try expectEqual(model.groups[1].tabs.map(\.id), [a0, workAuto],
            "negative atIndex clamps to 0")
    }
}
