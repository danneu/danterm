// Unix-domain socket server that dispatches DanTerm IPC requests onto AppRuntime.
import Foundation
import DanTermProtocol
import Darwin

actor IpcServer {
    nonisolated let socketPath: URL

    private weak var runtime: AppRuntime?
    private let appVersion: String
    private let acceptQueue = DispatchQueue(label: "danterm.ipc.accept", qos: .utility)
    private var listener: ControlSocketListener?
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
        guard listener == nil else { return }
        do {
            listener = try ControlSocketListener.open(at: socketPath)
        } catch {
            print("Failed to start DanTerm IPC server: \(error)")
            return
        }

        guard let listener else { return }
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

    func stop() {
        listener?.close()
        listener = nil
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
}
