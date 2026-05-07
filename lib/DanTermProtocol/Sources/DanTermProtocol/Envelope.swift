// JSON-RPC 2.0 envelopes shared by the DanTerm app and CLI.
import Foundation

public struct JsonRpcRequest: Codable, Equatable {
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

public struct JsonRpcResponse: Codable, Equatable {
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

public struct JsonRpcError: Codable, Equatable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}
