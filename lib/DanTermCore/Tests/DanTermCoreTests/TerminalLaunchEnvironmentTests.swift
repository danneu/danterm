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
}
