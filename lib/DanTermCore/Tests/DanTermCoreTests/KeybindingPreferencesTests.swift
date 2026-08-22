// Behavioral proofs for atomic keybinding edits in the Settings draft.
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct KeybindingPreferencesTests {
    @Test("accepted edits update live and draft bindings in one save")
    func acceptedEditUpdatesLiveAndDraft() throws {
        var model = openPreferences()
        let chord = try #require(KeyChord(compact: "cmd+option+t"))

        let commands = update(&model, .prefKeybinding(.add(chord, to: "tab.new")))

        #expect(model.config.keybindingOverrides.chordsByAction["tab.new"] == chords("cmd+t", "cmd+option+t"))
        #expect(model.preferencesDraft?.config.keybindingOverrides == model.config.keybindingOverrides)
        #expect(savedConfigs(in: commands) == [model.config])
    }

    @Test("a configurable conflict waits for confirmation without changing config")
    func conflictWaitsForConfirmation() throws {
        var model = openPreferences()
        let original = model.config
        let chord = try #require(KeyChord(compact: "cmd+t"))

        let commands = update(&model, .prefKeybinding(.add(chord, to: "tab.new-group")))

        #expect(model.config == original)
        #expect(commands.isEmpty)
        #expect(model.preferencesDraft?.keybindingConflict == KeybindingConflict(
            chord: chord,
            source: "tab.new",
            destination: "tab.new-group"
        ))
    }

    @Test("confirming a move disables the displaced action and saves once")
    func confirmedMoveDisablesDisplacedAction() throws {
        var model = openPreferences()
        let chord = try #require(KeyChord(compact: "cmd+t"))
        _ = update(&model, .prefKeybinding(.add(chord, to: "tab.new-group")))

        let commands = update(&model, .prefKeybinding(.confirmConflictMove))

        #expect(model.config.keybindingOverrides.chordsByAction["tab.new"] == [])
        #expect(model.config.keybindingOverrides.chordsByAction["tab.new-group"] == chords("cmd+n", "cmd+t"))
        #expect(model.preferencesDraft?.keybindingConflict == nil)
        #expect(savedConfigs(in: commands) == [model.config])
    }

    @Test("reserved and gesture-invalid edits report inline without mutation")
    func invalidEditsDoNotMutate() throws {
        var model = openPreferences()
        let original = model.config
        let reserved = try #require(KeyChord(compact: "cmd+c"))
        let mismatchedMRU = try #require(KeyChord(compact: "cmd+option+i"))

        #expect(update(&model, .prefKeybinding(.add(reserved, to: "tab.new"))).isEmpty)
        #expect(model.preferencesDraft?.keybindingDiagnostic?.reason == "reserved by Copy")
        #expect(update(&model, .prefKeybinding(.replace([mismatchedMRU], for: "tab.recent-newer"))).isEmpty)
        #expect(model.preferencesDraft?.keybindingDiagnostic?.reason == "must use the same modifiers as tab.recent-older")
        #expect(model.config == original)
    }

    @Test("remove, reorder, disable, reset, and Reset All preserve valid effective bindings")
    func allEditOperations() throws {
        var config = DanTermConfig.default
        let first = try #require(KeyChord(compact: "cmd+option+t"))
        let second = try #require(KeyChord(compact: "ctrl+option+t"))
        config.keybindingOverrides = KeybindingOverrides(["tab.new": [first, second]])
        var model = openPreferences(config)

        _ = update(&model, .prefKeybinding(.makePrimary(chordAt: 1, for: "tab.new")))
        #expect(model.config.keybindingOverrides.chordsByAction["tab.new"] == [second, first])
        _ = update(&model, .prefKeybinding(.remove(chordAt: 1, from: "tab.new")))
        #expect(model.config.keybindingOverrides.chordsByAction["tab.new"] == [second])
        _ = update(&model, .prefKeybinding(.disable("tab.new")))
        #expect(model.config.keybindingOverrides.chordsByAction["tab.new"] == [])
        _ = update(&model, .prefKeybinding(.reset("tab.new")))
        #expect(model.config.keybindingOverrides.chordsByAction["tab.new"] == nil)
        _ = update(&model, .prefKeybinding(.replace([first], for: "tab.new")))
        _ = update(&model, .prefKeybinding(.resetAll))
        #expect(model.config.keybindingOverrides == .empty)
    }

    @Test("recording state is model-owned and reload clears transient state")
    func recordingAndReload() {
        var model = openPreferences()
        _ = update(&model, .prefKeybinding(.beginRecording("tab.new")))
        #expect(model.preferencesDraft?.recordingKeybindingFor == "tab.new")
        _ = update(&model, .prefKeybinding(.cancelRecording))
        #expect(model.preferencesDraft?.recordingKeybindingFor == nil)

        _ = update(&model, .prefKeybinding(.beginRecording("tab.new")))
        _ = update(&model, .configLoaded(.default, resolvedFontFamily: nil))
        #expect(model.preferencesDraft?.recordingKeybindingFor == nil)
        #expect(model.preferencesDraft?.keybindingConflict == nil)
        #expect(model.preferencesDraft?.keybindingDiagnostic == nil)
    }

    @Test("an unrepresentable recording failure stays in model state")
    func recordingFailureIsModelOwned() {
        var model = openPreferences()
        _ = update(&model, .prefKeybinding(.beginRecording("tab.new")))
        let diagnostic = KeybindingDiagnostic(
            path: "keybindings.tab.new",
            reason: "a shortcut requires Cmd, Control, or Option"
        )

        let commands = update(&model, .prefKeybinding(.rejectRecording(diagnostic)))

        #expect(commands.isEmpty)
        #expect(model.preferencesDraft?.recordingKeybindingFor == nil)
        #expect(model.preferencesDraft?.keybindingDiagnostic == diagnostic)
    }

    @Test("a later General save retains an accepted binding edit")
    func laterGeneralSaveRetainsBinding() throws {
        var model = openPreferences()
        let chord = try #require(KeyChord(compact: "cmd+option+t"))
        _ = update(&model, .prefKeybinding(.replace([chord], for: "tab.new")))
        _ = update(&model, .prefSet(.alertClearMode(.manual)))

        let commands = update(&model, .prefSave)

        #expect(model.config.keybindingOverrides.chordsByAction["tab.new"] == [chord])
        #expect(savedConfigs(in: commands).first?.keybindingOverrides.chordsByAction["tab.new"] == [chord])
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
