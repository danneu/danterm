// Tests for tab jump mode update handlers. The per-tab jump badges and the selection
// now reconcile via reconcileSidebar (the projection carries jumpMode.keyMap and
// selection is view-owned), so these assert the model-state outcomes and the surviving
// commands rather than the deleted reloadSidebar / setSidebarSelection effects.
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

    test("jumpModeActivated populates keyMap") {
        var model = makeModel()
        let visibleTabs = [TabId(), TabId(), TabId()]

        let effects = update(&model, .jumpModeActivated(visibleTabs: visibleTabs))

        try expectEqual(model.jumpMode?.keyMap, assignJumpKeys(visibleTabs: visibleTabs))
        // Per-tab jump badges appear via reconcileSidebar; plain activation emits no command.
        try expect(effects.isEmpty, "plain activation emits no commands")
    }

    test("jumpModeActivated clears an active MRU cycle") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0
        model.mruCycle = MruCycleState(frozenOrder: model.mruOrder, cursorIndex: 1)

        let effects = update(&model, .jumpModeActivated(visibleTabs: ids))

        try expect(model.mruCycle == nil, "MRU cycle cleared -> reconcileSwitcher hides the panel")
        try expect(model.jumpMode != nil, "jump mode should be active")
        try expect(effects.isEmpty, "no commands; jump badges + switcher hide both reconcile")
    }

    test("jumpModeKeyPressed selects mapped tab and clears mode") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        update(&model, .jumpModeKeyPressed(char: "a"))

        try expectEqual(model.selectedTabId, ids[0], "first visible tab should be selected")
        try expect(model.selectedTabId != initiallySelected)
        try expect(model.jumpMode == nil, "jump mode should be cleared")
        // The view swap is structural now: reconcileContainers shows the newly selected
        // tab. selectedTabId (asserted above) is the net.
    }

    test("jumpModeKeyPressed on already-selected tab clears mode") {
        let (m0, ids) = buildModelWithTabs(1)
        var model = m0
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        let effects = update(&model, .jumpModeKeyPressed(char: "a"))

        try expectEqual(model.selectedTabId, ids[0])
        try expect(model.jumpMode == nil)
        // Re-selecting the current tab is a command no-op; badges clear via reconcile.
        try expect(effects.isEmpty, "self-select commit emits no commands")
    }

    test("jumpModeKeyPressed for unmapped key clears mode without changing selection") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        let effects = update(&model, .jumpModeKeyPressed(char: "z"))

        try expectEqual(model.selectedTabId, initiallySelected)
        try expect(model.jumpMode == nil)
        try expect(effects.isEmpty, "unmapped key emits no commands (badges clear via reconcile)")
    }

    test("jumpModeKeyPressed for stale mapped tab clears mode") {
        let (m0, ids) = buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))
        _ = update(&model, .closeTab(id: ids[0]))

        let effects = update(&model, .jumpModeKeyPressed(char: "a"))

        try expectEqual(model.selectedTabId, initiallySelected)
        try expect(model.jumpMode == nil)
        try expect(effects.isEmpty, "stale target emits no commands (badges clear via reconcile)")
    }

    test("jumpModeCanceled clears mode") {
        let (m0, ids) = buildModelWithTabs(2)
        var model = m0
        let initiallySelected = model.selectedTabId
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        let effects = update(&model, .jumpModeCanceled)

        try expectEqual(model.selectedTabId, initiallySelected)
        try expect(model.jumpMode == nil)
        try expect(effects.isEmpty, "cancel emits no commands (badges clear via reconcile)")
    }

    test("appResignedActive clears jump mode") {
        let (m0, ids) = buildModelWithTabs(2)
        var model = m0
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        let effects = update(&model, .appResignedActive)

        try expect(model.jumpMode == nil)
        try expect(hasEffect(effects) { if case .setAppFocus(false) = $0 { return true }; return false })
    }

    test("appResignedActive without jump mode still defocuses") {
        var model = makeModel()

        let effects = update(&model, .appResignedActive)

        try expect(hasEffect(effects) { if case .setAppFocus(false) = $0 { return true }; return false })
    }
}
