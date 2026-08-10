// Swift Testing migration of the legacy `tests/TerminalLaunchEnvironmentTests.swift`
// harness suite. Pins the pure terminal launch environment helper:
// DANTERM_* env vars (flag, sock, pane) are included; DANTERM_TAB
// is intentionally omitted from new pane environments.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct TerminalLaunchEnvironmentTests {
    @Test("terminal launch env includes pane context and omits tab context")
    func terminalLaunchEnvIncludesPaneOmitsTab() {
        // Intent: terminalLaunchEnvironment carries DANTERM_FLAG /
        //   DANTERM_SOCK / DANTERM_PANE but omits
        //   DANTERM_TAB.
        // Why it exists: pins the env-var surface of the helper.
        // Scenario: spec-first env vars.
        let paneId = PaneId()
        let env = terminalLaunchEnvironment(
            ipcSocketPath: "/tmp/danterm/control.sock",
            paneId: paneId
        )
        let dict = Dictionary(uniqueKeysWithValues: env)

        #expect(dict[EnvVars.flag] == "1")
        #expect(dict[EnvVars.sock] == "/tmp/danterm/control.sock")
        #expect(dict[EnvVars.pane] == paneId.rawValue.uuidString)
        #expect(dict["DANTERM_TAB"] == nil, "new pane environments should not include DANTERM_TAB")
    }

    @Test("terminal launch env clears inherited socket targeting for a non-owner")
    func terminalLaunchEnvClearsSocketForNonOwner() {
        // Intent: a pane launched by an instance without a control socket cannot
        //   inherit a different instance's socket target.
        // Why it exists: the launch environment is an overlay, so omitting
        //   DANTERM_SOCK would preserve a hostile inherited value.
        // Scenario: a second same-identity app is launched from the first app's
        //   pane, loses the bind race, and then opens its own pane.
        let paneId = PaneId()
        let env = Dictionary(uniqueKeysWithValues: terminalLaunchEnvironment(
            ipcSocketPath: nil,
            paneId: paneId
        ))

        #expect(env[EnvVars.flag] == "1")
        #expect(env[EnvVars.sock] == "")
        #expect(env[EnvVars.pane] == paneId.rawValue.uuidString)
    }

    @Test("restore launch env includes optional restore values verbatim")
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
            scrollbackFilePath: "/tmp/danterm/replay.txt",
            command: "printf 'one\ntwo'"
        ))

        #expect(full[EnvVars.flag] == "1")
        #expect(full[EnvVars.sock] == "/tmp/danterm/control.sock")
        #expect(full[EnvVars.pane] == paneId.rawValue.uuidString)
        #expect(full["DANTERM_RESTORE_SCROLLBACK_FILE"] == "/tmp/danterm/replay.txt")
        #expect(full["DANTERM_RESTORE_COMMAND"] == "printf 'one\ntwo'")

        let minimal = Dictionary(uniqueKeysWithValues: restoreLaunchEnvironment(
            ipcSocketPath: "/tmp/danterm/control.sock",
            paneId: paneId,
            scrollbackFilePath: nil,
            command: ""
        ))
        #expect(minimal["DANTERM_RESTORE_SCROLLBACK_FILE"] == nil)
        #expect(minimal["DANTERM_RESTORE_COMMAND"] == nil)
    }

    @Test("hostile inherited restore values are absent from every launch shape")
    func inheritedRestoreValuesAreScrubbed() {
        let paneId = PaneId()
        let inherited = scrubbedTerminalProcessEnvironment([
            "PATH": "/usr/bin",
            "DANTERM_RESTORE_COMMAND": "hostile command",
            "DANTERM_RESTORE_SCROLLBACK_FILE": "/hostile/replay",
        ])
        let normal = Dictionary(uniqueKeysWithValues: terminalLaunchEnvironment(
            ipcSocketPath: "/tmp/danterm/control.sock",
            paneId: paneId
        ))
        let emptyRestore = Dictionary(uniqueKeysWithValues: restoreLaunchEnvironment(
            ipcSocketPath: "/tmp/danterm/control.sock",
            paneId: paneId,
            scrollbackFilePath: nil,
            command: ""
        ))
        let restored = Dictionary(uniqueKeysWithValues: restoreLaunchEnvironment(
            ipcSocketPath: "/tmp/danterm/control.sock",
            paneId: paneId,
            scrollbackFilePath: "/owned/replay",
            command: "owned command"
        ))

        #expect(inherited["DANTERM_RESTORE_COMMAND"] == nil)
        #expect(inherited["DANTERM_RESTORE_SCROLLBACK_FILE"] == nil)
        #expect(normal["DANTERM_RESTORE_COMMAND"] == nil)
        #expect(emptyRestore["DANTERM_RESTORE_COMMAND"] == nil)
        #expect(restored["DANTERM_RESTORE_COMMAND"] == "owned command")
        #expect(restored["DANTERM_RESTORE_SCROLLBACK_FILE"] == "/owned/replay")
    }
}
