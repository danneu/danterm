// Maps phone controls to pane input intent without encoding terminal bytes on the client.
import DanTermProtocol

/// Describes either owner-side input or a local replica viewport movement.
public enum MobileInputAction: Equatable, Sendable {
    case send(IpcPaneInput)
    case scrollViewport(Int)
}

/// Names every key in the step-0 phone accessory row.
public enum MobileAccessoryKey: Equatable, Sendable {
    case escape
    case control
    case tab
    case up
    case down
    case left
    case right
    case pipe
    case tilde
    case slash
}

/// Converts normalized UIKit input into the two D8 wire forms while owning Ctrl latch state.
public struct MobileInputMapper: Equatable, Sendable {
    public private(set) var isControlLatched = false

    /// Creates a mapper with no active modifier latch.
    public init() {}

    /// Keeps ordinary committed text on the raw event-token path.
    public mutating func text(_ text: String) -> MobileInputAction {
        .send(.events([.text(text)]))
    }

    /// Keeps a paste gesture on the top-level safe-paste path.
    public mutating func paste(_ text: String) -> MobileInputAction {
        .send(.text(text))
    }

    /// Sends the keyboard's backspace as the named key the owner already encodes.
    ///
    /// The Ctrl latch is deliberately not read: it belongs to the accessory row alone, as
    /// it does for typed text.
    public mutating func deleteBackward() -> MobileInputAction {
        named(.bspace, modifiers: [])
    }

    /// Applies one accessory-row key, toggling Ctrl without producing traffic itself.
    public mutating func accessory(_ key: MobileAccessoryKey) -> MobileInputAction? {
        if key == .control {
            isControlLatched.toggle()
            return nil
        }
        let modifiers: KeyMods = isControlLatched ? .ctrl : []
        switch key {
        case .escape: return named(.escape, modifiers: modifiers)
        case .tab: return named(.tab, modifiers: modifiers)
        case .up: return named(.up, modifiers: modifiers)
        case .down: return named(.down, modifiers: modifiers)
        case .left: return named(.left, modifiers: modifiers)
        case .right: return named(.right, modifiers: modifiers)
        case .pipe: return inputCharacter("|", modifiers: modifiers)
        case .tilde: return inputCharacter("~", modifiers: modifiers)
        case .slash: return inputCharacter("/", modifiers: modifiers)
        case .control: return nil
        }
    }

    /// Maps a hardware-keyboard character without inventing a client-side byte encoder.
    public mutating func hardwareCharacter(
        _ character: Character,
        modifiers: KeyMods
    ) -> MobileInputAction {
        inputCharacter(character, modifiers: modifiers)
    }

    /// Maps a hardware-keyboard named key for owner-side mode-aware encoding.
    public mutating func hardwareKey(
        _ key: NamedKey,
        modifiers: KeyMods
    ) -> MobileInputAction {
        named(key, modifiers: modifiers)
    }

    /// Routes scroll from replicated screen state: primary is local, alternate is remote intent.
    public mutating func scroll(
        _ direction: InputWheelDirection,
        column: Int,
        row: Int,
        alternateScreen: Bool
    ) -> MobileInputAction {
        guard alternateScreen else {
            return .scrollViewport(direction == .up ? -1 : 1)
        }
        return .send(.events([.wheel(direction, column: column, row: row)]))
    }

    private func named(_ key: NamedKey, modifiers: KeyMods) -> MobileInputAction {
        .send(.events([.key(.named(key), modifiers)]))
    }

    private func inputCharacter(_ character: Character, modifiers: KeyMods) -> MobileInputAction {
        if modifiers.isEmpty { return .send(.events([.text(String(character))])) }
        return .send(.events([.key(.character(character), modifiers)]))
    }
}
