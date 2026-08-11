// Swift Testing migration of the legacy `tests/UpdateSearchTests.swift`
// harness suite. Pins the search-domain Msg paths: startSearch /
// searchStarted (focus-field + searchState creation), needle changes
// (stale match-status reset), searchNavigate, endSearch teardown, the
// searchTotalReported / searchSelectionReported handlers (model-only, no
// commands), and cleanup of searchState across closePane / closeTab /
// sessionCreationFailed / deleteGroup.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateSearchTests {
    @Test("startSearch emits sendStartSearch for focused pane")
    func startSearchEmitsSendStartSearchForFocusedPane() {
        // Intent: startSearch emits sendStartSearch addressed to the
        //   focused pane and does NOT create searchState (that arrives via
        //   the backend's searchStarted callback).
        // Why it exists: pins the two-step search activation (command
        //   first, model state on the callback).
        // Scenario: spec-first startSearch.
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        let commands = update(&model, .startSearch)
        #expect(hasEffect(commands) {
            if case .sendStartSearch(let pid) = $0 { return pid == tab.focusedPaneId }
            return false
        }, "expected sendStartSearch")
        #expect(model.searchState.isEmpty, "should not create search state")
    }

    @Test("navigateFocusedSearch forwards to the focused pane's active search")
    func navigateFocusedSearchForwardsToFocusedPane() {
        // Intent: the paneless navigate msg resolves the focused pane and emits
        //   sendSearchNavigate for it in the requested direction.
        // Why it exists: Cmd-G/Cmd-Shift-G fire from the menu bar with no pane in
        //   hand, so the resolution has to happen in the pure core the same way
        //   `.startSearch` does it.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .searchStarted(paneId: paneId, needle: "hit"))

        let commands = update(&model, .navigateFocusedSearch(direction: .previous))
        #expect(hasEffect(commands) {
            if case .sendSearchNavigate(let pid, let direction) = $0 {
                return pid == paneId && direction == .previous
            }
            return false
        }, "expected sendSearchNavigate")
    }

    @Test("navigateFocusedSearch is a no-op without an active search")
    func navigateFocusedSearchNoOpWithoutActiveSearch() {
        // Intent: Cmd-G on a pane with no open find overlay emits nothing.
        // Why it exists: I6 -- the menu items stay enabled, so the guard is the
        //   only thing keeping a stray Cmd-G from driving engine search state
        //   behind the user's back.
        var model = makeModel()
        createTab(&model)

        let commands = update(&model, .navigateFocusedSearch(direction: .next))
        #expect(commands.isEmpty, "expected no commands without search state")
    }

    @Test("searchStarted creates SearchModel and emits focus")
    func searchStartedCreatesSearchModelEmitsFocus() {
        // Intent: searchStarted installs searchState for the pane and
        //   emits focusSearchField.
        // Why it exists: pins the callback-side wiring.
        // Scenario: spec-first backend start.
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        let paneId = tab.focusedPaneId
        let commands = update(&model, .searchStarted(paneId: paneId, needle: ""))
        #expect(model.searchState[paneId] != nil, "search state should exist")
        #expect(model.searchState[paneId]?.needle == "")
        #expect(hasEffect(commands) {
            if case .focusSearchField(let pid) = $0 { return pid == paneId }
            return false
        }, "expected focusSearchField")
    }

    @Test("searchStarted with needle sets needle in model")
    func searchStartedWithNeedleSetsNeedle() {
        // Intent: searchStarted carries the needle into searchState.
        // Why it exists: pins the needle propagation on activation.
        // Scenario: spec-first needle-on-start.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .searchStarted(paneId: paneId, needle: "hello"))
        #expect(model.searchState[paneId]?.needle == "hello")
    }

    @Test("searchStarted when already active updates needle and re-emits focus")
    func searchStartedWhileActiveUpdatesNeedleRefocuses() {
        // Intent: re-entering searchStarted on an active pane updates
        //   the needle and re-emits focusSearchField.
        // Why it exists: pins the idempotent re-entry path.
        // Scenario: spec-first re-entry update.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .searchStarted(paneId: paneId, needle: "first"))
        let commands = update(&model, .searchStarted(paneId: paneId, needle: "second"))
        #expect(model.searchState[paneId]?.needle == "second")
        #expect(hasEffect(commands) {
            if case .focusSearchField(let pid) = $0 { return pid == paneId }
            return false
        }, "expected focusSearchField on re-entry")
    }

    @Test("searchNeedleChanged updates needle and clears the stale match status")
    func searchNeedleChangedUpdatesNeedleClearsStaleCounts() {
        // Intent: searchNeedleChanged installs the new needle, clears the
        //   match status, and emits sendSearchNeedle.
        // Why it exists: pins the "needle changed -> counts invalid"
        //   invariant.
        // Scenario: spec-first needle change.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .searchStarted(paneId: paneId, needle: ""))
        model.searchState[paneId]?.status = .matched(selected: 2, total: 5)
        let commands = update(&model, .searchNeedleChanged(paneId: paneId, needle: "new"))
        #expect(model.searchState[paneId]?.needle == "new")
        #expect(model.searchState[paneId]?.status == nil, "status should be cleared")
        #expect(hasEffect(commands) {
            if case .sendSearchNeedle(let pid, let n) = $0 { return pid == paneId && n == "new" }
            return false
        }, "expected sendSearchNeedle")
    }

    @Test("searchNavigate emits sendSearchNavigate")
    func searchNavigateEmitsSendSearchNavigate() {
        // Intent: searchNavigate forwards the direction to the pane's backend.
        // Why it exists: pins the navigation wiring.
        // Scenario: spec-first navigate.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .searchStarted(paneId: paneId, needle: ""))
        let commands = update(&model, .searchNavigate(paneId: paneId, direction: .next))
        #expect(hasEffect(commands) {
            if case .sendSearchNavigate(let pid, let dir) = $0 {
                return pid == paneId && dir == .next
            }
            return false
        }, "expected sendSearchNavigate")
    }

    @Test("endSearch removes state and emits sendEnd + makeFirstResponder")
    func endSearchRemovesStateEmitsEndAndFirstResponder() {
        // Intent: endSearch clears searchState and emits sendEndSearch +
        //   makeFirstResponder.
        // Why it exists: pins the cleanup + focus return.
        // Scenario: spec-first end search.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .searchStarted(paneId: paneId, needle: "test"))
        let commands = update(&model, .endSearch(paneId: paneId))
        #expect(model.searchState[paneId] == nil, "search state should be removed")
        #expect(hasEffect(commands) {
            if case .sendEndSearch(let pid) = $0 { return pid == paneId }
            return false
        }, "expected sendEndSearch")
        #expect(hasEffect(commands) {
            if case .makeFirstResponder(let pid) = $0 { return pid == paneId }
            return false
        }, "expected makeFirstResponder")
    }

    @Test("endSearch on non-searching pane is no-op")
    func endSearchOnNonSearchingPaneIsNoOp() {
        // Intent: endSearch on a pane with no searchState is a no-op.
        // Why it exists: pins the absent-state guard.
        // Scenario: spec-first no-op end.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let commands = update(&model, .endSearch(paneId: paneId))
        #expect(commands.isEmpty, "should be no-op")
    }

    @Test("a reported total counts matches without selecting one, and drops any selection")
    func searchTotalReportedCountsWithoutSelecting() {
        // Intent: searchTotalReported stores `.counted(total:)` -- a count with no
        //   selection -- and emits no commands. A total arriving over an existing
        //   selection drops it, and a nil total clears the status outright.
        // Why it exists: backends report the total before the selection that goes
        //   with it, so the intermediate "N matches, none selected yet" state is
        //   real and the overlay renders it as `-/N`. A stale selection surviving a
        //   new total would render a match index the new count no longer contains.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .searchStarted(paneId: paneId, needle: "x"))

        let commands = update(&model, .searchTotalReported(paneId: paneId, total: 42))
        #expect(model.searchState[paneId]?.status == .counted(total: 42))
        #expect(commands.isEmpty, "searchTotalReported emits no command")

        update(&model, .searchSelectionReported(paneId: paneId, selected: 3))
        update(&model, .searchTotalReported(paneId: paneId, total: 2))
        #expect(model.searchState[paneId]?.status == .counted(total: 2),
            "a fresh total drops the selection it invalidated")

        update(&model, .searchTotalReported(paneId: paneId, total: nil))
        #expect(model.searchState[paneId]?.status == nil)
    }

    @Test("a reported selection pairs with the standing total, and is dropped without one")
    func searchSelectionReportedPairsWithStandingTotal() {
        // Intent: searchSelectionReported folds the index into the standing total as
        //   `.matched(selected:total:)`, a nil selection falls back to `.counted`,
        //   and a selection arriving before any total is discarded. No commands.
        // Why it exists: the status is one field precisely so "selected with no
        //   total" is unrepresentable; the discard is what keeps a stray
        //   out-of-order callback from resurrecting that pair.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .searchStarted(paneId: paneId, needle: "x"))

        let orphan = update(&model, .searchSelectionReported(paneId: paneId, selected: 3))
        #expect(model.searchState[paneId]?.status == nil, "no total yet -> nothing to select into")
        #expect(orphan.isEmpty)

        update(&model, .searchTotalReported(paneId: paneId, total: 42))
        let commands = update(&model, .searchSelectionReported(paneId: paneId, selected: 3))
        #expect(model.searchState[paneId]?.status == .matched(selected: 3, total: 42))
        #expect(commands.isEmpty, "searchSelectionReported emits no command")

        update(&model, .searchSelectionReported(paneId: paneId, selected: nil))
        #expect(model.searchState[paneId]?.status == .counted(total: 42),
            "clearing the selection keeps the count")
    }

    @Test("closePane cleans up search state")
    func closePaneCleansUpSearchState() {
        // Intent: closePane drops the pane's searchState.
        // Why it exists: pins the per-pane teardown.
        // Scenario: spec-first closePane cleanup.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .searchStarted(paneId: paneId, needle: "test"))
        #expect(model.searchState[paneId] != nil, "search state should exist before close")
        update(&model, .closePane(paneId: paneId))
        #expect(model.searchState[paneId] == nil, "search state should be cleaned up")
    }

    @Test("closeTab cleans up search state for all panes")
    func closeTabCleansUpSearchStateForAllPanes() {
        // Intent: closeTab clears searchState for every pane in the
        //   closed tab.
        // Why it exists: pins the per-tab teardown.
        // Scenario: spec-first closeTab cleanup.
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabId = model.selectedTabId!
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .searchStarted(paneId: paneId, needle: "test"))
        update(&model, .closeTab(id: tabId))
        #expect(model.searchState[paneId] == nil, "search state should be cleaned up on tab close")
    }

    @Test("sessionCreationFailed cleans up search state")
    func sessionCreationFailedCleansUpSearchState() {
        // Intent: sessionCreationFailed clears the failed pane's
        //   searchState.
        // Why it exists: pins the failure-path teardown.
        // Scenario: spec-first failure cleanup.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        model.searchState[paneId] = SearchModel(needle: "test")
        let sessionId = model.pane(paneId)!.session!.id
        update(&model, .sessionCreationFailed(sessionId: sessionId))
        #expect(model.searchState[paneId] == nil, "search state should be cleaned up on session failure")
    }

    @Test("deleteGroup cleans up search state")
    func deleteGroupCleansUpSearchState() {
        // Intent: deleteGroup clears side-table state for every pane in
        //   the deleted group's tabs.
        // Why it exists: pins the full per-group teardown.
        // Scenario: spec-first deleteGroup cleanup.
        var model = makeModel()
        createTab(&model)
        let group1Id = model.groups[0].id
        update(&model, .createGroup(name: "Second"))
        let group2Id = model.groups.first(where: { $0.id != group1Id })!.id
        let group2Tab = model.groups.first(where: { $0.id == group2Id })!.tabs[0]
        let group2PaneId = group2Tab.focusedPaneId
        model.alerts.insert(AlertModel(
            id: AlertId(), kind: .bell, paneId: group2PaneId,
            title: "DanTerm", body: "test", createdAt: Date(), isUnread: true
        ), at: 0)
        model.searchState[group2PaneId] = SearchModel(needle: "test")
        model.lastNotificationTime[group2PaneId] = [.bell: Date()]
        update(&model, .deleteGroup(id: group2Id, moveTabs: false))
        #expect(!model.alerts.contains { $0.paneId == group2PaneId }, "alerts should be cleaned up on group delete")
        #expect(model.searchState[group2PaneId] == nil, "search state should be cleaned up on group delete")
        #expect(model.lastNotificationTime[group2PaneId] == nil, "throttle data should be cleaned up on group delete")
    }
}
