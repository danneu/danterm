// Pure construction of environment variables injected into newly created panes.
import Foundation
import DanTermProtocol

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
/// and adding one-shot restore-only hints when present.
func restoreLaunchEnvironment(
    ipcSocketPath: String,
    paneId: PaneId,
    token: String,
    scrollbackFilePath: String?,
    agentRecoveryMessage: String?
) -> [(String, String)] {
    var env = terminalLaunchEnvironment(
        ipcSocketPath: ipcSocketPath,
        paneId: paneId,
        token: token
    )
    if let scrollbackFilePath {
        env.append(("DANTERM_RESTORE_SCROLLBACK_FILE", scrollbackFilePath))
    }
    if let agentRecoveryMessage {
        env.append((EnvVars.agentRecovery, agentRecoveryMessage))
    }
    return env
}
