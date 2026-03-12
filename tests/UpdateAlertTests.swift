import Foundation

func alertTests() {
    print("Alert Tests...")

    test("testMarkAlertRead") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .markAlertRead(alertId: alertId))
        try expectEqual(model.alerts[0].isUnread, false)
        try expect(hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should rebuild content view")
        try expect(hasEffect(effects) {
            if case .reloadSidebar = $0 { return true }
            return false
        }, "should reload sidebar")
    }

    test("testMarkAllAlertsRead") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        for _ in 0..<3 {
            model.alerts.insert(AlertModel(
                id: AlertId(), kind: .bell, paneId: paneId,
                title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
            ), at: 0)
        }

        let effects = update(&model, .markAllAlertsRead)
        try expect(model.alerts.allSatisfy { !$0.isUnread }, "all alerts should be read")
        try expect(hasEffect(effects) {
            if case .rebuildContentView = $0 { return true }
            return false
        }, "should rebuild content view")
    }

    test("testActivateAlertNavigatesAndMarksRead") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].focusedPaneId

        // Switch to second tab
        createTab(&model)

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .activateAlert(alertId: alertId))
        try expectEqual(model.selectedTabId, tabId, "should navigate to alert's tab")
        try expectEqual(model.alerts[0].isUnread, false, "alert should be marked read")
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneId { return true }
            return false
        }, "should focus alert's pane")
        try expect(hasEffect(effects) {
            if case .activateApp = $0 { return true }
            return false
        }, "should activate app")
        try expect(hasEffect(effects) {
            if case .dismissAlertsPopover = $0 { return true }
            return false
        }, "should dismiss popover")
    }

    test("testActivateStaleAlertMarksReadButNoNavigation") {
        var model = makeModel()
        createTab(&model)

        let stalePaneId = PaneId()
        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: stalePaneId,
            title: "DanTerm", body: "stale", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .activateAlert(alertId: alertId))
        try expectEqual(model.alerts[0].isUnread, false, "should mark read")
        try expect(!hasEffect(effects) {
            if case .makeFirstResponder = $0 { return true }
            return false
        }, "should not navigate")
        try expect(hasEffect(effects) {
            if case .dismissAlertsPopover = $0 { return true }
            return false
        }, "should dismiss popover")
    }

    test("testAlertHistoryCappedAt100") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        // Create second tab so pane is in background
        createTab(&model)

        // Insert 100 alerts manually
        for i in 0..<100 {
            model.alerts.append(AlertModel(
                id: AlertId(), kind: .bell, paneId: paneId,
                title: "DanTerm", body: "alert \(i)", createdAt: Date(), isUnread: false
            ))
        }
        try expectEqual(model.alerts.count, 100)

        // Reset throttle so notification fires
        model.lastNotificationTime[paneId] = [.bell: Date.distantPast]

        // 101st alert via surfaceBell
        update(&model, .surfaceBell(paneId: paneId))
        try expectEqual(model.alerts.count, 100, "alerts should be capped at 100")
        try expectEqual(model.alerts[0].body, model.panes[paneId]?.title ?? "", "newest alert should be first")
    }

    test("testSelectTabMarksAlertsReadForFocusedPane") {
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        // Add unread alert for paneA
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .selectTab(id: tabAId))
        try expectEqual(model.alerts[0].isUnread, false, "selecting tab should mark focused pane's alerts read")
    }

    test("testPaneBecameFirstResponderMarksAlertsRead") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        // Add unread alert for paneA
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        // Focus paneA
        update(&model, .paneBecameFirstResponder(paneId: paneA))
        try expectEqual(model.alerts[0].isUnread, false, "focusing pane should mark its alerts read")
        _ = paneB
    }

    test("testClosePaneRemovesAlertsAndCleansUpThrottle") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))

        // Add unread alert and throttle data for paneA
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        model.lastNotificationTime[paneA] = [.bell: Date()]

        update(&model, .closePane(paneId: paneA))
        try expect(model.alerts.isEmpty, "closing pane should remove its alerts")
        try expect(model.lastNotificationTime[paneA] == nil, "closing pane should clean up throttle data")
    }

    test("testCloseTabRemovesAlertsForAllPanes") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        // Split to get a second pane
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        // Create second tab so closing the first doesn't terminate
        createTab(&model)

        // Add alerts for both panes
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "a", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "b", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .closeTab(id: tabId))
        try expect(model.alerts.isEmpty, "closing tab should remove alerts for all its panes")
    }

    test("testSurfaceCreationFailedRemovesAlerts") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        // Create second tab so closing the first doesn't terminate
        createTab(&model)

        // Add alert and throttle data for paneA
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        model.lastNotificationTime[paneA] = [.bell: Date()]

        update(&model, .surfaceCreationFailed(paneId: paneA))
        try expect(model.alerts.isEmpty, "surfaceCreationFailed should remove pane's alerts")
        try expect(model.lastNotificationTime[paneA] == nil, "surfaceCreationFailed should clean up throttle data")
    }

    test("testThrottleIsPerPanePerKind") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        // Fire a bell (creates alert + notification)
        let effects1 = update(&model, .surfaceBell(paneId: paneId))
        try expect(hasEffect(effects1) {
            if case .sendNotification = $0 { return true }
            return false
        }, "first bell should send notification")

        // Fire a desktop notification (different kind — should not be throttled)
        let effects2 = update(&model, .desktopNotification(paneId: paneId, title: "Done", body: "ok"))
        try expect(hasEffect(effects2) {
            if case .sendNotification = $0 { return true }
            return false
        }, "desktop notification should not be throttled by bell")

        // Fire another bell — should be throttled
        let effects3 = update(&model, .surfaceBell(paneId: paneId))
        try expect(!hasEffect(effects3) {
            if case .sendNotification = $0 { return true }
            return false
        }, "second bell should be throttled")
    }

    test("testActivateAlertFromMacOSNotification") {
        // Same code path as popover row click — just verifying the Msg works
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .activateAlert(alertId: alertId))
        try expectEqual(model.selectedTabId, tabId)
        try expectEqual(model.alerts[0].isUnread, false)
        try expect(hasEffect(effects) {
            if case .activateApp = $0 { return true }
            return false
        }, "should activate app")
    }

    // MARK: - goToMostRecentAlertPane Tests

    test("testGoToMostRecentAlertPaneNavigatesToPaneAndTab") {
        var model = makeModel()
        createTab(&model)  // tab1 with paneA
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)  // tab2 (now selected)
        try expect(model.selectedTabId != tab1Id, "tab2 should be selected")

        // Add alert for paneA on tab1
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .goToMostRecentAlertPane)
        try expectEqual(model.selectedTabId, tab1Id, "should switch to tab containing alert pane")
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should focus the alert's pane")
    }

    test("testGoToMostRecentAlertPaneSkipsStaleAlert") {
        var model = makeModel()
        createTab(&model)  // tab1
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)  // tab2 (now selected)
        let paneB = model.groups[0].tabs[0].focusedPaneId

        // Newest alert references a deleted pane (stale)
        let stalePaneId = PaneId()
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: stalePaneId,
            title: "DanTerm", body: "stale", createdAt: Date(), isUnread: true
        ), at: 0)

        // Second alert references valid paneA
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "valid", createdAt: Date(), isUnread: true
        ), at: 1)

        let effects = update(&model, .goToMostRecentAlertPane)
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should navigate to the first valid alert's pane")
        _ = paneB
    }

    test("testGoToMostRecentAlertPaneNoAlerts") {
        var model = makeModel()
        createTab(&model)

        let effects = update(&model, .goToMostRecentAlertPane)
        try expectEqual(effects.count, 0, "no alerts should produce no effects")
    }

    test("testGoToMostRecentAlertPaneUsesCurrentTabAfterMove") {
        var model = makeModel()
        createTab(&model)  // tab1 with paneA
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)  // tab2
        let tab2Id = model.groups[0].tabs[1].id

        // Add alert for paneA (while it's on tab1)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        // Move paneA to tab2 (this marks paneA's alerts read)
        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))
        model.alerts[0].isUnread = true  // re-mark unread so goToMostRecentAlertPane finds it

        // Now create tab3 so we're not already on tab2
        createTab(&model)

        // goToMostRecentAlertPane should use paneA's CURRENT tab (tab2), not the stale tab1
        let effects = update(&model, .goToMostRecentAlertPane)
        try expectEqual(model.selectedTabId, tab2Id, "should navigate to pane's current tab, not original tab")
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should focus the alert's pane")
    }

    test("testGoToMostRecentAlertPaneSkipsReadAlerts") {
        var model = makeModel()
        createTab(&model)  // tab1 with paneA
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)  // tab2 with paneB
        let paneB = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)  // tab3 (now selected)

        // Newest alert (index 0) is read — should be skipped
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "read", createdAt: Date(), isUnread: false
        ), at: 0)

        // Second alert (index 1) is unread — should be targeted
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "unread", createdAt: Date(), isUnread: true
        ), at: 1)

        let effects = update(&model, .goToMostRecentAlertPane)
        try expectEqual(model.selectedTabId, tab1Id, "should navigate to the unread alert's tab, skipping read alert")
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should focus the unread alert's pane")
    }

    test("testGoToMostRecentAlertPaneUnzoomsIfNeeded") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        // Split to get paneB, then zoom paneB
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, true)

        // Alert targets paneA (not zoomed paneB)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .goToMostRecentAlertPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, false, "zoom should clear when navigating to different pane")
        _ = paneB
    }
}
