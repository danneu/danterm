// JSON-RPC 2.0 envelopes shared by the DanTerm app and CLI.
import Foundation

/// The request envelope, generic over what rides in `params`.
///
/// The payload is a type parameter so a producer can hand a typed value straight to the
/// encoder and pay one JSON pass, while every reader keeps decoding into `JSONValue`. One
/// declaration serves both: a second outgoing-only struct would restate `jsonrpc`, `id`, and
/// `method`, and the two spellings could drift.
public struct JsonRpcRequestEnvelope<Params> {
    public var jsonrpc: String
    public var id: JSONValue?
    public var method: String
    public var params: Params?

    public init(
        jsonrpc: String = "2.0",
        id: JSONValue? = nil,
        method: String,
        params: Params? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

extension JsonRpcRequestEnvelope: Encodable where Params: Encodable {}
extension JsonRpcRequestEnvelope: Decodable where Params: Decodable {}
extension JsonRpcRequestEnvelope: Equatable where Params: Equatable {}
extension JsonRpcRequestEnvelope: Sendable where Params: Sendable {}

/// The response envelope, generic over what rides in `result`, for the same reason as
/// `JsonRpcRequestEnvelope`.
public struct JsonRpcResponseEnvelope<Payload> {
    public var jsonrpc: String
    public var id: JSONValue?
    public var result: Payload?
    public var error: JsonRpcError?

    public init(
        jsonrpc: String = "2.0",
        id: JSONValue?,
        result: Payload? = nil,
        error: JsonRpcError? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }
}

extension JsonRpcResponseEnvelope: Encodable where Payload: Encodable {}
extension JsonRpcResponseEnvelope: Decodable where Payload: Decodable {}
extension JsonRpcResponseEnvelope: Equatable where Payload: Equatable {}
extension JsonRpcResponseEnvelope: Sendable where Payload: Sendable {}

/// The envelope every reader decodes into: the payload stays JSON until something that owns
/// its vocabulary lifts it.
public typealias JsonRpcRequest = JsonRpcRequestEnvelope<JSONValue>
/// The response counterpart of `JsonRpcRequest`.
public typealias JsonRpcResponse = JsonRpcResponseEnvelope<JSONValue>

public struct JsonRpcError: Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// Builds the exact request envelope for a parsed CLI command without adding process context.
public func makeCLIRequest(_ command: CLICommand, id: JSONValue) -> JsonRpcRequest {
    JsonRpcRequest(
        id: id,
        method: command.method,
        params: .object(command.params)
    )
}

/// Encodes one transport line without doubling base64 slash bytes inside large replies.
public func encodeIpcLine<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    var line = try encoder.encode(value)
    line.append(0x0A)
    return line
}
