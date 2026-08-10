// Tests for the CLI argument parser shared with `danterm pane input`.
import Foundation
import Testing
@testable import DanTermProtocol

struct SendKeysArgsTests {
    @Test("no separator throws")
    func noSeparatorThrows() {
        #expect(throws: SendKeysParseError.missingArguments) {
            try parseSendKeysArgs(["hello", "world"])
        }
    }

    @Test("tmux mode basic")
    func tmuxModeBasic() throws {
        let parsed = try parseSendKeysArgs(["--", "ls", "Enter"])
        #expect(parsed == ParsedSendKeys(
                pane: nil,
                events: [.text("ls"), .key(.named(.enter), [])]
            ))
    }

    @Test("explicit pane in tmux mode")
    func explicitPaneInTmuxMode() throws {
        let parsed = try parseSendKeysArgs(["--pane", "P1", "--", "x"])
        #expect(parsed == ParsedSendKeys(pane: "P1", events: [.text("x")]))
    }

    @Test("explicit pane without separator throws")
    func explicitPaneWithoutSeparatorThrows() {
        #expect(throws: SendKeysParseError.missingArguments) {
            try parseSendKeysArgs(["--pane", "P1", "hello"])
        }
    }

    @Test("literal flag passes through to tokens")
    func literalFlagPassesThroughToTokens() throws {
        let parsed = try parseSendKeysArgs(["--literal", "--", "Enter"])
        #expect(parsed == ParsedSendKeys(pane: nil, events: [.text("Enter")]))
    }

    @Test("literal without separator throws")
    func literalWithoutSeparatorThrows() {
        #expect(throws: SendKeysParseError.literalRequiresSeparator) {
            try parseSendKeysArgs(["--literal", "hello"])
        }
    }

    @Test("unknown flag throws")
    func unknownFlagThrows() {
        #expect(throws: SendKeysParseError.unknownFlag("--bogus")) {
            try parseSendKeysArgs(["--bogus", "x"])
        }
    }

    @Test("missing pane arg throws")
    func missingPaneArgThrows() {
        #expect(throws: SendKeysParseError.missingPaneArg) {
            try parseSendKeysArgs(["--pane"])
        }
    }

    @Test("empty args throws")
    func emptyArgsThrows() {
        #expect(throws: SendKeysParseError.missingArguments) {
            try parseSendKeysArgs([])
        }
    }

    @Test("empty after separator throws")
    func emptyAfterSeparatorThrows() {
        #expect(throws: SendKeysParseError.missingArguments) {
            try parseSendKeysArgs(["--"])
        }
    }

    @Test("key token error is wrapped")
    func keyTokenErrorIsWrapped() {
        #expect(throws: SendKeysParseError.keyToken(.unknownKey("C-yz"))) {
            try parseSendKeysArgs(["--", "C-yz"])
        }
    }
}
