// Coverage for the client conversation itself, driven over a transport that is not a
// socket. Nothing here opens a file descriptor: if these tests needed one, the seam would
// not be a seam.
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermClient

/// A transport backed by two byte buffers, so a whole conversation can be scripted in
/// memory. Its existence is the evidence that the seam admits more than one transport.
final class ScriptedTransport: DanTermClientTransport {
    private var inbound: [Data]
    private(set) var sent = Data()
    private(set) var isClosed = false

    /// Each element is delivered by one `receive()` call, so a test can control how lines
    /// are split across chunk boundaries.
    init(chunks: [Data]) {
        self.inbound = chunks
    }

    convenience init(lines: [String]) {
        self.init(chunks: lines.map { Data(($0 + "\n").utf8) })
    }

    func send(_ bytes: Data) throws {
        sent.append(bytes)
    }

    func receive() throws -> Data {
        inbound.isEmpty ? Data() : inbound.removeFirst()
    }

    func close() {
        isClosed = true
    }
}

struct ClientSessionTests {
    @Test("the handshake accepts the protocol version and surfaces the server app version")
    func handshakeAcceptsKnownVersionAndSurfacesAppVersion() throws {
        let session = DanTermClientSession(
            transport: ScriptedTransport(lines: [hello(protocol: 1, app: "9.4.1")])
        )

        let server = try session.handshake()

        #expect(server.appVersion == "9.4.1")
    }

    @Test("the handshake reports a stream that closed, a bad hello, and an unknown version apart")
    func handshakeDistinguishesItsFailures() throws {
        // Intent: the three ways a handshake can fail stay three outcomes.
        // Why it exists: a caller renders them differently -- absent, broken, too new --
        //   and a single "handshake failed" would make that impossible.
        // Scenario: three peers, each wrong in one way.
        #expect(throws: DanTermClientError.closedBeforeHello) {
            try DanTermClientSession(transport: ScriptedTransport(lines: [])).handshake()
        }
        #expect(throws: DanTermClientError.invalidHello) {
            let line = #"{"jsonrpc":"2.0","method":"something-else"}"#
            try DanTermClientSession(transport: ScriptedTransport(lines: [line])).handshake()
        }
        #expect(throws: DanTermClientError.unsupportedProtocol(9)) {
            try DanTermClientSession(
                transport: ScriptedTransport(lines: [hello(protocol: 9, app: "future")])
            ).handshake()
        }
    }

    @Test("every connection rejection reason becomes its own typed client error")
    func handshakeDistinguishesConnectionRejections() {
        let cases: [(IpcConnectionRejectionReason, DanTermClientError)] = [
            (.notAdmitted, .notAdmitted),
            (.identityUnresolved, .identityUnresolved),
            (.connectionLimit, .connectionLimit),
            (.auditUnavailable, .auditUnavailable),
        ]

        for (reason, expectedError) in cases {
            #expect(throws: expectedError) {
                try DanTermClientSession(
                    transport: ScriptedTransport(lines: [encoded(reason.notification)])
                ).handshake()
            }
        }
    }

    @Test("a line split across chunk boundaries is still one frame")
    func framingSpansChunks() throws {
        let line = hello(protocol: 1, app: "test") + "\n"
        let split = line.index(line.startIndex, offsetBy: 12)
        let transport = ScriptedTransport(chunks: [
            Data(line[line.startIndex..<split].utf8),
            Data(line[split...].utf8),
        ])
        let session = DanTermClientSession(transport: transport)

        #expect(throws: Never.self) { try session.handshake() }
    }

    @Test("notifications that arrive while a reply is awaited are delivered once and in order")
    func notificationsSurviveAnAwaitedReply() throws {
        // Intent: awaiting a correlated reply consumes nothing else. Notifications that
        //   arrive before it, and between two replies, are all still there afterwards,
        //   in the order the peer sent them, each exactly once.
        // Why it exists: the natural shape for this loop is "read until the id matches,
        //   discard the rest", and that loop silently eats tape records whenever a
        //   request overlaps a subscription. The bug is invisible until a pane is busy.
        // Scenario: a client holds a tape subscription and asks a question while records
        //   are streaming in.
        let session = DanTermClientSession(transport: ScriptedTransport(lines: [
            notification(record: "first"),
            reply(id: "other", result: .string("not mine")),
            notification(record: "second"),
            reply(id: "mine", result: .string("mine")),
            notification(record: "third"),
        ]))

        let response = try session.awaitReply(id: .string("mine"))
        #expect(response?.result == .string("mine"))

        var records: [String] = []
        while let next = try session.nextNotification() {
            let carried = try #require(PaneTapeStreamNotification(method: next.method, params: next.params))
            records.append(try #require(carried.record["kind"]?.asString))
        }
        #expect(records == ["first", "second", "third"])
    }

    @Test("a reply nobody is waiting for neither satisfies a pending request nor disappears")
    func uncorrelatedReplyIsKeptNotConsumed() throws {
        // Intent: an unrelated reply arriving first does not resolve the awaited request,
        //   and is still readable afterwards.
        // Why it exists: a loop that returns the first response it sees would hand the
        //   caller another request's answer; a loop that discards it would lose a reply a
        //   second outstanding request still needs.
        // Scenario: two requests are outstanding and the peer answers them out of order.
        let session = DanTermClientSession(transport: ScriptedTransport(lines: [
            reply(id: "b", result: .string("b-result")),
            reply(id: "a", result: .string("a-result")),
        ]))

        #expect(try session.awaitReply(id: .string("a"))?.result == .string("a-result"))
        #expect(try session.awaitReply(id: .string("b"))?.result == .string("b-result"))
    }

    @Test("deferred frames are handed back oldest first, whatever their kind")
    func deferredFramesKeepArrivalOrder() throws {
        let session = DanTermClientSession(transport: ScriptedTransport(lines: [
            notification(record: "first"),
            reply(id: "other", result: .string("other-result")),
            reply(id: "mine", result: .string("mine-result")),
        ]))
        _ = try session.awaitReply(id: .string("mine"))

        #expect(try session.nextFrame() == .notification(
            method: Methods.paneTapeEvent,
            params: .object([
                "subscription": .string("s1"),
                "record": .object(["kind": .string("first")]),
            ])
        ))
        #expect(try session.nextFrame() == .response(
            JsonRpcResponse(id: .string("other"), result: .string("other-result"))
        ))
        #expect(try session.nextFrame() == nil)
    }

    @Test("a reply that never arrives resolves as end of stream rather than an error")
    func missingReplyIsEndOfStream() throws {
        // Intent: the session reports "the peer closed first" as nil, and leaves the
        //   judgement to the caller.
        // Why it exists: a request that ends the instance takes its own socket down, so
        //   only the caller knows whether a missing reply is the expected outcome.
        // Scenario: the app honors a quit and exits before it can answer.
        let session = DanTermClientSession(transport: ScriptedTransport(lines: []))
        #expect(try session.awaitReply(id: .string("mine")) == nil)
    }

    @Test("the request a caller sends reaches the transport as one framed line")
    func requestIsWrittenAsOneLine() throws {
        let transport = ScriptedTransport(lines: [])
        let session = DanTermClientSession(transport: transport)
        try session.send(JsonRpcRequest(id: .string("r1"), method: "ls", params: .object([:])))

        let written = String(decoding: transport.sent, as: UTF8.self)
        #expect(written.hasSuffix("\n"))
        #expect(written.dropLast().contains("\n") == false)
        let decoded = try JSONDecoder().decode(
            JsonRpcRequest.self,
            from: Data(written.dropLast().utf8)
        )
        #expect(decoded.id == .string("r1"))
        #expect(decoded.method == "ls")
    }

    @Test("closing the session closes its transport")
    func closePropagates() {
        let transport = ScriptedTransport(lines: [])
        DanTermClientSession(transport: transport).close()
        #expect(transport.isClosed)
    }

    private func hello(protocol version: Int, app: String) -> String {
        encoded(JsonRpcRequest(
            method: Methods.hello,
            params: .object([
                "protocol": .number(Double(version)),
                "app": .string(app),
            ])
        ))
    }

    private func reply(id: String, result: JSONValue) -> String {
        encoded(JsonRpcResponse(id: .string(id), result: result))
    }

    private func notification(record kind: String) -> String {
        encoded(JsonRpcRequest(
            method: Methods.paneTapeEvent,
            params: .object([
                "subscription": .string("s1"),
                "record": .object(["kind": .string(kind)]),
            ])
        ))
    }

    private func encoded<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
