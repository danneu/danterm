// Tests for the CLI argument parser and rendering helpers for `danterm pane read`.
import Foundation
import Testing
@testable import DanTermProtocol

struct ReadPaneArgsTests {
    @Test("an empty tail parses")
    func anEmptyTailParses() throws {
        #expect(try parseReadPaneArgs([]) == ParsedReadPane(lineLimit: nil))
    }

    @Test("lines parses")
    func linesParses() throws {
        #expect(try parseReadPaneArgs(["--lines", "50"]) == ParsedReadPane(lineLimit: 50))
    }

    @Test("the pane flag is not this parser's to read")
    func thePaneFlagIsNotThisParsersToRead() {
        // Intent: the tail parser treats `--pane` as any other unknown flag.
        // Why it exists: the target belongs to the shared step that runs before
        //   this parser, so a target reaching it would mean two owners.
        #expect(throws: ReadPaneParseError.unknownFlag("--pane")) {
            try parseReadPaneArgs(["--pane", "P1"])
        }
    }

    @Test("missing lines arg throws")
    func missingLinesArgThrows() {
        #expect(throws: ReadPaneParseError.missingLinesArg) {
            try parseReadPaneArgs(["--lines"])
        }
    }

    @Test("invalid lines throw", arguments: ["0", "-5", "abc", "1.5"])
    func invalidLinesThrow(_ value: String) {
        #expect(throws: ReadPaneParseError.invalidLines(value)) {
            try parseReadPaneArgs(["--lines", value])
        }
    }

    @Test("unknown flag throws")
    func unknownFlagThrows() {
        #expect(throws: ReadPaneParseError.unknownFlag("--frob")) {
            try parseReadPaneArgs(["--frob"])
        }
    }

    @Test("unexpected argument throws")
    func unexpectedArgumentThrows() {
        #expect(throws: ReadPaneParseError.unexpectedArgument("foo")) {
            try parseReadPaneArgs(["foo"])
        }
    }

    @Test("render text result")
    func renderTextResult() {
        #expect(renderReadPaneResult(.object(["text": .string("hello")])) == "hello")
        #expect(renderReadPaneResult(.object(["text": .string("a\nb\nc\n")])) == "a\nb\nc\n")
        #expect(renderReadPaneResult(.object(["text": .string("")])) == "")
    }

    @Test("render malformed result returns nil")
    func renderMalformedResultReturnsNil() {
        #expect(renderReadPaneResult(.object([:])) == nil)
        #expect(renderReadPaneResult(.object(["text": .number(42)])) == nil)
        #expect(renderReadPaneResult(.array([.number(1), .number(2)])) == nil)
        #expect(renderReadPaneResult(.string("hello")) == nil)
    }

    @Test("tail lines")
    func tailLinesPreservesTerminators() {
        #expect(tailLines("a\nb\nc\nd\n", n: 2) == "c\nd\n")
        #expect(tailLines("a\nb\nc", n: 2) == "b\nc")
        #expect(tailLines("a\nb", n: 5) == "a\nb")
        #expect(tailLines("", n: 1) == "")
        #expect(tailLines("hello\n", n: 1) == "hello\n")
        #expect(tailLines("a\nb\nc\nd", n: 1) == "d")
        #expect(tailLines("a\nb\n", n: 0) == "")
    }
}
