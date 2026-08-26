// Behavioral proofs for atomic keybinding edits in the Settings draft.
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct KeybindingPreferencesTests {
    @Test("sheet edits stay isolated until Done and Cancel discards them")
    func sheetEditsAreTransactional() throws {
        var model = openPreferences()
        let original = model.config
        let chord = try #require(KeyChord(compact: "cmd+option+t"))

        _ = update(&model, .prefKeybinding(.openEditor("tab.new")))
        _ = update(&model, .prefKeybinding(.beginEditorRecording(chordAt: nil)))
        let stageCommands = update(&model, .prefKeybinding(.recordEditorChord(chord)))

        #expect(stageCommands.isEmpty)
        #expect(model.config == original)
        #expect(model.preferencesDraft?.config == original)
        #expect(model.preferencesDraft?.keybindingEditor?.candidate.chordsByAction["tab.new"]
            == chords("cmd+t", "cmd+option+t"))
        _ = update(&model, .prefKeybinding(.closeEditor))
        #expect(model.preferencesDraft?.keybindingEditor == nil)
        #expect(model.config == original)
    }

    @Test("Done validates and saves the whole candidate once while preserving unknown actions")
    func editorDoneCommitsOnceAndPreservesUnknownOverrides() throws {
        var config = DanTermConfig.default
        let unknown: KeybindingActionID = "plugin.future"
        config.keybindingOverrides = KeybindingOverrides([unknown: chords("cmd+option+f")])
        var model = openPreferences(config)
        let chord = try #require(KeyChord(compact: "cmd+option+t"))

        _ = update(&model, .prefKeybinding(.openEditor("tab.new")))
        _ = update(&model, .prefKeybinding(.beginEditorRecording(chordAt: nil)))
        _ = update(&model, .prefKeybinding(.recordEditorChord(chord)))
        let commands = update(&model, .prefKeybinding(.acceptEditor))

        #expect(model.preferencesDraft?.keybindingEditor == nil)
        #expect(model.config.keybindingOverrides.chordsByAction["tab.new"] == chords("cmd+t", "cmd+option+t"))
        #expect(model.config.keybindingOverrides.chordsByAction[unknown] == chords("cmd+option+f"))
        #expect(savedConfigs(in: commands) == [model.config])
    }

    @Test("invalid Done keeps the sheet open and emits no save")
    func invalidEditorDoneStaysOpen() {
        var config = DanTermConfig.default
        config.keybindingOverrides = KeybindingOverrides(["tab.new": chords("cmd+c")])
        var model = openPreferences(config)

        _ = update(&model, .prefKeybinding(.openEditor("tab.new")))
        let commands = update(&model, .prefKeybinding(.acceptEditor))

        #expect(commands.isEmpty)
        #expect(model.preferencesDraft?.keybindingEditor != nil)
        #expect(model.preferencesDraft?.keybindingEditor?.diagnostic?.reason == "reserved by Copy")
    }

    @Test("capture moves an existing owner inside the candidate and projects a persistent note")
    func captureMovesCandidateOwner() throws {
        var model = openPreferences()
        let chord = try #require(KeyChord(compact: "cmd+t"))

        _ = update(&model, .prefKeybinding(.openEditor("tab.new-group")))
        _ = update(&model, .prefKeybinding(.beginEditorRecording(chordAt: nil)))
        _ = update(&model, .prefKeybinding(.recordEditorChord(chord)))

        let candidate = try #require(model.preferencesDraft?.keybindingEditor?.candidate)
        #expect(candidate.chordsByAction["tab.new"] == [])
        #expect(candidate.chordsByAction["tab.new-group"] == chords("cmd+n", "cmd+t"))
        let editor = try #require(desiredPreferencesPanel(in: model)?.keybindingEditor)
        #expect(editor.shortcuts.last?.moveNote == "Moved from New Tab")
        #expect(model.config.keybindingOverrides == .empty)
    }

    @Test("invalid and duplicate captures keep the candidate and recorder active")
    func invalidCapturesKeepRecording() throws {
        var model = openPreferences()
        let reserved = try #require(KeyChord(compact: "cmd+c"))
        let duplicate = try #require(KeyChord(compact: "cmd+t"))

        _ = update(&model, .prefKeybinding(.openEditor("tab.new")))
        _ = update(&model, .prefKeybinding(.beginEditorRecording(chordAt: nil)))
        let original = try #require(model.preferencesDraft?.keybindingEditor?.candidate)
        _ = update(&model, .prefKeybinding(.recordEditorChord(reserved)))
        #expect(model.preferencesDraft?.keybindingEditor?.candidate == original)
        #expect(model.preferencesDraft?.keybindingEditor?.recordingTarget == .adding)
        #expect(model.preferencesDraft?.keybindingEditor?.diagnostic?.reason == "reserved by Copy")
        _ = update(&model, .prefKeybinding(.recordEditorChord(duplicate)))
        #expect(model.preferencesDraft?.keybindingEditor?.candidate == original)
        #expect(model.preferencesDraft?.keybindingEditor?.recordingTarget == .adding)
        #expect(model.preferencesDraft?.keybindingEditor?.diagnostic?.reason == "already assigned to this command")
    }

    @Test("recording rejection and Escape cancel do not dismiss the editor")
    func editorRecordingCancellationIsLocal() {
        var model = openPreferences()
        let diagnostic = KeybindingDiagnostic(
            path: "keybindings.tab.new",
            reason: "shortcut must use Cmd, Control, or Option with a representable key"
        )

        _ = update(&model, .prefKeybinding(.openEditor("tab.new")))
        _ = update(&model, .prefKeybinding(.beginEditorRecording(chordAt: nil)))
        _ = update(&model, .prefKeybinding(.rejectEditorRecording(diagnostic)))
        #expect(model.preferencesDraft?.keybindingEditor?.recordingTarget == .adding)
        #expect(model.preferencesDraft?.keybindingEditor?.diagnostic == diagnostic)
        _ = update(&model, .prefKeybinding(.cancelEditorRecording))
        #expect(model.preferencesDraft?.keybindingEditor?.recordingTarget == nil)
        #expect(model.preferencesDraft?.keybindingEditor != nil)
    }

    @Test("disable retains shortcuts and re-enable restores them while moving conflicts")
    func disableAndReenableRestoresChords() throws {
        var model = openPreferences()
        let chord = try #require(KeyChord(compact: "cmd+t"))

        _ = update(&model, .prefKeybinding(.openEditor("tab.new")))
        _ = update(&model, .prefKeybinding(.setEditorEnabled(false)))
        var editor = try #require(desiredPreferencesPanel(in: model)?.keybindingEditor)
        #expect(editor.isEnabled == false)
        #expect(editor.shortcuts.map(\.chord) == [chord])
        #expect(editor.shortcuts.map(\.accessibilityValue) == ["Command-T, disabled"])
        _ = update(&model, .prefKeybinding(.setEditorEnabled(true)))
        editor = try #require(desiredPreferencesPanel(in: model)?.keybindingEditor)
        #expect(editor.isEnabled)
        #expect(editor.shortcuts.map(\.chord) == [chord])
    }

    @Test("a command disabled before open restores catalog defaults")
    func initiallyDisabledCommandRestoresDefaults() throws {
        var config = DanTermConfig.default
        config.keybindingOverrides = KeybindingOverrides(["tab.new": []])
        var model = openPreferences(config)

        _ = update(&model, .prefKeybinding(.openEditor("tab.new")))
        _ = update(&model, .prefKeybinding(.setEditorEnabled(true)))

        let candidate = try #require(model.preferencesDraft?.keybindingEditor?.candidate)
        #expect(candidate.chordsByAction["tab.new"] == chords("cmd+t"))
    }

    @Test("recording a disabled shortcut re-enables its command")
    func editingDisabledCommandEnablesIt() throws {
        var config = DanTermConfig.default
        config.keybindingOverrides = KeybindingOverrides(["tab.new": []])
        var model = openPreferences(config)
        let chord = try #require(KeyChord(compact: "cmd+option+t"))

        _ = update(&model, .prefKeybinding(.openEditor("tab.new")))
        _ = update(&model, .prefKeybinding(.beginEditorRecording(chordAt: 0)))
        _ = update(&model, .prefKeybinding(.recordEditorChord(chord)))

        let editor = try #require(desiredPreferencesPanel(in: model)?.keybindingEditor)
        #expect(editor.isEnabled)
        #expect(editor.shortcuts.map(\.chord) == [chord])
    }

    @Test("re-enable and reset reclaim candidate shortcuts from their current owners")
    func restorationActionsMoveConflicts() throws {
        var disabledConfig = DanTermConfig.default
        disabledConfig.keybindingOverrides = KeybindingOverrides([
            "tab.new": [],
            "tab.new-group": chords("cmd+t"),
        ])
        var disabledModel = openPreferences(disabledConfig)
        _ = update(&disabledModel, .prefKeybinding(.openEditor("tab.new")))
        _ = update(&disabledModel, .prefKeybinding(.setEditorEnabled(true)))
        var candidate = try #require(disabledModel.preferencesDraft?.keybindingEditor?.candidate)
        #expect(candidate.chordsByAction["tab.new"] == chords("cmd+t"))
        #expect(candidate.chordsByAction["tab.new-group"] == [])

        var customConfig = DanTermConfig.default
        customConfig.keybindingOverrides = KeybindingOverrides([
            "tab.new": chords("cmd+option+t"),
            "tab.new-group": chords("cmd+t"),
        ])
        var customModel = openPreferences(customConfig)
        _ = update(&customModel, .prefKeybinding(.openEditor("tab.new")))
        _ = update(&customModel, .prefKeybinding(.resetEditor))
        candidate = try #require(customModel.preferencesDraft?.keybindingEditor?.candidate)
        #expect(candidate.chordsByAction["tab.new"] == nil)
        #expect(candidate.chordsByAction["tab.new-group"] == [])
    }

    @Test("held MRU editing stages its partner and removes committed extras")
    func heldMRUEditingKeepsPairValid() throws {
        var config = DanTermConfig.default
        config.keybindingOverrides = KeybindingOverrides([
            "tab.recent-older": chords("cmd+shift+o", "cmd+option+o"),
        ])
        var model = openPreferences(config)
        let replacement = try #require(KeyChord(compact: "cmd+option+o"))

        _ = update(&model, .prefKeybinding(.openEditor("tab.recent-older")))
        var editor = try #require(desiredPreferencesPanel(in: model)?.keybindingEditor)
        #expect(editor.shortcuts.count == 1)
        #expect(editor.removalNote == "Done will remove 1 extra shortcut.")
        _ = update(&model, .prefKeybinding(.beginEditorRecording(chordAt: 0)))
        _ = update(&model, .prefKeybinding(.recordEditorChord(replacement)))

        let candidate = try #require(model.preferencesDraft?.keybindingEditor?.candidate)
        #expect(candidate.chordsByAction["tab.recent-older"] == [replacement])
        #expect(candidate.chordsByAction["tab.recent-newer"] == chords("cmd+option+i"))
        editor = try #require(desiredPreferencesPanel(in: model)?.keybindingEditor)
        #expect(editor.canAddOrRemove == false)
    }

    @Test("invalid committed bindings remain visible and marked not applied")
    func invalidCommittedBindingsRemainBrowsable() throws {
        var config = DanTermConfig.default
        config.keybindingOverrides = KeybindingOverrides(["tab.new": chords("cmd+c")])
        let model = openPreferences(config)

        let projection = try #require(desiredPreferencesPanel(in: model))
        let row = try #require(projection.keybindingGroups.flatMap(\.actions).first { $0.id == "tab.new" })
        #expect(row.chords == chords("cmd+c"))
        #expect(row.shortcutsAreApplied == false)
        #expect(row.shortcutAccessibilityValues == ["Command-C, not applied"])
        #expect(projection.keybindingDiagnosticText?.contains("menu shortcuts keep the last valid map") == true)
    }

    @Test("shortcut presentation uses native glyphs and spoken names without changing compact spelling")
    func shortcutPresentationUsesNativeText() throws {
        let chord = try #require(KeyChord(compact: "ctrl+option+shift+left"))

        let presentation = keybindingShortcutPresentation(chord)

        #expect(presentation.visual == "⌃⌥⇧←")
        #expect(presentation.spoken == "Control-Option-Shift-Left Arrow")
        #expect(chord.compact == "ctrl+option+shift+left")
    }

    @Test("shortcut presentation covers command, named, function, and character keys")
    func shortcutPresentationCoversKeyKinds() throws {
        let commandCharacter = keybindingShortcutPresentation(try #require(KeyChord(compact: "cmd+a")))
        let named = keybindingShortcutPresentation(try #require(KeyChord(compact: "cmd+enter")))
        let function = keybindingShortcutPresentation(try #require(KeyChord(compact: "option+f12")))

        #expect(commandCharacter == KeybindingShortcutPresentation(visual: "⌘A", spoken: "Command-A"))
        #expect(named == KeybindingShortcutPresentation(visual: "⌘↩", spoken: "Command-Return"))
        #expect(function == KeybindingShortcutPresentation(visual: "⌥F12", spoken: "Option-F12"))
    }

    @Test("browser selection and sheet shortcut operations remain model-owned")
    func browserSelectionAndSheetOperations() throws {
        var config = DanTermConfig.default
        config.keybindingOverrides = KeybindingOverrides([
            "tab.new": chords("cmd+t", "cmd+option+t", "ctrl+option+t"),
        ])
        var model = openPreferences(config)

        _ = update(&model, .prefKeybinding(.selectBrowserAction("tab.new")))
        var row = try #require(desiredPreferencesPanel(in: model)?.keybindingGroups
            .flatMap(\.actions).first { $0.id == "tab.new" })
        #expect(row.isSelected)
        _ = update(&model, .prefKeybinding(.openEditor("tab.new")))
        _ = update(&model, .prefKeybinding(.makeEditorChordPrimary(at: 2)))
        _ = update(&model, .prefKeybinding(.removeEditorChord(at: 1)))
        var editor = try #require(desiredPreferencesPanel(in: model)?.keybindingEditor)
        #expect(editor.shortcuts.map(\.chord) == chords("ctrl+option+t", "cmd+option+t"))
        _ = update(&model, .prefKeybinding(.resetEditor))
        editor = try #require(desiredPreferencesPanel(in: model)?.keybindingEditor)
        #expect(editor.isEnabled)
        #expect(editor.shortcuts.map(\.chord) == chords("cmd+t"))
        row = try #require(desiredPreferencesPanel(in: model)?.keybindingGroups
            .flatMap(\.actions).first { $0.id == "tab.new" })
        #expect(row.chords == chords("cmd+t", "cmd+option+t", "ctrl+option+t"))
    }

    @Test("Reset All waits for confirmation and preserves unknown action overrides")
    func resetAllRequiresConfirmationAndPreservesUnknownOverrides() throws {
        let unknown: KeybindingActionID = "plugin.future"
        var config = DanTermConfig.default
        config.keybindingOverrides = KeybindingOverrides([
            "tab.new": chords("cmd+option+t"),
            unknown: chords("cmd+option+f"),
        ])
        var model = openPreferences(config)

        #expect(update(&model, .prefKeybinding(.requestResetAll)).isEmpty)
        #expect(model.config == config)
        #expect(try #require(desiredPreferencesPanel(in: model))
            .isResetAllKeybindingsConfirmationPresented)
        _ = update(&model, .prefKeybinding(.cancelResetAll))
        #expect(model.config == config)
        #expect(try #require(desiredPreferencesPanel(in: model))
            .isResetAllKeybindingsConfirmationPresented == false)
        _ = update(&model, .prefKeybinding(.requestResetAll))
        let commands = update(&model, .prefKeybinding(.confirmResetAll))

        #expect(model.config.keybindingOverrides.chordsByAction == [unknown: chords("cmd+option+f")])
        #expect(savedConfigs(in: commands) == [model.config])
    }

    @Test("reload, Settings close, and ordinary editor close discard the sheet")
    func editorTeardownPathsDiscardCandidate() {
        var model = openPreferences()
        _ = update(&model, .prefKeybinding(.openEditor("tab.new")))
        _ = update(&model, .configLoaded(.default, resolvedFontFamily: nil))
        #expect(model.preferencesDraft?.keybindingEditor == nil)
        _ = update(&model, .prefKeybinding(.openEditor("tab.new")))
        _ = update(&model, .preferencesClosed)
        #expect(model.preferencesDraft == nil)
    }

    @Test("the browser's Application group lists only the two configurable commands")
    func applicationGroupListsOnlyConfigurableCommands() throws {
        // Intent: Import State, Export State, Settings, and Install danterm in PATH never
        //   appear in the keybinding browser, by search or by browsing.
        // Why it exists: they are fixed App-menu items with nothing to rebind; listing them
        //   offered the user a row that could not do anything useful.
        // Scenario: spec-first -- a user opens the Keybindings section, then searches.
        var model = openPreferences()

        let group = try #require(desiredPreferencesPanel(in: model)?.keybindingGroups
            .first { $0.title == "Application" })
        #expect(group.actions.map(\.id) == ["app.open-config", "app.reload-config"])

        for query in ["settings", "install", "state"] {
            _ = update(&model, .prefKeybindingSearchChanged(query))
            #expect(desiredPreferencesPanel(in: model)?.keybindingGroups
                .contains { $0.title == "Application" } == false)
        }
    }

    @Test("keybinding browser state survives projection rebuilds")
    func presentationStateSurvivesProjectionRebuilds() throws {
        var model = openPreferences()
        let id: KeybindingActionID = "pane.focus-left"

        _ = update(&model, .prefSelectSection(.keybindings))
        _ = update(&model, .prefKeybindingSearchChanged("focus"))
        _ = update(&model, .prefKeybinding(.selectBrowserAction(id)))

        let projection = try #require(desiredPreferencesPanel(in: model))
        #expect(projection.section == .keybindings)
        #expect(projection.keybindingSearchText == "focus")
        #expect(projection.keybindingGroups.flatMap(\.actions).map(\.id) == [
            "pane.focus-left", "pane.focus-down", "pane.focus-up", "pane.focus-right",
        ])
        #expect(projection.keybindingGroups.flatMap(\.actions).first?.isSelected == true)
    }
}

private func openPreferences(_ config: DanTermConfig = .default) -> AppModel {
    var model = makeModel()
    model.config = config
    _ = update(&model, .preferencesOpened())
    return model
}

private func savedConfigs(in commands: [Command]) -> [DanTermConfig] {
    commands.compactMap { command in
        guard case .saveDanTermConfig(let config) = command else { return nil }
        return config
    }
}

private func chords(_ values: String...) -> [KeyChord] {
    values.map { KeyChord(compact: $0)! }
}
