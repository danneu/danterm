// Pins the preferences-draft Msg paths: panel lifecycle (preferencesOpened
// initializes the draft from the saved config without wiping an existing
// draft, preferencesClosed clears it), the desiredPreferencesPanel projection
// (the values and warnings the panel renders, plus invalid font-size
// persistence), edit operations (prefSet* preserve raw text for remoteTheme, do
// NOT mutate committed config), prefSave (one whole-document transaction,
// remote-theme propagation to live panes, theme + font-size ownership, and
// invalid font-size handling), configLoaded while open (resets only DanTerm
// fields), the no-op-when-draft-nil guards, and the resolveRemoteTheme helper.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

/// Open the panel against a config whose saved theme and font size are the given
/// values -- the committed side the draft is seeded from.
@discardableResult
private func openPrefs(
    _ model: inout AppModel,
    theme: String? = nil,
    fontSize: Double? = nil,
    availableThemeNames: [String] = []
) -> [Command] {
    model.config.defaultTheme = theme
    model.config.fontSize = fontSize
    return update(&model, .preferencesOpened(availableThemeNames: availableThemeNames))
}

@Suite struct UpdatePreferencesTests {
    // MARK: - Lifecycle

    @Test("preferencesOpened initializes draft from current config")
    func preferencesOpenedInitializesDraftFromCurrentConfig() {
        // Intent: opening prefs seeds every draft field from model.config.
        // Why it exists: pins the initial-state derivation.
        // Scenario: spec-first open.
        var model = makeModel()
        model.config.alertClearMode = .manual
        model.config.remoteTheme = "Grape"
        let commands = openPrefs(&model, theme: "Dracula", fontSize: 14)
        #expect(model.preferencesDraft?.alertClearMode == .manual)
        #expect(model.preferencesDraft?.remoteTheme == "Grape")
        #expect(model.preferencesDraft?.theme == "Dracula")
        #expect(model.preferencesDraft?.fontSize == "14", "saved size renders as field text")
        #expect(commands.count == 0)
    }

    @Test("preferencesOpened when draft exists does not wipe it")
    func preferencesOpenedWhenDraftExistsDoesNotWipe() {
        // Intent: re-opening prefs preserves an in-flight draft.
        // Why it exists: pins the no-wipe re-entry rule.
        // Scenario: spec-first preserve draft.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetAlertClearMode(.manual))
        #expect(model.preferencesDraft?.alertClearMode == .manual)
        _ = openPrefs(&model)
        #expect(model.preferencesDraft?.alertClearMode == .manual, "draft should not be wiped")
    }

    @Test("preferencesClosed clears the draft")
    func preferencesClosedClearsDraft() {
        // Intent: closing prefs nils the draft.
        // Why it exists: pins the close-side cleanup.
        // Scenario: spec-first close.
        var model = makeModel()
        _ = openPrefs(&model, theme: "Dracula", fontSize: 14)
        #expect(model.preferencesDraft != nil, "draft should exist")
        let commands = update(&model, .preferencesClosed)
        #expect(model.preferencesDraft == nil, "draft should be nil")
        #expect(desiredPreferencesPanel(in: model) == nil, "closed panel projects nothing")
        #expect(commands.count == 0)
    }

    // MARK: - Preferences panel projection

    @Test("desiredPreferencesPanel returns nil when no draft is open")
    func desiredPreferencesPanelNilWhenClosed() {
        // Intent: closed prefs project nil (no panel).
        // Why it exists: pins the closed-state projection.
        // Scenario: spec-first closed projection.
        let model = makeModel()
        #expect(desiredPreferencesPanel(in: model) == nil, "closed preferences should not project UI")
    }

    @Test("a freshly seeded draft renders the committed values")
    func freshlySeededDraftRendersCommittedValues() throws {
        var model = makeModel()
        model.config.alertClearMode = .manual
        model.config.remoteTheme = "Grape"
        _ = openPrefs(&model, theme: "Dracula", fontSize: 14)

        let projection = try #require(desiredPreferencesPanel(in: model), "expected preferences projection")
        #expect(projection.selectedAlertClearMode == .manual)
        #expect(projection.remoteThemeText == "Grape")
        #expect(projection.themeText == "Dracula")
        #expect(projection.fontSizeText == "14")
    }

    @Test("unavailable configured themes report the dark fallback")
    func unavailableConfiguredThemesReportFallback() throws {
        // Intent: picker-only theme fields explain invalid values that arrived
        //   through a hand-edited config file.
        // Why it exists: both render paths recover to the built-in dark theme;
        //   without this warning the displayed name appears to have taken effect.
        // Scenario: the config names unavailable local and remote themes before
        //   Settings opens against the bundled catalog.
        var model = makeModel()
        model.config.remoteTheme = "Missing Remote"
        _ = openPrefs(&model, theme: "Missing Local", availableThemeNames: ["Known"])

        let projection = try #require(desiredPreferencesPanel(in: model))
        #expect(projection.themeWarning
            == "Theme \"Missing Local\" is not available -- using the built-in dark theme.")
        #expect(projection.remoteThemeWarning
            == "Theme \"Missing Remote\" is not available -- using the built-in dark theme.")
    }

    @Test("available configured themes carry no warning")
    func availableConfiguredThemesCarryNoWarning() throws {
        var model = makeModel()
        model.config.remoteTheme = "Remote"
        _ = openPrefs(&model, theme: "Local", availableThemeNames: ["Local", "Remote"])

        let projection = try #require(desiredPreferencesPanel(in: model))
        #expect(projection.themeWarning == nil)
        #expect(projection.remoteThemeWarning == nil)
    }

    @Test("the remote theme field renders the raw draft text")
    func remoteThemeFieldRendersRawDraftText() throws {
        // Intent: the projection hands the panel exactly what the draft holds,
        //   whitespace included.
        // Why it exists: normalizing on render would rewrite the field under a
        //   user who is still typing; the trim belongs to save.
        // Scenario: spec-first -- type a padded name that trims to the committed
        //   one.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("  Purplepeter  "))

        let projection = try #require(desiredPreferencesPanel(in: model), "expected preferences projection")
        #expect(projection.remoteThemeText == "  Purplepeter  ", "field keeps raw draft text")
    }

    @Test("an untouched panel shows the saved theme and font size")
    func untouchedPanelShowsSavedConfig() throws {
        // Intent: opening the panel on a config that sets a theme and a font size
        //   shows those values, for both a whole and a fractional size.
        // Why it exists: the field holds text while the config holds a number, so
        //   a mismatch in how the number is rendered would show the user a size
        //   they never chose.
        // Scenario: spec-first -- open the panel, touch nothing.
        for (size, text) in [(13.0, "13"), (13.5, "13.5")] {
            var model = makeModel()
            _ = openPrefs(&model, theme: "Dracula", fontSize: size)

            let projection = try #require(desiredPreferencesPanel(in: model), "expected projection")
            #expect(projection.themeText == "Dracula")
            #expect(projection.fontSizeText == text, "rendered text for \(size)")
        }
    }

    @Test("an external config reload re-seeds the open panel's fields")
    func externalConfigReloadReseedsOpenPanel() throws {
        // Intent: a config reload while the panel is open replaces the draft's
        //   fields with the reloaded values, discarding the pending edit.
        // Why it exists: a draft that kept the stale edit would show a setting
        //   the config no longer holds, and would write it back on the next save.
        // Scenario: spec-first -- edit the theme, then the config file changes.
        var model = makeModel()
        _ = openPrefs(&model, theme: "Dracula", fontSize: 13)
        _ = update(&model, .prefSetTheme("Solarized"))

        var reloaded = DanTermConfig.default
        reloaded.defaultTheme = "Nord"
        reloaded.fontSize = 15
        _ = update(&model, .configLoaded(reloaded, resolvedFontFamily: nil))

        let projection = try #require(desiredPreferencesPanel(in: model), "expected projection")
        #expect(projection.themeText == "Nord")
        #expect(projection.fontSizeText == "15")
    }

    @Test("an invalid font size is not saved and stays in the field")
    func invalidFontSizeIsNotSavedAndStaysInField() throws {
        // Intent: an unparseable font size emits no save command and the text
        //   the user typed stays on screen.
        // Why it exists: pins the validation-skip rule -- the field is the only
        //   place that text lives, so clearing it would lose the user's input.
        // Scenario: spec-first invalid font save.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetFontSize("abc"))
        let commands = update(&model, .prefSave)

        let projection = try #require(desiredPreferencesPanel(in: model), "expected preferences projection")
        #expect(commands.count == 0)
        #expect(projection.fontSizeText == "abc")
        #expect(model.config.fontSize == nil, "the committed size is untouched")
    }

    // MARK: - Editing draft

    @Test("prefSetAlertClearMode updates draft only, not model.config")
    func prefSetAlertClearModeUpdatesDraftOnly() {
        // Intent: prefSetAlertClearMode writes the draft only; committed
        //   config is unchanged.
        // Why it exists: pins the draft-isolation rule.
        // Scenario: spec-first draft-only.
        var model = makeModel()
        _ = openPrefs(&model)
        let commands = update(&model, .prefSetAlertClearMode(.manual))
        #expect(model.preferencesDraft?.alertClearMode == .manual)
        #expect(model.config.alertClearMode == .focus, "committed config should not change")
        #expect(commands.count == 0)
    }

    @Test("prefSetRemoteTheme stores raw text without normalizing")
    func prefSetRemoteThemeStoresRawText() {
        // Intent: prefSetRemoteTheme stores the raw string (no trim).
        // Why it exists: pins the raw-text storage so the editor preserves
        //   user input including whitespace.
        // Scenario: spec-first raw text.
        var model = makeModel()
        _ = openPrefs(&model)
        let commands = update(&model, .prefSetRemoteTheme("  Grape  "))
        #expect(model.preferencesDraft?.remoteTheme == "  Grape  ", "should store raw text")
        #expect(model.config.remoteTheme == "Purplepeter", "committed config should not change")
        #expect(commands.count == 0)
    }

    @Test("prefSetRemoteTheme stores empty string without defaulting")
    func prefSetRemoteThemeStoresEmptyString() {
        // Intent: an empty string is stored as-is in the draft (defaulting
        //   happens later on save).
        // Why it exists: pins the no-default-on-set rule.
        // Scenario: spec-first empty store.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme(""))
        #expect(model.preferencesDraft?.remoteTheme == "", "should store empty string")
    }

    @Test("prefSetTheme updates draft")
    func prefSetThemeUpdatesDraft() {
        // Intent: prefSetTheme writes the draft theme.
        // Why it exists: pins the bare write.
        // Scenario: spec-first set theme.
        var model = makeModel()
        _ = openPrefs(&model)
        let commands = update(&model, .prefSetTheme("Solarized"))
        #expect(model.preferencesDraft?.theme == "Solarized")
        #expect(commands.count == 0)
    }

    @Test("prefSetTheme nil clears draft theme")
    func prefSetThemeNilClearsDraftTheme() {
        // Intent: prefSetTheme(nil) clears the draft theme.
        // Why it exists: pins the explicit-clear branch.
        // Scenario: spec-first clear theme.
        var model = makeModel()
        _ = openPrefs(&model, theme: "Dracula")
        _ = update(&model, .prefSetTheme(nil))
        #expect(model.preferencesDraft?.theme == nil, "should be nil")
    }

    @Test("prefSetFontSize updates draft")
    func prefSetFontSizeUpdatesDraft() {
        // Intent: prefSetFontSize writes the draft fontSize.
        // Why it exists: pins the bare write.
        // Scenario: spec-first set font size.
        var model = makeModel()
        _ = openPrefs(&model)
        let commands = update(&model, .prefSetFontSize("16"))
        #expect(model.preferencesDraft?.fontSize == "16")
        #expect(commands.count == 0)
    }

    // MARK: - Save

    @Test("prefSave applies every valid field and emits one JSON transaction")
    func prefSaveAppliesEveryFieldInOneTransaction() {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetTheme("Dracula"))
        _ = update(&model, .prefSetFontSize("17.5"))
        _ = update(&model, .prefSetAlertClearMode(.manual))
        _ = update(&model, .prefSetRemoteTheme("Grape"))

        let commands = update(&model, .prefSave)

        #expect(model.config == DanTermConfig(
            defaultTheme: "Dracula",
            remoteTheme: "Grape",
            fontSize: 17.5,
            alertClearMode: .manual
        ))
        #expect(commands.count == 1)
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config == model.config }
            return false
        })
        #expect(
            desiredPreferencesPanel(in: model)?.fontSizeText == "17.5",
            "the field echoes back the number the size was parsed into"
        )
    }

    @Test("an invalid font size does not block the other fields from saving")
    func invalidFontSizeDoesNotBlockOtherFields() {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetFontSize("nan"))
        _ = update(&model, .prefSetAlertClearMode(.manual))

        let commands = update(&model, .prefSave)

        #expect(model.config.alertClearMode == .manual)
        #expect(model.config.fontSize == nil)
        #expect(commands.count == 1)
        #expect(model.preferencesDraft?.fontSize == "nan", "the unparseable text stays in the field")
    }

    @Test("prefSave with no changes emits no commands")
    func prefSaveWithNoChangesEmitsNoCommands() {
        // Intent: a save on a clean draft emits no commands.
        // Why it exists: pins the no-op-on-clean rule.
        // Scenario: spec-first clean save.
        var model = makeModel()
        _ = openPrefs(&model)
        let commands = update(&model, .prefSave)
        #expect(commands.count == 0)
    }

    @Test("prefSave with alertClearMode change emits one config transaction")
    func prefSaveWithAlertClearModeChangeEmitsKey() {
        // Intent: a dirty alert mode emits a whole-document save and
        //   updates model.config.
        // Why it exists: pins the alert-mode save path.
        // Scenario: spec-first save alert mode.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetAlertClearMode(.manual))
        let commands = update(&model, .prefSave)
        #expect(model.config.alertClearMode == .manual, "committed config should update")
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config.alertClearMode == .manual }
            return false
        }, "should save alert-clear-mode")
    }

    @Test("prefSave with remoteTheme change emits one config transaction")
    func prefSaveWithRemoteThemeChangeEmitsKey() {
        // Intent: a dirty remote theme emits a whole-document save and
        //   updates model.config.
        // Why it exists: pins the remote-theme save path.
        // Scenario: spec-first save remote theme.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let commands = update(&model, .prefSave)
        #expect(model.config.remoteTheme == "Grape", "committed config should update")
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config.remoteTheme == "Grape" }
            return false
        }, "should save remote-theme")
    }

    @Test("prefSave normalizes draft remoteTheme")
    func prefSaveNormalizesDraftRemoteTheme() {
        // Intent: save trims whitespace in the draft and committed
        //   config.
        // Why it exists: pins the on-save trim.
        // Scenario: spec-first save trim.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("  Grape  "))
        _ = update(&model, .prefSave)
        #expect(model.preferencesDraft?.remoteTheme == "Grape", "draft should be normalized post-save")
        #expect(model.config.remoteTheme == "Grape")
    }

    @Test("prefSave with whitespace-only remoteTheme resolves to default")
    func prefSaveWhitespaceOnlyRemoteThemeResolvesToDefault() {
        // Intent: save resolves a whitespace-only draft to the default
        //   "Purplepeter".
        // Why it exists: pins the empty -> default rule on save.
        // Scenario: spec-first save default.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("   "))
        _ = update(&model, .prefSave)
        #expect(model.config.remoteTheme == "Purplepeter", "should resolve to default")
        #expect(model.preferencesDraft?.remoteTheme == "Purplepeter")
    }

    @Test("a second save with no further edit emits no command")
    func secondSaveWithNoFurtherEditEmitsNoCommand() {
        // Intent: once an edit is committed, saving again writes nothing.
        // Why it exists: every control change sends prefSave, so a save that
        //   could not tell the committed config from the draft would rewrite the
        //   config file on each repeat.
        // Scenario: spec-first -- edit the alert mode, save, then save again.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetAlertClearMode(.manual))
        #expect(update(&model, .prefSave).count == 1, "the edit is committed")
        #expect(update(&model, .prefSave).count == 0, "nothing left to write")
    }

    @Test("prefSave with remoteTheme change updates the remote pane projection")
    func prefSaveWithRemoteThemeChangeUpdatesRemoteProjection() {
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let sessionId = model.pane(paneId)!.session!.id
        update(&model, .sessionReport(
            sessionId: sessionId,
            report: .connectionDeclared(.remote(identity: nil))
        ))
        let paneBefore = model.pane(paneId)

        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let commands = update(&model, .prefSave)
        #expect(model.pane(paneId) == paneBefore)
        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Grape")
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config.remoteTheme == "Grape" }
            return false
        }, "should save remote theme")
    }

    @Test("prefSave with theme change emits one config transaction")
    func prefSaveWithThemeChangeEmitsKeyAndReload() {
        // Intent: a local theme change enters the single JSON transaction.
        // Why it exists: pins theme ownership at the DanTerm document boundary.
        // Scenario: spec-first save local theme.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetTheme("Solarized"))
        let commands = update(&model, .prefSave)
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config.defaultTheme == "Solarized" }
            return false
        }, "should save theme key")
    }

    @Test("prefSave with cleared theme removes the JSON setting")
    func prefSaveWithClearedThemeEmitsRemoveKey() {
        // Intent: clearing the local theme removes it through the JSON transaction.
        // Why it exists: pins absent-key default semantics.
        // Scenario: spec-first clear local theme.
        var model = makeModel()
        model.config.defaultTheme = "Dracula"
        _ = openPrefs(&model, theme: "Dracula")
        _ = update(&model, .prefSetTheme(nil))
        let commands = update(&model, .prefSave)
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config.defaultTheme == nil }
            return false
        }, "should clear default theme")
    }

    @Test("prefSave with valid fontSize emits one config transaction")
    func prefSaveWithValidFontSizeEmitsKey() {
        // Intent: a valid font size enters the single JSON transaction.
        // Why it exists: pins the font-size save path.
        // Scenario: spec-first save font size.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetFontSize("16"))
        let commands = update(&model, .prefSave)
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config.fontSize == 16 }
            return false
        }, "should save font-size key")
    }

    @Test("prefSave with invalid fontSize skips save and reload")
    func prefSaveWithInvalidFontSizeSkipsSave() {
        // Intent: an invalid font size emits NO save key, NO reload.
        // Why it exists: pins the validation-skip rule on save.
        // Scenario: spec-first invalid font save skip.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetFontSize("abc"))
        let commands = update(&model, .prefSave)
        #expect(commands.count == 0)
        #expect(!hasEffect(commands) {
            if case .saveDanTermConfig = $0 { return true }
            return false
        }, "should not save invalid font-size")
    }

    // MARK: - External reload

    @Test("configLoaded while panel open resets all JSON-backed draft fields")
    func configLoadedWhilePanelOpenResetsAllFields() {
        // Intent: configLoaded while open resets every JSON-backed field in the draft.
        // Why it exists: theme and font moved from Ghostty preferences into DanTerm JSON.
        // Scenario: spec-first configLoaded scope.
        var model = makeModel()
        _ = openPrefs(&model, theme: "Dracula", fontSize: 14)
        _ = update(&model, .prefSetAlertClearMode(.manual))
        _ = update(&model, .prefSetTheme("Solarized"))

        var newConfig = DanTermConfig()
        newConfig.remoteTheme = "Ocean"
        newConfig.defaultTheme = "Monokai"
        newConfig.fontSize = 18
        _ = update(&model, .configLoaded(newConfig, resolvedFontFamily: nil))
        #expect(model.preferencesDraft?.alertClearMode == .focus, "DanTerm field should match new config")
        #expect(model.preferencesDraft?.remoteTheme == "Ocean", "DanTerm field should match new config")
        #expect(model.preferencesDraft?.theme == "Monokai")
        #expect(model.preferencesDraft?.fontSize == "18")
    }

    @Test("configLoaded while panel closed does not create draft")
    func configLoadedWhilePanelClosedDoesNotCreateDraft() {
        // Intent: configLoaded does not create a draft when prefs are
        //   closed.
        // Why it exists: pins the no-implicit-open rule.
        // Scenario: spec-first closed configLoaded.
        var model = makeModel()
        _ = update(&model, .configLoaded(DanTermConfig.default, resolvedFontFamily: nil))
        #expect(model.preferencesDraft == nil, "draft should remain nil")
    }

    // MARK: - No-ops when draft is nil

    @Test("pref messages are no-ops when draft is nil")
    func prefMessagesAreNoOpsWhenDraftIsNil() {
        // Intent: every pref* message is a no-op when no draft exists.
        // Why it exists: pins the closed-state safety net for the entire
        //   draft Msg surface.
        // Scenario: spec-first all-no-ops.
        var model = makeModel()
        let e1 = update(&model, .prefSetAlertClearMode(.manual))
        #expect(e1.count == 0)
        #expect(model.config.alertClearMode == .focus, "should not change")

        let e2 = update(&model, .prefSetRemoteTheme("Grape"))
        #expect(e2.count == 0)

        let e3 = update(&model, .prefSave)
        #expect(e3.count == 0)

        let e4 = update(&model, .prefSetTheme("Dracula"))
        #expect(e4.count == 0)

        let e5 = update(&model, .prefSetFontSize("14"))
        #expect(e5.count == 0)
    }

    // MARK: - Helper functions

    @Test("resolveRemoteTheme trims whitespace")
    func resolveRemoteThemeTrimsWhitespace() {
        // Intent: resolveRemoteTheme trims whitespace.
        // Why it exists: pins the trim helper.
        // Scenario: spec-first trim.
        #expect(resolveRemoteTheme("  Grape  ") == "Grape")
    }

    @Test("resolveRemoteTheme defaults empty to Purplepeter")
    func resolveRemoteThemeDefaultsEmptyToPurplepeter() {
        // Intent: resolveRemoteTheme returns "Purplepeter" for empty /
        //   whitespace-only input.
        // Why it exists: pins the default-name fallback.
        // Scenario: spec-first default fallback.
        #expect(resolveRemoteTheme("") == "Purplepeter")
        #expect(resolveRemoteTheme("   ") == "Purplepeter")
    }
}
