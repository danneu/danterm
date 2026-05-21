// Structured input events used by the `pane.input` IPC method to drive a pane
// as if the user typed at the keyboard. The CLI parses argv tokens into these
// values; the wire form decodes one-to-one via `KeyName(wireName:)`.
import Foundation

public enum InputEvent: Equatable {
    case text(String)
    case key(KeyName, KeyMods)
}

// One of the closed set of key names danterm understands.
public enum KeyName: Equatable {
    case named(NamedKey)
    // Single lowercase ASCII letter, used for modifier-letter combos (e.g. C-c).
    case letter(Character)

    // Decode a wire `key` string. Case-sensitive, returns nil for anything
    // outside the closed set so the caller can surface a JSON-RPC error.
    public init?(wireName: String) {
        if let canonical = KeyName.namedAliases[wireName] {
            self = .named(canonical)
            return
        }
        if let fn = KeyName.parseFunctionKey(wireName) {
            self = .named(fn)
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

    // Wire-name -> canonical NamedKey. The map is the single source of truth
    // for the accepted keynames; aliases (BSpace/Backspace, Esc/Escape) map to
    // the same canonical case.
    public static let namedAliases: [String: NamedKey] = [
        "Enter": .enter,
        "Tab": .tab,
        "BSpace": .bspace,
        "Backspace": .bspace,
        "Escape": .escape,
        "Esc": .escape,
        "Up": .up,
        "Down": .down,
        "Left": .left,
        "Right": .right,
        "Home": .home,
        "End": .end,
        "PgUp": .pgUp,
        "PgDn": .pgDn,
        "Delete": .delete,
    ]

    private static func parseFunctionKey(_ name: String) -> NamedKey? {
        switch name {
        case "F1": return .f1
        case "F2": return .f2
        case "F3": return .f3
        case "F4": return .f4
        case "F5": return .f5
        case "F6": return .f6
        case "F7": return .f7
        case "F8": return .f8
        case "F9": return .f9
        case "F10": return .f10
        case "F11": return .f11
        case "F12": return .f12
        default: return nil
        }
    }
}

public enum NamedKey: Equatable, CaseIterable {
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
}

public struct KeyMods: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let ctrl = KeyMods(rawValue: 1 << 0)
    public static let alt  = KeyMods(rawValue: 1 << 1)

    // Decode from a wire `mods` array. Throws on unknown or non-string entries
    // so the IPC handler can surface "unknown mod <name>" / structural errors.
    public static func decode(wire entries: [String]) throws -> KeyMods {
        var mods: KeyMods = []
        for name in entries {
            switch name {
            case "ctrl": mods.insert(.ctrl)
            case "alt":  mods.insert(.alt)
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
