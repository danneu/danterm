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

/// Names every terminal key the phone's own controls can send.
///
/// It is the full vocabulary, not the bottom row's contents: the four arrows live on the
/// floating arrow pad and reach the pane through these same cases. `barRow` says what the
/// row draws.
public enum MobileAccessoryKey: Equatable, Sendable, CaseIterable {
    case escape
    case control
    case shift
    case tab
    case up
    case down
    case left
    case right
    case pipe
    case tilde
    case slash

    /// The keys the bottom row offers, in the order it draws them, left to right.
    ///
    /// Spelled out rather than taken from `allCases`, because the row is now a choice
    /// about what deserves a permanent slot beside the keyboard -- the arrows gave four
    /// narrow slots to keys the pad serves better, and a case added to the enum must not
    /// claim a slot in the row by existing.
    public static let barRow: [MobileAccessoryKey] = [
        .escape, .control, .shift, .tab, .pipe, .tilde, .slash,
    ]
}

/// Converts normalized UIKit input into the two D8 wire forms while owning the one-shot
/// modifier latch: the latch chords the next key-shaped input from any source, and that
/// input consumes it.
///
/// The latch is a modifier set rather than one flag, because the software keyboard offers
/// no modifier of its own: every chord the phone can reach is a chord the row armed, so
/// the row must be able to arm more than one at a time.
public struct MobileInputMapper: Equatable, Sendable {
    /// The modifiers armed for the next key-shaped input. The row renders its latch keys
    /// from this, so it lit exactly what the next input will carry.
    public private(set) var latchedModifiers: KeyMods = []

    /// Creates a mapper with no active modifier latch.
    public init() {}

    /// Keeps ordinary committed text on the raw event-token path -- unless the latch is
    /// armed and the commit is a single character, which is the chord the latch was armed
    /// for. A longer commit (autocorrect, dictation, IME) cannot be chorded, so it goes
    /// unchanged; either way the latch is spent.
    public mutating func text(_ text: String) -> MobileInputAction {
        let modifiers = takeLatch()
        guard let character = text.first, text.count == 1 else {
            return .send(.events([.text(text)]))
        }
        return inputCharacter(character, modifiers: modifiers)
    }

    /// Keeps a paste gesture on the top-level safe-paste path. The latch cannot chord a
    /// paste, but the paste still consumes it so it cannot chord a later keystroke.
    public mutating func paste(_ text: String) -> MobileInputAction {
        _ = takeLatch()
        return .send(.text(text))
    }

    /// Sends the keyboard's backspace as the named key the owner already encodes, with
    /// the latch's Ctrl when one is armed.
    public mutating func deleteBackward() -> MobileInputAction {
        named(.bspace, modifiers: takeLatch())
    }

    /// Applies one accessory-row key: a latch key moves the latch without producing
    /// traffic, and every other key spends it.
    public mutating func accessory(_ key: MobileAccessoryKey) -> MobileInputAction? {
        if let modifier = Self.latchModifier(for: key) {
            latchedModifiers.formSymmetricDifference(modifier)
            return nil
        }
        let modifiers = takeLatch()
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
        case .control, .shift: return nil
        }
    }

    /// Names the latch keys, so the row and the mapper cannot disagree about which keys
    /// arm a modifier instead of sending one.
    public static func latchModifier(for key: MobileAccessoryKey) -> KeyMods? {
        switch key {
        case .control: return .ctrl
        case .shift: return .shift
        default: return nil
        }
    }

    /// Maps one hardware-keyboard press for owner-side mode-aware encoding.
    ///
    /// It takes the key the press already decided on -- named or character -- rather than
    /// deciding again: `MobileHardwareKeyPress` is the only producer of a character key
    /// here, and it produces one only under Ctrl or Alt, so a Shift-only hardware chord
    /// cannot be built at this entry point at all.
    public mutating func hardwareKey(
        _ key: KeyName,
        modifiers: KeyMods
    ) -> MobileInputAction {
        let modifiers = modifiers.union(takeLatch())
        switch key {
        case .named(let key): return named(key, modifiers: modifiers)
        case .character(let character): return inputCharacter(character, modifiers: modifiers)
        }
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

    /// Reads the armed modifiers and spends them in the same step, so one armed latch can
    /// never chord two inputs.
    private mutating func takeLatch() -> KeyMods {
        defer { latchedModifiers = [] }
        return latchedModifiers
    }

    private func named(_ key: NamedKey, modifiers: KeyMods) -> MobileInputAction {
        .send(.events([.key(.named(key), modifiers)]))
    }

    private func inputCharacter(_ character: Character, modifiers: KeyMods) -> MobileInputAction {
        // UIKit hands the software keyboard's Return to `UIKeyInput` as inserted text, so
        // the return key arrives here rather than through `hardwareKey`. It is named
        // rather than sent as its literal byte, because only the owner knows the pane's
        // newline mode -- and a bare LF reads as "insert a line" to a TUI composer, which
        // is the one thing the return key must not do.
        if character.isNewline { return named(.enter, modifiers: modifiers) }
        // A chord carries the character in the wire's own domain, which is where a latched
        // Ctrl meets a Shift-produced capital: `Shift+A` reaches here as `A` through the
        // text path, and the Ctrl-A byte is what the user asked for. A character with no
        // canonical form -- a non-ASCII layout key -- is typed as text rather than sent as
        // a chord the owner would refuse to decode.
        guard modifiers.isEmpty == false,
              let canonical = MobileHardwareKeyPress.wireCharacter(from: String(character))
        else {
            return .send(.events([.text(String(character))]))
        }
        return .send(.events([.key(.character(canonical), modifiers)]))
    }
}
