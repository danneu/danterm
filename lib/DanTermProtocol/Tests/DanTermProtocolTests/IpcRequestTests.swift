// Behavioral coverage for the shared typed IPC request catalog.
import Foundation
import Testing
@testable import DanTermProtocol

struct IpcRequestTests {
    @Test("every CLI request round trips through the shared catalog")
    func everyCLIRequestRoundTripsThroughCatalog() throws {
        // Intent: every command the CLI builds decodes to the same typed request.
        // Why it exists: separate CLI and daemon parameter transcriptions can drift
        //   while their independent tests remain green.
        // Scenario: one representative invocation for every client request method.
        let commands = try representativeCLICommands()

        #expect(Set(commands.map(\.method)) == Set(IpcRequestMethod.allCases.map(\.rawValue)))
        for command in commands {
            let decoded = try IpcRequest.decode(
                method: command.method,
                params: .object(command.params)
            )
            #expect(decoded == command.request)
        }
    }

    @Test("every catalog method declared as targeting rejects its absent target")
    func everyTargetingCatalogMethodRejectsAbsentTarget() throws {
        // Intent: targeting classification drives the missing-target proof.
        // Why it exists: a new targeting method must join the proof when it joins
        //   the exhaustive catalog, without a second hand-maintained method list.
        // Scenario: remove the declared target from otherwise-valid CLI params.
        for command in try representativeCLICommands()
        where command.request.method.isTargeting {
            var params = command.params
            let targetKeys = command.request.targetParameterKeys
            let targetKey = try #require(targetKeys.first)
            for key in targetKeys { params.removeValue(forKey: key) }

            let error = #expect(throws: IpcRequestDecodeError.self) {
                try IpcRequest.decode(method: command.method, params: .object(params))
            }
            let expected = targetKeys.count == 1 ? "\(targetKey) required" : "pane or tab required"
            #expect(error?.message == expected)
        }
    }

    @Test("todo requests accept either owner and reject ambiguous targeting")
    func todoRequestsRequireExactlyOneOwner() throws {
        let pane = "11111111-1111-4111-8111-111111111111"
        let tab = "22222222-2222-4222-8222-222222222222"

        #expect(try IpcRequest.decode(
            method: IpcRequestMethod.todoList.rawValue,
            params: .object(["tab": .string(tab)])
        ) == .todoList(owner: .tab(TabId(rawValue: UUID(uuidString: tab)!))))

        let absent = #expect(throws: IpcRequestDecodeError.self) {
            try IpcRequest.decode(method: IpcRequestMethod.todoList.rawValue, params: .object([:]))
        }
        #expect(absent?.message == "pane or tab required")

        let ambiguous = #expect(throws: IpcRequestDecodeError.self) {
            try IpcRequest.decode(
                method: IpcRequestMethod.todoList.rawValue,
                params: .object(["pane": .string(pane), "tab": .string(tab)])
            )
        }
        #expect(ambiguous?.message == "exactly one of pane or tab required")
    }

    @Test("group.rename requires a string name", arguments: [
        JSONValue.null, .number(7), .object([:]),
    ])
    func groupRenameRequiresStringName(_ name: JSONValue) throws {
        // Intent: a `name` that is absent or not a string is rejected at decode.
        // Why it exists: `group.rename` has no clear-to-null form, so a null
        //   name must fail rather than decode to one.
        // Scenario: spec-first non-string names, plus the absent case below.
        let group = "33333333-3333-4333-8333-333333333333"

        let wrongType = #expect(throws: IpcRequestDecodeError.self) {
            try IpcRequest.decode(
                method: IpcRequestMethod.groupRename.rawValue,
                params: .object(["group": .string(group), "name": name])
            )
        }
        #expect(wrongType?.message == "invalid name")

        let absent = #expect(throws: IpcRequestDecodeError.self) {
            try IpcRequest.decode(
                method: IpcRequestMethod.groupRename.rawValue,
                params: .object(["group": .string(group)])
            )
        }
        #expect(absent?.message == "invalid name")
    }

    private func representativeCLICommands() throws -> [CLICommand] {
        let pane = "11111111-1111-4111-8111-111111111111"
        let tab = "22222222-2222-4222-8222-222222222222"
        let group = "33333333-3333-4333-8333-333333333333"
        let todo = "44444444-4444-4444-8444-444444444444"

        return [
            CLICommand(request: .doctorPermissions, outputMode: .none),
            try parseCLI(["ls"]),
            try parseCLI(["focus"]),
            try parseCLI(["tab", "new", "--group", group], currentDirectory: "/caller"),
            try parseCLI(["tab", "rename", "--tab", tab, "work"]),
            try parseCLI(["tab", "close", "--tab", tab]),
            try parseCLI(["group", "rename", "--group", group, "notes"]),
            try parseCLI(["pane", "focus", pane]),
            try parseCLI(["pane", "info", "--pane", pane]),
            try parseCLI(["pane", "split", "--pane", pane, "-h"]),
            try parseCLI(["pane", "close", "--pane", pane]),
            try parseCLI(["pane", "input", "--pane", pane, "--", "C-c"]),
            try parseCLI(["pane", "read", "--pane", pane, "--lines", "20"]),
            try parseCLI(["pane", "rows", "--pane", pane]),
            try parseCLI(["pane", "zoom", "--pane", pane, "on"]),
            try parseCLI(["pane", "tape", "--pane", pane, "--follow"]),
            try parseCLI(["theme", "set", "--pane", pane, "Tokyo Night"]),
            try parseCLI(["agent", "attach", "--pane", pane, "--kind", "codex", "--id", "thread-1"]),
            try parseCLI(["agent", "activity", "--pane", pane, "--kind", "codex", "--id", "thread-1", "--state", "working"]),
            try parseCLI(["agent", "detach", "--pane", pane, "--kind", "codex", "--id", "thread-1"]),
            try parseCLI(["todo", "list", "--pane", pane]),
            try parseCLI(["todo", "add", "--pane", pane, "write", "test"]),
            try parseCLI(["todo", "edit", "--pane", pane, todo, "write", "test"]),
            try parseCLI(["todo", "done", "--pane", pane, todo]),
            try parseCLI(["todo", "open", "--pane", pane, todo]),
            try parseCLI(["todo", "delete", "--pane", pane, todo]),
            try parseCLI(["todo", "clear-completed", "--pane", pane]),
            try parseCLI(["todo", "list", "--tab", tab]),
            try parseCLI(["todo", "add", "--tab", tab, "write", "test"]),
            try parseCLI(["todo", "edit", "--tab", tab, todo, "write", "test"]),
            try parseCLI(["todo", "done", "--tab", tab, todo]),
            try parseCLI(["todo", "open", "--tab", tab, todo]),
            try parseCLI(["todo", "delete", "--tab", tab, todo]),
            try parseCLI(["todo", "clear-completed", "--tab", tab]),
        ]
    }
}
