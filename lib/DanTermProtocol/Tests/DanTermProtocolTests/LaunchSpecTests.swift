// Tests for strict IPC launch specification validation.
import Foundation
import XCTest
@testable import DanTermProtocol

final class LaunchSpecTests: XCTestCase {
    func testAbsentLaunchReturnsNil() throws {
        XCTAssertNil(try parseLaunchSpec(nil))
    }

    func testNonObjectThrows() {
        XCTAssertThrowsError(try parseLaunchSpec(.string("nope"))) { err in
            XCTAssertEqual(err as? LaunchSpecParseError, .notObject)
        }
    }

    func testNonStringFieldsThrow() {
        let cases: [(String, JSONValue)] = [
            ("cmd", .number(1)),
            ("cwd", .null),
            ("title", .array([])),
        ]
        for (field, value) in cases {
            XCTAssertThrowsError(try parseLaunchSpec(.object([field: value]))) { err in
                XCTAssertEqual(err as? LaunchSpecParseError, .fieldNotString(field: field))
            }
        }
    }

    func testEmptyCommandOnlyReturnsNil() throws {
        XCTAssertNil(try parseLaunchSpec(.object(["cmd": .string("")])))
    }

    func testAllStringFieldsParse() throws {
        let spec = try parseLaunchSpec(.object([
            "cmd": .string("vim foo"),
            "cwd": .string("/tmp"),
            "title": .string("edit"),
        ]))
        XCTAssertEqual(spec, LaunchSpec(cmd: "vim foo", cwd: "/tmp", title: "edit"))
    }
}
