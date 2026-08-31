// Converts AppKit key events into the canonical chord representation shared by
// shortcut capture and runtime command recognition.
import Cocoa
import DanTermProtocol

/// Gives every AppKit key-event consumer the same layout-aware chord conversion.
func keyChord(from event: NSEvent) -> KeyChord? {
    var modifiers: DanTermProtocol.KeyModifiers = []
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command) { modifiers.insert(.command) }
    if flags.contains(.control) { modifiers.insert(.control) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    let key: KeybindingKey?
    switch event.keyCode {
    case 0x24, 0x4c: key = .named(.enter)
    case 0x30: key = .named(.tab)
    case 0x31: key = .named(.space)
    case 0x33: key = .named(.backspace)
    case 0x35: key = .named(.escape)
    case 0x75: key = .named(.delete)
    case 0x72: key = .named(.insert)
    case 0x73: key = .named(.home)
    case 0x74: key = .named(.pageUp)
    case 0x77: key = .named(.end)
    case 0x79: key = .named(.pageDown)
    case 0x7b: key = .named(.left)
    case 0x7c: key = .named(.right)
    case 0x7d: key = .named(.down)
    case 0x7e: key = .named(.up)
    case 0x7a: key = .named(.f1)
    case 0x78: key = .named(.f2)
    case 0x63: key = .named(.f3)
    case 0x76: key = .named(.f4)
    case 0x60: key = .named(.f5)
    case 0x61: key = .named(.f6)
    case 0x62: key = .named(.f7)
    case 0x64: key = .named(.f8)
    case 0x65: key = .named(.f9)
    case 0x6d: key = .named(.f10)
    case 0x67: key = .named(.f11)
    case 0x6f: key = .named(.f12)
    case 0x69: key = .named(.f13)
    case 0x6b: key = .named(.f14)
    case 0x71: key = .named(.f15)
    case 0x6a: key = .named(.f16)
    case 0x40: key = .named(.f17)
    case 0x4f: key = .named(.f18)
    case 0x50: key = .named(.f19)
    case 0x5a: key = .named(.f20)
    default:
        let text = event.characters(byApplyingModifiers: [])?.lowercased()
        if text == "+" { key = .named(.plus) }
        else if let character = text?.first { key = .character(character) }
        else { key = nil }
    }
    guard let key else { return nil }
    return KeyChord(modifiers: modifiers, key: key)
}

/// Matches runtime key events with the same conversion used when a chord is captured.
func eventMatchesKeyChord(_ event: NSEvent, _ chord: KeyChord) -> Bool {
    keyChord(from: event) == chord
}
