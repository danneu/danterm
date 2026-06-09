// Swift Testing migration of the legacy `tests/TerminalLaunchEnvironmentTests.swift`
// harness suite. Pins the pure terminal launch environment helper:
// DANTERM_* env vars (flag, sock, pane, token) are included; DANTERM_TAB
// is intentionally omitted from new pane environments.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct TerminalLaunchEnvironmentTests {
    @Test("terminal launch env includes pane context and omits tab context")
    func terminalLaunchEnvIncludesPaneOmitsTab() {
        // Intent: terminalLaunchEnvironment carries DANTERM_FLAG /
        //   DANTERM_SOCK / DANTERM_PANE / DANTERM_TOKEN but omits
        //   DANTERM_TAB.
        // Why it exists: pins the env-var surface of the helper.
        // Scenario: spec-first env vars.
        let paneId = PaneId()
        let env = terminalLaunchEnvironment(
            ipcSocketPath: "/tmp/danterm/control.sock",
            paneId: paneId,
            token: "secret-token"
        )
        let dict = Dictionary(uniqueKeysWithValues: env)

        #expect(dict[EnvVars.flag] == "1")
        #expect(dict[EnvVars.sock] == "/tmp/danterm/control.sock")
        #expect(dict[EnvVars.pane] == paneId.rawValue.uuidString)
        #expect(dict["DANTERM_TOKEN"] == "secret-token")
        #expect(dict["DANTERM_TAB"] == nil, "new pane environments should not include DANTERM_TAB")
    }

    @Test("restore launch env includes pane context and optional scrollback var")
    func restoreLaunchEnvIncludesPaneContextAndOptionalScrollbackVar() {
        // Intent: restoreLaunchEnvironment restores the same DanTerm pane
        //   context as new panes and adds the replay var only when present.
        // Why it exists: pins the recovered-pane CLI context needed by
        //   pane-scoped commands such as agent.attach.
        // Scenario: one restored pane with scrollback replay, plus one with no
        //   optional restore input.
        let paneId = PaneId()
        let full = Dictionary(uniqueKeysWithValues: restoreLaunchEnvironment(
            ipcSocketPath: "/tmp/danterm/control.sock",
            paneId: paneId,
            token: "secret-token",
            scrollbackFilePath: "/tmp/danterm/replay.txt"
        ))

        #expect(full[EnvVars.flag] == "1")
        #expect(full[EnvVars.sock] == "/tmp/danterm/control.sock")
        #expect(full[EnvVars.pane] == paneId.rawValue.uuidString)
        #expect(full["DANTERM_TOKEN"] == "secret-token")
        #expect(full["DANTERM_RESTORE_SCROLLBACK_FILE"] == "/tmp/danterm/replay.txt")

        let minimal = Dictionary(uniqueKeysWithValues: restoreLaunchEnvironment(
            ipcSocketPath: "/tmp/danterm/control.sock",
            paneId: paneId,
            token: "secret-token",
            scrollbackFilePath: nil
        ))
        #expect(minimal["DANTERM_RESTORE_SCROLLBACK_FILE"] == nil)
    }
}
