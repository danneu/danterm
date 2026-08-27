// Pure normalized-input policy for terminal keys, paste safety, and mouse reporting.
// Focus reports are not here: they depend on focus the terminal retains, so `Terminal` owns
// both the state and the bytes.

/// Child-selected mouse tracking behavior, represented as one exclusive mode.
public enum TerminalMouseTrackingMode: Equatable, Sendable {
    case off
    case click
    case drag
    case anyMotion
}

/// The kitty keyboard protocol flags DanTerm implements, declared once as a set.
///
/// The protocol's flag word is open-ended and DanTerm honors one bit of it. Narrowing a
/// reported word to `supported` happens in `init(reported:)` and nowhere else, so no stack
/// entry, `CSI ? u` reply, or encoder decision can name a capability the key encoder does
/// not have. A second flag costs one `static let` and one `supported` member.
public struct TerminalKittyKeyboardFlags: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Reports every key as a CSI-u sequence, so Escape and Ctrl-key forms stay distinct.
    public static let disambiguateEscapeCodes = Self(rawValue: 1)

    /// Every flag DanTerm answers for. `init(reported:)` is defined against this.
    public static let supported: Self = [.disambiguateEscapeCodes]

    /// Narrows a flag word the child sent to what DanTerm can honor.
    ///
    /// This is the only sanctioned way a wire value becomes a value of this type: it is
    /// what makes an unimplemented flag on the stack unrepresentable.
    public init(reported rawValue: UInt16) {
        self = Self(rawValue: rawValue).intersection(.supported)
    }
}

/// Snapshot of child-controlled modes that can affect bytes sent back as user input.
public struct TerminalInputModes: Equatable, Sendable {
    /// Selects SS3 for unmodified arrows, Home, and End in legacy mode.
    public var applicationCursorKeys: Bool
    /// Selects SS3 keypad forms in legacy mode.
    public var applicationKeypad: Bool
    /// Makes every CR a legacy key emits carry a following LF.
    public var lineFeedNewLine: Bool
    /// Enables focus-in and focus-out reports.
    public var focusReporting: Bool
    /// Enables safe-paste marker wrapping without newline normalization.
    public var bracketedPaste: Bool
    /// Selects which mouse transitions the child receives.
    public var mouseTracking: TerminalMouseTrackingMode
    /// Selects SGR coordinates and release markers instead of legacy X10 bytes.
    public var sgrMouseEncoding: Bool
    /// Lets wheel motion over an active alternate screen reach the child as cursor keys.
    ///
    /// Set by default, which is what makes an alternate-screen program scroll with the wheel
    /// without asking. A child that owns its own scrollback resets it to give the wheel back.
    public var alternateScroll: Bool
    /// Selects the kitty keyboard protocol flags the child negotiated.
    public var kittyKeyboardFlags: TerminalKittyKeyboardFlags

    /// Creates a complete deterministic input-policy snapshot with terminal defaults.
    public init(
        applicationCursorKeys: Bool = false,
        applicationKeypad: Bool = false,
        lineFeedNewLine: Bool = false,
        focusReporting: Bool = false,
        bracketedPaste: Bool = false,
        mouseTracking: TerminalMouseTrackingMode = .off,
        sgrMouseEncoding: Bool = false,
        alternateScroll: Bool = true,
        kittyKeyboardFlags: TerminalKittyKeyboardFlags = []
    ) {
        self.applicationCursorKeys = applicationCursorKeys
        self.applicationKeypad = applicationKeypad
        self.lineFeedNewLine = lineFeedNewLine
        self.focusReporting = focusReporting
        self.bracketedPaste = bracketedPaste
        self.mouseTracking = mouseTracking
        self.sgrMouseEncoding = sgrMouseEncoding
        self.alternateScroll = alternateScroll
        self.kittyKeyboardFlags = kittyKeyboardFlags
    }

    /// Represents the terminal's initial input-policy state.
    public static let `default` = Self()
}

/// Platform-neutral semantic keys whose terminal encodings depend on active child modes.
public enum TerminalInputKey: Equatable, Sendable {
    case returnKey, tab, backspace, escape
    case up, down, right, left, home, end, insert, pageUp, pageDown, deleteForward
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case character(Unicode.Scalar)
    case keypad0, keypad1, keypad2, keypad3, keypad4
    case keypad5, keypad6, keypad7, keypad8, keypad9
    case keypadDecimal, keypadDivide, keypadMultiply, keypadSubtract, keypadAdd
    case keypadEnter, keypadEqual
}

/// Stable modifier bits shared by AppKit, IPC, fixture replay, and pure policy tests.
public struct TerminalKeyModifiers: OptionSet, Equatable, Sendable {
    /// Stable storage shared across module and recording boundaries.
    public let rawValue: UInt8

    /// Reconstructs modifiers from their stable bit representation.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Selects shifted terminal forms without implying text case conversion.
    public static let shift = Self(rawValue: 1 << 0)
    /// Selects terminal Alt semantics, including legacy ESC prefixing.
    public static let alt = Self(rawValue: 1 << 1)
    /// Selects control-byte or enhanced protocol forms.
    public static let control = Self(rawValue: 1 << 2)
    /// Carries platform Command intent for local policy while remaining terminal-byte inert.
    public static let command = Self(rawValue: 1 << 3)
}

/// The three stateful mouse buttons represented by terminal reporting protocols.
public enum TerminalMouseButton: Int, Hashable, Sendable {
    case left = 0
    case middle = 1
    case right = 2
}

/// Stateless wheel directions represented as terminal mouse buttons 4 through 7.
public enum TerminalMouseWheelDirection: Int, Equatable, Sendable {
    case up = 64
    case down = 65
    case left = 66
    case right = 67
}

/// One encoder-level mouse transition carrying the pointed cell used in its report.
public enum TerminalMouseReportEvent: Equatable, Sendable {
    case move(column: Int, row: Int, modifiers: TerminalKeyModifiers = [])
    case down(
        TerminalMouseButton,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = []
    )
    case up(TerminalMouseButton, column: Int, row: Int, modifiers: TerminalKeyModifiers = [])
    case wheel(
        TerminalMouseWheelDirection,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = []
    )
}

/// Explicit host-input history needed to suppress duplicate transitions and encode drag motion.
public struct TerminalMouseTracker: Equatable, Sendable {
    fileprivate var pressedButtons: UInt8 = 0
    fileprivate var column = 0
    fileprivate var row = 0

    /// Creates tracker state at the protocol's initial cell with no held buttons.
    public init() {}
}

/// Encodes one normalized key solely from its semantic identity, modifiers, and mode snapshot.
public func encodeTerminalKey(
    _ key: TerminalInputKey,
    modifiers: TerminalKeyModifiers,
    modes: TerminalInputModes
) -> [UInt8] {
    let modifiers = protocolModifiers(modifiers)
    if modes.kittyKeyboardFlags.contains(.disambiguateEscapeCodes) {
        return encodeKittyKey(key, modifiers: modifiers)
    }
    let bytes = encodeLegacyKey(key, modifiers: modifiers, modes: modes)
    guard modes.lineFeedNewLine else { return bytes }
    return lineFeedNewLineBytes(bytes)
}

/// Applies LNM (mode 20) as xterm does: as a rule over emitted bytes, not over key names.
///
/// xterm routes every legacy key's bytes through one output path that appends LF to each
/// CR while LNM is set, so keypad Enter and Ctrl+M submit a line exactly like Return does.
private func lineFeedNewLineBytes(_ bytes: [UInt8]) -> [UInt8] {
    guard bytes.contains(0x0D) else { return bytes }
    var result: [UInt8] = []
    result.reserveCapacity(bytes.count + 1)
    for byte in bytes {
        result.append(byte)
        if byte == 0x0D { result.append(0x0A) }
    }
    return result
}

/// Removes local-only modifier intent before any terminal protocol decision observes it.
private func protocolModifiers(_ modifiers: TerminalKeyModifiers) -> TerminalKeyModifiers {
    modifiers.intersection([.shift, .alt, .control])
}

/// Sanitizes paste text and applies bracket markers without permitting embedded control sequences.
public func encodeTerminalPaste(_ text: String, modes: TerminalInputModes) -> [UInt8] {
    let safeScalars = text.unicodeScalars.filter { scalar in
        let value = scalar.value
        if value == 0x09 || value == 0x0A || value == 0x0D { return true }
        return value >= 0x20 && value != 0x7F && (0x80...0x9F).contains(value) == false
    }
    guard safeScalars.isEmpty == false else { return [] }

    var body = String.UnicodeScalarView()
    var index = safeScalars.startIndex
    while index != safeScalars.endIndex {
        let scalar = safeScalars[index]
        if modes.bracketedPaste == false, scalar.value == 0x0D {
            body.append(scalar)
            let next = safeScalars.index(after: index)
            if next != safeScalars.endIndex, safeScalars[next].value == 0x0A {
                index = next
            }
        } else if modes.bracketedPaste == false, scalar.value == 0x0A {
            body.append("\r")
        } else {
            body.append(scalar)
        }
        index = safeScalars.index(after: index)
    }

    let bytes = Array(String(body).utf8)
    guard modes.bracketedPaste else { return bytes }
    return Array("\u{1B}[200~".utf8) + bytes + Array("\u{1B}[201~".utf8)
}

/// Advances explicit mouse state and emits one mode-gated X10 or SGR report.
public func encodeTerminalMouse(
    _ event: TerminalMouseReportEvent,
    tracker: inout TerminalMouseTracker,
    modes: TerminalInputModes
) -> [UInt8] {
    let code: Int
    let isPressed: Bool
    let modifiers: TerminalKeyModifiers

    switch event {
    case let .move(column, row, eventModifiers):
        guard column != tracker.column || row != tracker.row else { return [] }
        tracker.column = column
        tracker.row = row
        modifiers = protocolModifiers(eventModifiers)

        let heldButton = lowestPressedMouseButton(tracker.pressedButtons)
        switch modes.mouseTracking {
        case .drag where heldButton != nil, .anyMotion:
            code = (heldButton?.rawValue ?? 3) + 32
            isPressed = true
        case .off, .click, .drag:
            return []
        }

    case let .down(button, column, row, eventModifiers):
        tracker.column = column
        tracker.row = row
        let mask = UInt8(1 << button.rawValue)
        guard tracker.pressedButtons & mask == 0 else { return [] }
        tracker.pressedButtons |= mask
        guard modes.mouseTracking != .off else { return [] }
        code = button.rawValue
        isPressed = true
        modifiers = protocolModifiers(eventModifiers)

    case let .up(button, column, row, eventModifiers):
        tracker.column = column
        tracker.row = row
        let mask = UInt8(1 << button.rawValue)
        guard tracker.pressedButtons & mask != 0 else { return [] }
        tracker.pressedButtons &= ~mask
        guard modes.mouseTracking != .off else { return [] }
        code = button.rawValue
        isPressed = false
        modifiers = protocolModifiers(eventModifiers)

    case let .wheel(direction, column, row, eventModifiers):
        tracker.column = column
        tracker.row = row
        guard modes.mouseTracking != .off else { return [] }
        code = direction.rawValue
        isPressed = true
        modifiers = protocolModifiers(eventModifiers)
    }

    return encodeMouseReport(
        code: code | mouseModifierBits(modifiers),
        isPressed: isPressed,
        column: tracker.column,
        row: tracker.row,
        sgr: modes.sgrMouseEncoding
    )
}

private func lowestPressedMouseButton(_ buttons: UInt8) -> TerminalMouseButton? {
    for button in [TerminalMouseButton.left, .middle, .right] {
        if buttons & UInt8(1 << button.rawValue) != 0 {
            return button
        }
    }
    return nil
}

private func mouseModifierBits(_ modifiers: TerminalKeyModifiers) -> Int {
    (modifiers.contains(.shift) ? 4 : 0)
        | (modifiers.contains(.alt) ? 8 : 0)
        | (modifiers.contains(.control) ? 16 : 0)
}

private func encodeMouseReport(
    code: Int,
    isPressed: Bool,
    column: Int,
    row: Int,
    sgr: Bool
) -> [UInt8] {
    if sgr {
        return Array("\u{1B}[<\(code);\(column + 1);\(row + 1)\(isPressed ? "M" : "m")".utf8)
    }

    let legacyCode = isPressed ? code : 3 | (code & 0x1C)
    return [
        0x1B, 0x5B, 0x4D,
        UInt8(clamping: legacyCode + 0x20),
        UInt8(clamping: column + 0x21),
        UInt8(clamping: row + 0x21),
    ]
}

private func modifierParameter(_ modifiers: TerminalKeyModifiers) -> Int {
    1
        + (modifiers.contains(.shift) ? 1 : 0)
        + (modifiers.contains(.alt) ? 2 : 0)
        + (modifiers.contains(.control) ? 4 : 0)
}

private func csi(_ body: String) -> [UInt8] {
    Array("\u{1B}[\(body)".utf8)
}

private func modifiedCSI(
    parameter: Int = 1,
    final: Character,
    modifiers: TerminalKeyModifiers
) -> [UInt8] {
    let modifier = modifierParameter(modifiers)
    return csi(modifier == 1 ? "\(final)" : "\(parameter);\(modifier)\(final)")
}

private func tilde(_ parameter: Int, modifiers: TerminalKeyModifiers) -> [UInt8] {
    let modifier = modifierParameter(modifiers)
    return csi(modifier == 1 ? "\(parameter)~" : "\(parameter);\(modifier)~")
}

private func encodeLegacyKey(
    _ key: TerminalInputKey,
    modifiers: TerminalKeyModifiers,
    modes: TerminalInputModes
) -> [UInt8] {
    // Base bytes for the family whose Alt form is a Meta ESC prefix. The switch never
    // applies the prefix itself: the single site below owns it, so a key added to the
    // family cannot forget it. Keys that carry Alt as a CSI modifier parameter, and the
    // keypad keys, return their finished bytes directly and never reach that site.
    let base: [UInt8]

    switch key {
    case .returnKey:
        // Shift+Return is an explicit "insert a line feed" affordance, not the return
        // key's newline semantics: it emits LF and no CR, so the LNM byte rule leaves it
        // alone. Emitting a CR would make composers submit. Programs that care about the
        // distinction can negotiate the kitty protocol and get CSI 13;2u instead.
        base = modifiers.contains(.shift) ? [0x0A] : [0x0D]
    case .tab:
        base = modifiers.contains(.shift) ? csi("Z") : [0x09]
    case .backspace:
        base = modifiers.contains(.control) ? [0x08] : [0x7F]
    case .escape:
        base = [0x1B]
    case .character(let scalar):
        base = modifiers.contains(.control)
            ? legacyControlBytes(for: scalar)
            : Array(String(scalar).utf8)
    case .up, .down, .right, .left, .home, .end:
        let final: Character
        switch key {
        case .up: final = "A"
        case .down: final = "B"
        case .right: final = "C"
        case .left: final = "D"
        case .home: final = "H"
        default: final = "F"
        }
        if modifiers.isEmpty, modes.applicationCursorKeys {
            return Array("\u{1B}O\(final)".utf8)
        }
        return modifiedCSI(final: final, modifiers: modifiers)
    case .insert: return tilde(2, modifiers: modifiers)
    case .deleteForward: return tilde(3, modifiers: modifiers)
    case .pageUp: return tilde(5, modifiers: modifiers)
    case .pageDown: return tilde(6, modifiers: modifiers)
    case .f1, .f2, .f3, .f4:
        let final: Character = switch key {
        case .f1: "P"
        case .f2: "Q"
        case .f3: "R"
        default: "S"
        }
        if modifiers.isEmpty { return Array("\u{1B}O\(final)".utf8) }
        return modifiedCSI(final: final, modifiers: modifiers)
    case .f5: return tilde(15, modifiers: modifiers)
    case .f6: return tilde(17, modifiers: modifiers)
    case .f7: return tilde(18, modifiers: modifiers)
    case .f8: return tilde(19, modifiers: modifiers)
    case .f9: return tilde(20, modifiers: modifiers)
    case .f10: return tilde(21, modifiers: modifiers)
    case .f11: return tilde(23, modifiers: modifiers)
    case .f12: return tilde(24, modifiers: modifiers)
    case .keypad0, .keypad1, .keypad2, .keypad3, .keypad4,
         .keypad5, .keypad6, .keypad7, .keypad8, .keypad9,
         .keypadDecimal, .keypadDivide, .keypadMultiply, .keypadSubtract,
         .keypadAdd, .keypadEnter, .keypadEqual:
        let (normal, application, _) = keypadEncoding(for: key)
        return modes.applicationKeypad ? Array("\u{1B}O\(application)".utf8) : Array(normal.utf8)
    }

    guard modifiers.contains(.alt) else { return base }
    return [0x1B] + base
}

private func legacyControlBytes(for scalar: Unicode.Scalar) -> [UInt8] {
    // The non-alphabetic entries come from kitty's encoder, copied into
    // references/ghostty/src/input/key_encode.zig and asserted again by
    // windows-terminal's inputTest.cpp. Digits 0, 1, and 9 send their own character
    // there, so they belong in the default branch, not in this list.
    switch scalar.value {
    case 0x20, 0x40: [0x00]         // space, @
    case 0x41...0x5A: [UInt8(scalar.value - 0x40)]
    case 0x61...0x7A: [UInt8(scalar.value - 0x60)]
    case 0x5B...0x5F: [UInt8(scalar.value - 0x40)]
    case 0x3F: [0x7F]               // ?
    case 0x2F: [0x1F]               // /
    case 0x32: [0x00]               // 2
    case 0x33...0x37: [UInt8(scalar.value - 0x18)]  // 3...7 -> 0x1B...0x1F
    case 0x38: [0x7F]               // 8
    default: Array(String(scalar).utf8)
    }
}

private func encodeKittyKey(
    _ key: TerminalInputKey,
    modifiers: TerminalKeyModifiers
) -> [UInt8] {
    let modifier = modifierParameter(modifiers)
    switch key {
    case .escape:
        return csi(modifier == 1 ? "27u" : "27;\(modifier)u")
    case .returnKey, .tab, .backspace:
        let code = key == .returnKey ? 13 : (key == .tab ? 9 : 127)
        if modifiers.isEmpty {
            return [UInt8(code)]
        }
        return csi("\(code);\(modifier)u")
    case .character(let scalar):
        guard modifiers.contains(.control) || modifiers.contains(.alt) else {
            return Array(String(scalar).utf8)
        }
        let code = (0x41...0x5A).contains(scalar.value) ? scalar.value + 0x20 : scalar.value
        return csi("\(code);\(modifier)u")
    case .up, .down, .right, .left, .home, .end:
        let final: Character = switch key {
        case .up: "A"
        case .down: "B"
        case .right: "C"
        case .left: "D"
        case .home: "H"
        default: "F"
        }
        return modifiedCSI(final: final, modifiers: modifiers)
    case .insert: return tilde(2, modifiers: modifiers)
    case .deleteForward: return tilde(3, modifiers: modifiers)
    case .pageUp: return tilde(5, modifiers: modifiers)
    case .pageDown: return tilde(6, modifiers: modifiers)
    case .f1, .f2, .f4:
        let final: Character = key == .f1 ? "P" : (key == .f2 ? "Q" : "S")
        return modifiedCSI(final: final, modifiers: modifiers)
    case .f3: return tilde(13, modifiers: modifiers)
    case .f5: return tilde(15, modifiers: modifiers)
    case .f6: return tilde(17, modifiers: modifiers)
    case .f7: return tilde(18, modifiers: modifiers)
    case .f8: return tilde(19, modifiers: modifiers)
    case .f9: return tilde(20, modifiers: modifiers)
    case .f10: return tilde(21, modifiers: modifiers)
    case .f11: return tilde(23, modifiers: modifiers)
    case .f12: return tilde(24, modifiers: modifiers)
    case .keypad0, .keypad1, .keypad2, .keypad3, .keypad4,
         .keypad5, .keypad6, .keypad7, .keypad8, .keypad9,
         .keypadDecimal, .keypadDivide, .keypadMultiply, .keypadSubtract,
         .keypadAdd, .keypadEnter, .keypadEqual:
        // A keypad key sends its legacy text only when that text is printable. Keypad
        // Enter's text is CR, so sending it would be byte-identical to Return and defeat
        // the disambiguation the flag was negotiated for; it sends its functional code.
        let (normal, _, functionalCode) = keypadEncoding(for: key)
        if modifiers.isEmpty, isPrintableKeyText(normal) { return Array(normal.utf8) }
        return csi(modifier == 1 ? "\(functionalCode)u" : "\(functionalCode);\(modifier)u")
    }
}

/// Decides whether a key's legacy text may stand in for its kitty functional code.
///
/// kitty drops the text of any key whose text begins with an ASCII control byte, so the
/// enhanced protocol never re-sends a byte a legacy key already owns.
private func isPrintableKeyText(_ text: String) -> Bool {
    guard let first = text.unicodeScalars.first else { return false }
    return first.value >= 0x20 && first.value != 0x7F
}

private func keypadEncoding(for key: TerminalInputKey) -> (String, Character, Int) {
    switch key {
    case .keypad0: ("0", "p", 57399)
    case .keypad1: ("1", "q", 57400)
    case .keypad2: ("2", "r", 57401)
    case .keypad3: ("3", "s", 57402)
    case .keypad4: ("4", "t", 57403)
    case .keypad5: ("5", "u", 57404)
    case .keypad6: ("6", "v", 57405)
    case .keypad7: ("7", "w", 57406)
    case .keypad8: ("8", "x", 57407)
    case .keypad9: ("9", "y", 57408)
    case .keypadDecimal: (".", "n", 57409)
    case .keypadDivide: ("/", "o", 57410)
    case .keypadMultiply: ("*", "j", 57411)
    case .keypadSubtract: ("-", "m", 57412)
    case .keypadAdd: ("+", "k", 57413)
    case .keypadEnter: ("\r", "M", 57414)
    case .keypadEqual: ("=", "X", 57415)
    default: preconditionFailure("non-keypad key")
    }
}
