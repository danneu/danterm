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
        #expect(parsed == ParsedSendKeys(events: [.text("ls"), .key(.named(.enter), [])]))
    }

    @Test("the pane flag is not this parser's to read")
    func thePaneFlagIsNotThisParsersToRead() {
        // Intent: the tail parser treats `--pane` as any other unknown flag.
        // Why it exists: the target belongs to the shared step that runs before
        //   this parser, so a target reaching it would mean two owners.
        #expect(throws: SendKeysParseError.unknownFlag("--pane")) {
            try parseSendKeysArgs(["--pane", "P1", "--", "x"])
        }
    }

    @Test("one token without a separator throws")
    func oneTokenWithoutSeparatorThrows() {
        #expect(throws: SendKeysParseError.missingArguments) {
            try parseSendKeysArgs(["hello"])
        }
    }

    @Test("literal flag passes through to tokens")
    func literalFlagPassesThroughToTokens() throws {
        let parsed = try parseSendKeysArgs(["--literal", "--", "Enter"])
        #expect(parsed == ParsedSendKeys(events: [.text("Enter")]))
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
