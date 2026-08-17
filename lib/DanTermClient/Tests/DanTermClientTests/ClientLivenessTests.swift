// Coverage for the client half of the peer-liveness contract: the ping obligation, the
// receive deadline, and what a dead peer does to a session.
//
// The bounds here are a second or less because the number is the server's to state and
// the client only derives from it, so a test can compress the whole contract by
// advertising a small one. Nothing here opens a socket: the contract is a rule about a
// byte stream, and a stream that a test writes by hand proves it more precisely than a
// real one can.
//
// The bounds are not as small as they could be, on purpose. A test that trips at half a
// bound of scheduling delay fails on a loaded machine and says nothing about the code, so
// every margin here is several times the delay the gate's parallel workers introduce.
//
// Waiting is done with `Task.sleep` rather than by blocking a test thread. These tests
// park real reader threads, and a blocked test thread beside them starved sibling suites
// in this package into timing out.
import Foundation
import Testing
import DanTermProtocol
@testable import DanTermClient

/// A scripted peer on a stream that declares itself under the contract, so a test can
/// choose independently whether it answers heartbeats and whether it sends any byte.
private final class LivenessPeer: DanTermClientTransport, @unchecked Sendable {
    static let livenessPolicy = DanTermClientLivenessPolicy.underContract

    private let condition = NSCondition()
    private var inbound: [Data] = []
    private var closed = false
    private let answersPings: Bool
    private var writesFail = false
    private var pingsReceived = 0

    init(answersPings: Bool) {
        self.answersPings = answersPings
    }

    func send(_ bytes: Data) throws {
        condition.lock()
        defer { condition.unlock() }
        if writesFail { throw DanTermClientTransportError.cancelled }
        let line = bytes.prefix(while: { $0 != UInt8(ascii: "\n") })
        guard let request = try? JSONDecoder().decode(JsonRpcRequest.self, from: Data(line)),
              request.method == IpcRequestMethod.ping.rawValue
        else { return }
        pingsReceived += 1
        guard answersPings, let id = request.id else { return }
        if let pong = try? encodeIpcLine(JsonRpcResponse(id: id, result: .object([:]))) {
            inbound.append(pong)
            condition.broadcast()
        }
    }

    func receive() throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        while inbound.isEmpty && closed == false { condition.wait() }
        if closed { return Data() }
        return inbound.removeFirst()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// Puts one complete line on the stream.
    func deliver(_ text: String) {
        deliver(bytes: Data((text + "\n").utf8))
    }

    /// Puts an arbitrary run of bytes on the stream, so a test can split a line anywhere.
    func deliver(bytes: Data) {
        condition.lock()
        inbound.append(bytes)
        condition.broadcast()
        condition.unlock()
    }

    func failEveryWrite() {
        condition.withLock { writesFail = true }
    }

    var observedPingCount: Int {
        condition.withLock { pingsReceived }
    }
}

/// A stream whose kind is exempt and which never produces a byte, so a test can watch a
/// reader idle for as long as it likes.
private final class ExemptSilentPeer: DanTermClientTransport, @unchecked Sendable {
    static let livenessPolicy = DanTermClientLivenessPolicy.exempt

    private let condition = NSCondition()
    private var closed = false

    func send(_ bytes: Data) throws {}

    func receive() throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        while closed == false { condition.wait() }
        return Data()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Runs one blocking read on its own thread so the test can ask, at any moment, whether
/// the session is still waiting or has produced an outcome.
private final class ReaderProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var outcome: Result<DanTermClientFrame?, Error>?
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var elapsed: TimeInterval = 0

    init(reading session: DanTermClientSession) {
        let thread = Thread { [self] in
            let result = Result { try session.nextFrame() }
            condition.lock()
            elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            outcome = result
            condition.broadcast()
            condition.unlock()
        }
        thread.name = "liveness-probe"
        thread.start()
    }

    var isStillWaiting: Bool {
        condition.withLock { outcome == nil }
    }

    /// How long the read took, valid once it has settled.
    var finishedAfter: TimeInterval {
        condition.withLock { elapsed }
    }

    /// Suspends until the read finishes, giving up rather than hanging the whole suite.
    /// It polls instead of waiting on the condition so no test thread is ever parked.
    func settled(within timeout: TimeInterval) async -> Result<DanTermClientFrame?, Error>? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let settled = condition.withLock({ outcome }) { return settled }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition.withLock { outcome }
    }
}

/// Consumes frames as fast as they arrive, so a test can keep a session busy rather than
/// parked and check that the obligation does not depend on how quiet the stream is.
private final class DrainingReader: @unchecked Sendable {
    private let lock = NSLock()
    private var received = 0

    init(reading session: DanTermClientSession) {
        let thread = Thread {
            while let _ = try? session.nextFrame() {
                self.lock.withLock { self.received += 1 }
            }
        }
        thread.name = "liveness-drain"
        thread.start()
    }

    var observedFrameCount: Int {
        lock.withLock { received }
    }
}

private func helloLine(silenceBound: Double) -> String {
    let request = JsonRpcRequest(
        method: Methods.hello,
        params: IpcHello.params(
            protocolVersion: DanTermClientSession.supportedProtocolVersion,
            appVersion: "test",
            livenessBound: IpcLivenessBound(seconds: silenceBound)!
        )
    )
    guard let data = try? JSONEncoder().encode(request) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

private func notificationLine(_ method: String) -> String {
    guard let data = try? JSONEncoder().encode(JsonRpcRequest(method: method)) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

private func silentPeerError(_ outcome: Result<DanTermClientFrame?, Error>?) -> DanTermClientError? {
    guard case .failure(let error) = outcome else { return nil }
    return error as? DanTermClientError
}

struct ClientLivenessTests {
    @Test("a transport kind declares whether its streams live under the contract")
    func transportKindsDeclareTheirPolicy() {
        // Intent: the contract applies because of what a stream is, not because a call
        //   site remembered to ask for it.
        // Why it exists: a session that could be opened without the contract is exactly
        //   the unbounded "Connecting" this work exists to remove.
        #expect(TCPSocketTransport.livenessPolicy == .underContract)
        #expect(UnixSocketTransport.livenessPolicy == .exempt)
    }

    @Test("a quiet session stays alive across several bounds on its heartbeats alone")
    func quietSessionSurvivesOnItsHeartbeats() async throws {
        // Intent: with nothing to say in either direction, the client pings at half the
        //   advertised bound and neither end runs out of patience.
        // Why it exists: a user reading a quiet pane must never have the connection taken
        //   away, and the cadence is the only thing keeping either deadline fed.
        // Scenario: a phone left on a quiet pane, with the establishment bound set far
        //   too long to be the source of any of this -- only the advertised number can be.
        let bound = 0.8
        let peer = LivenessPeer(answersPings: true)
        peer.deliver(helloLine(silenceBound: bound))
        let session = DanTermClientSession(
            transport: peer,
            establishmentBound: IpcLivenessBound(seconds: 60)!
        )
        defer { session.cancel() }
        #expect(try session.handshake().livenessBound == IpcLivenessBound(seconds: bound))

        let probe = ReaderProbe(reading: session)
        try await Task.sleep(for: .seconds(bound * 3))

        #expect(probe.isStillWaiting)
        #expect(peer.observedPingCount >= 3)
    }

    @Test("a busy session keeps the same heartbeat cadence as a quiet one")
    func busySessionKeepsTheSameCadence() async throws {
        // Intent: the cadence is unconditional. A session draining a flood pings on the
        //   same schedule as one with nothing to read.
        // Why it exists: a cadence that skipped a ping because other traffic was flowing
        //   would make each end's deadline depend on which frames the other happens to
        //   answer -- and a flood of notifications earns no replies at all.
        // Scenario: a followed pane producing records continuously.
        let bound = 0.8
        let peer = LivenessPeer(answersPings: true)
        peer.deliver(helloLine(silenceBound: bound))
        let session = DanTermClientSession(transport: peer)
        defer { session.cancel() }
        try session.handshake()

        let reader = DrainingReader(reading: session)
        let flood = Task {
            while Task.isCancelled == false {
                peer.deliver(notificationLine("pane.tape.event"))
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        try await Task.sleep(for: .seconds(bound * 2.5))
        flood.cancel()

        #expect(reader.observedFrameCount > 5)
        #expect(peer.observedPingCount >= 3)
    }

    @Test("a stream that goes byte-silent past the bound reports the peer as gone")
    func silentStreamReportsPeerSilent() async throws {
        // Intent: silence past the advertised bound ends the session with `peerSilent`
        //   rather than leaving the reader parked.
        // Why it exists: measured on hardware, a Mac that stops answering leaves the
        //   phone reading "Connected" for the whole outage.
        // Scenario: the server delivers hello and then answers nothing at all.
        let peer = LivenessPeer(answersPings: false)
        peer.deliver(helloLine(silenceBound: 0.3))
        let session = DanTermClientSession(transport: peer)
        defer { session.cancel() }
        try session.handshake()

        let probe = ReaderProbe(reading: session)

        #expect(silentPeerError(await probe.settled(within: 3)) == .peerSilent)
    }

    @Test("a request whose reply never comes ends at the bound instead of waiting forever")
    func awaitedReplyEndsAtTheBound() throws {
        // Intent: an outstanding request on a byte-silent stream fails with `peerSilent`.
        // Why it exists: a Mac that accepts, greets, and then never services a request is
        //   the deafness case; nothing below dispatch rescues it, so the client must say so.
        // Scenario: the server is admitting connections but cannot do any work.
        let peer = LivenessPeer(answersPings: false)
        peer.deliver(helloLine(silenceBound: 0.3))
        let session = DanTermClientSession(transport: peer)
        defer { session.cancel() }
        try session.handshake()
        try session.send(JsonRpcRequest(id: .string("r1"), method: IpcRequestMethod.ls.rawValue))

        let outcome = Result { try session.awaitReply(id: .string("r1")) }

        guard case .failure(let error) = outcome else {
            Issue.record("A silent server produced a reply.")
            return
        }
        #expect(error as? DanTermClientError == .peerSilent)
    }

    @Test("a peer that trickles bytes without completing a line is not declared dead")
    func trickledBytesKeepTheStreamAlive() async throws {
        // Intent: the bound measures arriving bytes, not arriving frames.
        // Why it exists: a large sync record over a slow cellular link takes longer than
        //   the bound to finish, and killing that connection would break the case remote
        //   use exists for.
        // Scenario: one long notification arrives in pieces spread over more than a
        //   bound, from a server that answers no heartbeat at all.
        let bound = 2.0
        let peer = LivenessPeer(answersPings: false)
        peer.deliver(helloLine(silenceBound: bound))
        let session = DanTermClientSession(transport: peer)
        defer { session.cancel() }
        try session.handshake()

        // A tenth of the bound between pieces, for long enough in total to pass one whole
        // bound. The ratio is what makes this safe on a loaded machine: a gap has to
        // stretch tenfold before it means anything.
        let probe = ReaderProbe(reading: session)
        let line = Array((notificationLine("pane.tape.event") + "\n").utf8)
        let size = max(line.count / 12, 1)
        for start in stride(from: 0, to: line.count, by: size) {
            try await Task.sleep(for: .seconds(bound / 10))
            peer.deliver(bytes: Data(line[start..<min(start + size, line.count)]))
        }

        guard case .success(let frame) = await probe.settled(within: 3) else {
            Issue.record("A trickling peer was declared dead.")
            return
        }
        #expect(frame == .notification(method: "pane.tape.event", params: nil))
    }

    @Test("a peer that never sends hello is bounded by the client's establishment policy")
    func missingHelloIsBoundedBeforeTheServerStatesABound() {
        // Intent: the pre-hello wait ends, even though the server has stated no bound yet.
        // Why it exists: a Mac that accepts the connection and never reads it left
        //   "Connecting" unbounded by construction.
        // Scenario: the connection is admitted and then nothing arrives on it.
        let session = DanTermClientSession(
            transport: LivenessPeer(answersPings: false),
            establishmentBound: IpcLivenessBound(seconds: 0.3)!
        )
        defer { session.cancel() }

        #expect(throws: DanTermClientError.peerSilent) { try session.handshake() }
    }

    @Test("a hello with no advertised bound is unusable on a stream under the contract")
    func helloWithoutABoundIsRefusedUnderTheContract() {
        // Intent: a stream that owes the contract refuses a hello that states no number.
        // Why it exists: only the server may define the bound. Carrying on without one
        //   would leave the client either unbounded or applying a rule it invented.
        // Scenario: a server that greets a remote client without the field.
        let peer = LivenessPeer(answersPings: false)
        peer.deliver(#"{"jsonrpc":"2.0","method":"hello","params":{"protocol":1,"app":"test"}}"#)
        let session = DanTermClientSession(transport: peer)
        defer { session.cancel() }

        #expect(throws: DanTermClientError.invalidHello) { try session.handshake() }
    }

    @Test("no heartbeat reply ever reaches a session consumer")
    func pongsAreAbsorbedBeforeTheConsumerSeesThem() async throws {
        // Intent: the first frame a consumer gets is the first real one, however many
        //   heartbeats were exchanged while it waited.
        // Why it exists: a pong delivered as an ordinary reply would either satisfy the
        //   wrong `awaitReply` or pile up in the deferred queue for the whole session.
        // Scenario: a long quiet follow, then one tape record.
        let bound = 0.8
        let peer = LivenessPeer(answersPings: true)
        peer.deliver(helloLine(silenceBound: bound))
        let session = DanTermClientSession(transport: peer)
        defer { session.cancel() }
        try session.handshake()

        let probe = ReaderProbe(reading: session)
        try await Task.sleep(for: .seconds(bound * 2.5))
        #expect(peer.observedPingCount >= 3)
        peer.deliver(notificationLine("pane.tape.event"))

        guard case .success(let frame) = await probe.settled(within: 3) else {
            Issue.record("A healthy peer's reader did not produce the notification.")
            return
        }
        #expect(frame == .notification(method: "pane.tape.event", params: nil))
    }

    @Test("a heartbeat that cannot be written ends the connection before the bound")
    func unwritableHeartbeatEndsTheConnectionEarly() async throws {
        // Intent: a failed ping is reported now, not left for the server to reclaim a
        //   whole bound later.
        // Why it exists: a connection that silently stopped pinging is already dead in
        //   both directions; waiting out the bound would only delay saying so.
        // Scenario: the socket's write side fails while its read side stays parked.
        let bound = 3.0
        let peer = LivenessPeer(answersPings: true)
        peer.deliver(helloLine(silenceBound: bound))
        let session = DanTermClientSession(transport: peer)
        defer { session.cancel() }
        try session.handshake()

        let probe = ReaderProbe(reading: session)
        peer.failEveryWrite()

        #expect(silentPeerError(await probe.settled(within: bound * 2)) == .peerSilent)
        #expect(probe.finishedAfter < bound)
    }

    @Test("an exempt stream idles far past any bound untouched")
    func exemptStreamIsNeverDeclaredDead() async throws {
        // Intent: a stream whose kind is exempt gets no deadline at all.
        // Why it exists: a local pane follow is idle for exactly as long as its pane is
        //   quiet, and a bound applied there would cut a healthy capture short.
        // Scenario: a `danterm pane tape --follow` over the local control socket, on a
        //   session whose establishment bound is small enough to have fired many times.
        let session = DanTermClientSession(
            transport: ExemptSilentPeer(),
            establishmentBound: IpcLivenessBound(seconds: 0.2)!
        )
        defer { session.cancel() }

        let probe = ReaderProbe(reading: session)
        try await Task.sleep(for: .seconds(1.2))

        #expect(probe.isStillWaiting)
    }
}
