// Synthetic asciicast v2 contracts for the nested-PTY compatibility workflow.
import Foundation
import Testing
@testable import TerminalWorkflowSupport

@Suite("Asciicast validation")
struct AsciicastValidationTests {
    @Test("accepts required header, UTF-8 color output, input, and resize evidence")
    func validCast() throws {
        let cast = """
        {"version":2,"width":80,"height":24,"env":{"SHELL":"/bin/zsh","TERM":"xterm-256color"}}
        [0.1,"o","\\u001b[36m__ASCIINEMA_UTF8__=café-λ\\u001b[0m\\r\\n"]
        [0.2,"i","printf __ASCIINEMA_UTF8__=café-λ\\n"]
        [0.3,"r","53x17"]

        """

        let report = try AsciicastValidator.validate(Data(cast.utf8))

        #expect(report.outputEventCount == 1)
        #expect(report.inputEventCount == 1)
        #expect(report.resizeEventCount == 1)
    }

    @Test("rejects malformed header and events", arguments: [
        "{}\n",
        "{\"version\":2.5,\"width\":80,\"height\":24,\"env\":{\"SHELL\":\"/bin/zsh\",\"TERM\":\"xterm-256color\"}}\n",
        "{\"version\":2,\"width\":80,\"height\":24,\"env\":{\"SHELL\":\"/bin/zsh\",\"TERM\":\"xterm-256color\"}}\n\n[0.1,\"o\",\"bad\"]\n",
        "{\"version\":2,\"width\":80,\"height\":24,\"env\":{\"SHELL\":\"/bin/zsh\",\"TERM\":\"xterm-256color\"}}\nnot-json\n",
        "{\"version\":2,\"width\":80,\"height\":24,\"env\":{\"SHELL\":\"/bin/zsh\",\"TERM\":\"xterm-256color\"}}\n[0.1,\"x\",\"bad\"]\n",
    ])
    func malformedCast(_ cast: String) {
        #expect(throws: AsciicastValidationError.self) {
            try AsciicastValidator.validate(Data(cast.utf8))
        }
    }

    @Test("requires each controlled event class", arguments: [
        ("output", "[0.1,\"i\",\"__ASCIINEMA_UTF8__=café-λ\\n\"]\n[0.2,\"r\",\"53x17\"]\n"),
        ("input", "[0.1,\"o\",\"\\u001b[36m__ASCIINEMA_UTF8__=café-λ\\u001b[0m\"]\n[0.2,\"r\",\"53x17\"]\n"),
        ("resize", "[0.1,\"o\",\"\\u001b[36m__ASCIINEMA_UTF8__=café-λ\\u001b[0m\"]\n[0.2,\"i\",\"__ASCIINEMA_UTF8__=café-λ\\n\"]\n"),
    ])
    func missingEvidence(_ name: String, _ events: String) {
        let header = "{\"version\":2,\"width\":80,\"height\":24,\"env\":{\"SHELL\":\"/bin/zsh\",\"TERM\":\"xterm-256color\"}}\n"
        #expect(throws: AsciicastValidationError.self, "missing \(name) must fail") {
            try AsciicastValidator.validate(Data((header + events).utf8))
        }
    }
}
