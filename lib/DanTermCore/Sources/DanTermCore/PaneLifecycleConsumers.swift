// Pure read-only projections from one terminal session's lifecycle state.
import Foundation
import DanTermProtocol

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
            "activity": activity.map { .string($0.ipcValue) } ?? .null,
        ])
    }

    return [
        "integration": integration,
        "command": command,
        "connection": connection,
        "agent": agent,
    ]
}

/// Shows a complete running command while it is live, then returns to the
/// ordinary title and cwd label as soon as the command lifecycle becomes idle.
func paneCommandChromeText(
    title: String,
    cwd: String?,
    command: String?
) -> String {
    if let command {
        return command
    }
    return formatToolbarLabel(title: title, cwd: cwd)
}
