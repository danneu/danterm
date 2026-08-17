// Unix-socket connection lifecycle and JSON-RPC response writing for DanTerm IPC; line framing
// lives in DanTermProtocol (IpcLineFramer).
//
// Writes are queued and their completions are delivered on the main queue, always: the app state
// a completion feeds lives on the main actor, so the completions are typed `@MainActor` and every
// exit routes through `deliver`. The uniformity is the point -- an early exit that reported
// inline would hand one callback two delivery contexts, and re-enter its own caller.
import Foundation
import DanTermProtocol
import Darwin

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
    func startReading(
        livenessBound: IpcLivenessBound? = nil,
        onRequest: @escaping @Sendable (JsonRpcRequest, IpcConnection) -> Void,
        onMalformedRequest: @escaping @Sendable (String?, IpcConnection) -> Void = { _, _ in },
        onClose: @escaping @Sendable (IpcConnection, IpcConnectionCloseReason) -> Void
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
                        do {
                            let request = try JSONDecoder().decode(JsonRpcRequest.self, from: line)
                            onRequest(request, self)
                        } catch {
                            let method = try? JSONDecoder().decode(
                                IpcMalformedRequestProbe.self,
                                from: line
                            ).method
                            onMalformedRequest(method, self)
                            writeErrorResponse(id: .null, code: -32700, message: "parse error")
                        }
                    case .oversized:
                        writeErrorResponse(
                            id: .null,
                            code: -32600,
                            message: "request line too large",
                            closeAfterWrite: true
                        )
                        onClose(self, .oversizedRequest)
                        return
                    }
                }
            }

            if reason == .peerSilent { shutdownIfOpen() }
            close()
            onClose(self, reason)
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
                protocolVersion: 1,
                appVersion: appVersion,
                livenessBound: livenessBound
            )
        )
        writeLine(hello)
    }

    /// Writes the pre-handshake refusal and closes after its complete line is flushed.
    func writeRejected(_ reason: IpcConnectionRejectionReason) {
        writeLine(reason.notification, closeAfterWrite: true)
    }

    func writeSuccess(
        reqId: UUID,
        result: JSONValue,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        guard let rpcId = takeResponseId(reqId) else {
            if let completion { deliver(completion, false) }
            return
        }
        writeLine(JsonRpcResponse(id: rpcId, result: result), completion: completion)
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
    func writeNotification(
        method: String,
        params: JSONValue,
        closeAfterWrite: Bool = false,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        writeLine(
            JsonRpcRequest(method: method, params: params),
            closeAfterWrite: closeAfterWrite,
            completion: completion
        )
    }

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

    /// Fails a write parked on this socket, so the close queued behind it can run.
    ///
    /// `close()` only enqueues the descriptor's close on the write queue, and a peer that
    /// stopped reading parks that queue in a blocking write -- so without this the bound
    /// would bound the read loop and not the descriptor. It runs under the same lock that
    /// guards `closed`, which is what keeps it from touching a descriptor number the
    /// queued close has already released and the kernel has already handed to someone else.
    private func shutdownIfOpen() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
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

    private func writeLine<T: Encodable>(
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

        guard let line = try? encodeIpcLine(value) else {
            if let completion { deliver(completion, false) }
            return
        }
        writeQueue.async { [self, line] in
            defer {
                if closeAfterWrite {
                    close()
                }
            }
            let succeeded = line.withUnsafeBytes { rawBuffer -> Bool in
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
            if let completion { deliver(completion, succeeded) }
            if succeeded == false {
                close()
            }
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

/// Recovers a method string from an otherwise malformed JSON-RPC envelope for audit.
private struct IpcMalformedRequestProbe: Decodable {
    let method: String?
}
