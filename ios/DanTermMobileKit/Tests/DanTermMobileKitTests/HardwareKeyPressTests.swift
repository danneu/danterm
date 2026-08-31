// Behavioral tests for the hardware-keyboard press decision: which presses become terminal
// key events and which fall through to the phone's text-input system.
import DanTermMobileKit
import DanTermProtocol
import Testing

// The HID usage codes the decision's named-key table is keyed by, spelled here from the
// USB HID standard so a test states the number UIKit would have delivered.
private enum HID {
    static let a = 0x04
    static let enter = 0x28
    static let escape = 0x29
    static let backspace = 0x2A
    static let tab = 0x2B
    static let two = 0x1F
    static let insert = 0x49
    static let home = 0x4A
    static let pageUp = 0x4B
    static let deleteForward = 0x4C
    static let end = 0x4D
    static let pageDown = 0x4E
    static let rightArrow = 0x4F
    static let leftArrow = 0x50
    static let downArrow = 0x51
    static let upArrow = 0x52
}

@Test("Shift-only and unmodified character presses leave the press to the text system")
func shiftOnlyCharacterPressesDecline() {
    // Intent: a character press without Ctrl or Alt produces no terminal key event, so the
    //   press falls through to UIKit's text-input system.
    // Why it exists: MOBAPP-1 -- claiming the press for any non-empty modifier set made
    //   Shift+A type `a` and Shift+2 type `2`, because the unshifted characters are what
    //   the press carries and the wire encoder ignores Shift on a character key.
    #expect(MobileHardwareKeyPress(
        hidUsage: HID.a,
        charactersIgnoringModifiers: "a",
        modifiers: .shift,
        isCommandHeld: false
    ).terminalKey == nil)

    #expect(MobileHardwareKeyPress(
        hidUsage: HID.two,
        charactersIgnoringModifiers: "2",
        modifiers: .shift,
        isCommandHeld: false
    ).terminalKey == nil)

    #expect(MobileHardwareKeyPress(
        hidUsage: HID.a,
        charactersIgnoringModifiers: "a",
        modifiers: [],
        isCommandHeld: false
    ).terminalKey == nil)
}

@Test("Ctrl and Alt character chords dispatch the lowercase unshifted character")
func controlAndAltCharacterChordsDispatch() {
    #expect(MobileHardwareKeyPress(
        hidUsage: HID.a,
        charactersIgnoringModifiers: "a",
        modifiers: .ctrl,
        isCommandHeld: false
    ).terminalKey == .character("a"))

    #expect(MobileHardwareKeyPress(
        hidUsage: HID.a,
        charactersIgnoringModifiers: "a",
        modifiers: .alt,
        isCommandHeld: false
    ).terminalKey == .character("a"))

    #expect(MobileHardwareKeyPress(
        hidUsage: HID.a,
        charactersIgnoringModifiers: "a",
        modifiers: [.ctrl, .shift],
        isCommandHeld: false
    ).terminalKey == .character("a"))
}

@Test("A caps-lock uppercase delivery canonicalizes to the lowercase chord")
func uppercaseDeliveryCanonicalizes() {
    // Intent: an uppercase ASCII character under Ctrl reaches the wire lowercased.
    // Why it exists: the wire's character domain is lowercase letters, so an uppercase
    //   chord would serialize and then fail IPC decode, losing the keystroke.
    #expect(MobileHardwareKeyPress(
        hidUsage: HID.a,
        charactersIgnoringModifiers: "A",
        modifiers: .ctrl,
        isCommandHeld: false
    ).terminalKey == .character("a"))
}

@Test("Characters outside the wire's domain decline rather than produce an undecodable key")
func nonCanonicalCharactersDecline() {
    // Intent: a chord whose character is not one printable ASCII scalar produces no key
    //   event at all.
    // Why it exists: `KeyName(wireName:)` would reject such a character on decode, so
    //   dispatching one loses the input silently instead of typing it.
    let cases = ["é", "e\u{0301}", "", "ab", "\u{7F}"]
    for characters in cases {
        #expect(MobileHardwareKeyPress(
            hidUsage: HID.a,
            charactersIgnoringModifiers: characters,
            modifiers: .ctrl,
            isCommandHeld: false
        ).terminalKey == nil, "expected \(characters.debugDescription) to decline")
    }
}

@Test("A Cmd-held character chord stays with the system")
func commandCharacterChordsDecline() {
    // Intent: Cmd+C produces no terminal key event even though Ctrl or Alt may also be
    //   held.
    // Why it exists: Cmd chords belong to the system and to future line editing, and the
    //   wire has no Cmd modifier to carry them faithfully.
    #expect(MobileHardwareKeyPress(
        hidUsage: 0x06,
        charactersIgnoringModifiers: "c",
        modifiers: [],
        isCommandHeld: true
    ).terminalKey == nil)

    #expect(MobileHardwareKeyPress(
        hidUsage: 0x06,
        charactersIgnoringModifiers: "c",
        modifiers: .ctrl,
        isCommandHeld: true
    ).terminalKey == nil)
}

@Test("Every named key dispatches whatever the modifiers are")
func namedKeysAlwaysDispatch() {
    // Intent: the full named-key table maps its HID usage to its wire key, under no
    //   modifiers, under Shift alone, and under Cmd.
    // Why it exists: named keys are the one route that must not change with this fix --
    //   Shift+Tab and Cmd+Left still have to reach the pane.
    let rows: [(Int, NamedKey)] = [
        (HID.enter, .enter),
        (HID.tab, .tab),
        (HID.backspace, .bspace),
        (HID.escape, .escape),
        (HID.upArrow, .up),
        (HID.downArrow, .down),
        (HID.leftArrow, .left),
        (HID.rightArrow, .right),
        (HID.home, .home),
        (HID.end, .end),
        (HID.pageUp, .pgUp),
        (HID.pageDown, .pgDn),
        (HID.insert, .insert),
        (HID.deleteForward, .delete),
    ]
    for (usage, key) in rows {
        #expect(MobileHardwareKeyPress(
            hidUsage: usage,
            charactersIgnoringModifiers: "",
            modifiers: [],
            isCommandHeld: false
        ).terminalKey == .named(key))

        #expect(MobileHardwareKeyPress(
            hidUsage: usage,
            charactersIgnoringModifiers: "",
            modifiers: .shift,
            isCommandHeld: false
        ).terminalKey == .named(key))

        #expect(MobileHardwareKeyPress(
            hidUsage: usage,
            charactersIgnoringModifiers: "",
            modifiers: [],
            isCommandHeld: true
        ).terminalKey == .named(key))
    }
}
