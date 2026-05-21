// Tests for the CLI argument parser shared with `danterm pane input`.
import Foundation
import XCTest
@testable import DanTermProtocol

final class SendKeysArgsTests: XCTestCase {
    func testNoSeparatorThrows() {
        XCTAssertThrowsError(try parseSendKeysArgs(["hello", "world"])) { err in
            XCTAssertEqual(err as? SendKeysParseError, .missingArguments)
        }
    }

    func testTmuxModeBasic() throws {
        let parsed = try parseSendKeysArgs(["--", "ls", "Enter"])
        XCTAssertEqual(
            parsed,
            ParsedSendKeys(
                pane: nil,
                events: [.text("ls"), .key(.named(.enter), [])]
            )
        )
    }

    func testExplicitPaneInTmuxMode() throws {
        let parsed = try parseSendKeysArgs(["--pane", "P1", "--", "x"])
        XCTAssertEqual(
            parsed,
            ParsedSendKeys(pane: "P1", events: [.text("x")])
        )
    }

    func testExplicitPaneWithoutSeparatorThrows() {
        XCTAssertThrowsError(try parseSendKeysArgs(["--pane", "P1", "hello"])) { err in
            XCTAssertEqual(err as? SendKeysParseError, .missingArguments)
        }
    }

    func testLiteralFlagPassesThroughToTokens() throws {
        let parsed = try parseSendKeysArgs(["--literal", "--", "Enter"])
        XCTAssertEqual(
            parsed,
            ParsedSendKeys(pane: nil, events: [.text("Enter")])
        )
    }

    func testLiteralWithoutSeparatorThrows() {
        XCTAssertThrowsError(try parseSendKeysArgs(["--literal", "hello"])) { err in
            XCTAssertEqual(err as? SendKeysParseError, .literalRequiresSeparator)
        }
    }

    func testUnknownFlagThrows() {
        XCTAssertThrowsError(try parseSendKeysArgs(["--bogus", "x"])) { err in
            XCTAssertEqual(err as? SendKeysParseError, .unknownFlag("--bogus"))
        }
    }

    func testMissingPaneArgThrows() {
        XCTAssertThrowsError(try parseSendKeysArgs(["--pane"])) { err in
            XCTAssertEqual(err as? SendKeysParseError, .missingPaneArg)
        }
    }

    func testEmptyArgsThrows() {
        XCTAssertThrowsError(try parseSendKeysArgs([])) { err in
            XCTAssertEqual(err as? SendKeysParseError, .missingArguments)
        }
    }

    func testEmptyAfterSeparatorThrows() {
        XCTAssertThrowsError(try parseSendKeysArgs(["--"])) { err in
            XCTAssertEqual(err as? SendKeysParseError, .missingArguments)
        }
    }

    func testKeyTokenErrorIsWrapped() {
        XCTAssertThrowsError(try parseSendKeysArgs(["--", "C-yz"])) { err in
            XCTAssertEqual(err as? SendKeysParseError, .keyToken(.unknownKey("C-yz")))
        }
    }
}
