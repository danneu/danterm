// Tests remote detection state transitions and remote theme behavior.
import Foundation

func remoteTests() {
    print("Remote Tests...")

    test("remoteSessionStarted sets isRemote") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        try expectEqual(model.pane(paneId)?.isRemote, true, "pane should be remote")
        try expectEqual(desiredPaneConfig(in: model)[paneId]?.theme, "Purplepeter")
    }

    test("remoteSessionStarted sets remoteThemeOverride without changing theme") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.theme = "MyCustomTheme" }
        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        try expectEqual(model.pane(paneId)?.theme, "MyCustomTheme", "user theme should be unchanged")
        try expectEqual(model.pane(paneId)?.remoteThemeOverride, "Purplepeter", "remote override should be set")
    }

    test("remoteSessionStarted uses config.remoteTheme") {
        var model = makeModel()
        model.config.remoteTheme = "Ocean"
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        try expectEqual(model.pane(paneId)?.remoteThemeOverride, "Ocean", "should use config remote theme")
    }

    test("remoteSessionStarted clears stale remoteSession") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.remoteSession = RemoteSession(user: "dan", host: "caja") }
        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        try expectEqual(model.pane(paneId)?.remoteSession, nil, "stale remote session should be cleared")
    }

    test("remoteSessionReported sets remoteSession and isRemote on first call") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let session = RemoteSession(user: "dan", host: "caja")

        _ = update(&model, .remoteSessionReported(paneId: paneId, session: session))
        try expectEqual(model.pane(paneId)?.isRemote, true, "pane should be remote")
        try expectEqual(model.pane(paneId)?.remoteSession, session, "session should be stored")
        try expectEqual(desiredPaneConfig(in: model)[paneId]?.theme, "Purplepeter")
    }

    test("remoteSessionReported applies remoteThemeOverride only on first transition") {
        var model = makeModel()
        model.config.remoteTheme = "Ocean"
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        _ = update(&model, .remoteSessionReported(paneId: paneId, session: RemoteSession(user: "dan", host: "caja")))
        try expectEqual(model.pane(paneId)?.remoteThemeOverride, "Ocean")
        try expectEqual(desiredPaneConfig(in: model)[paneId]?.theme, "Ocean")

        let secondEffects = update(&model, .remoteSessionReported(paneId: paneId, session: RemoteSession(user: "dan", host: "silverstone")))
        try expectEqual(model.pane(paneId)?.remoteThemeOverride, "Ocean")
        try expectEqual(secondEffects.count, 0, "remote-to-remote session update should not reapply theme")
    }

    test("remoteSessionReported with same session is no-op") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let session = RemoteSession(user: "dan", host: "caja")
        _ = update(&model, .remoteSessionReported(paneId: paneId, session: session))

        let commands = update(&model, .remoteSessionReported(paneId: paneId, session: session))
        try expectEqual(model.pane(paneId)?.remoteSession, session)
        try expectEqual(commands.count, 0, "unchanged session should produce no commands")
    }

    test("remoteSessionReported with different session updates without theme reapply") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .remoteSessionReported(paneId: paneId, session: RemoteSession(user: "dan", host: "caja")))
        let nextSession = RemoteSession(user: "root", host: "silverstone")

        let commands = update(&model, .remoteSessionReported(paneId: paneId, session: nextSession))
        try expectEqual(model.pane(paneId)?.remoteSession, nextSession)
        try expectEqual(commands.count, 0, "changed session while already remote should not reapply theme")
    }

    test("remoteSessionReported on missing pane returns empty commands") {
        var model = makeModel()
        let commands = update(&model, .remoteSessionReported(paneId: PaneId(), session: RemoteSession(user: "dan", host: "caja")))
        try expectEqual(commands.count, 0, "no commands for missing pane")
    }

    test("commandEnded clears isRemote and remoteThemeOverride") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.isRemote = true }
        model.updatePane(paneId) { $0.remoteSession = RemoteSession(user: "dan", host: "caja") }
        model.updatePane(paneId) { $0.remoteThemeOverride = "Purplepeter" }
        let commands = update(&model, .commandEnded(paneId: paneId))
        try expectEqual(model.pane(paneId)?.isRemote, false)
        try expectEqual(model.pane(paneId)?.remoteSession, nil, "remote session should be cleared")
        try expectEqual(model.pane(paneId)?.remoteThemeOverride, nil, "override should be cleared")
        try expect(desiredPaneConfig(in: model)[paneId] == nil, "cleared override without user theme -> no config key")
        try expectEqual(commands.count, 0)
    }

    test("commandEnded clears remoteSession too") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.isRemote = true }
        model.updatePane(paneId) { $0.remoteSession = RemoteSession(user: "dan", host: "caja") }
        let commands = update(&model, .commandEnded(paneId: paneId))
        try expectEqual(model.pane(paneId)?.isRemote, false)
        try expectEqual(model.pane(paneId)?.remoteSession, nil, "remote session should be cleared")
        try expectEqual(commands.count, 0, "no theme command when no override was set")
    }

    test("commandEnded on non-remote pane is no-op") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .commandEnded(paneId: paneId))
        try expectEqual(model.pane(paneId)?.isRemote, false, "pane should remain non-remote")
        try expectEqual(commands.count, 0, "no commands expected")
    }

    test("remoteSessionStarted on missing pane returns empty commands") {
        var model = makeModel()
        let fakePaneId = PaneId()
        let commands = update(&model, .remoteSessionStarted(paneId: fakePaneId))
        try expectEqual(commands.count, 0, "no commands for missing pane")
    }

    test("commandEnded on missing pane returns empty commands") {
        var model = makeModel()
        let fakePaneId = PaneId()
        let commands = update(&model, .commandEnded(paneId: fakePaneId))
        try expectEqual(commands.count, 0, "no commands for missing pane")
    }

    test("remote lifecycle: start then end restores theme") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.theme = "Dracula" }
        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        try expectEqual(model.pane(paneId)?.remoteThemeOverride, "Purplepeter")
        try expectEqual(model.pane(paneId)?.theme, "Dracula", "user theme preserved")

        _ = update(&model, .commandEnded(paneId: paneId))
        try expectEqual(model.pane(paneId)?.remoteThemeOverride, nil)
        try expectEqual(model.pane(paneId)?.theme, "Dracula", "user theme still there")
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
        try expectEqual(model.pane(paneId)?.theme, "Solarized", "user theme should change")
        try expectEqual(model.pane(paneId)?.remoteThemeOverride, "Purplepeter", "override unchanged")
    }

    // MARK: - configLoaded

    test("configLoaded updates model.config") {
        var model = makeModel()
        var newConfig = DanTermConfig()
        newConfig.remoteTheme = "Grape"
        let commands = update(&model, .configLoaded(newConfig))
        try expectEqual(model.config.remoteTheme, "Grape")
        try expectEqual(commands.count, 0)
    }

    test("configLoaded reapplies remote theme to remote panes") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        try expectEqual(model.pane(paneId)?.remoteThemeOverride, "Purplepeter")

        var newConfig = DanTermConfig()
        newConfig.remoteTheme = "Grape"
        let commands = update(&model, .configLoaded(newConfig))
        try expectEqual(model.pane(paneId)?.remoteThemeOverride, "Grape", "remote pane should get new theme")
        try expectEqual(desiredPaneConfig(in: model)[paneId]?.theme, "Grape")
        try expectEqual(commands.count, 0)
    }

    test("configLoaded with same config emits no commands") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .remoteSessionStarted(paneId: paneId))

        // Reload with same default config — no theme change
        let commands = update(&model, .configLoaded(DanTermConfig.default))
        try expectEqual(commands.count, 0)
    }

    // MARK: - setAlertClearMode (via pref draft + save)

    test("pref save alertClearMode updates model and emits save") {
        var model = makeModel()
        _ = update(&model, .preferencesOpened(ghostty: GhosttyPrefs()))
        _ = update(&model, .prefSetAlertClearMode(.manual))
        let commands = update(&model, .prefSave)
        try expectEqual(model.config.alertClearMode, .manual)
        try expect(hasEffect(commands) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "alert-clear-mode" && value == "manual"
            }
            return false
        }, "should emit saveDanTermConfigKey")
    }

    test("pref save alertClearMode with same value does not emit save key") {
        var model = makeModel()
        _ = update(&model, .preferencesOpened(ghostty: GhosttyPrefs()))
        // Don't change anything, so there is no persistence or theme side effect.
        let commands = update(&model, .prefSave)
        try expectEqual(commands.count, 0)
        try expect(!hasEffect(commands) {
            if case .saveDanTermConfigKey = $0 { return true }
            return false
        }, "should not emit saveDanTermConfigKey")
    }

    // MARK: - setRemoteTheme (via pref draft + save)

    test("pref save remoteTheme updates model and saves") {
        var model = makeModel()
        _ = update(&model, .preferencesOpened(ghostty: GhosttyPrefs()))
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let commands = update(&model, .prefSave)
        try expectEqual(model.config.remoteTheme, "Grape")
        try expect(hasEffect(commands) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "remote-theme" && value == "Grape"
            }
            return false
        }, "should emit saveDanTermConfigKey")
    }

    test("pref save remoteTheme updates remote panes") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .remoteSessionStarted(paneId: paneId))

        _ = update(&model, .preferencesOpened(ghostty: GhosttyPrefs()))
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let commands = update(&model, .prefSave)
        try expectEqual(model.pane(paneId)?.remoteThemeOverride, "Grape")
        try expectEqual(desiredPaneConfig(in: model)[paneId]?.theme, "Grape")
        try expect(hasEffect(commands) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "remote-theme" && value == "Grape"
            }
            return false
        }, "should save remote theme")
    }
}
