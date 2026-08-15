// JSON-RPC 2.0 envelopes shared by the DanTerm app and CLI.
import Foundation

public struct JsonRpcRequest: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JSONValue?
    public var method: String
    public var params: JSONValue?

    public init(
        jsonrpc: String = "2.0",
        id: JSONValue? = nil,
        method: String,
        params: JSONValue? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JsonRpcResponse: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JSONValue?
    public var result: JSONValue?
    public var error: JsonRpcError?

    public init(
        jsonrpc: String = "2.0",
        id: JSONValue?,
        result: JSONValue? = nil,
        error: JsonRpcError? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }
}

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
