// Socket-level coverage for the bounded flush of queued connection writes: replies handed
// to the flush are in the kernel when it returns, and a peer that stopped reading cannot
// hold it past its bound.
import Foundation
import Testing
import DanTermProtocol
import Darwin
@testable import DanTermSupport

/// How long a wait in this file may take before it declares the code under test hung.
///
/// A hang guard, not a threshold: no assertion turns on how fast the flush drains, so the
/// only requirement is that a passing run cannot approach it and that it fires before the
/// suite's time-limit backstop.
private let hangGuardSeconds = 30.0
private let hangGuardMilliseconds = Int32(hangGuardSeconds * 1000)

/// The one flush bound in this file that is meant to expire: the wedged-peer test learns
/// what it needs precisely because no byte moves before this runs out. Kept far below the
/// hang guard so the test spends its time on assertions, not on waiting.
private let expiringFlushBoundSeconds = 0.2

@Suite(.timeLimit(.minutes(1)))
struct IpcConnectionFlushTests {
    @Test("queued replies are readable by their peers once the flush returns")
    func flushedRepliesAreReadableWithoutWaiting() throws {
        // Intent: every write queued on the given connections before the flush is in the
        //   kernel -- readable by the peer with no further waiting -- when the flush
        //   returns true.
        // Why it exists: writes run asynchronously on each connection's serial write
        //   queue, so without a flush a process can exit between enqueueing a reply and
        //   the kernel taking its bytes, and the peer nondeterministically loses it.
        // Scenario: spec-first, shaped by orderly quit -- the shutdown drain writes one
        //   explanatory error per pending request, then the app must not close the
        //   sockets until those replies are out.
        let first = try socketPair()
        let second = try socketPair()
        let connections = [
            IpcConnection(fileDescriptor: first.connection),
            IpcConnection(fileDescriptor: second.connection),
        ]
        defer {
            connections.forEach { $0.forceClose() }
            Darwin.close(first.peer)
            Darwin.close(second.peer)
        }

        for connection in connections {
            connection.writeErrorResponse(
                id: .string("R-\(connection.id.uuidString)"),
                code: -32603,
                message: "application shut down before the request completed"
            )
        }

        let flushed = IpcConnection.flushQueuedWrites(
            on: connections,
            within: hangGuardSeconds
        )

        #expect(flushed)
        for (connection, peer) in zip(connections, [first.peer, second.peer]) {
            let reply = try JSONDecoder().decode(
                JsonRpcResponse.self,
                from: readDeliveredLine(from: peer)
            )
            #expect(reply.id == .string("R-\(connection.id.uuidString)"))
            #expect(reply.error?.code == -32603)
        }
    }

    @Test("a peer that stopped reading a full backlog does not hold the flush past its bound")
    func wedgedPeerCannotHoldTheFlush() throws {
        // Intent: when a peer has stopped reading and its socket backlog is full, the
        //   flush returns false at its bound instead of waiting on the parked write.
        // Why it exists: the flush sits on the quit path, where an unbounded wait on a
        //   wedged peer would turn one stuck client into an app that never exits.
        // Scenario: spec-first -- a client hangs without closing its socket while a
        //   multi-megabyte write has filled the shrunken send buffer.
        let descriptors = try socketPair()
        var sendBufferBytes: Int32 = 4_096
        setsockopt(
            descriptors.connection,
            SOL_SOCKET,
            SO_SNDBUF,
            &sendBufferBytes,
            socklen_t(MemoryLayout<Int32>.size)
        )
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        defer {
            connection.forceClose()
            Darwin.close(descriptors.peer)
        }

        connection.writeNotification(
            method: Methods.paneTapeEvent,
            params: JSONValue.object([
                "record": .string(String(repeating: "x", count: 4_000_000)),
            ])
        )
        // The parked write announces itself by the bytes that did fit; only then is the
        // flush provably waiting on a wedged peer rather than an empty queue.
        guard waitForReadable(descriptors.peer, timeout: hangGuardMilliseconds) else {
            throw POSIXError(.ETIMEDOUT)
        }

        let flushed = IpcConnection.flushQueuedWrites(
            on: [connection],
            within: expiringFlushBoundSeconds
        )

        #expect(flushed == false)
    }

    private func socketPair() throws -> (connection: Int32, peer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }

    /// Reads one line the kernel already holds for the peer, without waiting.
    ///
    /// Not waiting is the point: the claim under test is that a returned flush means the
    /// bytes are already there, so any blocking here would mask exactly the bug the
    /// caller asserts against. The descriptor goes non-blocking and one read must carry
    /// the complete line.
    private func readDeliveredLine(from descriptor: Int32) throws -> Data {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var line = Data(buffer.prefix(count))
        guard line.last == 0x0A else { throw POSIXError(.EBADMSG) }
        line.removeLast()
        return line
    }

    /// Blocks until the descriptor has a byte pending, and reports whether one arrived
    /// before the deadline. Guards the one read in this file that must wait: proving the
    /// wedged write actually started.
    private func waitForReadable(_ descriptor: Int32, timeout: Int32) -> Bool {
        while true {
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&readiness, 1, timeout)
            if ready < 0 && errno == EINTR { continue }
            return ready > 0
        }
    }
}
