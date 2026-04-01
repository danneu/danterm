import Foundation

func preferencesTests() {
    print("Preferences Draft Tests...")

    // MARK: - Lifecycle

    test("preferencesOpened initializes draft from current config") {
        var model = makeModel()
        model.config.alertClearMode = .manual
        model.config.remoteTheme = "Grape"
        let effects = update(&model, .preferencesOpened)
        try expectEqual(model.preferencesDraft?.alertClearMode, .manual)
        try expectEqual(model.preferencesDraft?.remoteTheme, "Grape")
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    test("preferencesOpened when draft exists does not wipe it") {
        var model = makeModel()
        _ = update(&model, .preferencesOpened)
        // Edit the draft.
        _ = update(&model, .prefSetAlertClearMode(.manual))
        try expectEqual(model.preferencesDraft?.alertClearMode, .manual)
        // Re-open: draft should be preserved.
        _ = update(&model, .preferencesOpened)
        try expectEqual(model.preferencesDraft?.alertClearMode, .manual, "draft should not be wiped")
    }

    test("preferencesClosed clears draft") {
        var model = makeModel()
        _ = update(&model, .preferencesOpened)
        try expect(model.preferencesDraft != nil, "draft should exist")
        let effects = update(&model, .preferencesClosed)
        try expect(model.preferencesDraft == nil, "draft should be nil")
        try expectEqual(effects.count, 0)
    }

    // MARK: - Editing draft

    test("prefSetAlertClearMode updates draft only, not model.config") {
        var model = makeModel()
        _ = update(&model, .preferencesOpened)
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
        _ = update(&model, .preferencesOpened)
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
        _ = update(&model, .preferencesOpened)
        _ = update(&model, .prefSetRemoteTheme(""))
        try expectEqual(model.preferencesDraft?.remoteTheme, "", "should store empty string")
    }

    // MARK: - Reset

    test("prefResetAlertClearMode reverts draft to committed") {
        var model = makeModel()
        _ = update(&model, .preferencesOpened)
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
        _ = update(&model, .preferencesOpened)
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let effects = update(&model, .prefResetRemoteTheme)
        try expectEqual(model.preferencesDraft?.remoteTheme, "Purplepeter", "should revert to committed")
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    // MARK: - Save

    test("prefSave with no changes emits only syncPreferencesPanel") {
        var model = makeModel()
        _ = update(&model, .preferencesOpened)
        let effects = update(&model, .prefSave)
        try expectEqual(effects.count, 1)
        try expect(hasEffect(effects) {
            if case .syncPreferencesPanel = $0 { return true }
            return false
        }, "should emit syncPreferencesPanel")
    }

    test("prefSave with alertClearMode change emits saveDanTermConfigKey") {
        var model = makeModel()
        _ = update(&model, .preferencesOpened)
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
        _ = update(&model, .preferencesOpened)
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
        _ = update(&model, .preferencesOpened)
        _ = update(&model, .prefSetRemoteTheme("  Grape  "))
        _ = update(&model, .prefSave)
        try expectEqual(model.preferencesDraft?.remoteTheme, "Grape", "draft should be normalized post-save")
        try expectEqual(model.config.remoteTheme, "Grape")
    }

    test("prefSave with whitespace-only remoteTheme resolves to default") {
        var model = makeModel()
        _ = update(&model, .preferencesOpened)
        _ = update(&model, .prefSetRemoteTheme("   "))
        _ = update(&model, .prefSave)
        try expectEqual(model.config.remoteTheme, "Purplepeter", "should resolve to default")
        try expectEqual(model.preferencesDraft?.remoteTheme, "Purplepeter")
    }

    test("prefSave resets dirty state") {
        var model = makeModel()
        _ = update(&model, .preferencesOpened)
        _ = update(&model, .prefSetAlertClearMode(.manual))
        try expect(isDraftDirty(model.preferencesDraft!, vs: model.config), "should be dirty before save")
        _ = update(&model, .prefSave)
        try expect(!isDraftDirty(model.preferencesDraft!, vs: model.config), "should be clean after save")
    }

    test("prefSave with remoteTheme change updates remote panes") {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .remoteSessionStarted(paneId: paneId))

        _ = update(&model, .preferencesOpened)
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let effects = update(&model, .prefSave)
        try expectEqual(model.panes[paneId]?.remoteThemeOverride, "Grape")
        try expect(hasEffect(effects) {
            if case .applyPaneTheme(let pid) = $0, pid == paneId { return true }
            return false
        }, "should emit applyPaneTheme for remote pane")
    }

    // MARK: - External reload

    test("configLoaded while panel open resets draft to new config") {
        var model = makeModel()
        _ = update(&model, .preferencesOpened)
        _ = update(&model, .prefSetAlertClearMode(.manual))

        var newConfig = DanTermConfig()
        newConfig.remoteTheme = "Ocean"
        _ = update(&model, .configLoaded(newConfig))
        try expectEqual(model.preferencesDraft?.alertClearMode, .focus, "draft should match new config")
        try expectEqual(model.preferencesDraft?.remoteTheme, "Ocean", "draft should match new config")
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
    }

    // MARK: - Helper functions

    test("resolveRemoteTheme trims whitespace") {
        try expectEqual(resolveRemoteTheme("  Grape  "), "Grape")
    }

    test("resolveRemoteTheme defaults empty to Purplepeter") {
        try expectEqual(resolveRemoteTheme(""), "Purplepeter")
        try expectEqual(resolveRemoteTheme("   "), "Purplepeter")
    }

    test("isDraftDirty returns false when raw resolves to same value") {
        let config = DanTermConfig.default
        let draft = PreferencesDraft(alertClearMode: .focus, remoteTheme: "  Purplepeter  ")
        try expect(!isDraftDirty(draft, vs: config), "should not be dirty")
    }

    test("isDraftDirty returns true when alertClearMode differs") {
        let config = DanTermConfig.default
        let draft = PreferencesDraft(alertClearMode: .manual, remoteTheme: "Purplepeter")
        try expect(isDraftDirty(draft, vs: config), "should be dirty")
    }

    test("isDraftDirty returns true when remoteTheme differs") {
        let config = DanTermConfig.default
        let draft = PreferencesDraft(alertClearMode: .focus, remoteTheme: "Grape")
        try expect(isDraftDirty(draft, vs: config), "should be dirty")
    }
}
