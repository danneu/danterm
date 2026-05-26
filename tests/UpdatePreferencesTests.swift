import Foundation

/// Default GhosttyPrefs used in tests (no theme or font-size override).
private let defaultGhostty = GhosttyPrefs(theme: nil, fontSize: nil)

/// Helper: open preferences with default Ghostty values.
private func openPrefs(_ model: inout AppModel, ghostty: GhosttyPrefs = defaultGhostty) -> [Effect] {
    update(&model, .preferencesOpened(ghostty: ghostty))
}

func preferencesTests() {
    print("Preferences Draft Tests...")

    // MARK: - Lifecycle

    test("preferencesOpened initializes draft from current config") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        model.config.remoteTheme = "Grape"
        let ghostty = GhosttyPrefs(theme: "Dracula", fontSize: "14")
        let effects = openPrefs(&model, ghostty: ghostty)
        try expectEqual(model.preferencesDraft?.alertClearMode, .manual)
        try expectEqual(model.preferencesDraft?.remoteTheme, "Grape")
        try expectEqual(model.preferencesDraft?.theme, "Dracula")
        try expectEqual(model.preferencesDraft?.fontSize, "14")
        try expectEqual(model.committedGhosttyPrefs, ghostty)
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    test("preferencesOpened when draft exists does not wipe it") {
        var model = makeModel()
        _ = openPrefs(&model)
        // Edit the draft.
        _ = update(&model, .prefSetAlertClearMode(.manual))
        try expectEqual(model.preferencesDraft?.alertClearMode, .manual)
        // Re-open: draft should be preserved.
        _ = openPrefs(&model)
        try expectEqual(model.preferencesDraft?.alertClearMode, .manual, "draft should not be wiped")
    }

    test("preferencesClosed clears draft and committedGhosttyPrefs") {
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))
        try expect(model.preferencesDraft != nil, "draft should exist")
        try expect(model.committedGhosttyPrefs != nil, "ghostty prefs should exist")
        let effects = update(&model, .preferencesClosed)
        try expect(model.preferencesDraft == nil, "draft should be nil")
        try expect(model.committedGhosttyPrefs == nil, "ghostty prefs should be nil")
        try expectEqual(effects.count, 0)
    }

    // MARK: - Editing draft

    test("prefSetAlertClearMode updates draft only, not model.config") {
        var model = makeModel()
        _ = openPrefs(&model)
        let effects = update(&model, .prefSetAlertClearMode(.manual))
        try expectEqual(model.preferencesDraft?.alertClearMode, .manual)
        try expectEqual(model.config.alertClearMode, .focus, "committed config should not change")
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    test("prefSetRemoteTheme stores raw text without normalizing") {
        var model = makeModel()
        _ = openPrefs(&model)
        let effects = update(&model, .prefSetRemoteTheme("  Grape  "))
        try expectEqual(model.preferencesDraft?.remoteTheme, "  Grape  ", "should store raw text")
        try expectEqual(model.config.remoteTheme, "Purplepeter", "committed config should not change")
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    test("prefSetRemoteTheme stores empty string without defaulting") {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme(""))
        try expectEqual(model.preferencesDraft?.remoteTheme, "", "should store empty string")
    }

    test("prefSetTheme updates draft") {
        var model = makeModel()
        _ = openPrefs(&model)
        let effects = update(&model, .prefSetTheme("Solarized"))
        try expectEqual(model.preferencesDraft?.theme, "Solarized")
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    test("prefSetTheme nil clears draft theme") {
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: nil))
        _ = update(&model, .prefSetTheme(nil))
        try expect(model.preferencesDraft?.theme == nil, "should be nil")
    }

    test("prefSetFontSize updates draft") {
        var model = makeModel()
        _ = openPrefs(&model)
        let effects = update(&model, .prefSetFontSize("16"))
        try expectEqual(model.preferencesDraft?.fontSize, "16")
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    // MARK: - Reset

    test("prefResetAlertClearMode reverts draft to committed") {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetAlertClearMode(.manual))
        try expectEqual(model.preferencesDraft?.alertClearMode, .manual)
        let effects = update(&model, .prefResetAlertClearMode)
        try expectEqual(model.preferencesDraft?.alertClearMode, .focus, "should revert to committed")
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    test("prefResetRemoteTheme reverts draft to committed") {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let effects = update(&model, .prefResetRemoteTheme)
        try expectEqual(model.preferencesDraft?.remoteTheme, "Purplepeter", "should revert to committed")
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    test("prefResetTheme reverts draft to committed Ghostty value") {
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: nil))
        _ = update(&model, .prefSetTheme("Solarized"))
        try expectEqual(model.preferencesDraft?.theme, "Solarized")
        let effects = update(&model, .prefResetTheme)
        try expectEqual(model.preferencesDraft?.theme, "Dracula", "should revert to committed")
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    test("prefResetFontSize reverts draft to committed Ghostty value") {
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: nil, fontSize: "14"))
        _ = update(&model, .prefSetFontSize("20"))
        let effects = update(&model, .prefResetFontSize)
        try expectEqual(model.preferencesDraft?.fontSize, "14", "should revert to committed")
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    // MARK: - Save

    test("prefSave with no changes emits only syncPreferencesPanel") {
        var model = makeModel()
        _ = openPrefs(&model)
        let effects = update(&model, .prefSave)
        try expectEqual(effects.count, 1)
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    test("prefSave with alertClearMode change emits saveDanTermConfigKey") {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetAlertClearMode(.manual))
        let effects = update(&model, .prefSave)
        try expectEqual(model.config.alertClearMode, .manual, "committed config should update")
        try expect(hasEffect(effects) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "alert-clear-mode" && value == "manual"
            }
            return false
        }, "should save alert-clear-mode")
    }

    test("prefSave with remoteTheme change emits saveDanTermConfigKey") {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let effects = update(&model, .prefSave)
        try expectEqual(model.config.remoteTheme, "Grape", "committed config should update")
        try expect(hasEffect(effects) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "remote-theme" && value == "Grape"
            }
            return false
        }, "should save remote-theme")
    }

    test("prefSave normalizes draft remoteTheme") {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("  Grape  "))
        _ = update(&model, .prefSave)
        try expectEqual(model.preferencesDraft?.remoteTheme, "Grape", "draft should be normalized post-save")
        try expectEqual(model.config.remoteTheme, "Grape")
    }

    test("prefSave with whitespace-only remoteTheme resolves to default") {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("   "))
        _ = update(&model, .prefSave)
        try expectEqual(model.config.remoteTheme, "Purplepeter", "should resolve to default")
        try expectEqual(model.preferencesDraft?.remoteTheme, "Purplepeter")
    }

    test("prefSave resets dirty state") {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetAlertClearMode(.manual))
        try expect(isDraftDirty(model.preferencesDraft!, vs: model.config, ghostty: model.committedGhosttyPrefs), "should be dirty before save")
        _ = update(&model, .prefSave)
        try expect(!isDraftDirty(model.preferencesDraft!, vs: model.config, ghostty: model.committedGhosttyPrefs), "should be clean after save")
    }

    test("prefSave with remoteTheme change updates remote panes") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .remoteSessionStarted(paneId: paneId))

        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let effects = update(&model, .prefSave)
        try expectEqual(model.pane(paneId)?.remoteThemeOverride, "Grape")
        try expect(hasEffect(effects) {
            if case .applyPaneTheme(let pid) = $0, pid == paneId { return true }
            return false
        }, "should emit applyPaneTheme for remote pane")
    }

    test("prefSave with theme change emits saveDanTermConfigKey and reloadGhosttyConfig") {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetTheme("Solarized"))
        let effects = update(&model, .prefSave)
        try expect(hasEffect(effects) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "theme" && value == "Solarized"
            }
            return false
        }, "should save theme key")
        try expect(hasEffect(effects) {
            if case .reloadGhosttyConfig = $0 { return true }
            return false
        }, "should emit reloadGhosttyConfig")
    }

    test("prefSave with cleared theme emits removeDanTermConfigKey") {
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: nil))
        _ = update(&model, .prefSetTheme(nil))
        let effects = update(&model, .prefSave)
        try expect(hasEffect(effects) {
            if case .removeDanTermConfigKey(let key) = $0 { return key == "theme" }
            return false
        }, "should remove theme key")
        try expect(hasEffect(effects) {
            if case .reloadGhosttyConfig = $0 { return true }
            return false
        }, "should emit reloadGhosttyConfig")
    }

    test("prefSave with valid fontSize emits saveDanTermConfigKey") {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetFontSize("16"))
        let effects = update(&model, .prefSave)
        try expect(hasEffect(effects) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "font-size" && value == "16"
            }
            return false
        }, "should save font-size key")
        try expect(hasEffect(effects) {
            if case .reloadGhosttyConfig = $0 { return true }
            return false
        }, "should emit reloadGhosttyConfig")
    }

    test("prefSave with invalid fontSize skips save and reload") {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetFontSize("abc"))
        let effects = update(&model, .prefSave)
        try expect(!hasEffect(effects) {
            if case .saveDanTermConfigKey(let key, _) = $0 { return key == "font-size" }
            return false
        }, "should not save invalid font-size")
        try expect(!hasEffect(effects) {
            if case .reloadGhosttyConfig = $0 { return true }
            return false
        }, "should not reload for invalid font-size")
    }

    test("prefSave with unchanged Ghostty keys does not emit reload") {
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))
        // Only change a DanTerm key.
        _ = update(&model, .prefSetAlertClearMode(.manual))
        let effects = update(&model, .prefSave)
        try expect(!hasEffect(effects) {
            if case .reloadGhosttyConfig = $0 { return true }
            return false
        }, "should not reload when Ghostty keys unchanged")
    }

    // MARK: - ghosttyPrefsRefreshed

    test("ghosttyPrefsRefreshed updates committed snapshot and resets draft") {
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))
        _ = update(&model, .prefSetTheme("Solarized"))
        try expectEqual(model.preferencesDraft?.theme, "Solarized")

        let newPrefs = GhosttyPrefs(theme: "Monokai", fontSize: "16")
        let effects = update(&model, .ghosttyPrefsRefreshed(newPrefs))
        try expectEqual(model.committedGhosttyPrefs, newPrefs)
        try expectEqual(model.preferencesDraft?.theme, "Monokai", "draft should reset to new committed")
        try expectEqual(model.preferencesDraft?.fontSize, "16", "draft should reset to new committed")
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    test("ghosttyPrefsRefreshed with no draft open just updates committed") {
        var model = makeModel()
        let prefs = GhosttyPrefs(theme: "Dracula", fontSize: "14")
        let effects = update(&model, .ghosttyPrefsRefreshed(prefs))
        try expectEqual(model.committedGhosttyPrefs, prefs)
        try expect(model.preferencesDraft == nil, "draft should remain nil")
        try expectEqual(effects.count, 0, "no sync needed when panel not open")
    }

    // MARK: - External reload

    test("configLoaded while panel open resets DanTerm draft fields only") {
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))
        _ = update(&model, .prefSetAlertClearMode(.manual))
        _ = update(&model, .prefSetTheme("Solarized"))

        var newConfig = DanTermConfig()
        newConfig.remoteTheme = "Ocean"
        _ = update(&model, .configLoaded(newConfig))
        try expectEqual(model.preferencesDraft?.alertClearMode, .focus, "DanTerm field should match new config")
        try expectEqual(model.preferencesDraft?.remoteTheme, "Ocean", "DanTerm field should match new config")
        // Ghostty fields preserved — ghosttyPrefsRefreshed handles those separately.
        try expectEqual(model.preferencesDraft?.theme, "Solarized", "Ghostty field should be preserved")
    }

    test("configLoaded while panel closed does not create draft") {
        var model = makeModel()
        _ = update(&model, .configLoaded(DanTermConfig.default))
        try expect(model.preferencesDraft == nil, "draft should remain nil")
    }

    // MARK: - No-ops when draft is nil

    test("pref messages are no-ops when draft is nil") {
        var model = makeModel()
        let e1 = update(&model, .prefSetAlertClearMode(.manual))
        try expectEqual(e1.count, 0)
        try expectEqual(model.config.alertClearMode, .focus, "should not change")

        let e2 = update(&model, .prefSetRemoteTheme("Grape"))
        try expectEqual(e2.count, 0)

        let e3 = update(&model, .prefResetAlertClearMode)
        try expectEqual(e3.count, 0)

        let e4 = update(&model, .prefResetRemoteTheme)
        try expectEqual(e4.count, 0)

        let e5 = update(&model, .prefSave)
        try expectEqual(e5.count, 0)

        let e6 = update(&model, .prefSetTheme("Dracula"))
        try expectEqual(e6.count, 0)

        let e7 = update(&model, .prefSetFontSize("14"))
        try expectEqual(e7.count, 0)

        let e8 = update(&model, .prefResetTheme)
        try expectEqual(e8.count, 0)

        let e9 = update(&model, .prefResetFontSize)
        try expectEqual(e9.count, 0)
    }

    // MARK: - Helper functions

    test("resolveRemoteTheme trims whitespace") {
        try expectEqual(resolveRemoteTheme("  Grape  "), "Grape")
    }

    test("resolveRemoteTheme defaults empty to Purplepeter") {
        try expectEqual(resolveRemoteTheme(""), "Purplepeter")
        try expectEqual(resolveRemoteTheme("   "), "Purplepeter")
    }

    test("isDraftDirty returns false when all fields match") {
        let config = DanTermConfig.default
        let ghostty = GhosttyPrefs(theme: nil, fontSize: nil)
        let draft = PreferencesDraft(alertClearMode: .focus, remoteTheme: "  Purplepeter  ", theme: nil, fontSize: nil)
        try expect(!isDraftDirty(draft, vs: config, ghostty: ghostty), "should not be dirty")
    }

    test("isDraftDirty returns true when alertClearMode differs") {
        let config = DanTermConfig.default
        let draft = PreferencesDraft(alertClearMode: .manual, remoteTheme: "Purplepeter", theme: nil, fontSize: nil)
        try expect(isDraftDirty(draft, vs: config, ghostty: defaultGhostty), "should be dirty")
    }

    test("isDraftDirty returns true when remoteTheme differs") {
        let config = DanTermConfig.default
        let draft = PreferencesDraft(alertClearMode: .focus, remoteTheme: "Grape", theme: nil, fontSize: nil)
        try expect(isDraftDirty(draft, vs: config, ghostty: defaultGhostty), "should be dirty")
    }

    test("isDraftDirty returns true when theme differs from Ghostty committed") {
        let config = DanTermConfig.default
        let ghostty = GhosttyPrefs(theme: "Dracula", fontSize: nil)
        let draft = PreferencesDraft(alertClearMode: .focus, remoteTheme: "Purplepeter", theme: "Solarized", fontSize: nil)
        try expect(isDraftDirty(draft, vs: config, ghostty: ghostty), "should be dirty")
    }

    test("isDraftDirty returns true when fontSize differs from Ghostty committed") {
        let config = DanTermConfig.default
        let ghostty = GhosttyPrefs(theme: nil, fontSize: "14")
        let draft = PreferencesDraft(alertClearMode: .focus, remoteTheme: "Purplepeter", theme: nil, fontSize: "16")
        try expect(isDraftDirty(draft, vs: config, ghostty: ghostty), "should be dirty")
    }
}
