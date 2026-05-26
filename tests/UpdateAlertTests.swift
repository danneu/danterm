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
        try expect(!alertTestHasTabContainerEffect(effects), "should not refresh tab container")
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0,
               tid == model.groups[0].tabs[0].id { return true }
            return false
        }, "should refresh alert tab row")
        try expect(!alertTestHasReloadSidebar(effects), "should not reload sidebar")
    }

    test("testMarkAlertReadForStalePaneSkipsSidebarUpdate") {
        var model = makeModel()
        createTab(&model)
        let stalePaneId = PaneId()

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: stalePaneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .markAlertRead(alertId: alertId))
        try expectEqual(model.alerts[0].isUnread, false)
        try expectEqual(alertTestEffectCount(effects) {
            if case .updateSidebarTabRow = $0 { return true }
            return false
        }, 0, "stale alert should not refresh any tab row")
        try expect(!alertTestHasReloadSidebar(effects), "stale alert should not reload sidebar")
    }

    test("testMarkAllAlertsRead") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId
        createTab(&model)
        let paneB = model.groups[0].tabs[1].focusedPaneId

        for paneId in [paneA, paneB, paneA] {
            model.alerts.insert(AlertModel(
                id: AlertId(), kind: .bell, paneId: paneId,
                title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
            ), at: 0)
        }

        let effects = update(&model, .markAllAlertsRead)
        try expect(model.alerts.allSatisfy { !$0.isUnread }, "all alerts should be read")
        try expect(!alertTestHasTabContainerEffect(effects), "should not refresh tab container")
        try expectEqual(alertTestEffectCount(effects) {
            if case .updateSidebarTabRow = $0 { return true }
            return false
        }, 2, "should refresh one row per affected tab")
        try expect(!alertTestHasReloadSidebar(effects), "should not reload sidebar")
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
        try expectEqual(alertTestShowSelectedTabCount(effects), 1, "cross-tab alert activation should show selected tab once")
    }

    test("testActivateAlertSameTabShowsSelectedTab") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId
        update(&model, .splitPane(direction: .horizontal))
        let tabId = model.groups[0].tabs[0].id

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .activateAlert(alertId: alertId))

        try expectEqual(model.selectedTabId, tabId, "should stay on current tab")
        try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneA, "should focus alert pane")
        try expectEqual(alertTestShowSelectedTabCount(effects), 1, "same-tab alert activation should explicitly show selected tab")
        try expect(!hasEffect(effects) {
            if case .rebuildTabContainer = $0 { return true }
            return false
        }, "same-tab non-zoom navigation should not rebuild tab container")
    }

    test("testActivateAlertSameTabZoomClearRebuildsContainer") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneB, "paneB should be focused before navigation")
        try expectEqual(model.groups[0].tabs[0].isZoomed, true, "tab should be zoomed before navigation")

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .activateAlert(alertId: alertId))

        let tab = model.groups[0].tabs[0]
        try expectEqual(tab.focusedPaneId, paneA, "should focus alert pane")
        try expectEqual(tab.isZoomed, false, "zoom should clear when navigating to hidden pane")
        try expectEqual(alertTestShowSelectedTabCount(effects), 1, "same-tab zoom navigation should show selected tab")
        try expect(hasEffect(effects) {
            if case .rebuildTabContainer(let tabId) = $0, tabId == tab.id { return true }
            return false
        }, "zoom clear should rebuild tab container")
    }

    test("testActivateAlertDoesNotMarkReadInManualMode") {
        var model = makeModel()
        model.config.alertClearMode = .manual
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
        try expectEqual(model.selectedTabId, tabId, "should still navigate to alert's tab")
        try expectEqual(model.alerts[0].isUnread, true, "manual mode: activateAlert should NOT mark alert read")
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneId { return true }
            return false
        }, "should still focus alert's pane")
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
        try expect(!alertTestHasTabContainerEffect(effects), "should not refresh tab container")
        try expect(!alertTestHasReloadSidebar(effects), "stale alert should not reload sidebar")
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
        try expectEqual(model.alerts[0].body, model.pane(paneId)?.title ?? "", "newest alert should be first")
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

    test("testCloseZoomedPaneClearsAlertOnNewlyFocusedPane") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        // Focus paneA and zoom it
        update(&model, .paneBecameFirstResponder(paneId: paneA))
        update(&model, .toggleZoomPane)

        // paneB gets an alert while paneA is zoomed
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        // Close the zoomed pane — focus should move to paneB and clear its alerts
        update(&model, .closePane(paneId: paneA))
        try expect(model.groups[0].tabs[0].focusedPaneId == paneB, "paneB should be focused after closing paneA")
        try expect(!model.alerts[0].isUnread, "alert on newly focused pane should be marked read")
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

    test("testGoToMostRecentAlertPaneIntraTabNavigatesToAlertPane") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        update(&model, .paneBecameFirstResponder(paneId: paneA))
        try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneA)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "intra-tab", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .goToMostRecentAlertPane)

        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneB { return true }
            return false
        }, "should focus paneB")

        try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneB,
            "tab's focusedPaneId should be paneB after navigation")
        try expectEqual(model.alerts[0].isUnread, false,
            "paneB's alert should be marked read after focus moves to it")
    }

    test("testGoToMostRecentAlertPaneIntraTabDoesNotAckSiblingInManualMode") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        update(&model, .paneBecameFirstResponder(paneId: paneA))

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "intra-tab", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .goToMostRecentAlertPane)

        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneB { return true }
            return false
        }, "should focus paneB")

        try expectEqual(model.alerts[0].isUnread, true,
            "paneB's alert should remain unread")
    }

    test("testGoToMostRecentAlertPaneRepeatedPressWalksPanesInTab") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .vertical))
        let paneC = model.groups[0].tabs[0].focusedPaneId

        update(&model, .paneBecameFirstResponder(paneId: paneA))
        try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneA)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneC,
            title: "DanTerm", body: "older", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "newer", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .goToMostRecentAlertPane)
        try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneB,
            "press 1 should land on paneB")
        try expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == true,
            "paneB unread after press 1")
        try expect(model.alerts.first(where: { $0.paneId == paneC })?.isUnread == true,
            "paneC unread after press 1")

        update(&model, .goToMostRecentAlertPane)
        try expectEqual(model.groups[0].tabs[0].focusedPaneId, paneC,
            "press 2 should land on paneC")
        try expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == false,
            "paneB acked on press 2")
        try expect(model.alerts.first(where: { $0.paneId == paneC })?.isUnread == true,
            "paneC unread until press 3")

        update(&model, .goToMostRecentAlertPane)
        try expect(model.alerts.first(where: { $0.paneId == paneC })?.isUnread == false,
            "paneC acked on press 3")
        try expect(!model.alerts.contains(where: { $0.isUnread }),
            "all alerts read after walking through siblings")
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

    test("testGoToMostRecentAlertPaneAcksCurrentTabFirst") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)  // tab1 with paneA
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)  // tab2 (selected) with paneB
        let paneB = model.groups[0].tabs[1].focusedPaneId

        // paneA's alert at index 0 (most recent), paneB's at index 1
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "tab1 alert", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "tab2 alert", createdAt: Date(), isUnread: true
        ), at: 1)

        let effects = update(&model, .goToMostRecentAlertPane)
        // tab2's alert should be acked
        try expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == false, "current tab's alert should be acked")
        // paneA's alert should still be unread (manual mode, selectTab won't auto-clear)
        try expect(model.alerts.first(where: { $0.paneId == paneA })?.isUnread == true, "destination alert should still be unread")
        // Should navigate to tab1/paneA
        try expectEqual(model.selectedTabId, tab1Id, "should navigate to tab1")
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should focus paneA")
    }

    test("testGoToMostRecentAlertPaneAcksCurrentTabThenNoMoreAlerts") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)  // single tab (selected)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "only alert", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .goToMostRecentAlertPane)
        try expectEqual(model.alerts[0].isUnread, false, "alert should be acked")
        try expect(!hasEffect(effects) {
            if case .makeFirstResponder = $0 { return true }
            return false
        }, "no unread alerts remained after acking current tab")
        try expect(!alertTestHasTabContainerEffect(effects), "should not refresh tab container")
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0,
               tid == model.selectedTabId { return true }
            return false
        }, "should refresh selected tab row")
        try expect(!alertTestHasReloadSidebar(effects), "should not reload sidebar")
    }

    test("testGoToMostRecentAlertPaneRepeatedPressWalksTabs") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)  // tab1 with paneA
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)  // tab2 with paneB
        let tab2Id = model.groups[0].tabs[1].id
        let paneB = model.groups[0].tabs[1].focusedPaneId

        createTab(&model)  // tab3 (selected), no alerts

        // paneA alert at index 0, paneB alert at index 1
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "tab1 alert", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "tab2 alert", createdAt: Date(), isUnread: true
        ), at: 1)

        // First press: tab3 has no alerts (no-op ack), navigates to tab1 (index 0)
        update(&model, .goToMostRecentAlertPane)
        try expectEqual(model.selectedTabId, tab1Id, "first press should navigate to tab1")
        try expect(model.alerts.first(where: { $0.paneId == paneA })?.isUnread == true, "paneA alert still unread after first press")

        // Second press: acks tab1, navigates to tab2 (index 1)
        update(&model, .goToMostRecentAlertPane)
        try expectEqual(model.selectedTabId, tab2Id, "second press should navigate to tab2")
        try expect(model.alerts.first(where: { $0.paneId == paneA })?.isUnread == false, "paneA alert should be acked after second press")
        try expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == true, "paneB alert still unread after second press")

        // Third press: acks tab2, no more unread alerts
        let effects = update(&model, .goToMostRecentAlertPane)
        try expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == false, "paneB alert should be acked after third press")
        try expect(!alertTestHasTabContainerEffect(effects), "third press should not refresh tab container")
        try expect(!hasEffect(effects) {
            if case .makeFirstResponder = $0 { return true }
            return false
        }, "third press should not navigate")
    }

    test("testGoToMostRecentAlertPaneAcksOnlyFocusedPaneInSplit") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)  // tab1 with paneA
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)  // tab2 (selected), split into paneB + paneC
        update(&model, .splitPane(direction: .horizontal))
        let paneC = model.groups[0].tabs[1].focusedPaneId
        // paneB is the other pane in the split
        let tab2PaneIds = allPaneIds(model.groups[0].tabs[1].rootNode)
        let paneB = tab2PaneIds.first(where: { $0 != paneC })!

        // Alert on paneA (another tab), alerts on both split panes
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "tab1 alert", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "split pane B", createdAt: Date(), isUnread: true
        ), at: 1)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneC,
            title: "DanTerm", body: "split pane C", createdAt: Date(), isUnread: true
        ), at: 2)

        let effects = update(&model, .goToMostRecentAlertPane)
        try expect(model.alerts.first(where: { $0.paneId == paneC })?.isUnread == false,
            "focused pane's alert should be acked")
        try expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == true,
            "non-focused sibling alert should remain unread")
        // paneA alert should still be unread
        try expect(model.alerts.first(where: { $0.paneId == paneA })?.isUnread == true, "paneA alert should still be unread")
        // Should navigate to tab1/paneA
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should navigate to paneA")
    }

    // MARK: - filteredAlerts / alertsEmptyText Tests

    test("testFilteredAlertsUnreadReturnsOnlyUnread") {
        let paneId = PaneId()
        let alerts = [
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "a", createdAt: Date(), isUnread: true),
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "b", createdAt: Date(), isUnread: false),
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "c", createdAt: Date(), isUnread: true),
        ]
        let result = filteredAlerts(alerts, tab: .unread)
        try expectEqual(result.count, 2, "should return only unread alerts")
        try expectEqual(result[0].body, "a")
        try expectEqual(result[1].body, "c")
    }

    test("testFilteredAlertsHistoryReturnsAll") {
        let paneId = PaneId()
        let alerts = [
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "a", createdAt: Date(), isUnread: true),
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "b", createdAt: Date(), isUnread: false),
        ]
        let result = filteredAlerts(alerts, tab: .history)
        try expectEqual(result.count, 2, "history should return all alerts")
        try expectEqual(result[0].body, "a")
        try expectEqual(result[1].body, "b")
    }

    test("testFilteredAlertsUnreadAllReadReturnsEmpty") {
        let paneId = PaneId()
        let alerts = [
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "a", createdAt: Date(), isUnread: false),
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "b", createdAt: Date(), isUnread: false),
        ]
        let result = filteredAlerts(alerts, tab: .unread)
        try expectEqual(result.count, 0, "all-read list should return empty for unread tab")
    }

    test("testAlertsEmptyTextReturnsCorrectString") {
        try expectEqual(alertsEmptyText(tab: .unread), "No unread alerts")
        try expectEqual(alertsEmptyText(tab: .history), "No alerts")
    }

    test("testSetShowAllAlerts") {
        var model = makeModel()
        try expectEqual(model.showAllAlerts, false, "defaults to false")
        update(&model, .setShowAllAlerts(true))
        try expectEqual(model.showAllAlerts, true)
        update(&model, .setShowAllAlerts(false))
        try expectEqual(model.showAllAlerts, false)
    }

    // MARK: - alert-clear-mode = manual

    test("testSelectTabDoesNotClearAlertsInManualMode") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .selectTab(id: tabAId))
        try expectEqual(model.alerts[0].isUnread, true, "manual mode: selecting tab should NOT mark alerts read")
    }

    test("testPaneBecameFirstResponderDoesNotClearAlertsInManualMode") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .paneBecameFirstResponder(paneId: paneA))
        try expectEqual(model.alerts[0].isUnread, true, "manual mode: focusing pane should NOT mark alerts read")
    }

    test("testCloseZoomedPaneDoesNotClearAlertsInManualMode") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        update(&model, .paneBecameFirstResponder(paneId: paneA))
        update(&model, .toggleZoomPane)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .closePane(paneId: paneA))
        try expectEqual(model.alerts[0].isUnread, true, "manual mode: closePane should NOT clear alerts on newly focused pane")
    }

    test("testMovePaneToTabDoesNotClearAlertsInManualMode") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))
        try expectEqual(model.alerts[0].isUnread, true, "manual mode: movePaneToTab should NOT clear alerts")
    }

    test("testMovePaneToNewTabDoesNotClearAlertsInManualMode") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId
        update(&model, .splitPane(direction: .horizontal))
        let groupId = model.groups[0].id

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .movePaneToNewTab(paneId: paneA, inGroupId: groupId, atIndex: 1))
        try expectEqual(model.alerts[0].isUnread, true, "manual mode: movePaneToNewTab should NOT clear alerts")
    }

    // MARK: - clearAlertsForPane

    test("testClearAlertsForPaneClearsAlerts") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .clearAlertsForPane(paneId: paneA))
        try expectEqual(model.alerts[0].isUnread, false, "clearAlertsForPane should mark pane's alerts read")
        try expect(!alertTestHasTabContainerEffect(effects), "should not refresh tab container")
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0,
               tid == model.groups[0].tabs[0].id { return true }
            return false
        }, "should refresh pane's tab row")
        try expect(!alertTestHasReloadSidebar(effects), "should not reload sidebar")
    }

    test("testClearAlertsForPaneNoopsWhenNoUnreadAlerts") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .clearAlertsForPane(paneId: paneA))
        try expectEqual(effects.count, 0, "clearAlertsForPane with no unread alerts should be a no-op")
    }

    test("testClearAlertsForNonFocusedPane") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        // Split to create a second pane (which becomes focused)
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        try expect(paneA != paneB, "split should create a new pane")

        // Add alert for the non-focused pane
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        // Clear alerts for paneA (not focused) while paneB is focused
        let effects = update(&model, .clearAlertsForPane(paneId: paneA))
        try expectEqual(model.alerts[0].isUnread, false, "clearAlertsForPane should clear non-focused pane's alerts")
        try expect(!alertTestHasTabContainerEffect(effects), "should not refresh tab container")
    }

    // MARK: - ackTabAlerts

    test("testAckTabAlertsClearsAllPaneAlertsInTab") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        // Split to create a second pane
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        try expect(paneA != paneB, "split should create a new pane")

        // Add unread alerts for both panes
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .ackTabAlerts)
        try expectEqual(model.alerts.filter { $0.isUnread }.count, 0, "all tab alerts should be marked read")
        try expect(!alertTestHasTabContainerEffect(effects), "should not refresh tab container")
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0,
               tid == model.selectedTabId { return true }
            return false
        }, "should refresh selected tab row")
        try expect(!alertTestHasReloadSidebar(effects), "should not reload sidebar")
    }

    test("testAckTabAlertsDoesNotAffectOtherTabs") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let tab1PaneId = model.groups[0].tabs[0].focusedPaneId

        // Create a second tab and add alerts to both
        createTab(&model)
        let tab2PaneId = model.groups[0].tabs[1].focusedPaneId

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: tab1PaneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: tab2PaneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        // Select tab 2 and clear its alerts
        update(&model, .selectTab(id: model.groups[0].tabs[1].id))
        update(&model, .ackTabAlerts)

        let tab1Alert = model.alerts.first { $0.paneId == tab1PaneId }!
        let tab2Alert = model.alerts.first { $0.paneId == tab2PaneId }!
        try expectEqual(tab1Alert.isUnread, true, "other tab's alerts should remain unread")
        try expectEqual(tab2Alert.isUnread, false, "selected tab's alerts should be cleared")
    }

    test("testAckTabAlertsNoopsWhenNoUnreadAlerts") {
        var model = makeModel()
        createTab(&model)

        let effects = update(&model, .ackTabAlerts)
        try expectEqual(effects.count, 0, "ackTabAlerts with no unread alerts should be a no-op")
    }

    // MARK: - clearAlertsForTab

    test("testClearAlertsForTabClearsSpecificTab") {
        var model = makeModel()
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let tab1Pane = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let tab2Pane = model.groups[0].tabs[1].focusedPaneId

        // Add unread alerts for both tabs
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: tab1Pane,
            title: "DanTerm", body: "tab1", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: tab2Pane,
            title: "DanTerm", body: "tab2", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .clearAlertsForTabs(tabIds: [tab1Id]))
        let tab1Alert = model.alerts.first { $0.paneId == tab1Pane }!
        let tab2Alert = model.alerts.first { $0.paneId == tab2Pane }!
        try expectEqual(tab1Alert.isUnread, false, "target tab's alerts should be cleared")
        try expectEqual(tab2Alert.isUnread, true, "other tab's alerts should remain unread")
        try expect(!alertTestHasTabContainerEffect(effects), "should not refresh tab container")
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0, tid == tab1Id { return true }
            return false
        }, "should refresh cleared tab row")
        try expect(!alertTestHasReloadSidebar(effects), "should not reload sidebar")
    }

    test("testClearAlertsForTabNoopsWhenNoUnreadAlerts") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let effects = update(&model, .clearAlertsForTabs(tabIds: [tabId]))
        try expectEqual(effects.count, 0, "clearAlertsForTabs with no unread alerts should be a no-op")
    }

    test("testGoToMostRecentAlertPaneUnzoomsIfNeeded") {
        var model = makeModel()
        createTab(&model)  // tab1 with paneA
        let paneA = model.groups[0].tabs[0].focusedPaneId

        // Split tab1 to get paneB, then zoom paneB
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        update(&model, .toggleZoomPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, true)

        // Create tab2 so we navigate back to tab1 (acking tab2 first is a no-op)
        createTab(&model)

        // Alert targets paneA on tab1 (not the zoomed paneB)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .goToMostRecentAlertPane)
        try expectEqual(model.groups[0].tabs[0].isZoomed, false, "zoom should clear when navigating to different pane")
        _ = paneB
    }

    // MARK: - clearAlertsForTabs (batch from multi-select context menu)

    test("testClearAlertsForTabsClearsAllSelected") {
        var model = makeModel()
        createTab(&model) // tab1
        createTab(&model) // tab2
        createTab(&model) // tab3 — alerts should remain on this one
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        let id3 = model.groups[0].tabs[2].id
        let pane1 = model.groups[0].tabs[0].focusedPaneId
        let pane2 = model.groups[0].tabs[1].focusedPaneId
        let pane3 = model.groups[0].tabs[2].focusedPaneId

        for pid in [pane1, pane2, pane3] {
            model.alerts.insert(AlertModel(
                id: AlertId(), kind: .bell, paneId: pid,
                title: "x", body: "y", createdAt: Date(), isUnread: true
            ), at: 0)
        }

        let effects = update(&model, .clearAlertsForTabs(tabIds: [id1, id2]))

        let unreadByPane: (PaneId) -> Bool = { pid in
            model.alerts.contains { $0.paneId == pid && $0.isUnread }
        }
        try expect(!unreadByPane(pane1), "tab1 alerts cleared")
        try expect(!unreadByPane(pane2), "tab2 alerts cleared")
        try expect(unreadByPane(pane3), "tab3 alert preserved")
        try expectEqual(alertTestEffectCount(effects) {
            if case .updateSidebarTabRow = $0 { return true }
            return false
        }, 2, "should refresh one row per cleared tab")
        try expect(!alertTestHasReloadSidebar(effects), "should not reload sidebar")
        try expect(!alertTestHasTabContainerEffect(effects), "should not refresh tab container")
        _ = id3
    }

    test("testClearAlertsForTabsRefreshesOnlyTabsWithUnreadAlerts") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        let pane1 = model.groups[0].tabs[0].focusedPaneId

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: pane1,
            title: "x", body: "y", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .clearAlertsForTabs(tabIds: [id1, id2]))

        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0, tid == id1 { return true }
            return false
        }, "tab with unread alerts should refresh")
        try expect(!hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0, tid == id2 { return true }
            return false
        }, "tab without unread alerts should not refresh")
        try expect(!alertTestHasReloadSidebar(effects), "should not reload sidebar")
    }

    test("testClearAlertsForTabsNoUnreadIsNoop") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id
        // No alerts inserted.

        let effects = update(&model, .clearAlertsForTabs(tabIds: [id1, id2]))
        try expectEqual(effects.count, 0,
            "no unread alerts on any selected tab → no-op")
    }

    test("testClearAlertsForTabsAllStaleIsNoop") {
        var model = makeModel()
        createTab(&model)
        let pane = model.groups[0].tabs[0].focusedPaneId
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: pane,
            title: "x", body: "y", createdAt: Date(), isUnread: true
        ), at: 0)

        let effects = update(&model, .clearAlertsForTabs(
            tabIds: [TabId(), TabId()]))

        try expectEqual(effects.count, 0, "all stale ids → no-op")
        try expect(model.alerts.contains { $0.isUnread },
            "real alerts unaffected by stale-id batch")
    }
}

private func alertTestHasTabContainerEffect(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .showSelectedTab = $0 { return true }
        if case .rebuildTabContainer = $0 { return true }
        return false
    }
}

private func alertTestShowSelectedTabCount(_ effects: [Effect]) -> Int {
    effects.filter {
        if case .showSelectedTab = $0 { return true }
        return false
    }.count
}


private func alertTestHasReloadSidebar(_ effects: [Effect]) -> Bool {
    hasEffect(effects) {
        if case .reloadSidebar = $0 { return true }
        return false
    }
}

private func alertTestEffectCount(_ effects: [Effect], matching predicate: (Effect) -> Bool) -> Int {
    effects.filter(predicate).count
}
