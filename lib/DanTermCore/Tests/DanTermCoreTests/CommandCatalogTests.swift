// Behavioral coverage for the configurable command catalog and effective bindings.
import Testing
import DanTermProtocol
@testable import DanTermCore

@Suite struct CommandCatalogTests {
    @Test("catalog contains each stable menu and toolbar action exactly once")
    func catalogCoverage() {
        let ids = commandCatalog.map(\.id)
        let expected: Set<KeybindingActionID> = [
            "app.import-state", "app.export-state", "app.settings", "app.open-config",
            "app.reload-config", "app.install-cli", "edit.find", "edit.find-next",
            "edit.find-previous", "view.toggle-theme-browser", "view.font-increase",
            "view.font-decrease", "view.font-reset", "view.toggle-sidebar", "view.toggle-alerts",
            "tab.new", "tab.new-at-end", "tab.new-group", "tab.rename", "tab.clear-title",
            "tab.next", "tab.previous", "tab.jump", "tab.recent-older", "tab.recent-newer",
            "tab.color-red", "tab.color-orange", "tab.color-yellow", "tab.color-green",
            "tab.color-blue", "tab.color-purple", "tab.color-gray", "tab.color-none",
            "tab.clear-alerts", "tab.toggle-todo", "tab.close", "pane.split-right",
            "pane.split-down", "pane.toggle-zoom", "pane.focus-left", "pane.focus-down",
            "pane.focus-up", "pane.focus-right", "pane.next-alert", "pane.clear-alerts",
            "pane.toggle-todo", "pane.close",
        ]

        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == expected)
        #expect(Set(commandCatalog.map(\.action)) == Set(ConfigurableCommand.allCases))
    }

    @Test("defaults preserve both font increase chords and modal gestures")
    func defaultsPreserveCurrentBindings() throws {
        let bindings = try #require(effectiveBindings(overrides: .empty).value)

        #expect(bindings["view.font-increase"] == chords("cmd+shift+plus", "cmd+="))
        #expect(bindings["tab.jump"] == chords("cmd+shift+f"))
        #expect(bindings["tab.recent-older"] == chords("cmd+shift+o"))
        #expect(bindings["tab.recent-newer"] == chords("cmd+shift+i"))
    }

    @Test("an override replaces all defaults and an empty override disables")
    func overrideAndDisable() throws {
        let result = effectiveBindings(overrides: KeybindingOverrides([
            "view.font-increase": chords("cmd+option+plus"),
            "tab.jump": [],
        ]))
        let bindings = try #require(result.value)

        #expect(bindings["view.font-increase"] == chords("cmd+option+plus"))
        #expect(bindings["tab.jump"] == [])
    }

    @Test("one configurable conflict rejects the whole candidate map")
    func configurableConflictIsAtomic() {
        let result = effectiveBindings(overrides: KeybindingOverrides([
            "tab.new": chords("ctrl+option+x"),
            "tab.new-group": chords("ctrl+option+x"),
        ]))

        #expect(result.value == nil)
        #expect(result.diagnostics == [KeybindingDiagnostic(
            path: "keybindings.tab.new-group[0]",
            reason: "conflicts with tab.new"
        )])
    }

    @Test("native responder and app shortcuts are reserved")
    func nativeReservationConflict() {
        let result = effectiveBindings(overrides: KeybindingOverrides([
            "tab.new": chords("cmd+c"),
        ]))

        #expect(result.value == nil)
        #expect(result.diagnostics == [KeybindingDiagnostic(
            path: "keybindings.tab.new[0]",
            reason: "reserved by Copy"
        )])
    }

    @Test("held MRU directions require one chord with matching modifiers")
    func heldMRUModifiersMustMatch() {
        let result = effectiveBindings(overrides: KeybindingOverrides([
            "tab.recent-newer": chords("cmd+option+i"),
        ]))

        #expect(result.value == nil)
        #expect(result.diagnostics == [KeybindingDiagnostic(
            path: "keybindings.tab.recent-newer[0]",
            reason: "must use the same modifiers as tab.recent-older"
        )])
    }

    @Test("held MRU mismatch identifies an Older-only override")
    func heldMRUOlderOverridePath() {
        let result = effectiveBindings(overrides: KeybindingOverrides([
            "tab.recent-older": chords("cmd+option+o"),
        ]))

        #expect(result.diagnostics == [KeybindingDiagnostic(
            path: "keybindings.tab.recent-older[0]",
            reason: "must use the same modifiers as tab.recent-newer"
        )])
    }
}

private func chords(_ values: String...) -> [KeyChord] {
    values.map { KeyChord(compact: $0)! }
}
