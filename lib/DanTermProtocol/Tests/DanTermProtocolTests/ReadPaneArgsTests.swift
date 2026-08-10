// Tests for the CLI argument parser and rendering helpers for `danterm pane read`.
import Foundation
import Testing
@testable import DanTermProtocol

struct ReadPaneArgsTests {
    @Test("pane only parses")
    func paneOnlyParses() throws {
        let parsed = try parseReadPaneArgs(["--pane", "P1"])
        #expect(parsed == ParsedReadPane(pane: "P1", lineLimit: nil))
    }

    @Test("pane with lines parses")
    func paneWithLinesParses() throws {
        let parsed = try parseReadPaneArgs(["--pane", "P1", "--lines", "50"])
        #expect(parsed == ParsedReadPane(pane: "P1", lineLimit: 50))
    }

    @Test("flags can be in any order")
    func flagsCanBeInAnyOrder() throws {
        let parsed = try parseReadPaneArgs(["--lines", "50", "--pane", "P1"])
        #expect(parsed == ParsedReadPane(pane: "P1", lineLimit: 50))
    }

    @Test("no flags throws missing pane")
    func noFlagsThrowsMissingPane() {
        #expect(throws: ReadPaneParseError.missingPane) {
            try parseReadPaneArgs([])
        }
    }

    @Test("missing pane arg throws")
    func missingPaneArgThrows() {
        #expect(throws: ReadPaneParseError.missingPaneArg) {
            try parseReadPaneArgs(["--pane"])
        }
    }

    @Test("empty pane throws missing pane")
    func emptyPaneThrowsMissingPane() {
        #expect(throws: ReadPaneParseError.missingPane) {
            try parseReadPaneArgs(["--pane", ""])
        }
    }

    @Test("missing lines arg throws")
    func missingLinesArgThrows() {
        #expect(throws: ReadPaneParseError.missingLinesArg) {
            try parseReadPaneArgs(["--pane", "P1", "--lines"])
        }
    }

    @Test("invalid lines throw", arguments: ["0", "-5", "abc", "1.5"])
    func invalidLinesThrow(_ value: String) {
        #expect(throws: ReadPaneParseError.invalidLines(value)) {
            try parseReadPaneArgs(["--pane", "P1", "--lines", value])
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
