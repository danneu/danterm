// Typed, layout-free keybinding values shared by config readers and the app.

/// Identifies a configurable command independently of its presentation or implementation.
public struct KeybindingActionID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    /// Creates an action id from its stable dotted config spelling.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Supports concise catalog and test declarations without weakening the stored type.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

/// Names modifiers in the canonical order used by the config grammar.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
}

/// Names keys that need an unambiguous word instead of a literal character.
public enum KeybindingNamedKey: String, CaseIterable, Hashable, Sendable {
    case plus
    case space
    case tab
    case enter
    case escape
    case backspace
    case delete
    case insert
    case left
    case right
    case up
    case down
    case home
    case end
    case pageUp = "pageup"
    case pageDown = "pagedown"
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case f13, f14, f15, f16, f17, f18, f19, f20
}

/// Represents one unshifted logical key in a canonical chord.
public struct KeybindingKey: Hashable, Sendable {
    private let compactValue: String

    /// Creates a key from a portable unshifted printable character.
    public static func character(_ character: Character) -> Self? {
        let unshiftedPunctuation = "`-=[]\\;',./"
        guard character.isASCII,
              character.isLowercase || character.isNumber || unshiftedPunctuation.contains(character)
        else { return nil }
        return Self(compactValue: String(character))
    }

    /// Creates a key from a documented name for a non-literal key.
    public static func named(_ key: KeybindingNamedKey) -> Self {
        Self(compactValue: key.rawValue)
    }

    fileprivate var compact: String { compactValue }
}

/// Represents one canonical, layout-free activation chord.
public struct KeyChord: Hashable, Sendable {
    public let modifiers: KeyModifiers
    public let key: KeybindingKey

    /// Creates a chord after enforcing the non-Shift activation requirement.
    public init?(modifiers: KeyModifiers, key: KeybindingKey) {
        let supported: KeyModifiers = [.command, .control, .option, .shift]
        guard modifiers.subtracting(supported).isEmpty,
              modifiers.intersection([.command, .control, .option]).isEmpty == false
        else { return nil }
        self.modifiers = modifiers
        self.key = key
    }

    /// Parses the strict compact config spelling without accepting aliases.
    public init?(compact: String) {
        let tokens = compact.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count >= 2, let keyToken = tokens.last, keyToken.isEmpty == false else { return nil }

        var modifiers: KeyModifiers = []
        var previousOrder = -1
        for token in tokens.dropLast() {
            let item: (KeyModifiers, Int)
            switch token {
            case "cmd": item = (.command, 0)
            case "ctrl": item = (.control, 1)
            case "option": item = (.option, 2)
            case "shift": item = (.shift, 3)
            default: return nil
            }
            guard item.1 > previousOrder, modifiers.contains(item.0) == false else { return nil }
            modifiers.insert(item.0)
            previousOrder = item.1
        }

        let key: KeybindingKey
        if let named = KeybindingNamedKey(rawValue: keyToken) {
            key = .named(named)
        } else {
            guard keyToken.count == 1,
                  let character = keyToken.first,
                  let characterKey = KeybindingKey.character(character)
            else { return nil }
            key = characterKey
        }
        self.init(modifiers: modifiers, key: key)
    }

    /// Returns the only config spelling accepted for this chord.
    public var compact: String {
        var tokens: [String] = []
        if modifiers.contains(.command) { tokens.append("cmd") }
        if modifiers.contains(.control) { tokens.append("ctrl") }
        if modifiers.contains(.option) { tokens.append("option") }
        if modifiers.contains(.shift) { tokens.append("shift") }
        tokens.append(key.compact)
        return tokens.joined(separator: "+")
    }
}

/// Stores explicit action replacements; an empty chord array disables its action.
public struct KeybindingOverrides: Equatable, Sendable {
    public static let empty = Self()

    public var chordsByAction: [KeybindingActionID: [KeyChord]]

    public init(_ chordsByAction: [KeybindingActionID: [KeyChord]] = [:]) {
        self.chordsByAction = chordsByAction
    }
}

/// Identifies one invalid known config value precisely enough to repair by hand.
public struct KeybindingDiagnostic: Equatable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// Distinguishes default use, an atomic replacement, and a rejected known section.
public enum KeybindingSectionLoadResult: Equatable, Sendable {
    case absent
    case replacement(KeybindingOverrides)
    case rejected([KeybindingDiagnostic])
}
