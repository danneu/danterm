// Swift Testing migration of the legacy `tests/UpdateGhosttyTests.swift`
// harness suite. Pins the surface-event Msg paths: surfaceBell + OSC
// desktopNotification routing (focused-pane suppression vs background-pane
// alert + sendNotification, with per-kind throttling), surfaceCreationFailed
// cleanup (single + split tab, terminate vs fallback), surface metadata
// updates (title/cwd/progress) and the reconcile-decision coalescing policy
// against post-reconcile forcing. The few tests already carrying Intent /
// Why / Scenario preambles in the legacy file keep them verbatim; the rest
// get new spec-first preambles.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateGhosttyTests {
    @Test("testBellOnFocusedPaneIsIgnored")
    func testBellOnFocusedPaneIsIgnored() {
        // Intent: a bell from the selected tab's focused pane is ignored while
        //   DanTerm is active.
        // Why it exists: pins the foreground noise-suppression contract after
        //   backgrounded focused panes become notification-worthy.
        // Scenario: the user is looking at the focused pane and it rings; no
        //   alert or macOS notification should be created. Spec-first -- no
        //   incident to cite, and none should be invented.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .surfaceBell(paneId: paneId))
        #expect(model.alerts.count == 0, "no alert for bell on focused pane")
        #expect(commands.count == 0, "no commands for bell on focused pane")
    }

    @Test("testBellOnBackgroundPaneCreatesUnreadAlert")
    func testBellOnBackgroundPaneCreatesUnreadAlert() {
        // Intent: a bell from a background-tab pane creates an unread bell
        //   alert and emits sendNotification.
        // Why it exists: pins the background-bell user-facing path.
        // Scenario: spec-first background bell -- with two tabs and the
        //   first pane in the background, a bell on it creates an alert
        //   and notification.
        var model = makeModel()
        createTab(&model)
        let firstTabPaneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        let commands = update(&model, .surfaceBell(paneId: firstTabPaneId))
        #expect(model.alerts.count == 1, "should create one alert")
        #expect(model.alerts[0].kind == .bell)
        #expect(model.alerts[0].isUnread == true, "alert should be unread")
        #expect(model.alerts[0].paneId == firstTabPaneId)
        #expect(hasEffect(commands) {
            if case .sendNotification = $0 { return true }
            return false
        }, "should emit sendNotification for background bell")
    }

    @Test("testBellOnFocusedPaneWhileInactiveCreatesAlertAndNotification")
    func testBellOnFocusedPaneWhileInactiveCreatesAlertAndNotification() {
        // Intent: a bell from the selected tab's focused pane creates an unread
        //   alert and macOS notification while DanTerm is inactive.
        // Why it exists: a backgrounded app cannot rely on focused-pane
        //   visibility, so the focused pane must follow the unseen-pane path.
        // Scenario: a foreground shell finishes after the user switches to
        //   another app; the notification should still surface and remain
        //   clickable back to the pane. Spec-first -- no incident to cite, and
        //   none should be invented.
        var model = makeModel()
        model.isAppActive = false
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .surfaceBell(paneId: paneId))
        #expect(model.alerts.count == 1, "should create one alert")
        #expect(model.alerts[0].kind == .bell)
        #expect(model.alerts[0].isUnread == true, "alert should be unread")
        #expect(model.alerts[0].paneId == paneId)
        #expect(hasEffect(commands) {
            if case .sendNotification = $0 { return true }
            return false
        }, "should emit sendNotification for inactive focused-pane bell")
    }

    @Test("testSurfaceCreationFailedCleansUp")
    func testSurfaceCreationFailedCleansUp() {
        // Intent: surfaceCreationFailed on the only pane removes the pane +
        //   its tab, emits terminate (no tabs left), and the surface-
        //   existence net tears down the failed pane's surface.
        // Why it exists: pins the bottom-out terminate path.
        // Scenario: spec-first terminate -- last tab's pane fails to be
        //   created; app must terminate.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let liveSurfaceIds = Set(model.allPaneIds)

        let commands = update(&model, .surfaceCreationFailed(paneId: paneId))
        #expect(model.pane(paneId) == nil, "pane should be removed")
        #expect(model.groups[0].tabs.count == 0, "tab should be removed")
        #expect(hasEffect(commands) {
            if case .terminate = $0 { return true }
            return false
        }, "should terminate when no tabs left")
        #expect(surfacesToTearDown(liveSurfaceIds: liveSurfaceIds, model: model) == Set([paneId]),
            "failed pane surface is torn down")
    }

    @Test("surfaceCreationFailed removes split tab siblings")
    func surfaceCreationFailedRemovesSplitTabSiblings() {
        // Intent: a failure on one pane of a split tab removes BOTH panes
        //   (the tab as a whole), selects a fallback tab, and tears down
        //   both pane surfaces.
        // Why it exists: pins the whole-tab teardown branch (not just the
        //   single failed leaf) so a failed launch doesn't strand its
        //   sibling.
        // Scenario: spec-first split-failure.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        createTab(&model)
        let fallbackTabId = model.groups[0].tabs[1].id
        update(&model, .selectTab(id: tabId))
        let liveSurfaceIds = Set(model.allPaneIds)

        let commands = update(&model, .surfaceCreationFailed(paneId: paneA))

        #expect(model.selectedTabId == fallbackTabId, "selection should move to fallback tab")
        #expect(model.pane(paneA) == nil, "failed pane should be removed")
        #expect(model.pane(paneB) == nil, "sibling pane should be removed")
        #expect(!model.groups[0].tabs.contains { $0.id == tabId }, "failed tab should be removed")
        #expect(surfacesToTearDown(liveSurfaceIds: liveSurfaceIds, model: model) == Set([paneA, paneB]),
            "both sibling pane surfaces are torn down")
        #expect(!hasEffect(commands) {
            if case .terminate = $0 { return true }
            return false
        }, "should not terminate when fallback tab remains")
    }

    @Test("testBellThrottling")
    func testBellThrottling() {
        // Intent: the first bell records a lastNotificationTime; a second
        //   bell immediately is throttled (no sendNotification).
        // Why it exists: pins per-pane per-kind throttling so a runaway
        //   shell doesn't spam notifications.
        // Scenario: spec-first throttle.
        var model = makeModel()
        createTab(&model)
        let firstTabPaneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        update(&model, .surfaceBell(paneId: firstTabPaneId))
        #expect(model.lastNotificationTime[firstTabPaneId]?[.bell] != nil, "should set lastNotificationTime for bell")

        let effects2 = update(&model, .surfaceBell(paneId: firstTabPaneId))
        #expect(!hasEffect(effects2) {
            if case .sendNotification = $0 { return true }
            return false
        }, "second bell should be throttled (no sendNotification)")
    }

    @Test("reconcileDecision coalesces only eligible high-frequency messages")
    func reconcileDecisionCoalescesOnlyEligibleMessages() {
        // Intent: high-frequency split-ratio and search-count messages classify
        //   as coalesce-eligible while post-reconcile commands still force inline.
        // Why it exists: pins reconcile coalescing policy against regressions in
        //   message classification, pending-state handling, and post-reconcile
        //   command forcing.
        // Scenario: divider drags and streaming search scans emit bursts whose
        //   empty or cosmetic sweeps defer into the 75 ms timer. Spec-first -- no
        //   incident to cite, and none should be invented.
        let paneId = PaneId()
        let coalescedMessages: [Msg] = [
            .surfaceTitle(paneId: paneId, title: "vim"),
            .surfaceCwd(paneId: paneId, cwd: "/tmp"),
            .surfaceProgress(paneId: paneId, state: .set(percent: 50)),
            .splitRatioChanged(splitId: SplitId(), ratio: 0.3),
            .ghosttySearchTotal(paneId: paneId, total: 42),
            .ghosttySearchSelected(paneId: paneId, selected: 3)
        ]

        for msg in coalescedMessages {
            #expect(
                reconcileDecision(for: msg, coalescedSweepPending: false, emitsPostReconcile: false) ==
                .scheduleCoalesced
            )
            #expect(
                reconcileDecision(for: msg, coalescedSweepPending: true, emitsPostReconcile: false) ==
                .coalesceIntoPending
            )
            #expect(
                reconcileDecision(for: msg, coalescedSweepPending: false, emitsPostReconcile: true) ==
                .reconcileNow
            )
            #expect(
                reconcileDecision(for: msg, coalescedSweepPending: true, emitsPostReconcile: true) ==
                .reconcileNow
            )
        }

        let inlineMessages: [Msg] = [
            .surfaceBell(paneId: paneId),
            .commandStarted(paneId: paneId, command: "make test"),
            .preferencesOpened(ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14")),
            .preferencesClosed
        ]
        for msg in inlineMessages {
            #expect(
                reconcileDecision(for: msg, coalescedSweepPending: false, emitsPostReconcile: false) ==
                .reconcileNow
            )
            #expect(
                reconcileDecision(for: msg, coalescedSweepPending: true, emitsPostReconcile: false) ==
                .reconcileNow
            )
        }
    }

    @Test("surface metadata updates stay coalesce eligible")
    func surfaceMetadataUpdatesStayCoalesceEligible() {
        // Intent: surface metadata updates (title / cwd / progress) emit no
        //   post-reconcile commands so they can ride the coalesced sweep.
        // Why it exists: pins the "no post-reconcile in metadata" rule the
        //   coalescer relies on.
        // Scenario: spec-first metadata coalesce -- iterate focused and
        //   unfocused-pane metadata Msgs; none emit post-reconcile commands.
        var focusedModel = makeModel()
        createTab(&focusedModel)
        let focusedPane = focusedModel.groups[0].tabs[0].focusedPaneId

        var unfocusedModel = makeModel()
        createTab(&unfocusedModel)
        let unfocusedPane = unfocusedModel.groups[0].tabs[0].focusedPaneId
        update(&unfocusedModel, .splitPane(direction: .horizontal))

        let scenarios: [(Msg, AppModel)] = [
            (.surfaceTitle(paneId: focusedPane, title: "vim"), focusedModel),
            (.surfaceCwd(paneId: focusedPane, cwd: "/tmp"), focusedModel),
            (.surfaceProgress(paneId: focusedPane, state: .set(percent: 50)), focusedModel),
            (.surfaceTitle(paneId: unfocusedPane, title: "htop"), unfocusedModel),
            (.surfaceCwd(paneId: unfocusedPane, cwd: "/var/tmp"), unfocusedModel),
            (.surfaceProgress(paneId: unfocusedPane, state: .indeterminate), unfocusedModel)
        ]

        for (msg, seedModel) in scenarios {
            var model = seedModel
            let commands = update(&model, msg)
            #expect(commands.allSatisfy { !$0.isPostReconcile },
                "coalesced surface metadata update should not emit post-reconcile commands")
        }
    }

    @Test("testSurfaceTitleFocusedPane")
    func testSurfaceTitleFocusedPane() {
        // Intent: surfaceTitle on the focused pane updates both the pane's
        //   title and the tab's title (chrome sync).
        // Why it exists: pins the focused-pane chrome sync.
        // Scenario: spec-first focused title.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .surfaceTitle(paneId: paneId, title: "vim"))
        #expect(model.pane(paneId)?.title == "vim")
        #expect(model.groups[0].tabs[0].title == "vim")
    }

    @Test("testSurfaceTitleUnfocusedPane")
    func testSurfaceTitleUnfocusedPane() {
        // Intent: surfaceTitle on an unfocused pane updates the pane's
        //   title only (no tab chrome change); emits exactly one
        //   scheduleCheckpoint.
        // Why it exists: pins the per-pane scope of the title update.
        // Scenario: spec-first unfocused title.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))

        let commands = update(&model, .surfaceTitle(paneId: paneA, title: "htop"))
        #expect(model.pane(paneA)?.title == "htop", "pane title should update")
        #expect(model.groups[0].tabs[0].title == "Terminal", "tab title should not change")
        #expect(commands.count == 1, "only scheduleCheckpoint for unfocused pane title")
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false })
    }

    @Test("testSurfacePwdFocusedPane")
    func testSurfacePwdFocusedPane() {
        // Intent: surfaceCwd on the focused pane updates the pane's cwd
        //   and the tab's subtitle (abbreviated from $HOME).
        // Why it exists: pins the chrome-sync for cwd on the selected
        //   tab.
        // Scenario: spec-first focused cwd.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .surfaceCwd(paneId: paneId, cwd: "/home/dan/projects"))
        #expect(model.pane(paneId)?.cwd == "/home/dan/projects")
        #expect(model.groups[0].tabs[0].subtitle == abbreviateHome("/home/dan/projects"),
            "focused-pane cwd syncs the selected tab's subtitle (the window-chrome input)")
    }

    @Test("testSurfacePwdUnfocusedPane")
    func testSurfacePwdUnfocusedPane() {
        // Intent: surfaceCwd on an unfocused pane only updates the pane's
        //   cwd; emits exactly one scheduleCheckpoint.
        // Why it exists: pins the per-pane scope for cwd updates.
        // Scenario: spec-first unfocused cwd.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))

        let commands = update(&model, .surfaceCwd(paneId: paneA, cwd: "/tmp"))
        #expect(model.pane(paneA)?.cwd == "/tmp", "pane cwd should update")
        #expect(commands.count == 1, "only scheduleCheckpoint for unfocused pane cwd")
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false })
    }

    @Test("testSurfaceTitleBackgroundTab")
    func testSurfaceTitleBackgroundTab() {
        // Intent: a background tab's pane title still updates that tab's
        //   title; the selected tab is unaffected.
        // Why it exists: pins the "every tab tracks its pane chrome" rule
        //   independent of selection.
        // Scenario: spec-first background title.
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        #expect(model.selectedTabId != tabAId, "Tab B should be selected")

        update(&model, .surfaceTitle(paneId: paneA, title: "vim"))
        #expect(model.pane(paneA)?.title == "vim", "pane title should update")
        #expect(model.groups[0].tabs[0].title == "vim", "background tab title should update")
    }

    @Test("testSurfacePwdBackgroundTab")
    func testSurfacePwdBackgroundTab() {
        // Intent: a background tab's pane cwd still updates that tab's
        //   subtitle.
        // Why it exists: pins the same per-tab rule for cwd.
        // Scenario: spec-first background cwd.
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        #expect(model.selectedTabId != tabAId, "Tab B should be selected")

        update(&model, .surfaceCwd(paneId: paneA, cwd: "/tmp"))
        #expect(model.pane(paneA)?.cwd == "/tmp", "pane cwd should update")
        #expect(model.groups[0].tabs[0].subtitle == ("~" == abbreviateHome("/tmp") ? "~" : "/tmp"), "background tab subtitle should update")
    }

    @Test("testDesktopNotificationOnFocusedPaneIsIgnored")
    func testDesktopNotificationOnFocusedPaneIsIgnored() {
        // Intent: an OSC desktop notification from the selected tab's focused
        //   pane is ignored while DanTerm is active.
        // Why it exists: pins the foreground noise-suppression contract after
        //   backgrounded focused panes become notification-worthy.
        // Scenario: the user is looking at the focused pane when it emits OSC-9;
        //   no alert or macOS notification should be created. Spec-first -- no
        //   incident to cite, and none should be invented.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .desktopNotification(paneId: paneId, title: "Build complete", body: "make finished"))
        #expect(model.alerts.count == 0, "should not create alert for focused pane")
        #expect(commands.count == 0, "should produce no commands for focused pane")
    }

    @Test("testDesktopNotificationOnFocusedPaneWhileInactiveCreatesAlertAndNotification")
    func testDesktopNotificationOnFocusedPaneWhileInactiveCreatesAlertAndNotification() {
        // Intent: an OSC desktop notification from the selected tab's focused
        //   pane creates an unread alert and macOS notification while DanTerm is
        //   inactive.
        // Why it exists: a backgrounded app cannot rely on focused-pane
        //   visibility, so OSC notifications must keep their backing alert for
        //   notification-click navigation.
        // Scenario: a foreground task emits OSC-9 after the user switches to
        //   another app; the notification should carry the OSC title/body and
        //   navigate back to the pane. Spec-first -- no incident to cite, and
        //   none should be invented.
        var model = makeModel()
        model.isAppActive = false
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .desktopNotification(paneId: paneId, title: "Hello", body: "World"))
        #expect(model.alerts.count == 1, "should create one alert")
        #expect(model.alerts[0].kind == .desktopNotification)
        #expect(model.alerts[0].isUnread == true, "alert should be unread")
        #expect(model.alerts[0].paneId == paneId)
        #expect(hasEffect(commands) {
            if case .sendNotification(_, let title, let body) = $0,
               title == "Hello", body == "World" { return true }
            return false
        }, "should send notification with OSC title/body")
    }

    @Test("testDesktopNotificationOnBackgroundPaneCreatesUnreadAlert")
    func testDesktopNotificationOnBackgroundPaneCreatesUnreadAlert() {
        // Intent: a desktop notification on a background pane creates an
        //   unread alert and emits sendNotification with OSC title/body.
        // Why it exists: pins the background-pane OSC path.
        // Scenario: spec-first background OSC notification.
        var model = makeModel()
        createTab(&model)
        let firstTabPaneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        let commands = update(&model, .desktopNotification(paneId: firstTabPaneId, title: "Hello", body: "World"))
        #expect(model.alerts.count == 1, "should create alert")
        #expect(model.alerts[0].isUnread == true, "background pane alert should be unread")
        #expect(hasEffect(commands) {
            if case .sendNotification(_, let t, let b) = $0,
               t == "Hello", b == "World" { return true }
            return false
        }, "should send notification with OSC 777 title/body")
    }

    @Test("testDesktopNotificationThrottlesIndependentlyFromBell")
    func testDesktopNotificationThrottlesIndependentlyFromBell() {
        // Intent: bell and desktop-notification throttles are independent
        //   per kind; back-to-back desktop notifications still throttle on
        //   their own kind.
        // Why it exists: pins the per-kind throttle structure.
        // Scenario: spec-first independent throttle.
        var model = makeModel()
        createTab(&model)
        let firstTabPaneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        update(&model, .surfaceBell(paneId: firstTabPaneId))
        #expect(model.lastNotificationTime[firstTabPaneId]?[.bell] != nil, "bell should set lastNotificationTime")

        let commands = update(&model, .desktopNotification(paneId: firstTabPaneId, title: "Done", body: "Task finished"))
        #expect(hasEffect(commands) {
            if case .sendNotification(_, let t, _) = $0, t == "Done" { return true }
            return false
        }, "desktop notification should not be throttled by bell")
        #expect(model.lastNotificationTime[firstTabPaneId]?[.desktopNotification] != nil, "should set lastNotificationTime for desktopNotification")

        let effects2 = update(&model, .desktopNotification(paneId: firstTabPaneId, title: "Done2", body: "Again"))
        #expect(!hasEffect(effects2) {
            if case .sendNotification = $0 { return true }
            return false
        }, "second desktop notification should be throttled")
    }

    // MARK: - Progress

    @Test("testSurfaceProgressSetStoresState")
    func testSurfaceProgressSetStoresState() {
        // Intent: surfaceProgress(.set) stores the percent on the pane;
        //   emits no commands.
        // Why it exists: pins the no-side-effect progress write.
        // Scenario: spec-first progress set.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .surfaceProgress(paneId: paneId, state: .set(percent: 50)))
        #expect(model.pane(paneId)?.progress == .set(percent: 50))
        #expect(commands.count == 0, "no commands from progress update")
    }

    @Test("testSurfaceProgressNilClearsState")
    func testSurfaceProgressNilClearsState() {
        // Intent: surfaceProgress(.nil) clears the pane's progress.
        // Why it exists: pins the explicit-clear branch.
        // Scenario: spec-first progress clear.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .surfaceProgress(paneId: paneId, state: .set(percent: 75)))
        #expect(model.pane(paneId)?.progress == .set(percent: 75))

        update(&model, .surfaceProgress(paneId: paneId, state: nil))
        #expect(model.pane(paneId)?.progress == nil, "progress should be cleared")
    }

    @Test("testSurfaceProgressUnknownPaneIsNoop")
    func testSurfaceProgressUnknownPaneIsNoop() {
        // Intent: progress for an unknown pane id emits no commands.
        // Why it exists: pins fail-closed on stale pane ids.
        // Scenario: spec-first stale-pane progress.
        var model = makeModel()
        createTab(&model)
        let unknownPaneId = PaneId()

        let commands = update(&model, .surfaceProgress(paneId: unknownPaneId, state: .set(percent: 50)))
        #expect(commands.count == 0, "no commands for unknown pane")
    }

    @Test("testProgressStateSurvivesTitleUpdate")
    func testProgressStateSurvivesTitleUpdate() {
        // Intent: a title update does not clear progress.
        // Why it exists: pins independence of pane-state fields.
        // Scenario: spec-first progress + title.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .surfaceProgress(paneId: paneId, state: .indeterminate))
        update(&model, .surfaceTitle(paneId: paneId, title: "vim"))

        #expect(model.pane(paneId)?.progress == .indeterminate, "progress should survive title update")
        #expect(model.pane(paneId)?.title == "vim")
    }

    @Test("testProgressStateSurvivesCwdUpdate")
    func testProgressStateSurvivesCwdUpdate() {
        // Intent: a cwd update does not clear progress.
        // Why it exists: pins independence between progress and cwd fields.
        // Scenario: spec-first progress + cwd.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .surfaceProgress(paneId: paneId, state: .error(percent: 80)))
        update(&model, .surfaceCwd(paneId: paneId, cwd: "/tmp"))

        #expect(model.pane(paneId)?.progress == .error(percent: 80), "progress should survive cwd update")
        #expect(model.pane(paneId)?.cwd == "/tmp")
    }

    @Test("testSurfaceClosed")
    func testSurfaceClosed() {
        // Intent: surfaceClosed on the last pane flips pendingConfirmation
        //   to .terminate and leaves the model intact.
        // Why it exists: pins the surface-closed -> quit-confirm path.
        // Scenario: spec-first surface-closed terminate.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .surfaceClosed(paneId: paneId))
        #expect(model.pane(paneId) != nil, "pane should still exist (confirmation pending)")
        #expect(commands.isEmpty, "no command; reconcileQuitConfirmation drives the panel")
        #expect(model.pendingConfirmation == .terminate, "quit confirmation should be pending")
    }
}
