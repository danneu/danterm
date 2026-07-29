// Verifies deterministic key bytes across legacy, application, and Kitty keyboard modes.
import Testing

@testable import TerminalCore

/// Pins the normalized-key contract independently from AppKit and PTY ownership.
struct TerminalKeyEncodingTests {
    @Test("Command is byte-inert across legacy cursor keypad Kitty and mouse encodings")
    func commandModifierIsByteInert() {
        let command = TerminalKeyModifiers.command
        #expect(encodeTerminalKey(.up, modifiers: command, modes: .init(applicationCursorKeys: true))
            == encodeTerminalKey(.up, modifiers: [], modes: .init(applicationCursorKeys: true)))
        #expect(encodeTerminalKey(.keypad1, modifiers: command, modes: .init(applicationKeypad: true))
            == encodeTerminalKey(.keypad1, modifiers: [], modes: .init(applicationKeypad: true)))
        #expect(encodeTerminalKey(.f5, modifiers: command, modes: .init(kittyKeyboardFlags: 1))
            == encodeTerminalKey(.f5, modifiers: [], modes: .init(kittyKeyboardFlags: 1)))

        var plainTracker = TerminalMouseTracker()
        var commandTracker = TerminalMouseTracker()
        let modes = TerminalInputModes(mouseTracking: .click, sgrMouseEncoding: true)
        #expect(encodeTerminalMouse(
            .down(.left, column: 2, row: 1), tracker: &plainTracker, modes: modes
        ) == encodeTerminalMouse(
            .down(.left, column: 2, row: 1, modifiers: command),
            tracker: &commandTracker,
            modes: modes
        ))
    }
    @Test("every legacy navigation and function key covers the full xterm modifier matrix")
    func completeLegacySpecialKeyMatrix() {
        let modifiers: [(TerminalKeyModifiers, Int)] = [
            ([], 1), ([.shift], 2), ([.alt], 3), ([.shift, .alt], 4),
            ([.control], 5), ([.shift, .control], 6),
            ([.alt, .control], 7), ([.shift, .alt, .control], 8),
        ]
        let cursorKeys: [(TerminalInputKey, Character)] = [
            (.up, "A"), (.down, "B"), (.right, "C"), (.left, "D"),
            (.home, "H"), (.end, "F"),
        ]
        for (key, final) in cursorKeys {
            for (flags, parameter) in modifiers {
                let expected = parameter == 1 ? "\u{1B}[\(final)" : "\u{1B}[1;\(parameter)\(final)"
                #expect(encodeTerminalKey(key, modifiers: flags, modes: .default) == Array(expected.utf8))
            }
        }

        let tildeKeys: [(TerminalInputKey, Int)] = [
            (.insert, 2), (.deleteForward, 3), (.pageUp, 5), (.pageDown, 6),
            (.f5, 15), (.f6, 17), (.f7, 18), (.f8, 19),
            (.f9, 20), (.f10, 21), (.f11, 23), (.f12, 24),
        ]
        for (key, code) in tildeKeys {
            for (flags, parameter) in modifiers {
                let expected = parameter == 1 ? "\u{1B}[\(code)~" : "\u{1B}[\(code);\(parameter)~"
                #expect(encodeTerminalKey(key, modifiers: flags, modes: .default) == Array(expected.utf8))
            }
        }

        let ss3Keys: [(TerminalInputKey, Character)] = [(.f1, "P"), (.f2, "Q"), (.f3, "R"), (.f4, "S")]
        for (key, final) in ss3Keys {
            for (flags, parameter) in modifiers {
                let expected = parameter == 1 ? "\u{1B}O\(final)" : "\u{1B}[1;\(parameter)\(final)"
                #expect(encodeTerminalKey(key, modifiers: flags, modes: .default) == Array(expected.utf8))
            }
        }
    }

    @Test("legacy Return, Tab, and Backspace cover control, Shift, Alt, and LNM forms")
    func completeLegacyControlKeyMatrix() {
        #expect(encodeTerminalKey(.returnKey, modifiers: [], modes: .default) == [0x0D])
        #expect(encodeTerminalKey(.returnKey, modifiers: [.control], modes: .default) == [0x0D])
        #expect(encodeTerminalKey(.returnKey, modifiers: [.alt], modes: .default) == [0x1B, 0x0D])
        #expect(
            encodeTerminalKey(
                .returnKey,
                modifiers: [.alt],
                modes: TerminalInputModes(lineFeedNewLine: true)
            ) == [0x1B, 0x0D, 0x0A]
        )

        #expect(encodeTerminalKey(.tab, modifiers: [], modes: .default) == [0x09])
        #expect(encodeTerminalKey(.tab, modifiers: [.control], modes: .default) == [0x09])
        #expect(encodeTerminalKey(.tab, modifiers: [.alt], modes: .default) == [0x1B, 0x09])
        #expect(encodeTerminalKey(.tab, modifiers: [.shift], modes: .default) == Array("\u{1B}[Z".utf8))

        #expect(encodeTerminalKey(.backspace, modifiers: [], modes: .default) == [0x7F])
        #expect(encodeTerminalKey(.backspace, modifiers: [.control], modes: .default) == [0x08])
        #expect(encodeTerminalKey(.backspace, modifiers: [.alt], modes: .default) == [0x1B, 0x7F])
        #expect(
            encodeTerminalKey(.backspace, modifiers: [.alt, .control], modes: .default)
                == [0x1B, 0x08]
        )
    }

    @Test("legacy Shift+Return encodes LF under every modifier and mode combination")
    func legacyShiftReturnEncodesLineFeed() {
        // Intent: in legacy mode every Return chord containing Shift emits LF (0x0A),
        //   ESC-prefixed when Alt is held, regardless of the active modes.
        // Why it exists: Claude Code never negotiates the kitty protocol for DanTerm,
        //   so legacy Shift+Enter is what composers see; CR reads as submit there.
        //   LNM is the case that would silently regress to CR LF and submit again.
        // Scenario: pressing Shift+Enter in a Swift-engine pane running `claude`
        //   inserts a newline instead of sending the message.
        let lnm = TerminalInputModes(lineFeedNewLine: true)
        let allModes = TerminalInputModes(
            applicationCursorKeys: true,
            applicationKeypad: true,
            lineFeedNewLine: true
        )

        for modes in [TerminalInputModes.default, lnm, allModes] {
            #expect(encodeTerminalKey(.returnKey, modifiers: [.shift], modes: modes) == [0x0A])
            #expect(
                encodeTerminalKey(.returnKey, modifiers: [.shift, .control], modes: modes) == [0x0A]
            )
            #expect(
                encodeTerminalKey(.returnKey, modifiers: [.shift, .alt], modes: modes)
                    == [0x1B, 0x0A]
            )
            #expect(
                encodeTerminalKey(.returnKey, modifiers: [.shift, .control, .alt], modes: modes)
                    == [0x1B, 0x0A]
            )
        }
    }

    @Test("DECKPNM and DECKPAM cover the complete keypad table")
    func completeKeypadTable() {
        let cases: [(TerminalInputKey, String, Character)] = [
            (.keypad0, "0", "p"), (.keypad1, "1", "q"), (.keypad2, "2", "r"),
            (.keypad3, "3", "s"), (.keypad4, "4", "t"), (.keypad5, "5", "u"),
            (.keypad6, "6", "v"), (.keypad7, "7", "w"), (.keypad8, "8", "x"),
            (.keypad9, "9", "y"), (.keypadDecimal, ".", "n"),
            (.keypadDivide, "/", "o"), (.keypadMultiply, "*", "j"),
            (.keypadSubtract, "-", "m"), (.keypadAdd, "+", "k"),
            (.keypadEnter, "\r", "M"), (.keypadEqual, "=", "X"),
        ]
        for (key, numeric, application) in cases {
            #expect(encodeTerminalKey(key, modifiers: [], modes: .default) == Array(numeric.utf8))
            #expect(
                encodeTerminalKey(key, modifiers: [], modes: TerminalInputModes(applicationKeypad: true))
                    == Array("\u{1B}O\(application)".utf8)
            )
        }
    }

    @Test("legacy navigation and function modifiers use xterm parameter forms")
    func legacyNavigationMatrix() {
        let cases: [(TerminalInputKey, TerminalKeyModifiers, String)] = [
            (.up, [], "\u{1B}[A"),
            (.up, [.shift], "\u{1B}[1;2A"),
            (.home, [.alt, .control], "\u{1B}[1;7H"),
            (.insert, [], "\u{1B}[2~"),
            (.pageDown, [.control], "\u{1B}[6;5~"),
            (.f1, [], "\u{1B}OP"),
            (.f1, [.shift], "\u{1B}[1;2P"),
            (.f5, [], "\u{1B}[15~"),
            (.f12, [.alt], "\u{1B}[24;3~"),
        ]

        for (key, modifiers, expected) in cases {
            #expect(encodeTerminalKey(key, modifiers: modifiers, modes: .default) == Array(expected.utf8))
        }
    }

    @Test("legacy control text uses strict xterm bytes without unsolicited CSI-u")
    func legacyTextMatrix() {
        let cases: [(Unicode.Scalar, TerminalKeyModifiers, [UInt8])] = [
            ("a", [.control], [0x01]),
            ("A", [.control, .shift], [0x01]),
            ("i", [.control], [0x09]),
            (" ", [.control], [0x00]),
            ("[", [.control], [0x1B]),
            ("\\", [.control], [0x1C]),
            ("]", [.control], [0x1D]),
            ("^", [.control], [0x1E]),
            ("_", [.control], [0x1F]),
            ("a", [.control, .alt], [0x1B, 0x01]),
        ]

        for (scalar, modifiers, expected) in cases {
            #expect(encodeTerminalKey(.character(scalar), modifiers: modifiers, modes: .default) == expected)
        }
        #expect(encodeTerminalKey(.tab, modifiers: [.shift], modes: .default) == Array("\u{1B}[Z".utf8))
        #expect(encodeTerminalKey(.tab, modifiers: [.control], modes: .default) == [0x09])
        #expect(encodeTerminalKey(.backspace, modifiers: [.control], modes: .default) == [0x08])
    }

    @Test("application cursor, keypad, and LNM modes affect only their key families")
    func applicationModes() {
        let modes = TerminalInputModes(
            applicationCursorKeys: true,
            applicationKeypad: true,
            lineFeedNewLine: true
        )

        #expect(encodeTerminalKey(.up, modifiers: [], modes: modes) == Array("\u{1B}OA".utf8))
        #expect(encodeTerminalKey(.home, modifiers: [], modes: modes) == Array("\u{1B}OH".utf8))
        #expect(encodeTerminalKey(.keypad0, modifiers: [], modes: modes) == Array("\u{1B}Op".utf8))
        #expect(encodeTerminalKey(.keypadEnter, modifiers: [], modes: modes) == Array("\u{1B}OM".utf8))
        #expect(encodeTerminalKey(.returnKey, modifiers: [], modes: modes) == [0x0D, 0x0A])
        #expect(encodeTerminalKey(.up, modifiers: [.shift], modes: modes) == Array("\u{1B}[1;2A".utf8))
    }

    @Test("Kitty flag 1 disambiguates modified keys and ignores application modes")
    func kittyFlagOneMatrix() {
        let modes = TerminalInputModes(
            applicationCursorKeys: true,
            applicationKeypad: true,
            kittyKeyboardFlags: 1
        )
        let cases: [(TerminalInputKey, TerminalKeyModifiers, String)] = [
            (.escape, [], "\u{1B}[27u"),
            (.returnKey, [.shift], "\u{1B}[13;2u"),
            (.tab, [.shift], "\u{1B}[9;2u"),
            (.backspace, [.control], "\u{1B}[127;5u"),
            (.character("a"), [.control], "\u{1B}[97;5u"),
            (.character("A"), [.control, .shift], "\u{1B}[97;6u"),
            (.character(" "), [.control], "\u{1B}[32;5u"),
            (.character("["), [.control], "\u{1B}[91;5u"),
            (.character("\\"), [.control], "\u{1B}[92;5u"),
            (.character("]"), [.control], "\u{1B}[93;5u"),
            (.character("^"), [.control], "\u{1B}[94;5u"),
            (.character("_"), [.control], "\u{1B}[95;5u"),
            (.up, [], "\u{1B}[A"),
            (.up, [.alt], "\u{1B}[1;3A"),
            (.f3, [], "\u{1B}[13~"),
            (.f3, [.control], "\u{1B}[13;5~"),
            (.keypad0, [.shift], "\u{1B}[57399;2u"),
        ]

        for (key, modifiers, expected) in cases {
            #expect(encodeTerminalKey(key, modifiers: modifiers, modes: modes) == Array(expected.utf8))
        }
    }

    // Formerly TerminalCapabilityManifestTests.keyConformance, decoding these
    // sequences out of the now-retired terminal-capabilities-v1.json manifest;
    // see docs/terminal-capabilities.md for the full terminfo claim table these
    // sequences are pinned against.
    @Test("application-cursor-mode navigation keys match DanTerm's xterm-256color terminfo entries")
    func applicationCursorModeMatchesXterm256ColorTerminfo() {
        let modes = TerminalInputModes(applicationCursorKeys: true)
        let cases: [(TerminalInputKey, String)] = [
            (.up, "\u{1B}OA"),
            (.down, "\u{1B}OB"),
            (.left, "\u{1B}OD"),
            (.right, "\u{1B}OC"),
            (.home, "\u{1B}OH"),
            (.end, "\u{1B}OF"),
            (.deleteForward, "\u{1B}[3~"),
            (.pageUp, "\u{1B}[5~"),
            (.pageDown, "\u{1B}[6~"),
        ]
        for (key, expected) in cases {
            #expect(
                String(decoding: encodeTerminalKey(key, modifiers: [], modes: modes), as: UTF8.self)
                    == expected
            )
        }
    }
}
