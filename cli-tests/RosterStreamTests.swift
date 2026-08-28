// Socket-and-pipe coverage for the CLI's followed pane-roster renderer.
//
// A roster subscription's whole value is that a change reaches the consumer without a
// poll, so every case here feeds the session one frame at a time through a real socket
// and reads the output pipe between frames. The fixtures are shared with the pane-tape
// suite; see StreamFixtures.swift.
import Foundation
import Testing
import DanTermClient
import DanTermProtocol
import Darwin
@testable import DanTermCLI

@Suite(.timeLimit(.minutes(1)))
struct RosterStreamTests {
    @Test("the renderer flushes the reply and each later roster as it arrives")
    func rendererWritesEachRosterAsItArrives() throws {
        // Intent: the reply roster and every `roster.event` roster reach stdout as whole
        //   lines, in order, before the next frame is written.
        // Why it exists: an agent watches this stream instead of polling `ls`. Any
        //   buffering would hold a pane's appearance back until the next one happened,
        //   which is the missed transition the command exists to close.
        // Scenario: an agent follows the roster, then someone splits a pane and closes it.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        let completion = StreamCompletionProbe<Void>()
        // The peer is closed in the body, not here: a roster stream has no terminator, so
        // EOF is the only thing that can end it, and closing the same descriptor twice
        // would let an unrelated fd reused in between be closed by the second call.
        defer { Darwin.close(output.read) }

        runOnItsOwnThread {
            do {
                completion.finish(try renderRosterStream(
                    session: streamSession(socket.connection),
                    output: output.write,
                    requestId: "R1"
                ))
            } catch {
                completion.fail(error)
            }
            Darwin.close(socket.connection)
            Darwin.close(output.write)
        }

        try writeFrame(
            JsonRpcResponse(id: .string("R1"), result: roster("P1")),
            to: socket.peer
        )
        #expect(try readDescriptorRecord(output.read) == roster("P1"))

        try writeFrame(rosterEvent(roster("P1", "P2")), to: socket.peer)
        #expect(try readDescriptorRecord(output.read) == roster("P1", "P2"))

        try writeFrame(rosterEvent(roster("P2")), to: socket.peer)
        #expect(try readDescriptorRecord(output.read) == roster("P2"))

        Darwin.close(socket.peer)
        try completion.wait()
    }

    @Test("the renderer writes the roster exactly as the app sent it")
    func rendererDoesNotProjectTheRosterThroughItsDecoder() throws {
        // Intent: a pane entry carrying a field this build does not know reaches stdout
        //   with that field intact.
        // Why it exists: the wire roster is the stdout contract. Re-encoding a decoded
        //   `PaneRoster` would silently drop whatever the app added since this CLI was
        //   built, and a consumer would read the loss as the app not reporting it.
        // Scenario: a newer app reports a pane field the installed helper predates.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        defer {
            Darwin.close(socket.connection)
            Darwin.close(output.read)
            Darwin.close(output.write)
        }
        let unknown = JSONValue.object([
            "panes": .array([.object(["paneId": .string("P1"), "somethingNew": .bool(true)])]),
        ])
        try writeFrame(JsonRpcResponse(id: .string("R1"), result: unknown), to: socket.peer)
        Darwin.close(socket.peer)

        try renderRosterStream(
            session: streamSession(socket.connection),
            output: output.write,
            requestId: "R1"
        )
        #expect(try readDescriptorRecord(output.read) == unknown)
    }

    @Test("the renderer treats EOF after the first roster as a clean ending")
    func rendererStopsCleanlyOnEOFAfterTheReply() throws {
        // Intent: the app closing the connection after at least one roster returns
        //   normally, leaving every roster written.
        // Why it exists: the subscription lasts exactly as long as the connection, so EOF
        //   is how a follow legitimately ends. Failing here would make the ordinary case
        //   -- the app quitting under a watcher -- look like an error.
        // Scenario: someone quits DanTerm while an agent is following the roster.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        defer {
            Darwin.close(socket.connection)
            Darwin.close(output.read)
            Darwin.close(output.write)
        }
        try writeFrame(JsonRpcResponse(id: .string("R1"), result: roster("P1")), to: socket.peer)
        Darwin.close(socket.peer)

        try renderRosterStream(
            session: streamSession(socket.connection),
            output: output.write,
            requestId: "R1"
        )
        #expect(try readDescriptorRecord(output.read) == roster("P1"))
    }

    @Test("the renderer fails and writes nothing when the stream ends before the reply")
    func rendererFailsWhenClosedBeforeTheFirstRoster() throws {
        // Intent: EOF before any roster arrives fails with the CLI's connection-closed
        //   wording and leaves stdout empty.
        // Why it exists: an empty stream and a stream that ended after reporting the whole
        //   roster are opposite outcomes. Exiting 0 with no lines would tell a consumer
        //   that no panes are open.
        // Scenario: DanTerm accepts the connection and dies before it can answer.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        defer {
            Darwin.close(socket.connection)
            Darwin.close(output.read)
        }
        Darwin.close(socket.peer)

        #expect {
            try renderRosterStream(
                session: streamSession(socket.connection),
                output: output.write,
                requestId: "R1"
            )
        } throws: { error in
            (error as? RosterStreamError)?.errorDescription == "DanTerm closed the connection"
        }
        Darwin.close(output.write)
        #expect(try readDescriptorRecord(output.read) == nil)
    }

    @Test("an error reply fails with the server's message and writes no roster")
    func rendererFailsOnAnErrorReply() throws {
        // Intent: an RPC error carries the server's own sentence out and produces no line.
        // Why it exists: a refused subscription that still printed something would put a
        //   roster the app never sent into a consumer's pipeline.
        // Scenario: the app refuses the request.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        defer {
            Darwin.close(socket.connection)
            Darwin.close(output.read)
        }
        try writeFrame(
            JsonRpcResponse(id: .string("R1"), error: .init(code: -32000, message: "refused")),
            to: socket.peer
        )
        Darwin.close(socket.peer)

        #expect {
            try renderRosterStream(
                session: streamSession(socket.connection),
                output: output.write,
                requestId: "R1"
            )
        } throws: { error in
            (error as? RosterStreamError)?.errorDescription == "refused"
        }
        Darwin.close(output.write)
        #expect(try readDescriptorRecord(output.read) == nil)
    }

    @Test("the renderer treats a closed stdout pipe as a clean ending")
    func rendererStopsCleanlyOnBrokenPipe() throws {
        // Intent: a consumer that walks away mid-follow ends the stream without an error.
        // Why it exists: `danterm roster --follow | head -1` is the obvious way to take one
        //   roster, and it must not report a failure the user did not cause.
        // Scenario: a shell pipeline closes its read end after the first line.
        let socket = try descriptorPair()
        let output = try descriptorPipe()
        defer {
            Darwin.close(socket.connection)
            Darwin.close(socket.peer)
            Darwin.close(output.write)
        }
        signal(SIGPIPE, SIG_IGN)
        Darwin.close(output.read)
        try writeFrame(JsonRpcResponse(id: .string("R1"), result: roster("P1")), to: socket.peer)

        try renderRosterStream(
            session: streamSession(socket.connection),
            output: output.write,
            requestId: "R1"
        )
    }

    private func roster(_ paneIds: String...) -> JSONValue {
        .object(["panes": .array(paneIds.map { .object(["paneId": .string($0)]) })])
    }

    private func rosterEvent(_ roster: JSONValue) -> JsonRpcRequest {
        JsonRpcRequest(method: Methods.rosterEvent, params: roster)
    }
}
