// Verifies safe paste bytes as a pure function of authoritative terminal modes.
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
}
