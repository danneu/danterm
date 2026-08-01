// Unix-domain socket server that dispatches DanTerm IPC requests onto AppRuntime.
import Foundation
import DanTermProtocol
import Darwin

actor IpcServer {
    nonisolated let socketPath: URL

    private weak var runtime: AppRuntime?
    private let appVersion: String
    private let acceptQueue = DispatchQueue(label: "danterm.ipc.accept", qos: .utility)
    private var listenFD: Int32 = -1
    private var connections: [UUID: IpcConnection] = [:]

    init(
        socketPath: URL = controlSocketPath(),
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        runtime: AppRuntime
    ) {
        self.socketPath = socketPath
        self.appVersion = appVersion
        self.runtime = runtime
    }

    func start() {
        guard listenFD < 0 else { return }
        do {
            listenFD = try Self.openListenSocket(at: socketPath)
        } catch {
            print("Failed to start DanTerm IPC server: \(error)")
            return
        }

        let fd = listenFD
        acceptQueue.async { [weak self] in
            while true {
                let clientFD = Darwin.accept(fd, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    break
                }
                Task { await self?.accept(fileDescriptor: clientFD) }
            }
        }
    }

    func stop() {
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
        try? FileManager.default.removeItem(at: socketPath)
    }

    private func accept(fileDescriptor: Int32) {
        let connection = IpcConnection(fileDescriptor: fileDescriptor)
        connections[connection.id] = connection
        connection.writeHello(appVersion: appVersion)
        connection.startReading(
            onRequest: { [weak self] request, connection in
                Task { await self?.dispatch(request, from: connection) }
            },
            onClose: { [weak self] connection in
                Task { await self?.close(connection) }
            }
        )
    }

    private func close(_ connection: IpcConnection) async {
        connections.removeValue(forKey: connection.id)
        await runtime?.ipcConnectionClosed(connection.id)
    }

    private func dispatch(_ request: JsonRpcRequest, from connection: IpcConnection) async {
        guard let rpcId = request.id else {
            return
        }
        let reqId = UUID()
        connection.rememberRequest(reqId: reqId, rpcId: rpcId)
        let context = IpcRequestContext.from(params: request.params)
        let params = IpcRequestContext.strippingContext(from: request.params)
        let runtime = self.runtime
        await MainActor.run {
            runtime?.registerIpcConnection(connection, for: reqId)
            runtime?.send(.ipcRequest(
                reqId: reqId,
                method: request.method,
                params: params,
                context: context
            ))
        }
    }

    private static func openListenSocket(at url: URL) throws -> Int32 {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        unlink(url.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        do {
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
            guard url.path.utf8.count < maxLength else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            url.path.withCString { ptr in
                withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                    let buffer = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                    strncpy(buffer, ptr, maxLength - 1)
                }
            }

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard listen(fd, SOMAXCONN) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            chmod(url.path, 0o600)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }
}
