// Unix-socket connection lifecycle and JSON-RPC response writing for DanTerm IPC; line framing
// lives in DanTermProtocol (IpcLineFramer).
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

    func writeSuccess(reqId: UUID, result: JSONValue) {
        guard let rpcId = takeResponseId(reqId) else { return }
        writeLine(JsonRpcResponse(id: rpcId, result: result))
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

    private func writeLine<T: Encodable>(_ value: T, closeAfterWrite: Bool = false) {
        lock.lock()
        let shouldWrite = !closed
        lock.unlock()
        guard shouldWrite else { return }

        guard let encoded = try? JSONEncoder().encode(value) else { return }
        var line = encoded
        line.append(0x0A)
        writeQueue.async { [self, line] in
            defer {
                if closeAfterWrite {
                    close()
                }
            }
            line.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var written = 0
                while written < line.count {
                    let result = Darwin.write(fd, baseAddress.advanced(by: written), line.count - written)
                    if result < 0 && errno == EINTR { continue }
                    guard result > 0 else { return }
                    written += result
                }
            }
        }
    }

    private static func disableSigPipe(on fd: Int32) {
        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }
}
