// Socket-level coverage for ordered notification writes and their completion signal.
import Foundation
import Testing
import DanTermProtocol
import Darwin
@testable import DanTermSupport

struct IpcConnectionWriteTests {
    @Test("real socket stream orders start, notifications, end, and close")
    func realSocketStreamOrdersEveryFrame() throws {
        // Intent: production framing flushes the start reply before ordered stream records,
        //   then flushes the end record before closing the socket.
        // Why it exists: unit tests of record construction and socket writes cannot catch a
        //   missing or reordered handoff between those seams.
        // Scenario: a local client follows one pane through an event, a gap, and pane close.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let requestId = UUID()
        let closed = ConnectionCloseProbe()
        defer { Darwin.close(descriptors.peer) }

        connection.writeHello(appVersion: "test")
        connection.startReading(
            onRequest: { request, connection in
                connection.rememberRequest(reqId: requestId, rpcId: request.id)
                connection.writeSuccess(
                    reqId: requestId,
                    result: .object(["kind": .string("start")])
                ) { succeeded in
                    guard succeeded else { return }
                    for record in [
                        JSONValue.object(["kind": .string("event"), "sequence": .number(1)]),
                        .object(["kind": .string("gap"), "droppedEventCount": .number(2)]),
                    ] {
                        connection.writeNotification(
                            method: Methods.paneTapeEvent,
                            params: .object([
                                "subscription": .string("S1"),
                                "record": record,
                            ])
                        )
                    }
                    connection.writeNotification(
                        method: Methods.paneTapeEvent,
                        params: .object([
                            "subscription": .string("S1"),
                            "record": .object([
                                "kind": .string("end"),
                                "reason": .string("pane-closed"),
                            ]),
                        ]),
                        closeAfterWrite: true
                    )
                }
            },
            onClose: { connection in closed.record(connection.id) }
        )

        let hello = try JSONDecoder().decode(
            JsonRpcRequest.self,
            from: readIpcLine(from: descriptors.peer)
        )
        #expect(hello.method == Methods.hello)
        try writeIpcLine(
            JsonRpcRequest(id: .string("R1"), method: IpcRequestMethod.paneTape.rawValue),
            to: descriptors.peer
        )

        let start = try JSONDecoder().decode(
            JsonRpcResponse.self,
            from: readIpcLine(from: descriptors.peer)
        )
        #expect(start.id == .string("R1"))
        #expect(start.result?["kind"] == .string("start"))

        var kinds: [String] = []
        for _ in 0..<3 {
            let notification = try JSONDecoder().decode(
                JsonRpcRequest.self,
                from: readIpcLine(from: descriptors.peer)
            )
            #expect(notification.id == nil)
            #expect(notification.method == Methods.paneTapeEvent)
            kinds.append(notification.params?["record"]?["kind"]?.asString ?? "")
        }
        #expect(kinds == ["event", "gap", "end"])
        #expect(readByte(from: descriptors.peer) == 0)
        #expect(closed.wait() == connection.id)
    }

    @Test("client disconnect reaches the production close callback")
    func clientDisconnectReportsConnectionClose() throws {
        // Intent: EOF from a client reaches the callback that removes owned subscriptions.
        // Why it exists: without the callback, every disconnected follow leaks polling work.
        // Scenario: an agent interrupts a live follow while the app keeps running.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let closed = ConnectionCloseProbe()
        connection.startReading(
            onRequest: { _, _ in },
            onClose: { connection in closed.record(connection.id) }
        )

        Darwin.close(descriptors.peer)
        #expect(closed.wait() == connection.id)
    }

    @Test("notification completion reports a fully flushed JSON-RPC line")
    func notificationCompletionReportsFlush() async throws {
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        defer {
            connection.close()
            Darwin.close(descriptors.peer)
        }

        // Awaiting rather than blocking keeps the main queue free to deliver the completion.
        // The line waits in the socket buffer meanwhile, so it is still there to read after.
        let succeeded: Bool = await withCheckedContinuation { continuation in
            connection.writeNotification(
                method: Methods.paneTapeEvent,
                params: .object(["subscription": .string("S1")]),
                completion: { continuation.resume(returning: $0) }
            )
        }

        let line = try readIpcLine(from: descriptors.peer)
        let request = try JSONDecoder().decode(JsonRpcRequest.self, from: line)
        #expect(request.id == nil)
        #expect(request.method == Methods.paneTapeEvent)
        #expect(request.params?["subscription"] == .string("S1"))
        #expect(succeeded)
    }

    @Test("notification completion reports a failed socket write")
    func notificationCompletionReportsFailure() async throws {
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        Darwin.close(descriptors.peer)
        defer { connection.close() }

        let succeeded: Bool = await withCheckedContinuation { continuation in
            connection.writeNotification(
                method: Methods.paneTapeEvent,
                params: .object([:]),
                completion: { continuation.resume(returning: $0) }
            )
        }

        #expect(succeeded == false)
    }

    // Runs on the main actor, like every production caller of these completions. That is also
    // what makes the ordering assertion below decidable: the completion is delivered by a
    // `DispatchQueue.main.async`, so it cannot run until this body reaches its first
    // suspension. Off the main actor the two observations race, and a loaded machine sees
    // the completion first even though nothing is wrong.
    @MainActor
    @Test("a completion on the already-closed path still lands on main, after the call returns")
    func closedPathCompletionIsAsynchronousAndOnMain() async throws {
        // Intent: writing to a closed connection reports `false` on the main thread, and only
        //   after the write call has returned -- the same as every other completion path.
        // Why it exists: this exit used to call the completion inline, on whatever thread asked
        //   for the write, while the success path reported from the writer queue. One callback
        //   with two delivery contexts is the re-entrancy trap: a caller that reads its own
        //   state after the write call can have that state already mutated by its completion.
        //   Uniform main delivery is what closes it, and this is the path that proves it.
        // Scenario: spec-first. The connection is closed before the write is attempted.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        defer { Darwin.close(descriptors.peer) }
        connection.close()
        let order = DeliveryOrderProbe()

        let onMainThread: Bool = await withCheckedContinuation { continuation in
            connection.writeNotification(
                method: Methods.paneTapeEvent,
                params: .object([:]),
                completion: { _ in
                    order.record(.completed)
                    continuation.resume(returning: Thread.isMainThread)
                }
            )
            order.record(.returned)
        }

        #expect(order.recorded == [.returned, .completed],
                "the completion must not run before the write call returns")
        #expect(onMainThread, "every completion path must report on the main thread")
    }

    @Test("a terminator never overtakes a batch already enqueued for the same stream")
    func terminatorFollowsTheBatchEnqueuedBeforeIt() throws {
        // Intent: records handed to the follow write helper reach the socket in the order
        //   they were handed over, and ending a stream leaves the socket writable.
        // Why it exists: the follow writes used to hop through the concurrent global queue,
        //   one dispatch per batch, so a pane-close terminator could reach the socket ahead
        //   of a batch prepared before it -- making the terminal record non-terminal. Ending
        //   the stream also used to close the socket, cutting off every other stream and
        //   request the client had on it.
        // Scenario: a pane closes in the same runloop turn that a prepared batch is delivered.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let subscriptionId = UUID()
        defer {
            connection.close()
            Darwin.close(descriptors.peer)
        }

        writePaneTapeRecords(
            [
                .object(["kind": .string("event"), "sequence": .number(0)]),
                .object(["kind": .string("event"), "sequence": .number(1)]),
            ],
            connection: connection,
            subscriptionId: subscriptionId
        )
        writePaneTapeRecords(
            [makePaneTapeEndRecord(reason: .paneClosed)],
            connection: connection,
            subscriptionId: subscriptionId
        )
        // A sibling stream on the same socket must still be served after the `end`.
        let siblingId = UUID()
        writePaneTapeRecords(
            [.object(["kind": .string("event"), "sequence": .number(7)])],
            connection: connection,
            subscriptionId: siblingId
        )

        var received: [(subscription: String, kind: String)] = []
        for _ in 0..<4 {
            let notification = try JSONDecoder().decode(
                JsonRpcRequest.self,
                from: readIpcLine(from: descriptors.peer)
            )
            #expect(notification.method == Methods.paneTapeEvent)
            received.append((
                notification.params?["subscription"]?.asString ?? "",
                notification.params?["record"]?["kind"]?.asString ?? ""
            ))
        }

        #expect(received.map(\.kind) == ["event", "event", "end", "event"])
        #expect(received.map(\.subscription) == [
            subscriptionId.uuidString,
            subscriptionId.uuidString,
            subscriptionId.uuidString,
            siblingId.uuidString,
        ])
    }

    @Test("a peer that never answers fails the read instead of parking it")
    func silentPeerFailsTheRead() throws {
        // Intent: both socket reads this suite makes give up on a deadline.
        // Why it exists: `Darwin.read` on a socket nobody writes to and nobody closes
        //   parks the thread for good. It is a synchronous syscall, so a `.timeLimit`
        //   cannot unwind it either -- the lane keeps the process alive until an
        //   outside deadline kills it, and reports nothing about which test stopped.
        // Scenario: the connection under test writes a short frame or drops a reply,
        //   which is what every assertion below the read is there to catch.
        let descriptors = try socketPair()
        defer {
            Darwin.close(descriptors.connection)
            Darwin.close(descriptors.peer)
        }

        let started = ContinuousClock().now
        #expect(throws: (any Error).self) { try readIpcLine(from: descriptors.peer) }
        #expect(readByte(from: descriptors.peer) < 0)
        let elapsed = ContinuousClock().now - started

        #expect(elapsed < .seconds(30), "the silent reads took \(elapsed)")
    }

    private func socketPair() throws -> (connection: Int32, peer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }

    private func readIpcLine(from descriptor: Int32) throws -> Data {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            guard waitForReadable(descriptor) else { throw POSIXError(.ETIMEDOUT) }
            let count = Darwin.read(descriptor, &byte, 1)
            guard count == 1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if byte == 0x0A { return Data(bytes) }
            bytes.append(byte)
        }
    }

    private func writeIpcLine<T: Encodable>(_ value: T, to descriptor: Int32) throws {
        let line = try encodeIpcLine(value)
        let succeeded = line.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            var written = 0
            while written < line.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    line.count - written
                )
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }
                written += result
            }
            return true
        }
        guard succeeded else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Reads one byte, or reports -1 when the peer neither writes nor closes in time.
    ///
    /// Callers assert on EOF (a zero-length read), so the case this guards against --
    /// a peer that stays open and silent -- is the one they exist to catch.
    private func readByte(from descriptor: Int32) -> Int {
        guard waitForReadable(descriptor) else { return -1 }
        var byte: UInt8 = 0
        return Darwin.read(descriptor, &byte, 1)
    }

    /// Blocks until the descriptor has a byte or a close pending, and reports whether
    /// one arrived before the deadline.
    ///
    /// Every read in this suite goes through here. A bare `Darwin.read` on a socket
    /// the connection under test never answers parks the thread for good, and no
    /// `.timeLimit` can unwind a synchronous syscall -- the whole lane then dies to an
    /// outside deadline, naming no test. The bound matches the close probe below, so a
    /// stalled test fails in seconds and says which read stalled.
    private func waitForReadable(_ descriptor: Int32, timeout: Int32 = 2_000) -> Bool {
        while true {
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&readiness, 1, timeout)
            if ready < 0 && errno == EINTR { continue }
            return ready > 0
        }
    }
}

/// Records the order of two events -- the write call returning, and its completion running --
/// under one lock, so a re-entrancy claim can be made without racing the two observations.
private final class DeliveryOrderProbe: @unchecked Sendable {
    enum Event { case returned, completed }

    private let lock = NSLock()
    private var events: [Event] = []

    func record(_ event: Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var recorded: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class ConnectionCloseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var connectionId: UUID?

    func record(_ connectionId: UUID) {
        lock.lock()
        self.connectionId = connectionId
        lock.unlock()
        semaphore.signal()
    }

    func wait() -> UUID? {
        guard semaphore.wait(timeout: .now() + 2) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return connectionId
    }
}
