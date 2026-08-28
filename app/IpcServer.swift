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

    func writeSuccess<Result: Encodable & Sendable>(
        reqId: UUID,
        result: Result,
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

/// The runtime entry points `IpcServer` may reach, as a main-actor-bound handle.
///
/// The server holds this instead of the runtime itself. Each closure captures the runtime
/// weakly and strengthens it only inside its own main-actor body, so a strong runtime
/// reference never exists on the server's executor and the server can never perform the
/// runtime's last release -- which would destroy main-actor state on a cooperative thread.
/// The server has no object to capture, so that holds for call sites added later too.
struct AppRuntimeIpcDispatch: Sendable {
    /// Registers a decoded request's transport and sends it in one main-actor body, so
    /// nothing can run between them and get ahead of a connection's own ordering.
    let serve: @MainActor @Sendable (
        IpcConnection,
        UUID,
        IpcRequestAudit?,
        IpcCallerIdentity,
        IpcRequest
    ) -> Void
    /// Retires the runtime state owned by a connection that has gone.
    let connectionClosed: @MainActor @Sendable (UUID) -> Void
    /// Publishes each tailnet listener transition into the model, so every surface that
    /// reports the listener reports the value the server authored.
    let tailnetStatusChanged: @MainActor @Sendable (DanTermTailnetStatus) -> Void
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

/// How long a failed tailnet bind waits before it tries the same endpoint again.
///
/// Discretionary: long enough that a permanently rejected address does not spin, short
/// enough that a login-time race with Tailscale heals in seconds rather than minutes.
private let tailnetBindRetryInterval = Duration.seconds(5)

/// Keeps the tailnet listener reachable from a synchronous stop, whichever attempt bound it.
///
/// The bind is retried, so the descriptor `stop()` must close does not exist yet when stop
/// may first be called, and the attempt that creates it runs on the actor. This box is the
/// one place the two sides meet, and it refuses to adopt a listener once stop has won.
private final class TailnetListenerHandle: Sendable {
    private let listener = Mutex<TailnetListener?>(nil)

    /// The bound port, or nil while no attempt has succeeded.
    var port: UInt16? { listener.withLock { $0?.port } }

    /// Takes ownership of a freshly bound listener; false tells the caller to close it itself.
    func adopt(_ opened: TailnetListener, unless stopState: IpcServerStopState) -> Bool {
        listener.withLock { current in
            guard stopState.isStopped == false else { return false }
            current = opened
            return true
        }
    }

    func close() {
        listener.withLock { $0?.close() }
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
        /// Whether this connection lives under the liveness contract, decided once at
        /// admission. Nil exempts it, which is what every local caller gets.
        let livenessBound: IpcLivenessBound?
        /// Requests handed to the runtime on this connection, heartbeats included.
        var servedRequests = 0
    }

    nonisolated let socketPath: URL
    nonisolated private let listener: ControlSocketListener
    nonisolated private let tailnetListenerHandle = TailnetListenerHandle()

    /// The port this instance's tailnet listener took, or nil while nothing is bound.
    nonisolated var tailnetPort: UInt16? { tailnetListenerHandle.port }

    /// What this instance's tailnet listener is doing, authored here and reported everywhere.
    private(set) var tailnetStatus: DanTermTailnetStatus

    /// The status this instance starts at, decided in `init` from the launch-frozen
    /// activation.
    ///
    /// Nonisolated so the runtime can seed the model with it while it is still building
    /// itself, before the Elm loop exists to receive a message. Every later value arrives
    /// through `AppRuntimeIpcDispatch.tailnetStatusChanged`.
    nonisolated let initialTailnetStatus: DanTermTailnetStatus

    private let runtimeDispatch: AppRuntimeIpcDispatch?
    private let appVersion: String
    private let livenessBound: IpcLivenessBound
    private let auditWriter: IpcAuditLogWriter
    private let whoisResolver: TailnetWhoisResolver
    private let admittedNodeIds: Set<String>
    /// The launch-frozen decision: this instance's endpoint, or why it opens no listener.
    private let tailnetActivation: DanTermTailnetActivation
    private let resolveTailnetBindAddress: @Sendable (String) throws -> TailnetBindAddress
    private let tailnetBindRetryDelay: @Sendable () async -> Void
    /// The failure the log already carries, so retries record transitions and not attempts.
    private var recordedBindFailureReason: String?
    nonisolated private let remoteSlots: RemoteConnectionSlots
    nonisolated private let stopState = IpcServerStopState()
    private let acceptQueue = DispatchQueue(label: "danterm.ipc.accept", qos: .utility)
    private let tailnetAcceptQueue = DispatchQueue(label: "danterm.ipc.tailnet.accept", qos: .utility)
    private var connections: [UUID: ConnectionState] = [:]

    /// The socket, the identity, and the audit sink have no defaults: all three are
    /// this instance's own, and the launch-resolved paths value is what knows them.
    /// The audit writer stays a separate input rather than a path, because the
    /// remote fixture breaks and restores that sink to read what the server wrote.
    init(
        socketPath: URL,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        livenessBound: IpcLivenessBound = .standard,
        tailnetConfig: DanTermTailnetConfig? = nil,
        identity: DanTermInstanceIdentity,
        auditWriter: IpcAuditLogWriter,
        whoisResolver: TailnetWhoisResolver = .live,
        remoteConnectionLimit: Int = 8,
        resolveTailnetBindAddress: @escaping @Sendable (String) throws -> TailnetBindAddress = {
            try TailnetBindAddress.resolve($0)
        },
        tailnetBindRetryDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: tailnetBindRetryInterval)
        },
        runtimeDispatch: AppRuntimeIpcDispatch?
    ) throws {
        self.socketPath = socketPath
        self.listener = try ControlSocketListener.open(at: socketPath)
        self.appVersion = appVersion
        self.livenessBound = livenessBound
        self.auditWriter = auditWriter
        self.whoisResolver = whoisResolver
        self.admittedNodeIds = Set(tailnetConfig?.admittedNodeIds ?? [])
        self.remoteSlots = RemoteConnectionSlots(limit: remoteConnectionLimit)
        self.runtimeDispatch = runtimeDispatch
        self.resolveTailnetBindAddress = resolveTailnetBindAddress
        self.tailnetBindRetryDelay = tailnetBindRetryDelay

        // Frozen here, for this whole run: a later config reload changes what the next
        // launch would bind, never what this process is bound to.
        let activation = DanTermTailnetActivation.resolve(
            config: tailnetConfig,
            identity: identity
        )
        self.tailnetActivation = activation
        switch activation {
        case .disabled(let reason):
            self.initialTailnetStatus = .disabled(reason: reason)
        case .active(let endpoint):
            self.initialTailnetStatus = .waiting(
                endpoint: endpoint,
                reason: "the listener is not open yet"
            )
        }
        self.tailnetStatus = initialTailnetStatus
    }

    /// Opens both surfaces, and returns once the first tailnet bind attempt has been made.
    func start() async {
        guard stopState.isStopped == false else { return }
        startLocalAcceptLoop()
        await openTailnetListener()
    }

    /// Binds this instance's endpoint, and keeps trying on its own until it does.
    ///
    /// The first attempt runs inline, so a caller that awaited `start()` knows whether the
    /// listener came up at launch. Only a failure schedules the retry loop.
    private func openTailnetListener() async {
        guard case .active(let endpoint) = tailnetActivation else { return }
        guard await attemptTailnetBind(endpoint) == false else { return }
        let delay = tailnetBindRetryDelay
        // Weak between turns on purpose: the loop ends with the server, and a strong
        // reference held across the delay would keep a dead server alive for it.
        Task { [weak self] in
            while true {
                await delay()
                guard let self, await self.retryTailnetBind(endpoint) == false else { return }
            }
        }
    }

    /// One retry turn. False keeps the loop going; true means bound, or stopped.
    private func retryTailnetBind(_ endpoint: DanTermTailnetEndpoint) async -> Bool {
        guard stopState.isStopped == false else { return true }
        return await attemptTailnetBind(endpoint)
    }

    /// Makes one complete bind attempt and records only the transition it caused.
    ///
    /// Address resolution runs again on every attempt, because the interface the endpoint
    /// belongs to is exactly what may still be missing -- that is the case the retry heals,
    /// and re-running it keeps the tailnet-range and local-interface checks in front of
    /// every listener this process opens.
    private func attemptTailnetBind(_ endpoint: DanTermTailnetEndpoint) async -> Bool {
        do {
            try auditWriter.prepare()
            let bindAddress = try resolveTailnetBindAddress(endpoint.text)
            let opened = try TailnetListener.open(on: bindAddress)
            guard tailnetListenerHandle.adopt(opened, unless: stopState) else {
                opened.close()
                return true
            }
            try? auditWriter.append(.listenerBound(endpoint: endpoint.text))
            startTailnetAcceptLoop(on: opened.fileDescriptor)
            // Last, because it suspends: adopting the listener and handing its descriptor
            // to the accept loop has to stay one uninterrupted turn, or a stop between the
            // two would close that descriptor and leave the loop accepting on a number the
            // process may already have reused.
            await publish(.listening(endpoint: endpoint))
            return true
        } catch {
            let reason = String(describing: error)
            if reason != recordedBindFailureReason {
                recordedBindFailureReason = reason
                try? auditWriter.append(.listenerFailed(reason: reason))
            }
            await publish(.waiting(endpoint: endpoint, reason: reason))
            return false
        }
    }

    /// Records one status transition and hands it to the runtime, in that order.
    ///
    /// Only a change is published, because a bind that keeps failing for one reason would
    /// otherwise run a whole update frame per retry to store the value the model already
    /// holds. The runtime call is awaited rather than detached so two transitions cannot
    /// reach the model out of order and leave a listening instance reported as waiting.
    private func publish(_ status: DanTermTailnetStatus) async {
        guard status != tailnetStatus else { return }
        tailnetStatus = status
        await runtimeDispatch?.tailnetStatusChanged(status)
    }

    /// Makes both listener surfaces unreachable before returning to synchronous app exit.
    ///
    /// The cleanup task holds the server strongly: it is the only thing that closes the
    /// descriptors the readers are parked on, so letting the server go first would skip it
    /// and leave every idle reader blocked on a socket nobody closes.
    nonisolated func stop() {
        stopState.markStopped()
        listener.close()
        tailnetListenerHandle.close()
        Task { await self.closeConnections() }
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

    private func startTailnetAcceptLoop(on listenerFileDescriptor: Int32) {
        let slots = remoteSlots
        let resolver = whoisResolver
        let auditWriter = auditWriter
        let livenessBound = livenessBound
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
                    connection.writeRejected(.connectionLimit, livenessBound: livenessBound)
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
            // Forced, because a peer that stopped reading must not be able to keep a
            // descriptor -- and a reader thread parked on it -- past the server's own life.
            state.connection.forceClose()
            try? auditWriter.append(.connectionClosed(
                transport: state.transport,
                peerAddress: state.peerAddress,
                caller: state.caller,
                reason: .serverStopped,
                servedRequests: state.servedRequests
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
            holdsRemoteSlot: false,
            livenessBound: nil
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
            holdsRemoteSlot: true,
            livenessBound: livenessBound
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
        connection.writeRejected(reason, livenessBound: livenessBound)
    }

    private func beginService(_ state: ConnectionState) {
        state.connection.writeHello(appVersion: appVersion, livenessBound: livenessBound)
        state.connection.startReading(livenessBound: state.livenessBound) { [weak self] event, connection in
            // The reader thread waits here, so this connection's next event does not exist
            // until this one has been handled. That is the whole ordering guarantee: there
            // is never a second event to get ahead of the first. The semaphore is signalled
            // by the submitted task itself rather than by the server, so a server that has
            // gone away leaves no reader stranded.
            let handled = DispatchSemaphore(value: 0)
            Task {
                defer { handled.signal() }
                await self?.handle(event, from: connection)
            }
            handled.wait()
        }
    }

    /// Acts on one connection event, on the actor, while its reader waits.
    private func handle(_ event: IpcConnectionEvent, from connection: IpcConnection) async {
        switch event {
        case .request(let request):
            await dispatch(request, from: connection)
        case .malformedRequest(let rawMethod):
            recordMalformedRequest(rawMethod, from: connection)
        case .closed(let reason):
            await close(connection, reason: reason)
        }
    }

    /// Records an unparseable line and answers it, in that order, on this connection's timeline.
    private func recordMalformedRequest(_ rawMethod: String?, from connection: IpcConnection) {
        guard let state = connections[connection.id] else { return }
        try? auditWriter.append(.requestDecodeFailed(
            caller: state.caller,
            rawMethod: rawMethod ?? "<unparseable>",
            outcome: "error"
        ))
        connection.writeErrorResponse(id: .null, code: -32700, message: "parse error")
    }

    private func close(_ connection: IpcConnection, reason: IpcConnectionCloseReason) async {
        guard let state = connections.removeValue(forKey: connection.id) else { return }
        if state.holdsRemoteSlot { remoteSlots.release() }
        try? auditWriter.append(.connectionClosed(
            transport: state.transport,
            peerAddress: state.peerAddress,
            caller: state.caller,
            reason: reason,
            servedRequests: state.servedRequests
        ))
        if let runtimeDispatch {
            await runtimeDispatch.connectionClosed(connection.id)
        }
    }

    private func dispatch(_ request: JsonRpcRequest, from connection: IpcConnection) async {
        guard let state = connections[connection.id] else { return }
        guard let rpcId = request.id else {
            try? auditWriter.append(.requestDropped(caller: state.caller, rawMethod: request.method))
            return
        }
        let typedRequest: IpcRequest
        do {
            typedRequest = try IpcRequest.decode(
                method: request.method,
                params: request.params ?? .object([:])
            )
        } catch let error {
            try? auditWriter.append(.requestDecodeFailed(
                caller: state.caller,
                rawMethod: request.method,
                outcome: "error"
            ))
            connection.writeErrorResponse(id: rpcId, code: error.code, message: error.message)
            return
        }
        let reqId = UUID()

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
            caller: state.caller,
            request: typedRequest,
            connection: connection,
            reqId: reqId,
            audit: audit
        )
    }

    private func dispatchToRuntime(
        caller: IpcCallerIdentity,
        request: IpcRequest,
        connection: IpcConnection,
        reqId: UUID,
        audit: IpcRequestAudit?
    ) async {
        // The one funnel every serviced request passes through, so the close-time count is
        // "requests this connection was actually served" rather than "lines that arrived".
        // A connection a starved instance never dispatched for still reports zero.
        connections[connection.id]?.servedRequests += 1
        if let runtimeDispatch {
            await runtimeDispatch.serve(connection, reqId, audit, caller, request)
        }
    }
}
