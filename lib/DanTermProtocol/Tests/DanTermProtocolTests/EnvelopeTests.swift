// Tests for DanTerm JSON-RPC envelope and JSONValue encoding.
import Foundation
import XCTest
@testable import DanTermProtocol

final class EnvelopeTests: XCTestCase {
    func testObjectParamsRoundTrip() throws {
        let request = JsonRpcRequest(
            id: .number(1),
            method: Methods.tabTitle,
            params: .object([
                "b": .array([.number(2), .number(3)]),
                "a": .number(1),
            ])
        )

        let encoded = try sortedEncoder().encode(request)
        XCTAssertEqual(
            String(data: encoded, encoding: .utf8),
            #"{"id":1,"jsonrpc":"2.0","method":"tab.title","params":{"a":1,"b":[2,3]}}"#
        )
        let decoded = try JSONDecoder().decode(JsonRpcRequest.self, from: encoded)
        XCTAssertEqual(decoded, request)
    }

    func testNotificationRequestRoundTripsWithoutId() throws {
        let request = JsonRpcRequest(method: Methods.hello, params: .object(["protocol": .number(1)]))
        let encoded = try sortedEncoder().encode(request)
        XCTAssertEqual(
            String(data: encoded, encoding: .utf8),
            #"{"jsonrpc":"2.0","method":"hello","params":{"protocol":1}}"#
        )
        let decoded = try JSONDecoder().decode(JsonRpcRequest.self, from: encoded)
        XCTAssertEqual(decoded, request)
    }

    func testErrorResponseWithDataRoundTrips() throws {
        let response = JsonRpcResponse(
            id: .string("abc"),
            error: JsonRpcError(
                code: -32602,
                message: "invalid params",
                data: .object(["field": .string("paneId")])
            )
        )

        let encoded = try sortedEncoder().encode(response)
        let decoded = try JSONDecoder().decode(JsonRpcResponse.self, from: encoded)
        XCTAssertEqual(decoded, response)
    }

    func testRequestContextDecodesFromParams() throws {
        let request = JsonRpcRequest(
            id: .string("1"),
            method: Methods.todoList,
            params: .object([
                IpcRequestContext.paramsKey: .object([
                    "paneId": .string("pane-1"),
                    "tabId": .string("tab-1"),
                ]),
            ])
        )

        let encoded = try sortedEncoder().encode(request)
        let decoded = try JSONDecoder().decode(JsonRpcRequest.self, from: encoded)
        XCTAssertEqual(IpcRequestContext.from(params: decoded.params), IpcRequestContext(paneId: "pane-1", tabId: "tab-1"))
    }

    func testJSONValueDoesNotEncodeObjectAsBase64Data() throws {
        let value = JSONValue.object(["x": .number(1)])
        let encoded = try sortedEncoder().encode(value)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), #"{"x":1}"#)
    }

    private func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
