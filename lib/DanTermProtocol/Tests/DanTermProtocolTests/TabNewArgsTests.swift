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
            try parseTabNewArgs(["--group", "G1"]),
            ParsedTabNew(group: "G1", launch: nil)
        )
    }

    func testBackgroundFlagParses() throws {
        // Intent: `--background` records only the background flag.
        // Why it exists: preserves back-compat for scripts that already pass the
        //   now-redundant explicit background request.
        // Scenario: an existing agent recipe still includes `--background`;
        //   parsing must keep accepting it without implying foreground.
        XCTAssertEqual(
            try parseTabNewArgs(["--background"]),
            ParsedTabNew(group: nil, launch: nil, background: true, foreground: false)
        )
    }

    func testForegroundFlagParses() throws {
        // Intent: `--foreground` records a request to focus/select the new tab.
        // Why it exists: keeps the arg parser as a faithful flag-presence layer
        //   before CLI policy maps absent focus flags to background execution.
        // Scenario: the user explicitly asks an agent to switch to the new tab.
        XCTAssertEqual(
            try parseTabNewArgs(["--foreground"]),
            ParsedTabNew(group: nil, launch: nil, background: false, foreground: true)
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
            try parseTabNewArgs(["--group", "G1", "--cmd", "make test", "--cwd", "/repo", "--title", "tests"]),
            ParsedTabNew(group: "G1", launch: LaunchSpec(cmd: "make test", cwd: "/repo", title: "tests"))
        )
    }

    func testBackgroundCombinesWithOtherFlags() throws {
        XCTAssertEqual(
            try parseTabNewArgs(["--group", "G1", "--background", "--cmd", "date"]),
            ParsedTabNew(
                group: "G1",
                launch: LaunchSpec(cmd: "date", cwd: nil, title: nil),
                background: true,
                foreground: false
            )
        )
    }

    func testConflictingFocusFlagsThrow() {
        // Intent: `--background --foreground` is rejected instead of letting the
        //   last parsed flag win.
        // Why it exists: prevents ambiguous focus policy on the agent-facing CLI.
        // Scenario: a composed command accidentally includes both focus flags.
        XCTAssertThrowsError(try parseTabNewArgs(["--background", "--foreground"])) { err in
            XCTAssertEqual(err as? TabNewParseError, .conflictingFocusFlags)
        }
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
