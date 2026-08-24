// Pure physical-side routing for the macOS Option-as-Alt setting.
import DanTermProtocol

/// Physical Option sides held for one key event; an empty value means side data was absent.
struct OptionKeySides: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let left = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
}

/// Decides whether a text-producing Option event bypasses native text input for terminal Alt.
func optionRoutesToTerminalAlt(policy: OptionAsAlt?, heldSides: OptionKeySides) -> Bool {
    guard let policy else { return false }
    let effectiveSides: OptionKeySides = heldSides.isEmpty ? .left : heldSides
    switch policy {
    case .left:
        return effectiveSides.contains(.left)
    case .right:
        return effectiveSides.contains(.right)
    case .both:
        return true
    }
}
