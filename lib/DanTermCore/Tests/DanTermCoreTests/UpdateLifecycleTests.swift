// Swift Testing migration of the legacy `tests/UpdateLifecycleTests.swift`
// harness suite. Pins the app-lifecycle Msg paths: appBecameActive /
// appResignedActive (isAppActive flag, alert auto-clear in focus mode,
// manual mode preservation), activateAlert (tab + focus navigation, zoom
// clear / preserve, stale-pane handling, popover dismissal), the quit
// confirmation cycle (requestQuit -> confirmConfirmation / cancelConfirmation),
// the close-tab(s) confirmation response shims, and the no-op guards while
// either confirmation is pending. The terminate command and unified response
// message pattern matches inside `commands[0]` convert to
// `Issue.record + return` to preserve the per-file failure-site count.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateLifecycleTests {
    @Test("testAppResignedActiveClearsActiveFlag")
    func testAppResignedActiveClearsActiveFlag() {
        // Intent: app deactivation records that DanTerm is no longer active in
        //   the pure model.
        // Why it exists: focused-pane notification suppression depends on a
        //   model-owned foreground/background flag.
        // Scenario: the user switches to another app; subsequent focused-pane
        //   bells should be treated as unseen. Spec-first -- no incident to
        //   cite, and none should be invented.
        var model = makeModel()

        let commands = update(&model, .appResignedActive)

        #expect(model.isAppActive == false, "app should be marked inactive")
        #expect(commands.isEmpty, "deactivation is pure model bookkeeping")
    }

    @Test("testAppBecameActiveSetsActiveFlag")
    func testAppBecameActiveSetsActiveFlag() {
        // Intent: app activation records that DanTerm is active in the pure
        //   model.
        // Why it exists: focused-pane notification suppression should resume as
        //   soon as the app is foregrounded.
        // Scenario: the user switches back to DanTerm; subsequent focused-pane
        //   bells should be suppressed as visible-pane noise. Spec-first -- no
        //   incident to cite, and none should be invented.
        var model = makeModel()
        model.isAppActive = false

        let commands = update(&model, .appBecameActive)

        #expect(model.isAppActive == true, "app should be marked active")
        #expect(commands.isEmpty, "activation is pure model bookkeeping")
    }

    @Test("testAppBecameActiveMarksFocusedPaneAlertReadInFocusMode")
    func testAppBecameActiveMarksFocusedPaneAlertReadInFocusMode() {
        // Intent: returning to DanTerm in focus-clear mode marks the selected
        //   tab's focused-pane alert read.
        // Why it exists: inactive focused-pane notifications need backing
        //   alerts for click navigation, but should not leave a stale badge on
        //   the pane the user is now viewing.
        // Scenario: a focused pane rings while DanTerm is backgrounded, then the
        //   user switches back without clicking the notification. Spec-first --
        //   no incident to cite, and none should be invented.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        model.isAppActive = false
        update(&model, .sessionBell(sessionId: sessionId(for: paneId, in: model)))

        update(&model, .appBecameActive)

        #expect(model.alerts.count == 1, "setup should create one alert")
        #expect(model.alerts[0].paneId == paneId)
        #expect(model.alerts[0].isUnread == false, "focused pane alert should be marked read")
    }

    @Test("testAppBecameActiveDoesNotMarkReadInManualMode")
    func testAppBecameActiveDoesNotMarkReadInManualMode() {
        // Intent: returning to DanTerm in manual-clear mode leaves the selected
        //   tab's focused-pane alert unread.
        // Why it exists: the app-active auto-clear must respect the user's
        //   explicit alert-clear preference.
        // Scenario: a user who chose manual alert clearing switches back after a
        //   backgrounded focused-pane bell; the badge remains until explicit ack.
        //   Spec-first -- no incident to cite, and none should be invented.
        var model = makeModel()
        model.config.alertClearMode = .manual
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        model.isAppActive = false
        update(&model, .sessionBell(sessionId: sessionId(for: paneId, in: model)))

        update(&model, .appBecameActive)

        #expect(model.alerts.count == 1, "setup should create one alert")
        #expect(model.alerts[0].paneId == paneId)
        #expect(model.alerts[0].isUnread == true, "manual mode should leave alert unread")
    }

    @Test("testAppBecameActiveLeavesBackgroundPaneAlertUnread")
    func testAppBecameActiveLeavesBackgroundPaneAlertUnread() {
        // Intent: returning to DanTerm clears only the selected tab's focused
        //   pane alert, not alerts from background tabs.
        // Why it exists: auto-clear on activation models the pane now visible to
        //   the user, not every alert created while the app was inactive.
        // Scenario: one focused-pane alert and one background-tab alert arrive
        //   while DanTerm is backgrounded; only the visible pane's badge clears
        //   on return. Spec-first -- no incident to cite, and none should be
        //   invented.
        var model = makeModel()
        createTab(&model)
        let backgroundPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        createTab(&model)
        let focusedPaneId = model.groups[0].tabs[1].paneTree.focusedPaneId
        model.isAppActive = false

        update(&model, .sessionBell(sessionId: sessionId(for: backgroundPaneId, in: model)))
        update(&model, .sessionBell(sessionId: sessionId(for: focusedPaneId, in: model)))
        update(&model, .appBecameActive)

        let backgroundAlert = model.alerts.first { $0.paneId == backgroundPaneId }
        let focusedAlert = model.alerts.first { $0.paneId == focusedPaneId }
        #expect(backgroundAlert?.isUnread == true, "background pane alert should stay unread")
        #expect(focusedAlert?.isUnread == false, "focused pane alert should be marked read")
    }

    @Test("inactive focus changes preserve alerts until the app becomes active")
    func inactiveFocusChangePreservesAlertUntilAppBecomesActive() {
        // Intent: focus-mode reconciliation waits until the selected pane is
        //   visible before it marks that pane's alerts read.
        // Why it exists: the shared reconcile pass must not erase an alert
        //   while DanTerm is inactive, including after a background focus move.
        // Scenario: REDUCE-3 -- tab A has an unread alert, background work
        //   selects it, and foregrounding DanTerm then acknowledges the alert.
        var model = makeModel()
        model.config.alertClearMode = .focus
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        let paneAId = model.groups[0].tabs[0].paneTree.focusedPaneId
        createTab(&model)
        model.alerts = [AlertModel(
            id: AlertId(), kind: .bell, paneId: paneAId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        )]
        model.isAppActive = false

        update(&model, .selectTab(id: tabAId))

        #expect(model.alerts[0].isUnread == true,
                "a focus change while inactive must preserve the alert")

        update(&model, .appBecameActive)

        #expect(model.alerts[0].isUnread == false,
                "foregrounding makes the focused pane visible and clears its alert")
    }

    @Test("testActivateAlert")
    func testActivateAlert() {
        // Intent: activateAlert selects the alert's tab, marks the alert
        //   read, records pane focus, activates the app, and
        //   dismisses the alerts popover.
        // Why it exists: pins the full notification-click navigation path.
        // Scenario: spec-first activate-alert.
        var model = makeModel()
        createTab(&model)
        let firstTabId = model.groups[0].tabs[0].id
        let firstPaneId = model.groups[0].tabs[0].paneTree.focusedPaneId

        createTab(&model)

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: firstPaneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alertsPopoverOpen = true

        let commands = update(&model, .activateAlert(alertId: alertId))
        #expect(model.selectedTabId == firstTabId, "should select the alert's tab")
        #expect(model.alerts[0].isUnread == false, "alert should be marked read")
        #expect(desiredPaneFocus(in: model) == .terminal(firstPaneId))
        #expect(hasEffect(commands) {
            if case .activateApp = $0 { return true }
            return false
        }, "should activate app")
        #expect(model.alertsPopoverOpen == false, "should dismiss alerts popover")
    }

    @Test("testActivateAlertStalePane")
    func testActivateAlertStalePane() {
        // Intent: an alert whose pane is gone is still marked read and
        //   dismisses the popover, but does not change desired focus.
        // Why it exists: pins fail-closed for stale alert paneIds.
        // Scenario: spec-first stale-pane activation.
        var model = makeModel()
        createTab(&model)

        let stalePaneId = PaneId()
        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: stalePaneId,
            title: "DanTerm", body: "stale", createdAt: Date(), isUnread: true
        ), at: 0)
        model.alertsPopoverOpen = true

        _ = update(&model, .activateAlert(alertId: alertId))
        #expect(model.alerts[0].isUnread == false, "stale alert should be marked read")
        #expect(model.alertsPopoverOpen == false, "should still dismiss popover")
    }

    @Test("testActivateAlertWhileZoomedClearsZoom")
    func testActivateAlertWhileZoomedClearsZoom() {
        // Intent: activateAlert that targets a different pane than the
        //   current zoomed focus clears zoom.
        // Why it exists: pins the zoom-clear rule on cross-pane alert
        //   activation.
        // Scenario: spec-first zoom-clear-on-activate.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .toggleZoomPane(paneId: nil))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == true)

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneA,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        _ = update(&model, .activateAlert(alertId: alertId))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == false, "zoom should clear when alert targets different pane")
        #expect(desiredPaneFocus(in: model) == .terminal(paneA))
        _ = paneB
    }

    @Test("testActivateAlertWhileZoomedSamePaneKeepsZoom")
    func testActivateAlertWhileZoomedSamePaneKeepsZoom() {
        // Intent: activateAlert targeting the already-zoomed focused pane
        //   preserves zoom.
        // Why it exists: pins the zoom-preserve branch (same-pane
        //   activation is a no-op for layout).
        // Scenario: spec-first zoom-preserve.
        var model = makeModel()
        createTab(&model)

        update(&model, .splitFocusedPane(direction: .horizontal))
        let paneB = model.groups[0].tabs[0].paneTree.focusedPaneId
        update(&model, .toggleZoomPane(paneId: nil))

        let alertId = AlertId()
        model.alerts.insert(AlertModel(
            id: alertId, kind: .bell, paneId: paneB,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)

        _ = update(&model, .activateAlert(alertId: alertId))
        #expect(model.groups[0].tabs[0].paneTree.isZoomed == true, "zoom should remain when alert targets same pane")
    }

    @Test("testTerminate")
    func testTerminate() {
        // Intent: .terminate emits exactly one terminate command.
        // Why it exists: pins the bare wiring of the terminate Msg.
        // Scenario: spec-first terminate emission.
        var model = makeModel()
        let commands = update(&model, .terminate)
        #expect(commands.count == 1)
        if case .terminate = commands[0] {
            // good
        } else {
            Issue.record("expected terminate command")
            return
        }
    }

    @Test("testRequestQuitWithOnePane")
    func testRequestQuitWithOnePane() {
        // Intent: requestQuit with a single pane sets pendingConfirmation
        //   to .terminate and emits no commands (the reconciler drives the
        //   panel).
        // Why it exists: pins the single-pane quit-confirm path.
        // Scenario: spec-first single-pane quit.
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .requestQuit)
        #expect(commands.isEmpty, "no command; reconcileQuitConfirmation drives the panel")
        #expect(model.pendingConfirmation?.subject == .app, "quit confirmation should be pending")
    }

    @Test("testRequestQuitWithMultiplePanes")
    func testRequestQuitWithMultiplePanes() {
        // Intent: requestQuit with multiple panes also sets pending
        //   confirmation without emitting commands.
        // Why it exists: pins the multi-pane symmetry.
        // Scenario: spec-first multi-pane quit.
        var model = makeModel()
        createTab(&model)
        update(&model, .splitFocusedPane(direction: .horizontal))
        createTab(&model)
        let commands = update(&model, .requestQuit)
        #expect(commands.isEmpty, "no command; reconcileQuitConfirmation drives the panel")
        #expect(model.pendingConfirmation?.subject == .app, "quit confirmation should be pending")
    }

    @Test("testRequestQuitSetsPending")
    func testRequestQuitSetsPending() {
        // Intent: requestQuit always records an app confirmation transaction.
        // Why it exists: pins the pending-state mutation.
        // Scenario: spec-first pending set.
        var model = makeModel()
        createTab(&model)

        let commands = update(&model, .requestQuit)

        #expect(commands.isEmpty, "no command; reconcileQuitConfirmation drives the panel")
        #expect(model.pendingConfirmation?.subject == .app, "quit confirmation should be pending")
    }

    @Test("a repeated quit request replaces the transaction")
    func repeatedQuitRequestReplacesTransaction() throws {
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .requestQuit)
        let firstId = try #require(model.pendingConfirmation?.id)

        let commands = update(&model, .requestQuit)

        #expect(commands.isEmpty)
        #expect(model.pendingConfirmation?.subject == .app)
        #expect(model.pendingConfirmation?.id != firstId)
    }

    @Test("testCloseTabLastTabWhileQuitPendingIsNoOp")
    func testCloseTabLastTabWhileQuitPendingIsNoOp() {
        // Intent: closeTab is blocked while a quit confirmation is
        //   pending.
        // Why it exists: pins the cross-Msg block.
        // Scenario: spec-first cross-block (closeTab vs terminate).
        var model = makeModel()
        createTab(&model)
        let originalGroups = model.groups
        let originalPanes = model.allPanes
        let tabId = model.groups[0].tabs[0].id
        model.pendingConfirmation = pendingAppConfirmation()

        let commands = update(&model, .closeTab(id: tabId))

        #expect(commands.count == 0, "closeTab should be blocked by pending quit confirmation")
        #expect(model.groups == originalGroups, "groups should be unchanged")
        #expect(model.allPanes == originalPanes, "panes should be unchanged")
    }

    @Test("testClosePaneLastPaneWhileQuitPendingIsNoOp")
    func testClosePaneLastPaneWhileQuitPendingIsNoOp() {
        // Intent: closePane is blocked while a quit confirmation is
        //   pending.
        // Why it exists: pins the cross-Msg block for pane closes.
        // Scenario: spec-first cross-block (closePane vs terminate).
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let originalPanes = model.allPanes
        model.pendingConfirmation = pendingAppConfirmation()

        let commands = update(&model, .closePane(paneId: paneId))

        #expect(commands.count == 0, "closePane should be blocked by pending quit confirmation")
        #expect(model.allPanes == originalPanes, "panes should be unchanged")
    }

    @Test("testDeleteGroupLastGroupTabsWhileQuitPendingIsNoOp")
    func testDeleteGroupLastGroupTabsWhileQuitPendingIsNoOp() {
        // Intent: deleteGroup is blocked while a quit confirmation is
        //   pending.
        // Why it exists: pins the cross-Msg block for group deletes.
        // Scenario: spec-first cross-block (deleteGroup vs terminate).
        var model = makeModel()
        createTab(&model)
        let tabsGroupId = model.groups[0].id
        let emptyGroupId = GroupId()
        model.groups.append(GroupModel(id: emptyGroupId, name: "Empty"))
        model.pendingConfirmation = pendingAppConfirmation()

        let commands = update(&model, .deleteGroup(id: tabsGroupId, moveTabs: false))

        #expect(commands.count == 0, "deleteGroup should be blocked by pending quit confirmation")
        #expect(model.groups.contains { $0.id == tabsGroupId }, "tabs group should remain")
        #expect(model.groups.contains { $0.id == emptyGroupId }, "empty group should remain")
    }

    @Test("testConfirmTerminateAlwaysTerminates")
    func testConfirmTerminateAlwaysTerminates() {
        // Intent: confirming an app transaction emits terminate regardless of remaining
        //   panes.
        // Why it exists: pins the unconditional terminate-on-confirm rule.
        // Scenario: spec-first confirm-terminate.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        model.pendingConfirmation = pendingAppConfirmation()
        let commands = confirmPending(&model)
        #expect(commands.count == 1)
        #expect(hasEffect(commands) {
            if case .terminate = $0 { return true }
            return false
        }, "should unconditionally terminate after confirmation")
    }

    @Test("testConfirmTerminateClearsPending")
    func testConfirmTerminateClearsPending() {
        // Intent: app confirmation clears pendingConfirmation and emits
        //   exactly one terminate command.
        // Why it exists: pins the pending-state + command emission pair.
        // Scenario: spec-first confirm-and-clear.
        var model = makeModel()
        createTab(&model)
        model.pendingConfirmation = pendingAppConfirmation()

        let commands = confirmPending(&model)

        #expect(commands.count == 1)
        if case .terminate = commands[0] {
            // good
        } else {
            Issue.record("expected terminate command")
            return
        }
        #expect(model.pendingConfirmation == nil, "confirm should clear pending confirmation")
    }

    @Test("testCancelTerminate")
    func testCancelTerminate() {
        // Intent: canceling a confirmation produces no commands.
        // Why it exists: pins the cancel-side no-op.
        // Scenario: spec-first cancel.
        var model = makeModel()
        createTab(&model)
        let commands = update(&model, .cancelConfirmation(id: ConfirmationId()))
        #expect(commands.count == 0, "cancel should produce no commands")
    }

    @Test("testCancelTerminateClearsPending")
    func testCancelTerminateClearsPending() {
        // Intent: canceling clears pendingConfirmation.
        // Why it exists: pins the pending-clear pair.
        // Scenario: spec-first cancel-and-clear.
        var model = makeModel()
        createTab(&model)
        model.pendingConfirmation = pendingAppConfirmation()

        let commands = cancelPending(&model)

        #expect(commands.count == 0, "cancel should produce no commands")
        #expect(model.pendingConfirmation == nil, "cancel should clear pending confirmation")
    }

    @Test("testRequestQuitAgainAfterCancel")
    func testRequestQuitAgainAfterCancel() {
        // Intent: after cancel, a new requestQuit can re-open the
        //   confirmation.
        // Why it exists: pins the reusable confirmation path.
        // Scenario: spec-first re-quit after cancel.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .requestQuit)
        _ = cancelPending(&model)

        let commands = update(&model, .requestQuit)

        #expect(commands.isEmpty, "no command; reconcileQuitConfirmation drives the panel")
        #expect(model.pendingConfirmation?.subject == .app, "quit confirmation should be pending")
    }

    @Test("a quit request replaces a pending close-tab transaction")
    func quitRequestReplacesPendingCloseTab() {
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        model.pendingConfirmation = pendingCloseConfirmation(for: .tab(tabId), in: model)

        let commands = update(&model, .requestQuit)

        #expect(commands.isEmpty)
        #expect(model.pendingConfirmation?.subject == .app)
    }

    @Test("testCloseTabConfirmationResponseConfirm")
    func testCloseTabConfirmationResponseConfirm() {
        // Intent: closeTabConfirmationResponse(isConfirm: true) returns
        //   the unified confirm message.
        // Why it exists: pins the dispatcher-side shim that converts an
        //   NSAlert response into a Msg.
        // Scenario: spec-first response confirm.
        let id = ConfirmationId()
        let msg = confirmationResponse(id: id, isConfirm: true)

        if case .confirmConfirmation(let answerId) = msg {
            #expect(answerId == id)
        } else {
            Issue.record("expected confirmConfirmation")
            return
        }
    }

    @Test("testCloseTabConfirmationResponseCancel")
    func testCloseTabConfirmationResponseCancel() {
        // Intent: closeTabConfirmationResponse(isConfirm: false) returns
        //   the unified cancel message.
        // Why it exists: pins the cancel branch of the shim.
        // Scenario: spec-first response cancel.
        let id = ConfirmationId()
        let msg = confirmationResponse(id: id, isConfirm: false)

        if case .cancelConfirmation(let answerId) = msg {
            #expect(answerId == id)
        } else {
            Issue.record("expected cancelConfirmation")
            return
        }
    }

    @Test("testCloseTabsConfirmationResponseConfirm")
    func testCloseTabsConfirmationResponseConfirm() {
        // Intent: closeTabsConfirmationResponse(isConfirm: true) returns
        //   the unified confirm message for batch alerts too.
        // Why it exists: pins the dispatcher-side shim that converts an
        //   NSAlert response into a Msg for batch tab close confirmations.
        // Scenario: spec-first batch response confirm.
        let id = ConfirmationId()
        let msg = confirmationResponse(id: id, isConfirm: true)

        if case .confirmConfirmation(let answerId) = msg {
            #expect(answerId == id)
        } else {
            Issue.record("expected confirmConfirmation")
            return
        }
    }

    @Test("testCloseTabsConfirmationResponseCancel")
    func testCloseTabsConfirmationResponseCancel() {
        // Intent: closeTabsConfirmationResponse(isConfirm: false) returns
        //   the unified cancel message for batch alerts too.
        // Why it exists: pins the cancel branch of the batch confirmation shim.
        // Scenario: spec-first batch response cancel.
        let id = ConfirmationId()
        let msg = confirmationResponse(id: id, isConfirm: false)

        if case .cancelConfirmation(let answerId) = msg {
            #expect(answerId == id)
        } else {
            Issue.record("expected cancelConfirmation")
            return
        }
    }
}
