// Tests for the CLI argument parser shared with `danterm tab new`.
import Foundation
import XCTest
@testable import DanTermProtocol

final class TabNewArgsTests: XCTestCase {
    func testEmptyArgsParsesDefaultTab() throws {
        XCTAssertEqual(try parseTabNewArgs([]), ParsedTabNew(group: nil, launch: nil))
    }

    func testGroupParses() throws {
        XCTAssertEqual(
            try parseTabNewArgs(["--group", "Builds"]),
            ParsedTabNew(group: "Builds", launch: nil)
        )
    }

    func testLaunchFlagsParseIndividually() throws {
        XCTAssertEqual(
            try parseTabNewArgs(["--cmd", "date"]),
            ParsedTabNew(group: nil, launch: LaunchSpec(cmd: "date", cwd: nil, title: nil))
        )
        XCTAssertEqual(
            try parseTabNewArgs(["--cwd", "/tmp"]),
            ParsedTabNew(group: nil, launch: LaunchSpec(cmd: nil, cwd: "/tmp", title: nil))
        )
        XCTAssertEqual(
            try parseTabNewArgs(["--title", "logs"]),
            ParsedTabNew(group: nil, launch: LaunchSpec(cmd: nil, cwd: nil, title: "logs"))
        )
    }

    func testCombinationParses() throws {
        XCTAssertEqual(
            try parseTabNewArgs(["--group", "Builds", "--cmd", "make test", "--cwd", "/repo", "--title", "tests"]),
            ParsedTabNew(group: "Builds", launch: LaunchSpec(cmd: "make test", cwd: "/repo", title: "tests"))
        )
    }

    func testMissingValueThrows() {
        XCTAssertThrowsError(try parseTabNewArgs(["--title"])) { err in
            XCTAssertEqual(err as? TabNewParseError, .missingValue("--title"))
        }
    }

    func testUnknownFlagThrows() {
        XCTAssertThrowsError(try parseTabNewArgs(["--bogus"])) { err in
            XCTAssertEqual(err as? TabNewParseError, .unknownFlag("--bogus"))
        }
    }
}
