// Pins the Msg paths a live terminal session drives: sessionBell + OSC
// desktopNotification routing (focused-pane suppression vs background-pane
// alert + sendNotification, with per-kind throttling), sessionCreationFailed
// cleanup (single + split tab, terminate vs fallback), session metadata
// updates (title/cwd/progress), and alert/command-event coalescing policy
// against post-reconcile forcing.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateSessionEventTests {
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

        let commands = update(&model, .sessionBell(paneId: paneId))
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

        let commands = update(&model, .sessionBell(paneId: firstTabPaneId))
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

        let commands = update(&model, .sessionBell(paneId: paneId))
        #expect(model.alerts.count == 1, "should create one alert")
        #expect(model.alerts[0].kind == .bell)
        #expect(model.alerts[0].isUnread == true, "alert should be unread")
        #expect(model.alerts[0].paneId == paneId)
        #expect(hasEffect(commands) {
            if case .sendNotification = $0 { return true }
            return false
        }, "should emit sendNotification for inactive focused-pane bell")
    }

    @Test("testSessionCreationFailedCleansUp")
    func testSessionCreationFailedCleansUp() {
        // Intent: sessionCreationFailed on the only pane removes the pane +
        //   its tab, emits terminate (no tabs left), and the session-
        //   existence net tears down the failed pane's session.
        // Why it exists: pins the bottom-out terminate path.
        // Scenario: spec-first terminate -- last tab's pane fails to be
        //   created; app must terminate.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let liveSessionIds = Set(model.allPaneIds)

        let commands = update(&model, .sessionCreationFailed(paneId: paneId))
        #expect(model.pane(paneId) == nil, "pane should be removed")
        #expect(model.groups[0].tabs.count == 0, "tab should be removed")
        #expect(hasEffect(commands) {
            if case .terminate = $0 { return true }
            return false
        }, "should terminate when no tabs left")
        #expect(sessionsToTearDown(liveSessionIds: liveSessionIds, model: model) == Set([paneId]),
            "failed pane session is torn down")
    }

    @Test("sessionCreationFailed removes split tab siblings")
    func sessionCreationFailedRemovesSplitTabSiblings() {
        // Intent: a failure on one pane of a split tab removes BOTH panes
        //   (the tab as a whole), selects a fallback tab, and tears down
        //   both pane sessions.
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
        let liveSessionIds = Set(model.allPaneIds)

        let commands = update(&model, .sessionCreationFailed(paneId: paneA))

        #expect(model.selectedTabId == fallbackTabId, "selection should move to fallback tab")
        #expect(model.pane(paneA) == nil, "failed pane should be removed")
        #expect(model.pane(paneB) == nil, "sibling pane should be removed")
        #expect(!model.groups[0].tabs.contains { $0.id == tabId }, "failed tab should be removed")
        #expect(sessionsToTearDown(liveSessionIds: liveSessionIds, model: model) == Set([paneA, paneB]),
            "both sibling pane sessions are torn down")
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

        update(&model, .sessionBell(paneId: firstTabPaneId))
        #expect(model.lastNotificationTime[firstTabPaneId]?[.bell] != nil, "should set lastNotificationTime for bell")

        let effects2 = update(&model, .sessionBell(paneId: firstTabPaneId))
        #expect(!hasEffect(effects2) {
            if case .sendNotification = $0 { return true }
            return false
        }, "second bell should be throttled (no sendNotification)")
    }

    @Test("reconcileDecision coalesces only eligible high-frequency messages")
    func reconcileDecisionCoalescesOnlyEligibleMessages() throws {
        // Intent: high-frequency split-ratio, search-count, background alert,
        //   and command-event messages classify as coalesce-eligible while
        //   post-reconcile commands still force inline.
        // Why it exists: pins reconcile coalescing policy against regressions in
        //   message classification, pending-state handling, and post-reconcile
        //   command forcing.
        // Scenario: divider drags, streaming search scans, bell/notification
        //   storms, and shell-integration command loops emit bursts whose empty
        //   or cosmetic sweeps defer into the 75 ms timer. Spec-first -- no
        //   incident to cite, and none should be invented.
        let paneId = PaneId()
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        let coalescedMessages: [Msg] = [
            .sessionTitle(paneId: paneId, title: "vim"),
            .sessionCwd(paneId: paneId, cwd: "/tmp"),
            .sessionProgress(paneId: paneId, state: .set(percent: 50)),
            .splitRatioChanged(splitId: SplitId(), ratio: 0.3),
            .searchTotalReported(paneId: paneId, total: 42),
            .searchSelectionReported(paneId: paneId, selected: 3),
            .sessionBell(paneId: paneId),
            .desktopNotification(
                paneId: paneId,
                title: "build",
                body: "done"
            ),
            lifecycleMessage(paneId: paneId, event: .commandStarted("make test")),
            lifecycleMessage(
                paneId: paneId,
                event: .commandEnded(exitStatus: 0),
                after: [.commandStarted("make test")]
            ),
            lifecycleMessage(
                paneId: paneId,
                event: .agentActivityChanged(session: agent, activity: .waiting),
                after: [.agentAttached(agent)]
            ),
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
            lifecycleMessage(paneId: paneId, event: .integrationReady),
            lifecycleMessage(paneId: paneId, event: .remoteDetected),
            lifecycleMessage(paneId: paneId, event: .remoteIdentityReported(
                RemoteSession(user: "dan", host: "caja")
            )),
            lifecycleMessage(
                paneId: paneId,
                event: .connectionEnded,
                after: [.remoteDetected]
            ),
            lifecycleMessage(paneId: paneId, event: .agentAttached(agent)),
            lifecycleMessage(
                paneId: paneId,
                event: .agentDetached(agent),
                after: [.agentAttached(agent)]
            ),
            .preferencesOpened(),
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

    @Test("coalesce-eligible messages emit no post-reconcile commands")
    func coalesceEligibleMessagesEmitNoPostReconcileCommands() {
        // Intent: coalesce-eligible metadata, alert, and command events emit no
        //   post-reconcile commands so they can ride the coalesced sweep.
        // Why it exists: pins the "no post-reconcile in coalesced messages" rule
        //   the coalescer relies on.
        // Scenario: spec-first coalesce eligibility -- iterate focused and
        //   unfocused-pane metadata Msgs plus background alert and command Msgs;
        //   none emit post-reconcile commands.
        var focusedModel = makeModel()
        createTab(&focusedModel)
        let focusedPane = focusedModel.groups[0].tabs[0].focusedPaneId

        var unfocusedModel = makeModel()
        createTab(&unfocusedModel)
        let unfocusedPane = unfocusedModel.groups[0].tabs[0].focusedPaneId
        update(&unfocusedModel, .splitPane(direction: .horizontal))

        let scenarios: [(Msg, AppModel)] = [
            (.sessionTitle(paneId: focusedPane, title: "vim"), focusedModel),
            (.sessionCwd(paneId: focusedPane, cwd: "/tmp"), focusedModel),
            (.sessionProgress(paneId: focusedPane, state: .set(percent: 50)), focusedModel),
            (.sessionTitle(paneId: unfocusedPane, title: "htop"), unfocusedModel),
            (.sessionCwd(paneId: unfocusedPane, cwd: "/var/tmp"), unfocusedModel),
            (.sessionProgress(paneId: unfocusedPane, state: .indeterminate), unfocusedModel),
            (.sessionBell(paneId: unfocusedPane), unfocusedModel),
            (.desktopNotification(
                paneId: unfocusedPane,
                title: "build",
                body: "done"
            ), unfocusedModel),
            (lifecycleMessage(paneId: unfocusedPane, event: .commandStarted("make")), unfocusedModel),
            (lifecycleMessage(
                paneId: unfocusedPane,
                event: .commandEnded(exitStatus: 0),
                after: [.commandStarted("make")]
            ), unfocusedModel)
        ]

        for (msg, seedModel) in scenarios {
            var model = seedModel
            let commands = update(&model, msg)
            #expect(commands.allSatisfy { $0.isPostReconcile == false },
                "coalesced update should not emit post-reconcile commands")
        }
    }

    @Test("testSessionTitleFocusedPane")
    func testSessionTitleFocusedPane() {
        // Intent: sessionTitle on the focused pane updates both the pane's
        //   title and the tab's title (chrome sync).
        // Why it exists: pins the focused-pane chrome sync.
        // Scenario: spec-first focused title.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .sessionTitle(paneId: paneId, title: "vim"))
        #expect(model.pane(paneId)?.title == "vim")
        #expect(model.groups[0].tabs[0].title == "vim")
    }

    @Test("testSessionTitleUnfocusedPane")
    func testSessionTitleUnfocusedPane() {
        // Intent: sessionTitle on an unfocused pane updates the pane's title only, with
        //   no tab chrome change or side-effect command.
        // Why it exists: pins the per-pane scope of the title update.
        // Scenario: spec-first unfocused title.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))

        let commands = update(&model, .sessionTitle(paneId: paneA, title: "htop"))
        #expect(model.pane(paneA)?.title == "htop", "pane title should update")
        #expect(model.groups[0].tabs[0].title == "Terminal", "tab title should not change")
        #expect(commands.isEmpty)
    }

    @Test("testSessionPwdFocusedPane")
    func testSessionPwdFocusedPane() {
        // Intent: sessionCwd on the focused pane updates the pane's cwd
        //   and the tab's subtitle (abbreviated from $HOME).
        // Why it exists: pins the chrome-sync for cwd on the selected
        //   tab.
        // Scenario: spec-first focused cwd.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .sessionCwd(paneId: paneId, cwd: "/home/dan/projects"))
        #expect(model.pane(paneId)?.cwd == "/home/dan/projects")
        #expect(model.groups[0].tabs[0].subtitle == abbreviateHome("/home/dan/projects"),
            "focused-pane cwd syncs the selected tab's subtitle (the window-chrome input)")
    }

    @Test("testSessionPwdUnfocusedPane")
    func testSessionPwdUnfocusedPane() {
        // Intent: sessionCwd on an unfocused pane only updates the pane's cwd, with no
        //   side-effect command.
        // Why it exists: pins the per-pane scope for cwd updates.
        // Scenario: spec-first unfocused cwd.
        var model = makeModel()
        createTab(&model)
        let paneA = model.groups[0].tabs[0].focusedPaneId

        update(&model, .splitPane(direction: .horizontal))

        let commands = update(&model, .sessionCwd(paneId: paneA, cwd: "/tmp"))
        #expect(model.pane(paneA)?.cwd == "/tmp", "pane cwd should update")
        #expect(commands.isEmpty)
    }

    @Test("testSessionTitleBackgroundTab")
    func testSessionTitleBackgroundTab() {
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

        update(&model, .sessionTitle(paneId: paneA, title: "vim"))
        #expect(model.pane(paneA)?.title == "vim", "pane title should update")
        #expect(model.groups[0].tabs[0].title == "vim", "background tab title should update")
    }

    @Test("testSessionPwdBackgroundTab")
    func testSessionPwdBackgroundTab() {
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

        update(&model, .sessionCwd(paneId: paneA, cwd: "/tmp"))
        #expect(model.pane(paneA)?.cwd == "/tmp", "pane cwd should update")
        #expect(model.groups[0].tabs[0].subtitle == ("~" == abbreviateHome("/tmp") ? "~" : "/tmp"), "background tab subtitle should update")
    }

    @Test("terminal metadata accepts 64 KiB values and rejects larger values")
    func terminalMetadataValueLimit() {
        // Intent: every untrusted string-bearing terminal message applies at
        //   exactly 64 KiB, has no model or command effect above the limit, and
        //   a later valid value still applies after an oversized one was
        //   rejected (I4: no partial/stuck effect from an oversized value).
        // Why it exists: pins DanTerm's defensive boundary independently of
        //   TerminalCore's parser-side validation, now that there is no
        //   aggregate per-pane budget to fall back on -- the per-value guard is
        //   the entire model-side contract.
        // Scenario: a backend sends title, cwd, and notification values at and
        //   just beyond the advertised limit, oversized-then-valid. Command and
        //   remote identity enter through the engine-to-pane admission tests.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let accepted = String(repeating: "a", count: 64 * 1024)
        let rejected = accepted + "b"

        #expect(update(&model, .sessionTitle(paneId: paneId, title: rejected)).isEmpty)
        #expect(model.pane(paneId)?.title != rejected)
        #expect(update(&model, .sessionTitle(paneId: paneId, title: accepted)).isEmpty)
        #expect(model.pane(paneId)?.title == accepted)

        #expect(update(&model, .sessionCwd(paneId: paneId, cwd: rejected)).isEmpty)
        #expect(model.pane(paneId)?.cwd != rejected)
        #expect(update(&model, .sessionCwd(paneId: paneId, cwd: accepted)).isEmpty)
        #expect(model.pane(paneId)?.cwd == accepted)

        model.isAppActive = false
        #expect(update(&model, .desktopNotification(
            paneId: paneId,
            title: rejected,
            body: "body"
        )).isEmpty)
        #expect(model.alerts.isEmpty)
        #expect(update(&model, .desktopNotification(
            paneId: paneId,
            title: "title",
            body: rejected
        )).isEmpty)
        #expect(model.alerts.isEmpty)
        #expect(update(&model, .desktopNotification(
            paneId: paneId,
            title: "title",
            body: "body"
        )).count == 1)
        #expect(model.alerts.count == 1)
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

        let commands = update(&model, .desktopNotification(
            paneId: paneId,
            title: "Build complete",
            body: "make finished"
        ))
        #expect(model.alerts.count == 0, "should not create alert for focused pane")
        #expect(commands.count == 0, "should produce no commands for focused pane")
    }

    @Test("agent waiting alerts once only when its pane is not focused")
    func agentWaitingAlertsOnlyForUnfocusedPane() throws {
        var model = makeModel()
        createTab(&model)
        let backgroundPaneId = model.groups[0].tabs[0].focusedPaneId
        createTab(&model)
        let focusedPaneId = selectedTab(in: model)!.focusedPaneId
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let lifecycles = PaneLifecycles(
            agent: .attached(session: agent, activity: .waiting)
        )
        let livePaneState = PaneLifecyclesView(lifecyclesByPaneId: [
            backgroundPaneId: lifecycles,
            focusedPaneId: lifecycles,
        ])
        let backgroundCommands = update(
            &model,
            lifecycleMessage(
                paneId: backgroundPaneId,
                event: .agentActivityChanged(session: agent, activity: .waiting),
                after: [.agentAttached(agent)]
            ),
            livePaneState: livePaneState
        )
        let focusedCommands = update(
            &model,
            lifecycleMessage(
                paneId: focusedPaneId,
                event: .agentActivityChanged(session: agent, activity: .waiting),
                after: [.agentAttached(agent)]
            ),
            livePaneState: livePaneState
        )

        #expect(model.alerts.count == 1)
        #expect(model.alerts.first?.paneId == backgroundPaneId)
        #expect(model.alerts.first?.title == "Claude session-1")
        #expect(model.alerts.first?.body == "Waiting for input")
        #expect(hasEffect(backgroundCommands) {
            if case .sendNotification(_, let paneId, let title, _, let body) = $0 {
                return paneId == backgroundPaneId
                    && title == "Claude session-1"
                    && body == "Waiting for input"
            }
            return false
        })
        #expect(focusedCommands.isEmpty)

        let alertId = try #require(model.alerts.first?.id)
        _ = update(&model, .activateAlert(alertId: alertId))
        #expect(model.selectedTabId == tabForPane(backgroundPaneId, in: model)?.id)
        #expect(tabForPane(backgroundPaneId, in: model)?.focusedPaneId == backgroundPaneId)
    }

    @Test("agent attention rejects unsupported live states")
    func agentAttentionRequiresAttachedWaitingState() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        createTab(&model)
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))

        for transition in [
            lifecycleTransition(event: .integrationReady),
            lifecycleTransition(
                event: .agentActivityChanged(session: agent, activity: .working),
                after: [.agentAttached(agent)]
            ),
            lifecycleTransition(
                event: .agentActivityChanged(session: agent, activity: .idle),
                after: [.agentAttached(agent)]
            ),
        ] {
            #expect(update(
                &model,
                .paneLifecycleChanged(paneId: paneId, event: transition.event),
                livePaneState: PaneLifecyclesView(lifecyclesByPaneId: [paneId: transition.current])
            ).isEmpty)
        }
        #expect(model.alerts.isEmpty)
    }

    @Test("agent waiting stays silent for the focused pane while the app is inactive")
    func agentWaitingRequiresAnUnfocusedPaneEvenWhenInactive() throws {
        var model = makeModel()
        model.isAppActive = false
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        let lifecycles = PaneLifecycles(
            agent: .attached(session: agent, activity: .waiting)
        )
        #expect(update(
            &model,
            lifecycleMessage(
                paneId: paneId,
                event: .agentActivityChanged(session: agent, activity: .waiting),
                after: [.agentAttached(agent)]
            ),
            livePaneState: PaneLifecyclesView(lifecyclesByPaneId: [paneId: lifecycles])
        ).isEmpty)
        #expect(model.alerts.isEmpty)
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

        let commands = update(&model, .desktopNotification(
            paneId: paneId,
            title: "Hello",
            body: "World"
        ))
        #expect(model.alerts.count == 1, "should create one alert")
        #expect(model.alerts[0].kind == .desktopNotification)
        #expect(model.alerts[0].isUnread == true, "alert should be unread")
        #expect(model.alerts[0].paneId == paneId)
        #expect(hasEffect(commands) {
            if case .sendNotification(_, _, let title, _, let body) = $0,
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

        let commands = update(&model, .desktopNotification(
            paneId: firstTabPaneId,
            title: "Hello",
            body: "World"
        ))
        #expect(model.alerts.count == 1, "should create alert")
        #expect(model.alerts[0].isUnread == true, "background pane alert should be unread")
        #expect(hasEffect(commands) {
            if case .sendNotification(_, _, let t, _, let b) = $0,
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

        update(&model, .sessionBell(paneId: firstTabPaneId))
        #expect(model.lastNotificationTime[firstTabPaneId]?[.bell] != nil, "bell should set lastNotificationTime")

        let commands = update(&model, .desktopNotification(
            paneId: firstTabPaneId,
            title: "Done",
            body: "Task finished"
        ))
        #expect(hasEffect(commands) {
            if case .sendNotification(_, _, let t, _, _) = $0, t == "Done" { return true }
            return false
        }, "desktop notification should not be throttled by bell")
        #expect(model.lastNotificationTime[firstTabPaneId]?[.desktopNotification] != nil, "should set lastNotificationTime for desktopNotification")

        let effects2 = update(&model, .desktopNotification(
            paneId: firstTabPaneId,
            title: "Done2",
            body: "Again"
        ))
        #expect(!hasEffect(effects2) {
            if case .sendNotification = $0 { return true }
            return false
        }, "second desktop notification should be throttled")
    }

    // MARK: - Progress

    @Test("testSessionProgressSetStoresState")
    func testSessionProgressSetStoresState() {
        // Intent: sessionProgress(.set) stores the percent on the pane;
        //   emits no commands.
        // Why it exists: pins the no-side-effect progress write.
        // Scenario: spec-first progress set.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .sessionProgress(paneId: paneId, state: .set(percent: 50)))
        #expect(model.pane(paneId)?.progress == .set(percent: 50))
        #expect(commands.count == 0, "no commands from progress update")
    }

    @Test("testSessionProgressNilClearsState")
    func testSessionProgressNilClearsState() {
        // Intent: sessionProgress(.nil) clears the pane's progress.
        // Why it exists: pins the explicit-clear branch.
        // Scenario: spec-first progress clear.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        update(&model, .sessionProgress(paneId: paneId, state: .set(percent: 75)))
        #expect(model.pane(paneId)?.progress == .set(percent: 75))

        update(&model, .sessionProgress(paneId: paneId, state: nil))
        #expect(model.pane(paneId)?.progress == nil, "progress should be cleared")
    }

    @Test("testSessionProgressUnknownPaneIsNoop")
    func testSessionProgressUnknownPaneIsNoop() {
        // Intent: progress for an unknown pane id emits no commands.
        // Why it exists: pins fail-closed on stale pane ids.
        // Scenario: spec-first stale-pane progress.
        var model = makeModel()
        createTab(&model)
        let unknownPaneId = PaneId()

        let commands = update(&model, .sessionProgress(paneId: unknownPaneId, state: .set(percent: 50)))
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

        update(&model, .sessionProgress(paneId: paneId, state: .indeterminate))
        update(&model, .sessionTitle(paneId: paneId, title: "vim"))

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

        update(&model, .sessionProgress(paneId: paneId, state: .error(percent: 80)))
        update(&model, .sessionCwd(paneId: paneId, cwd: "/tmp"))

        #expect(model.pane(paneId)?.progress == .error(percent: 80), "progress should survive cwd update")
        #expect(model.pane(paneId)?.cwd == "/tmp")
    }

    @Test("testSessionClosed")
    func testSessionClosed() {
        // Intent: sessionClosed on the last pane flips pendingConfirmation
        //   to .terminate and leaves the model intact.
        // Why it exists: pins the session-closed -> quit-confirm path.
        // Scenario: spec-first session-closed terminate.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .sessionClosed(paneId: paneId))
        #expect(model.pane(paneId) != nil, "pane should still exist (confirmation pending)")
        #expect(commands.isEmpty, "no command; reconcileQuitConfirmation drives the panel")
        #expect(model.pendingConfirmation == .terminate, "quit confirmation should be pending")
    }
}

private func lifecycleMessage(
    paneId: PaneId,
    event: PaneLifecycleEvent,
    after preceding: [PaneLifecycleEvent] = []
) -> Msg {
    .paneLifecycleChanged(
        paneId: paneId,
        event: lifecycleTransition(event: event, after: preceding).event
    )
}

private func lifecycleTransition(
    event: PaneLifecycleEvent,
    after preceding: [PaneLifecycleEvent] = []
) -> PaneLifecycleTransition {
    var stream = PaneLifecycleStream()
    for event in preceding {
        _ = stream.apply(event)
    }
    return stream.apply(event)
}
