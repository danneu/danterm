// One hardware-keyboard press, as the UIKit-free facts the decision needs, plus the
// decision itself: which presses become terminal key events and which belong to the
// phone's text-input system.
//
// It lives in the kit rather than in the app so both the rule and the named-key table run
// under the macOS test gate. What does not belong here: anything UIKit-shaped. The press
// is built from `UIPress` in the app, and the modifier translation stays there too.
import DanTermProtocol

/// The facts of one hardware-keyboard press, in a vocabulary with no UIKit in it.
///
/// The HID usage code is carried as a plain `Int` because USB HID usages are a
/// platform-independent standard: `UIKeyboardHIDUsage` is one spelling of the same
/// numbers, so the app can hand its raw value over without the kit importing UIKit.
///
/// Cmd is a separate fact rather than a `KeyMods` member because the wire has no Cmd
/// modifier -- it can only decide whether a press is ours, never travel with one.
public struct MobileHardwareKeyPress: Equatable, Sendable {
    public let hidUsage: Int
    /// UIKit's unshifted, lowercase form of the key's characters.
    public let charactersIgnoringModifiers: String
    public let modifiers: KeyMods
    public let isCommandHeld: Bool

    public init(
        hidUsage: Int,
        charactersIgnoringModifiers: String,
        modifiers: KeyMods,
        isCommandHeld: Bool
    ) {
        self.hidUsage = hidUsage
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
        self.isCommandHeld = isCommandHeld
    }

    /// The key this press sends to the pane, or nothing when the press belongs to the
    /// text-input system instead.
    ///
    /// Declining is the whole point of the type: a press that returns nothing is one the
    /// shell must leave to `super.pressesBegan`, so `Shift+A` inserts `A` and `Shift+2`
    /// inserts `@` through the same road unmodified typing already takes. A character
    /// chord exists only under Ctrl or Alt without Cmd -- the Mac surface's rule -- so no
    /// caller can construct a Shift-only or unmodified character key event from a press.
    public var terminalKey: KeyName? {
        if let named = Self.namedKey(forHIDUsage: hidUsage) { return .named(named) }
        guard isCommandHeld == false,
              modifiers.contains(.ctrl) || modifiers.contains(.alt),
              let character = Self.wireCharacter(from: charactersIgnoringModifiers)
        else {
            return nil
        }
        return .character(character)
    }

    /// The named key a HID usage code stands for, or nothing when the key is a character
    /// key or one the terminal vocabulary has no name for.
    private static func namedKey(forHIDUsage usage: Int) -> NamedKey? {
        // USB HID keyboard usage page values, as UIKit spells them in `UIKeyboardHIDUsage`.
        switch usage {
        case 0x28: return .enter
        case 0x2B: return .tab
        case 0x2A: return .bspace
        case 0x29: return .escape
        case 0x52: return .up
        case 0x51: return .down
        case 0x50: return .left
        case 0x4F: return .right
        case 0x4A: return .home
        case 0x4D: return .end
        case 0x4B: return .pgUp
        case 0x4E: return .pgDn
        case 0x49: return .insert
        case 0x4C: return .delete
        default: return nil
        }
    }

    /// Canonicalizes typed characters to the one character a chord may carry on the wire,
    /// or nothing when they fall outside that domain.
    ///
    /// The domain is `KeyName(wireName:)`'s own -- exactly one printable ASCII scalar,
    /// lowercase for letters -- so it decides by asking that initializer rather than by
    /// restating its rule. A chord outside it would serialize and then fail IPC decode,
    /// which loses the keystroke instead of typing it.
    static func wireCharacter(from text: String) -> Character? {
        guard case .character(let character)? = KeyName(wireName: text.lowercased()) else {
            return nil
        }
        return character
    }
}
