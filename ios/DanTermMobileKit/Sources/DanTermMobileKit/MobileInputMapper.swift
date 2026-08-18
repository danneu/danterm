// Maps phone controls to pane input intent without encoding terminal bytes on the client.
import DanTermProtocol

/// The two meanings a scroll has, which are the two the engine's viewport answers to.
///
/// They stay apart all the way to the replica because each one has a safe answer under
/// either replicated screen mode: an absolute row is meaningless where there is no
/// scrollback, and whole rows must never be replayed as a jump.
public enum MobileViewportScroll: Equatable, Sendable {
    /// Move the window by whole rows; negative moves toward history.
    case byRows(Int)
    /// Put this row at the top of the window. The engine clamps it.
    case toTopRow(Int)
}

/// Describes either owner-side input or a local replica viewport movement.
public enum MobileInputAction: Equatable, Sendable {
    case send(IpcPaneInput)
    case scrollViewport(MobileViewportScroll)
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

    /// Routes an absolute top row, which only the primary screen can hold: the alternate
    /// screen reports a degenerate projection, so a row named against it means nothing.
    public func scroll(toTopRow row: Int, alternateScreen: Bool) -> MobileInputAction? {
        guard alternateScreen == false else { return nil }
        return .scrollViewport(.toTopRow(row))
    }

    /// Routes whole rows from replicated screen state: primary is local, alternate is one
    /// wheel event per row at the gesture's own cell, which the owner routes through its
    /// wheel policy.
    public func scroll(
        byRows rows: Int,
        column: Int,
        row: Int,
        alternateScreen: Bool
    ) -> MobileInputAction? {
        guard alternateScreen else {
            return rows == 0 ? nil : .scrollViewport(.byRows(rows))
        }
        // `Int(exactly:)` rather than `abs`, which traps on the one row count that has no
        // positive counterpart.
        guard let count = Int(exactly: rows.magnitude), count > 0 else { return nil }
        let direction: InputWheelDirection = rows < 0 ? .up : .down
        let wheel = InputEvent.wheel(direction, column: column, row: row)
        return .send(.events(Array(repeating: wheel, count: count)))
    }

    private func named(_ key: NamedKey, modifiers: KeyMods) -> MobileInputAction {
        .send(.events([.key(.named(key), modifiers)]))
    }

    private func inputCharacter(_ character: Character, modifiers: KeyMods) -> MobileInputAction {
        if modifiers.isEmpty { return .send(.events([.text(String(character))])) }
        return .send(.events([.key(.character(character), modifiers)]))
    }
}
