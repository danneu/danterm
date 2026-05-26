import Foundation

func searchTests() {
    print("Search tests:")

    test("startSearch emits sendStartSearch for focused pane") {
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        let effects = update(&model, .startSearch)
        try expect(hasEffect(effects) {
            if case .sendStartSearch(let pid) = $0 { return pid == tab.focusedPaneId }
            return false
        }, "expected sendStartSearch")
        // Should NOT create model state
        try expect(model.searchState.isEmpty, "should not create search state")
    }

    test("ghosttyStartSearch creates SearchModel and emits focus") {
        var model = makeModel()
        createTab(&model)
        let tab = selectedTab(in: model)!
        let paneId = tab.focusedPaneId
        let effects = update(&model, .ghosttyStartSearch(paneId: paneId, needle: ""))
        // searchState set -> reconcilePaneChrome renders the overlay (no .showSearchOverlay).
        try expect(model.searchState[paneId] != nil, "search state should exist")
        try expectEqual(model.searchState[paneId]?.needle, "")
        try expect(hasEffect(effects) {
            if case .focusSearchField(let pid) = $0 { return pid == paneId }
            return false
        }, "expected focusSearchField")
    }

    test("ghosttyStartSearch with needle sets needle in model") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "hello"))
        try expectEqual(model.searchState[paneId]?.needle, "hello")
    }

    test("ghosttyStartSearch when already active updates needle and re-emits focus") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "first"))
        let effects = update(&model, .ghosttyStartSearch(paneId: paneId, needle: "second"))
        try expectEqual(model.searchState[paneId]?.needle, "second")
        try expect(hasEffect(effects) {
            if case .focusSearchField(let pid) = $0 { return pid == paneId }
            return false
        }, "expected focusSearchField on re-entry")
    }

    test("searchNeedleChanged updates needle and clears stale total/selected") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: ""))
        model.searchState[paneId]?.total = 5
        model.searchState[paneId]?.selected = 2
        let effects = update(&model, .searchNeedleChanged(paneId: paneId, needle: "new"))
        try expectEqual(model.searchState[paneId]?.needle, "new")
        try expect(model.searchState[paneId]?.total == nil, "total should be cleared")
        try expect(model.searchState[paneId]?.selected == nil, "selected should be cleared")
        try expect(hasEffect(effects) {
            if case .sendSearchNeedle(let pid, let n) = $0 { return pid == paneId && n == "new" }
            return false
        }, "expected sendSearchNeedle")
    }

    test("searchNavigate emits sendSearchNavigate") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: ""))
        let effects = update(&model, .searchNavigate(paneId: paneId, direction: .next))
        try expect(hasEffect(effects) {
            if case .sendSearchNavigate(let pid, let dir) = $0 {
                return pid == paneId && dir == .next
            }
            return false
        }, "expected sendSearchNavigate")
    }

    test("endSearch removes state and emits sendEnd + makeFirstResponder") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "test"))
        let effects = update(&model, .endSearch(paneId: paneId))
        // searchState cleared -> the overlay projection drops this pane's key, so
        // reconcilePaneChrome's `remove` tears the overlay down (no .hideSearchOverlay).
        try expect(model.searchState[paneId] == nil, "search state should be removed")
        try expect(hasEffect(effects) {
            if case .sendEndSearch(let pid) = $0 { return pid == paneId }
            return false
        }, "expected sendEndSearch")
        try expect(hasEffect(effects) {
            if case .makeFirstResponder(let pid) = $0 { return pid == paneId }
            return false
        }, "expected makeFirstResponder")
    }

    test("endSearch on non-searching pane is no-op") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let effects = update(&model, .endSearch(paneId: paneId))
        try expect(effects.isEmpty, "should be no-op")
    }

    test("ghosttySearchTotal updates total") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "x"))
        let effects = update(&model, .ghosttySearchTotal(paneId: paneId, total: 42))
        try expectEqual(model.searchState[paneId]?.total, 42)
        // The match count re-renders via reconcilePaneChrome from the searchState
        // change above; the handler emits no command.
        try expect(effects.isEmpty, "ghosttySearchTotal emits no command")
    }

    test("ghosttySearchSelected updates selected") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "x"))
        let effects = update(&model, .ghosttySearchSelected(paneId: paneId, selected: 3))
        try expectEqual(model.searchState[paneId]?.selected, 3)
        // The match count re-renders via reconcilePaneChrome from the searchState
        // change above; the handler emits no command.
        try expect(effects.isEmpty, "ghosttySearchSelected emits no command")
    }

    test("closePane cleans up search state") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "test"))
        try expect(model.searchState[paneId] != nil, "search state should exist before close")
        update(&model, .closePane(paneId: paneId))
        try expect(model.searchState[paneId] == nil, "search state should be cleaned up")
    }

    test("closeTab cleans up search state for all panes") {
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let tabId = model.selectedTabId!
        let paneId = selectedTab(in: model)!.focusedPaneId
        update(&model, .ghosttyStartSearch(paneId: paneId, needle: "test"))
        update(&model, .closeTab(id: tabId))
        try expect(model.searchState[paneId] == nil, "search state should be cleaned up on tab close")
    }

    test("surfaceCreationFailed cleans up search state") {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        model.searchState[paneId] = SearchModel(needle: "test")
        update(&model, .surfaceCreationFailed(paneId: paneId))
        try expect(model.searchState[paneId] == nil, "search state should be cleaned up on surface failure")
    }

    test("deleteGroup cleans up search state") {
        var model = makeModel()
        createTab(&model)
        let group1Id = model.groups[0].id
        // Create a second group with a tab
        update(&model, .createGroup(name: "Second"))
        let group2Id = model.groups.first(where: { $0.id != group1Id })!.id
        let group2Tab = model.groups.first(where: { $0.id == group2Id })!.tabs[0]
        let group2PaneId = group2Tab.focusedPaneId
        model.searchState[group2PaneId] = SearchModel(needle: "test")
        update(&model, .deleteGroup(id: group2Id, moveTabs: false))
        try expect(model.searchState[group2PaneId] == nil, "search state should be cleaned up on group delete")
    }
}
