import Foundation

func ghosttyTests() {
    print("Ghostty Tests...")

    test("testBellOnFocusedPaneIsIgnored") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .surfaceBell(paneId: paneId))
        try expectEqual(model.alerts.count, 0, "no alert for bell on focused pane")
        try expectEqual(effects.count, 0, "no effects for bell on focused pane")
    }

    test("testBellOnBackgroundPaneCreatesUnreadAlert") {
        var model = makeModel()
        createTab(&model)
        let firstTabPaneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        let effects = update(&model, .surfaceBell(paneId: firstTabPaneId))
        try expectEqual(model.alerts.count, 1, "should create one alert")
        try expectEqual(model.alerts[0].kind, .bell)
        try expectEqual(model.alerts[0].isUnread, true, "alert should be unread")
        try expectEqual(model.alerts[0].paneId, firstTabPaneId)
        try expect(hasEffect(effects) {
            if case .sendNotification = $0 { return true }
            return false
        }, "should emit sendNotification for background bell")
        try expect(hasEffect(effects) {
            if case .refreshPaneBorder(let pid) = $0, pid == firstTabPaneId { return true }
            return false
        }, "should emit refreshPaneBorder for background bell")
        try expect(hasEffect(effects) {
            if case .refreshPaneToolbar(let pid) = $0, pid == firstTabPaneId { return true }
            return false
        }, "should refresh pane toolbar for background bell")
    }

    test("testSurfaceCreationFailedCleansUp") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .surfaceCreationFailed(paneId: paneId))
        try expect(model.panes[paneId] == nil, "pane should be removed")
        try expectEqual(model.groups[0].tabs.count, 0, "tab should be removed")
        try expect(hasEffect(effects) {
            if case .terminate = $0 { return true }
            return false
        }, "should terminate when no tabs left")
        try expect(hasEffect(effects) {
            if case .destroySurface(let pid) = $0, pid == paneId { return true }
            return false
        }, "should destroy failed pane surface")
        try expect(hasEffect(effects) {
            if case .removeTabContainer = $0 { return true }
            return false
        }, "should remove failed tab container")
        try expect(!hasEffect(effects) {
            if case .showSelectedTab = $0 { return true }
            return false
        }, "last-tab failure should not show a fallback tab")
    }

    test("surfaceCreationFailed removes split tab siblings") {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        createTab(&model)
        let fallbackTabId = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: tabId))

        let effects = update(&model, .surfaceCreationFailed(paneId: paneA))

        try expectEqual(model.selectedTabId, fallbackTabId, "selection should move to fallback tab")
        try expect(model.panes[paneA] == nil, "failed pane should be removed")
        try expect(model.panes[paneB] == nil, "sibling pane should be removed")
        try expect(!model.groups[0].tabs.contains { $0.id == tabId }, "failed tab should be removed")
        try expect(hasEffect(effects) {
            if case .destroySurface(let pid) = $0, pid == paneA { return true }
            return false
        }, "should destroy failed pane surface")
        try expect(hasEffect(effects) {
            if case .destroySurface(let pid) = $0, pid == paneB { return true }
            return false
        }, "should destroy sibling pane surface")
        try expect(hasEffect(effects) {
            if case .removeTabContainer(let effectTabId) = $0, effectTabId == tabId { return true }
            return false
        }, "should remove failed tab container")
        try expect(hasEffect(effects) {
            if case .showSelectedTab = $0 { return true }
            return false
        }, "should show fallback tab")
        try expect(!hasEffect(effects) {
            if case .terminate = $0 { return true }
            return false
        }, "should not terminate when fallback tab remains")
    }

    test("testBellThrottling") {
        var model = makeModel()
        createTab(&model)
        let firstTabPaneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        // First bell
        update(&model, .surfaceBell(paneId: firstTabPaneId))
        try expect(model.lastNotificationTime[firstTabPaneId]?[.bell] != nil, "should set lastNotificationTime for bell")

        // Second bell immediately — should be throttled
        let effects2 = update(&model, .surfaceBell(paneId: firstTabPaneId))
        try expect(!hasEffect(effects2) {
            if case .sendNotification = $0 { return true }
            return false
        }, "second bell should be throttled (no sendNotification)")
    }

    test("testSurfaceTitleFocusedPane") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let tabId = model.groups[0].tabs[0].id

        let effects = update(&model, .surfaceTitle(paneId: paneId, title: "vim"))
        try expectEqual(model.panes[paneId]?.title, "vim")
        try expectEqual(model.groups[0].tabs[0].title, "vim")
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0, tid == tabId { return true }
            return false
        }, "should reload sidebar row")
        try expect(hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "should set window title")
    }

    test("testSurfaceTitleUnfocusedPane") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        // paneB is focused

        let effects = update(&model, .surfaceTitle(paneId: paneA, title: "htop"))
        try expectEqual(model.panes[paneA]?.title, "htop", "pane title should update")
        try expectEqual(model.groups[0].tabs[0].title, "Terminal", "tab title should not change")
        try expectEqual(effects.count, 1, "only scheduleCheckpoint for unfocused pane title")
        try expect(hasEffect(effects) { if case .scheduleCheckpoint = $0 { return true }; return false })
    }

    test("testSurfacePwdFocusedPane") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let tabId = model.groups[0].tabs[0].id

        let effects = update(&model, .surfaceCwd(paneId: paneId, cwd: "/home/dan/projects"))
        try expectEqual(model.panes[paneId]?.cwd, "/home/dan/projects")
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0, tid == tabId { return true }
            return false
        }, "should reload sidebar row")
        try expect(hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "should set window title")
    }

    test("testSurfacePwdUnfocusedPane") {
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        // paneB is now focused

        let effects = update(&model, .surfaceCwd(paneId: paneA, cwd: "/tmp"))
        try expectEqual(model.panes[paneA]?.cwd, "/tmp", "pane cwd should update")
        try expectEqual(effects.count, 1, "only scheduleCheckpoint for unfocused pane cwd")
        try expect(hasEffect(effects) { if case .scheduleCheckpoint = $0 { return true }; return false })
    }

    test("testSurfaceTitleBackgroundTab") {
        var model = makeModel()
        createTab(&model) // Tab A
        let tabAId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model) // Tab B (now selected)
        try expect(model.selectedTabId != tabAId, "Tab B should be selected")

        let effects = update(&model, .surfaceTitle(paneId: paneA, title: "vim"))
        try expectEqual(model.panes[paneA]?.title, "vim", "pane title should update")
        try expectEqual(model.groups[0].tabs[0].title, "vim", "background tab title should update")
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0, tid == tabAId { return true }
            return false
        }, "should reload sidebar row for background tab")
        try expect(!hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "should NOT set window title for background tab")
    }

    test("testSurfacePwdBackgroundTab") {
        var model = makeModel()
        createTab(&model) // Tab A
        let tabAId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model) // Tab B (now selected)
        try expect(model.selectedTabId != tabAId, "Tab B should be selected")

        let effects = update(&model, .surfaceCwd(paneId: paneA, cwd: "/tmp"))
        try expectEqual(model.panes[paneA]?.cwd, "/tmp", "pane cwd should update")
        try expectEqual(model.groups[0].tabs[0].subtitle, "~" == abbreviateHome("/tmp") ? "~" : "/tmp", "background tab subtitle should update")
        try expect(hasEffect(effects) {
            if case .updateSidebarTabRow(let tid) = $0, tid == tabAId { return true }
            return false
        }, "should reload sidebar row for background tab")
        try expect(!hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "should NOT set window title for background tab")
    }

    test("testDesktopNotificationOnFocusedPaneIsIgnored") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .desktopNotification(paneId: paneId, title: "Build complete", body: "make finished"))
        try expectEqual(model.alerts.count, 0, "should not create alert for focused pane")
        try expectEqual(effects.count, 0, "should produce no effects for focused pane")
    }

    test("testDesktopNotificationOnBackgroundPaneCreatesUnreadAlert") {
        var model = makeModel()
        createTab(&model)
        let firstTabPaneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        let effects = update(&model, .desktopNotification(paneId: firstTabPaneId, title: "Hello", body: "World"))
        try expectEqual(model.alerts.count, 1, "should create alert")
        try expectEqual(model.alerts[0].isUnread, true, "background pane alert should be unread")
        try expect(hasEffect(effects) {
            if case .sendNotification(_, let t, let b) = $0,
               t == "Hello", b == "World" { return true }
            return false
        }, "should send notification with OSC 777 title/body")
        try expect(hasEffect(effects) {
            if case .refreshPaneBorder(let pid) = $0, pid == firstTabPaneId { return true }
            return false
        }, "should refresh pane border for background pane")
        try expect(hasEffect(effects) {
            if case .refreshPaneToolbar(let pid) = $0, pid == firstTabPaneId { return true }
            return false
        }, "should refresh pane toolbar for background notification")
    }

    test("testDesktopNotificationThrottlesIndependentlyFromBell") {
        var model = makeModel()
        createTab(&model)
        let firstTabPaneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        // Fire a bell first
        update(&model, .surfaceBell(paneId: firstTabPaneId))
        try expect(model.lastNotificationTime[firstTabPaneId]?[.bell] != nil, "bell should set lastNotificationTime")

        // Desktop notification should still fire (independent throttle)
        let effects = update(&model, .desktopNotification(paneId: firstTabPaneId, title: "Done", body: "Task finished"))
        try expect(hasEffect(effects) {
            if case .sendNotification(_, let t, _) = $0, t == "Done" { return true }
            return false
        }, "desktop notification should not be throttled by bell")
        try expect(model.lastNotificationTime[firstTabPaneId]?[.desktopNotification] != nil, "should set lastNotificationTime for desktopNotification")

        // Second desktop notification immediately — should be throttled
        let effects2 = update(&model, .desktopNotification(paneId: firstTabPaneId, title: "Done2", body: "Again"))
        try expect(!hasEffect(effects2) {
            if case .sendNotification = $0 { return true }
            return false
        }, "second desktop notification should be throttled")
    }

    // MARK: - Progress

    test("testSurfaceProgressSetStoresState") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .surfaceProgress(paneId: paneId, state: .set(percent: 50)))
        try expectEqual(model.panes[paneId]?.progress, .set(percent: 50))
        try expectEqual(effects.count, 0, "no effects from progress update")
    }

    test("testSurfaceProgressNilClearsState") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .surfaceProgress(paneId: paneId, state: .set(percent: 75)))
        try expectEqual(model.panes[paneId]?.progress, .set(percent: 75))

        update(&model, .surfaceProgress(paneId: paneId, state: nil))
        try expect(model.panes[paneId]?.progress == nil, "progress should be cleared")
    }

    test("testSurfaceProgressUnknownPaneIsNoop") {
        var model = makeModel()
        createTab(&model)
        let unknownPaneId = PaneId()

        let effects = update(&model, .surfaceProgress(paneId: unknownPaneId, state: .set(percent: 50)))
        try expectEqual(effects.count, 0, "no effects for unknown pane")
    }

    test("testProgressStateSurvivesTitleUpdate") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .surfaceProgress(paneId: paneId, state: .indeterminate))
        update(&model, .surfaceTitle(paneId: paneId, title: "vim"))

        try expectEqual(model.panes[paneId]?.progress, .indeterminate, "progress should survive title update")
        try expectEqual(model.panes[paneId]?.title, "vim")
    }

    test("testProgressStateSurvivesCwdUpdate") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .surfaceProgress(paneId: paneId, state: .error(percent: 80)))
        update(&model, .surfaceCwd(paneId: paneId, cwd: "/tmp"))

        try expectEqual(model.panes[paneId]?.progress, .error(percent: 80), "progress should survive cwd update")
        try expectEqual(model.panes[paneId]?.cwd, "/tmp")
    }

    test("testSurfaceClosed") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .surfaceClosed(paneId: paneId))
        try expect(model.panes[paneId] != nil, "pane should still exist (confirmation pending)")
        try expect(hasEffect(effects) {
            if case .showTerminateConfirmation(let count) = $0, count == 1 { return true }
            return false
        }, "should show confirmation when last pane closed via surfaceClosed")
    }
}
