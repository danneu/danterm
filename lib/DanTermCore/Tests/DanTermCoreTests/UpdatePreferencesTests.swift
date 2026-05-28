// Swift Testing migration of the legacy `tests/UpdatePreferencesTests.swift`
// harness suite. Pins the preferences-draft Msg paths: panel lifecycle
// (preferencesOpened initializes draft + committedGhosttyPrefs without wiping
// an existing draft, preferencesClosed clears both), the desiredPreferencesPanel
// projection (clean draft + per-field dirty labels + saveEnabled + invalid
// font-size persistence), edit operations (prefSet* preserve raw text for
// remoteTheme, do NOT mutate committed config), reset operations, prefSave
// (per-field saveDanTermConfigKey emission, remote-theme propagation to
// remote panes, theme + font-size invalidating reloadGhosttyConfig, invalid
// font-size skipping save, unchanged Ghostty keys not reloading),
// ghosttyPrefsRefreshed (committed-snapshot sync + draft reset), configLoaded
// while open (resets only DanTerm fields), and the no-op-when-draft-nil guards
// + helper functions (resolveRemoteTheme / isDraftDirty). The eight
// `guard let projection = ... else { throw }` unwraps convert to `try #require`.
import Foundation
import Testing

@testable import DanTermCore

private let defaultGhostty = GhosttyPrefs(theme: nil, fontSize: nil)

@discardableResult
private func openPrefs(_ model: inout AppModel, ghostty: GhosttyPrefs = defaultGhostty) -> [Command] {
    update(&model, .preferencesOpened(ghostty: ghostty))
}

@Suite struct UpdatePreferencesTests {
    // MARK: - Lifecycle

    @Test("preferencesOpened initializes draft from current config")
    func preferencesOpenedInitializesDraftFromCurrentConfig() {
        // Intent: opening prefs seeds preferencesDraft from model.config +
        //   committed Ghostty prefs.
        // Why it exists: pins the initial-state derivation.
        // Scenario: spec-first open.
        var model = makeModel()
        model.config.alertClearMode = .manual
        model.config.remoteTheme = "Grape"
        let ghostty = GhosttyPrefs(theme: "Dracula", fontSize: "14")
        let commands = openPrefs(&model, ghostty: ghostty)
        #expect(model.preferencesDraft?.alertClearMode == .manual)
        #expect(model.preferencesDraft?.remoteTheme == "Grape")
        #expect(model.preferencesDraft?.theme == "Dracula")
        #expect(model.preferencesDraft?.fontSize == "14")
        #expect(model.committedGhosttyPrefs == ghostty)
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

    @Test("preferencesClosed clears draft and committedGhosttyPrefs")
    func preferencesClosedClearsDraftAndCommitted() {
        // Intent: closing prefs nils both the draft and committed Ghostty
        //   snapshot.
        // Why it exists: pins the close-side cleanup.
        // Scenario: spec-first close.
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))
        #expect(model.preferencesDraft != nil, "draft should exist")
        #expect(model.committedGhosttyPrefs != nil, "ghostty prefs should exist")
        let commands = update(&model, .preferencesClosed)
        #expect(model.preferencesDraft == nil, "draft should be nil")
        #expect(model.committedGhosttyPrefs == nil, "ghostty prefs should be nil")
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

    @Test("desiredPreferencesPanel clean draft renders values with save disabled")
    func desiredPreferencesPanelCleanDraftDisablesSave() throws {
        // Intent: a clean draft renders current values, no dirty labels,
        //   Save disabled.
        // Why it exists: pins the no-changes projection.
        // Scenario: spec-first clean panel.
        var model = makeModel()
        model.config.alertClearMode = .manual
        model.config.remoteTheme = "Grape"
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))

        let projection = try #require(desiredPreferencesPanel(in: model), "expected preferences projection")
        #expect(projection.selectedAlertClearMode == .manual)
        #expect(projection.remoteThemeText == "Grape")
        #expect(projection.ghosttyThemeText == "Dracula")
        #expect(projection.fontSizeText == "14")
        #expect(projection.ghosttyThemeDirtyLabel == nil, "theme row hidden")
        #expect(projection.fontSizeDirtyLabel == nil, "font-size row hidden")
        #expect(projection.alertClearModeDirtyLabel == nil, "alert row hidden")
        #expect(projection.remoteThemeDirtyLabel == nil, "remote theme row hidden")
        #expect(!projection.saveEnabled, "clean draft disables Save")
    }

    @Test("desiredPreferencesPanel renders alert clear mode dirty label")
    func desiredPreferencesPanelRendersAlertClearModeDirty() throws {
        // Intent: alert clear mode change surfaces a dirty label and
        //   enables Save.
        // Why it exists: pins the dirty-label rendering for alert mode.
        // Scenario: spec-first dirty alert mode.
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))
        _ = update(&model, .prefSetAlertClearMode(.manual))

        let projection = try #require(desiredPreferencesPanel(in: model), "expected preferences projection")
        #expect(projection.alertClearModeDirtyLabel == "Prev: Focus")
        #expect(projection.saveEnabled, "dirty alert clear mode enables Save")
    }

    @Test("desiredPreferencesPanel renders remote theme dirty label")
    func desiredPreferencesPanelRendersRemoteThemeDirty() throws {
        // Intent: remote-theme change surfaces a dirty label and enables
        //   Save.
        // Why it exists: pins the dirty-label rendering for remote theme.
        // Scenario: spec-first dirty remote theme.
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))
        _ = update(&model, .prefSetRemoteTheme("Grape"))

        let projection = try #require(desiredPreferencesPanel(in: model), "expected preferences projection")
        #expect(projection.remoteThemeDirtyLabel == "Prev: Purplepeter")
        #expect(projection.saveEnabled, "dirty remote theme enables Save")
    }

    @Test("desiredPreferencesPanel renders Ghostty theme dirty label")
    func desiredPreferencesPanelRendersGhosttyThemeDirty() throws {
        // Intent: Ghostty theme change surfaces a dirty label.
        // Why it exists: pins the dirty-label rendering for Ghostty
        //   theme.
        // Scenario: spec-first dirty Ghostty theme.
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))
        _ = update(&model, .prefSetTheme("Solarized"))

        let projection = try #require(desiredPreferencesPanel(in: model), "expected preferences projection")
        #expect(projection.ghosttyThemeDirtyLabel == "Prev: Dracula")
        #expect(projection.saveEnabled, "dirty Ghostty theme enables Save")
    }

    @Test("desiredPreferencesPanel renders font-size dirty label")
    func desiredPreferencesPanelRendersFontSizeDirty() throws {
        // Intent: font-size change surfaces a dirty label.
        // Why it exists: pins the dirty-label rendering for font size.
        // Scenario: spec-first dirty font size.
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))
        _ = update(&model, .prefSetFontSize("16"))

        let projection = try #require(desiredPreferencesPanel(in: model), "expected preferences projection")
        #expect(projection.fontSizeDirtyLabel == "Prev: 14")
        #expect(projection.saveEnabled, "dirty font size enables Save")
    }

    @Test("desiredPreferencesPanel normalizes remote theme dirtiness")
    func desiredPreferencesPanelNormalizesRemoteThemeDirtiness() throws {
        // Intent: a whitespace-padded remote theme that normalizes to the
        //   committed value is treated as clean.
        // Why it exists: pins the normalize-on-render rule.
        // Scenario: spec-first normalize-clean.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("  Purplepeter  "))

        let projection = try #require(desiredPreferencesPanel(in: model), "expected preferences projection")
        #expect(projection.remoteThemeText == "  Purplepeter  ", "field keeps raw draft text")
        #expect(projection.remoteThemeDirtyLabel == nil, "normalized remote theme is clean")
        #expect(!projection.saveEnabled, "normalized clean draft disables Save")
    }

    @Test("desiredPreferencesPanel uses default labels for Ghostty defaults")
    func desiredPreferencesPanelUsesDefaultLabelsForGhosttyDefaults() throws {
        // Intent: when committed Ghostty values are nil (defaults), dirty
        //   labels read "Prev: (default)".
        // Why it exists: pins the default-label rendering.
        // Scenario: spec-first default labels.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetTheme("Solarized"))
        _ = update(&model, .prefSetFontSize("16"))

        let projection = try #require(desiredPreferencesPanel(in: model), "expected preferences projection")
        #expect(projection.ghosttyThemeDirtyLabel == "Prev: (default)")
        #expect(projection.fontSizeDirtyLabel == "Prev: (default)")
        #expect(projection.saveEnabled, "dirty Ghostty draft enables Save")
    }

    @Test("invalid font-size stays dirty after save")
    func invalidFontSizeStaysDirtyAfterSave() throws {
        // Intent: invalid font-size is not saved; the draft remains dirty
        //   and Save stays enabled.
        // Why it exists: pins the validation-skip rule.
        // Scenario: spec-first invalid font save.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetFontSize("abc"))
        let commands = update(&model, .prefSave)

        let projection = try #require(desiredPreferencesPanel(in: model), "expected preferences projection")
        #expect(commands.count == 0)
        #expect(projection.fontSizeText == "abc")
        #expect(projection.fontSizeDirtyLabel == "Prev: (default)")
        #expect(projection.saveEnabled, "invalid unsaved font size remains dirty")
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
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: nil))
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

    // MARK: - Reset

    @Test("prefResetAlertClearMode reverts draft to committed")
    func prefResetAlertClearModeReverts() {
        // Intent: reset returns the draft alert mode to committed value.
        // Why it exists: pins the alert-mode reset.
        // Scenario: spec-first reset alert mode.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetAlertClearMode(.manual))
        #expect(model.preferencesDraft?.alertClearMode == .manual)
        let commands = update(&model, .prefResetAlertClearMode)
        #expect(model.preferencesDraft?.alertClearMode == .focus, "should revert to committed")
        #expect(commands.count == 0)
    }

    @Test("prefResetRemoteTheme reverts draft to committed")
    func prefResetRemoteThemeReverts() {
        // Intent: reset returns the draft remote theme to committed value
        //   (default "Purplepeter").
        // Why it exists: pins the remote-theme reset.
        // Scenario: spec-first reset remote theme.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let commands = update(&model, .prefResetRemoteTheme)
        #expect(model.preferencesDraft?.remoteTheme == "Purplepeter", "should revert to committed")
        #expect(commands.count == 0)
    }

    @Test("prefResetTheme reverts draft to committed Ghostty value")
    func prefResetThemeReverts() {
        // Intent: reset returns the draft Ghostty theme to committed
        //   value.
        // Why it exists: pins the Ghostty theme reset.
        // Scenario: spec-first reset Ghostty theme.
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: nil))
        _ = update(&model, .prefSetTheme("Solarized"))
        #expect(model.preferencesDraft?.theme == "Solarized")
        let commands = update(&model, .prefResetTheme)
        #expect(model.preferencesDraft?.theme == "Dracula", "should revert to committed")
        #expect(commands.count == 0)
    }

    @Test("prefResetFontSize reverts draft to committed Ghostty value")
    func prefResetFontSizeReverts() {
        // Intent: reset returns the draft font size to committed value.
        // Why it exists: pins the font-size reset.
        // Scenario: spec-first reset font size.
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: nil, fontSize: "14"))
        _ = update(&model, .prefSetFontSize("20"))
        let commands = update(&model, .prefResetFontSize)
        #expect(model.preferencesDraft?.fontSize == "14", "should revert to committed")
        #expect(commands.count == 0)
    }

    // MARK: - Save

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

    @Test("prefSave with alertClearMode change emits saveDanTermConfigKey")
    func prefSaveWithAlertClearModeChangeEmitsKey() {
        // Intent: a dirty alert mode emits saveDanTermConfigKey and
        //   updates model.config.
        // Why it exists: pins the alert-mode save path.
        // Scenario: spec-first save alert mode.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetAlertClearMode(.manual))
        let commands = update(&model, .prefSave)
        #expect(model.config.alertClearMode == .manual, "committed config should update")
        #expect(hasEffect(commands) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "alert-clear-mode" && value == "manual"
            }
            return false
        }, "should save alert-clear-mode")
    }

    @Test("prefSave with remoteTheme change emits saveDanTermConfigKey")
    func prefSaveWithRemoteThemeChangeEmitsKey() {
        // Intent: a dirty remote theme emits saveDanTermConfigKey and
        //   updates model.config.
        // Why it exists: pins the remote-theme save path.
        // Scenario: spec-first save remote theme.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let commands = update(&model, .prefSave)
        #expect(model.config.remoteTheme == "Grape", "committed config should update")
        #expect(hasEffect(commands) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "remote-theme" && value == "Grape"
            }
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

    @Test("prefSave resets dirty state")
    func prefSaveResetsDirtyState() {
        // Intent: after a successful save, the draft is clean against the
        //   committed config.
        // Why it exists: pins the post-save invariant.
        // Scenario: spec-first save clears dirty.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetAlertClearMode(.manual))
        #expect(isDraftDirty(model.preferencesDraft!, vs: model.config, ghostty: model.committedGhosttyPrefs), "should be dirty before save")
        _ = update(&model, .prefSave)
        #expect(!isDraftDirty(model.preferencesDraft!, vs: model.config, ghostty: model.committedGhosttyPrefs), "should be clean after save")
    }

    @Test("prefSave with remoteTheme change updates remote panes")
    func prefSaveWithRemoteThemeChangeUpdatesRemotePanes() {
        // Intent: saving a new remote theme propagates to remote panes'
        //   remoteThemeOverride and the per-pane config projection.
        // Why it exists: pins the live remote-theme propagation.
        // Scenario: spec-first remote panes update.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .remoteSessionStarted(paneId: paneId))

        _ = openPrefs(&model)
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let commands = update(&model, .prefSave)
        #expect(model.pane(paneId)?.remoteThemeOverride == "Grape")
        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Grape")
        #expect(hasEffect(commands) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "remote-theme" && value == "Grape"
            }
            return false
        }, "should save remote theme")
    }

    @Test("prefSave with theme change emits saveDanTermConfigKey and reloadGhosttyConfig")
    func prefSaveWithThemeChangeEmitsKeyAndReload() {
        // Intent: a Ghostty theme change emits saveDanTermConfigKey +
        //   reloadGhosttyConfig.
        // Why it exists: pins the Ghostty-key save + reload pair.
        // Scenario: spec-first save Ghostty theme.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetTheme("Solarized"))
        let commands = update(&model, .prefSave)
        #expect(hasEffect(commands) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "theme" && value == "Solarized"
            }
            return false
        }, "should save theme key")
        #expect(hasEffect(commands) {
            if case .reloadGhosttyConfig = $0 { return true }
            return false
        }, "should emit reloadGhosttyConfig")
    }

    @Test("prefSave with cleared theme emits removeDanTermConfigKey")
    func prefSaveWithClearedThemeEmitsRemoveKey() {
        // Intent: clearing the Ghostty theme emits removeDanTermConfigKey
        //   + reloadGhosttyConfig.
        // Why it exists: pins the clear path of the Ghostty save.
        // Scenario: spec-first clear Ghostty theme.
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: nil))
        _ = update(&model, .prefSetTheme(nil))
        let commands = update(&model, .prefSave)
        #expect(hasEffect(commands) {
            if case .removeDanTermConfigKey(let key) = $0 { return key == "theme" }
            return false
        }, "should remove theme key")
        #expect(hasEffect(commands) {
            if case .reloadGhosttyConfig = $0 { return true }
            return false
        }, "should emit reloadGhosttyConfig")
    }

    @Test("prefSave with valid fontSize emits saveDanTermConfigKey")
    func prefSaveWithValidFontSizeEmitsKey() {
        // Intent: a valid font size emits saveDanTermConfigKey +
        //   reloadGhosttyConfig.
        // Why it exists: pins the font-size save path.
        // Scenario: spec-first save font size.
        var model = makeModel()
        _ = openPrefs(&model)
        _ = update(&model, .prefSetFontSize("16"))
        let commands = update(&model, .prefSave)
        #expect(hasEffect(commands) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "font-size" && value == "16"
            }
            return false
        }, "should save font-size key")
        #expect(hasEffect(commands) {
            if case .reloadGhosttyConfig = $0 { return true }
            return false
        }, "should emit reloadGhosttyConfig")
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
            if case .saveDanTermConfigKey(let key, _) = $0 { return key == "font-size" }
            return false
        }, "should not save invalid font-size")
        #expect(!hasEffect(commands) {
            if case .reloadGhosttyConfig = $0 { return true }
            return false
        }, "should not reload for invalid font-size")
    }

    @Test("prefSave with unchanged Ghostty keys does not emit reload")
    func prefSaveWithUnchangedGhosttyKeysSkipsReload() {
        // Intent: saving with only DanTerm keys dirty does NOT emit
        //   reloadGhosttyConfig.
        // Why it exists: pins the reload scope (Ghostty keys only).
        // Scenario: spec-first DanTerm-only save.
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))
        _ = update(&model, .prefSetAlertClearMode(.manual))
        let commands = update(&model, .prefSave)
        #expect(!hasEffect(commands) {
            if case .reloadGhosttyConfig = $0 { return true }
            return false
        }, "should not reload when Ghostty keys unchanged")
    }

    // MARK: - ghosttyPrefsRefreshed

    @Test("ghosttyPrefsRefreshed updates committed snapshot and resets draft")
    func ghosttyPrefsRefreshedUpdatesCommittedResetsDraft() {
        // Intent: ghosttyPrefsRefreshed updates committedGhosttyPrefs and
        //   resets the draft's Ghostty fields to the new committed.
        // Why it exists: pins the external-refresh syncing.
        // Scenario: spec-first refresh sync.
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))
        _ = update(&model, .prefSetTheme("Solarized"))
        #expect(model.preferencesDraft?.theme == "Solarized")

        let newPrefs = GhosttyPrefs(theme: "Monokai", fontSize: "16")
        let commands = update(&model, .ghosttyPrefsRefreshed(newPrefs))
        #expect(model.committedGhosttyPrefs == newPrefs)
        #expect(model.preferencesDraft?.theme == "Monokai", "draft should reset to new committed")
        #expect(model.preferencesDraft?.fontSize == "16", "draft should reset to new committed")
        #expect(commands.count == 0)
    }

    @Test("ghosttyPrefsRefreshed with no draft open just updates committed")
    func ghosttyPrefsRefreshedWithNoDraftJustUpdatesCommitted() {
        // Intent: refresh with no draft open updates only the committed
        //   snapshot.
        // Why it exists: pins the no-draft branch.
        // Scenario: spec-first closed refresh.
        var model = makeModel()
        let prefs = GhosttyPrefs(theme: "Dracula", fontSize: "14")
        let commands = update(&model, .ghosttyPrefsRefreshed(prefs))
        #expect(model.committedGhosttyPrefs == prefs)
        #expect(model.preferencesDraft == nil, "draft should remain nil")
        #expect(commands.count == 0, "no sync needed when panel not open")
    }

    // MARK: - External reload

    @Test("configLoaded while panel open resets DanTerm draft fields only")
    func configLoadedWhilePanelOpenResetsDanTermFields() {
        // Intent: configLoaded while open resets DanTerm fields in the
        //   draft (and preserves Ghostty draft fields).
        // Why it exists: pins the scope of configLoaded's reset.
        // Scenario: spec-first configLoaded scope.
        var model = makeModel()
        _ = openPrefs(&model, ghostty: GhosttyPrefs(theme: "Dracula", fontSize: "14"))
        _ = update(&model, .prefSetAlertClearMode(.manual))
        _ = update(&model, .prefSetTheme("Solarized"))

        var newConfig = DanTermConfig()
        newConfig.remoteTheme = "Ocean"
        _ = update(&model, .configLoaded(newConfig))
        #expect(model.preferencesDraft?.alertClearMode == .focus, "DanTerm field should match new config")
        #expect(model.preferencesDraft?.remoteTheme == "Ocean", "DanTerm field should match new config")
        #expect(model.preferencesDraft?.theme == "Solarized", "Ghostty field should be preserved")
    }

    @Test("configLoaded while panel closed does not create draft")
    func configLoadedWhilePanelClosedDoesNotCreateDraft() {
        // Intent: configLoaded does not create a draft when prefs are
        //   closed.
        // Why it exists: pins the no-implicit-open rule.
        // Scenario: spec-first closed configLoaded.
        var model = makeModel()
        _ = update(&model, .configLoaded(DanTermConfig.default))
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

        let e3 = update(&model, .prefResetAlertClearMode)
        #expect(e3.count == 0)

        let e4 = update(&model, .prefResetRemoteTheme)
        #expect(e4.count == 0)

        let e5 = update(&model, .prefSave)
        #expect(e5.count == 0)

        let e6 = update(&model, .prefSetTheme("Dracula"))
        #expect(e6.count == 0)

        let e7 = update(&model, .prefSetFontSize("14"))
        #expect(e7.count == 0)

        let e8 = update(&model, .prefResetTheme)
        #expect(e8.count == 0)

        let e9 = update(&model, .prefResetFontSize)
        #expect(e9.count == 0)
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

    @Test("isDraftDirty returns false when all fields match")
    func isDraftDirtyFalseWhenAllMatch() {
        // Intent: a draft matching every committed field reports clean.
        // Why it exists: pins the dirty-check happy path (with normalize
        //   on whitespace-padded remote theme).
        // Scenario: spec-first clean.
        let config = DanTermConfig.default
        let ghostty = GhosttyPrefs(theme: nil, fontSize: nil)
        let draft = PreferencesDraft(alertClearMode: .focus, remoteTheme: "  Purplepeter  ", theme: nil, fontSize: nil)
        #expect(!isDraftDirty(draft, vs: config, ghostty: ghostty), "should not be dirty")
    }

    @Test("isDraftDirty returns true when alertClearMode differs")
    func isDraftDirtyTrueWhenAlertClearModeDiffers() {
        // Intent: alert mode mismatch flags dirty.
        // Why it exists: pins the alert-mode branch.
        // Scenario: spec-first alert mismatch.
        let config = DanTermConfig.default
        let draft = PreferencesDraft(alertClearMode: .manual, remoteTheme: "Purplepeter", theme: nil, fontSize: nil)
        #expect(isDraftDirty(draft, vs: config, ghostty: defaultGhostty), "should be dirty")
    }

    @Test("isDraftDirty returns true when remoteTheme differs")
    func isDraftDirtyTrueWhenRemoteThemeDiffers() {
        // Intent: remote-theme mismatch flags dirty.
        // Why it exists: pins the remote-theme branch.
        // Scenario: spec-first remote mismatch.
        let config = DanTermConfig.default
        let draft = PreferencesDraft(alertClearMode: .focus, remoteTheme: "Grape", theme: nil, fontSize: nil)
        #expect(isDraftDirty(draft, vs: config, ghostty: defaultGhostty), "should be dirty")
    }

    @Test("isDraftDirty returns true when theme differs from Ghostty committed")
    func isDraftDirtyTrueWhenThemeDiffersFromGhostty() {
        // Intent: Ghostty theme mismatch flags dirty.
        // Why it exists: pins the Ghostty theme branch.
        // Scenario: spec-first Ghostty theme mismatch.
        let config = DanTermConfig.default
        let ghostty = GhosttyPrefs(theme: "Dracula", fontSize: nil)
        let draft = PreferencesDraft(alertClearMode: .focus, remoteTheme: "Purplepeter", theme: "Solarized", fontSize: nil)
        #expect(isDraftDirty(draft, vs: config, ghostty: ghostty), "should be dirty")
    }

    @Test("isDraftDirty returns true when fontSize differs from Ghostty committed")
    func isDraftDirtyTrueWhenFontSizeDiffersFromGhostty() {
        // Intent: font-size mismatch flags dirty.
        // Why it exists: pins the font-size branch.
        // Scenario: spec-first font-size mismatch.
        let config = DanTermConfig.default
        let ghostty = GhosttyPrefs(theme: nil, fontSize: "14")
        let draft = PreferencesDraft(alertClearMode: .focus, remoteTheme: "Purplepeter", theme: nil, fontSize: "16")
        #expect(isDraftDirty(draft, vs: config, ghostty: ghostty), "should be dirty")
    }
}
