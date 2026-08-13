// The client end of a DanTerm control conversation, over an abstract byte stream.
// The transport is a protocol so the socket kind is not baked in: the CLI connects
// over AF_UNIX, the phone will connect over TLS to the bridge, and the conversation
// above them is the same one.
import Foundation
import DanTermProtocol

/// One bidirectional byte stream a client conversation runs over. Everything the
/// client protocol needs from a socket, a TLS session, or a test double.
public protocol DanTermClientTransport: AnyObject {
    func send(_ bytes: Data) throws
    /// Blocks until at least one byte arrives, or returns an empty value at EOF.
    func receive() throws -> Data
    func close()
}

/// Every way a client conversation can fail, stated once so a UI never has to read errno.
public enum DanTermClientError: Error, Equatable {
    case transportFailed(String)
    case malformedLine
    case unsupportedProtocol(Int)
    case missingHello
    case serverError(code: Int, message: String)
    case streamEnded(PaneTapeEndReason?)
}

/// Drives the client half of the JSON-RPC line conversation: the hello handshake, one
/// request at a time, and the server-initiated notifications that carry tape records.
/// Reads go through `IpcLineFramer`, the same framer the server side uses, so there is
/// one line-framing implementation for both ends instead of one per client.
public final class DanTermClientSession {
    private let transport: any DanTermClientTransport
    private var framer = IpcLineFramer()
    private var pending: [Data] = []

    public init(transport: any DanTermClientTransport) {
        self.transport = transport
    }

    /// Reads the server's opening `hello` and rejects a protocol version this client
    /// cannot speak, before any request is sent.
    public func handshake() throws {
        guard let line = try nextLine() else { throw DanTermClientError.missingHello }
        guard let request = try? JSONDecoder().decode(JsonRpcRequest.self, from: line),
              request.method == Methods.hello,
              let version = request.params?["protocol"]?.asNumber
        else { throw DanTermClientError.missingHello }
        guard Int(version) == 1 else { throw DanTermClientError.unsupportedProtocol(Int(version)) }
    }

    /// Sends one request and returns the matching result, failing on a JSON-RPC error.
    public func request(method: String, params: JSONValue?) throws -> JSONValue {
        let id = UUID().uuidString
        let request = JsonRpcRequest(id: .string(id), method: method, params: params)
        try transport.send(encodeIpcLine(request))
        while let line = try nextLine() {
            guard let response = try? JSONDecoder().decode(JsonRpcResponse.self, from: line) else {
                continue
            }
            guard response.id == .string(id) else { continue }
            if let error = response.error {
                throw DanTermClientError.serverError(code: error.code, message: error.message)
            }
            return response.result ?? .null
        }
        throw DanTermClientError.transportFailed("connection closed before a reply")
    }

    /// Yields the next server-initiated notification, so a tape subscription can be read
    /// as a stream rather than a request/reply pair.
    public func nextNotification() throws -> (method: String, params: JSONValue?)? {
        while let line = try nextLine() {
            guard let request = try? JSONDecoder().decode(JsonRpcRequest.self, from: line) else {
                continue
            }
            return (request.method, request.params)
        }
        return nil
    }

    public func close() { transport.close() }

    private func nextLine() throws -> Data? {
        while true {
            if pending.isEmpty == false { return pending.removeFirst() }
            let chunk = try transport.receive()
            if chunk.isEmpty { return nil }
            for event in framer.append(chunk) {
                switch event {
                case .line(let line):
                    if line.isEmpty == false { pending.append(line) }
                case .oversized:
                    throw DanTermClientError.malformedLine
                }
            }
        }
    }
}
