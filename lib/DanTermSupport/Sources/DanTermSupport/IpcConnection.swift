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

    func startReading(
        onRequest: @escaping @Sendable (JsonRpcRequest, IpcConnection) -> Void,
        onClose: @escaping @Sendable (IpcConnection) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async { [self] in
            var framer = IpcLineFramer()
            var buffer = [UInt8](repeating: 0, count: 4096)

            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
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
                            writeErrorResponse(id: .null, code: -32700, message: "parse error")
                        }
                    case .oversized:
                        writeErrorResponse(
                            id: .null,
                            code: -32600,
                            message: "request line too large",
                            closeAfterWrite: true
                        )
                        onClose(self)
                        return
                    }
                }
            }

            close()
            onClose(self)
        }
    }

    func rememberRequest(reqId: UUID, rpcId: JSONValue?) {
        lock.lock()
        pendingResponseIds[reqId] = rpcId ?? .null
        lock.unlock()
    }

    func writeHello(appVersion: String) {
        let hello = JsonRpcRequest(
            method: Methods.hello,
            params: .object([
                "protocol": .number(1),
                "app": .string(appVersion),
            ])
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

    private static func disableSigPipe(on fd: Int32) {
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }
}
