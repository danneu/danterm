// Behavioral coverage for Projections.swift: the pure `desired*` functions that
// compose an AppModel into what the UI renders -- theme browser, alerts popover,
// TODO popovers, switcher and close/quit confirmation overlays, pane emphasis,
// pane toolbar, search overlays, pane config, sidebar, and window chrome --
// plus the `isFocusedAndVisible` predicate they share and the tally overloads
// that let a caller supply an unread count instead of recomputing it.
//
// Not here: the model queries and resolvers defined in ModelOperations.swift
// (ModelOperationsTests.swift), the TabTodo.swift row builder and its
// drop/bucket/reorder resolvers (TabTodoTests.swift), and the same projections
// driven through the `Msg` surface (UpdateXxxTests.swift).
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct ProjectionsTests {
    @Test("sidebar presentation projection is the model-owned state")
    func sidebarPresentationProjectionIsModelOwnedState() {
        var model = makeModel()
        model.sidebar = SidebarPresentation(isCollapsed: true, width: 275)

        #expect(desiredSidebarPresentation(in: model) == model.sidebar)
    }

    // MARK: - isFocusedAndVisible

    @Test("testIsFocusedAndVisible")
    func testIsFocusedAndVisible() {
        // Intent: isFocusedAndVisible returns true only for the focused pane
        //   of the selected split tab (not single-pane, not background).
        // Why it exists: pins the green focus-border rule applied to the
        //   pane (single-pane tabs draw no border; background panes don't
        //   either).
        // Scenario: spec-first focus-border check -- split selected tab has
        //   one true, sibling false; new single-pane tab is also false.
        var model = makeModel()
        createTab(&model)
        let firstPaneId = selectedTab(in: model)!.paneTree.focusedPaneId

        update(&model, .splitFocusedPane(direction: .horizontal))
        let focusedSplitPaneId = selectedTab(in: model)!.paneTree.focusedPaneId

        #expect(isFocusedAndVisible(focusedSplitPaneId, in: model), "focused pane in selected split tab should be visible")
        #expect(!isFocusedAndVisible(firstPaneId, in: model), "non-focused pane should not be focused and visible")

        createTab(&model)
        let singlePaneId = selectedTab(in: model)!.paneTree.focusedPaneId

        #expect(!isFocusedAndVisible(singlePaneId, in: model), "focused pane in single-pane tab should not show a focus border")
        #expect(!isFocusedAndVisible(focusedSplitPaneId, in: model), "pane in non-selected tab should not be focused and visible")
    }

    // MARK: - desiredThemeBrowser

    @Test("desiredThemeBrowser: tracks the focused pane's theme across same-tab focus")
    func desiredThemeBrowserTracksFocusedPaneTheme() {
        // Intent: desiredThemeBrowser.currentThemeName reads the
        //   currently focused pane's theme; same-tab focus changes flip
        //   it.
        // Why it exists: pins the live update the theme browser reads
        //   to reflect the active pane.
        // Scenario: spec-first focus follow -- split tab with two
        //   themed panes; switching focus across panes flips the
        //   projected theme.
        var model = makeModel()
        model.themeBrowserOpen = true
        createTab(&model)
        let paneA = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let focused = selectedTab(in: model)!.paneTree.focusedPaneId
        let other = allPaneIds(selectedTab(in: model)!.paneTree.root).first { $0 != focused }!
        update(&model, .setPaneTheme(paneId: focused, themeName: "Dracula"))
        update(&model, .setPaneTheme(paneId: other, themeName: "Nord"))

        #expect(desiredThemeBrowser(in: model)?.currentThemeName == "Dracula",
            "projection returns the focused pane's theme")

        update(&model, .paneBecameFirstResponder(paneId: other))
        #expect(desiredThemeBrowser(in: model)?.currentThemeName == "Nord",
            "projection updates on same-tab focus change -- the bug this fixes")
    }

    @Test("desiredThemeBrowser: existence follows the model slot")
    func desiredThemeBrowserExistenceFollowsModelSlot() throws {
        // Intent: the optional projection exists exactly while the model says the
        //   theme browser is open.
        // Why it exists: a view-owned existence fact let the browser bypass update
        //   and the ordered reconcile sweep.
        // Scenario: the browser starts closed, then its toggle message opens it.
        var model = makeModel()

        #expect(desiredThemeBrowser(in: model) == nil)

        createTab(&model)
        #expect(update(&model, .toggleThemeBrowser).isEmpty)
        let projection = try #require(desiredThemeBrowser(in: model))
        #expect(projection.currentThemeName == nil)
    }

    @Test("desiredThemeBrowser reports the user theme independent of live lifecycles")
    func desiredThemeBrowserReportsUserTheme() {
        var model = makeModel()
        model.themeBrowserOpen = true
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .setPaneTheme(paneId: paneId, themeName: "Dracula"))

        #expect(desiredThemeBrowser(in: model)?.currentThemeName == "Dracula",
            "projection reads the user's pane theme")
    }

    // MARK: - desiredAlertsPopover

    @Test("alert age text floors across display boundaries")
    func alertAgeTextFloorsAcrossDisplayBoundaries() {
        let now = Date(timeIntervalSince1970: 100_000)

        #expect(relativeAlertAge(createdAt: now.addingTimeInterval(1), now: now) == "now")
        #expect(relativeAlertAge(createdAt: now.addingTimeInterval(-59), now: now) == "now")
        #expect(relativeAlertAge(createdAt: now.addingTimeInterval(-60), now: now) == "1m")
        #expect(relativeAlertAge(createdAt: now.addingTimeInterval(-3_599), now: now) == "59m")
        #expect(relativeAlertAge(createdAt: now.addingTimeInterval(-3_600), now: now) == "1h")
        #expect(relativeAlertAge(createdAt: now.addingTimeInterval(-86_399), now: now) == "23h")
        #expect(relativeAlertAge(createdAt: now.addingTimeInterval(-86_400), now: now) == "1d")
    }

    @Test("desiredAlertsPopover projects age from explicit current time")
    func desiredAlertsPopoverProjectsAgeFromExplicitCurrentTime() throws {
        var model = makeModel()
        model.alertsPopoverOpen = true
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let createdAt = Date(timeIntervalSince1970: 1_000)
        model.alerts = [AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "DanTerm", body: "done", createdAt: createdAt, isUnread: true)]

        let first = desiredAlertsPopover(in: model, now: createdAt.addingTimeInterval(119))
        let second = desiredAlertsPopover(in: model, now: createdAt.addingTimeInterval(120))

        #expect(first?.rows.first?.ageText == "1m")
        #expect(second?.rows.first?.ageText == "2m")
        model.alertsPopoverOpen = false
        #expect(desiredAlertsPopover(in: model, now: createdAt) == nil)
    }

    @Test("desiredAlertsPopover filters unread vs show-all rows")
    func desiredAlertsPopoverFiltersUnreadVsShowAll() {
        // Intent: desiredAlertsPopover.rows reflects the show-all flag
        //   (only unread when false, all alerts when true).
        // Why it exists: pins the tab toggle wiring the alerts popover
        //   panel renders.
        // Scenario: spec-first tab-toggle -- one unread + one read; rows
        //   shrink to {unread} then expand to both.
        var model = makeModel()
        model.alertsPopoverOpen = true
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let unread = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "Unread", body: "bell", createdAt: Date(timeIntervalSince1970: 10), isUnread: true)
        let read = AlertModel(
            id: AlertId(), kind: .desktopNotification, paneId: paneId,
            title: "Read", body: "osc", createdAt: Date(timeIntervalSince1970: 20), isUnread: false)
        model.alerts = [unread, read]

        var proj = desiredAlertsPopover(in: model, now: Date())!
        #expect(proj.rows.map(\.id) == [unread.id], "unread tab shows only unread alerts")
        #expect(proj.showAll == false, "projection carries the show-all flag")

        model.showAllAlerts = true
        proj = desiredAlertsPopover(in: model, now: Date())!
        #expect(proj.rows.map(\.id) == [unread.id, read.id], "show-all tab shows all alerts")
        #expect(proj.showAll == true, "projection carries the show-all flag")
    }

    @Test("desiredAlertsPopover mark-all visibility reads the full alert list")
    func desiredAlertsPopoverMarkAllVisibility() {
        // Intent: markAllVisible is true if any alert is unread,
        //   independent of the show-all flag.
        // Why it exists: pins the "no unread anywhere" condition for
        //   hiding the mark-all button.
        // Scenario: spec-first mark-all -- in show-all mode, mark-all is
        //   visible until the last unread alert is marked read.
        var model = makeModel()
        model.alertsPopoverOpen = true
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let read = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "Read", body: "x", createdAt: Date(timeIntervalSince1970: 10), isUnread: false)
        var unread = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "Unread", body: "x", createdAt: Date(timeIntervalSince1970: 20), isUnread: true)
        model.showAllAlerts = true
        model.alerts = [read, unread]

        var proj = desiredAlertsPopover(in: model, now: Date())!
        #expect(proj.rows.map(\.id) == [read.id, unread.id], "show-all keeps read rows visible")
        #expect(proj.markAllVisible == true, "any unread alert shows the mark-all button")

        unread.isUnread = false
        model.alerts = [read, unread]
        proj = desiredAlertsPopover(in: model, now: Date())!
        #expect(proj.rows.map(\.id) == [read.id, unread.id], "show-all rows remain after all alerts are read")
        #expect(proj.markAllVisible == false, "no unread alerts hides the mark-all button")
    }

    @Test("desiredAlertsPopover empty text follows the selected alert tab")
    func desiredAlertsPopoverEmptyTextFollowsTab() {
        // Intent: emptyText carries "No unread alerts" on the unread tab
        //   and "No alerts" on the show-all tab; non-empty rows -> nil.
        // Why it exists: pins the per-tab empty-state copy the popover
        //   shows.
        // Scenario: spec-first empty-state -- inspect emptyText across
        //   tab toggles and after inserting an alert.
        var model = makeModel()
        model.alertsPopoverOpen = true
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

        var proj = desiredAlertsPopover(in: model, now: Date())!
        #expect(proj.emptyText == "No unread alerts", "empty unread tab uses unread copy")

        model.showAllAlerts = true
        proj = desiredAlertsPopover(in: model, now: Date())!
        #expect(proj.emptyText == "No alerts", "empty history tab uses history copy")

        model.alerts = [AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "DanTerm", body: "x", createdAt: Date(timeIntervalSince1970: 10), isUnread: true)]
        proj = desiredAlertsPopover(in: model, now: Date())!
        #expect(proj.emptyText == nil, "rows present means no empty text")
    }

    @Test("desiredAlertsPopover changes when a background alert is inserted")
    func desiredAlertsPopoverChangesOnBackgroundAlert() {
        // Intent: inserting an alert into model.alerts changes the
        //   projection identity (rows + markAllVisible reflect the new
        //   state).
        // Why it exists: pins the input-equality contract the reconcile
        //   loop reads to decide whether to refresh the popover.
        // Scenario: spec-first insertion-detected -- proj0 != proj1 after
        //   an unread alert is prepended.
        var model = makeModel()
        model.alertsPopoverOpen = true
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

        let proj0 = desiredAlertsPopover(in: model, now: Date())!
        let alert = AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "DanTerm", body: "build", createdAt: Date(timeIntervalSince1970: 10), isUnread: true)
        model.alerts.insert(alert, at: 0)
        let proj1 = desiredAlertsPopover(in: model, now: Date())!

        #expect(proj0 != proj1, "inserted alert changes the projection")
        #expect(proj1.rows.first?.id == alert.id, "new alert is the first rendered row")
        #expect(proj1.markAllVisible == true, "unread background alert shows the mark-all button")
    }

    // MARK: - alert projection tally overloads

    @Test("alert projections read the supplied tally")
    func alertProjectionsReadSuppliedTally() throws {
        // Intent: every tally overload surfaces injected counts instead of
        //   recomputing from model.alerts.
        // Why it exists: this guards the hot-path wiring against a body that
        //   accepts a tally parameter but ignores it.
        // Scenario: empty alerts plus sentinel tally counts; projections
        //   still render those sentinel values.
        var model = makeModel()
        createTab(&model)
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        model.groups[0].tabs[0].customTitle = "Alpha"
        model.mruCycle = MruCycleState(frozenOrder: [tabId], cursorIndex: 0)
        let tally = UnreadAlertTally(
            byPane: [paneId: 7],
            byTab: [tabId: 11],
            byGroup: [model.groups[0].id: 13],
            total: 99
        )

        #expect(desiredPaneEmphasis(in: model, tally: tally)[paneId]?.bell == true)
        #expect(desiredPaneToolbar(in: model, tally: tally)[paneId]?.alertBadge == 7)
        #expect(desiredWindowChrome(in: model, tally: tally).unreadBadge == 99)

        let sidebar = desiredSidebar(in: model, tally: tally)
        #expect(sidebar.groups[0].rendered.alertBadge == nil)
        #expect(sidebar.groups[0].tabs[0].alertBadge == 11)

        let switcher = try #require(desiredSwitcher(in: model, tally: tally))
        #expect(switcher.rows[0].alertCount == 11)
    }

    @Test("badge projections decide whether each count is visible")
    func badgeProjectionsDecideVisibility() throws {
        // Intent: each badge projection carries nil when its badge must be hidden.
        // Why it exists: views must not re-derive badge visibility from counts or collapse state.
        // Scenario: one alerted tab moves from an expanded group to a collapsed group,
        //   then a zero tally hides every alert badge.
        var model = makeModel()
        createTab(&model)
        let groupId = model.groups[0].id
        let tabId = model.groups[0].tabs[0].id
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let nonzero = UnreadAlertTally(
            byPane: [paneId: 7],
            byTab: [tabId: 11],
            byGroup: [groupId: 13],
            total: 99
        )

        let expanded = desiredSidebar(in: model, tally: nonzero)
        #expect(expanded.groups[0].rendered.alertBadge == nil)
        #expect(expanded.groups[0].rendered.tabCountBadge == nil)
        #expect(expanded.groups[0].tabs[0].alertBadge == 11)
        #expect(desiredPaneToolbar(in: model, tally: nonzero)[paneId]?.alertBadge == 7)
        #expect(desiredWindowChrome(in: model, tally: nonzero).unreadBadge == 99)

        model.groups[0].isCollapsed = true
        let collapsed = desiredSidebar(in: model, tally: nonzero)
        #expect(collapsed.groups[0].rendered.alertBadge == 13)
        #expect(collapsed.groups[0].rendered.tabCountBadge == 1)

        let zero = UnreadAlertTally(byPane: [:], byTab: [:], byGroup: [:], total: 0)
        #expect(desiredSidebar(in: model, tally: zero).groups[0].tabs[0].alertBadge == nil)
        #expect(desiredPaneToolbar(in: model, tally: zero)[paneId]?.alertBadge == nil)
        #expect(desiredWindowChrome(in: model, tally: zero).unreadBadge == nil)
    }

    // MARK: - desiredSwitcher

    @Test("desiredSwitcher: non-nil while cycling, nil once the cycle ends")
    func desiredSwitcherNonNilWhileCyclingNilAfter() {
        // Intent: desiredSwitcher returns a populated projection while
        //   cycling and nil otherwise.
        // Why it exists: pins the appearance/disappearance net the
        //   reconciler uses to issue orderFront/orderOut on the panel.
        // Scenario: spec-first cycle lifecycle -- absence pre-cycle, rows
        //   while cycling reflect live order + carried cursor + per-row
        //   name/alertCount, then absence after the cycle ends.
        let (m0, ids) = makeMruModel(tabCount: 3)
        var model = m0
        #expect(model.mruCycle == nil, "precondition: not cycling")
        #expect(desiredSwitcher(in: model) == nil, "no MRU cycle -> nil projection")

        model.groups[0].tabs[0].customTitle = "Alpha"
        let alertPane = model.groups[0].tabs[1].paneTree.focusedPaneId
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: alertPane,
            title: "DanTerm", body: "x", createdAt: Date(), isUnread: true), at: 0)

        model.mruCycle = MruCycleState(frozenOrder: ids, cursorIndex: 1)
        guard let proj = desiredSwitcher(in: model) else {
            Issue.record("expected a non-nil projection while cycling")
            return
        }
        #expect(proj.rows.map(\.tabId) == ids, "rows follow the live (frozen) order")
        #expect(proj.cursorIndex == 1, "cursor index carried from the cycle")
        #expect(proj.rows[0].name == "Alpha", "row name is the tab's displayTitle")
        #expect(proj.rows[1].alertCount == 1, "row alertCount reflects the model's unread alerts")
        #expect(proj.rows[0].alertCount == 0, "a tab with no unread alerts has zero count")

        model.mruCycle = nil
        #expect(desiredSwitcher(in: model) == nil, "cycle ended -> nil projection (orderOut)")
    }

    // MARK: - desiredConfirmation

    @Test("desiredConfirmation projects close and quit transactions")
    func desiredConfirmationProjectsEverySubject() {
        var model = makeModel()
        createTab(&model)

        #expect(desiredConfirmation(in: model) == nil, "no pending confirmation -> nil projection")

        let tabId = model.groups[0].tabs[0].id
        model.pendingConfirmation = pendingCloseConfirmation(
            for: closeTabTarget(tabId, in: model),
            in: model
        )
        #expect(desiredConfirmation(in: model)?.confirm.title == "Close Tab")

        model.pendingConfirmation = pendingAppConfirmation()
        #expect(desiredConfirmation(in: model)?.informativeText == "This will close 1 terminal session.")

        var multi = makeMruModel(tabCount: 3).model
        multi.pendingConfirmation = pendingAppConfirmation()
        #expect(desiredConfirmation(in: multi)?.informativeText == "This will close 3 terminal sessions.")

        multi.pendingConfirmation = nil
        #expect(desiredConfirmation(in: multi) == nil, "cleared confirmation -> nil projection")
    }

    @Test("desiredConfirmation decrements quit copy as panes close while pending")
    func desiredConfirmationDecrementsQuitCopyWithPanes() {
        // Intent: the paneCount field reflects live panes while a quit
        //   confirmation is pending.
        // Why it exists: pins the live-rollup so the user sees the
        //   accurate pane count even after closing some panes.
        // Scenario: spec-first live-update -- start with two panes,
        //   close one non-last pane; the projection reports 1.
        var model = makeModel()
        createTab(&model)
        _ = update(&model, .splitFocusedPane(direction: .horizontal))
        #expect(model.allPaneIds.count == 2, "precondition: split created two panes")
        model.pendingConfirmation = pendingAppConfirmation()
        #expect(desiredConfirmation(in: model)?.informativeText == "This will close 2 terminal sessions.",
            "open quit panel starts with both panes")

        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        _ = update(&model, .closePane(paneId: paneId))

        #expect(model.allPaneIds.count == 1, "non-last pane close removes one pane")
        #expect(testConfirmationKind(model.pendingConfirmation) == .app, "non-last pane close keeps quit confirmation pending")
        #expect(desiredConfirmation(in: model)?.informativeText == "This will close 1 terminal session.",
            "projection reflects the decremented live pane count")
    }

    @Test("a pending quit names every running command app-wide and drops each as its pane closes")
    func desiredConfirmationRollsUpQuitCommands() throws {
        // Intent: the quit confirmation names the commands quitting would end,
        //   across every tab, in pane order, and the list follows the live model
        //   the same way the session count does.
        // Why it exists: quit is the most destructive path and used to name no
        //   command at all. Deriving the list from the live model rather than a
        //   frozen impact is what keeps it honest while the panel is open.
        // Scenario: spec-first -- two tabs, three panes, two of them running;
        //   close one running pane and the projection drops that command only.
        var model = makeModel()
        createTab(&model)
        let firstTabId = try #require(selectedTab(in: model)?.id)
        let firstPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        _ = update(&model, .splitPane(paneId: firstPaneId, direction: .horizontal))
        let firstTabPanes = allPaneIds(try #require(tabById(firstTabId, in: model)).paneTree.root)
        createTab(&model)
        let secondTabPaneId = try #require(selectedTab(in: model)?.paneTree.focusedPaneId)
        model.updatePane(firstTabPanes[0]) { $0.session?.command = .running("make test") }
        model.updatePane(secondTabPaneId) { $0.session?.command = .running("npm run dev") }
        model.pendingConfirmation = pendingAppConfirmation()

        #expect(desiredConfirmation(in: model)?.commands.map(\.text) == ["make test", "npm run dev"],
            "quit names both running commands in pane order and skips the idle pane")

        _ = update(&model, .closePane(paneId: firstTabPanes[0]))

        #expect(desiredConfirmation(in: model)?.commands.map(\.text) == ["npm run dev"],
            "closing a running pane drops its command from the live rollup")
    }

    // MARK: - desiredPaneTodoPopover / desiredTabTodoPopover

    @Test("desiredPaneTodoPopover returns rows, pane id, and completed visibility")
    func desiredPaneTodoPopoverReturnsRowsAndCompleted() {
        // Intent: desiredPaneTodoPopover carries rows from the pane's
        //   todos, the pane id, and hasCompleted=true when any item is
        //   done.
        // Why it exists: pins the per-pane projection the popover panel
        //   reads.
        // Scenario: spec-first projection -- a pane with two todos, one
        //   marked done, hasCompleted is true.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .addTodo(owner: .pane(paneId), text: TodoText("done")!))
        update(&model, .addTodo(owner: .pane(paneId), text: TodoText("pending")!))
        let doneId = model.pane(paneId)!.todos[0].id
        update(&model, .toggleTodoDone(owner: .pane(paneId), todoId: doneId))

        let projection = desiredPaneTodoPopover(paneId: paneId, in: model)

        #expect(projection?.paneId == paneId)
        #expect(projection?.rows == model.pane(paneId)!.todos)
        #expect(projection?.hasCompleted == true)
    }

    @Test("desiredPaneTodoPopover returns nil for a missing pane")
    func desiredPaneTodoPopoverNilForMissingPane() {
        // Intent: missing pane id yields nil projection.
        // Why it exists: pins fail-closed for stale pane ids.
        // Scenario: spec-first stale-pane.
        let model = makeModel()

        let projection = desiredPaneTodoPopover(paneId: PaneId(), in: model)

        #expect(projection == nil)
    }

    @Test("desiredTabTodoPopover includes rows, pane order, and tab-only completed visibility")
    func desiredTabTodoPopoverRowsPaneOrderTabOnlyCompleted() {
        // Intent: desiredTabTodoPopover.rows == buildTabTodoRows; .paneOrder
        //   matches the tab's pane order; tabHasCompleted reflects ONLY tab
        //   todos (pane completion does not flip it).
        // Why it exists: pins the projection contract the tab popover reads
        //   plus the subtle "tab-only completed" semantics.
        // Scenario: spec-first projection -- tab todo + paneA todo, then
        //   complete the pane todo (tabHasCompleted stays false), then
        //   complete the tab todo (tabHasCompleted flips true).
        var (model, tabId, paneA, paneB) = makeTwoPaneTabTodoRowsModel()
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("tab pending")!))
        update(&model, .addTodo(owner: .pane(paneA), text: TodoText("pane done")!))
        let paneDoneId = model.pane(paneA)!.todos[0].id
        update(&model, .toggleTodoDone(owner: .pane(paneA), todoId: paneDoneId))

        var projection = desiredTabTodoPopover(tabId: tabId, in: model)

        #expect(projection?.tabId == tabId)
        #expect(projection?.rows == buildTabTodoRows(model: model, tabId: tabId))
        #expect(projection?.paneOrder == [paneA, paneB])
        #expect(projection?.tabHasCompleted == false, "pane completion should not show tab clear button")

        let tabTodoId = tabById(tabId, in: model)!.todos[0].id
        update(&model, .toggleTodoDone(owner: .tab(tabId), todoId: tabTodoId))
        projection = desiredTabTodoPopover(tabId: tabId, in: model)

        #expect(projection?.tabHasCompleted == true)
    }

    @Test("desiredTabTodoPopover changes for pane todo, tab todo, and pane title changes")
    func desiredTabTodoPopoverChangesOnTodoOrTitleChange() {
        // Intent: the projection identity changes when pane todos, tab
        //   todos, or focused session titles change.
        // Why it exists: pins the input-equality contract the reconcile
        //   loop reads.
        // Scenario: spec-first change-detection -- three mutations in
        //   sequence each flip the projection.
        var (model, tabId, paneA, _) = makeTwoPaneTabTodoRowsModel()
        var previous = desiredTabTodoPopover(tabId: tabId, in: model)

        update(&model, .addTodo(owner: .pane(paneA), text: TodoText("pane task")!))
        var next = desiredTabTodoPopover(tabId: tabId, in: model)
        #expect(previous != next, "pane todo changes should update the projection")

        previous = next
        update(&model, .addTodo(owner: .tab(tabId), text: TodoText("tab task")!))
        next = desiredTabTodoPopover(tabId: tabId, in: model)
        #expect(previous != next, "tab todo changes should update the projection")

        previous = next
        model.updatePane(paneA) { $0.session?.titleState = .declared("renamed pane") }
        next = desiredTabTodoPopover(tabId: tabId, in: model)
        #expect(previous != next, "pane title changes should update the projection")
    }

    // MARK: - desiredPaneEmphasis

    @Test("desiredPaneEmphasis: single-pane selected tab draws no focus border (bell still shows)")
    func desiredPaneEmphasisSinglePaneNoBorderBellOk() {
        // Intent: a single-pane selected tab reports focused=false; an
        //   unread alert still flips bell=true.
        // Why it exists: pins the single-pane suppression rule against
        //   the bell-border independence.
        // Scenario: spec-first dual-check -- no border initially; bell
        //   true after inserting an unread alert.
        var model = makeModel()
        createTab(&model)
        let pane = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(
            desiredPaneEmphasis(in: model)[pane] ==
            PaneEmphasis(focused: false, bell: false, scrimAlpha: 0),
            "single-pane focused tab draws no border")
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: pane,
            title: "DanTerm", body: "x", createdAt: Date(), isUnread: true), at: 0)
        #expect(
            desiredPaneEmphasis(in: model)[pane] ==
            PaneEmphasis(focused: false, bell: true, scrimAlpha: 0),
            "single-pane tab still shows the bell border")
    }

    @Test("desiredPaneEmphasis: split tab marks the focused pane, bell follows unread alert")
    func desiredPaneEmphasisSplitTabFocusBellPerPane() {
        // Intent: in a split tab, the focused pane has focused=true and
        //   bell=false; an unread alert on the sibling flips its
        //   bell=true (without touching the focused pane).
        // Why it exists: pins the per-pane border decomposition in a
        //   multi-pane tab.
        // Scenario: spec-first split-tab check -- two panes, alert lands
        //   on the unfocused one; focused stays unaffected.
        var model = makeModel()
        createTab(&model)
        let paneA = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let focusedId = selectedTab(in: model)!.paneTree.focusedPaneId
        let otherId = allPaneIds(selectedTab(in: model)!.paneTree.root).first { $0 != focusedId }!

        var borders = desiredPaneEmphasis(in: model)
        #expect(borders[focusedId] == PaneEmphasis(focused: true, bell: false, scrimAlpha: 0),
            "focused pane in a split tab draws the focus border")
        #expect(borders[otherId] == PaneEmphasis(focused: false, bell: false, scrimAlpha: 0),
            "unfocused sibling draws no border")

        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: otherId,
            title: "DanTerm", body: "x", createdAt: Date(), isUnread: true), at: 0)
        borders = desiredPaneEmphasis(in: model)
        #expect(borders[otherId] == PaneEmphasis(focused: false, bell: true, scrimAlpha: 0),
            "unfocused pane with an unread alert shows the bell border")
        #expect(borders[focusedId] == PaneEmphasis(focused: true, bell: false, scrimAlpha: 0),
            "focused pane is unaffected by a sibling's alert")
    }

    @Test("desiredPaneEmphasis: keyed over all live panes; non-selected tabs draw no border")
    func desiredPaneEmphasisKeyedOverAllLivePanes() {
        // Intent: borders dict is keyed over every live pane; panes in
        //   non-selected tabs all report focused=false, bell=false.
        // Why it exists: pins the coverage invariant the diff reads to
        //   know which keys to remove.
        // Scenario: spec-first coverage -- two tabs (selected split,
        //   background single); background panes report no border.
        var model = makeModel()
        createTab(&model)
        let tab0Pane = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: tab0Pane, direction: .horizontal))
        createTab(&model)

        let borders = desiredPaneEmphasis(in: model)
        #expect(Set(borders.keys) == Set(model.allPaneIds),
            "projection is keyed over every live pane")
        for paneId in allPaneIds(model.groups[0].tabs[0].paneTree.root) {
            #expect(borders[paneId] == PaneEmphasis(focused: false, bell: false, scrimAlpha: 0),
                "panes in a non-selected tab draw no border")
        }
    }

    @Test("desiredPaneEmphasis: only the tab's focused pane escapes the scrim, at the complement")
    func desiredPaneEmphasisScrimsEverySiblingByTheComplement() {
        // Intent: in a split tab the focused pane carries no scrim and its
        //   sibling carries 1 minus the configured opacity.
        // Why it exists: the setting is an opacity and the layer takes an alpha,
        //   so a projection that forwarded the setting itself would dim by the
        //   wrong amount. 0.7 and 0.3 differ, which 0.5 would hide.
        var model = makeModel()
        model.config.unfocusedPaneOpacity = 0.7
        createTab(&model)
        let paneA = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let focusedId = selectedTab(in: model)!.paneTree.focusedPaneId
        let otherId = allPaneIds(selectedTab(in: model)!.paneTree.root).first { $0 != focusedId }!

        let emphasis = desiredPaneEmphasis(in: model)

        #expect(emphasis[focusedId]?.scrimAlpha == 0, "the focused pane is never dimmed")
        #expect(emphasis[otherId]?.scrimAlpha == 1 - 0.7)
    }

    @Test("desiredPaneEmphasis: a lone pane is never scrimmed, and a hidden tab is already right")
    func desiredPaneEmphasisScrimIsTabLocal() {
        // Intent: a single-pane tab's only pane carries no scrim, and the focused
        //   pane of a tab that is not selected carries none either.
        // Why it exists: the scrim is derived from each pane's own tab, not from
        //   visibility. Deriving it from the selected tab would dim a background
        //   tab whole, then correct it the moment that tab was revealed.
        var model = makeModel()
        model.config.unfocusedPaneOpacity = 0.7
        createTab(&model)
        let backgroundTabPane = selectedTab(in: model)!.paneTree.focusedPaneId
        createTab(&model)
        let lonePane = selectedTab(in: model)!.paneTree.focusedPaneId

        let emphasis = desiredPaneEmphasis(in: model)

        #expect(emphasis[lonePane]?.scrimAlpha == 0, "a tab's only pane is its focused pane")
        #expect(emphasis[backgroundTabPane]?.scrimAlpha == 0,
            "a hidden tab's focused pane is already undimmed before it is revealed")
    }

    @Test("desiredPaneEmphasis: a reloaded config moves a live pane's scrim")
    func desiredPaneEmphasisFollowsConfigLoaded() {
        // Intent: a `.configLoaded` carrying a new level changes the projected
        //   value for an already mounted pane.
        // Why it exists: the reconciler only re-pushes what the projection
        //   changes, so a level that did not reach the projection would leave
        //   mounted panes at the old dim until a restart.
        var model = makeModel()
        createTab(&model)
        let paneA = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: paneA, direction: .horizontal))
        let focusedId = selectedTab(in: model)!.paneTree.focusedPaneId
        let otherId = allPaneIds(selectedTab(in: model)!.paneTree.root).first { $0 != focusedId }!
        #expect(desiredPaneEmphasis(in: model)[otherId]?.scrimAlpha == 0, "ships undimmed")

        var config = DanTermConfig.default
        config.unfocusedPaneOpacity = 0.6
        update(&model, .configLoaded(config, resolvedFontFamily: nil))

        #expect(desiredPaneEmphasis(in: model)[otherId]?.scrimAlpha == 1 - 0.6)
    }

    // MARK: - desiredPaneToolbar
    //
    // The composed toolbar strings used to be assembled by
    // `PaneWrapperView.updateToolbar` out of raw model values, which put
    // untrusted terminal-reported text -- a title, a cwd, a remote user and
    // host -- together inside a view. Composing them is the projection's job,
    // so they are asserted here rather than through a window.

    @Test("desiredPaneToolbar derives structural fields and counts from the model")
    func desiredPaneToolbarDerivesStructuralFields() {
        // Why it exists: pins the toolbar render contract so a UI refactor
        //   cannot silently drop a field.
        // Scenario: spec-first full-field check -- a populated pane with
        //   two unread + one read alert renders the documented
        //   PaneToolbarRender.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        model.updatePane(paneId) {
            $0.session?.titleState = .declared("vim")
            $0.session?.cwd = "/work/proj"
            $0.session?.progress = .set(percent: 42)
            $0.todos = [
                TodoItem(id: UUID(), text: TodoText("a")!, isDone: false),
                TodoItem(id: UUID(), text: TodoText("b")!, isDone: true),
                TodoItem(id: UUID(), text: TodoText("c")!, isDone: false),
            ]
        }
        for unread in [true, true, false] {
            model.alerts.insert(AlertModel(
                id: AlertId(), kind: .bell, paneId: paneId,
                title: "DanTerm", body: "x", createdAt: Date(), isUnread: unread), at: 0)
        }
        #expect(
            desiredPaneToolbar(in: model)[paneId] ==
            PaneToolbarRender(
                label: "vim \u{2013} /work/proj",
                progress: .set(percent: 42),
                isRemote: false,
                remoteLabel: nil,
                agentLabel: nil,
                chipTooltip: nil,
                chipKind: .terminal,
                alertBadge: 2,
                totalTodoCount: 3,
                uncompletedTodoCount: 2,
                isZoomed: false,
                hasSplits: false,
                canDrag: false,
                isGridClaimed: false),
            "all toolbar fields derive from the pane + model.alerts")
    }

    @Test("desiredPaneToolbar projects pane drag eligibility")
    func desiredPaneToolbarProjectsPaneDragEligibility() throws {
        // Intent: a pane can start a drag exactly when another pane or tab can
        //   receive it.
        // Why it exists: the drag handle used to derive this rule from the
        //   selected tab instead of receiving the pane owner's projection.
        // Scenario: a lone pane gains a second tab, while a separate lone tab
        //   gains a sibling pane.
        var tabsModel = makeModel()
        createTab(&tabsModel)
        let firstPaneId = try #require(selectedTab(in: tabsModel)?.paneTree.focusedPaneId)
        #expect(desiredPaneToolbar(in: tabsModel)[firstPaneId]?.canDrag == false)

        createTab(&tabsModel)
        #expect(desiredPaneToolbar(in: tabsModel)[firstPaneId]?.canDrag == true)

        var splitModel = makeModel()
        createTab(&splitModel)
        let splitPaneId = try #require(selectedTab(in: splitModel)?.paneTree.focusedPaneId)
        update(&splitModel, .splitPane(paneId: splitPaneId, direction: .horizontal))
        #expect(desiredPaneToolbar(in: splitModel)[splitPaneId]?.canDrag == true)
    }

    @Test("desiredPaneToolbar tracks split and zoom affordances on a persistent wrapper")
    func desiredPaneToolbarTracksSplitAndZoomAffordances() {
        // Intent: the same pane's toolbar projection follows first split, zoom,
        //   unzoom, and closing the last sibling.
        // Why it exists: those values were frozen in wrapper construction before
        //   wrappers became session-lifetime hosts.
        // Scenario: the incremental-container reconciliation performance fix.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(desiredPaneToolbar(in: model)[paneId]?.hasSplits == false)

        update(&model, .splitPane(paneId: paneId, direction: .horizontal))
        let siblingId = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(desiredPaneToolbar(in: model)[paneId]?.hasSplits == true)
        update(&model, .paneBecameFirstResponder(paneId: paneId))

        update(&model, .toggleZoomPane(paneId: paneId))
        #expect(desiredPaneToolbar(in: model)[paneId]?.isZoomed == true)

        update(&model, .toggleZoomPane(paneId: paneId))
        #expect(desiredPaneToolbar(in: model)[paneId]?.isZoomed == false)

        update(&model, .closePane(paneId: siblingId))
        #expect(desiredPaneToolbar(in: model)[paneId]?.hasSplits == false)
    }

    @Test("desiredPaneToolbar reports a claimed grid for as long as the override is there")
    func desiredPaneToolbarTracksGridClaim() {
        // Intent: the take-back affordance follows the presence of the pane's grid
        //   override and nothing else -- including an override whose grid is the
        //   one the pane would have run at anyway.
        // Why it exists: a durable claim needs a one-gesture exit at the Mac. If
        //   the affordance were keyed off a comparison instead of presence, a
        //   claim that happened to match the pane's own size would leave the user
        //   with a pane that cannot be taken back.
        // Scenario: spec-first -- the phone claims a pane, claims it again at the
        //   size the pane already ran at, and the user takes it back.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(desiredPaneToolbar(in: model)[paneId]?.isGridClaimed == false)

        update(&model, .setPaneGridOverride(
            paneId: paneId, grid: PaneGridOverride(columns: 60, rows: 20)!))
        #expect(desiredPaneToolbar(in: model)[paneId]?.isGridClaimed == true)

        update(&model, .setPaneGridOverride(
            paneId: paneId, grid: PaneGridOverride(columns: 80, rows: 24)!))
        #expect(desiredPaneToolbar(in: model)[paneId]?.isGridClaimed == true,
                "a claim equal to the pane's own size is still a claim")

        update(&model, .clearPaneGridOverride(paneId: paneId))
        #expect(desiredPaneToolbar(in: model)[paneId]?.isGridClaimed == false)
    }

    @Test("desiredPaneToolbar reads running command state from immutable pane snapshots")
    func desiredPaneToolbarReadsCommandLifecycle() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let sessionId = model.pane(paneId)!.session!.id
        update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted("swift test")))

        let render = desiredPaneToolbar(in: model)[paneId]

        #expect(render?.label == "swift test")
    }

    @Test("desiredPaneToolbar reads every lifecycle chip from immutable pane snapshots")
    func desiredPaneToolbarReadsEveryLifecycleChip() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        let remote = RemoteSession(user: "dan", host: "caja")
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted("swift test")))
        update(&model, .sessionReport(
            sessionId: sessionId,
            report: .connectionDeclared(.remote(identity: remote))
        ))
        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(agent)))

        let populated = desiredPaneToolbar(in: model)[paneId]
        model.updatePane(paneId) { $0.session = nil }
        let absent = desiredPaneToolbar(in: model)[paneId]

        #expect(populated?.label == "swift test")
        #expect(populated?.isRemote == true)
        #expect(populated?.remoteLabel == DisplayLine(remote.displayString))
        #expect(populated?.chipTooltip == "claude session session-1")
        #expect(absent?.label == "Terminal")
        #expect(absent?.isRemote == false)
        #expect(absent?.remoteLabel == nil)
        #expect(absent?.chipTooltip == nil)

        model.updatePane(paneId) {
            $0.session = SessionModel(id: SessionId(), connection: .remote(identity: nil))
        }
        let unidentifiedRemote = desiredPaneToolbar(in: model)[paneId]
        #expect(unidentifiedRemote?.isRemote == true)
        #expect(unidentifiedRemote?.remoteLabel == nil)
    }

    @Test("desiredPaneToolbar: keyed over every live pane")
    func desiredPaneToolbarKeyedOverEveryLivePane() {
        // Intent: the projection is keyed over allPaneIds.
        // Why it exists: pins the coverage invariant the diff relies on
        //   so toolbars for background panes stay around for selection
        //   switches.
        // Scenario: spec-first coverage.
        var model = makeModel()
        createTab(&model)
        let tab0Pane = selectedTab(in: model)!.paneTree.focusedPaneId
        update(&model, .splitPane(paneId: tab0Pane, direction: .horizontal))
        createTab(&model)
        #expect(Set(desiredPaneToolbar(in: model).keys) == Set(model.allPaneIds),
            "toolbar projection covers all live panes (host destroyed elsewhere -> default no-op remove)")
    }

    @Test("the label is the title and cwd while no command runs")
    func labelIsTitleAndCwdWhenIdle() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        update(&model, .sessionReport(sessionId: sessionId, report: .title("vim")))
        update(&model, .sessionReport(sessionId: sessionId, report: .cwd("/tmp")))

        #expect(desiredPaneToolbar(in: model)[paneId]?.label == "vim \u{2013} /tmp")
    }

    @Test("a running command takes over the label")
    func runningCommandTakesOverTheLabel() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        update(&model, .sessionReport(sessionId: sessionId, report: .title("vim")))
        update(&model, .sessionReport(sessionId: sessionId, report: .cwd("/tmp")))
        update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted("swift test")))

        #expect(desiredPaneToolbar(in: model)[paneId]?.label == "swift test")
    }

    @Test("a remote identity composes the pill's user@host")
    func remoteIdentityComposesThePill() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        update(&model, .sessionReport(sessionId: sessionId, report: .connectionDeclared(
            .remote(identity: RemoteSession(user: "dan", host: "caja")))))

        let render = try #require(desiredPaneToolbar(in: model)[paneId])
        #expect(render.remoteLabel == "dan@caja")
        #expect(render.isRemote)
    }

    // The pill's visibility follows its composed value being nil, so a remote
    // connection with no identity yet still shows the bare remote marker.
    @Test("a remote connection with no identity composes no pill text")
    func remoteWithoutIdentityHasNoPillText() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        update(&model, .sessionReport(sessionId: sessionId, report: .connectionDeclared(
            .remote(identity: nil))))

        let render = try #require(desiredPaneToolbar(in: model)[paneId])
        #expect(render.remoteLabel == nil)
        #expect(render.isRemote)
    }

    @Test("a local pane composes no remote pill")
    func localPaneHasNoRemotePill() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId

        let render = try #require(desiredPaneToolbar(in: model)[paneId])
        #expect(render.remoteLabel == nil)
        #expect(render.isRemote == false)
    }

    // Why it exists: the tooltip is the only place the full session id is
    // reachable once the agent pill is hidden for a kind the chip can name.
    @Test("the chip tooltip names the agent kind and its full session id")
    func chipTooltipNamesTheAgent() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        let claude = try #require(AgentSession(kind: "claude", sessionId: "abc123"))

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(claude)))

        let render = try #require(desiredPaneToolbar(in: model)[paneId])
        #expect(render.chipTooltip == "claude session abc123")
        #expect(render.chipKind == .claude)
    }

    @Test("an agent the chip names is not also spelled out in the pill")
    func namedAgentHasNoPillText() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        let claude = try #require(AgentSession(kind: "claude", sessionId: "abc123"))

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(claude)))

        #expect(desiredPaneToolbar(in: model)[paneId]?.agentLabel == nil)
    }

    @Test("an agent with no chip of its own is named in the pill")
    func unknownAgentIsNamedInThePill() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        let aider = try #require(AgentSession(kind: "aider", sessionId: "abc123"))

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(aider)))

        let render = try #require(desiredPaneToolbar(in: model)[paneId])
        #expect(render.agentLabel == "aider")
        #expect(render.chipKind == .agent)
    }

    @Test("detaching an agent clears both the tooltip and the pill")
    func detachingClearsAgentText() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        let aider = try #require(AgentSession(kind: "aider", sessionId: "abc123"))

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(aider)))
        update(&model, .sessionReport(sessionId: sessionId, report: .agentDetached(aider)))

        let render = try #require(desiredPaneToolbar(in: model)[paneId])
        #expect(render.chipTooltip == nil)
        #expect(render.agentLabel == nil)
    }

    // MARK: - desiredSearchOverlays

    @Test("desiredSearchOverlays: keyed only while search is active; drops the key on endSearch")
    func desiredSearchOverlaysKeyedWhileActiveDropsOnEnd() {
        // Intent: the overlay dict keys a pane only while its live search
        //   exists; endSearch drops the key.
        // Why it exists: pins the appearance/disappearance contract the
        //   reconciler uses to show/hide the overlay.
        // Scenario: spec-first lifecycle -- no key pre-search, full
        //   render mid-search, no key post-search.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        #expect(desiredSearchOverlays(in: model)[paneId] == nil,
            "no active search -> no key")

        update(&model, .startSearch)
        update(&model, .searchNeedleChanged(paneId: paneId, needle: "foo"))
        model.updatePane(paneId) {
            $0.live.search?.status = .matched(selected: 2, total: 7)
        }
        #expect(
            desiredSearchOverlays(in: model)[paneId] ==
            SearchOverlayRender(needle: "foo", status: .matched(selected: 2, total: 7)),
            "active search keys the pane with needle + match counts")

        update(&model, .endSearch(paneId: paneId))
        #expect(desiredSearchOverlays(in: model)[paneId] == nil,
            "ended search drops the pane's key (disappear-but-host-survives)")
    }

    // MARK: - desiredPaneConfig

    @Test("desiredPaneConfig returns to the configured default after clearing an override")
    func desiredPaneConfigReturnsToDefaultOnClear() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId

        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Monokai Remastered")

        update(&model, .setPaneTheme(paneId: paneId, themeName: "Dracula"))
        #expect(
            desiredPaneConfig(in: model)[paneId] ==
            PaneConfigKey(theme: "Dracula"),
            "set theme keys the pane")

        update(&model, .setPaneTheme(paneId: paneId, themeName: nil))
        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Monokai Remastered")
    }

    @Test("desiredPaneConfig uses remote config for a remote lifecycle snapshot")
    func desiredPaneConfigUsesRemoteLifecycleSnapshot() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        model.updatePane(paneId) { $0.theme = "Dracula" }
        let sessionId = model.pane(paneId)!.session!.id
        update(&model, .sessionReport(
            sessionId: sessionId,
            report: .connectionDeclared(.remote(identity: nil))
        ))

        #expect(
            desiredPaneConfig(in: model)[paneId] ==
            PaneConfigKey(theme: "Purplepeter"),
            "remote connection uses the configured remote theme")
    }

    // MARK: - desiredSidebar

    @Test("desiredSidebar: a single-pane tab shows its pane instead of its working directory")
    func desiredSidebarSinglePaneShowsPaneInsteadOfWorkingDirectory() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let agent = try #require(AgentSession(kind: "codex", sessionId: "sidebar-single"))
        model.updatePane(paneId) { pane in
            pane.session?.cwd = "\(NSHomeDirectory())/src"
            pane.session?.agent = .attached(
                session: agent,
                activity: .working)
        }
        model.alerts = [AlertModel(
            id: AlertId(), kind: .bell, paneId: paneId,
            title: "DanTerm", body: "x", createdAt: Date(), isUnread: true)]

        let tab = try #require(desiredSidebar(in: model).groups.first?.tabs.first)

        let chip = try #require(tab.paneChips.first)
        #expect(tab.paneChips.count == 1)
        #expect(chip.paneId == paneId)
        #expect(chip.isFocused)
        #expect(chip.kind == .codex)
        #expect(chip.hasAlert)
        #expect(chip.agent == .working)
    }

    @Test("desiredSidebar: a cwd update reloads a tab row only while its pane has declared no title")
    func desiredSidebarReloadsOnlyTheRowsTheCwdNames() throws {
        // Intent: the cwd reaches the sidebar row exactly when it is the row's
        //   title, and stops reaching it once a program has declared one.
        // Why it exists: the cwd became a display fallback rather than a stored
        //   title, so which updates repaint a row changed with it.
        // Scenario: a shell reports a cwd, then a program declares a title and
        //   the shell reports a second cwd.
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).paneTree.focusedPaneId
        let before = desiredSidebar(in: model)

        model.updatePane(paneId) { pane in
            pane.session?.cwd = "\(NSHomeDirectory())/src"
        }
        let afterCwd = desiredSidebar(in: model)

        #expect(afterCwd.groups[0].tabs[0].displayTitle.text == "~/src")
        #expect(computeSidebarRowOps(old: before, new: afterCwd) == [
            .reloadTab(id: try #require(model.selectedTabId)),
        ])

        model.updatePane(paneId) { $0.session?.titleState = .declared("vim") }
        let declared = desiredSidebar(in: model)
        model.updatePane(paneId) { $0.session?.cwd = "\(NSHomeDirectory())/other" }
        let afterSecondCwd = desiredSidebar(in: model)

        #expect(afterSecondCwd == declared)
        #expect(computeSidebarRowOps(old: declared, new: afterSecondCwd).isEmpty)
    }

    @Test("desiredSidebar: ordered groups -> tabs with rendered attrs, collapse, jump badge")
    func desiredSidebarOrderedGroupsTabsAttrsCollapseJump() {
        // Intent: the sidebar projection lists groups in model order, each
        //   with collapse + isFirst + projected badges, and tabs
        //   with displayTitle/color/alertBadge + optional
        //   jumpKey from jumpMode.keyMap.
        // Why it exists: pins the sidebar render contract end to end across
        //   every projected field.
        // Scenario: spec-first full-projection -- two groups (Work collapsed
        //   with two tabs incl. customTitle/color/alert, Home with one
        //   tab); tab B has a jump key.
        let g1 = GroupId(); let g2 = GroupId()
        let tA = TabId(); let tB = TabId(); let tC = TabId()
        let pA = PaneId(); let pB = PaneId(); let pC = PaneId()
        var paneA = PaneModel(id: pA)
        paneA.session = SessionModel(
            id: SessionId(),
            titleState: .declared("shell"),
            cwd: "\(NSHomeDirectory())/src"
        )
        var tabA = TabModel(id: tA, paneTree: PaneTree(root: .leaf(paneA), focusedPaneId: pA))
        tabA.customTitle = "Edited"; tabA.color = .blue
        let tabB = TabModel(id: tB, paneTree: PaneTree(root: .leaf(PaneModel(id: pB)), focusedPaneId: pB))
        let tabC = TabModel(id: tC, paneTree: PaneTree(root: .leaf(PaneModel(id: pC)), focusedPaneId: pC))
        var model = AppModel(groups: [
            GroupModel(id: g1, name: "Work", isCollapsed: true, tabs: [tabA, tabB]),
            GroupModel(id: g2, name: "Home", tabs: [tabC]),
        ], selectedTabId: tA)
        model.alerts = [AlertModel(id: AlertId(), kind: .bell, paneId: pA,
            title: "t", body: "b", createdAt: Date(), isUnread: true)]
        model.jumpMode = JumpModeState(keyMap: [tB: "j"])

        let proj = desiredSidebar(in: model)
        #expect(!proj.isSingleGroupMode, "two groups -> not single-group mode")
        #expect(proj.groups.map(\.id) == [g1, g2], "groups in model order")

        let work = proj.groups[0]
        #expect(work.rendered.name == "Work")
        #expect(work.rendered.isCollapsed, "collapse projected from the model")
        #expect(work.rendered.isFirst, "first group flagged")
        #expect(work.rendered.tabCountBadge == 2)
        #expect(work.rendered.alertBadge == 1, "collapsed group bell rolls up its tabs' unread alerts")
        #expect(work.tabs.map(\.id) == [tA, tB], "tabs in group order")
        #expect(work.tabs[0].displayTitle == "Edited")
        #expect(work.tabs[0].color == .blue)
        #expect(work.tabs[0].alertBadge == 1)
        #expect(work.tabs[0].jumpKey == nil, "tab A has no jump key")
        #expect(work.tabs[1].jumpKey == "j", "jump badge from model.jumpMode.keyMap")
        #expect(!proj.groups[1].rendered.isFirst, "second group not first")
    }

    @Test("desiredSidebar: interaction facts follow the model")
    func desiredSidebarCarriesInteractionFacts() {
        // Intent: the applied sidebar projection carries selection, drop,
        //   deletion, context-menu, and requested-rename facts.
        // Why it exists: sidebar handlers must describe the rows they display
        //   without reading AppModel through the runtime.
        // Scenario: spec-first interaction projection -- one custom-titled,
        //   colored tab in a single group with a pending group rename.
        let (model, ids) = makeMruModel(tabCount: 3)
        var projectedModel = model
        projectedModel.groups[0].tabs[0].customTitle = "Pinned"
        projectedModel.groups[0].tabs[0].color = .green
        projectedModel.selectedTabId = ids[2]
        _ = update(&projectedModel, .beginSidebarRename(target: .group(projectedModel.groups[0].id)))

        let projection = desiredSidebar(in: projectedModel)

        #expect(projection.selectedTabId == ids[2])
        #expect(projection.singleGroupDropTargetId == projectedModel.groups[0].id)
        #expect(!projection.canDeleteGroups)
        #expect(projection.rename == projectedModel.sidebarRename)
        #expect(projection.groups[0].tabs[0].hasCustomTitle)
        #expect(projection.groups[0].tabs[0].color == .green)
    }

    @Test("desiredSidebar: multiple groups enable deletion and have no root drop target")
    func desiredSidebarMultipleGroupInteractionFacts() {
        var model = makeModel()
        createTab(&model)
        update(&model, .createGroup(name: "Work"))

        let projection = desiredSidebar(in: model)

        #expect(projection.singleGroupDropTargetId == nil)
        #expect(projection.canDeleteGroups)
    }

    @Test("desiredSidebar: one group is single-group mode")
    func desiredSidebarOneGroupIsSingleGroupMode() {
        // Intent: a one-group sidebar is single-group mode (tabs roll up
        //   without a group header).
        // Why it exists: pins the mode flag the sidebar layout reads.
        // Scenario: spec-first single-group.
        let (model, _) = makeMruModel(tabCount: 2)
        #expect(desiredSidebar(in: model).isSingleGroupMode,
            "a single group promotes tabs to roots (no group row)")
    }

    // MARK: - desiredWindowChrome

    @Test("desiredWindowChrome: window/content titles, unread count, and tab-todo rollup from the selected tab")
    func desiredWindowChromeAllFields() {
        // Intent: desiredWindowChrome derives windowTitle ("Custom — sub"),
        //   contentTitle ("Custom"), unreadBadge (only unread alerts), and
        //   tabTodoTotal/uncompleted (tab + pane todos in the selected tab).
        // Why it exists: pins the full window-chrome render contract,
        //   including the subtitle-join and todo rollup.
        // Scenario: spec-first projection -- custom-title tab with a cwd
        //   subtitle, mixed tab + pane todos, two unread + one read alert.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.paneTree.focusedPaneId
        model.groups[0].tabs[0].customTitle = "Custom"
        model.updatePane(paneId) { $0.session?.cwd = "\(NSHomeDirectory())/src" }
        model.groups[0].tabs[0].todos = [TodoItem(id: UUID(), text: TodoText("t1")!, isDone: false)]
        model.updatePane(paneId) {
            $0.todos = [
                TodoItem(id: UUID(), text: TodoText("p1")!, isDone: true),
                TodoItem(id: UUID(), text: TodoText("p2")!, isDone: false),
            ]
        }
        for unread in [true, true, false] {
            model.alerts.insert(AlertModel(
                id: AlertId(), kind: .bell, paneId: paneId,
                title: "DanTerm", body: "x", createdAt: Date(), isUnread: unread), at: 0)
        }
        #expect(
            desiredWindowChrome(in: model) ==
            WindowChromeProjection(
                windowTitle: "Custom — ~/src",
                contentTitle: "Custom",
                unreadBadge: 2,
                tabTodoTotal: 3,
                tabTodoUncompleted: 2),
            "window chrome derives both titles, the unread badge count, and the tab-todo rollup")
    }

    @Test("desiredWindowChrome: no selected tab -> empty titles, zero badge, zero rollup")
    func desiredWindowChromeNoSelectedTab() {
        // Intent: with no selected tab, windowTitle and contentTitle are
        //   empty and all counts are zero.
        // Why it exists: pins the empty-state branch.
        // Scenario: spec-first empty model.
        let model = makeModel()
        #expect(selectedTab(in: model) == nil, "precondition: no selected tab")
        #expect(
            desiredWindowChrome(in: model) ==
            WindowChromeProjection(
                windowTitle: "", contentTitle: "",
                unreadBadge: nil, tabTodoTotal: 0, tabTodoUncompleted: 0),
            "no selected tab -> empty titles, zero badge, (0,0) rollup")
    }

    @Test("desiredWindowChrome: window title omits the subtitle when absent or equal to the display title")
    func desiredWindowChromeOmitsSubtitleWhenAbsentOrEqual() {
        // Intent: when no subtitle exists, or it equals the display title,
        //   windowTitle is just the display title.
        // Why it exists: pins the subtitle-suppression rule that keeps
        //   redundancy out of the window title.
        // Scenario: spec-first dual-check -- no subtitle case, then
        //   subtitle equal to display title.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        model.updatePane(paneId) { $0.session?.titleState = .declared("vim") }
        var proj = desiredWindowChrome(in: model)
        #expect(proj.windowTitle == "vim", "no subtitle -> window title is the bare display title")
        #expect(proj.contentTitle == "vim")
        model.groups[0].tabs[0].customTitle = "~/src"
        model.updatePane(paneId) { $0.session?.cwd = "\(NSHomeDirectory())/src" }
        proj = desiredWindowChrome(in: model)
        #expect(proj.windowTitle == "~/src", "subtitle == display title is suppressed")
    }

    @Test("desiredWindowChrome: reflects the selected tab, not background tabs")
    func desiredWindowChromeReflectsSelectedTab() {
        // Intent: changing selectedTabId flips the projection's
        //   contentTitle to the new tab's display title.
        // Why it exists: pins the selection-drives-projection rule the
        //   reconciler relies on (replacing the deleted .setWindowTitle
        //   selection-change emission).
        // Scenario: spec-first selection-drive -- two tabs A/B with
        //   distinct customTitles; selecting A flips contentTitle to
        //   Alpha, then B flips it to Beta.
        var model = makeModel()
        createTab(&model)
        let tabAId = model.groups[0].tabs[0].id
        model.groups[0].tabs[0].customTitle = "Alpha"
        createTab(&model)
        model.groups[0].tabs[1].customTitle = "Beta"

        #expect(desiredWindowChrome(in: model).contentTitle == "Beta",
            "chrome reflects the selected tab B")
        model.selectedTabId = tabAId
        #expect(desiredWindowChrome(in: model).contentTitle == "Alpha",
            "selecting tab A makes the chrome reflect A")
    }
}
