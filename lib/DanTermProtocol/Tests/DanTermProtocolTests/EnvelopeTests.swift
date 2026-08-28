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
        let notification = IpcConnectionRejectionReason.notAdmitted.notification(
            livenessBound: .standard
        )

        let encoded = try sortedEncoder().encode(notification)

        #expect(
            String(data: encoded, encoding: .utf8)
                == #"{"jsonrpc":"2.0","method":"rejected","params":{"reason":"not-admitted"}}"#
        )
        #expect(IpcConnectionRejectionReason(notification: notification) == .notAdmitted)
        let capacity = try sortedEncoder().encode(
            IpcConnectionRejectionReason.connectionLimit.notification(livenessBound: .standard)
        )
        #expect(
            String(data: capacity, encoding: .utf8)
                == #"{"jsonrpc":"2.0","method":"rejected","params":{"reason":"connection-limit","silenceSeconds":30}}"#
        )
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
                )
            ),
            id: .string("1")
        )

        let encoded = try sortedEncoder().encode(request)
        let decoded = try JSONDecoder().decode(JsonRpcRequest.self, from: encoded)
        #expect(decoded == request)
        #expect(String(decoding: encoded, as: UTF8.self).contains("_ctx") == false)
    }

    // Intent: a typed payload written through the envelope reaches the wire as the same line
    // the JSONValue-built envelope produces, and reads back as the JSONValue envelope.
    // Why it exists: the producer encodes typed values once at `encodeIpcLine` while every
    // reader still decodes into `JSONValue`. If the generic and the JSONValue instantiations
    // could disagree about `jsonrpc`, `id`, or an omitted payload, one encode pass would
    // change the wire.
    // Scenario: one notification carrying a typed params value, and one response carrying a
    // typed result value, both read back with the reader's own envelope type.
    @Test("typed payload envelopes decode as the JSONValue envelopes")
    func typedPayloadEnvelopesDecodeAsJSONValueEnvelopes() throws {
        let typedRequest = JsonRpcRequestEnvelope(
            id: .number(7),
            method: "probe",
            params: EnvelopePayloadProbe(name: "pane", count: 3)
        )
        let decodedRequest = try JSONDecoder().decode(
            JsonRpcRequest.self,
            from: try encodeIpcLine(typedRequest)
        )
        #expect(decodedRequest == JsonRpcRequest(
            id: .number(7),
            method: "probe",
            params: .object(["name": .string("pane"), "count": .number(3)])
        ))

        let typedResponse = JsonRpcResponseEnvelope(
            id: .string("abc"),
            result: EnvelopePayloadProbe(name: "tape", count: 0)
        )
        let decodedResponse = try JSONDecoder().decode(
            JsonRpcResponse.self,
            from: try encodeIpcLine(typedResponse)
        )
        #expect(decodedResponse == JsonRpcResponse(
            id: .string("abc"),
            result: .object(["name": .string("tape"), "count": .number(0)])
        ))
    }

    // Intent: an envelope with no payload omits the key rather than stating null, whichever
    // payload type it was instantiated with.
    @Test("payload-free typed envelopes omit their payload key")
    func payloadFreeTypedEnvelopesOmitTheirPayloadKey() throws {
        let request = JsonRpcRequestEnvelope<EnvelopePayloadProbe>(method: "probe")
        #expect(
            String(decoding: try sortedEncoder().encode(request), as: UTF8.self)
                == #"{"jsonrpc":"2.0","method":"probe"}"#
        )

        let response = JsonRpcResponseEnvelope<EnvelopePayloadProbe>(
            id: .null,
            error: JsonRpcError(code: -1, message: "no")
        )
        #expect(
            String(decoding: try sortedEncoder().encode(response), as: UTF8.self)
                == #"{"error":{"code":-1,"message":"no"},"id":null,"jsonrpc":"2.0"}"#
        )
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

/// A stand-in for any typed payload a producer hands the envelope, so the envelope's own
/// behavior is tested without a real payload's vocabulary in the way.
private struct EnvelopePayloadProbe: Encodable {
    let name: String
    let count: Int
}
