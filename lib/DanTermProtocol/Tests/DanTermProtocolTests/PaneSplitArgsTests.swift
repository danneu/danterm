// Tests for the CLI argument parser shared with `danterm pane split`.
import Foundation
import XCTest
@testable import DanTermProtocol

final class PaneSplitArgsTests: XCTestCase {
    func testHorizontalDirectionParses() throws {
        let parsed = try parsePaneSplitArgs(["-h"])
        XCTAssertEqual(parsed, ParsedPaneSplit(pane: nil, direction: .horizontal))
    }

    func testVerticalDirectionParses() throws {
        let parsed = try parsePaneSplitArgs(["-v"])
        XCTAssertEqual(parsed, ParsedPaneSplit(pane: nil, direction: .vertical))
    }

    func testExplicitPaneParses() throws {
        let parsed = try parsePaneSplitArgs(["--pane", "P1", "-h"])
        XCTAssertEqual(parsed, ParsedPaneSplit(pane: "P1", direction: .horizontal))
    }

    func testBackgroundFlagParses() throws {
        // Intent: `--background` records only the background flag.
        // Why it exists: preserves back-compat for existing split recipes while
        //   the CLI layer flips the default to background.
        // Scenario: an existing agent recipe still includes `--background`.
        let parsed = try parsePaneSplitArgs(["-h", "--background"])
        XCTAssertEqual(parsed, ParsedPaneSplit(pane: nil, direction: .horizontal, background: true, foreground: false))
    }

    func testForegroundFlagParses() throws {
        // Intent: `--foreground` records a request to focus the new split pane
        //   within its tab.
        // Why it exists: keeps focus policy explicit without making the arg
        //   parser infer command defaults.
        // Scenario: the user asks an agent to split and focus the new pane.
        let parsed = try parsePaneSplitArgs(["-h", "--foreground"])
        XCTAssertEqual(parsed, ParsedPaneSplit(pane: nil, direction: .horizontal, background: false, foreground: true))
    }

    func testLaunchFlagsParse() throws {
        let parsed = try parsePaneSplitArgs(["-h", "--cmd", "vim foo", "--cwd", "/tmp", "--title", "edit"])
        XCTAssertEqual(
            parsed,
            ParsedPaneSplit(
                pane: nil,
                direction: .horizontal,
                launch: LaunchSpec(cmd: "vim foo", cwd: "/tmp", title: "edit")
            )
        )
    }

    func testBackgroundCombinesWithOtherFlags() throws {
        let parsed = try parsePaneSplitArgs([
            "--pane", "P1", "-h", "--background",
            "--cmd", "just test", "--cwd", "/tmp", "--title", "tests",
        ])
        XCTAssertEqual(
            parsed,
            ParsedPaneSplit(
                pane: "P1",
                direction: .horizontal,
                launch: LaunchSpec(cmd: "just test", cwd: "/tmp", title: "tests"),
                background: true,
                foreground: false
            )
        )
    }

    func testConflictingFocusFlagsThrow() {
        // Intent: `--background --foreground` is rejected for pane splits.
        // Why it exists: prevents ambiguous focus policy before the command is
        //   serialized for IPC.
        // Scenario: a composed split command accidentally includes both flags.
        XCTAssertThrowsError(try parsePaneSplitArgs(["-h", "--background", "--foreground"])) { err in
            XCTAssertEqual(err as? PaneSplitParseError, .conflictingFocusFlags)
        }
    }

    func testEmptyCommandIsOmittedFromLaunch() throws {
        let parsed = try parsePaneSplitArgs(["-v", "--cmd", "", "--cwd", "/tmp"])
        XCTAssertEqual(
            parsed,
            ParsedPaneSplit(
                pane: nil,
                direction: .vertical,
                launch: LaunchSpec(cmd: nil, cwd: "/tmp", title: nil)
            )
        )
    }

    func testMissingPaneArgThrows() {
        XCTAssertThrowsError(try parsePaneSplitArgs(["--pane"])) { err in
            XCTAssertEqual(err as? PaneSplitParseError, .missingPaneArg)
        }
    }

    func testMissingLaunchFlagValueThrows() {
        XCTAssertThrowsError(try parsePaneSplitArgs(["-h", "--cmd"])) { err in
            XCTAssertEqual(err as? PaneSplitParseError, .missingValue("--cmd"))
        }
    }

    func testNoDirectionThrows() {
        XCTAssertThrowsError(try parsePaneSplitArgs([])) { err in
            XCTAssertEqual(err as? PaneSplitParseError, .missingDirection)
        }
    }

    func testUnknownFlagThrows() {
        XCTAssertThrowsError(try parsePaneSplitArgs(["--bogus"])) { err in
            XCTAssertEqual(err as? PaneSplitParseError, .unknownFlag("--bogus"))
        }
    }

    func testTrailingArgumentThrows() {
        XCTAssertThrowsError(try parsePaneSplitArgs(["-h", "extra"])) { err in
            XCTAssertEqual(err as? PaneSplitParseError, .unexpectedArgument("extra"))
        }
    }
}
