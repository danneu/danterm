// Pure coverage for how the CLI judges a reply that never arrived. Correlating a reply to
// its request is the client session's job; only the verdict on a missing one is the CLI's,
// because only the CLI knows which verb was sent.
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermCLI

struct ReplyStreamTests {
    @Test("a reply that arrived is passed through whatever the method was")
    func arrivedReplyIsPassedThrough() throws {
        let reply = JsonRpcResponse(id: .string("R1"), result: .object(["ok": .bool(true)]))

        #expect(try resolveReply(reply, method: .ls)?.result == .object(["ok": .bool(true)]))
        #expect(try resolveReply(reply, method: .quit)?.result == .object(["ok": .bool(true)]))
    }

    @Test("a closed connection is success only for the instance-ending verb")
    func closedConnectionIsSuccessOnlyForQuit() throws {
        // Intent: no reply resolves to "no reply, and that is fine" for quit, and stays an
        //   error for every other method.
        // Why it exists: a successful quit ends the socket it was sent on, so the generic
        //   rule would report the working case as a failure -- and relaxing it for every
        //   verb would hide real dropped connections.
        // Scenario: the daemon sends nothing at all before closing.
        #expect(try resolveReply(nil, method: .quit) == nil)

        let error = #expect(throws: CLIError.self) {
            _ = try resolveReply(nil, method: .ls)
        }
        #expect(error?.message == "DanTerm closed the connection")
    }

    @Test("a refusal reply outlives the closed connection")
    func refusalReplyOutlivesClosedConnection() throws {
        // Intent: a quit the app answered with an error reports that error, even though
        //   the stream ends right behind it.
        // Why it exists: a refused quit must exit non-zero; treating quit's end-of-stream
        //   as success must not swallow a reply that arrived.
        let refusal = JsonRpcResponse(
            id: .string("R1"),
            error: JsonRpcError(code: -32602, message: "quit is limited to launcher slot instances")
        )

        let reply = try resolveReply(refusal, method: .quit)

        #expect(reply?.error?.message == "quit is limited to launcher slot instances")
    }
}
