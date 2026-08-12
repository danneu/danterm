// Structured input events used by the `pane.input` IPC method to drive a pane
// as if the user typed at the keyboard. The CLI parses argv tokens into these
// values; the wire form encodes via `KeyName.wireName` and decodes one-to-one
// via `KeyName(wireName:)`, an inverse pinned by protocol tests.
import Foundation

public enum InputEvent: Equatable, Sendable {
    case text(String)
    case key(KeyName, KeyMods)
}

// One of the closed set of key names danterm understands.
public enum KeyName: Equatable, Sendable {
    case named(NamedKey)
    // Single lowercase ASCII letter, used for modifier-letter combos (e.g. C-c).
    case letter(Character)

    /// Canonical IPC serialization name for a key event.
    public var wireName: String {
        switch self {
        case .letter(let c):
            return String(c)
        case .named(let n):
            return n.wireName
        }
    }

    /// Decodes a case-sensitive wire `key` string so IPC can reject unknown keys.
    public init?(wireName: String) {
        if let canonical = KeyName.namedAliases[wireName] {
            self = .named(canonical)
            return
        }
        if wireName.count == 1,
           let c = wireName.first,
           c.isASCII, c.isLetter, c.isLowercase {
            self = .letter(c)
            return
        }
        return nil
    }

    /// Wire-name lookup derived from `NamedKey.wireName`, plus decode-only aliases.
    public static let namedAliases: [String: NamedKey] = {
        var map = Dictionary(uniqueKeysWithValues: NamedKey.allCases.map { ($0.wireName, $0) })
        map["Backspace"] = .bspace
        map["Esc"] = .escape
        return map
    }()
}

public enum NamedKey: Equatable, CaseIterable, Sendable {
    case enter
    case tab
    case bspace
    case escape
    case up
    case down
    case left
    case right
    case home
    case end
    case pgUp
    case pgDn
    case delete
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    // Update integrations/danterm/SKILL.md's human-facing key list when adding a case.
    /// Canonical IPC serialization name for a named key.
    public var wireName: String {
        switch self {
        case .enter:  return "Enter"
        case .tab:    return "Tab"
        case .bspace: return "BSpace"
        case .escape: return "Escape"
        case .up:     return "Up"
        case .down:   return "Down"
        case .left:   return "Left"
        case .right:  return "Right"
        case .home:   return "Home"
        case .end:    return "End"
        case .pgUp:   return "PgUp"
        case .pgDn:   return "PgDn"
        case .delete: return "Delete"
        case .f1:  return "F1"
        case .f2:  return "F2"
        case .f3:  return "F3"
        case .f4:  return "F4"
        case .f5:  return "F5"
        case .f6:  return "F6"
        case .f7:  return "F7"
        case .f8:  return "F8"
        case .f9:  return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        }
    }
}

public struct KeyMods: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let ctrl = KeyMods(rawValue: 1 << 0)
    public static let alt  = KeyMods(rawValue: 1 << 1)
    /// Preserves Shift on named keys whose terminal encoding distinguishes it.
    public static let shift = KeyMods(rawValue: 1 << 2)

    // Decode from a wire `mods` array. Throws on unknown or non-string entries
    // so the IPC handler can surface "unknown mod <name>" / structural errors.
    public static func decode(wire entries: [String]) throws -> KeyMods {
        var mods: KeyMods = []
        for name in entries {
            switch name {
            case "ctrl": mods.insert(.ctrl)
            case "alt":  mods.insert(.alt)
            case "shift": mods.insert(.shift)
            default:
                throw KeyModsDecodeError.unknown(name)
            }
        }
        return mods
    }
}

public enum KeyModsDecodeError: Error, Equatable {
    case unknown(String)
}
