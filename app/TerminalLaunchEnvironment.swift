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
