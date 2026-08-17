// Socket-level coverage for the server's half of the liveness contract: the receive
// deadline a connection under the contract runs under, and the close reason it reports.
//
// Write ordering and completion delivery live in IpcConnectionWriteTests; what belongs
// here is only what the bound decides -- who is reclaimed, who is not, and how fast.
// The bounds are small fractions of a second so the suite proves the rule without
// spending the shipped 30, and every wait here suspends rather than blocks: these tests
// spend real time, and a blocked thread of the pool is one the rest of the suite's
// connection callbacks cannot run on.
import Foundation
import Testing
import DanTermProtocol
import Darwin
@testable import DanTermSupport

struct IpcConnectionLivenessTests {
    @Test("a peer that sends no byte within the bound is closed as silent")
    func silentPeerIsReclaimedAtTheBound() async throws {
        // Intent: silence longer than the bound ends the connection, and says so.
        // Why it exists: the idle-zombie case measured on hardware -- a phone whose
        //   radio dies holds an ESTABLISHED socket forever, and nothing in the read
        //   loop ever returns, so the slot and the fd are never released.
        // Scenario: a peer connects, is greeted, and then goes quiet for good.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let closed = CloseReasonProbe()
        defer { Darwin.close(descriptors.peer) }

        let started = ContinuousClock().now
        connection.startReading(
            livenessBound: try #require(IpcLivenessBound(seconds: 0.4)),
            onRequest: { _, _ in },
            onClose: { _, reason in closed.record(reason) }
        )

        #expect(await closed.wait() == .peerSilent)
        // Both sides of the bound: a compliant peer must not be reclaimed early, and a
        // dead one must not keep the slot for an unstated stretch past it.
        let elapsed = ContinuousClock().now - started
        #expect(elapsed >= .milliseconds(400), "reclaimed before the bound: \(elapsed)")
        #expect(elapsed < .seconds(2), "reclaimed long after the bound: \(elapsed)")
    }

    @Test("silence is measured against arriving bytes, not against complete lines")
    func trickledRequestOutlivesTheBound() async throws {
        // Intent: a request that arrives in pieces, each piece inside the bound, is
        //   served -- even when the whole line takes longer than the bound to land.
        // Why it exists: a large record over a slow cellular link arrives exactly this
        //   way, and a deadline measured per frame would kill the connections the
        //   contract exists to keep.
        // Scenario: a peer writes one request line one third at a time.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let closed = CloseReasonProbe()
        let served = RequestProbe()
        defer {
            connection.close()
            Darwin.close(descriptors.peer)
        }

        connection.startReading(
            livenessBound: try #require(IpcLivenessBound(seconds: 0.4)),
            onRequest: { request, _ in served.record(request.method) },
            onClose: { _, reason in closed.record(reason) }
        )

        let line = try encodeIpcLine(
            JsonRpcRequest(id: .string("R1"), method: IpcRequestMethod.ls.rawValue)
        )
        let chunkSize = (line.count / 3) + 1
        var offset = line.startIndex
        while offset < line.endIndex {
            let end = line.index(offset, offsetBy: chunkSize, limitedBy: line.endIndex)
                ?? line.endIndex
            try await Task.sleep(for: .milliseconds(250))
            try write(Data(line[offset..<end]), to: descriptors.peer)
            offset = end
        }

        #expect(await served.wait() == IpcRequestMethod.ls.rawValue)
        #expect(closed.recorded == nil, "a trickling peer must not be reclaimed")
    }

    @Test("an exempt connection idles past the bound and still reports a real close")
    func exemptConnectionIsNeverReclaimed() async throws {
        // Intent: a connection with no bound is never closed for silence, and its
        //   eventual close still names why.
        // Why it exists: a local caller cannot die without its socket closing, and a
        //   local pane follow legitimately idles forever waiting for output.
        // Scenario: a CLI follow sits quiet far longer than the shipped bound, then
        //   the user interrupts it.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let closed = CloseReasonProbe()

        connection.startReading(
            onRequest: { _, _ in },
            onClose: { _, reason in closed.record(reason) }
        )

        try await Task.sleep(for: .seconds(1))
        #expect(closed.recorded == nil, "an exempt connection must survive silence")

        Darwin.close(descriptors.peer)
        #expect(await closed.wait() == .peerClosed)
    }

    @Test("the bound is honored while a write to an unreading peer is parked")
    func parkedWriterDoesNotOutlastTheBound() async throws {
        // Intent: silence past the bound ends the connection even with output queued
        //   for a peer that stopped reading, and the socket really is released.
        // Why it exists: the close a reclaimed connection asks for is enqueued behind
        //   the write queue. A peer that stops reading parks that queue in a blocking
        //   write, so without shutting the socket down first the fd would outlive the
        //   bound by exactly as long as the dead peer chooses -- which is forever.
        // Scenario: an outage freezes a phone mid-stream: it stops reading the records
        //   the Mac is sending and stops sending anything of its own.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let closed = CloseReasonProbe()
        defer { Darwin.close(descriptors.peer) }

        connection.startReading(
            livenessBound: try #require(IpcLivenessBound(seconds: 0.4)),
            onRequest: { _, _ in },
            onClose: { _, reason in closed.record(reason) }
        )
        // Far past any socket buffer, so the writer is certainly parked in `write`.
        connection.writeNotification(
            method: Methods.paneTapeEvent,
            params: .object(["record": .string(String(repeating: "x", count: 4_000_000))])
        )

        #expect(await closed.wait() == .peerSilent)
        // The peer never reads until here. Reaching the end of the stream proves the
        // socket was torn down rather than left held open by the parked write.
        #expect(reachedEndOfStream(descriptors.peer))
    }

    private func socketPair() throws -> (connection: Int32, peer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == data.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Drains whatever is buffered and reports whether the stream ended.
    ///
    /// A bare `Darwin.read` would park this thread for good on a socket that is still
    /// open and quiet, which is the failure this returns `false` for instead. The reads
    /// themselves never wait: `poll` has already said a byte or an end is there.
    private func reachedEndOfStream(_ descriptor: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&readiness, 1, 2_000)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return false }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return true }
        }
    }
}

/// Captures the close reason the read loop reports, so a test can both wait for a close
/// and assert that none happened.
///
/// Waiting suspends rather than blocking a thread: the reader threads these tests park
/// are already real, and adding blocked test threads beside them starves the callbacks
/// the rest of the suite is waiting on.
private final class CloseReasonProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: IpcConnectionCloseReason?

    func record(_ reason: IpcConnectionCloseReason) {
        lock.lock()
        self.reason = reason
        lock.unlock()
    }

    func wait() async -> IpcConnectionCloseReason? {
        await pollUntilRecorded { recorded }
    }

    var recorded: IpcConnectionCloseReason? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }
}

private final class RequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var method: String?

    func record(_ method: String) {
        lock.lock()
        self.method = method
        lock.unlock()
    }

    func wait() async -> String? {
        await pollUntilRecorded { recorded }
    }

    var recorded: String? {
        lock.lock()
        defer { lock.unlock() }
        return method
    }
}

/// Suspends until the probe holds a value, or gives up so the assertion names the test
/// rather than letting the whole lane die to an outside deadline.
private func pollUntilRecorded<Value>(
    _ read: () -> Value?
) async -> Value? {
    let deadline = ContinuousClock.now + .seconds(4)
    while ContinuousClock.now < deadline {
        if let value = read() { return value }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return read()
}
