// Tests for the public `danterm` command-line parser.
import Foundation
import XCTest
@testable import DanTermProtocol

final class CLIParserTests: XCTestCase {
    func testTabNewParsesLaunchFlags() throws {
        let command = try parseCLI(["tab", "new", "--cmd", "foo", "--cwd", "/x", "--title", "t"])
        XCTAssertEqual(command.method, Methods.tabNew)
        XCTAssertEqual(command.outputMode, .json)
        XCTAssertEqual(command.params["launch"], .object([
            "cmd": .string("foo"),
            "cwd": .string("/x"),
            "title": .string("t"),
        ]))
    }

    func testTabRenameParsesStringAndClear() throws {
        let rename = try parseCLI(["tab", "rename", "work", "logs"])
        XCTAssertEqual(rename.method, Methods.tabRename)
        XCTAssertEqual(rename.params["title"], .string("work logs"))
        XCTAssertEqual(rename.outputMode, .none)

        let clear = try parseCLI(["tab", "rename", "--clear"])
        XCTAssertEqual(clear.method, Methods.tabRename)
        XCTAssertEqual(clear.params["title"], .null)
    }

    func testPaneInputReadAndSplitParse() throws {
        let input = try parseCLI(["pane", "input", "--pane", "P1", "--", "ls", "Enter"])
        XCTAssertEqual(input.method, Methods.paneInput)
        XCTAssertEqual(input.params["pane"], .string("P1"))
        XCTAssertEqual(input.outputMode, .none)

        let read = try parseCLI(["pane", "read", "--pane", "P1", "--lines", "20"])
        XCTAssertEqual(read.method, Methods.paneRead)
        XCTAssertEqual(read.params["lines"], .number(20))
        XCTAssertEqual(read.outputMode, .text)

        let split = try parseCLI(["pane", "split", "--pane", "P1", "-v", "--cmd", "top", "--title", "monitor"])
        XCTAssertEqual(split.method, Methods.paneSplit)
        XCTAssertEqual(split.outputMode, .json)
        XCTAssertEqual(split.params["direction"], .string("vertical"))
        XCTAssertEqual(split.params["launch"], .object([
            "cmd": .string("top"),
            "title": .string("monitor"),
        ]))
    }

    func testRemovedLegacyCommandsAreUnknown() {
        for command in ["new-tab", "send-keys", "read-pane"] {
            XCTAssertThrowsError(try parseCLI([command])) { err in
                XCTAssertEqual((err as? CLIParseError)?.message, "unknown command: \(command)")
            }
        }
    }
}
