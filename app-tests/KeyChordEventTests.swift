// Verifies that AppKit key events have one canonical KeyChord representation for both
// shortcut capture and runtime command recognition.
import AppKit
import DanTermProtocol
import Testing
@testable import DanTerm

struct KeyChordEventTests {
    @Test("a captured Control-punctuation chord matches the same runtime event")
    func capturedControlPunctuationMatchesRuntimeEvent() throws {
        // Intent: shortcut capture and runtime matching interpret the same physical event
        //   as the same chord.
        // Why it exists: separate event conversions let a captured Control-punctuation
        //   shortcut fail recognition when the local event monitor later saw it.
        // Scenario: Control-[ is captured, then the same event reaches command matching.
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "[",
            isARepeat: false,
            keyCode: 0x21
        ))

        let captured = try #require(keyChord(from: event))

        #expect(captured.compact == "ctrl+[")
        #expect(eventMatchesKeyChord(event, captured))
    }

    @Test("a modifier-release event yields its modifiers and no chord")
    func flagsChangedYieldsModifiersAndNoChord() throws {
        // Intent: a flagsChanged event reports the modifiers still held and never
        //   becomes a chord.
        // Why it exists: AppKit raises NSInternalInconsistencyException when a
        //   flagsChanged event is asked for its characters. The held-MRU monitor asked
        //   through keyChord(from:), so releasing Shift threw inside the monitor and
        //   the switcher never committed or dismissed.
        // Scenario: Shift is released while Command stays down during an MRU cycle.
        let event = try #require(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x38
        ))

        #expect(keyChordModifiers(from: event) == [.command])
        #expect(keyChord(from: event) == nil)
    }
}
