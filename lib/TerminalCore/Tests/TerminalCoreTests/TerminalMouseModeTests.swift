// Verifies DEC mouse tracking and encoding modes through public terminal input and queries.
import Testing

@testable import TerminalCore

/// Pins the mutually exclusive tracking mode and independent SGR encoding state.
struct TerminalMouseModeTests {
    @Test("DEC mouse tracking modes replace one another and any reset disables tracking")
    func trackingModeExclusivity() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))

        terminal.feed(Array("\u{1B}[?1000h".utf8))
        #expect(terminal.inputModes.mouseTracking == .click)
        terminal.feed(Array("\u{1B}[?1002h".utf8))
        #expect(terminal.inputModes.mouseTracking == .drag)
        terminal.feed(Array("\u{1B}[?1003h".utf8))
        #expect(terminal.inputModes.mouseTracking == .anyMotion)

        for resetMode in [1000, 1002, 1003] {
            terminal.feed(Array("\u{1B}[?1003h\u{1B}[?\(resetMode)l".utf8))
            #expect(terminal.inputModes.mouseTracking == .off)
        }
    }

    @Test("SGR mouse encoding toggles independently and unsupported encodings stay inert")
    func encodingModeIsolation() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))

        terminal.feed(Array("\u{1B}[?1002;1006h".utf8))
        #expect(terminal.inputModes.mouseTracking == .drag)
        #expect(terminal.inputModes.sgrMouseEncoding)

        terminal.feed(Array("\u{1B}[?1005;1015;1016h".utf8))
        #expect(terminal.inputModes.mouseTracking == .drag)
        #expect(terminal.inputModes.sgrMouseEncoding)

        terminal.feed(Array("\u{1B}[?1006l".utf8))
        #expect(terminal.inputModes.mouseTracking == .drag)
        #expect(terminal.inputModes.sgrMouseEncoding == false)
    }

    @Test("DECRQM reports only the active tracking mode and recognizes only SGR encoding")
    func modeQueries() throws {
        for activeMode in [1000, 1002, 1003] {
            var terminal = try #require(Terminal(columns: 8, rows: 3))
            terminal.feed(Array("\u{1B}[?\(activeMode);1006h".utf8))

            for queriedMode in [1000, 1002, 1003] {
                terminal.feed(Array("\u{1B}[?\(queriedMode)$p".utf8))
                let status = queriedMode == activeMode ? 1 : 2
                #expect(
                    terminal.drainReplyBytes()
                        == Array("\u{1B}[?\(queriedMode);\(status)$y".utf8),
                    "active mode \(activeMode), queried mode \(queriedMode)"
                )
            }
            terminal.feed(Array("\u{1B}[?1006$p".utf8))
            #expect(terminal.drainReplyBytes() == Array("\u{1B}[?1006;1$y".utf8))
        }

        var unsupported = try #require(Terminal(columns: 8, rows: 3))
        for mode in [1005, 1015, 1016] {
            unsupported.feed(Array("\u{1B}[?\(mode)$p".utf8))
            #expect(unsupported.drainReplyBytes() == Array("\u{1B}[?\(mode);0$y".utf8))
        }
    }

    @Test("mouse modes survive screen switches and reset to defaults under DECSTR and RIS")
    func screenAndResetSemantics() throws {
        for screenMode in [1047, 1049] {
            var terminal = try #require(Terminal(columns: 8, rows: 3))
            terminal.feed(Array("\u{1B}[?1003;1006h\u{1B}[?\(screenMode)h\u{1B}[?\(screenMode)l".utf8))
            #expect(terminal.inputModes.mouseTracking == .anyMotion)
            #expect(terminal.inputModes.sgrMouseEncoding)
        }

        for reset in ["\u{1B}[!p", "\u{1B}c"] {
            var terminal = try #require(Terminal(columns: 8, rows: 3))
            terminal.feed(Array("\u{1B}[?1003;1006h\(reset)".utf8))
            #expect(terminal.inputModes == .default)
        }
    }
}
