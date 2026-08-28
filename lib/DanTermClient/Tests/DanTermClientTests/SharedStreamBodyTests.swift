// Behavioral coverage for the one POSIX stream body both client transports run on.
//
// It holds what is true of the shared body rather than of either socket kind: the read
// buffer is reused across calls, each returned value is independent, and every stream
// outcome still arrives in the calling transport's own error vocabulary. Tests about how
// a socket is opened stay in the per-transport files.
import Darwin
import Foundation
import Testing
@testable import DanTermClient

// Serialized because the allocation test installs a process-wide malloc hook.
@Suite(.serialized)
struct SharedStreamBodyTests {
    // Intent: after the first read, a receive costs no buffer-sized allocation.
    // Why it exists: a followed tape stream wakes once per notification, so a per-call
    //   64 KiB calloc was paid per notification regardless of the bytes delivered.
    // Scenario: a warmed stream on each transport delivers 64 one-byte chunks while an
    //   allocation-event counter watches the reading thread.
    @Test("a warmed receive allocates no read buffer of its own", .timeLimit(.minutes(1)))
    func warmedReceiveAllocatesNoBuffer() throws {
        let unixPeer = try SocketPairPeer()
        let unix = try UnixSocketTransport(
            connectedDescriptor: unixPeer.transportDescriptor,
            sendTimeout: 30
        )
        defer { unix.close() }
        let unixSample = try sampledReceives(of: unix, fedBy: unixPeer.descriptor)
        #expect(unixSample.receives > 0)
        #expect(unixSample.allocations == 0)

        let listener = try TCPTestListener()
        defer { listener.close() }
        let tcp = try TCPSocketTransport(
            host: "127.0.0.1",
            port: listener.port,
            connectTimeout: 30,
            receiveTimeout: nil,
            sendTimeout: 30
        )
        defer { tcp.close() }
        let accepted = try #require(listener.accept())
        defer { Darwin.close(accepted) }
        let tcpSample = try sampledReceives(of: tcp, fedBy: accepted)
        #expect(tcpSample.receives > 0)
        #expect(tcpSample.allocations == 0)
    }

    // Intent: a value an earlier receive returned survives a later receive unchanged.
    // Why it exists: the shared buffer is reused, so a returned Data that aliased it
    //   would be rewritten under a caller that had not consumed it yet.
    @Test("consecutive receives return independent values", .timeLimit(.minutes(1)))
    func consecutiveReceivesReturnIndependentValues() throws {
        let peer = try SocketPairPeer()
        let transport = try UnixSocketTransport(
            connectedDescriptor: peer.transportDescriptor,
            sendTimeout: 30
        )
        defer { transport.close() }

        // Each feed is checked for the same reason the sampled loop checks its own: an
        // unsent payload leaves the matching receive blocked in `read`.
        try #require(peer.write(Data("first".utf8)))
        let first = try transport.receive()
        try #require(peer.write(Data("second".utf8)))
        let second = try transport.receive()

        #expect(first == Data("first".utf8))
        #expect(second == Data("second".utf8))
    }

    // Intent: a receive that outlives its configured wait stays each transport's own
    //   timedOut case rather than a shared internal outcome.
    @Test("a silent peer times out in each transport's vocabulary", .timeLimit(.minutes(1)))
    func silentPeerTimesOutPerTransport() throws {
        // These waits are the event under test, not hang guards: nothing is ever sent.
        let probeWait: TimeInterval = 0.1

        let peer = try SocketPairPeer()
        try peer.setReceiveTimeout(probeWait)
        let unix = try UnixSocketTransport(
            connectedDescriptor: peer.transportDescriptor,
            sendTimeout: 30
        )
        defer { unix.close() }
        #expect(throws: UnixSocketTransportError.timedOut) { try unix.receive() }

        let listener = try TCPTestListener()
        defer { listener.close() }
        let tcp = try TCPSocketTransport(
            host: "127.0.0.1",
            port: listener.port,
            connectTimeout: 30,
            receiveTimeout: probeWait,
            sendTimeout: 30
        )
        defer { tcp.close() }
        let accepted = try #require(listener.accept())
        defer { Darwin.close(accepted) }
        #expect(throws: TCPSocketTransportError.timedOut) { try tcp.receive() }
    }

    // Intent: end of stream stays an empty value, not an error, on both transports.
    @Test("a closed peer ends the stream with empty data", .timeLimit(.minutes(1)))
    func closedPeerEndsTheStream() throws {
        let peer = try SocketPairPeer()
        let unix = try UnixSocketTransport(
            connectedDescriptor: peer.transportDescriptor,
            sendTimeout: 30
        )
        defer { unix.close() }
        peer.close()
        #expect(try unix.receive().isEmpty)

        let listener = try TCPTestListener()
        defer { listener.close() }
        let tcp = try TCPSocketTransport(
            host: "127.0.0.1",
            port: listener.port,
            connectTimeout: 30,
            receiveTimeout: nil,
            sendTimeout: 30
        )
        defer { tcp.close() }
        let accepted = try #require(listener.accept())
        Darwin.close(accepted)
        #expect(try tcp.receive().isEmpty)
    }

    // Intent: a write to a departed peer is a write failure, not a timeout or an EOF.
    @Test("a write to a closed peer fails as a write failure", .timeLimit(.minutes(1)))
    func writeToClosedPeerFails() throws {
        let peer = try SocketPairPeer()
        let transport = try UnixSocketTransport(
            connectedDescriptor: peer.transportDescriptor,
            sendTimeout: 30
        )
        defer { transport.close() }
        peer.close()

        #expect(throws: UnixSocketTransportError.writeFailed) {
            try transport.send(Data("after the peer left".utf8))
        }
    }

    // Intent: a reset connection is a read failure, distinct from a clean EOF.
    // Why it exists: a client that reads a reset as EOF reports a finished stream when
    //   the peer actually vanished.
    // Scenario: a loopback peer with a zero linger closes, so the kernel sends RST.
    @Test("a reset peer fails the read", .timeLimit(.minutes(1)))
    func resetPeerFailsTheRead() throws {
        let listener = try TCPTestListener()
        defer { listener.close() }
        let transport = try TCPSocketTransport(
            host: "127.0.0.1",
            port: listener.port,
            connectTimeout: 30,
            receiveTimeout: nil,
            sendTimeout: 30
        )
        defer { transport.close() }
        let accepted = try #require(listener.accept())
        var resetOnClose = linger(l_onoff: 1, l_linger: 0)
        try #require(setsockopt(
            accepted, SOL_SOCKET, SO_LINGER, &resetOnClose, socklen_t(MemoryLayout<linger>.size)
        ) == 0)
        Darwin.close(accepted)

        #expect(throws: TCPSocketTransportError.readFailed) { try transport.receive() }
    }

    // Intent: close reaches a write that is blocked inside the shared body -- it wakes
    //   it, lets it finish, and fences every later operation.
    // Why it exists: the buffer and the descriptor now outlive individual calls, so the
    //   cancellation path has to reach a real blocked POSIX write, not only a double.
    // Scenario: a socketpair peer stops reading, an oversized send blocks in the shared
    //   write loop, and close begins while that send holds the descriptor.
    //
    // The strict "close returns only after the borrow is released" ordering is proven by
    // `ClientSessionTests` "cancellation waits for an active send", whose double controls
    // when the write releases. Here close wakes the write, so the release and close's
    // return are microseconds apart in either order; asserting that order would be a race,
    // not a proof.
    @Test("close wakes a blocked send and refuses later work", .timeLimit(.minutes(1)))
    func closeWakesABlockedSend() throws {
        let peer = try SocketPairPeer(sendBufferBytes: 1_024)
        nonisolated(unsafe) let transport = try UnixSocketTransport(
            connectedDescriptor: peer.transportDescriptor,
            // Long enough that this send cannot end on its own wait: only close ends it.
            sendTimeout: 30
        )
        let sendOutcome = ThreadOutcome()

        Thread {
            do {
                try transport.send(Data(repeating: 0x78, count: 8 * 1_024 * 1_024))
                sendOutcome.finish(nil)
            } catch {
                sendOutcome.finish(error)
            }
        }.start()
        try waitUntilUnwritable(peer.transportDescriptor, within: 30)

        transport.close()

        // The send was inside the shared body, so it ends in the transport's stream
        // vocabulary. `cancelled` here would mean close fenced it before it ever started,
        // and the scenario never happened.
        let outcome = try sendOutcome.wait(within: 30)
        #expect(outcome as? UnixSocketTransportError == .writeFailed)
        #expect(throws: DanTermClientTransportError.cancelled) { try transport.receive() }
        #expect(throws: DanTermClientTransportError.cancelled) {
            try transport.send(Data("later".utf8))
        }
    }

    private func sampledReceives(
        of transport: DanTermClientTransport,
        fedBy peer: Int32
    ) throws -> (allocations: Int, receives: Int) {
        // Every feed is checked: a byte that never arrives leaves the matching receive
        // blocked in `read`, and a time limit cannot unwind a blocking syscall.
        try #require(writeOneByte(to: peer))
        _ = try transport.receive()

        let sampleCount = 64
        var receives = 0
        var feeds = 0
        var failure: Error?
        let allocations = try #require(
            LargeAllocationCounter.count(allocationsOfAtLeast: 64 * 1_024) {
                for _ in 0..<sampleCount {
                    guard writeOneByte(to: peer) else { return }
                    feeds += 1
                    do {
                        receives += try transport.receive().isEmpty ? 0 : 1
                    } catch {
                        failure = error
                        return
                    }
                }
            }
        )
        if let failure { throw failure }
        #expect(feeds == sampleCount)
        return (allocations, receives)
    }
}

/// Waits until a descriptor's send buffer is full, which is the observable form of "the
/// write loop is blocked inside `write`". Signalling from the sending thread cannot say
/// that: the signal fires before the call, not inside it.
private func waitUntilUnwritable(_ descriptor: Int32, within seconds: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        // Five milliseconds is the poll's own step, not the guard; the guard is `deadline`.
        if Darwin.poll(&event, 1, 5) == 0 { return }
    }
    throw POSIXError(.ETIMEDOUT)
}

/// Writes one byte without touching the heap, so the allocation counter sees only the
/// allocations the transport itself makes, and reports whether it landed.
@discardableResult
private func writeOneByte(to descriptor: Int32) -> Bool {
    var byte: UInt8 = 0x61
    return Darwin.write(descriptor, &byte, 1) == 1
}

/// One end of a connected socketpair, so the real POSIX read and write paths run without
/// a filesystem endpoint. The other end is handed to the transport under test, which then
/// owns it.
private final class SocketPairPeer {
    let descriptor: Int32
    let transportDescriptor: Int32
    private var isClosed = false

    init(sendBufferBytes: Int32? = nil) throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        transportDescriptor = descriptors[0]
        descriptor = descriptors[1]
        if var sendBufferBytes {
            try #require(setsockopt(
                transportDescriptor,
                SOL_SOCKET,
                SO_SNDBUF,
                &sendBufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0)
        }
    }

    /// Configures the transport's end, which the transport's test-only initializer leaves
    /// unbounded. It has to take: without the bound, the receive under test blocks
    /// forever, and a blocked syscall is not something a time limit can unwind.
    func setReceiveTimeout(_ seconds: TimeInterval) throws {
        var timeout = timeval(
            tv_sec: Int(seconds),
            tv_usec: suseconds_t((seconds - Double(Int(seconds))) * 1_000_000)
        )
        try #require(setsockopt(
            transportDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0)
    }

    func write(_ bytes: Data) -> Bool {
        bytes.withUnsafeBytes {
            Darwin.write(descriptor, $0.baseAddress, $0.count) == $0.count
        }
    }

    func close() {
        guard isClosed == false else { return }
        isClosed = true
        Darwin.close(descriptor)
    }

    deinit { close() }
}

/// Carries a thread's result back to its test, and says so when the wait expires instead
/// of letting a hang read as a quiet pass.
private final class ThreadOutcome: @unchecked Sendable {
    private let condition = NSCondition()
    private var finished = false
    private var error: Error?

    func finish(_ error: Error?) {
        condition.lock()
        self.error = error
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(within seconds: TimeInterval) throws -> Error? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(seconds)
        while finished == false {
            guard condition.wait(until: deadline) else { throw POSIXError(.ETIMEDOUT) }
        }
        return error
    }
}

private typealias MallocEventLogger =
    @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// Counts heap allocation *events* of at least a given size made on the calling thread.
///
/// Live-heap statistics cannot answer the question this suite asks: a body that allocates
/// a 64 KiB buffer and frees it before returning leaves live bytes flat while paying the
/// cost on every call. Darwin's `malloc_logger` hook is the event stream libmalloc already
/// calls for stack logging. The callback runs inside malloc, so it reads only memory
/// allocated up front and never allocates itself, and it counts only the sampling thread
/// so a test running in parallel cannot contribute.
private enum LargeAllocationCounter {
    /// `[event count, size threshold, sampling thread]`, held in one raw allocation
    /// because the callback may not allocate and may not capture context.
    nonisolated(unsafe) private static let state =
        UnsafeMutablePointer<Int>.allocate(capacity: 3)

    private static let logger: MallocEventLogger = { type, first, second, _, _, _ in
        // libmalloc's log type: bit 1 is "allocate", bit 3 is "the first argument is the
        // zone", which shifts the size into the second argument.
        guard type & 2 != 0 else { return }
        let size = type & 8 != 0 ? second : first
        guard Int(bitPattern: size) >= state[1] else { return }
        guard Int(bitPattern: UnsafeRawPointer(pthread_self())) == state[2] else { return }
        state[0] += 1
    }

    /// Runs `body` with the hook installed. Returns nil when this platform does not
    /// export the hook, so the caller fails loudly rather than reading a silent zero.
    static func count(
        allocationsOfAtLeast threshold: Int,
        during body: () -> Void
    ) -> Int? {
        // RTLD_DEFAULT.
        guard let slot = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")
        else { return nil }
        let hook = slot.assumingMemoryBound(to: MallocEventLogger?.self)

        state[0] = 0
        state[1] = threshold
        state[2] = Int(bitPattern: UnsafeRawPointer(pthread_self()))
        let previous = hook.pointee
        hook.pointee = logger
        body()
        hook.pointee = previous
        return state[0]
    }
}
