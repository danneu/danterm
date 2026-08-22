// Behavioral proofs for canonical keybinding values at the shared config boundary.
import Foundation
import Testing

@testable import DanTermProtocol

struct KeybindingConfigTests {
    @Test("canonical chords round-trip through their compact config spelling")
    func canonicalChordRoundTrip() throws {
        let chord = try #require(KeyChord(compact: "cmd+ctrl+option+shift+left"))

        #expect(chord.modifiers == [.command, .control, .option, .shift])
        #expect(chord.key == .named(.left))
        #expect(chord.compact == "cmd+ctrl+option+shift+left")
    }

    @Test("compact chords reject ambiguous or non-activating spellings", arguments: [
        "a", "shift+a", "cmd+H", "cmd++", "cmd+!", "cmd+_", "shift+space", "cmd+unknown",
        "cmd+cmd+t", "option+", "cmd+ctrl",
    ])
    func rejectsInvalidChordSpellings(_ source: String) {
        #expect(KeyChord(compact: source) == nil)
    }

    @Test("typed chords reject modifier bits outside the config grammar")
    func rejectsUnknownModifierBits() throws {
        let key = try #require(KeybindingKey.character("t"))

        #expect(KeyChord(modifiers: KeyModifiers(rawValue: 0xff), key: key) == nil)
    }

    @Test("document projection atomically accepts known overrides and ignores unknown ids")
    func projectsKnownOverrides() throws {
        let document = try #require(DanTermConfigDocument.decode(data(#"{"schemaVersion":1,"keybindings":{"tab.new":["cmd+t"],"tab.jump":[],"future.action":{"shape":2}}}"#)))

        let result = document.projectKeybindings(knownActionIDs: ["tab.new", "tab.jump"])

        #expect(result == .replacement(KeybindingOverrides([
            "tab.new": [try #require(KeyChord(compact: "cmd+t"))],
            "tab.jump": [],
        ])))
    }

    @Test("one malformed known override rejects the whole section with its exact path")
    func rejectsKnownSectionAtomically() throws {
        let document = try #require(DanTermConfigDocument.decode(data(#"{"schemaVersion":1,"keybindings":{"tab.new":["cmd+t"],"pane.focus-left":["cmd+H"]}}"#)))

        let result = document.projectKeybindings(knownActionIDs: ["tab.new", "pane.focus-left"])

        #expect(result == .rejected([
            KeybindingDiagnostic(path: "keybindings.pane.focus-left[0]", reason: "invalid chord \"cmd+H\"")
        ]))
    }

    @Test("absent keybindings are distinct from an empty replacement")
    func absentAndEmptyAreDistinct() throws {
        let absent = try #require(DanTermConfigDocument.decode(DanTermConfigDocument.seedData))
        let empty = try #require(DanTermConfigDocument.decode(data(#"{"schemaVersion":1,"keybindings":{}}"#)))

        #expect(absent.projectKeybindings(knownActionIDs: ["tab.new"]) == .absent)
        #expect(empty.projectKeybindings(knownActionIDs: ["tab.new"]) == .replacement(.empty))
    }

    @Test("applying overrides preserves unknown entries and exact number tokens")
    func appliesOverridesWithoutDroppingUnknownContent() throws {
        var document = try #require(DanTermConfigDocument.decode(data(#"{"schemaVersion":1,"keybindings":{"tab.new":["cmd+n"],"future.action":{"threshold":9007199254740993}},"future":0.10}"#)))
        let replacement = KeybindingOverrides([
            "tab.new": [try #require(KeyChord(compact: "cmd+t"))],
            "tab.jump": [],
        ])

        document.applyKeybindings(replacement, knownActionIDs: ["tab.new", "tab.jump"])
        let output = String(decoding: document.encoded(), as: UTF8.self)

        #expect(output.contains("9007199254740993"))
        #expect(output.contains("0.10"))
        #expect(output.contains(#""future.action": {"#))
        let roundTrip = try #require(DanTermConfigDocument.decode(document.encoded()))
        #expect(roundTrip.projectKeybindings(knownActionIDs: ["tab.new", "tab.jump"]) == .replacement(replacement))
    }

    @Test("applying a reset removes its known override without touching unknown entries")
    func resetRemovesKnownOverride() throws {
        var document = try #require(DanTermConfigDocument.decode(data(#"{"schemaVersion":1,"keybindings":{"tab.new":["cmd+n"],"future.action":["future+syntax"]}}"#)))

        document.applyKeybindings(.empty, knownActionIDs: ["tab.new"])
        let output = String(decoding: document.encoded(), as: UTF8.self)

        #expect(output.contains(#""tab.new""#) == false)
        #expect(output.contains(#""future.action""#))
        #expect(output.contains(#""future+syntax""#))
        let roundTrip = try #require(DanTermConfigDocument.decode(document.encoded()))
        #expect(roundTrip.projectKeybindings(knownActionIDs: ["tab.new"]) == .replacement(.empty))
    }
}

private func data(_ string: String) -> Data {
    Data(string.utf8)
}
