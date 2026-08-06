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
    ipcSocketPath: String?,
    paneId: PaneId
) -> [(String, String)] {
    [
        (EnvVars.flag, "1"),
        // A pane's environment is a list of assignments layered over the inherited
        // process environment: it can override a variable but has no way to unset one.
        // Empty is the CLI's explicit fail-closed representation.
        (EnvVars.sock, ipcSocketPath ?? ""),
        (EnvVars.pane, paneId.rawValue.uuidString),
    ]
}

/// Build the environment for restored panes, preserving pane-scoped CLI context
/// and adding the scrollback replay hook when present.
func restoreLaunchEnvironment(
    ipcSocketPath: String?,
    paneId: PaneId,
    scrollbackFilePath: String?,
    command: String?
) -> [(String, String)] {
    var env = terminalLaunchEnvironment(
        ipcSocketPath: ipcSocketPath,
        paneId: paneId
    )
    if let scrollbackFilePath {
        env.append(("DANTERM_RESTORE_SCROLLBACK_FILE", scrollbackFilePath))
    }
    if let command, !command.isEmpty {
        env.append(("DANTERM_RESTORE_COMMAND", command))
    }
    return env
}
