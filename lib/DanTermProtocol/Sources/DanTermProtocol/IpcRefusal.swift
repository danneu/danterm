// Stable connection- and request-refusal shapes shared by IPC servers and clients.
import Foundation

/// Names why a server refused a connection before it promised service with a hello.
public enum IpcConnectionRejectionReason: String, Codable, CaseIterable, Sendable {
    /// The resolved tailnet node id is absent from the server's admitted set.
    case notAdmitted = "not-admitted"
    /// The server could not resolve the peer address to a tailnet identity.
    case identityUnresolved = "identity-unresolved"
    /// The server has no connection slot available.
    case connectionLimit = "connection-limit"
    /// The server cannot write the audit record required before remote service.
    case auditUnavailable = "audit-unavailable"

    /// Builds the server-first notification that replaces hello on a refused connection.
    ///
    /// A capacity refusal carries the server's current silence bound, and no other
    /// refusal does. That number is the deadline by which this server has provably
    /// reclaimed a dead peer's slot, so it is the earliest a retry can help -- and only
    /// the refusing server knows today's value. The remaining refusals name conditions
    /// the bound does not govern, so carrying it there would invite a pointless wait.
    public func notification(livenessBound: IpcLivenessBound) -> JsonRpcRequest {
        var params: [String: JSONValue] = ["reason": .string(rawValue)]
        if self == .connectionLimit {
            params[IpcLivenessBound.wireKey] = livenessBound.wireValue
        }
        return JsonRpcRequest(method: Methods.rejected, params: .object(params))
    }

    /// Reads a connection refusal without treating an unknown notification as one.
    public init?(notification: JsonRpcRequest) {
        guard notification.id == nil,
              notification.method == Methods.rejected,
              let rawValue = notification.params?["reason"]?.asString
        else { return nil }
        self.init(rawValue: rawValue)
    }
}

/// Holds application-defined JSON-RPC errors that must remain stable across server paths.
public enum IpcRequestErrors {
    /// Refuses a remote request whose write-ahead audit record could not be appended.
    public static var auditUnavailable: JsonRpcError {
        JsonRpcError(
            code: -32001,
            message: "audit unavailable",
            data: .object(["reason": .string(IpcConnectionRejectionReason.auditUnavailable.rawValue)])
        )
    }
}
