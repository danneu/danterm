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
            let targetKey = try #require(command.request.targetParameterKey)
            params.removeValue(forKey: targetKey)

            let error = #expect(throws: IpcRequestDecodeError.self) {
                try IpcRequest.decode(method: command.method, params: .object(params))
            }
            #expect(error?.message == "\(targetKey) required")
        }
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
        ]
    }
}
