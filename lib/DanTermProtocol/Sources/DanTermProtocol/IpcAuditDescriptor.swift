// Pure audit projection for IPC requests. It retains exercised authority while
// excluding terminal content and input details before any filesystem code sees them.
import Foundation

/// Records input quantity without retaining text, key names, or encoded PTY bytes.
public enum IpcAuditInputAccounting: Codable, Equatable, Sendable {
    /// Counts the UTF-8 bytes supplied through the paste-style text form.
    case textBytes(Int)
    /// Counts the intent events supplied through the structured input form.
    case eventCount(Int)

    private enum CodingKeys: String, CodingKey {
        case textBytes
        case eventCount
    }

    /// Decodes the explicit accounting vocabulary used by durable audit entries.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch (container.contains(.textBytes), container.contains(.eventCount)) {
        case (true, false):
            self = .textBytes(try container.decode(Int.self, forKey: .textBytes))
        case (false, true):
            self = .eventCount(try container.decode(Int.self, forKey: .eventCount))
        default:
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Input accounting must contain exactly one accounting key"
                )
            )
        }
    }

    /// Encodes one stable key instead of exposing Swift's associated-value representation.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .textBytes(let count):
            try container.encode(count, forKey: .textBytes)
        case .eventCount(let count):
            try container.encode(count, forKey: .eventCount)
        }
    }
}

/// Carries only the request facts that the durable audit log is permitted to retain.
public struct IpcAuditRequestDescriptor: Codable, Equatable, Sendable {
    /// Names the authority exercised by the request.
    public let method: String
    /// Names target entities without retaining response or pane content.
    public let target: [String: String]
    /// Retains a launch command because it is authority exercised by the caller.
    public let command: String?
    /// Retains a launch working directory because it is authority exercised by the caller.
    public let cwd: String?
    /// Accounts for input without retaining its content.
    public let input: IpcAuditInputAccounting?

}

public extension IpcRequest {
    /// Projects this request into the sole content shape admitted to the audit writer.
    var auditDescriptor: IpcAuditRequestDescriptor {
        let target = auditTarget
        let launch: LaunchSpec?
        let input: IpcAuditInputAccounting?
        switch self {
        case .tabNew(_, let value, _), .paneSplit(_, _, let value, _):
            launch = value
        default:
            launch = nil
        }
        switch self {
        case .paneInput(_, .text(let text)):
            input = .textBytes(text.utf8.count)
        case .paneInput(_, .events(let events)):
            input = .eventCount(events.count)
        default:
            input = nil
        }
        return IpcAuditRequestDescriptor(
            method: method.rawValue,
            target: target,
            command: launch?.cmd,
            cwd: launch?.cwd,
            input: input
        )
    }

    private var auditTarget: [String: String] {
        switch self {
        case .ping, .doctorPermissions, .ls, .focusInfo, .roster, .quit, .groupNew:
            return [:]
        case .groupRename(let group, _), .groupClose(let group, _):
            return ["group": auditId(group)]
        case .tabNew(let target, _, _):
            switch target {
            case .group(let group, _): return ["group": auditId(group)]
            case .afterTab(let tab): return ["afterTabId": auditId(tab)]
            }
        case .tabRename(let tab, _), .tabClose(let tab):
            return ["tab": auditId(tab)]
        case .paneFocus(let pane), .paneInfo(let pane), .paneClose(let pane),
             .paneInput(let pane, _), .paneRead(let pane, _), .paneRows(let pane),
             .paneZoom(let pane, _), .paneResize(let pane, _),
             .paneTape(let pane, _, _, _),
             .paneSnapshot(let pane), .themeSet(let pane, _),
             .agentAttach(let pane, _), .agentActivity(let pane, _, _),
             .agentDetach(let pane, _):
            return ["pane": auditId(pane)]
        case .paneSplit(let pane, _, _, _):
            return ["pane": auditId(pane)]
        case .todoList(let owner), .todoAdd(let owner, _),
             .todoClearCompleted(let owner):
            return auditOwner(owner)
        case .todoEdit(let owner, let todoId, _), .todoDone(let owner, let todoId),
             .todoOpen(let owner, let todoId), .todoDelete(let owner, let todoId):
            return auditOwner(owner).merging(["todoId": auditId(todoId)]) { _, new in new }
        }
    }
}

private func auditId<Tag>(_ id: TypedId<Tag>) -> String {
    id.rawValue.uuidString.lowercased()
}

private func auditOwner(_ owner: TodoOwner) -> [String: String] {
    switch owner {
    case .pane(let pane): return ["pane": auditId(pane)]
    case .tab(let tab): return ["tab": auditId(tab)]
    }
}
