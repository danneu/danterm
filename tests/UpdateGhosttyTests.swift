import Foundation

func ghosttyTests() {
    print("Ghostty Tests...")

    test("testBellOnFocusedPaneIsIgnored") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .surfaceBell(paneId: paneId))
        try expectEqual(model.panes[paneId]?.hasBell, false, "bell should be cleared on focused pane")
        try expectEqual(effects.count, 0, "no effects for bell on focused pane")
    }

    test("testBellOnBackgroundPaneEmitsNotification") {
        var model = makeModel()
        createTab(&model)
        let firstTabPaneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        let effects = update(&model, .surfaceBell(paneId: firstTabPaneId))
        try expectEqual(model.panes[firstTabPaneId]?.hasBell, true, "bell should be set on background pane")
        try expect(hasEffect(effects) {
            if case .sendNotification = $0 { return true }
            return false
        }, "should emit sendNotification for background bell")
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
    }

    test("testBellThrottling") {
        var model = makeModel()
        createTab(&model)
        let firstTabPaneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        // First bell
        update(&model, .surfaceBell(paneId: firstTabPaneId))
        try expect(model.panes[firstTabPaneId]?.lastBellNotification != nil, "should set lastBellNotification")

        // Second bell immediately — should be throttled
        let effects2 = update(&model, .surfaceBell(paneId: firstTabPaneId))
        try expect(!hasEffect(effects2) {
            if case .sendNotification = $0 { return true }
            return false
        }, "second bell should be throttled (no sendNotification)")
    }

    test("testBellRequestsPermissionOnce") {
        var model = makeModel()
        createTab(&model)
        let firstTabPaneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        try expectEqual(model.notificationPermissionRequested, false)

        let effects1 = update(&model, .surfaceBell(paneId: firstTabPaneId))
        try expect(hasEffect(effects1) {
            if case .requestNotificationPermission = $0 { return true }
            return false
        }, "first bell should request permission")
        try expectEqual(model.notificationPermissionRequested, true)

        // Reset throttle so second bell sends notification
        model.panes[firstTabPaneId]?.lastBellNotification = Date.distantPast

        let effects2 = update(&model, .surfaceBell(paneId: firstTabPaneId))
        try expect(!hasEffect(effects2) {
            if case .requestNotificationPermission = $0 { return true }
            return false
        }, "second bell should not request permission again")
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
            if case .reloadSidebarRow(let tid) = $0, tid == tabId { return true }
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
        try expectEqual(effects.count, 0, "no effects for unfocused pane title")
    }

    test("testSurfacePwdFocusedPane") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let tabId = model.groups[0].tabs[0].id

        let effects = update(&model, .surfaceCwd(paneId: paneId, cwd: "/home/dan/projects"))
        try expectEqual(model.panes[paneId]?.cwd, "/home/dan/projects")
        try expect(hasEffect(effects) {
            if case .reloadSidebarRow(let tid) = $0, tid == tabId { return true }
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
        try expectEqual(effects.count, 0, "no effects for unfocused pane cwd")
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
            if case .reloadSidebarRow(let tid) = $0, tid == tabAId { return true }
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
            if case .reloadSidebarRow(let tid) = $0, tid == tabAId { return true }
            return false
        }, "should reload sidebar row for background tab")
        try expect(!hasEffect(effects) {
            if case .setWindowTitle = $0 { return true }
            return false
        }, "should NOT set window title for background tab")
    }

    test("testSurfaceClosed") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .surfaceClosed(paneId: paneId))
        try expect(model.panes[paneId] == nil, "pane should be removed")
        try expect(hasEffect(effects) {
            if case .terminate = $0 { return true }
            return false
        }, "should terminate when last pane closed via surfaceClosed")
    }
}
