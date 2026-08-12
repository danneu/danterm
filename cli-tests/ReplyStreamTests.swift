// Pure coverage for how the CLI resolves a reply stream that ends before, or
// instead of, a reply. The socket transport stays in main.swift; only the
// end-of-stream policy is exercised here.
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermCLI

struct ReplyStreamTests {
    private let requestId = "58f6f1c8-0f30-4a4f-9dd8-0b0f5a0f0f01"

    @Test("a matching reply ends the read loop")
    func matchingReplyEndsTheLoop() throws {
        var lines = [
            try line(id: "other-request", result: .object(["ok": .bool(false)])),
            try line(id: requestId, result: .object(["ok": .bool(true)])),
        ]

        let reply = try awaitReply(requestId: requestId, method: .ls) {
            lines.isEmpty ? nil : lines.removeFirst()
        }

        #expect(reply?.result == .object(["ok": .bool(true)]))
    }

    @Test("a closed connection is success only for the instance-ending verb")
    func closedConnectionIsSuccessOnlyForQuit() throws {
        // Intent: end-of-stream resolves to "no reply, and that is fine" for
        //   quit, and stays an error for every other method.
        // Why it exists: a successful quit ends the socket it was sent on, so
        //   the generic loop would report the working case as a failure -- and
        //   relaxing it for every verb would hide real dropped connections.
        // Scenario: the daemon sends nothing at all before closing.
        #expect(try awaitReply(requestId: requestId, method: .quit) { nil } == nil)

        let error = #expect(throws: CLIError.self) {
            _ = try awaitReply(requestId: requestId, method: .ls) { nil }
        }
        #expect(error?.message == "DanTerm closed the connection")
    }

    @Test("a refusal reply outlives the closed connection")
    func refusalReplyOutlivesClosedConnection() throws {
        // Intent: a quit the app answered with an error reports that error,
        //   even though the stream ends right behind it.
        // Why it exists: a refused quit must exit non-zero; treating quit's
        //   end-of-stream as success must not swallow a reply that arrived.
        var lines = [try line(id: requestId, error: "quit is limited to launcher slot instances")]

        let reply = try awaitReply(requestId: requestId, method: .quit) {
            lines.isEmpty ? nil : lines.removeFirst()
        }

        #expect(reply?.error?.message == "quit is limited to launcher slot instances")
    }

    private func line(id: String, result: JSONValue) throws -> String {
        try encoded(JsonRpcResponse(id: .string(id), result: result))
    }

    private func line(id: String, error message: String) throws -> String {
        try encoded(JsonRpcResponse(id: .string(id), error: JsonRpcError(code: -32602, message: message)))
    }

    private func encoded(_ response: JsonRpcResponse) throws -> String {
        let data = try JSONEncoder().encode(response)
        return try #require(String(data: data, encoding: .utf8))
    }
}
