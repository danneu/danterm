// The client half of the DanTerm control conversation: the hello handshake, line
// framing, request/reply correlation, and notification delivery.
//
// This is the one implementation of that conversation. It reads through
// `IpcLineFramer`, the same framer the server side uses, so neither end has a framing
// copy of its own. What does not belong here: how a byte stream is opened (see
// ClientTransport.swift), and what any particular reply means (the caller's problem).
import Foundation
import DanTermProtocol

/// One frame off the wire, already classified. A reply the caller is not waiting for and
/// a notification are both real frames, so both are delivered rather than discarded.
public enum DanTermClientFrame: Equatable {
    case response(JsonRpcResponse)
    case notification(method: String, params: JSONValue?)
}

/// Every way the conversation itself can fail, stated once so a caller never reads errno
/// or re-derives the handshake rules. Transport failures are not in here: they come from
/// the transport and pass through untouched.
public enum DanTermClientError: Error, Equatable {
    /// The peer closed the stream before sending its opening hello.
    case closedBeforeHello
    /// The first line arrived but was not a hello this client can read.
    case invalidHello
    /// The tailnet node id is not in the server's admitted set.
    case notAdmitted
    /// The server could not resolve the connection to a tailnet identity.
    case identityUnresolved
    /// The server has no connection slot available.
    case connectionLimit
    /// The server cannot provide the durable audit record required for remote service.
    case auditUnavailable
    /// The server spoke a protocol version this client cannot use.
    case unsupportedProtocol(Int)
    /// A line exceeded the framer's limit, so the stream can no longer be trusted.
    case oversizedLine
}

/// Identifies the server build after protocol compatibility has been established.
public struct DanTermServerHello: Equatable, Sendable {
    /// The app version is advisory, so callers can warn about skew without refusing it.
    public let appVersion: String
}

/// Drives a DanTerm control conversation over one transport.
///
/// The correlation rule is the reason this type exists rather than a read loop at each
/// call site: while a request awaits its reply, notifications and replies to other
/// requests keep arriving, and every one of them is a frame the caller may still want.
/// They are deferred in arrival order instead of being discarded, so awaiting a reply
/// never loses a tape record that overtook it.
public final class DanTermClientSession {
    /// The protocol version this client speaks. A hello naming any other version is
    /// refused before a request is sent.
    public static let supportedProtocolVersion = 1

    private let transport: any DanTermClientTransport
    private var framer = IpcLineFramer()
    /// Whole lines already framed out of a received chunk, not yet classified.
    private var unread: [Data] = []
    /// Frames read while looking for something else, in the order they arrived.
    private var deferred: [DanTermClientFrame] = []

    public init(transport: any DanTermClientTransport) {
        self.transport = transport
    }

    /// Reads the peer's opening hello and refuses a protocol version this client cannot
    /// speak. Call this before sending anything.
    @discardableResult
    public func handshake() throws -> DanTermServerHello {
        guard let line = try nextLine() else { throw DanTermClientError.closedBeforeHello }
        guard let notification = try? JSONDecoder().decode(JsonRpcRequest.self, from: line) else {
            throw DanTermClientError.invalidHello
        }
        if let rejection = IpcConnectionRejectionReason(notification: notification) {
            throw Self.clientError(for: rejection)
        }
        guard notification.method == Methods.hello,
              let versionNumber = notification.params?["protocol"]?.asNumber,
              let version = Int(exactly: versionNumber),
              let appVersion = notification.params?["app"]?.asString
        else { throw DanTermClientError.invalidHello }
        guard version == Self.supportedProtocolVersion else {
            throw DanTermClientError.unsupportedProtocol(version)
        }
        return DanTermServerHello(appVersion: appVersion)
    }

    /// Writes one request. Correlating its reply is a separate step, so a caller may have
    /// more than one request outstanding.
    public func send(_ request: JsonRpcRequest) throws {
        try transport.send(encodeIpcLine(request))
    }

    /// Returns the reply to `id`, or nil if the peer closed the stream without sending it.
    ///
    /// Nil is not always a failure: a request that ends the instance takes the stream down
    /// with it, so only the caller knows whether a missing reply is the expected outcome.
    public func awaitReply(id: JSONValue) throws -> JsonRpcResponse? {
        if let index = deferred.firstIndex(where: { frame in
            if case .response(let response) = frame { return response.id == id }
            return false
        }) {
            guard case .response(let response) = deferred.remove(at: index) else { return nil }
            return response
        }
        while let frame = try readFrame() {
            if case .response(let response) = frame, response.id == id { return response }
            deferred.append(frame)
        }
        return nil
    }

    /// Returns the next server-initiated notification, so a subscription reads as a stream
    /// rather than as a series of replies. Returns nil at end of stream.
    public func nextNotification() throws -> (method: String, params: JSONValue?)? {
        if let index = deferred.firstIndex(where: { frame in
            if case .notification = frame { return true }
            return false
        }) {
            guard case .notification(let method, let params) = deferred.remove(at: index) else {
                return nil
            }
            return (method, params)
        }
        while let frame = try readFrame() {
            if case .notification(let method, let params) = frame { return (method, params) }
            deferred.append(frame)
        }
        return nil
    }

    /// Returns the next frame of any kind, oldest deferred frame first. This is what makes
    /// "no frame is dropped" observable: a reply nobody awaited is still here afterwards.
    public func nextFrame() throws -> DanTermClientFrame? {
        if deferred.isEmpty == false { return deferred.removeFirst() }
        return try readFrame()
    }

    public func close() { transport.close() }

    private static func clientError(
        for rejection: IpcConnectionRejectionReason
    ) -> DanTermClientError {
        switch rejection {
        case .notAdmitted: .notAdmitted
        case .identityUnresolved: .identityUnresolved
        case .connectionLimit: .connectionLimit
        case .auditUnavailable: .auditUnavailable
        }
    }

    /// Classifies one line. A frame carrying an id is a reply; anything else with a method
    /// is a notification. A line that is neither is skipped rather than failing the stream,
    /// because a peer that gained a frame kind must not break a client that predates it.
    private func readFrame() throws -> DanTermClientFrame? {
        while let line = try nextLine() {
            if let response = try? JSONDecoder().decode(JsonRpcResponse.self, from: line),
               response.id != nil,
               response.id != .null {
                return .response(response)
            }
            if let request = try? JSONDecoder().decode(JsonRpcRequest.self, from: line) {
                return .notification(method: request.method, params: request.params)
            }
        }
        return nil
    }

    private func nextLine() throws -> Data? {
        while true {
            if unread.isEmpty == false { return unread.removeFirst() }
            let chunk = try transport.receive()
            if chunk.isEmpty { return nil }
            for event in framer.append(chunk) {
                switch event {
                case .line(let line):
                    if line.isEmpty == false { unread.append(line) }
                case .oversized:
                    throw DanTermClientError.oversizedLine
                }
            }
        }
    }
}
