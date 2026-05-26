import Foundation

func lifecycleTests() {
    print("Lifecycle Tests...")

    test("testAppBecameActive") {
        var model = makeModel()
        let commands = update(&model, .appBecameActive)
        try expectEqual(commands.count, 1)
        if case .setAppFocus(let focused) = commands[0] {
            try expectEqual(focused, true)
        } else {
            throw TestFailure(message: "expected setAppFocus(true)")
        }
    }

    test("testAppResignedActive") {
        var model = makeModel()
        let commands = update(&model, .appResignedActive)
        try expectEqual(commands.count, 1)
        if case .setAppFocus(let focused) = commands[0] {
            try expectEqual(focused, false)
        } else {
            throw TestFailure(message: "expected setAppFocus(false)")
        }
    }

    test("testActivateAlert") {
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let firstPaneId = model.groups[0].tabs[0].focusedPaneId

        // Create second tab so selecting first is meaningful
        createTab(&model)

        // Add an unread alert for the first tab's pane
        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: firstPaneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .activateAlert(alertId: alertId))
        try expectEqual(model.selectedTabId, firstTabId, "should select the alert's tab")
        try expectEqual(model.alerts[0].isUnread, false, "alert should be marked read")
        try expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == firstPaneId { return true }
            return false
        }, "should make pane first responder")
        try expect(hasEffect(commands) {
            if case .activateApp = $0 { return true }
            return false
        }, "should activate app")
        try expect(hasEffect(commands) {
            if case .dismissAlertsPopover = $0 { return true }
            return false
        }, "should dismiss alerts popover")
    }

    test("testActivateAlertStalePane") {
        var model = makeModel()
        createTab(&model)

        // Create an alert referencing a pane that no longer exists
        let stalePaneId = PaneId()
        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: stalePaneId,
            title: "DanTerm", body: "stale", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .activateAlert(alertId: alertId))
        try expectEqual(model.alerts[0].isUnread, false, "stale alert should be marked read")
        try expect(!hasEffect(commands) {
            if case .makeFirstResponder = $0 { return true }
            return false
        }, "should not navigate when pane is gone")
        try expect(hasEffect(commands) {
            if case .dismissAlertsPopover = $0 { return true }
            return false
        }, "should still dismiss popover")
    }

    test("testActivateAlertWhileZoomedClearsZoom") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        // Split and zoom paneB
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, true)

        // Alert targets paneA (not the focused paneB)
        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .activateAlert(alertId: alertId))
        try expectEqual(model.groups[0].tabs[0].isZoomed, false, "zoom should clear when alert targets different pane")
        try expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should focus alert's pane")
        _ = paneB
    }

    test("testActivateAlertWhileZoomedSamePaneKeepsZoom") {
        var model = makeModel()
        createTab(&model)

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        update(&model, .toggleZoomPane)

        // Alert targets the already-focused paneB
        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneB,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        _ = update(&model, .activateAlert(alertId: alertId))
        try expectEqual(model.groups[0].tabs[0].isZoomed, true, "zoom should remain when alert targets same pane")
    }

    test("testTerminate") {
        var model = makeModel()
        let commands = update(&model, .terminate)
        try expectEqual(commands.count, 1)
        if case .terminate = commands[0] {
            // good
        } else {
            throw TestFailure(message: "expected terminate command")
        }
    }

    test("testRequestQuitWithOnePane") {
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .requestQuit)
        try expectEqual(commands.count, 1)
        try expect(hasEffect(commands) {
            if case .showTerminateConfirmation(let count) = $0, count == 1 { return true }
            return false
        }, "should show confirmation with pane count 1")
        try expect(model.pendingConfirmation == .terminate, "quit confirmation should be pending")
    }

    test("testRequestQuitWithMultiplePanes") {
        var model = makeModel()
        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        createTab(&model)
        let commands = update(&model, .requestQuit)
        try expectEqual(commands.count, 1)
        try expect(hasEffect(commands) {
            if case .showTerminateConfirmation(let count) = $0, count == 3 { return true }
            return false
        }, "should show confirmation with correct pane count")
        try expect(model.pendingConfirmation == .terminate, "quit confirmation should be pending")
    }

    test("testRequestQuitSetsPending") {
        var model = makeModel()
        createTab(&model)

        let commands = update(&model, .requestQuit)

        try expectEqual(commands.count, 1)
        if case .showTerminateConfirmation = commands[0] {
            // good
        } else {
            throw TestFailure(message: "expected showTerminateConfirmation")
        }
        try expect(model.pendingConfirmation == .terminate, "quit confirmation should be pending")
    }

    test("testRequestQuitWhileQuitPendingIsNoOp") {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .requestQuit)

        let commands = update(&model, .requestQuit)

        try expectEqual(commands.count, 0, "second requestQuit should not emit another confirmation")
    }

    test("testCloseTabLastTabWhileQuitPendingIsNoOp") {
        var model = makeModel()
        createTab(&model)
        let originalGroups = model.groups
        let originalPanes = model.allPanes
        let tabId = model.groups[0].tabs[0].id
        model.pendingConfirmation = .terminate

        let commands = update(&model, .closeTab(id: tabId))

        try expectEqual(commands.count, 0, "closeTab should be blocked by pending quit confirmation")
        try expectEqual(model.groups, originalGroups, "groups should be unchanged")
        try expectEqual(model.allPanes, originalPanes, "panes should be unchanged")
    }

    test("testClosePaneLastPaneWhileQuitPendingIsNoOp") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let originalPanes = model.allPanes
        model.pendingConfirmation = .terminate

        let commands = update(&model, .closePane(paneId: paneId))

        try expectEqual(commands.count, 0, "closePane should be blocked by pending quit confirmation")
        // No commands at all (asserted above) + the model unchanged means no surface is torn
        // down: reconcileSurfaceExistence only tears down panes absent from allPaneIds.
        try expectEqual(model.allPanes, originalPanes, "panes should be unchanged")
    }

    test("testDeleteGroupLastGroupTabsWhileQuitPendingIsNoOp") {
        var model = makeModel()
        createTab(&model)
        let tabsGroupId = model.groups[0].id
        let emptyGroupId = GroupId()
        model.groups.append(GroupModel(id: emptyGroupId, name: "Empty"))
        model.pendingConfirmation = .terminate

        let commands = update(&model, .deleteGroup(id: tabsGroupId, moveTabs: false))

        try expectEqual(commands.count, 0, "deleteGroup should be blocked by pending quit confirmation")
        try expect(model.groups.contains { $0.id == tabsGroupId }, "tabs group should remain")
        try expect(model.groups.contains { $0.id == emptyGroupId }, "empty group should remain")
    }

    test("testConfirmTerminateAlwaysTerminates") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let commands = update(&model, .confirmTerminate)
        try expectEqual(commands.count, 1)
        try expect(hasEffect(commands) {
            if case .terminate = $0 { return true }
            return false
        }, "should unconditionally terminate after confirmation")
    }

    test("testConfirmTerminateClearsPending") {
        var model = makeModel()
        createTab(&model)
        model.pendingConfirmation = .terminate

        let commands = update(&model, .confirmTerminate)

        try expectEqual(commands.count, 1)
        if case .terminate = commands[0] {
            // good
        } else {
            throw TestFailure(message: "expected terminate command")
        }
        try expect(model.pendingConfirmation == nil, "confirm should clear pending confirmation")
    }

    test("testCancelTerminate") {
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .cancelTerminate)
        try expectEqual(commands.count, 0, "cancel should produce no commands")
    }

    test("testCancelTerminateClearsPending") {
        var model = makeModel()
        createTab(&model)
        model.pendingConfirmation = .terminate

        let commands = update(&model, .cancelTerminate)

        try expectEqual(commands.count, 0, "cancel should produce no commands")
        try expect(model.pendingConfirmation == nil, "cancel should clear pending confirmation")
    }

    test("testRequestQuitAgainAfterCancel") {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .requestQuit)
        _ = update(&model, .cancelTerminate)

        let commands = update(&model, .requestQuit)

        try expectEqual(commands.count, 1)
        if case .showTerminateConfirmation = commands[0] {
            // good
        } else {
            throw TestFailure(message: "expected showTerminateConfirmation")
        }
    }

    test("testRequestQuitWhileCloseTabPendingIsNoOp") {
        var model = makeModel()
        createTab(&model)
        model.pendingConfirmation = .closeTab

        let commands = update(&model, .requestQuit)

        try expectEqual(commands.count, 0, "requestQuit should be blocked by pending close-tab confirmation")
        try expect(!hasEffect(commands) {
            if case .showTerminateConfirmation = $0 { return true }
            return false
        }, "should not emit terminate confirmation")
    }

    test("testCloseTabConfirmationResponseConfirm") {
        let tabId = TabId()

        let msg = closeTabConfirmationResponse(isConfirm: true, tabId: tabId)

        if case .confirmCloseTab(let returnedId) = msg {
            try expectEqual(returnedId, tabId, "confirm should carry the tab id")
        } else {
            throw TestFailure(message: "expected confirmCloseTab")
        }
    }

    test("testCloseTabConfirmationResponseCancel") {
        let msg = closeTabConfirmationResponse(isConfirm: false, tabId: TabId())

        if case .cancelCloseTab = msg {
            // good
        } else {
            throw TestFailure(message: "expected cancelCloseTab")
        }
    }
}
