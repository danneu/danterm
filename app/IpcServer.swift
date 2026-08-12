// Unix-domain socket server that dispatches DanTerm IPC requests onto AppRuntime.
import Foundation
import DanTermProtocol
import Darwin

actor IpcServer {
    nonisolated let socketPath: URL
    nonisolated private let listener: ControlSocketListener

    private weak var runtime: AppRuntime?
    private let appVersion: String
    private let acceptQueue = DispatchQueue(label: "danterm.ipc.accept", qos: .utility)
    private var connections: [UUID: IpcConnection] = [:]

    init(
        socketPath: URL = controlSocketPath(),
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        runtime: AppRuntime?
    ) throws {
        self.socketPath = socketPath
        self.listener = try ControlSocketListener.open(at: socketPath)
        self.appVersion = appVersion
        self.runtime = runtime
    }

    func start() {
        let fd = listener.fileDescriptor
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

    /// Makes the owned socket unreachable before returning to the synchronous app exit path.
    nonisolated func stop() {
        listener.close()
        Task { [weak self] in await self?.closeConnections() }
    }

    private func closeConnections() {
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
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
        let message: Msg
        do {
            message = .ipcRequest(
                reqId: reqId,
                request: try IpcRequest.decode(
                    method: request.method,
                    params: request.params ?? .object([:])
                )
            )
        } catch let error as IpcRequestDecodeError {
            message = .ipcRequestDecodeFailed(reqId: reqId, error: error)
        } catch {
            message = .ipcRequestDecodeFailed(
                reqId: reqId,
                error: .internalError
            )
        }
        let runtime = self.runtime
        await MainActor.run {
            runtime?.registerIpcConnection(connection, for: reqId)
            runtime?.send(message)
        }
    }
}
