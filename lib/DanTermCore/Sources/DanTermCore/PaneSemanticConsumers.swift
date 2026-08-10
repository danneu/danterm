// Pure read-only projections from one pane's live semantic snapshot.
import Foundation
import DanTermProtocol

/// Encodes every live facet with an explicit discriminator so pane inspection
/// never relies on missing keys to distinguish semantic states.
func paneSemanticInspectionValue(_ state: PaneSemanticState) -> JSONValue {
    let integration: JSONValue = .object([
        "state": .string(state.integration == .ready ? "ready" : "neverReported"),
    ])

    let command: JSONValue
    switch state.command {
    case .idle:
        command = .object(["state": .string("idle")])
    case .running(let text):
        command = .object(["state": .string("running"), "text": .string(text)])
    }

    let connection: JSONValue
    switch state.connection {
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
    switch state.agent {
    case .none:
        agent = .object(["state": .string("none")])
    case .attached(let session, let activity):
        agent = .object([
            "state": .string("attached"),
            "session": .object([
                "kind": .string(session.kind),
                "id": .string(session.sessionId),
            ]),
            "activity": activity.map { .string($0.ipcValue) } ?? .null,
        ])
    }

    return .object([
        "integration": integration,
        "command": command,
        "connection": connection,
        "agent": agent,
    ])
}

/// Adds a pane-owned semantic snapshot to an already-validated pane.info result.
func paneInfoResult(
    adding semantics: PaneSemanticState,
    to base: JSONValue
) -> JSONValue {
    guard case .object(var result) = base,
          case .object(var pane)? = result["pane"]
    else { return base }
    pane["semantics"] = paneSemanticInspectionValue(semantics)
    result["pane"] = .object(pane)
    return .object(result)
}

/// Adds each pane owner's live semantics to an encoded structural ls result.
func paneListResult(
    adding semanticsByPaneId: [PaneId: PaneSemanticState],
    to base: JSONValue
) -> JSONValue {
    func addSemantics(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let values):
            return .array(values.map(addSemantics))
        case .object(var object):
            if case .string(let rawId)? = object["id"],
               let uuid = UUID(uuidString: rawId),
               let semantics = semanticsByPaneId[PaneId(rawValue: uuid)] {
                object["semantics"] = paneSemanticInspectionValue(semantics)
            }
            for (key, child) in object where key != "semantics" {
                object[key] = addSemantics(child)
            }
            return .object(object)
        case .string, .number, .bool, .null:
            return value
        }
    }

    return addSemantics(base)
}

/// Shows a complete running command while it is live, then returns to the
/// ordinary title and cwd label as soon as the command facet becomes idle.
func paneCommandChromeText(
    title: String,
    cwd: String?,
    semantics: PaneSemanticState
) -> String {
    if case .running(let command) = semantics.command {
        return command
    }
    return formatToolbarLabel(title: title, cwd: cwd)
}

private extension AgentActivity {
    var ipcValue: String {
        switch self {
        case .working: "working"
        case .waiting: "waiting"
        case .idle: "idle"
        }
    }
}
