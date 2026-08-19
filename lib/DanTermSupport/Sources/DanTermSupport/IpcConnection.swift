// Unix-socket connection lifecycle and JSON-RPC response writing for DanTerm IPC; line framing
// lives in DanTermProtocol (IpcLineFramer).
//
// Reads leave through one callback carrying one ordered event sequence, and the reader waits
// for each event before it reads on. What the owner does with an event is its own business;
// what this file guarantees is that it never learns about two at once.
//
// Writes are queued as values, not as bytes: the connection's serial write queue both encodes
// the line and pushes it out, so no caller -- least of all the main actor -- pays for a JSON
// pass it asked for. Completions are delivered on the main queue, always: the app state
// a completion feeds lives on the main actor, so the completions are typed `@MainActor` and every
// exit routes through `deliver`. The uniformity is the point -- an early exit that reported
// inline would hand one callback two delivery contexts, and re-enter its own caller.
import Foundation
import DanTermProtocol
import Darwin

/// One thing that happened on a connection, in the order the bytes for it arrived.
///
/// It is one type with one delivery callback because the reader produces one ordered
/// sequence. Separate callbacks per kind invited separate routings, and out-of-order
/// handling followed; with a single sequence there is nothing left to reorder.
enum IpcConnectionEvent: Sendable {
    /// A well-formed JSON-RPC envelope.
    case request(JsonRpcRequest)
    /// A line that is not a JSON-RPC envelope, with whatever method name survived it.
    case malformedRequest(rawMethod: String?)
    /// The read loop is done. Emitted exactly once, on every exit, and nothing follows it.
    case closed(IpcConnectionCloseReason)
}

/// Names why a serviced connection ended, so a reader of the audit log can tell a peer
/// that left from one this server stopped waiting for.
///
/// It is exhaustive on purpose: every exit from the read loop names one of these, so no
/// close reaches the log without a stated cause.
enum IpcConnectionCloseReason: String, Sendable {
    /// The peer closed its end of the stream, or the stream failed under it.
    case peerClosed = "peer-closed"
    /// No byte arrived within the advertised silence bound, so the peer is treated as gone.
    case peerSilent = "peer-silent"
    /// The peer sent a line past the framing bound, so the server ended the conversation.
    case oversizedRequest = "oversized-request"
    /// The server itself is going away and is closing what it still holds.
    case serverStopped = "server-stopped"
}

final class IpcConnection: @unchecked Sendable {
    let id: UUID

    private let fd: Int32
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private var pendingResponseIds: [UUID: JSONValue] = [:]
    private var closed = false

    init(id: UUID = UUID(), fileDescriptor: Int32) {
        self.id = id
        self.fd = fileDescriptor
        self.writeQueue = DispatchQueue(label: "danterm.ipc.connection.\(id.uuidString)")
        Self.disableSigPipe(on: fd)
    }

    /// Reads request lines until the peer leaves or, on a connection under the liveness
    /// contract, until the bound passes with no arriving byte.
    ///
    /// A nil `livenessBound` exempts the connection, which is what a local peer gets: it
    /// cannot die without its socket closing, and a local follow may idle forever.
    ///
    /// `onEvent` runs on the reader thread, and the next byte of this connection is not
    /// read until it returns. A handler that hands the event to something asynchronous
    /// must therefore wait for that work before returning: the order the handler acts in
    /// is the wire order only because at most one event exists at a time.
    func startReading(
        livenessBound: IpcLivenessBound? = nil,
        onEvent: @escaping @Sendable (IpcConnectionEvent, IpcConnection) -> Void
    ) {
        if let livenessBound { Self.armReceiveDeadline(livenessBound, on: fd) }
        DispatchQueue.global(qos: .utility).async { [self] in
            var framer = IpcLineFramer()
            var buffer = [UInt8](repeating: 0, count: 4096)
            var reason = IpcConnectionCloseReason.peerClosed

            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    // The armed deadline reports itself as a would-block read, and it is
                    // rearmed by every read that returns data. That makes the silence this
                    // measures byte-level: a line still arriving in pieces keeps feeding it,
                    // and only a stream with nothing at all on it runs out.
                    if livenessBound != nil, errno == EAGAIN || errno == EWOULDBLOCK {
                        reason = .peerSilent
                    }
                    break
                }
                guard count > 0 else { break }

                let data = Data(buffer.prefix(Int(count)))
                for event in framer.append(data) {
                    switch event {
                    case .line(let line):
                        guard !line.isEmpty else { continue }
                        if let request = try? JSONDecoder().decode(
                            JsonRpcRequest.self,
                            from: line
                        ) {
                            onEvent(.request(request), self)
                        } else {
                            let method = try? JSONDecoder().decode(
                                IpcMalformedRequestProbe.self,
                                from: line
                            ).method
                            onEvent(.malformedRequest(rawMethod: method), self)
                        }
                    case .oversized:
                        // The refusal closes the socket once its line is flushed, so this
                        // exit hands the descriptor to the write queue rather than closing
                        // it here and cutting off the explanation.
                        writeErrorResponse(
                            id: .null,
                            code: -32600,
                            message: "request line too large",
                            closeAfterWrite: true
                        )
                        onEvent(.closed(.oversizedRequest), self)
                        return
                    }
                }
            }

            // A reclaimed peer is one that stopped reading too, so its queued writes must
            // not decide when the descriptor goes. A peer that left of its own accord is
            // still owed the answer to the last request it sent.
            if reason == .peerSilent { forceClose() } else { close() }
            onEvent(.closed(reason), self)
        }
    }

    func rememberRequest(reqId: UUID, rpcId: JSONValue?) {
        lock.lock()
        pendingResponseIds[reqId] = rpcId ?? .null
        lock.unlock()
    }

    func writeHello(appVersion: String, livenessBound: IpcLivenessBound) {
        let hello = JsonRpcRequest(
            method: Methods.hello,
            params: IpcHello.params(
                protocolVersion: danTermIpcProtocolVersion,
                appVersion: appVersion,
                livenessBound: livenessBound
            )
        )
        writeLine(hello)
    }

    /// Writes the pre-handshake refusal and closes after its complete line is flushed.
    ///
    /// The bound is the server's current one, and the refusal decides whether to state
    /// it, so every caller supplies it rather than choosing which refusals carry it.
    func writeRejected(_ reason: IpcConnectionRejectionReason, livenessBound: IpcLivenessBound) {
        writeLine(reason.notification(livenessBound: livenessBound), closeAfterWrite: true)
    }

    /// Answers one request with a value that encodes itself, whether that is a `JSONValue` tree
    /// or a typed result such as a pane-tape start record. One signature serves both, so a
    /// typed result pays exactly the one JSON pass the envelope around it pays.
    ///
    /// The value is `Sendable` because it is encoded on the write queue, not here.
    func writeSuccess<Result: Encodable & Sendable>(
        reqId: UUID,
        result: Result,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        guard let rpcId = takeResponseId(reqId) else {
            if let completion { deliver(completion, false) }
            return
        }
        writeLine(
            JsonRpcResponseEnvelope(id: rpcId, result: result),
            completion: completion
        )
    }

    func writeError(reqId: UUID, code: Int, message: String) {
        guard let rpcId = takeResponseId(reqId) else { return }
        writeErrorResponse(id: rpcId, code: code, message: message)
    }

    func writeErrorResponse(
        id: JSONValue?,
        code: Int,
        message: String,
        closeAfterWrite: Bool = false
    ) {
        let response = JsonRpcResponse(
            id: id ?? .null,
            error: JsonRpcError(code: code, message: message)
        )
        writeLine(response, closeAfterWrite: closeAfterWrite)
    }

    /// Writes a complete typed protocol error, including stable machine-readable data.
    func writeErrorResponse(
        id: JSONValue?,
        error: JsonRpcError,
        closeAfterWrite: Bool = false
    ) {
        writeLine(
            JsonRpcResponse(id: id ?? .null, error: error),
            closeAfterWrite: closeAfterWrite
        )
    }

    /// Queues one server-initiated JSON-RPC notification after earlier writes on this socket.
    ///
    /// The params encode themselves, so a typed payload -- a pane-tape record and the recorded
    /// event inside it -- reaches the wire in the same single JSON pass as the envelope.
    ///
    /// The params are `Sendable` because they are encoded on the write queue, not here.
    func writeNotification<Params: Encodable & Sendable>(
        method: String,
        params: Params,
        closeAfterWrite: Bool = false,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        writeLine(
            JsonRpcRequestEnvelope(method: method, params: params),
            closeAfterWrite: closeAfterWrite,
            completion: completion
        )
    }

    /// Queues one notification carrying an ordered batch, splitting it only when the encoded
    /// line would pass the framing bound the reader enforces.
    ///
    /// The split runs on the write queue because the encode does: how large a line is cannot
    /// be known until it is encoded, and measuring it at the call site would put the JSON pass
    /// back on the actor that handed the batch over. Groups leave in order, so the elements
    /// reach the peer in the order they were handed over whether they travel as one
    /// notification or several.
    ///
    /// `params` wraps one group of elements in the notification's own params shape, so this
    /// method never spells any part of that shape. The completion reports the whole batch: it
    /// is false if any group fails to encode or to write.
    func writeBatchedNotification<Element: Encodable & Sendable, Params: Encodable & Sendable>(
        method: String,
        batch: [Element],
        params: @escaping @Sendable (ArraySlice<Element>) -> Params,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        lock.lock()
        let shouldWrite = !closed
        lock.unlock()
        guard shouldWrite else {
            if let completion { deliver(completion, false) }
            return
        }

        writeQueue.async { [self, batch] in
            let outcome = writeGroup(method: method, group: batch[...], params: params)
            if let completion { deliver(completion, outcome == .flushed) }
            // Only a failed write leaves the peer's stream mid-line; a failed encode reached
            // the socket with no byte at all, so it takes down nothing else on the connection.
            if outcome == .writeFailed {
                close()
            }
        }
    }

    /// Writes one group as a single line, or halves it and writes each half, until every line
    /// is inside the framing bound.
    ///
    /// Only the write queue calls this. Halving is what keeps the split at an element
    /// boundary: a group of one that still does not fit has no boundary left to split at, so
    /// it goes out whole and the reader states the refusal, exactly as it would have before
    /// any batching existed.
    private func writeGroup<Element: Encodable, Params: Encodable>(
        method: String,
        group: ArraySlice<Element>,
        params: (ArraySlice<Element>) -> Params
    ) -> IpcBatchWriteOutcome {
        guard let line = try? encodeIpcLine(
            JsonRpcRequestEnvelope(method: method, params: params(group))
        ) else {
            return .encodeFailed
        }
        // The encoded line carries its terminating newline, which the reader's bound does not
        // count, so the payload is one byte shorter than what is measured here.
        if line.count - 1 > IpcLineFramer.maxLineBytes, group.count > 1 {
            let middle = group.startIndex + group.count / 2
            let first = writeGroup(
                method: method,
                group: group[group.startIndex..<middle],
                params: params
            )
            guard first == .flushed else { return first }
            return writeGroup(method: method, group: group[middle...], params: params)
        }
        return write(line: line) ? .flushed : .writeFailed
    }

    /// Releases the descriptor once the writes already queued on it have gone out.
    ///
    /// The release rides the write queue, so the answer to the peer's last request still
    /// reaches it. That also means a peer which stopped reading holds the descriptor for
    /// as long as it likes -- `forceClose` is for the cases that cannot allow that.
    func close() {
        lock.lock()
        let shouldClose = !closed
        closed = true
        lock.unlock()
        guard shouldClose else { return }
        writeQueue.async { [fd] in
            Darwin.close(fd)
        }
    }

    /// Releases the descriptor now, failing whatever write is parked on it.
    ///
    /// Reclamation at the silence bound and server stop both end connections the peer is
    /// no longer reading, where waiting for the write queue to drain means waiting on a
    /// peer that has stopped participating. The shutdown runs under the same lock that
    /// guards `closed`, which keeps it from touching a descriptor number the queued close
    /// has already released and the kernel has already handed to someone else.
    func forceClose() {
        lock.lock()
        let shouldShutDown = !closed
        if shouldShutDown { Darwin.shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        close()
    }

    private func takeResponseId(_ reqId: UUID) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return pendingResponseIds.removeValue(forKey: reqId)
    }

    /// The one place a write completion is invoked, so all three exits below report the same
    /// way: on the main queue, and never before the `write...` call that armed them returns.
    /// Delivering inline on the early exits would make a caller's own completion re-enter it.
    private func deliver(
        _ completion: @escaping @MainActor @Sendable (Bool) -> Void,
        _ succeeded: Bool
    ) {
        DispatchQueue.main.async {
            // `assumeIsolated` reads back the guarantee the line above just made, rather than
            // hopping again through `Task { @MainActor }` and giving up FIFO order with the
            // writes already queued behind it.
            MainActor.assumeIsolated { completion(succeeded) }
        }
    }

    /// Queues one value and turns it into a line on the write queue.
    ///
    /// The JSON pass runs inside the queued block, not here, so no caller pays for encoding
    /// its own payload -- and a followed pane tape, which writes continuously from the main
    /// actor and opens with multi-megabyte sync chunks, stops charging that cost to the actor
    /// drawing the panes. Order is unaffected: the queue is serial and values are enqueued in
    /// call order, so the encode order and the wire order are the call order.
    ///
    /// A value that fails to encode still reports through the completion, which is the only
    /// failure channel a caller has. It does not close the connection: no byte of the failed
    /// line reached the socket, so the peer's stream is short a record but not corrupt, and
    /// the connection's other streams are untouched.
    private func writeLine<T: Encodable & Sendable>(
        _ value: T,
        closeAfterWrite: Bool = false,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        lock.lock()
        let shouldWrite = !closed
        lock.unlock()
        guard shouldWrite else {
            if let completion { deliver(completion, false) }
            return
        }

        writeQueue.async { [self, value] in
            defer {
                if closeAfterWrite {
                    close()
                }
            }
            guard let line = try? encodeIpcLine(value) else {
                if let completion { deliver(completion, false) }
                return
            }
            let succeeded = write(line: line)
            if let completion { deliver(completion, succeeded) }
            if succeeded == false {
                close()
            }
        }
    }

    /// Pushes one complete line out, looping until the kernel has taken all of it.
    ///
    /// Only the write queue calls this: it touches the descriptor directly and blocks the
    /// caller until the peer has taken the bytes.
    private func write(line: Data) -> Bool {
        line.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var written = 0
            while written < line.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: written), line.count - written)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }
                written += result
            }
            return true
        }
    }

    /// Arms the kernel's own receive deadline on this socket.
    ///
    /// The deadline belongs on the read that waits for the bytes, rather than on a separate
    /// timer beside it: one clock, and no way for the two to disagree about the same stream.
    /// The clamp only keeps an absurd advertised bound from overflowing `timeval`; any bound
    /// that survives it is measured exactly.
    private static func armReceiveDeadline(_ bound: IpcLivenessBound, on fd: Int32) {
        let seconds = min(bound.seconds, TimeInterval(Int32.max))
        var deadline = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func disableSigPipe(on fd: Int32) {
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }
}

/// How a batched write ended, kept apart from a plain success flag because the two failures
/// are answered differently: a failed write has left a partial line on the socket and ends the
/// connection, while a failed encode put nothing on it and ends only that batch.
private enum IpcBatchWriteOutcome {
    case flushed
    case encodeFailed
    case writeFailed
}

/// Recovers a method string from an otherwise malformed JSON-RPC envelope for audit.
private struct IpcMalformedRequestProbe: Decodable {
    let method: String?
}
