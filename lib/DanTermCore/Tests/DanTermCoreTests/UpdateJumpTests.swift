// Swift Testing migration of the legacy `tests/UpdateJumpTests.swift` harness
// suite. Pins the tab-jump-mode Msg paths: jumpModeActivated (keyMap derive
// + active-cycle clear), jumpModeKeyPressed (mapped target selects + mode
// clear, already-selected no-op, unmapped no-op, stale-target no-op),
// jumpModeCanceled (clear without changing selection), and the
// appResignedActive jump-mode side effect (clears mode).
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateJumpTests {
    static func buildModelWithTabs(_ count: Int) -> (model: AppModel, tabIds: [TabId]) {
        var model = makeModel()
        var ids: [TabId] = []
        for _ in 0..<count {
            _ = update(&model, .createTab(inGroupId: nil))
            ids.append(model.selectedTabId!)
        }
        return (model, ids)
    }

    @Test("jumpModeActivated populates keyMap")
    func jumpModeActivatedPopulatesKeyMap() {
        // Intent: jumpModeActivated installs jumpMode.keyMap derived from
        //   the visible-tabs argument; emits no commands.
        // Why it exists: pins the activation contract (per-tab jump
        //   badges reconcile from the projection).
        // Scenario: spec-first activation.
        var model = makeModel()
        let visibleTabs = [TabId(), TabId(), TabId()]

        let commands = update(&model, .jumpModeActivated(visibleTabs: visibleTabs))

        #expect(model.jumpMode?.keyMap == assignJumpKeys(visibleTabs: visibleTabs))
        #expect(commands.isEmpty, "plain activation emits no commands")
    }

    @Test("jumpModeActivated clears an active MRU cycle")
    func jumpModeActivatedClearsActiveMruCycle() {
        // Intent: activating jump mode while an MRU cycle is active
        //   clears the cycle (one overlay at a time).
        // Why it exists: pins the cross-overlay clear rule.
        // Scenario: spec-first cycle + jump.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0
        model.mruCycle = MruCycleState(frozenOrder: model.mruOrder, cursorIndex: 1)

        let commands = update(&model, .jumpModeActivated(visibleTabs: ids))

        #expect(model.mruCycle == nil, "MRU cycle cleared -> reconcileSwitcher hides the panel")
        #expect(model.jumpMode != nil, "jump mode should be active")
        #expect(commands.isEmpty, "no commands; jump badges + switcher hide both reconcile")
    }

    @Test("jumpModeKeyPressed selects mapped tab and clears mode")
    func jumpModeKeyPressedSelectsMappedTabAndClears() {
        // Intent: pressing a mapped key selects the target tab and
        //   clears jumpMode.
        // Why it exists: pins the per-key selection path.
        // Scenario: spec-first key-press select.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        update(&model, .jumpModeKeyPressed(char: "a"))

        #expect(model.selectedTabId == ids[0], "first visible tab should be selected")
        #expect(model.selectedTabId != initiallySelected)
        #expect(model.jumpMode == nil, "jump mode should be cleared")
    }

    @Test("jumpModeKeyPressed on already-selected tab clears mode")
    func jumpModeKeyPressedOnAlreadySelectedClearsMode() {
        // Intent: a key-press selecting the already-selected tab still
        //   clears the mode and emits no commands.
        // Why it exists: pins the no-command self-select branch.
        // Scenario: spec-first self-select clear.
        let (m0, ids) = Self.buildModelWithTabs(1)
        var model = m0
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        let commands = update(&model, .jumpModeKeyPressed(char: "a"))

        #expect(model.selectedTabId == ids[0])
        #expect(model.jumpMode == nil)
        #expect(commands.isEmpty, "self-select commit emits no commands")
    }

    @Test("jumpModeKeyPressed for unmapped key clears mode without changing selection")
    func jumpModeKeyPressedUnmappedClearsModeNoSelection() {
        // Intent: an unmapped key clears the mode without changing
        //   selection.
        // Why it exists: pins the unmapped-key escape hatch.
        // Scenario: spec-first unmapped clear.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        let commands = update(&model, .jumpModeKeyPressed(char: "z"))

        #expect(model.selectedTabId == initiallySelected)
        #expect(model.jumpMode == nil)
        #expect(commands.isEmpty, "unmapped key emits no commands (badges clear via reconcile)")
    }

    @Test("jumpModeKeyPressed for stale mapped tab clears mode")
    func jumpModeKeyPressedStaleMappedClearsMode() {
        // Intent: a key whose mapped tab no longer exists clears mode
        //   without changing selection.
        // Why it exists: pins fail-closed for stale jump targets.
        // Scenario: spec-first stale jump.
        let (m0, ids) = Self.buildModelWithTabs(3)
        var model = m0
        let initiallySelected = model.selectedTabId
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))
        _ = update(&model, .closeTab(id: ids[0]))

        let commands = update(&model, .jumpModeKeyPressed(char: "a"))

        #expect(model.selectedTabId == initiallySelected)
        #expect(model.jumpMode == nil)
        #expect(commands.isEmpty, "stale target emits no commands (badges clear via reconcile)")
    }

    @Test("jumpModeCanceled clears mode")
    func jumpModeCanceledClearsMode() {
        // Intent: jumpModeCanceled clears jumpMode and leaves selection
        //   untouched.
        // Why it exists: pins the cancel path.
        // Scenario: spec-first cancel.
        let (m0, ids) = Self.buildModelWithTabs(2)
        var model = m0
        let initiallySelected = model.selectedTabId
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        let commands = update(&model, .jumpModeCanceled)

        #expect(model.selectedTabId == initiallySelected)
        #expect(model.jumpMode == nil)
        #expect(commands.isEmpty, "cancel emits no commands (badges clear via reconcile)")
    }

    @Test("appResignedActive clears jump mode")
    func appResignedActiveClearsJumpMode() {
        // Intent: appResignedActive while jump mode is active clears it and still
        //   records the app as inactive.
        // Why it exists: pins the lifecycle integration.
        // Scenario: spec-first lifecycle clear.
        let (m0, ids) = Self.buildModelWithTabs(2)
        var model = m0
        _ = update(&model, .jumpModeActivated(visibleTabs: ids))

        _ = update(&model, .appResignedActive)

        #expect(model.jumpMode == nil)
        #expect(model.isAppActive == false)
    }
}
