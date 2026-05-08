// Tests for the CLI argument parser and rendering helpers for `danterm read-pane`.
import Foundation
import XCTest
@testable import DanTermProtocol

final class ReadPaneArgsTests: XCTestCase {
    func testPaneOnlyParses() throws {
        let parsed = try parseReadPaneArgs(["--pane", "P1"])
        XCTAssertEqual(parsed, ParsedReadPane(pane: "P1", lineLimit: nil))
    }

    func testPaneWithLinesParses() throws {
        let parsed = try parseReadPaneArgs(["--pane", "P1", "--lines", "50"])
        XCTAssertEqual(parsed, ParsedReadPane(pane: "P1", lineLimit: 50))
    }

    func testFlagsCanBeInAnyOrder() throws {
        let parsed = try parseReadPaneArgs(["--lines", "50", "--pane", "P1"])
        XCTAssertEqual(parsed, ParsedReadPane(pane: "P1", lineLimit: 50))
    }

    func testNoFlagsThrowsMissingPane() {
        XCTAssertThrowsError(try parseReadPaneArgs([])) { err in
            XCTAssertEqual(err as? ReadPaneParseError, .missingPane)
        }
    }

    func testMissingPaneArgThrows() {
        XCTAssertThrowsError(try parseReadPaneArgs(["--pane"])) { err in
            XCTAssertEqual(err as? ReadPaneParseError, .missingPaneArg)
        }
    }

    func testEmptyPaneThrowsMissingPane() {
        XCTAssertThrowsError(try parseReadPaneArgs(["--pane", ""])) { err in
            XCTAssertEqual(err as? ReadPaneParseError, .missingPane)
        }
    }

    func testMissingLinesArgThrows() {
        XCTAssertThrowsError(try parseReadPaneArgs(["--pane", "P1", "--lines"])) { err in
            XCTAssertEqual(err as? ReadPaneParseError, .missingLinesArg)
        }
    }

    func testInvalidLinesThrows() {
        for value in ["0", "-5", "abc", "1.5"] {
            XCTAssertThrowsError(try parseReadPaneArgs(["--pane", "P1", "--lines", value])) { err in
                XCTAssertEqual(err as? ReadPaneParseError, .invalidLines(value))
            }
        }
    }

    func testUnknownFlagThrows() {
        XCTAssertThrowsError(try parseReadPaneArgs(["--frob"])) { err in
            XCTAssertEqual(err as? ReadPaneParseError, .unknownFlag("--frob"))
        }
    }

    func testUnexpectedArgumentThrows() {
        XCTAssertThrowsError(try parseReadPaneArgs(["foo"])) { err in
            XCTAssertEqual(err as? ReadPaneParseError, .unexpectedArgument("foo"))
        }
    }

    func testRenderTextResult() {
        XCTAssertEqual(renderReadPaneResult(.object(["text": .string("hello")])), "hello")
        XCTAssertEqual(renderReadPaneResult(.object(["text": .string("a\nb\nc\n")])), "a\nb\nc\n")
        XCTAssertEqual(renderReadPaneResult(.object(["text": .string("")])), "")
    }

    func testRenderMalformedResultReturnsNil() {
        XCTAssertNil(renderReadPaneResult(.object([:])))
        XCTAssertNil(renderReadPaneResult(.object(["text": .number(42)])))
        XCTAssertNil(renderReadPaneResult(.array([.number(1), .number(2)])))
        XCTAssertNil(renderReadPaneResult(.string("hello")))
    }

    func testTailLines() {
        XCTAssertEqual(tailLines("a\nb\nc\nd\n", n: 2), "c\nd\n")
        XCTAssertEqual(tailLines("a\nb\nc", n: 2), "b\nc")
        XCTAssertEqual(tailLines("a\nb", n: 5), "a\nb")
        XCTAssertEqual(tailLines("", n: 1), "")
        XCTAssertEqual(tailLines("hello\n", n: 1), "hello\n")
        XCTAssertEqual(tailLines("a\nb\nc\nd", n: 1), "d")
        XCTAssertEqual(tailLines("a\nb\n", n: 0), "")
    }
}
