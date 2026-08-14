// Tests for DanTerm JSON-RPC envelope and JSONValue encoding.
import Foundation
import Testing
@testable import DanTermProtocol

struct EnvelopeTests {
    @Test("object params round trip")
    func objectParamsRoundTrip() throws {
        let request = JsonRpcRequest(
            id: .number(1),
            method: IpcRequestMethod.tabRename.rawValue,
            params: .object([
                "b": .array([.number(2), .number(3)]),
                "a": .number(1),
            ])
        )

        let encoded = try sortedEncoder().encode(request)
        #expect(String(data: encoded, encoding: .utf8) == #"{"id":1,"jsonrpc":"2.0","method":"tab.rename","params":{"a":1,"b":[2,3]}}"#)
        let decoded = try JSONDecoder().decode(JsonRpcRequest.self, from: encoded)
        #expect(decoded == request)
    }

    @Test("notification request round trips without id")
    func notificationRequestRoundTripsWithoutId() throws {
        let request = JsonRpcRequest(method: Methods.hello, params: .object(["protocol": .number(1)]))
        let encoded = try sortedEncoder().encode(request)
        #expect(String(data: encoded, encoding: .utf8) == #"{"jsonrpc":"2.0","method":"hello","params":{"protocol":1}}"#)
        let decoded = try JSONDecoder().decode(JsonRpcRequest.self, from: encoded)
        #expect(decoded == request)
    }

    @Test("connection rejection notification has the stable wire shape")
    func connectionRejectionNotificationEncodes() throws {
        let notification = IpcConnectionRejectionReason.notAdmitted.notification

        let encoded = try sortedEncoder().encode(notification)

        #expect(
            String(data: encoded, encoding: .utf8)
                == #"{"jsonrpc":"2.0","method":"rejected","params":{"reason":"not-admitted"}}"#
        )
        #expect(IpcConnectionRejectionReason(notification: notification) == .notAdmitted)
        #expect(IpcConnectionRejectionReason.allCases.map(\.rawValue) == [
            "not-admitted",
            "identity-unresolved",
            "connection-limit",
            "audit-unavailable",
        ])
    }

    @Test("request audit refusal has a stable JSON-RPC error shape")
    func requestAuditRefusalShape() {
        #expect(IpcRequestErrors.auditUnavailable == JsonRpcError(
            code: -32001,
            message: "audit unavailable",
            data: .object(["reason": .string("audit-unavailable")])
        ))
    }

    @Test("error response with data round trips")
    func errorResponseWithDataRoundTrips() throws {
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
        #expect(decoded == response)
    }

    @Test("request round trip carries only explicit method params")
    func requestRoundTripCarriesOnlyExplicitMethodParams() throws {
        let request = makeCLIRequest(
            CLICommand(
                request: .todoList(
                    owner: .pane(PaneId(
                        rawValue: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
                    ))
                ),
                outputMode: .json
            ),
            id: .string("1")
        )

        let encoded = try sortedEncoder().encode(request)
        let decoded = try JSONDecoder().decode(JsonRpcRequest.self, from: encoded)
        #expect(decoded == request)
        #expect(String(decoding: encoded, as: UTF8.self).contains("_ctx") == false)
    }

    @Test("JSON value does not encode object as base64 data")
    func jSONValueDoesNotEncodeObjectAsBase64Data() throws {
        let value = JSONValue.object(["x": .number(1)])
        let encoded = try sortedEncoder().encode(value)
        #expect(String(data: encoded, encoding: .utf8) == #"{"x":1}"#)
    }

    private func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
