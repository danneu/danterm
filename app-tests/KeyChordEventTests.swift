// Verifies that AppKit key events have one canonical KeyChord representation for both
// shortcut capture and runtime command recognition.
import AppKit
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
}
