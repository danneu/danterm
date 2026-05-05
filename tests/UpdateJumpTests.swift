// Tests for tab jump mode update handlers and their sidebar reload effects.
import Foundation

func updateJumpTests() {
    print("Update Jump Tests...")

    func buildModelWithTabs(_ count: Int) -> (model: AppModel, tabIds: [TabId]) {
        var model = makeModel()
        var ids: [TabId] = []
        for _ in 0..<count {
            _ = update(&model, .createTab(inGroupId: nil))
            ids.append(model.selectedTabId!)
        }
        return (model, ids)
    }

    func hasReloadSidebar(_ effects: [Effect]) -> Bool {
        hasEffect(effects) {
            if case .reloadSidebar = $0 { return true }
            return false
        }
    }

    func hasHideSwitcherOverlay(_ effects: [Effect]) -> Bool {
        hasEffect(effects) {
            if case .hideSwitcherOverlay = $0 { return true }
            return false
        }
    }

    test("jumpModeActivated populates keyMap and reloads sidebar") {
        var model = makeModel()
        let visibleTabs = [TabId(), TabId(), TabId()]

        let effects = update(&model, .jumpModeActivated(visibleTabs: visibleTabs))

        try expectEqual(model.jumpMode?.keyMap, assignJumpKeys(visibleTabs: visibleTabs))
        try expect(hasReloadSidebar(effects), "activation should reload sidebar")
    }

    test("jumpModeActivated clears active MRU cycle and hides switcher overlay") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0
        model.mruCycle = MruCycleState(frozenOrder: model.mruOrder, cursorIndex: 1)

        let effects = update(&model, .jumpModeActivated(visibleTabs: ids))

        try expect(model.mruCycle == nil, "MRU cycle should be cleared")
        try expect(model.jumpMode != nil, "jump mode should be active")
        try expect(hasHideSwitcherOverlay(effects), "MRU overlay should hide")
        try expect(hasReloadSidebar(effects), "activation should reload sidebar")
    }

    test("jumpModeKeyPressed selects mapped tab, clears mode, and reloads sidebar") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        let effects = update(&model, .jumpModeKeyPressed(char: "a"))

        try expectEqual(model.selectedTabId, ids[0], "first visible tab should be selected")
        try expect(model.selectedTabId != initiallySelected)
        try expect(model.jumpMode == nil, "jump mode should be cleared")
        try expect(hasReloadSidebar(effects), "commit should reload sidebar")
    }

    test("jumpModeKeyPressed on already selected tab still reloads sidebar") {
        let (m0, ids) = buildModelWithTabs(1)
        var model = m0
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        let effects = update(&model, .jumpModeKeyPressed(char: "a"))

        try expectEqual(model.selectedTabId, ids[0])
        try expect(model.jumpMode == nil)
        try expect(hasReloadSidebar(effects), "self-select commit should reload sidebar")
    }

    test("jumpModeKeyPressed for unmapped key clears mode without changing selection") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        let effects = update(&model, .jumpModeKeyPressed(char: "z"))

        try expectEqual(model.selectedTabId, initiallySelected)
        try expect(model.jumpMode == nil)
        try expect(hasReloadSidebar(effects), "unmapped key should reload sidebar")
    }

    test("jumpModeKeyPressed for stale mapped tab clears mode and only reloads sidebar") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))
        _ = update(&model, .closeTab(id: ids[0]))

        let effects = update(&model, .jumpModeKeyPressed(char: "a"))

        try expectEqual(model.selectedTabId, initiallySelected)
        try expect(model.jumpMode == nil)
        try expectEqual(effects.count, 1)
        try expect(hasReloadSidebar(effects), "stale target should only reload sidebar")
    }

    test("jumpModeCanceled clears mode and reloads sidebar") {
        let (m0, ids) = buildModelWithTabs(2)
        var model = m0
        let initiallySelected = model.selectedTabId
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        let effects = update(&model, .jumpModeCanceled)

        try expectEqual(model.selectedTabId, initiallySelected)
        try expect(model.jumpMode == nil)
        try expect(hasReloadSidebar(effects), "cancel should reload sidebar")
    }

    test("appResignedActive clears jump mode and reloads sidebar") {
        let (m0, ids) = buildModelWithTabs(2)
        var model = m0
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        let effects = update(&model, .appResignedActive)

        try expect(model.jumpMode == nil)
        try expect(hasEffect(effects) { if case .setAppFocus(false) = $0 { return true }; return false })
        try expect(hasReloadSidebar(effects), "app resign should reload sidebar when jump mode was active")
    }

    test("appResignedActive without jump mode does not reload sidebar") {
        var model = makeModel()

        let effects = update(&model, .appResignedActive)

        try expect(hasEffect(effects) { if case .setAppFocus(false) = $0 { return true }; return false })
        try expect(!hasReloadSidebar(effects), "plain app resign should not reload sidebar")
    }
}
