// Swift Testing migration of the legacy `tests/UpdateAlertTests.swift`
// harness suite. Pins the alert-domain Msg paths: markAlertRead /
// markAllAlertsRead, activateAlert (selection + focus + popover dismiss,
// stale-pane fail-closed, zoom clear), the alert-history cap, focus-mode
// auto-clear vs manual mode, throttle isolation per pane per kind, alert +
// throttle cleanup on closePane / closeTab / surfaceCreationFailed,
// goToMostRecentAlertPane (cross-tab/intra-tab navigation, repeated-press
// walks, current-tab ack, stale skip, zoom clear), filteredAlerts /
// alertsEmptyText helpers, setShowAllAlerts, and the manual-mode preservation
// rules on selectTab / paneBecameFirstResponder / closeZoomedPane /
// movePaneToTab / movePaneToNewTab, plus the explicit clearAlertsForPane /
// ackTabAlerts / clearAlertsForTab / clearAlertsForTabs paths.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateAlertTests {
    @Test("testMarkAlertRead")
    func testMarkAlertRead() {
        // Intent: markAlertRead flips isUnread on the targeted alert.
        // Why it exists: pins the bare mark-read mutation.
        // Scenario: spec-first mark read.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .markAlertRead(alertId: alertId))
        #expect(model.alerts[0].isUnread == false)
    }

    @Test("testMarkAlertReadForStalePaneSkipsSidebarUpdate")
    func testMarkAlertReadForStalePaneSkipsSidebarUpdate() {
        // Intent: marking a stale-pane alert read still works but emits
        //   no commands (badges reconcile from the model).
        // Why it exists: pins the no-side-effect path for stale pane ids.
        // Scenario: spec-first stale-pane mark.
        var model = makeModel()
        createTab(&model)
        let stalePaneId = PaneId()

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: stalePaneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .markAlertRead(alertId: alertId))
        #expect(model.alerts[0].isUnread == false)
        #expect(commands.isEmpty, "stale alert marks read but emits no commands (badges reconcile)")
    }

    @Test("testMarkAllAlertsRead")
    func testMarkAllAlertsRead() {
        // Intent: markAllAlertsRead clears every alert's isUnread flag
        //   and emits no commands.
        // Why it exists: pins the bulk-mark path.
        // Scenario: spec-first mark all.
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

        let commands = update(&model, .markAllAlertsRead)
        #expect(model.alerts.allSatisfy { !$0.isUnread }, "all alerts should be read")
        #expect(commands.isEmpty, "marking all read emits no commands (badges reconcile)")
    }

    @Test("testActivateAlertNavigatesAndMarksRead")
    func testActivateAlertNavigatesAndMarksRead() {
        // Intent: activateAlert navigates to the alert's tab, marks the
        //   alert read, focuses the pane, activates the app, and dismisses
        //   the popover.
        // Why it exists: pins the full popover-row-click navigation path.
        // Scenario: spec-first popover activate.
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

        let commands = update(&model, .activateAlert(alertId: alertId))
        #expect(model.selectedTabId == tabId, "should navigate to alert's tab")
        #expect(model.alerts[0].isUnread == false, "alert should be marked read")
        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == paneId { return true }
            return false
        }, "should focus alert's pane")
        #expect(hasEffect(commands) {
            if case .activateApp = $0 { return true }
            return false
        }, "should activate app")
        #expect(hasEffect(commands) {
            if case .dismissAlertsPopover = $0 { return true }
            return false
        }, "should dismiss popover")
    }

    @Test("testActivateAlertSameTabShowsSelectedTab")
    func testActivateAlertSameTabShowsSelectedTab() {
        // Intent: activateAlert that targets a non-zoom same-tab pane
        //   leaves selection on the tab and focuses the targeted pane.
        // Why it exists: pins the in-tab activate path (no container
        //   rebuild needed).
        // Scenario: spec-first same-tab activate.
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

        update(&model, .activateAlert(alertId: alertId))

        #expect(model.selectedTabId == tabId, "should stay on current tab")
        #expect(model.groups[0].tabs[0].focusedPaneId == paneA, "should focus alert pane")
        #expect(model.groups[0].tabs[0].isZoomed == false, "non-zoom navigation leaves zoom off")
    }

    @Test("testActivateAlertSameTabZoomClearRebuildsContainer")
    func testActivateAlertSameTabZoomClearRebuildsContainer() {
        // Intent: activateAlert that targets a different pane while
        //   zoomed clears the zoom.
        // Why it exists: pins the zoom-clear rule for cross-pane activate.
        // Scenario: spec-first zoom clear on activate.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId
        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        update(&model, .toggleZoomPane)
        #expect(model.groups[0].tabs[0].focusedPaneId == paneB, "paneB should be focused before navigation")
        #expect(model.groups[0].tabs[0].isZoomed == true, "tab should be zoomed before navigation")

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .activateAlert(alertId: alertId))

        let tab = model.groups[0].tabs[0]
        #expect(tab.focusedPaneId == paneA, "should focus alert pane")
        #expect(tab.isZoomed == false, "zoom should clear when navigating to hidden pane")
    }

    @Test("testActivateAlertDoesNotMarkReadInManualMode")
    func testActivateAlertDoesNotMarkReadInManualMode() {
        // Intent: in manual mode, activateAlert navigates but does NOT
        //   mark the alert read.
        // Why it exists: pins the manual-mode preservation rule for
        //   navigation paths.
        // Scenario: spec-first manual activate.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .activateAlert(alertId: alertId))
        #expect(model.selectedTabId == tabId, "should still navigate to alert's tab")
        #expect(model.alerts[0].isUnread == true, "manual mode: activateAlert should NOT mark alert read")
        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == paneId { return true }
            return false
        }, "should still focus alert's pane")
    }

    @Test("testActivateStaleAlertMarksReadButNoNavigation")
    func testActivateStaleAlertMarksReadButNoNavigation() {
        // Intent: activating a stale-pane alert marks it read, dismisses
        //   the popover, but does NOT emit a first-responder request.
        // Why it exists: pins fail-closed for stale alert paneIds.
        // Scenario: spec-first stale activate.
        var model = makeModel()
        createTab(&model)

        let stalePaneId = PaneId()
        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: stalePaneId,
            title: "DanTerm", body: "stale", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .activateAlert(alertId: alertId))
        #expect(model.alerts[0].isUnread == false, "should mark read")
        #expect(!hasEffect(commands) {
            if case .makeFirstResponder = $0 { return true }
            return false
        }, "should not navigate")
        #expect(hasEffect(commands) {
            if case .dismissAlertsPopover = $0 { return true }
            return false
        }, "should dismiss popover")
    }

    @Test("testAlertHistoryCappedAt100")
    func testAlertHistoryCappedAt100() {
        // Intent: model.alerts is capped at 100 items; the oldest gets
        //   dropped when a new alert is inserted.
        // Why it exists: pins the bounded history.
        // Scenario: spec-first cap -- insert 100, then surfaceBell adds
        //   one more; total stays at 100 with the new alert at the front.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        for i in 0..<100 {
            model.alerts.append(AlertModel(
                id: AlertId(), kind: .bell, paneId: paneId,
                title: "DanTerm", body: "alert \(i)", createdAt: Date(), isUnread: false
            ))
        }
        #expect(model.alerts.count == 100)

        model.lastNotificationTime[paneId] = [.bell: Date.distantPast]

        update(&model, .surfaceBell(paneId: paneId))
        #expect(model.alerts.count == 100, "alerts should be capped at 100")
        #expect(model.alerts[0].body == (model.pane(paneId)?.title ?? ""), "newest alert should be first")
    }

    @Test("testSelectTabMarksAlertsReadForFocusedPane")
    func testSelectTabMarksAlertsReadForFocusedPane() {
        // Intent: selectTab in default focus mode marks the focused
        //   pane's alerts read.
        // Why it exists: pins the focus-mode default behavior on tab
        //   switches.
        // Scenario: spec-first selectTab clear.
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .selectTab(id: tabAId))
        #expect(model.alerts[0].isUnread == false, "selecting tab should mark focused pane's alerts read")
    }

    @Test("testPaneBecameFirstResponderMarksAlertsRead")
    func testPaneBecameFirstResponderMarksAlertsRead() {
        // Intent: paneBecameFirstResponder marks the new pane's alerts
        //   read (default focus mode).
        // Why it exists: pins the focus-mode default behavior on pane
        //   focus changes.
        // Scenario: spec-first focus clear.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .paneBecameFirstResponder(paneId: paneA))
        #expect(model.alerts[0].isUnread == false, "focusing pane should mark its alerts read")
        _ = paneB
    }

    @Test("testCloseZoomedPaneClearsAlertOnNewlyFocusedPane")
    func testCloseZoomedPaneClearsAlertOnNewlyFocusedPane() {
        // Intent: closing the zoomed pane refocuses the sibling and
        //   clears its alerts (default focus mode).
        // Why it exists: pins the focus-mode auto-clear during a
        //   zoom-close transition.
        // Scenario: spec-first zoom-close clear.
        var model = makeModel()
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
        #expect(model.groups[0].tabs[0].focusedPaneId == paneB, "paneB should be focused after closing paneA")
        #expect(!model.alerts[0].isUnread, "alert on newly focused pane should be marked read")
    }

    @Test("testClosePaneRemovesAlertsAndCleansUpThrottle")
    func testClosePaneRemovesAlertsAndCleansUpThrottle() {
        // Intent: closePane removes the pane's alerts and throttle
        //   bookkeeping.
        // Why it exists: pins the per-pane teardown of alert + throttle
        //   state.
        // Scenario: spec-first closePane cleanup.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        model.lastNotificationTime[paneA] = [.bell: Date()]

        update(&model, .closePane(paneId: paneA))
        #expect(model.alerts.isEmpty, "closing pane should remove its alerts")
        #expect(model.lastNotificationTime[paneA] == nil, "closing pane should clean up throttle data")
    }

    @Test("testCloseTabRemovesAlertsForAllPanes")
    func testCloseTabRemovesAlertsForAllPanes() {
        // Intent: closeTab removes alerts for every pane in the tab.
        // Why it exists: pins the per-tab cleanup.
        // Scenario: spec-first closeTab cleanup.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "a", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "b", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .closeTab(id: tabId))
        #expect(model.alerts.isEmpty, "closing tab should remove alerts for all its panes")
    }

    @Test("testSurfaceCreationFailedRemovesAlerts")
    func testSurfaceCreationFailedRemovesAlerts() {
        // Intent: surfaceCreationFailed removes the failed pane's alerts
        //   and throttle bookkeeping.
        // Why it exists: pins the failure-path cleanup symmetry.
        // Scenario: spec-first failure cleanup.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        model.lastNotificationTime[paneA] = [.bell: Date()]

        update(&model, .surfaceCreationFailed(paneId: paneA))
        #expect(model.alerts.isEmpty, "surfaceCreationFailed should remove pane's alerts")
        #expect(model.lastNotificationTime[paneA] == nil, "surfaceCreationFailed should clean up throttle data")
    }

    @Test("testThrottleIsPerPanePerKind")
    func testThrottleIsPerPanePerKind() {
        // Intent: bell and desktop notifications throttle independently
        //   per kind.
        // Why it exists: pins per-kind throttle isolation.
        // Scenario: spec-first per-kind throttle.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        let effects1 = update(&model, .surfaceBell(paneId: paneId))
        #expect(hasEffect(effects1) {
            if case .sendNotification = $0 { return true }
            return false
        }, "first bell should send notification")

        let effects2 = update(&model, .desktopNotification(paneId: paneId, title: "Done", body: "ok"))
        #expect(hasEffect(effects2) {
            if case .sendNotification = $0 { return true }
            return false
        }, "desktop notification should not be throttled by bell")

        let effects3 = update(&model, .surfaceBell(paneId: paneId))
        #expect(!hasEffect(effects3) {
            if case .sendNotification = $0 { return true }
            return false
        }, "second bell should be throttled")
    }

    @Test("testActivateAlertFromMacOSNotification")
    func testActivateAlertFromMacOSNotification() {
        // Intent: activateAlert hit from a notification follows the same
        //   path as a popover row click.
        // Why it exists: pins the single-entry-point invariant.
        // Scenario: spec-first activate-from-notification.
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

        let commands = update(&model, .activateAlert(alertId: alertId))
        #expect(model.selectedTabId == tabId)
        #expect(model.alerts[0].isUnread == false)
        #expect(hasEffect(commands) {
            if case .activateApp = $0 { return true }
            return false
        }, "should activate app")
    }

    // MARK: - goToMostRecentAlertPane Tests

    @Test("testGoToMostRecentAlertPaneNavigatesToPaneAndTab")
    func testGoToMostRecentAlertPaneNavigatesToPaneAndTab() {
        // Intent: goToMostRecentAlertPane switches to the alert pane's
        //   tab and focuses the pane.
        // Why it exists: pins the keyboard "go-to-most-recent" path.
        // Scenario: spec-first go-to navigation.
        var model = makeModel()
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        #expect(model.selectedTabId != tab1Id, "tab2 should be selected")

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .goToMostRecentAlertPane)
        #expect(model.selectedTabId == tab1Id, "should switch to tab containing alert pane")
        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should focus the alert's pane")
    }

    @Test("testGoToMostRecentAlertPaneSkipsStaleAlert")
    func testGoToMostRecentAlertPaneSkipsStaleAlert() {
        // Intent: the helper skips alerts whose pane is gone and
        //   navigates to the first valid alert.
        // Why it exists: pins fail-open for stale newest alerts.
        // Scenario: spec-first stale skip.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let paneB = model.groups[0].tabs[0].focusedPaneId

        let stalePaneId = PaneId()
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: stalePaneId,
            title: "DanTerm", body: "stale", createdAt: Date(), isUnread: true
        ), at: 0)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "valid", createdAt: Date(), isUnread: true
        ), at: 1)

        let commands = update(&model, .goToMostRecentAlertPane)
        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should navigate to the first valid alert's pane")
        _ = paneB
    }

    @Test("testGoToMostRecentAlertPaneNoAlerts")
    func testGoToMostRecentAlertPaneNoAlerts() {
        // Intent: with no alerts, the helper emits no commands.
        // Why it exists: pins the empty-state guard.
        // Scenario: spec-first no-alerts.
        var model = makeModel()
        createTab(&model)

        let commands = update(&model, .goToMostRecentAlertPane)
        #expect(commands.count == 0, "no alerts should produce no commands")
    }

    @Test("testGoToMostRecentAlertPaneIntraTabNavigatesToAlertPane")
    func testGoToMostRecentAlertPaneIntraTabNavigatesToAlertPane() {
        // Intent: with no other alert-bearing tabs, an intra-tab alert
        //   falls back to the sibling pane and clears current-tab alerts.
        // Why it exists: pins same-tab navigation as the fallback, not
        //   the primary shortcut loop.
        // Scenario: spec-first intra-tab fallback.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId

        update(&model, .paneBecameFirstResponder(paneId: paneA))
        #expect(model.groups[0].tabs[0].focusedPaneId == paneA)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "intra-tab", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .goToMostRecentAlertPane)

        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == paneB { return true }
            return false
        }, "should focus paneB")

        #expect(model.groups[0].tabs[0].focusedPaneId == paneB,
            "tab's focusedPaneId should be paneB after navigation")
        #expect(model.alerts[0].isUnread == false,
            "paneB's alert should be marked read by the current-tab clear")
    }

    @Test("testGoToMostRecentAlertPaneIntraTabClearsCurrentTabInManualMode")
    func testGoToMostRecentAlertPaneIntraTabClearsCurrentTabInManualMode() {
        // Intent: in manual mode, same-tab fallback focuses the latest
        //   unread sibling and then clears every current-tab alert.
        // Why it exists: pins the shortcut's explicit current-tab clear,
        //   which ignores alertClearMode for the tab being finished.
        // Scenario: spec-first manual same-tab fallback.
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
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "focused", createdAt: Date(), isUnread: true
        ), at: 1)

        let commands = update(&model, .goToMostRecentAlertPane)

        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == paneB { return true }
            return false
        }, "should focus paneB")

        #expect(model.alerts.first(where: { $0.paneId == paneA })?.isUnread == false,
            "focused pane alert should be cleared")
        #expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == false,
            "sibling pane alert should be cleared")
    }

    @Test("testGoToMostRecentAlertPanePrefersOtherTabOverCurrentSibling")
    func testGoToMostRecentAlertPanePrefersOtherTabOverCurrentSibling() {
        // Intent: an unread sibling in the current tab does not beat an
        //   unread alert in another tab, even when the sibling is newer.
        // Why it exists: pins tab-first triage: finish the current tab,
        //   then move to another tab that needs attention.
        // Scenario: spec-first cross-tab priority over same-tab fallback.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId
        let tab1Id = model.groups[0].tabs[0].id

        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let paneC = model.groups[0].tabs[1].focusedPaneId
        let tab2PaneIds = allPaneIds(model.groups[0].tabs[1].rootNode)
        let paneB = tab2PaneIds.first(where: { $0 != paneC })!

        update(&model, .paneBecameFirstResponder(paneId: paneB))
        #expect(model.groups[0].tabs[1].focusedPaneId == paneB)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "other tab", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "focused current", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneC,
            title: "DanTerm", body: "newer current sibling", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .goToMostRecentAlertPane)
        #expect(model.selectedTabId == tab1Id, "should jump to the other tab")
        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should focus paneA, not the newer current-tab sibling")
        #expect(model.alerts.first(where: { $0.paneId == paneA })?.isUnread == true,
            "destination alert should remain unread in manual mode")
        #expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == false,
            "focused current-tab alert should be cleared")
        #expect(model.alerts.first(where: { $0.paneId == paneC })?.isUnread == false,
            "newer current-tab sibling alert should be cleared")
    }

    @Test("testGoToMostRecentAlertPaneUsesCurrentTabAfterMove")
    func testGoToMostRecentAlertPaneUsesCurrentTabAfterMove() {
        // Intent: the helper uses the pane's CURRENT tab id, not a stale
        //   one captured at alert creation time.
        // Why it exists: pins the live-lookup contract.
        // Scenario: spec-first live tab lookup -- alert on paneA, move
        //   paneA, navigate; lands on paneA's new tab.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .movePaneToTab(paneId: paneA, targetTabId: tab2Id))
        model.alerts[0].isUnread = true

        createTab(&model)

        let commands = update(&model, .goToMostRecentAlertPane)
        #expect(model.selectedTabId == tab2Id, "should navigate to pane's current tab, not original tab")
        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should focus the alert's pane")
    }

    @Test("testGoToMostRecentAlertPaneSkipsReadAlerts")
    func testGoToMostRecentAlertPaneSkipsReadAlerts() {
        // Intent: read alerts are skipped (only unread are valid
        //   targets).
        // Why it exists: pins the "unread filter" rule.
        // Scenario: spec-first read-skip.
        var model = makeModel()
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let paneB = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "read", createdAt: Date(), isUnread: false
        ), at: 0)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "unread", createdAt: Date(), isUnread: true
        ), at: 1)

        let commands = update(&model, .goToMostRecentAlertPane)
        #expect(model.selectedTabId == tab1Id, "should navigate to the unread alert's tab, skipping read alert")
        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should focus the unread alert's pane")
    }

    @Test("testGoToMostRecentAlertPaneAcksCurrentTabFirst")
    func testGoToMostRecentAlertPaneAcksCurrentTabFirst() {
        // Intent: in manual mode, the helper acks the current tab's
        //   alerts before navigating elsewhere.
        // Why it exists: pins the "ack current first" rule that backs the
        //   walk algorithm.
        // Scenario: spec-first ack-current.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let paneB = model.groups[0].tabs[1].focusedPaneId

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "tab1 alert", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "tab2 alert", createdAt: Date(), isUnread: true
        ), at: 1)

        let commands = update(&model, .goToMostRecentAlertPane)
        #expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == false, "current tab's alert should be acked")
        #expect(model.alerts.first(where: { $0.paneId == paneA })?.isUnread == true, "destination alert should still be unread")
        #expect(model.selectedTabId == tab1Id, "should navigate to tab1")
        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should focus paneA")
    }

    @Test("testGoToMostRecentAlertPaneAcksCurrentTabThenNoMoreAlerts")
    func testGoToMostRecentAlertPaneAcksCurrentTabThenNoMoreAlerts() {
        // Intent: if the current tab's ack consumes the last unread
        //   alert, no navigation happens.
        // Why it exists: pins the "ack-then-done" branch.
        // Scenario: spec-first ack-only.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "only alert", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .goToMostRecentAlertPane)
        #expect(model.alerts[0].isUnread == false, "alert should be acked")
        #expect(!hasEffect(commands) {
            if case .makeFirstResponder = $0 { return true }
            return false
        }, "no unread alerts remained after acking current tab")
    }

    @Test("testGoToMostRecentAlertPaneRepeatedPressWalksTabs")
    func testGoToMostRecentAlertPaneRepeatedPressWalksTabs() {
        // Intent: repeated presses walk across alert-bearing tabs in
        //   newest-first order.
        // Why it exists: pins the cross-tab walk symmetry of the
        //   intra-tab walk.
        // Scenario: spec-first cross-tab walk.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let tab2Id = model.groups[0].tabs[1].id
        let paneB = model.groups[0].tabs[1].focusedPaneId

        createTab(&model)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "tab1 alert", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "tab2 alert", createdAt: Date(), isUnread: true
        ), at: 1)

        update(&model, .goToMostRecentAlertPane)
        #expect(model.selectedTabId == tab1Id, "first press should navigate to tab1")
        #expect(model.alerts.first(where: { $0.paneId == paneA })?.isUnread == true, "paneA alert still unread after first press")

        update(&model, .goToMostRecentAlertPane)
        #expect(model.selectedTabId == tab2Id, "second press should navigate to tab2")
        #expect(model.alerts.first(where: { $0.paneId == paneA })?.isUnread == false, "paneA alert should be acked after second press")
        #expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == true, "paneB alert still unread after second press")

        let commands = update(&model, .goToMostRecentAlertPane)
        #expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == false, "paneB alert should be acked after third press")
        #expect(!hasEffect(commands) {
            if case .makeFirstResponder = $0 { return true }
            return false
        }, "third press should not navigate")
    }

    @Test("testGoToMostRecentAlertPaneAcksAllPanesInSplit")
    func testGoToMostRecentAlertPaneAcksAllPanesInSplit() {
        // Intent: when another tab has an unread alert, the shortcut
        //   clears every unread pane in the original current tab.
        // Why it exists: pins the "finish current tab" scope for split
        //   tabs before cross-tab navigation.
        // Scenario: spec-first split tab clear.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        update(&model, .splitPane(direction: .horizontal))
        let paneC = model.groups[0].tabs[1].focusedPaneId
        let tab2PaneIds = allPaneIds(model.groups[0].tabs[1].rootNode)
        let paneB = tab2PaneIds.first(where: { $0 != paneC })!

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

        let commands = update(&model, .goToMostRecentAlertPane)
        #expect(model.alerts.first(where: { $0.paneId == paneC })?.isUnread == false,
            "focused pane's alert should be acked")
        #expect(model.alerts.first(where: { $0.paneId == paneB })?.isUnread == false,
            "non-focused sibling alert should also be acked")
        #expect(model.alerts.first(where: { $0.paneId == paneA })?.isUnread == true, "paneA alert should still be unread")
        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0, pid == paneA { return true }
            return false
        }, "should navigate to paneA")
    }

    // MARK: - filteredAlerts / alertsEmptyText Tests

    @Test("testFilteredAlertsUnreadReturnsOnlyUnread")
    func testFilteredAlertsUnreadReturnsOnlyUnread() {
        // Intent: filteredAlerts(.unread) keeps only isUnread items.
        // Why it exists: pins the unread-tab filter.
        // Scenario: spec-first unread filter.
        let paneId = PaneId()
        let alerts = [
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "a", createdAt: Date(), isUnread: true),
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "b", createdAt: Date(), isUnread: false),
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "c", createdAt: Date(), isUnread: true),
        ]
        let result = filteredAlerts(alerts, tab: .unread)
        #expect(result.count == 2, "should return only unread alerts")
        #expect(result[0].body == "a")
        #expect(result[1].body == "c")
    }

    @Test("testFilteredAlertsHistoryReturnsAll")
    func testFilteredAlertsHistoryReturnsAll() {
        // Intent: filteredAlerts(.history) returns every alert.
        // Why it exists: pins the history-tab filter.
        // Scenario: spec-first history filter.
        let paneId = PaneId()
        let alerts = [
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "a", createdAt: Date(), isUnread: true),
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "b", createdAt: Date(), isUnread: false),
        ]
        let result = filteredAlerts(alerts, tab: .history)
        #expect(result.count == 2, "history should return all alerts")
        #expect(result[0].body == "a")
        #expect(result[1].body == "b")
    }

    @Test("testFilteredAlertsUnreadAllReadReturnsEmpty")
    func testFilteredAlertsUnreadAllReadReturnsEmpty() {
        // Intent: an all-read list returns empty for the unread tab.
        // Why it exists: pins the empty filter case.
        // Scenario: spec-first empty unread.
        let paneId = PaneId()
        let alerts = [
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "a", createdAt: Date(), isUnread: false),
            AlertModel(id: AlertId(), kind: .bell, paneId: paneId, title: "T", body: "b", createdAt: Date(), isUnread: false),
        ]
        let result = filteredAlerts(alerts, tab: .unread)
        #expect(result.count == 0, "all-read list should return empty for unread tab")
    }

    @Test("testAlertsEmptyTextReturnsCorrectString")
    func testAlertsEmptyTextReturnsCorrectString() {
        // Intent: alertsEmptyText carries per-tab copy.
        // Why it exists: pins the per-tab copy lookup.
        // Scenario: spec-first empty text.
        #expect(alertsEmptyText(tab: .unread) == "No unread alerts")
        #expect(alertsEmptyText(tab: .history) == "No alerts")
    }

    @Test("testSetShowAllAlerts")
    func testSetShowAllAlerts() {
        // Intent: setShowAllAlerts sets the model flag (default false).
        // Why it exists: pins the flag setter.
        // Scenario: spec-first flag toggle.
        var model = makeModel()
        #expect(model.showAllAlerts == false, "defaults to false")
        update(&model, .setShowAllAlerts(true))
        #expect(model.showAllAlerts == true)
        update(&model, .setShowAllAlerts(false))
        #expect(model.showAllAlerts == false)
    }

    // MARK: - alert-clear-mode = manual

    @Test("testSelectTabDoesNotClearAlertsInManualMode")
    func testSelectTabDoesNotClearAlertsInManualMode() {
        // Intent: in manual mode, selectTab does NOT mark the focused
        //   pane's alerts read.
        // Why it exists: pins the manual-mode preservation rule for
        //   selectTab.
        // Scenario: spec-first manual selectTab.
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
        #expect(model.alerts[0].isUnread == true, "manual mode: selecting tab should NOT mark alerts read")
    }

    @Test("testPaneBecameFirstResponderDoesNotClearAlertsInManualMode")
    func testPaneBecameFirstResponderDoesNotClearAlertsInManualMode() {
        // Intent: in manual mode, paneBecameFirstResponder does NOT
        //   mark the new pane's alerts read.
        // Why it exists: pins the manual-mode preservation for focus
        //   changes.
        // Scenario: spec-first manual focus.
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
        #expect(model.alerts[0].isUnread == true, "manual mode: focusing pane should NOT mark alerts read")
    }

    @Test("testCloseZoomedPaneDoesNotClearAlertsInManualMode")
    func testCloseZoomedPaneDoesNotClearAlertsInManualMode() {
        // Intent: in manual mode, the closeZoomedPane refocus does NOT
        //   mark the new pane's alerts read.
        // Why it exists: pins the manual-mode preservation for the
        //   close-zoom-refocus path.
        // Scenario: spec-first manual close-zoom.
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
        #expect(model.alerts[0].isUnread == true, "manual mode: closePane should NOT clear alerts on newly focused pane")
    }

    @Test("testMovePaneToTabDoesNotClearAlertsInManualMode")
    func testMovePaneToTabDoesNotClearAlertsInManualMode() {
        // Intent: in manual mode, movePaneToTab does NOT clear the moved
        //   pane's alerts.
        // Why it exists: pins the manual-mode preservation for the
        //   reparent path.
        // Scenario: spec-first manual movePaneToTab.
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
        #expect(model.alerts[0].isUnread == true, "manual mode: movePaneToTab should NOT clear alerts")
    }

    @Test("testMovePaneToNewTabDoesNotClearAlertsInManualMode")
    func testMovePaneToNewTabDoesNotClearAlertsInManualMode() {
        // Intent: in manual mode, movePaneToNewTab does NOT clear the
        //   extracted pane's alerts.
        // Why it exists: pins the manual-mode preservation for the
        //   extraction path.
        // Scenario: spec-first manual movePaneToNewTab.
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
        #expect(model.alerts[0].isUnread == true, "manual mode: movePaneToNewTab should NOT clear alerts")
    }

    // MARK: - clearAlertsForPane

    @Test("testClearAlertsForPaneClearsAlerts")
    func testClearAlertsForPaneClearsAlerts() {
        // Intent: clearAlertsForPane marks the pane's alerts read.
        // Why it exists: pins the explicit per-pane clear.
        // Scenario: spec-first clearAlertsForPane.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .clearAlertsForPane(paneId: paneA))
        #expect(model.alerts[0].isUnread == false, "clearAlertsForPane should mark pane's alerts read")
    }

    @Test("testClearAlertsForPaneNoopsWhenNoUnreadAlerts")
    func testClearAlertsForPaneNoopsWhenNoUnreadAlerts() {
        // Intent: clearAlertsForPane on a pane with no unread alerts
        //   emits no commands.
        // Why it exists: pins the no-op guard.
        // Scenario: spec-first no-op clear.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .clearAlertsForPane(paneId: paneA))
        #expect(commands.count == 0, "clearAlertsForPane with no unread alerts should be a no-op")
    }

    @Test("testClearAlertsForNonFocusedPane")
    func testClearAlertsForNonFocusedPane() {
        // Intent: clearAlertsForPane works on a non-focused pane in
        //   manual mode.
        // Why it exists: pins that the explicit per-pane clear works
        //   regardless of focus state.
        // Scenario: spec-first manual non-focused clear.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        #expect(paneA != paneB, "split should create a new pane")

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .clearAlertsForPane(paneId: paneA))
        #expect(model.alerts[0].isUnread == false, "clearAlertsForPane should clear non-focused pane's alerts")
    }

    // MARK: - ackTabAlerts

    @Test("testAckTabAlertsClearsAllPaneAlertsInTab")
    func testAckTabAlertsClearsAllPaneAlertsInTab() {
        // Intent: ackTabAlerts marks every pane's alerts in the selected
        //   tab as read.
        // Why it exists: pins the tab-wide ack scope.
        // Scenario: spec-first ack-tab.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        #expect(paneA != paneB, "split should create a new pane")

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneB,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .ackTabAlerts)
        #expect(model.alerts.filter { $0.isUnread }.count == 0, "all tab alerts should be marked read")
    }

    @Test("testAckTabAlertsDoesNotAffectOtherTabs")
    func testAckTabAlertsDoesNotAffectOtherTabs() {
        // Intent: ackTabAlerts scope is the selected tab; other tabs
        //   stay unread.
        // Why it exists: pins the per-tab scope.
        // Scenario: spec-first ack-tab scope.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let tab1PaneId = model.groups[0].tabs[0].focusedPaneId

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

        update(&model, .selectTab(id: model.groups[0].tabs[1].id))
        update(&model, .ackTabAlerts)

        let tab1Alert = model.alerts.first { $0.paneId == tab1PaneId }!
        let tab2Alert = model.alerts.first { $0.paneId == tab2PaneId }!
        #expect(tab1Alert.isUnread == true, "other tab's alerts should remain unread")
        #expect(tab2Alert.isUnread == false, "selected tab's alerts should be cleared")
    }

    @Test("testAckTabAlertsNoopsWhenNoUnreadAlerts")
    func testAckTabAlertsNoopsWhenNoUnreadAlerts() {
        // Intent: ackTabAlerts is a no-op when no unread alerts exist.
        // Why it exists: pins the empty-state guard.
        // Scenario: spec-first ack-empty.
        var model = makeModel()
        createTab(&model)

        let commands = update(&model, .ackTabAlerts)
        #expect(commands.count == 0, "ackTabAlerts with no unread alerts should be a no-op")
    }

    // MARK: - clearAlertsForTab

    @Test("testClearAlertsForTabClearsSpecificTab")
    func testClearAlertsForTabClearsSpecificTab() {
        // Intent: clearAlertsForTabs([id]) clears alerts for that tab
        //   only.
        // Why it exists: pins the per-tab explicit clear.
        // Scenario: spec-first per-tab clear.
        var model = makeModel()
        createTab(&model)
        let tab1Id = model.groups[0].tabs[0].id
        let tab1Pane = model.groups[0].tabs[0].focusedPaneId

        createTab(&model)
        let tab2Pane = model.groups[0].tabs[1].focusedPaneId

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: tab1Pane,
            title: "DanTerm", body: "tab1", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: tab2Pane,
            title: "DanTerm", body: "tab2", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .clearAlertsForTabs(tabIds: [tab1Id]))
        let tab1Alert = model.alerts.first { $0.paneId == tab1Pane }!
        let tab2Alert = model.alerts.first { $0.paneId == tab2Pane }!
        #expect(tab1Alert.isUnread == false, "target tab's alerts should be cleared")
        #expect(tab2Alert.isUnread == true, "other tab's alerts should remain unread")
    }

    @Test("testClearAlertsForTabNoopsWhenNoUnreadAlerts")
    func testClearAlertsForTabNoopsWhenNoUnreadAlerts() {
        // Intent: clearAlertsForTabs on a tab with no alerts is a no-op.
        // Why it exists: pins the no-op guard.
        // Scenario: spec-first no-op per-tab clear.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id

        let commands = update(&model, .clearAlertsForTabs(tabIds: [tabId]))
        #expect(commands.count == 0, "clearAlertsForTabs with no unread alerts should be a no-op")
    }

    @Test("testGoToMostRecentAlertPaneUnzoomsIfNeeded")
    func testGoToMostRecentAlertPaneUnzoomsIfNeeded() {
        // Intent: goToMostRecentAlertPane clears zoom when the alert
        //   targets a different pane than the zoomed focus.
        // Why it exists: pins the zoom-clear interaction on cross-pane
        //   navigation.
        // Scenario: spec-first go-to unzoom.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].focusedPaneId
        update(&model, .toggleZoomPane)
        #expect(model.groups[0].tabs[0].isZoomed == true)

        createTab(&model)

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        update(&model, .goToMostRecentAlertPane)
        #expect(model.groups[0].tabs[0].isZoomed == false, "zoom should clear when navigating to different pane")
        _ = paneB
    }

    // MARK: - clearAlertsForTabs (batch from multi-select context menu)

    @Test("testClearAlertsForTabsClearsAllSelected")
    func testClearAlertsForTabsClearsAllSelected() {
        // Intent: clearAlertsForTabs(ids) clears every selected tab's
        //   alerts; non-selected tabs are untouched.
        // Why it exists: pins the batch context-menu path.
        // Scenario: spec-first batch clear.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
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

        let commands = update(&model, .clearAlertsForTabs(tabIds: [id1, id2]))

        let unreadByPane: (PaneId) -> Bool = { pid in
            model.alerts.contains { $0.paneId == pid && $0.isUnread }
        }
        #expect(!unreadByPane(pane1), "tab1 alerts cleared")
        #expect(!unreadByPane(pane2), "tab2 alerts cleared")
        #expect(unreadByPane(pane3), "tab3 alert preserved")
        #expect(commands.isEmpty, "clearing emits no commands (badges reconcile)")
        _ = id3
    }

    @Test("testClearAlertsForTabsRefreshesOnlyTabsWithUnreadAlerts")
    func testClearAlertsForTabsRefreshesOnlyTabsWithUnreadAlerts() {
        // Intent: only tabs with unread alerts trigger model mutations
        //   in the batch; empty tabs are no-ops within the batch.
        // Why it exists: pins the batch's per-tab filtering.
        // Scenario: spec-first batch filter.
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

        let commands = update(&model, .clearAlertsForTabs(tabIds: [id1, id2]))

        #expect(!model.alerts.contains { $0.paneId == pane1 && $0.isUnread },
            "id1's unread alert should be cleared")
        #expect(commands.isEmpty, "clearing emits no commands (badges reconcile)")
    }

    @Test("testClearAlertsForTabsNoUnreadIsNoop")
    func testClearAlertsForTabsNoUnreadIsNoop() {
        // Intent: a batch over tabs with no unread alerts is a no-op.
        // Why it exists: pins the empty-batch guard.
        // Scenario: spec-first batch no-op.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let id1 = model.groups[0].tabs[0].id
        let id2 = model.groups[0].tabs[1].id

        let commands = update(&model, .clearAlertsForTabs(tabIds: [id1, id2]))
        #expect(commands.count == 0,
            "no unread alerts on any selected tab -> no-op")
    }

    @Test("testClearAlertsForTabsAllStaleIsNoop")
    func testClearAlertsForTabsAllStaleIsNoop() {
        // Intent: an all-stale-id batch is a no-op; real alerts are
        //   untouched.
        // Why it exists: pins the stale-id fail-closed.
        // Scenario: spec-first batch stale.
        var model = makeModel()
        createTab(&model)
        let pane = model.groups[0].tabs[0].focusedPaneId
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: pane,
            title: "x", body: "y", createdAt: Date(), isUnread: true
        ), at: 0)

        let commands = update(&model, .clearAlertsForTabs(
            tabIds: [TabId(), TabId()]))

        #expect(commands.count == 0, "all stale ids -> no-op")
        #expect(model.alerts.contains { $0.isUnread },
            "real alerts unaffected by stale-id batch")
    }
}
