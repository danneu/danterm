// Pure construction of environment variables injected into newly created panes.
import Foundation
import DanTermProtocol

let reservedRestoreEnvironmentVariableNames = [
    "DANTERM_RESTORE_COMMAND",
    "DANTERM_RESTORE_SCROLLBACK_FILE",
]

/// Removes pane-scoped restore values before inherited process environment is used.
func scrubbedTerminalProcessEnvironment(
    _ environment: [String: String]
) -> [String: String] {
    environment.filter { !reservedRestoreEnvironmentVariableNames.contains($0.key) }
}

func terminalLaunchEnvironment(
    ipcSocketPath: String,
    paneId: PaneId,
    token: String
) -> [(String, String)] {
    [
        (EnvVars.flag, "1"),
        (EnvVars.sock, ipcSocketPath),
        (EnvVars.pane, paneId.rawValue.uuidString),
        ("DANTERM_TOKEN", token),
    ]
}

/// Build the environment for restored panes, preserving pane-scoped CLI context
/// and adding the scrollback replay hook when present.
func restoreLaunchEnvironment(
    ipcSocketPath: String,
    paneId: PaneId,
    token: String,
    scrollbackFilePath: String?,
    command: String?
) -> [(String, String)] {
    var env = terminalLaunchEnvironment(
        ipcSocketPath: ipcSocketPath,
        paneId: paneId,
        token: token
    )
    if let scrollbackFilePath {
        env.append(("DANTERM_RESTORE_SCROLLBACK_FILE", scrollbackFilePath))
    }
    if let command, !command.isEmpty {
        env.append(("DANTERM_RESTORE_COMMAND", command))
    }
    return env
}
