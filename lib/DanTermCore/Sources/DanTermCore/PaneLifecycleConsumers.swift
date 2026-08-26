// Pure read-only projections from one terminal session's lifecycle state.
import Foundation
import DanTermProtocol

/// Gives every PTY rejection a stable external discriminator for pane inspection.
func inputSubmissionFailureReason(_ failure: InputSubmissionFailure) -> String {
    switch failure {
    case .bufferLimitExceeded: "bufferLimitExceeded"
    case .canonicalModeTimeout: "canonicalModeTimeout"
    case .launchFailed: "launchFailed"
    case .processEnded: "processEnded"
    case .writeFailed: "writeFailed"
    }
}

/// Turns a typed PTY rejection into the actionable error returned by `pane input`.
func inputSubmissionFailureMessage(_ failure: InputSubmissionFailure) -> String {
    switch failure {
    case .bufferLimitExceeded:
        "pane input exceeded the 8 MiB pending-input limit"
    case .canonicalModeTimeout:
        "pane input timed out waiting for the tty to leave canonical mode"
    case .launchFailed:
        "pane input was not delivered because the pane process failed to launch"
    case .processEnded:
        "pane input was not delivered because the pane process ended"
    case .writeFailed(let code):
        "pane input failed to write to the PTY (errno \(code))"
    }
}

/// Encodes every lifecycle with an explicit discriminator so pane inspection
/// never relies on missing keys to distinguish current states.
func paneLifecycleInspectionFields(_ session: SessionModel?) -> [String: JSONValue] {
    let integration: JSONValue = .object([
        "state": .string(session?.integration == .ready ? "ready" : "neverReported"),
    ])

    let command: JSONValue
    switch session?.command ?? .idle {
    case .idle:
        command = .object(["state": .string("idle")])
    case .running(let text):
        command = .object(["state": .string("running"), "text": .string(text)])
    }

    let connection: JSONValue
    switch session?.connection ?? .local {
    case .local:
        connection = .object(["state": .string("local")])
    case .remote(let identity):
        connection = .object([
            "state": .string("remote"),
            "identity": identity.map { session in
                .object(["user": .string(session.user), "host": .string(session.host)])
            } ?? .null,
        ])
    }

    let agent: JSONValue
    switch session?.agent ?? .none {
    case .none:
        agent = .object(["state": .string("none")])
    case .attached(let session, let activity):
        agent = .object([
            "state": .string("attached"),
            "session": .object([
                "kind": .string(session.kind),
                "sessionId": .string(session.sessionId),
            ]),
            "activity": activity.map { .string($0.reported.ipcValue) } ?? .null,
        ])
    }

    return [
        "integration": integration,
        "command": command,
        "connection": connection,
        "agent": agent,
    ]
}

/// Joins a pane's claimed title and cwd into the one label the toolbar and
/// window chrome show. Lives here, beside its only caller, rather than in the
/// core's shared-helper run, which is for feeders the runtime reads too.
///
/// `title` is what the pane *claims* (see `paneClaimedTitle`), not what it
/// resolves to, so a pane that claims nothing shows its cwd once, not twice.
func formatToolbarLabel(title: String?, cwd: String?) -> String {
    guard let cwd else { return title ?? placeholderPaneTitle }
    let shortCwd = abbreviateHome(cwd)
    guard let title, title != cwd else { return shortCwd }
    return "\(title) \u{2013} \(shortCwd)"
}

/// Shows a complete running command while it is live, then returns to the
/// ordinary title and cwd label as soon as the command lifecycle becomes idle.
func paneCommandChromeText(
    title: String?,
    cwd: String?,
    command: String?
) -> String {
    if let command {
        return command
    }
    return formatToolbarLabel(title: title, cwd: cwd)
}
