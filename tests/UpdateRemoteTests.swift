import Foundation

func remoteTests() {
    print("Remote Tests...")

    test("remoteSessionStarted sets isRemote") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .remoteSessionStarted(paneId: paneId))
        try expectEqual(model.panes[paneId]?.isRemote, true, "pane should be remote")
        try expect(hasEffect(effects) {
            if case .applyPaneTheme(let pid) = $0, pid == paneId { return true }
            return false
        }, "should emit applyPaneTheme")
    }

    test("remoteSessionStarted sets remoteThemeOverride without changing theme") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.panes[paneId]?.theme = "MyCustomTheme"

        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        try expectEqual(model.panes[paneId]?.theme, "MyCustomTheme", "user theme should be unchanged")
        try expectEqual(model.panes[paneId]?.remoteThemeOverride, "Purplepeter", "remote override should be set")
    }

    test("commandEnded clears isRemote and remoteThemeOverride") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.panes[paneId]?.isRemote = true
        model.panes[paneId]?.remoteThemeOverride = "Purplepeter"

        let effects = update(&model, .commandEnded(paneId: paneId))
        try expectEqual(model.panes[paneId]?.isRemote, false)
        try expectEqual(model.panes[paneId]?.remoteThemeOverride, nil, "override should be cleared")
        try expect(hasEffect(effects) {
            if case .applyPaneTheme(let pid) = $0, pid == paneId { return true }
            return false
        }, "should emit applyPaneTheme to revert")
    }

    test("commandEnded on non-remote pane is no-op") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let effects = update(&model, .commandEnded(paneId: paneId))
        try expectEqual(model.panes[paneId]?.isRemote, false, "pane should remain non-remote")
        try expectEqual(effects.count, 0, "no effects expected")
    }

    test("remoteSessionStarted on missing pane returns empty effects") {
        var model = makeModel()
        let fakePaneId = PaneId()
        let effects = update(&model, .remoteSessionStarted(paneId: fakePaneId))
        try expectEqual(effects.count, 0, "no effects for missing pane")
    }

    test("commandEnded on missing pane returns empty effects") {
        var model = makeModel()
        let fakePaneId = PaneId()
        let effects = update(&model, .commandEnded(paneId: fakePaneId))
        try expectEqual(effects.count, 0, "no effects for missing pane")
    }

    test("remote lifecycle: start then end restores theme") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.panes[paneId]?.theme = "Dracula"

        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        try expectEqual(model.panes[paneId]?.remoteThemeOverride, "Purplepeter")
        try expectEqual(model.panes[paneId]?.theme, "Dracula", "user theme preserved")

        _ = update(&model, .commandEnded(paneId: paneId))
        try expectEqual(model.panes[paneId]?.remoteThemeOverride, nil)
        try expectEqual(model.panes[paneId]?.theme, "Dracula", "user theme still there")
    }

    test("effectiveTheme returns override when set") {
        var pane = PaneModel(id: PaneId())
        pane.theme = "Dracula"
        pane.remoteThemeOverride = "Purplepeter"
        try expectEqual(effectiveTheme(for: pane), "Purplepeter")
    }

    test("effectiveTheme falls back to user theme") {
        var pane = PaneModel(id: PaneId())
        pane.theme = "Dracula"
        try expectEqual(effectiveTheme(for: pane), "Dracula")
    }

    test("effectiveTheme returns nil when both are nil") {
        let pane = PaneModel(id: PaneId())
        try expect(effectiveTheme(for: pane) == nil, "should be nil")
    }

    test("setPaneTheme while remote changes user theme not override") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        _ = update(&model, .setPaneTheme(paneId: paneId, themeName: "Solarized"))
        try expectEqual(model.panes[paneId]?.theme, "Solarized", "user theme should change")
        try expectEqual(model.panes[paneId]?.remoteThemeOverride, "Purplepeter", "override unchanged")
    }
}
