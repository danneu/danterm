import Foundation

func lifecycleTests() {
    print("Lifecycle Tests...")

    test("testAppBecameActive") {
        var model = makeModel()
        let effects = update(&model, .appBecameActive)
        try expectEqual(effects.count, 1)
        if case .setAppFocus(let focused) = effects[0] {
            try expectEqual(focused, true)
        } else {
            throw TestFailure(message: "expected setAppFocus(true)")
        }
    }

    test("testAppResignedActive") {
        var model = makeModel()
        let effects = update(&model, .appResignedActive)
        try expectEqual(effects.count, 1)
        if case .setAppFocus(let focused) = effects[0] {
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
            id: alertId, kind: .bell, paneId: firstPaneId, tabId: firstTabId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .activateAlert(alertId: alertId))
        try expectEqual(model.selectedTabId, firstTabId, "should select the alert's tab")
        try expectEqual(model.alerts[0].isUnread, false, "alert should be marked read")
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == firstPaneId { return true }
            return false
        }, "should make pane first responder")
        try expect(hasEffect(effects) {
            if case .activateApp = $0 { return true }
            return false
        }, "should activate app")
        try expect(hasEffect(effects) {
            if case .dismissAlertsPopover = $0 { return true }
            return false
        }, "should dismiss alerts popover")
    }

    test("testActivateAlertStalePane") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        // Create an alert referencing a pane that no longer exists
        let stalePaneId = PaneId()
        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: stalePaneId, tabId: tabId,
            title: "DanTerm", body: "stale", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .activateAlert(alertId: alertId))
        try expectEqual(model.alerts[0].isUnread, false, "stale alert should be marked read")
        try expect(!hasEffect(effects) {
            if case .makeFirstResponder = $0 { return true }
            return false
        }, "should not navigate when pane is gone")
        try expect(hasEffect(effects) {
            if case .dismissAlertsPopover = $0 { return true }
            return false
        }, "should still dismiss popover")
    }

    test("testActivateAlertWhileZoomedClearsZoom") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        // Split and zoom paneB
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, true)

        // Alert targets paneA (not the focused paneB)
        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneA, tabId: tabId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .activateAlert(alertId: alertId))
        try expectEqual(model.groups[0].tabs[0].isZoomed, false, "zoom should clear when alert targets different pane")
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should focus alert's pane")
        _ = paneB
    }

    test("testActivateAlertWhileZoomedSamePaneKeepsZoom") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        update(&model, .toggleZoomPane)

        // Alert targets the already-focused paneB
        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneB, tabId: tabId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        _ = update(&model, .activateAlert(alertId: alertId))
        try expectEqual(model.groups[0].tabs[0].isZoomed, true, "zoom should remain when alert targets same pane")
    }

    test("testTerminate") {
        var model = makeModel()
        let effects = update(&model, .terminate)
        try expectEqual(effects.count, 1)
        if case .terminate = effects[0] {
            // good
        } else {
            throw TestFailure(message: "expected terminate effect")
        }
    }

    test("testConfirmTerminateWithOneTab") {
        var model = makeModel()
        createTab(&model)
        let effects = update(&model, .confirmTerminate)
        try expectEqual(effects.count, 1)
        try expect(hasEffect(effects) {
            if case .terminate = $0 { return true }
            return false
        }, "should terminate when only one tab remains")
    }

    test("testConfirmTerminateWithMultipleTabs") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let effects = update(&model, .confirmTerminate)
        try expectEqual(effects.count, 0, "should not terminate when multiple tabs exist")
    }

    test("testCancelTerminate") {
        var model = makeModel()
        createTab(&model)
        let effects = update(&model, .cancelTerminate)
        try expectEqual(effects.count, 0, "cancel should produce no effects")
    }
}
