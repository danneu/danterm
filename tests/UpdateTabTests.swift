import Foundation

func tabTests() {
    print("Tab Tests...")

    test("testCreateTabAddsToDefaultGroup") {
        var model = makeModel()
        let commands = createTab(&model)

        try expectEqual(model.groups[0].tabs.count, 1)
        try expectEqual(model.allPaneIds.count, 1)
        try expect(model.selectedTabId == model.groups[0].tabs[0].id)
        try expect(hasEffect(commands) {
            if case .createSurface = $0 { return true }
            return false
        }, "should emit createSurface")
        // The foreground tab is shown structurally (reconcileContainers builds + shows the
        // new selected tab); selectedTabId (asserted above) is the net.
    }

    test("testCreateTabBackgroundDoesNotChangeSelection") {
        var model = makeModel()
        createTab(&model)
        let selectedTabId = model.groups[0].tabs[0].id
        let selectedPaneId = model.groups[0].tabs[0].focusedPaneId
        let beforePaneIds = Set(model.allPaneIds)

        let commands = createTab(&model, background: true)
        let newPaneIds = Set(model.allPaneIds).subtracting(beforePaneIds)

        try expectEqual(model.groups[0].tabs.count, 2)
        try expectEqual(model.selectedTabId, selectedTabId, "background tab should not steal selection")
        try expectEqual(newPaneIds.count, 1, "background tab should create one pane")
        try expect(hasEffect(commands) {
            if case .createSurface(let paneId, _, _, _, _) = $0 {
                return newPaneIds.contains(paneId)
            }
            return false
        }, "should emit createSurface for new pane")
        // The new tab's row appears via reconcileSidebar.
        try expect(!hasEffect(commands) {
            if case .focusSurface(let paneId, false) = $0, paneId == selectedPaneId { return true }
            return false
        }, "should not defocus selected pane")
        // A background tab does not become visible -- selectedTabId is unchanged (asserted
        // above), so reconcileContainers mounts its container hidden, never shown.
    }

    test("testCreateTabInheritsWorkingDirectory") {
        var model = makeModel()
        createTab(&model)
        let firstPaneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(firstPaneId) { $0.cwd = "/tmp/test" }
        let commands = createTab(&model)
        let createEffect = commands.first(where: {
            if case .createSurface = $0 { return true }
            return false
        })
        try expect(createEffect != nil, "should have createSurface command")
        if case .createSurface(_, let cwd, _, _, _) = createEffect! {
            try expectEqual(cwd, "/tmp/test", "cwd should inherit")
        }
    }

    test("testSelectTabDefocusesOldPanes") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id

        createTab(&model)

        let commands = update(&model, .selectTab(id: firstTabId))

        let secondPaneId = model.groups[0].tabs[1].focusedPaneId
        try expect(hasEffect(commands) {
            if case .focusSurface(let pid, false) = $0, pid == secondPaneId { return true }
            return false
        }, "should defocus second tab's pane")
        try expectEqual(model.selectedTabId, firstTabId)
    }

    test("testSelectTabSwitchesSelection") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        createTab(&model)

        update(&model, .selectTab(id: firstTabId))

        // Selection is view-owned (reconcileSidebar reapplies it) and the container swap is
        // structural (reconcileContainers); the model selection is the net.
        try expectEqual(model.selectedTabId, firstTabId, "model selection should change")
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

    test("testSelectTabFocusModeMarksFocusedPaneAlertsRead") {
        var model = makeModel()
        model.config.alertClearMode = .focus
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        createTab(&model)
        let tabBId = model.groups[0].tabs[1].id
        let tabBPaneId = model.groups[0].tabs[1].focusedPaneId

        // Selecting tabA (no alert on its focused pane) leaves alerts untouched.
        update(&model, .selectTab(id: tabAId))

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: tabBPaneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .selectTab(id: tabBId))

        // Focus-mode selection marks the focused pane's alerts read; that tab's bell
        // badge then reconciles via reconcileSidebar (the row refresh is no longer emitted).
        try expectEqual(model.alerts[0].isUnread, false,
            "focus-mode selection should mark focused pane alerts read")
        try expectEqual(model.selectedTabId, tabBId)
    }

    test("testSelectTabFocusModeMarksAlertReadInCollapsedGroup") {
        var model = makeModel()
        model.config.alertClearMode = .focus
        createTab(&model)
        let generalTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        let workTabId = model.groups[1].tabs[0].id
        let workPaneId = model.groups[1].tabs[0].focusedPaneId
        update(&model, .selectTab(id: generalTabId))
        update(&model, .toggleGroupCollapse(groupId: workGroupId))

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: workPaneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .selectTab(id: workTabId))

        // The focused pane's alert is marked read; the collapsed group's rolled-up bell
        // badge then reconciles via reconcileSidebar (desiredSidebar.groupUnreadAlertCount).
        try expect(!model.alerts.contains { $0.paneId == workPaneId && $0.isUnread },
            "focus-mode selection should mark the focused pane's alert read")
        try expectEqual(model.selectedTabId, workTabId)
    }

    test("testCloseLastPaneShowsConfirmation") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .closePane(paneId: paneId))
        try expectEqual(commands.count, 1)
        try expect(hasEffect(commands) {
            if case .showTerminateConfirmation(let count) = $0, count == 1 { return true }
            return false
        }, "should show confirmation when closing last pane")
        try expect(model.pendingConfirmation == .terminate, "quit confirmation should be pending")
        try expectEqual(model.groups[0].tabs.count, 1, "model should be unchanged")
        try expect(model.pane(paneId) != nil, "pane should still exist")
    }

    test("testCloseLastTabShowsConfirmation") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let commands = update(&model, .closeTab(id: tabId))
        try expectEqual(commands.count, 1)
        try expect(hasEffect(commands) {
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

    test("testCreateTabBackgroundIntoSpecificGroup") {
        var model = makeModel()
        createTab(&model)
        let selectedTabId = model.selectedTabId!
        let _ = update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        let workCountBefore = model.groups[1].tabs.count
        _ = update(&model, .selectTab(id: selectedTabId))

        createTab(&model, inGroupId: workGroupId, background: true)

        try expectEqual(model.groups[1].tabs.count, workCountBefore + 1, "background tab should land in requested group")
        try expectEqual(model.selectedTabId, selectedTabId, "background tab should not change selection")
        // A background tab never becomes visible -- selectedTabId is unchanged (asserted
        // above), so reconcileContainers mounts its container hidden.
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

    test("testCreateTabAfterTabInTargetGroupInsertsAfterReference") {
        var model = makeModel()
        createTab(&model) // tab A
        createTab(&model) // tab B
        createTab(&model) // tab C
        let tabAId = model.groups[0].tabs[0].id
        let tabBId = model.groups[0].tabs[1].id
        let tabCId = model.groups[0].tabs[2].id

        update(&model, .createTab(inGroupId: nil, position: .afterTab(tabAId)))
        let tabDId = model.groups[0].tabs[1].id

        try expectEqual(model.groups[0].tabs.map(\.id), [tabAId, tabDId, tabBId, tabCId])
        try expectEqual(model.selectedTabId, tabDId, "newly created tab is selected")
    }

    test("testCreateTabAfterTabFromDifferentGroupAppendsToTargetGroup") {
        var model = makeModel()
        createTab(&model)
        let otherGroupRef = model.groups[0].tabs[0].id
        _ = update(&model, .createGroup(name: "Work"))
        let workGroupId = model.groups[1].id
        update(&model, .createTab(inGroupId: workGroupId))
        let workBefore = model.groups[1].tabs.map(\.id)

        update(&model, .createTab(inGroupId: workGroupId, position: .afterTab(otherGroupRef)))
        let newTabId = model.groups[1].tabs.last!.id

        try expectEqual(model.groups[1].tabs.map(\.id), workBefore + [newTabId])
        try expectEqual(model.selectedTabId, newTabId, "newly created tab is selected")
    }

    test("testCreateTabAfterUnknownTabAppendsToTargetGroup") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let before = model.groups[0].tabs.map(\.id)

        update(&model, .createTab(inGroupId: nil, position: .afterTab(TabId())))
        let newTabId = model.groups[0].tabs.last!.id

        try expectEqual(model.groups[0].tabs.map(\.id), before + [newTabId])
        try expectEqual(model.selectedTabId, newTabId, "newly created tab is selected")
    }

    test("testSelectTabAlreadySelected") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let commands = update(&model, .selectTab(id: tabId))
        try expectEqual(commands.count, 0, "selecting already-selected tab should return no commands")
    }

    // MARK: - Adjacent Tab Navigation

    test("testNextTabWithinSameGroup") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: firstTabId))

        let commands = update(&model, .selectAdjacentTab(direction: .next))
        try expectEqual(model.selectedTabId, secondTabId)
        try expect(commands.count > 0, "should have commands")
    }

    test("testPrevTabWithinSameGroup") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: secondTabId))

        let commands = update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(model.selectedTabId, firstTabId)
        try expect(commands.count > 0, "should have commands")
    }

    test("testNextTabAcrossGroups") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let secondTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: firstTabId))

        let commands = update(&model, .selectAdjacentTab(direction: .next))
        try expectEqual(model.selectedTabId, secondTabId)
        try expect(commands.count > 0, "should have commands")
    }

    test("testPrevTabAcrossGroups") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .createGroup(name: "Work"))
        let secondTabId = model.groups[1].tabs[0].id
        update(&model, .selectTab(id: secondTabId))

        let commands = update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(model.selectedTabId, firstTabId)
        try expect(commands.count > 0, "should have commands")
    }

    test("testNextTabNoOpWithSingleTab") {
        var model = makeModel()
        createTab(&model)
        let lastTabId = model.groups[0].tabs[0].id

        let commands = update(&model, .selectAdjacentTab(direction: .next))
        try expectEqual(commands.count, 0, "wrap to self should be no-op")
        try expectEqual(model.selectedTabId, lastTabId)
    }

    test("testPrevTabNoOpWithSingleTab") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id

        let commands = update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(commands.count, 0, "wrap to self should be no-op")
        try expectEqual(model.selectedTabId, firstTabId)
    }

    test("testNextTabWrapsFromLastToFirst") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let lastTabId  = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: lastTabId))

        let commands = update(&model, .selectAdjacentTab(direction: .next))
        try expectEqual(model.selectedTabId, firstTabId)
        try expect(commands.count > 0, "should have commands")
    }

    test("testPrevTabWrapsFromFirstToLast") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let lastTabId  = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: firstTabId))

        let commands = update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(model.selectedTabId, lastTabId)
        try expect(commands.count > 0, "should have commands")
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
        let commands = update(&model, .selectAdjacentTab(direction: .next))
        try expectEqual(commands.count, 0)
    }

    test("testPrevTabNoOpWithNoTabs") {
        var model = makeModel()
        let commands = update(&model, .selectAdjacentTab(direction: .prev))
        try expectEqual(commands.count, 0)
    }

    // MARK: - requestCloseTab

    test("testRequestCloseTabSinglePaneClosesDirectly") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let firstPaneId = model.groups[0].tabs[0].focusedPaneId
        let liveBefore = Set(model.allPaneIds)

        let commands = update(&model, .requestCloseTab(id: firstTabId))
        try expectEqual(model.groups[0].tabs.count, 1, "tab should be removed")
        // Surface teardown is reconcileSurfaceExistence's: the closed tab's pane is selected.
        try expectEqual(surfacesToTearDown(liveSurfaceIds: liveBefore, model: model), Set([firstPaneId]),
            "closed tab's pane surface is torn down")
        try expect(!hasEffect(commands) {
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

        let commands = update(&model, .requestCloseTab(id: firstTabId))
        try expectEqual(model.groups[0].tabs.count, 2, "tab should NOT be removed yet")
        try expect(hasEffect(commands) {
            if case .showCloseTabConfirmation(let tid, _, let count, let last, _) = $0 {
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

        let commands = update(&model, .requestCloseTab(id: firstTabId))

        try expectEqual(commands.count, 1)
        if case .showCloseTabConfirmation = commands[0] {
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

        let commands = update(&model, .requestCloseTab(id: firstTabId))

        try expectEqual(commands.count, 0, "requestCloseTab should be blocked by pending close-tab confirmation")
    }

    test("testRequestCloseTabWhileQuitPendingIsNoOp") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitPane(direction: .horizontal))
        model.pendingConfirmation = .terminate

        let commands = update(&model, .requestCloseTab(id: firstTabId))

        try expectEqual(commands.count, 0, "requestCloseTab should be blocked by pending quit confirmation")
        try expect(!hasEffect(commands) {
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
        let liveBefore = Set(model.allPaneIds)

        update(&model, .confirmCloseTab(id: firstTabId))

        try expect(model.pendingConfirmation == nil, "confirm should clear pending confirmation")
        try expect(!model.groups[0].tabs.contains { $0.id == firstTabId }, "tab should be removed")
        // Surface teardown is reconcileSurfaceExistence's: every pane in the closed tab is selected.
        try expectEqual(surfacesToTearDown(liveSurfaceIds: liveBefore, model: model), Set(paneIds),
            "each pane in the closed tab is torn down")
    }

    test("testConfirmCloseTabLastMultiPaneRoutesToTerminate") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .splitPane(direction: .horizontal))
        let paneIds = paneIdsForTab(tabId, in: model)
        model.pendingConfirmation = .closeTab
        let liveBefore = Set(model.allPaneIds)

        let commands = update(&model, .confirmCloseTab(id: tabId))

        try expectEqual(commands.count, 1)
        if case .showTerminateConfirmation = commands[0] {
            // good
        } else {
            throw TestFailure(message: "expected showTerminateConfirmation")
        }
        for paneId in paneIds {
            try expect(model.pane(paneId) != nil, "pane should still exist")
        }
        // Nothing left the model (routes to quit confirmation), so reconcileSurfaceExistence
        // tears down no surface -- checked against the pre-update live set so this is a real net.
        try expect(surfacesToTearDown(liveSurfaceIds: liveBefore, model: model).isEmpty,
            "no surface is torn down before the quit confirmation")
        try expect(model.groups[0].tabs.contains { $0.id == tabId }, "tab should still exist")
        try expect(model.pendingConfirmation == .terminate, "quit confirmation should be pending")
    }

    test("testCancelCloseTabClearsPending") {
        var model = makeModel()
        createTab(&model)
        model.pendingConfirmation = .closeTab

        let commands = update(&model, .cancelCloseTab)

        try expectEqual(commands.count, 0, "cancel should produce no commands")
        try expect(model.pendingConfirmation == nil, "cancel should clear pending confirmation")
    }

    test("testRequestCloseTabSinglePaneLastTabShowsTerminateConfirmation") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let commands = update(&model, .requestCloseTab(id: tabId))
        try expectEqual(model.groups[0].tabs.count, 1, "tab should NOT be removed")
        try expect(hasEffect(commands) {
            if case .showTerminateConfirmation(let count) = $0, count == 1 { return true }
            return false
        }, "should show terminate confirmation for last single-pane tab")
        try expect(model.pendingConfirmation == .terminate, "quit confirmation should be pending")
    }

    test("testRequestCloseTabsMixedBatchShowsSingleConfirmationAndKeepsTabsUntilConfirm") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        let thirdTabId = model.groups[0].tabs[2].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitPane(direction: .horizontal))
        update(&model, .addTabTodo(tabId: secondTabId, text: "finish this"))
        let tabIdsBefore = model.groups.flatMap(\.tabs).map(\.id)
        let liveBefore = Set(model.allPaneIds)

        let commands = update(&model, .requestCloseTabs(ids: [firstTabId, secondTabId, thirdTabId]))

        guard let confirmation = closeTabsConfirmationArgs(in: commands) else {
            throw TestFailure(message: "expected showCloseTabsConfirmation")
        }
        try expectEqual(closeTabsConfirmationEffectCount(commands), 1, "should emit one batch confirmation")
        try expectEqual(confirmation.tabIds, [firstTabId, secondTabId, thirdTabId])
        try expectEqual(confirmation.tabCount, 3)
        try expectEqual(model.groups.flatMap(\.tabs).map(\.id), tabIdsBefore, "tabs should remain until confirm")
        try expect(model.pendingConfirmation == .closeTab, "close-tab confirmation should be pending")
        // The request only shows the confirmation; no pane left the model, so
        // reconcileSurfaceExistence tears down nothing.
        try expect(surfacesToTearDown(liveSurfaceIds: liveBefore, model: model).isEmpty,
            "request should not tear down panes")
    }

    test("testRequestCloseTabsRollsUpPaneAndTodoCounts") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        let thirdTab = model.groups[0].tabs[2]
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitPane(direction: .horizontal))
        update(&model, .addTabTodo(tabId: secondTabId, text: "tab task"))
        update(&model, .addTodo(paneId: thirdTab.focusedPaneId, text: "pane task"))

        let commands = update(&model, .requestCloseTabs(ids: [firstTabId, secondTabId, thirdTab.id]))

        guard let confirmation = closeTabsConfirmationArgs(in: commands) else {
            throw TestFailure(message: "expected showCloseTabsConfirmation")
        }
        try expectEqual(confirmation.totalPaneCount, 4, "should roll up every pane in the batch")
        try expectEqual(confirmation.totalUncompletedTodos, 2, "should roll up tab and pane todos")
    }

    test("testRequestCloseTabsSetsIsQuitWhenBatchCoversEveryLiveTab") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)

        let commands = update(&model, .requestCloseTabs(ids: ids))

        guard let confirmation = closeTabsConfirmationArgs(in: commands) else {
            throw TestFailure(message: "expected showCloseTabsConfirmation")
        }
        try expect(confirmation.isQuit, "closing every live tab should set isQuit")
    }

    test("testRequestCloseTabsSingleIdDelegatesToRequestCloseTab") {
        var base = makeModel()
        createTab(&base)
        createTab(&base)
        let firstTabId = base.groups[0].tabs[0].id
        var direct = base
        var batch = base

        let liveBefore = Set(base.allPaneIds)
        let directEffects = update(&direct, .requestCloseTab(id: firstTabId))
        let batchEffects = update(&batch, .requestCloseTabs(ids: [firstTabId]))

        try expectEqual(batch, direct, "single-id batch should match direct request model mutation")
        // Equal models -> equal teardown selection (reconcileSurfaceExistence is a pure
        // function of the model + live surfaces).
        try expectEqual(surfacesToTearDown(liveSurfaceIds: liveBefore, model: batch),
                        surfacesToTearDown(liveSurfaceIds: liveBefore, model: direct))
        try expectEqual(effectCount(batchEffects) { if case .scheduleCheckpoint = $0 { return true }; return false },
                        effectCount(directEffects) { if case .scheduleCheckpoint = $0 { return true }; return false })
    }

    test("testRequestCloseTabsEmptyIdsIsNoOp") {
        var model = makeModel()
        let snapshot = model

        let commands = update(&model, .requestCloseTabs(ids: []))

        try expectEqual(commands.count, 0)
        try expectEqual(model, snapshot, "empty batch should not mutate model")
    }

    test("testRequestCloseTabsFiltersStaleIdsBeforeSingletonDelegation") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let liveTabId = model.groups[0].tabs[0].id
        let liveTabPaneId = model.groups[0].tabs[0].focusedPaneId
        let staleTabId = TabId()
        let liveBefore = Set(model.allPaneIds)

        update(&model, .requestCloseTabs(ids: [staleTabId, liveTabId]))

        try expect(!model.groups[0].tabs.contains { $0.id == liveTabId }, "live tab should be closed")
        try expectEqual(model.groups[0].tabs.count, 1, "stale id should be ignored")
        // The delegated close removed the live tab's pane, so reconcileSurfaceExistence
        // tears its surface down.
        try expect(surfacesToTearDown(liveSurfaceIds: liveBefore, model: model).contains(liveTabPaneId),
            "delegated close tears down the live tab pane")
    }

    test("testRequestCloseTabsDeduplicatesIdsForConfirmation") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitPane(direction: .horizontal))

        let commands = update(&model, .requestCloseTabs(ids: [firstTabId, secondTabId, firstTabId, secondTabId]))

        guard let confirmation = closeTabsConfirmationArgs(in: commands) else {
            throw TestFailure(message: "expected showCloseTabsConfirmation")
        }
        try expectEqual(confirmation.tabIds, [firstTabId, secondTabId])
        try expectEqual(confirmation.tabCount, 2)
        try expectEqual(confirmation.totalPaneCount, 3)
        try expect(confirmation.isQuit, "unique-id coverage should drive isQuit")
    }

    test("testRequestCloseTabsBatchNoOpsWhenConfirmationPending") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)
        model.pendingConfirmation = .closeTab

        let commands = update(&model, .requestCloseTabs(ids: ids))

        try expectEqual(commands.count, 0, "pending confirmation should block batch sheet")
        try expectEqual(model.groups[0].tabs.map(\.id), ids, "blocked batch should not close simple tabs")
    }

    test("testConfirmCloseTabsRemovesEveryRequestedTabAndClearsPending") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        let thirdTabId = model.groups[0].tabs[2].id
        update(&model, .selectTab(id: firstTabId))
        update(&model, .splitPane(direction: .horizontal))
        let expectedDestroyed = Set(paneIdsForTab(firstTabId, in: model) + paneIdsForTab(secondTabId, in: model))
        model.pendingConfirmation = .closeTab
        let liveBefore = Set(model.allPaneIds)

        update(&model, .confirmCloseTabs(ids: [firstTabId, secondTabId]))

        try expect(model.pendingConfirmation == nil, "confirm should clear pending confirmation")
        try expectEqual(Set(model.groups.flatMap(\.tabs).map(\.id)), Set([thirdTabId]))
        // Surface teardown is reconcileSurfaceExistence's: every pane in both closed tabs
        // is selected once absent from the model.
        try expectEqual(surfacesToTearDown(liveSurfaceIds: liveBefore, model: model), expectedDestroyed)
        for paneId in expectedDestroyed {
            try expect(model.pane(paneId) == nil, "closed tab pane should be removed")
        }
    }

    test("testConfirmCloseTabsEmptyingBatchTerminatesWithoutReloadOrCheckpoint") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)
        model.pendingConfirmation = .closeTab

        let commands = update(&model, .confirmCloseTabs(ids: ids))

        try expectEqual(effectCount(commands) { if case .terminate = $0 { return true }; return false },
                        1, "emptying batch should emit exactly one terminate")
        try expect(isTerminateEffect(commands.last), "terminate should be the final command")
        try expectEqual(effectCount(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                        0, "emptying batch should not schedule a checkpoint after terminate")
    }

    test("testConfirmCloseTabsNonEmptyingBatchReloadsAndCheckpointsOnce") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let secondTabId = model.groups[0].tabs[1].id
        let thirdTabId = model.groups[0].tabs[2].id
        update(&model, .selectTab(id: secondTabId))
        model.pendingConfirmation = .closeTab

        let commands = update(&model, .confirmCloseTabs(ids: [secondTabId, thirdTabId]))

        try expectEqual(Set(model.groups.flatMap(\.tabs).map(\.id)), Set([firstTabId]))
        try expectEqual(model.selectedTabId, firstTabId, "selection should move to a remaining tab")
        try expectEqual(effectCount(commands) { if case .scheduleCheckpoint = $0 { return true }; return false },
                        1, "non-emptying batch should checkpoint once")
        try expectEqual(effectCount(commands) { if case .terminate = $0 { return true }; return false },
                        0, "non-emptying batch should not terminate")
    }

    test("testCancelCloseTabsClearsPendingAndRemovesNothing") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)
        model.pendingConfirmation = .closeTab

        let commands = update(&model, .cancelCloseTabs)

        try expectEqual(commands.count, 0, "cancel should produce no commands")
        try expect(model.pendingConfirmation == nil, "cancel should clear pending confirmation")
        try expectEqual(model.groups[0].tabs.map(\.id), ids)
    }

    // MARK: - Tab Color

    test("testSetTabColor") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let commands = update(&model, .setTabColors(tabIds: [tabId], color: .red))
        try expectEqual(model.groups[0].tabs[0].color, .red)
        try expect(hasEffect(commands) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "should persist via scheduleCheckpoint (color reconciles via reconcileSidebar)")
    }

    test("testSetTabColorClear") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        update(&model, .setTabColors(tabIds: [tabId], color: .blue))

        let commands = update(&model, .setTabColors(tabIds: [tabId], color: nil))
        try expect(model.groups[0].tabs[0].color == nil, "color should be nil")
        try expect(hasEffect(commands) {
            if case .scheduleCheckpoint = $0 { return true }
            return false
        }, "should persist via scheduleCheckpoint (color reconciles via reconcileSidebar)")
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
        let firstPaneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let secondTabId = model.groups[0].tabs[1].id
        // secondTabId is now selected
        let liveBefore = Set(model.allPaneIds)

        update(&model, .closeTab(id: firstTabId))
        try expectEqual(model.selectedTabId, secondTabId, "selection should remain on second tab")
        try expectEqual(model.groups[0].tabs.count, 1)
        // Closing a non-selected tab does not change selection (asserted above), so
        // reconcileContainers leaves the visible tab alone and just removes the closed tab's
        // (hidden) container; reconcileSurfaceExistence tears down its pane.
        try expectEqual(surfacesToTearDown(liveSurfaceIds: liveBefore, model: model), Set([firstPaneId]),
            "closed non-selected tab's pane surface is torn down")
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

        let commands = update(&model, .setTabColors(
            tabIds: [id1, id1, stale, id2], color: .purple))

        try expectEqual(model.groups[0].tabs[0].color, .purple)
        try expectEqual(model.groups[0].tabs[1].color, .purple)
        // Per-tab row updates now reconcile; only scheduleCheckpoint remains.
        try expectEqual(commands.count, 1,
            "no double-dispatch for duplicates; stale dropped")
    }

    test("testSetTabColorsAllStaleIsNoop") {
        var model = makeModel()
        createTab(&model)
        let snapshot = model.groups
        let stale1 = TabId()
        let stale2 = TabId()

        let commands = update(&model, .setTabColors(
            tabIds: [stale1, stale2], color: .red))

        try expectEqual(model.groups, snapshot)
        try expectEqual(commands.count, 0)
    }
}

private func closeTabsConfirmationArgs(
    in commands: [Command]
) -> (tabIds: [TabId], tabCount: Int, totalPaneCount: Int, totalUncompletedTodos: Int, isQuit: Bool)? {
    for command in commands {
        if case .showCloseTabsConfirmation(
            let tabIds,
            let tabCount,
            let totalPaneCount,
            let totalUncompletedTodos,
            let isQuit
        ) = command {
            return (tabIds, tabCount, totalPaneCount, totalUncompletedTodos, isQuit)
        }
    }
    return nil
}

private func closeTabsConfirmationEffectCount(_ commands: [Command]) -> Int {
    effectCount(commands) {
        if case .showCloseTabsConfirmation = $0 { return true }
        return false
    }
}

private func effectCount(_ commands: [Command], matching predicate: (Command) -> Bool) -> Int {
    commands.filter(predicate).count
}

private func isTerminateEffect(_ command: Command?) -> Bool {
    guard let command else { return false }
    if case .terminate = command { return true }
    return false
}
