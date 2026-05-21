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
