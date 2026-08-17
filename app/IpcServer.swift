// Local and tailnet IPC accept loops. This actor owns admission, caller stamping,
// and audit gates; AppRuntime remains the request-effect executor.
import Foundation
import DanTermProtocol
import Darwin
import Synchronization

/// Completes the audit lifecycle after AppRuntime has produced a request outcome.
struct IpcRequestAudit: Sendable {
    let writer: IpcAuditLogWriter
    let caller: IpcCallerIdentity
    let request: IpcAuditRequestDescriptor
    let isRemote: Bool

    /// Records a remote completion or the local request's single best-effort record.
    func complete(outcome: String) {
        let event = isRemote
            ? IpcAuditEvent.requestCompleted(caller: caller, request: request, outcome: outcome)
            : IpcAuditEvent.localRequest(request: request, outcome: outcome)
        try? writer.append(event)
    }
}

/// Holds one runtime request's socket and optional audit completion responsibility.
struct IpcRequestTransport: Sendable {
    let connection: IpcConnection
    let audit: IpcRequestAudit?

    var id: UUID { connection.id }

    func close() {
        connection.close()
    }

    func writeSuccess(
        reqId: UUID,
        result: JSONValue,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        audit?.complete(outcome: "success")
        connection.writeSuccess(reqId: reqId, result: result, completion: completion)
    }

    func writeError(reqId: UUID, code: Int, message: String) {
        audit?.complete(outcome: "error")
        connection.writeError(reqId: reqId, code: code, message: message)
    }
}

/// Keeps remote-cap accounting synchronous at accept time and independent of actor scheduling.
private final class RemoteConnectionSlots: Sendable {
    private let limit: Int
    private let count = Mutex(0)

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func reserve() -> Bool {
        count.withLock { value in
            guard value < limit else { return false }
            value += 1
            return true
        }
    }

    func release() {
        count.withLock { value in
            precondition(value > 0)
            value -= 1
        }
    }
}

/// Lets synchronous stop win against accept and admission work already off-actor.
private final class IpcServerStopState: Sendable {
    private let stopped = Mutex(false)

    func markStopped() {
        stopped.withLock { $0 = true }
    }

    var isStopped: Bool {
        stopped.withLock { $0 }
    }
}

actor IpcServer {
    private struct ConnectionState {
        let connection: IpcConnection
        let caller: IpcCallerIdentity
        let transport: String
        let peerAddress: String
        let holdsRemoteSlot: Bool
    }

    nonisolated let socketPath: URL
    nonisolated private let listener: ControlSocketListener
    nonisolated private let tailnetListener: TailnetListener?
    nonisolated let tailnetPort: UInt16?

    private weak var runtime: AppRuntime?
    private let appVersion: String
    private let livenessBound: IpcLivenessBound
    private let auditWriter: IpcAuditLogWriter
    private let whoisResolver: TailnetWhoisResolver
    private let admittedNodeIds: Set<String>
    nonisolated private let remoteSlots: RemoteConnectionSlots
    nonisolated private let stopState = IpcServerStopState()
    private let acceptQueue = DispatchQueue(label: "danterm.ipc.accept", qos: .utility)
    private let tailnetAcceptQueue = DispatchQueue(label: "danterm.ipc.tailnet.accept", qos: .utility)
    private var connections: [UUID: ConnectionState] = [:]

    init(
        socketPath: URL = controlSocketPath(),
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        livenessBound: IpcLivenessBound = .standard,
        tailnetConfig: DanTermTailnetConfig? = nil,
        auditWriter: IpcAuditLogWriter = IpcAuditLogWriter(directory: recoveryDirectoryURL()),
        whoisResolver: TailnetWhoisResolver = .live,
        remoteConnectionLimit: Int = 8,
        resolveTailnetBindAddress: @Sendable (String) throws -> TailnetBindAddress = {
            try TailnetBindAddress.resolve($0)
        },
        runtime: AppRuntime?
    ) throws {
        self.socketPath = socketPath
        self.listener = try ControlSocketListener.open(at: socketPath)
        self.appVersion = appVersion
        self.livenessBound = livenessBound
        self.auditWriter = auditWriter
        self.whoisResolver = whoisResolver
        self.admittedNodeIds = Set(tailnetConfig?.admittedNodeIds ?? [])
        self.remoteSlots = RemoteConnectionSlots(limit: remoteConnectionLimit)
        self.runtime = runtime

        var openedTailnetListener: TailnetListener?
        if let tailnetConfig, tailnetConfig.admittedNodeIds.isEmpty == false {
            do {
                try auditWriter.prepare()
                let bindAddress = try resolveTailnetBindAddress(tailnetConfig.listen)
                openedTailnetListener = try TailnetListener.open(on: bindAddress)
            } catch {
                try? auditWriter.append(.listenerFailed(reason: String(describing: error)))
            }
        }
        self.tailnetListener = openedTailnetListener
        self.tailnetPort = openedTailnetListener?.port
    }

    func start() {
        guard stopState.isStopped == false else { return }
        startLocalAcceptLoop()
        startTailnetAcceptLoop()
    }

    /// Makes both listener surfaces unreachable before returning to synchronous app exit.
    nonisolated func stop() {
        stopState.markStopped()
        listener.close()
        tailnetListener?.close()
        Task { [weak self] in await self?.closeConnections() }
    }

    private func startLocalAcceptLoop() {
        let fileDescriptor = listener.fileDescriptor
        acceptQueue.async { [weak self] in
            while true {
                let clientFD = Darwin.accept(fileDescriptor, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    break
                }
                Task { await self?.acceptLocal(fileDescriptor: clientFD) }
            }
        }
    }

    private func startTailnetAcceptLoop() {
        guard let tailnetListener else { return }
        let listenerFileDescriptor = tailnetListener.fileDescriptor
        let slots = remoteSlots
        let resolver = whoisResolver
        let auditWriter = auditWriter
        tailnetAcceptQueue.async { [weak self] in
            while true {
                let accepted: TailnetAcceptedPeer
                do {
                    accepted = try acceptTailnetPeer(on: listenerFileDescriptor)
                } catch {
                    if errno == EINTR { continue }
                    break
                }
                guard slots.reserve() else {
                    let connection = IpcConnection(fileDescriptor: accepted.fileDescriptor)
                    try? auditWriter.append(.connectionRefused(
                        transport: "tailnet",
                        peerAddress: accepted.peer.description,
                        reason: IpcConnectionRejectionReason.connectionLimit.rawValue
                    ))
                    connection.writeRejected(.connectionLimit)
                    continue
                }
                Task.detached { [weak self, slots] in
                    let resolution = Result {
                        try resolver.resolve(peerAddress: accepted.peer.description)
                    }
                    guard let self else {
                        Darwin.close(accepted.fileDescriptor)
                        slots.release()
                        return
                    }
                    await self.acceptRemote(accepted, resolution: resolution)
                }
            }
        }
    }

    private func closeConnections() {
        for state in connections.values {
            state.connection.close()
            try? auditWriter.append(.connectionClosed(
                transport: state.transport,
                peerAddress: state.peerAddress,
                caller: state.caller
            ))
            if state.holdsRemoteSlot { remoteSlots.release() }
        }
        connections.removeAll()
    }

    private func acceptLocal(fileDescriptor: Int32) {
        guard stopState.isStopped == false else {
            Darwin.close(fileDescriptor)
            return
        }
        let connection = IpcConnection(fileDescriptor: fileDescriptor)
        let state = ConnectionState(
            connection: connection,
            caller: .local,
            transport: "local",
            peerAddress: socketPath.path,
            holdsRemoteSlot: false
        )
        connections[connection.id] = state
        try? auditWriter.append(.connectionOpened(
            transport: state.transport,
            peerAddress: state.peerAddress,
            caller: state.caller
        ))
        beginService(state)
    }

    private func acceptRemote(
        _ accepted: TailnetAcceptedPeer,
        resolution: Result<TailnetPeerIdentity, Error>
    ) {
        guard stopState.isStopped == false else {
            Darwin.close(accepted.fileDescriptor)
            remoteSlots.release()
            return
        }
        let connection = IpcConnection(fileDescriptor: accepted.fileDescriptor)
        let peerAddress = accepted.peer.description
        guard case .success(let identity) = resolution else {
            refuse(connection, peerAddress: peerAddress, reason: .identityUnresolved)
            remoteSlots.release()
            return
        }
        guard admittedNodeIds.contains(identity.nodeId) else {
            refuse(connection, peerAddress: peerAddress, reason: .notAdmitted)
            remoteSlots.release()
            return
        }
        let caller = IpcCallerIdentity.remote(
            nodeId: identity.nodeId,
            user: identity.user,
            machineName: identity.machineName
        )
        let opened = IpcAuditEvent.connectionOpened(
            transport: "tailnet",
            peerAddress: peerAddress,
            caller: caller
        )
        do {
            try auditWriter.append(opened)
        } catch {
            refuse(connection, peerAddress: peerAddress, reason: .auditUnavailable)
            remoteSlots.release()
            return
        }
        let state = ConnectionState(
            connection: connection,
            caller: caller,
            transport: "tailnet",
            peerAddress: peerAddress,
            holdsRemoteSlot: true
        )
        connections[connection.id] = state
        beginService(state)
    }

    private func refuse(
        _ connection: IpcConnection,
        peerAddress: String,
        reason: IpcConnectionRejectionReason
    ) {
        try? auditWriter.append(.connectionRefused(
            transport: "tailnet",
            peerAddress: peerAddress,
            reason: reason.rawValue
        ))
        connection.writeRejected(reason)
    }

    private func beginService(_ state: ConnectionState) {
        let auditWriter = auditWriter
        let caller = state.caller
        state.connection.writeHello(appVersion: appVersion, livenessBound: livenessBound)
        state.connection.startReading(
            onRequest: { [weak self] request, connection in
                Task { await self?.dispatch(request, from: connection) }
            },
            onMalformedRequest: { method, _ in
                try? auditWriter.append(.requestDecodeFailed(
                    caller: caller,
                    rawMethod: method ?? "<unparseable>",
                    outcome: "error"
                ))
            },
            onClose: { [weak self] connection in
                Task { await self?.close(connection) }
            }
        )
    }

    private func close(_ connection: IpcConnection) async {
        guard let state = connections.removeValue(forKey: connection.id) else { return }
        if state.holdsRemoteSlot { remoteSlots.release() }
        try? auditWriter.append(.connectionClosed(
            transport: state.transport,
            peerAddress: state.peerAddress,
            caller: state.caller
        ))
        await runtime?.ipcConnectionClosed(connection.id)
    }

    private func dispatch(_ request: JsonRpcRequest, from connection: IpcConnection) async {
        guard let state = connections[connection.id] else { return }
        guard let rpcId = request.id else {
            try? auditWriter.append(.requestDropped(caller: state.caller, rawMethod: request.method))
            return
        }
        let reqId = UUID()
        let typedRequest: IpcRequest
        do {
            typedRequest = try IpcRequest.decode(
                method: request.method,
                params: request.params ?? .object([:])
            )
        } catch let error as IpcRequestDecodeError {
            try? auditWriter.append(.requestDecodeFailed(
                caller: state.caller,
                rawMethod: request.method,
                outcome: "error"
            ))
            connection.rememberRequest(reqId: reqId, rpcId: rpcId)
            await dispatchToRuntime(
                .ipcRequestDecodeFailed(reqId: reqId, error: error),
                connection: connection,
                reqId: reqId,
                audit: nil
            )
            return
        } catch {
            try? auditWriter.append(.requestDecodeFailed(
                caller: state.caller,
                rawMethod: request.method,
                outcome: "error"
            ))
            connection.rememberRequest(reqId: reqId, rpcId: rpcId)
            await dispatchToRuntime(
                .ipcRequestDecodeFailed(reqId: reqId, error: .internalError),
                connection: connection,
                reqId: reqId,
                audit: nil
            )
            return
        }

        // A method that earns no durable record also skips the write-ahead gate that
        // makes remote service depend on the log. A heartbeat exercises no authority
        // and names no target, and one record every half-bound would evict the events
        // the log exists for.
        let isAudited = typedRequest.method.producesAuditRecord
        let audit = isAudited
            ? IpcRequestAudit(
                writer: auditWriter,
                caller: state.caller,
                request: typedRequest.auditDescriptor,
                isRemote: state.holdsRemoteSlot
            )
            : nil
        if isAudited, state.holdsRemoteSlot {
            do {
                try auditWriter.append(.requestStarted(
                    caller: state.caller,
                    request: typedRequest.auditDescriptor
                ))
            } catch {
                connection.writeErrorResponse(
                    id: rpcId,
                    error: IpcRequestErrors.auditUnavailable,
                    closeAfterWrite: true
                )
                return
            }
        }
        connection.rememberRequest(reqId: reqId, rpcId: rpcId)
        await dispatchToRuntime(
            .ipcRequest(reqId: reqId, caller: state.caller, request: typedRequest),
            connection: connection,
            reqId: reqId,
            audit: audit
        )
    }

    private func dispatchToRuntime(
        _ message: Msg,
        connection: IpcConnection,
        reqId: UUID,
        audit: IpcRequestAudit?
    ) async {
        let runtime = self.runtime
        await MainActor.run {
            runtime?.registerIpcConnection(connection, for: reqId, audit: audit)
            runtime?.send(message)
        }
    }
}
