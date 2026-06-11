// Tests for the pure menubar tab-action router. These pin the shared target rule
// AppDelegate uses for batch-capable Tab menu actions: sidebar multi-selection
// first, selected-tab fallback second, and no message when neither exists.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct MenubarTabActionTests {
    @Test("menubarTabActionMsg routes multi-selection for every tab action")
    func menubarTabActionRoutesMultiSelection() {
        // Intent: every batch-capable Tab menu action uses the sidebar's
        //   multi-selection as its target set when one exists.
        // Why it exists: pins the shared menubar rule so individual AppDelegate
        //   handlers cannot drift back to selected-tab-only behavior.
        // Scenario: spec-first multi-selection check -- selected tab is id2,
        //   sidebar selection is [id0, id2], and every action targets [id0, id2].
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)
        let targets = [ids[0], ids[2]]

        expectSetTabColors(
            menubarTabActionMsg(.setColor(.green), sidebarSelection: targets, in: model),
            tabIds: targets,
            color: .green)
        expectSetTabColors(
            menubarTabActionMsg(.clearColor, sidebarSelection: targets, in: model),
            tabIds: targets,
            color: nil)
        expectClearCustomTitles(
            menubarTabActionMsg(.clearCustomTitles, sidebarSelection: targets, in: model),
            tabIds: targets)
        expectClearAlertsForTabs(
            menubarTabActionMsg(.clearAlerts, sidebarSelection: targets, in: model),
            tabIds: targets)
    }

    @Test("menubarTabActionMsg falls back to selected tab for every tab action")
    func menubarTabActionFallsBackToSelectedTab() throws {
        // Intent: when the sidebar contributes no selection, every
        //   batch-capable Tab menu action targets the focused tab.
        // Why it exists: pins the fallback that keeps menu shortcuts useful
        //   during transient sidebar teardown or empty selection states.
        // Scenario: spec-first fallback check -- no sidebar selection, selected
        //   tab is id1, and every action targets [id1].
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let selected = try #require(model.selectedTabId)
        let targets = [selected]

        expectSetTabColors(
            menubarTabActionMsg(.setColor(.blue), sidebarSelection: [], in: model),
            tabIds: targets,
            color: .blue)
        expectSetTabColors(
            menubarTabActionMsg(.clearColor, sidebarSelection: [], in: model),
            tabIds: targets,
            color: nil)
        expectClearCustomTitles(
            menubarTabActionMsg(.clearCustomTitles, sidebarSelection: [], in: model),
            tabIds: targets)
        expectClearAlertsForTabs(
            menubarTabActionMsg(.clearAlerts, sidebarSelection: [], in: model),
            tabIds: targets)
    }

    @Test("menubarTabActionMsg returns nil without sidebar or selected tab")
    func menubarTabActionReturnsNilWithoutTarget() {
        // Intent: the router returns nil when neither sidebar selection nor
        //   selectedTabId can supply a target.
        // Why it exists: pins the fail-closed menu path for empty models and
        //   teardown states.
        // Scenario: spec-first no-target check -- model has a tab but
        //   selectedTabId is nil and sidebar selection is empty.
        var model = makeModel()
        createTab(&model)
        model.selectedTabId = nil

        #expect(menubarTabActionMsg(.setColor(.red), sidebarSelection: [], in: model) == nil)
        #expect(menubarTabActionMsg(.clearColor, sidebarSelection: [], in: model) == nil)
        #expect(menubarTabActionMsg(.clearCustomTitles, sidebarSelection: [], in: model) == nil)
        #expect(menubarTabActionMsg(.clearAlerts, sidebarSelection: [], in: model) == nil)
    }

    @Test("menubarTabActionMsg setColor uses batch toggle-off policy")
    func menubarTabActionSetColorUsesToggleOffPolicy() {
        // Intent: setColor threads through resolveColorForBatch, including the
        //   all-targets-share toggle-off case.
        // Why it exists: pins the color shortcut behavior while moving target
        //   selection into the shared menubar router.
        // Scenario: spec-first toggle -- two selected red tabs receive setColor
        //   red, so the router emits setTabColors(..., nil).
        var model = makeModel()
        createTab(&model)
        createTab(&model)
        let ids = model.groups[0].tabs.map(\.id)
        model.groups[0].tabs[0].color = .red
        model.groups[0].tabs[1].color = .red

        expectSetTabColors(
            menubarTabActionMsg(.setColor(.red), sidebarSelection: ids, in: model),
            tabIds: ids,
            color: nil)
    }
}

private func expectSetTabColors(_ msg: Msg?, tabIds: [TabId], color: TabColor?) {
    guard let msg else {
        Issue.record("expected setTabColors, got nil")
        return
    }
    guard case .setTabColors(let actualIds, let actualColor) = msg else {
        Issue.record("expected setTabColors, got \(msg)")
        return
    }
    #expect(actualIds == tabIds)
    #expect(actualColor == color)
}

private func expectClearCustomTitles(_ msg: Msg?, tabIds: [TabId]) {
    guard let msg else {
        Issue.record("expected clearCustomTitles, got nil")
        return
    }
    guard case .clearCustomTitles(let actualIds) = msg else {
        Issue.record("expected clearCustomTitles, got \(msg)")
        return
    }
    #expect(actualIds == tabIds)
}

private func expectClearAlertsForTabs(_ msg: Msg?, tabIds: [TabId]) {
    guard let msg else {
        Issue.record("expected clearAlertsForTabs, got nil")
        return
    }
    guard case .clearAlertsForTabs(let actualIds) = msg else {
        Issue.record("expected clearAlertsForTabs, got \(msg)")
        return
    }
    #expect(actualIds == tabIds)
}
