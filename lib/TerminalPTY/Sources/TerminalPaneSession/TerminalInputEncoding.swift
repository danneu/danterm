// AppKit-free key vocabulary and byte-exact encoding for the viability slice.

/// Names only the keys whose initial terminal byte forms are product-pinned.
public enum TerminalInputKey: Equatable, Sendable {
    case returnKey
    case tab
    case backspace
    case escape
    case up
    case down
    case right
    case left
    case home
    case end
    case pageUp
    case pageDown
    case deleteForward
    case letter(Unicode.Scalar)
}

/// Carries platform-neutral modifiers so the app can map NSEvent and IPC keys identically.
public struct TerminalKeyModifiers: OptionSet, Equatable, Sendable {
    /// Stable modifier bits shared without platform event types.
    public let rawValue: UInt8

    /// Creates a modifier set from its stable bit representation.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Shift remains explicit for app mapping even though it does not alter the fixed table.
    public static let shift = Self(rawValue: 1 << 0)
    /// Control selects ASCII control bytes for letter keys.
    public static let control = Self(rawValue: 1 << 1)
    /// Option remains explicit so the app never silently treats it as Alt escape prefixing.
    public static let option = Self(rawValue: 1 << 2)
    /// Command remains explicit so platform shortcuts can be filtered before submission.
    public static let command = Self(rawValue: 1 << 3)
}

/// Encodes the fixed CSI-normal table and ASCII Ctrl letters; unsupported input drops.
public func encodeTerminalKey(
    _ key: TerminalInputKey,
    modifiers: TerminalKeyModifiers
) -> [UInt8]? {
    switch key {
    case .returnKey: return [0x0D]
    case .tab: return [0x09]
    case .backspace: return [0x7F]
    case .escape: return [0x1B]
    case .up: return [0x1B, 0x5B, 0x41]
    case .down: return [0x1B, 0x5B, 0x42]
    case .right: return [0x1B, 0x5B, 0x43]
    case .left: return [0x1B, 0x5B, 0x44]
    case .home: return [0x1B, 0x5B, 0x48]
    case .end: return [0x1B, 0x5B, 0x46]
    case .pageUp: return [0x1B, 0x5B, 0x35, 0x7E]
    case .pageDown: return [0x1B, 0x5B, 0x36, 0x7E]
    case .deleteForward: return [0x1B, 0x5B, 0x33, 0x7E]
    case .letter(let scalar):
        guard modifiers.contains(.control) else { return nil }
        switch scalar.value {
        case 65...90: return [UInt8(scalar.value - 64)]
        case 97...122: return [UInt8(scalar.value - 96)]
        default: return nil
        }
    }
}
