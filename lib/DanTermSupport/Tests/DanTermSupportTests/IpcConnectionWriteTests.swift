// Socket-level coverage for ordered notification writes and their completion signal.
import Foundation
import Testing
import DanTermProtocol
import Darwin
@testable import DanTermSupport

/// How long a read in this file waits before it declares the connection hung.
///
/// This is a hang guard, not a threshold: no assertion here turns on how fast a frame
/// arrives, so the only requirement is that a passing run cannot approach it and that it
/// fires before the suite's time-limit backstop, so the failure names the read.
private let hangGuardSeconds = 30.0
private let hangGuardMilliseconds = Int32(hangGuardSeconds * 1000)

/// How long the one test that proves the reads give up is willing to spend proving it.
///
/// Unlike the hang guard, this one is meant to expire twice over, so keep it short. It is
/// supplied explicitly at that test's call sites rather than lowering the guard for
/// everyone, because every other read here expects an answer.
private let silenceProbeMilliseconds: Int32 = 500

@Suite(.timeLimit(.minutes(1)))
struct IpcConnectionWriteTests {
    @Test("connection rejection writes its stable notification then closes")
    func connectionRejectionWritesThenCloses() throws {
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        defer { Darwin.close(descriptors.peer) }

        connection.writeRejected(.connectionLimit, livenessBound: .standard)

        let notification = try JSONDecoder().decode(
            JsonRpcRequest.self,
            from: readIpcLine(from: descriptors.peer)
        )
        #expect(
            notification
                == IpcConnectionRejectionReason.connectionLimit.notification(
                    livenessBound: .standard
                )
        )
        #expect(readByte(from: descriptors.peer) == 0)
    }

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

        connection.writeHello(appVersion: "test", livenessBound: .standard)
        connection.startReading { event, connection in
            switch event {
            case .request(let request):
                connection.rememberRequest(reqId: requestId, rpcId: request.id)
                connection.writeSuccess(
                    reqId: requestId,
                    result: JSONValue.object(["kind": .string("start")])
                ) { succeeded in
                    guard succeeded else { return }
                    for record in [
                        JSONValue.object(["kind": .string("event"), "sequence": .number(1)]),
                        .object(["kind": .string("gap"), "droppedEventCount": .number(2)]),
                    ] {
                        connection.writeNotification(
                            method: Methods.paneTapeEvent,
                            params: JSONValue.object([
                                "subscription": .string("S1"),
                                "record": record,
                            ])
                        )
                    }
                    connection.writeNotification(
                        method: Methods.paneTapeEvent,
                        params: JSONValue.object([
                            "subscription": .string("S1"),
                            "record": .object([
                                "kind": .string("end"),
                                "reason": .string("pane-closed"),
                            ]),
                        ]),
                        closeAfterWrite: true
                    )
                }
            case .malformedRequest:
                break
            case .closed:
                closed.record(connection.id)
            }
        }

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
        #expect(try closed.wait() == connection.id)
    }

    @Test("client disconnect reaches the production close callback")
    func clientDisconnectReportsConnectionClose() throws {
        // Intent: EOF from a client reaches the callback that removes owned subscriptions.
        // Why it exists: without the callback, every disconnected follow leaks polling work.
        // Scenario: an agent interrupts a live follow while the app keeps running.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let closed = ConnectionCloseProbe()
        connection.startReading { event, connection in
            if case .closed = event { closed.record(connection.id) }
        }

        Darwin.close(descriptors.peer)
        #expect(try closed.wait() == connection.id)
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
                params: JSONValue.object(["subscription": .string("S1")]),
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
                params: JSONValue.object([:]),
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
                params: JSONValue.object([:]),
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
            [eventRecord(sequence: 0), eventRecord(sequence: 1)],
            connection: connection,
            subscriptionId: subscriptionId
        )
        writePaneTapeRecords(
            [PaneTapeOutgoingRecord<JSONValue>.end(reason: .paneClosed)],
            connection: connection,
            subscriptionId: subscriptionId
        )
        // A sibling stream on the same socket must still be served after the `end`.
        let siblingId = UUID()
        writePaneTapeRecords(
            [eventRecord(sequence: 7)],
            connection: connection,
            subscriptionId: siblingId
        )

        var received: [(subscription: String, kinds: [String])] = []
        for _ in 0..<3 {
            let notification = try JSONDecoder().decode(
                JsonRpcRequest.self,
                from: readIpcLine(from: descriptors.peer)
            )
            #expect(notification.method == Methods.paneTapeEvent)
            received.append((
                notification.params?["subscription"]?.asString ?? "",
                recordKinds(of: notification)
            ))
        }

        #expect(received.map(\.kinds) == [["event", "event"], ["end"], ["event"]])
        #expect(received.map(\.subscription) == [
            subscriptionId.uuidString,
            subscriptionId.uuidString,
            siblingId.uuidString,
        ])
    }

    @Test("a delivered batch reaches the wire as one notification carrying its records in order")
    func batchTravelsAsOneNotification() throws {
        // Intent: however many records a batch holds, it costs one notification, and the
        //   records inside it keep the order they were handed over in.
        // Why it exists: a batch used to be written one notification per record, restating
        //   the subscription and queueing a write each time. The count of records and the
        //   count of envelopes could then differ, which is exactly what one envelope per
        //   batch removes.
        // Scenario: a busy pane delivers a gap followed by three events in one batch.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let subscriptionId = UUID()
        defer {
            connection.close()
            Darwin.close(descriptors.peer)
        }

        writePaneTapeRecords(
            [
                .gap(PaneTapeGapRecord(
                    droppedEventCount: 2,
                    droppedFeedBytes: 3,
                    droppedWriteBytes: 4
                )),
                eventRecord(sequence: 5),
                eventRecord(sequence: 6),
                eventRecord(sequence: 7),
            ],
            connection: connection,
            subscriptionId: subscriptionId
        )

        let notification = try JSONDecoder().decode(
            JsonRpcRequest.self,
            from: readIpcLine(from: descriptors.peer)
        )
        #expect(notification.method == Methods.paneTapeEvent)
        #expect(notification.params?["subscription"]?.asString == subscriptionId.uuidString)
        #expect(recordKinds(of: notification) == ["gap", "event", "event", "event"])
        #expect(recordSequences(of: notification) == [5, 6, 7])
    }

    @Test("a batch too large for one line splits at record boundaries and keeps its order")
    func oversizedBatchSplitsWithinTheLineBound() throws {
        // Intent: a batch whose line would pass the reader's framing bound arrives as more
        //   than one notification, each of them a line the reader accepts, and together they
        //   carry every record once and in order.
        // Why it exists: sync records are chunked at a quarter of the bound, so a batch of
        //   several of them exceeds it. Without a split the reader would refuse the line and
        //   the whole batch would vanish from the stream.
        // Scenario: a reconstructible follow opens with a multi-megabyte state transfer.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let subscriptionId = UUID()
        let chunkBytes = IpcLineFramer.maxLineBytes / 4
        defer {
            connection.close()
            Darwin.close(descriptors.peer)
        }

        // The write is queued, not performed here, so the reads below drain the socket while
        // the write queue is still filling it.
        writePaneTapeRecords(
            (0..<6).map { chunkyEventRecord(sequence: UInt64($0), payloadBytes: chunkBytes) },
            connection: connection,
            subscriptionId: subscriptionId
        )

        // Chunked reads, unlike the byte-at-a-time reader the small fixtures use: this batch
        // is tens of megabytes, and one syscall per byte is what makes a test slow enough to
        // approach its own hang guard.
        let reader = BufferedLineReader(descriptor: descriptors.peer)
        var notificationCount = 0
        var sequences: [Double] = []
        while sequences.count < 6 {
            let line = try reader.next()
            let notification = try JSONDecoder().decode(JsonRpcRequest.self, from: line)
            notificationCount += 1
            // The line the reader measures is the one without its newline, which the framer
            // strips, so the bound applies to what this decode was handed.
            #expect(line.count <= IpcLineFramer.maxLineBytes)
            #expect(notification.params?["subscription"]?.asString == subscriptionId.uuidString)
            #expect(recordKinds(of: notification).allSatisfy { $0 == "event" })
            sequences += recordSequences(of: notification)
        }

        #expect(notificationCount > 1, "a batch over the line bound must split")
        #expect(sequences == [0, 1, 2, 3, 4, 5])
    }

    @Test("a batch reports its flush, and a record that will not encode fails the whole batch")
    func batchCompletionReportsEveryRecord() async throws {
        // Intent: the completion handed to a batch answers for the batch: true once every
        //   record is out, false when any record in it failed to encode.
        // Why it exists: only the last record of a batch used to carry a completion, so a
        //   failure on any earlier record was invisible and the caller advanced its cursor
        //   past records the peer never received.
        // Scenario: a recorded event whose payload cannot be encoded sits in the middle of
        //   an otherwise ordinary batch.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        defer {
            connection.close()
            Darwin.close(descriptors.peer)
        }

        let flushed: Bool = await withCheckedContinuation { continuation in
            writePaneTapeRecords(
                [eventRecord(sequence: 1), eventRecord(sequence: 2)],
                connection: connection,
                subscriptionId: UUID(),
                completion: { continuation.resume(returning: $0) }
            )
        }
        #expect(flushed)
        _ = try readIpcLine(from: descriptors.peer)

        let failed: Bool = await withCheckedContinuation { continuation in
            writePaneTapeRecords(
                [
                    probeEventRecord(sequence: 3, event: .encodable),
                    probeEventRecord(sequence: 4, event: .refusesToEncode),
                    probeEventRecord(sequence: 5, event: .encodable),
                ],
                connection: connection,
                subscriptionId: UUID(),
                completion: { continuation.resume(returning: $0) }
            )
        }
        #expect(failed == false)
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
        #expect(throws: (any Error).self) {
            try readIpcLine(from: descriptors.peer, timeout: silenceProbeMilliseconds)
        }
        #expect(readByte(from: descriptors.peer, timeout: silenceProbeMilliseconds) < 0)
        let elapsed = ContinuousClock().now - started

        // A generous bound that only proves the two reads terminated. Nothing here turns
        // on how close to the supplied deadline they came.
        #expect(elapsed < .seconds(30), "the silent reads took \(elapsed)")
    }

    @Test("a malformed envelope reports its readable raw method")
    func malformedEnvelopeReportsMethod() throws {
        // The reply this line earns is written by the connection's owner, not here, so
        // the wire assertion for it lives beside that owner in the app tests.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        let malformed = MalformedRequestProbe()
        defer {
            connection.close()
            Darwin.close(descriptors.peer)
        }
        connection.startReading { event, _ in
            if case .malformedRequest(let method) = event { malformed.record(method) }
        }

        let line = Data((#"{"jsonrpc":2,"id":1,"method":"pane.read","params":{}}"# + "\n").utf8)
        _ = line.withUnsafeBytes { Darwin.write(descriptors.peer, $0.baseAddress, $0.count) }

        #expect(try malformed.wait() == "pane.read")
    }

    @Test("an IPC line is encoded on the connection's write queue, not the caller's")
    @MainActor
    func writeEncodesOnTheConnectionWriteQueue() throws {
        // Intent: the JSON pass for a write happens on the connection's serial write queue.
        // Why it exists: a followed pane tape writes continuously from the main actor, and
        //   its opening records carry multi-megabyte sync chunks. Encoding inline in the
        //   write call charged that whole cost to whichever context asked for the write.
        // Scenario: the main actor queues one notification whose params report, from inside
        //   `encode(to:)`, which queue and thread ran them.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        defer { Darwin.close(descriptors.peer) }
        let probe = EncodingContextProbe()

        connection.writeNotification(
            method: "probe",
            params: EncodingContextReporter(probe: probe)
        )

        _ = try readIpcLine(from: descriptors.peer)
        let context = try probe.wait()
        // The call was made on the main actor, so a label naming this connection also rules
        // out an inline encode: inline would have reported the main queue.
        #expect(context.queueLabel.contains(connection.id.uuidString))
        #expect(context.onMainThread == false)
    }

    @Test("a value that fails to encode reports failure and leaves the connection open")
    func failedEncodeReportsThroughItsCompletion() async throws {
        // Intent: an encode that throws reports false through the completion, and the
        //   connection keeps serving whatever else is on it.
        // Why it exists: encoding moved onto the write queue, past the point where a caller
        //   could see a throw. The completion is now the only channel that can carry it, and
        //   a silent drop would leave a follower waiting on a record that will never come.
        // Scenario: one notification whose params refuse to encode, then a second that does.
        let descriptors = try socketPair()
        let connection = IpcConnection(fileDescriptor: descriptors.connection)
        defer { Darwin.close(descriptors.peer) }

        let reported: Bool = try await withCheckedThrowingContinuation { continuation in
            connection.writeNotification(method: "probe", params: UnencodableParams()) {
                continuation.resume(returning: $0)
            }
        }
        #expect(reported == false)

        connection.writeNotification(
            method: Methods.paneTapeEvent,
            params: JSONValue.object(["subscription": .string("S1")])
        )
        let survivor = try JSONDecoder().decode(
            JsonRpcRequest.self,
            from: readIpcLine(from: descriptors.peer)
        )
        #expect(survivor.method == Methods.paneTapeEvent)
    }

    /// The `kind` of every record one notification carries, in wire order.
    private func recordKinds(of notification: JsonRpcRequest) -> [String] {
        (notification.params?["records"]?.asArray ?? []).map { $0["kind"]?.asString ?? "" }
    }

    /// The sequence stated by every record that states one, in wire order.
    private func recordSequences(of notification: JsonRpcRequest) -> [Double] {
        (notification.params?["records"]?.asArray ?? []).compactMap { $0["sequence"]?.asNumber }
    }

    private func socketPair() throws -> (connection: Int32, peer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }

    private func readIpcLine(
        from descriptor: Int32,
        timeout: Int32 = hangGuardMilliseconds
    ) throws -> Data {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            guard waitForReadable(descriptor, timeout: timeout) else {
                throw POSIXError(.ETIMEDOUT)
            }
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
    private func readByte(from descriptor: Int32, timeout: Int32 = hangGuardMilliseconds) -> Int {
        guard waitForReadable(descriptor, timeout: timeout) else { return -1 }
        var byte: UInt8 = 0
        return Darwin.read(descriptor, &byte, 1)
    }

    /// Blocks until the descriptor has a byte or a close pending, and reports whether
    /// one arrived before the deadline.
    ///
    /// Every read in this suite goes through here. A bare `Darwin.read` on a socket
    /// the connection under test never answers parks the thread for good, and no
    /// `.timeLimit` can unwind a synchronous syscall -- the whole lane then dies to an
    /// outside deadline, naming no test. Callers pass the hang guard unless they are the
    /// one test proving the reads give up, which supplies a deadline meant to expire.
    private func waitForReadable(_ descriptor: Int32, timeout: Int32) -> Bool {
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

    /// Throws rather than returning `nil`, so giving up is never mistaken for a close
    /// that named a different connection.
    func wait() throws -> UUID? {
        guard semaphore.wait(timeout: .now() + hangGuardSeconds) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        lock.lock()
        defer { lock.unlock() }
        return connectionId
    }
}

/// One tape record whose only interesting fact is its order on the socket.
private func eventRecord(sequence: UInt64) -> PaneTapeOutgoingRecord<JSONValue> {
    .event(PaneTapeEventRecord(
        sequence: sequence,
        elapsedNanoseconds: sequence,
        originElapsedNanoseconds: nil,
        byteOffset: nil,
        byteLength: nil,
        event: .object(["type": .string("feed")])
    ))
}

/// Reads whole lines off a descriptor in chunks, through the production framer.
///
/// The suite's own reader takes one byte per syscall, which is fine for a short fixture and
/// far too slow for a multi-megabyte one. Every read waits on the same hang guard, so a
/// connection that stops writing names this reader rather than parking the lane.
private final class BufferedLineReader {
    private let descriptor: Int32
    private var framer = IpcLineFramer()
    private var pending: [Data] = []

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func next() throws -> Data {
        while pending.isEmpty {
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&readiness, 1, hangGuardMilliseconds)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw POSIXError(.ETIMEDOUT) }

            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            for event in framer.append(Data(buffer.prefix(count))) {
                guard case .line(let line) = event else {
                    throw POSIXError(.EMSGSIZE)
                }
                pending.append(line)
            }
        }
        return pending.removeFirst()
    }
}

/// One tape record big enough that a few of them pass the reader's line bound together.
private func chunkyEventRecord(
    sequence: UInt64,
    payloadBytes: Int
) -> PaneTapeOutgoingRecord<JSONValue> {
    .event(PaneTapeEventRecord(
        sequence: sequence,
        elapsedNanoseconds: sequence,
        originElapsedNanoseconds: nil,
        byteOffset: nil,
        byteLength: payloadBytes,
        event: .object([
            "type": .string("feed"),
            "base64": .string(String(repeating: "A", count: payloadBytes)),
        ])
    ))
}

/// A recorded event that either encodes or refuses to, so one batch can hold both.
private enum ProbeEvent: Encodable, Sendable {
    struct EncodeRefused: Error {}

    case encodable
    case refusesToEncode

    func encode(to encoder: any Encoder) throws {
        guard case .encodable = self else { throw EncodeRefused() }
        var container = encoder.singleValueContainer()
        try container.encode("probe")
    }
}

/// One tape record carrying a probe event, so a test can put a record that will not encode
/// beside records that will.
private func probeEventRecord(
    sequence: UInt64,
    event: ProbeEvent
) -> PaneTapeOutgoingRecord<ProbeEvent> {
    .event(PaneTapeEventRecord(
        sequence: sequence,
        elapsedNanoseconds: sequence,
        originElapsedNanoseconds: nil,
        byteOffset: nil,
        byteLength: nil,
        event: event
    ))
}

/// Params that always fail to encode, so a test can reach the write queue's encode failure.
private struct UnencodableParams: Encodable, Sendable {
    struct EncodeRefused: Error {}

    func encode(to encoder: any Encoder) throws {
        throw EncodeRefused()
    }
}

/// Where one `encode(to:)` call ran, captured from inside the encode itself.
///
/// Naming the execution context is the only way to prove the encode moved off the caller:
/// the bytes on the socket look the same either way.
private struct EncodingContext: Sendable {
    let queueLabel: String
    let onMainThread: Bool
}

/// Params whose encoding reports its own execution context instead of carrying data.
private struct EncodingContextReporter: Encodable, Sendable {
    let probe: EncodingContextProbe

    func encode(to encoder: any Encoder) throws {
        probe.record(EncodingContext(
            queueLabel: String(cString: __dispatch_queue_get_label(nil)),
            onMainThread: Thread.isMainThread
        ))
        var container = encoder.singleValueContainer()
        try container.encode("probe")
    }
}

/// Holds the one context an `EncodingContextReporter` observed until a test can read it.
private final class EncodingContextProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var context: EncodingContext?

    func record(_ context: EncodingContext) {
        lock.lock()
        self.context = context
        lock.unlock()
        semaphore.signal()
    }

    /// Throws rather than returning `nil`, so an encode that never ran is never mistaken for
    /// one that ran in an unnamed context.
    func wait() throws -> EncodingContext {
        guard semaphore.wait(timeout: .now() + hangGuardSeconds) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let context else { throw POSIXError(.ETIMEDOUT) }
        return context
    }
}

private final class MalformedRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var method: String?

    func record(_ method: String?) {
        lock.lock()
        self.method = method
        lock.unlock()
        semaphore.signal()
    }

    /// Throws rather than returning `nil`, so giving up is never mistaken for a request
    /// the connection reported with no method at all.
    func wait() throws -> String? {
        guard semaphore.wait(timeout: .now() + hangGuardSeconds) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        lock.lock()
        defer { lock.unlock() }
        return method
    }
}
