// Pins the preferences-draft Msg paths: panel lifecycle (preferencesOpened
// initializes the draft from the saved config without wiping an existing
// draft, preferencesClosed clears it), the desiredPreferencesPanel projection
// (the values and warnings the panel renders, plus invalid font-size
// persistence), edit operations (prefSet preserves raw text for remoteTheme, does
// NOT mutate committed config), prefSave (one whole-document transaction,
// remote-theme propagation to live panes, theme + font-size ownership, and
// invalid font-size handling), configLoaded while open (re-seeds the draft from
// the reloaded config, including the settings the panel cannot edit), the
// no-op-when-draft-nil guards, and the resolveRemoteTheme helper.
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
        #expect(model.preferencesDraft?.config.alertClearMode == .manual)
        #expect(model.preferencesDraft?.config.remoteTheme == "Grape")
        #expect(model.preferencesDraft?.config.defaultTheme == "Dracula")
        #expect(model.preferencesDraft?.fontSizeText == "14", "saved size renders as field text")
        #expect(commands.count == 0)
    }

    @Test("preferencesOpened when draft exists does not wipe it")
    func preferencesOpenedWhenDraftExistsDoesNotWipe() {
        // Intent: re-opening prefs preserves an in-flight draft.
        // Why it exists: pins the no-wipe re-entry rule.
        // Scenario: spec-first preserve draft.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSet(.alertClearMode(.manual)))
        #expect(model.preferencesDraft?.config.alertClearMode == .manual)
        _ = openPrefs(&model)
        #expect(model.preferencesDraft?.config.alertClearMode == .manual, "draft should not be wiped")
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
        _ = update(&model, .prefSet(.remoteTheme("  Purplepeter  ")))

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
        _ = update(&model, .prefSet(.theme("Solarized")))

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
        _ = openPrefs(&model, fontSize: 16)
        _ = update(&model, .prefSet(.fontSize("abc")))
        let commands = update(&model, .prefSave)

        let projection = try #require(desiredPreferencesPanel(in: model), "expected preferences projection")
        #expect(commands.count == 0)
        #expect(projection.fontSizeText == "abc")
        #expect(model.config.fontSize == 16, "the committed size is untouched")
    }

    @Test("blank font-size text removes the configured size")
    func blankFontSizeTextRemovesConfiguredSize() throws {
        // Intent: empty and whitespace-only drafts both remove `font.size` and
        //   normalize the visible field to empty text.
        // Why it exists: the core owns the blank-means-no-key rule, including
        //   text that AppKit previously forwarded without normalizing.
        // Scenario: spec-first -- clear a configured size with each blank form.
        for text in ["", "  "] {
            var model = makeModel()
            _ = openPrefs(&model, fontSize: 16)
            _ = update(&model, .prefSet(.fontSize(text)))

            let commands = update(&model, .prefSave)
            let projection = try #require(desiredPreferencesPanel(in: model))

            #expect(model.config.fontSize == nil)
            #expect(projection.fontSizeText == "")
            #expect(hasEffect(commands) {
                if case .saveDanTermConfig(let config) = $0 { return config.fontSize == nil }
                return false
            })
        }
    }

    @Test("font-size projection resolves the stepper value in the core")
    func fontSizeProjectionResolvesStepperValueInCore() throws {
        // Intent: the projection supplies the bounded value that the stepper
        //   renders, while it preserves the raw field text.
        // Why it exists: AppKit must not restate the draft parse or fallback.
        // Scenario: spec-first valid, blank, and invalid drafts.
        var model = makeModel()
        _ = openPrefs(&model, fontSize: 16)

        for (text, expected) in [
            ("200", DanTermConfig.fontSizeRange.upperBound),
            ("", DanTermConfig.default.resolvedFontSize),
            ("abc", DanTermConfig.default.resolvedFontSize),
        ] {
            _ = update(&model, .prefSet(.fontSize(text)))
            let projection = try #require(desiredPreferencesPanel(in: model))
            #expect(projection.fontSizeText == text)
            #expect(projection.fontSizeStepperValue == expected)
        }
    }

    // MARK: - Editing draft

    @Test(".prefSet(.alertClearMode) updates draft only, not model.config")
    func alertClearModeEditUpdatesDraftOnly() {
        // Intent: .prefSet(.alertClearMode) writes the draft only; committed
        //   config is unchanged.
        // Why it exists: pins the draft-isolation rule.
        // Scenario: spec-first draft-only.
        var model = makeModel()
        _ = openPrefs(&model)
        let commands = update(&model, .prefSet(.alertClearMode(.manual)))
        #expect(model.preferencesDraft?.config.alertClearMode == .manual)
        #expect(model.config.alertClearMode == .focus, "committed config should not change")
        #expect(commands.count == 0)
    }

    @Test(".prefSet(.remoteTheme) stores raw text without normalizing")
    func remoteThemeEditStoresRawText() {
        // Intent: .prefSet(.remoteTheme) stores the raw string (no trim).
        // Why it exists: pins the raw-text storage so the editor preserves
        //   user input including whitespace.
        // Scenario: spec-first raw text.
        var model = makeModel()
        _ = openPrefs(&model)
        let commands = update(&model, .prefSet(.remoteTheme("  Grape  ")))
        #expect(model.preferencesDraft?.config.remoteTheme == "  Grape  ", "should store raw text")
        #expect(model.config.remoteTheme == "Purplepeter", "committed config should not change")
        #expect(commands.count == 0)
    }

    @Test(".prefSet(.remoteTheme) stores empty string without defaulting")
    func remoteThemeEditStoresEmptyString() {
        // Intent: an empty string is stored as-is in the draft (defaulting
        //   happens later on save).
        // Why it exists: pins the no-default-on-set rule.
        // Scenario: spec-first empty store.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSet(.remoteTheme("")))
        #expect(model.preferencesDraft?.config.remoteTheme == "", "should store empty string")
    }

    @Test(".prefSet(.theme) updates draft")
    func themeEditUpdatesDraft() {
        // Intent: .prefSet(.theme) writes the draft theme.
        // Why it exists: pins the bare write.
        // Scenario: spec-first set theme.
        var model = makeModel()
        _ = openPrefs(&model)
        let commands = update(&model, .prefSet(.theme("Solarized")))
        #expect(model.preferencesDraft?.config.defaultTheme == "Solarized")
        #expect(commands.count == 0)
    }

    @Test(".prefSet(.theme) nil clears draft theme")
    func themeEditNilClearsDraftTheme() {
        // Intent: .prefSet(.theme(nil)) clears the draft theme.
        // Why it exists: pins the explicit-clear branch.
        // Scenario: spec-first clear theme.
        var model = makeModel()
        _ = openPrefs(&model, theme: "Dracula")
        _ = update(&model, .prefSet(.theme(nil)))
        #expect(model.preferencesDraft?.config.defaultTheme == nil, "should be nil")
    }

    @Test(".prefSet(.fontSize) updates draft")
    func fontSizeEditUpdatesDraft() {
        // Intent: .prefSet(.fontSize) writes the draft fontSize.
        // Why it exists: pins the bare write.
        // Scenario: spec-first set font size.
        var model = makeModel()
        _ = openPrefs(&model)
        let commands = update(&model, .prefSet(.fontSize("16")))
        #expect(model.preferencesDraft?.fontSizeText == "16")
        #expect(commands.count == 0)
    }

    // MARK: - Save

    @Test("prefSave applies every valid field and emits one JSON transaction")
    func prefSaveAppliesEveryFieldInOneTransaction() {
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSet(.theme("Dracula")))
        _ = update(&model, .prefSet(.fontSize("17.5")))
        _ = update(&model, .prefSet(.alertClearMode(.manual)))
        _ = update(&model, .prefSet(.remoteTheme("Grape")))

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
        // The committed size is the one half of the draft's font-size split that
        // survives text that will not parse, so the save has to start from a
        // config that names one.
        var model = makeModel()
        _ = openPrefs(&model, fontSize: 14)
        _ = update(&model, .prefSet(.fontSize("nan")))
        _ = update(&model, .prefSet(.alertClearMode(.manual)))

        let commands = update(&model, .prefSave)

        #expect(model.config.alertClearMode == .manual)
        #expect(model.config.fontSize == 14, "the committed size survives the unparseable text")
        #expect(commands.count == 1)
        #expect(model.preferencesDraft?.fontSizeText == "nan", "the unparseable text stays in the field")
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
        _ = update(&model, .prefSet(.alertClearMode(.manual)))
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
        _ = update(&model, .prefSet(.remoteTheme("Grape")))
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
        _ = update(&model, .prefSet(.remoteTheme("  Grape  ")))
        _ = update(&model, .prefSave)
        #expect(model.preferencesDraft?.config.remoteTheme == "Grape", "draft should be normalized post-save")
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
        _ = update(&model, .prefSet(.remoteTheme("   ")))
        _ = update(&model, .prefSave)
        #expect(model.config.remoteTheme == "Purplepeter", "should resolve to default")
        #expect(model.preferencesDraft?.config.remoteTheme == "Purplepeter")
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
        _ = update(&model, .prefSet(.alertClearMode(.manual)))
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
        _ = update(&model, .prefSet(.remoteTheme("Grape")))
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
        _ = update(&model, .prefSet(.theme("Solarized")))
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
        _ = update(&model, .prefSet(.theme(nil)))
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
        _ = update(&model, .prefSet(.fontSize("16")))
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
        _ = update(&model, .prefSet(.fontSize("abc")))
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
        _ = update(&model, .prefSet(.alertClearMode(.manual)))
        _ = update(&model, .prefSet(.theme("Solarized")))

        var newConfig = DanTermConfig()
        newConfig.remoteTheme = "Ocean"
        newConfig.defaultTheme = "Monokai"
        newConfig.fontSize = 18
        _ = update(&model, .configLoaded(newConfig, resolvedFontFamily: nil))
        #expect(model.preferencesDraft?.config.alertClearMode == .focus, "DanTerm field should match new config")
        #expect(model.preferencesDraft?.config.remoteTheme == "Ocean", "DanTerm field should match new config")
        #expect(model.preferencesDraft?.config.defaultTheme == "Monokai")
        #expect(model.preferencesDraft?.fontSizeText == "18")
    }

    @Test("a save after a reload keeps the reloaded settings the panel cannot edit")
    func saveAfterReloadKeepsSettingsThePanelCannotEdit() throws {
        // Intent: after a config reload arrives while the panel is open, the next
        //   save writes the reloaded values of settings the panel has no control
        //   for, not the values that were current when the panel opened.
        // Why it exists: the draft carries a whole candidate config, so a
        //   candidate the reload did not re-seed would silently write the stale
        //   value of every setting the user cannot see back to the file.
        // Scenario: spec-first -- open the panel, let the config file change
        //   underneath it, then edit one visible field and save.
        var model = makeModel()
        _ = openPrefs(&model, theme: "Dracula", fontSize: 14)

        var reloaded = DanTermConfig.default
        reloaded.localeFallback = false
        reloaded.tailnet = DanTermTailnetConfig(listen: "100.64.0.1:7000", admittedNodeIds: ["node-a"])
        _ = update(&model, .configLoaded(reloaded, resolvedFontFamily: nil))

        _ = update(&model, .prefSet(.theme("Nord")))
        let commands = update(&model, .prefSave)

        let saved = try #require(
            commands.compactMap { command -> DanTermConfig? in
                if case .saveDanTermConfig(let config) = command { return config }
                return nil
            }.first,
            "expected a config save"
        )
        #expect(saved.localeFallback == false, "the save should carry the reloaded locale fallback")
        #expect(saved.tailnet == reloaded.tailnet, "the save should carry the reloaded tailnet")
        #expect(model.config.localeFallback == false)
        #expect(model.config.tailnet == reloaded.tailnet)
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
        // Intent: every preference edit, and prefSave, leaves the whole model
        //   untouched and emits nothing when no draft exists.
        // Why it exists: one reducer arm now holds the draft-open guard for
        //   every control, so a regression there would let a closed panel write
        //   the model. Covering all six edits is what makes that guard pinned
        //   rather than sampled.
        // Scenario: spec-first all-no-ops.
        let edits: [PreferenceEdit] = [
            .alertClearMode(.manual),
            .remoteTheme("Grape"),
            .theme("Dracula"),
            .fontSize("14"),
            .fontFamily("Menlo"),
            .copyOnSelect(true),
        ]
        for edit in edits {
            var model = makeModel()
            let before = model
            let commands = update(&model, .prefSet(edit))
            #expect(commands.count == 0, "\(edit) should emit no commands")
            #expect(model == before, "\(edit) should leave the model unchanged")
        }

        var model = makeModel()
        let before = model
        let commands = update(&model, .prefSave)
        #expect(commands.count == 0)
        #expect(model == before, "prefSave should leave the model unchanged")
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
