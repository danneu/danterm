// Swift Testing migration of the legacy `tests/UpdateSearchTests.swift`
// harness suite. Pins the search-domain Msg paths: startSearch /
// ghosttyStartSearch (focus-field + searchState creation), needle changes
// (stale total/selected reset), searchNavigate, endSearch teardown, the
// ghosttySearchTotal / ghosttySearchSelected handlers (model-only, no
// commands), and cleanup of searchState across closePane / closeTab /
// surfaceCreationFailed / deleteGroup.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateSearchTests {
    @Test("startSearch emits sendStartSearch for focused pane")
    func startSearchEmitsSendStartSearchForFocusedPane() {
        // Intent: startSearch emits sendStartSearch addressed to the
        //   focused pane and does NOT create searchState (that arrives via
        //   the Ghostty callback).
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

    @Test("ghosttyStartSearch creates SearchModel and emits focus")
    func ghosttyStartSearchCreatesSearchModelEmitsFocus() {
        // Intent: ghosttyStartSearch installs searchState for the pane and
        //   emits focusSearchField.
        // Why it exists: pins the callback-side wiring.
        // Scenario: spec-first ghostty start.
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        let paneId = tab.focusedPaneId
        let commands = update(&model, .ghosttyStartSearch(paneId: paneId, needle: ""))
        #expect(model.searchState[paneId] != nil, "search state should exist")
        #expect(model.searchState[paneId]?.needle == "")
        #expect(hasEffect(commands) {
            if case .focusSearchField(let pid) = $0 { return pid == paneId }
            return false
        }, "expected focusSearchField")
    }

    @Test("ghosttyStartSearch with needle sets needle in model")
    func ghosttyStartSearchWithNeedleSetsNeedle() {
        // Intent: ghosttyStartSearch carries the needle into searchState.
        // Why it exists: pins the needle propagation on activation.
        // Scenario: spec-first needle-on-start.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "hello"))
        #expect(model.searchState[paneId]?.needle == "hello")
    }

    @Test("ghosttyStartSearch when already active updates needle and re-emits focus")
    func ghosttyStartSearchWhileActiveUpdatesNeedleRefocuses() {
        // Intent: re-entering ghosttyStartSearch on an active pane updates
        //   the needle and re-emits focusSearchField.
        // Why it exists: pins the idempotent re-entry path.
        // Scenario: spec-first re-entry update.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "first"))
        let commands = update(&model, .ghosttyStartSearch(paneId: paneId, needle: "second"))
        #expect(model.searchState[paneId]?.needle == "second")
        #expect(hasEffect(commands) {
            if case .focusSearchField(let pid) = $0 { return pid == paneId }
            return false
        }, "expected focusSearchField on re-entry")
    }

    @Test("searchNeedleChanged updates needle and clears stale total/selected")
    func searchNeedleChangedUpdatesNeedleClearsStaleCounts() {
        // Intent: searchNeedleChanged installs the new needle, clears
        //   total/selected, and emits sendSearchNeedle.
        // Why it exists: pins the "needle changed -> counts invalid"
        //   invariant.
        // Scenario: spec-first needle change.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: ""))
        model.searchState[paneId]?.total = 5
        model.searchState[paneId]?.selected = 2
        let commands = update(&model, .searchNeedleChanged(paneId: paneId, needle: "new"))
        #expect(model.searchState[paneId]?.needle == "new")
        #expect(model.searchState[paneId]?.total == nil, "total should be cleared")
        #expect(model.searchState[paneId]?.selected == nil, "selected should be cleared")
        #expect(hasEffect(commands) {
            if case .sendSearchNeedle(let pid, let n) = $0 { return pid == paneId && n == "new" }
            return false
        }, "expected sendSearchNeedle")
    }

    @Test("searchNavigate emits sendSearchNavigate")
    func searchNavigateEmitsSendSearchNavigate() {
        // Intent: searchNavigate forwards the direction to Ghostty.
        // Why it exists: pins the navigation wiring.
        // Scenario: spec-first navigate.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: ""))
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
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "test"))
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

    @Test("ghosttySearchTotal updates total")
    func ghosttySearchTotalUpdatesTotal() {
        // Intent: ghosttySearchTotal stores total; emits no commands.
        // Why it exists: pins the no-side-effect total update.
        // Scenario: spec-first total update.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "x"))
        let commands = update(&model, .ghosttySearchTotal(paneId: paneId, total: 42))
        #expect(model.searchState[paneId]?.total == 42)
        #expect(commands.isEmpty, "ghosttySearchTotal emits no command")
    }

    @Test("ghosttySearchSelected updates selected")
    func ghosttySearchSelectedUpdatesSelected() {
        // Intent: ghosttySearchSelected stores selected; emits no
        //   commands.
        // Why it exists: pins the no-side-effect selected update.
        // Scenario: spec-first selected update.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "x"))
        let commands = update(&model, .ghosttySearchSelected(paneId: paneId, selected: 3))
        #expect(model.searchState[paneId]?.selected == 3)
        #expect(commands.isEmpty, "ghosttySearchSelected emits no command")
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
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "test"))
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
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "test"))
        update(&model, .closeTab(id: tabId))
        #expect(model.searchState[paneId] == nil, "search state should be cleaned up on tab close")
    }

    @Test("surfaceCreationFailed cleans up search state")
    func surfaceCreationFailedCleansUpSearchState() {
        // Intent: surfaceCreationFailed clears the failed pane's
        //   searchState.
        // Why it exists: pins the failure-path teardown.
        // Scenario: spec-first failure cleanup.
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        model.searchState[paneId] = SearchModel(needle: "test")
        update(&model, .surfaceCreationFailed(paneId: paneId))
        #expect(model.searchState[paneId] == nil, "search state should be cleaned up on surface failure")
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
