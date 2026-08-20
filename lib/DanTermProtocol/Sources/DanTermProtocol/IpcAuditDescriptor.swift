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
        let target = Dictionary(uniqueKeysWithValues: targetEntries.map { entry in
            (entry.key, entry.auditValue)
        })
        let launch: LaunchSpec?
        let input: IpcAuditInputAccounting?
        switch self {
        case .tabNew(_, let value, _), .paneSplit(_, let value, _):
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
}
