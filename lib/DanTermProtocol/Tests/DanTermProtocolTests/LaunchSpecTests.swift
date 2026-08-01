// Tests for strict IPC launch specification validation.
import Foundation
import Testing
@testable import DanTermProtocol

struct LaunchSpecTests {
    @Test("absent launch returns nil")
    func absentLaunchReturnsNil() throws {
        #expect(try parseLaunchSpec(nil) == nil)
    }

    @Test("non object throws")
    func nonObjectThrows() {
        #expect(throws: LaunchSpecParseError.notObject) {
            try parseLaunchSpec(.string("nope"))
        }
    }

    @Test("non string fields throw", arguments: [
        ("cmd", .number(1)),
        ("cwd", .null),
        ("title", .array([])),
    ] as [(String, JSONValue)])
    func nonStringFieldsThrow(_ testCase: (String, JSONValue)) {
        #expect(throws: LaunchSpecParseError.fieldNotString(field: testCase.0)) {
            try parseLaunchSpec(.object([testCase.0: testCase.1]))
        }
    }

    @Test("empty command only returns nil")
    func emptyCommandOnlyReturnsNil() throws {
        #expect(try parseLaunchSpec(.object(["cmd": .string("")])) == nil)
    }

    @Test("all string fields parse")
    func allStringFieldsParse() throws {
        let spec = try parseLaunchSpec(.object([
            "cmd": .string("vim foo"),
            "cwd": .string("/tmp"),
            "title": .string("edit"),
        ]))
        #expect(spec == LaunchSpec(cmd: "vim foo", cwd: "/tmp", title: "edit"))
    }
}
