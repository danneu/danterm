// Verifies safe paste and focus bytes as pure functions of authoritative terminal modes.
import Testing

@testable import TerminalCore

/// Pins injection resistance and mode gating outside every platform pasteboard call site.
struct TerminalPastePolicyTests {
    @Test("paste strips unsafe controls and normalizes line endings only outside bracketed mode")
    func sanitizationAndLineEndings() {
        let input = "a\t\u{0000}b\r\nc\nd\r\u{001B}[201~\u{007F}\u{0085}e"

        #expect(
            encodeTerminalPaste(input, modes: .default)
                == Array("a\tb\rc\rd\r[201~e".utf8)
        )

        let bracketed = TerminalInputModes(bracketedPaste: true)
        #expect(
            encodeTerminalPaste(input, modes: bracketed)
                == Array("\u{1B}[200~a\tb\r\nc\nd\r[201~e\u{1B}[201~".utf8)
        )
    }

    @Test("empty sanitized paste emits neither body nor bracket markers")
    func emptyPaste() {
        #expect(encodeTerminalPaste("\u{0000}\u{001B}\u{007F}\u{0080}", modes: TerminalInputModes(bracketedPaste: true)).isEmpty)
    }

    @Test("focus reports are gated without mutating terminal state")
    func focusGating() throws {
        let off = TerminalInputModes.default
        let on = TerminalInputModes(focusReporting: true)
        #expect(encodeTerminalFocus(focused: true, modes: off).isEmpty)
        #expect(encodeTerminalFocus(focused: true, modes: on) == Array("\u{1B}[I".utf8))
        #expect(encodeTerminalFocus(focused: false, modes: on) == Array("\u{1B}[O".utf8))

        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("\u{1B}[?1004h".utf8))
        let before = terminal
        _ = encodeTerminalFocus(focused: true, modes: terminal.inputModes)
        #expect(terminal == before)
    }
}
