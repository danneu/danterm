// The client half of the DanTerm control conversation: the hello handshake, line
// framing, request/reply correlation, and notification delivery.
//
// This is the one implementation of that conversation. It reads through
// `IpcLineFramer`, the same framer the server side uses, so neither end has a framing
// copy of its own. What does not belong here: how a byte stream is opened (see
// ClientTransport.swift), and what any particular reply means (the caller's problem).
import Foundation
import DanTermProtocol

/// One frame off the wire, already classified. A reply the caller is not waiting for and
/// a notification are both real frames, so both are delivered rather than discarded.
public enum DanTermClientFrame: Equatable, Sendable {
    case response(JsonRpcResponse)
    case notification(method: String, params: JSONValue?)
}

/// Every way the conversation itself can fail, stated once so a caller never reads errno
/// or re-derives the handshake rules. Transport failures are not in here: they come from
/// the transport and pass through untouched.
public enum DanTermClientError: Error, Equatable, Sendable {
    /// The caller cancelled this session before the operation began.
    case cancelled
    /// The peer closed the stream before sending its opening hello.
    case closedBeforeHello
    /// The first line arrived but was not a hello this client can read.
    case invalidHello
    /// The tailnet node id is not in the server's admitted set.
    case notAdmitted
    /// The server could not resolve the connection to a tailnet identity.
    case identityUnresolved
    /// The server has no connection slot available, with the silence bound that server
    /// stated in the refusal -- the deadline by which it has provably reclaimed a dead
    /// peer's slot, so the earliest a retry can help. Nil when the refusal stated none.
    case connectionLimit(IpcLivenessBound?)
    /// The server cannot provide the durable audit record required for remote service.
    case auditUnavailable
    /// The server spoke a protocol version this client cannot use.
    case unsupportedProtocol(Int)
    /// A line exceeded the framer's limit, so the stream can no longer be trusted.
    case oversizedLine
    /// No byte arrived within the bound in force, so the peer is treated as gone and this
    /// session's transport resources are released.
    case peerSilent
}

/// Identifies the server build after protocol compatibility has been established.
public struct DanTermServerHello: Equatable, Sendable {
    /// The app version is advisory, so callers can warn about skew without refusing it.
    public let appVersion: String
    /// The silence bound this server advertised, or nil when it advertised none this
    /// client can use. The number is the server's to state: a client constant would be
    /// a second, independently tuned rule about the same connection.
    public let livenessBound: IpcLivenessBound?
}

/// Drives a DanTerm control conversation over one transport.
///
/// The correlation rule is the reason this type exists rather than a read loop at each
/// call site: while a request awaits its reply, notifications and replies to other
/// requests keep arriving, and every one of them is a frame the caller may still want.
/// They are deferred in arrival order instead of being discarded, so awaiting a reply
/// never loses a tape record that overtook it.
///
/// Any number of threads may call `send` while one thread owns frame consumption through
/// `handshake`, `awaitReply`, `nextNotification`, or `nextFrame`. Do not split frame
/// consumption across threads. `cancel` may run from any thread: it wakes a blocked read,
/// waits for every active transport operation, and makes later sends throw `cancelled`.
///
/// On a transport whose kind declares itself under the liveness contract, the session also
/// runs a watchdog: it pays the client's ping obligation and reports `peerSilent` when no
/// byte arrives within the bound in force. No call site chooses that -- the transport kind
/// does -- so a remote stream cannot be opened without it.
public final class DanTermClientSession: @unchecked Sendable {
    /// The protocol version this client speaks. A hello naming any other version is
    /// refused before a request is sent.
    public static let supportedProtocolVersion = danTermIpcProtocolVersion

    /// How long a client under the contract waits for the server's opening hello.
    ///
    /// This is the one number the client owns, and it governs only the phase in which the
    /// server has not yet stated its own. It is generous against a slow first round trip
    /// and still far short of a wait a person would read as a hang.
    public static let establishmentBound = IpcLivenessBound(seconds: 10)!

    private let transport: any DanTermClientTransport
    /// Present only on a transport under the liveness contract. An exempt stream has no
    /// watchdog at all, which is what lets a local follow idle for as long as it likes.
    private var monitor: PeerLivenessMonitor?
    private let sendLock = NSLock()
    private let readLock = NSLock()
    private let lifecycle = NSCondition()
    private enum LifecycleState {
        case open
        case cancelling
        case cancelled
    }
    private var lifecycleState = LifecycleState.open
    private var framer = IpcLineFramer()
    /// Whole lines already framed out of a received chunk, not yet classified.
    private var unread: [Data] = []
    /// Frames read while looking for something else, in the order they arrived.
    private var deferred: [DanTermClientFrame] = []
    /// Set once, by the watchdog, so a woken read reports peer death rather than the
    /// ordinary cancellation the same wake-up looks like.
    private var deathReason: DanTermClientError?

    /// Whether this session runs under the liveness contract is the transport kind's
    /// declaration, never a caller's argument. `establishmentBound` only bounds the wait
    /// before the server states its own, and exists as a parameter so a test can compress
    /// that phase without a clock of its own.
    public init(
        transport: any DanTermClientTransport,
        establishmentBound: IpcLivenessBound = DanTermClientSession.establishmentBound
    ) {
        self.transport = transport
        if type(of: transport).livenessPolicy == .underContract {
            monitor = PeerLivenessMonitor(establishmentBound: establishmentBound, delegate: self)
        }
    }

    /// Ends the watchdog when a session is dropped without being closed, so no thread
    /// outlives the conversation it was watching.
    deinit { monitor?.stop() }

    /// Reads the peer's opening hello and refuses a protocol version this client cannot
    /// speak. Call this before sending anything.
    @discardableResult
    public func handshake() throws -> DanTermServerHello {
        try withReadLock {
            guard let line = try nextLine() else { throw DanTermClientError.closedBeforeHello }
            guard let notification = try? JSONDecoder().decode(
                JsonRpcRequest.self,
                from: line
            ) else {
                throw DanTermClientError.invalidHello
            }
            if let rejection = IpcConnectionRejectionReason(notification: notification) {
                throw Self.clientError(for: rejection, params: notification.params)
            }
            guard notification.method == Methods.hello,
                  let versionNumber = notification.params?["protocol"]?.asNumber,
                  let version = Int(exactly: versionNumber),
                  let appVersion = notification.params?["app"]?.asString
            else { throw DanTermClientError.invalidHello }
            guard version == Self.supportedProtocolVersion else {
                throw DanTermClientError.unsupportedProtocol(version)
            }
            let advertised = IpcLivenessBound.read(from: notification.params)
            if let monitor {
                // A stream under the contract needs the number, and only the server may
                // state it. A hello that omits it leaves this client with no bound it is
                // allowed to apply, so the hello is unusable rather than an invitation to
                // invent a second rule.
                guard let advertised else { throw DanTermClientError.invalidHello }
                monitor.adoptAdvertisedBound(advertised)
            }
            return DanTermServerHello(appVersion: appVersion, livenessBound: advertised)
        }
    }

    /// Writes one complete request without interleaving it with a concurrent sender.
    /// Correlating its reply is a separate step, so several requests may be outstanding.
    public func send(_ request: JsonRpcRequest) throws {
        try sendLock.withLock {
            guard cancellationRequested == false else { throw endOfSessionError }
            do {
                try transport.send(encodeIpcLine(request))
            } catch {
                if cancellationRequested { throw endOfSessionError }
                throw error
            }
        }
    }

    /// Returns the reply to `id`, or nil if the peer closed the stream without sending it.
    ///
    /// Nil is not always a failure: a request that ends the instance takes the stream down
    /// with it, so only the caller knows whether a missing reply is the expected outcome.
    public func awaitReply(id: JSONValue) throws -> JsonRpcResponse? {
        try withReadLock {
            if let index = deferred.firstIndex(where: { frame in
                if case .response(let response) = frame { return response.id == id }
                return false
            }) {
                guard case .response(let response) = deferred.remove(at: index) else {
                    return nil
                }
                return response
            }
            while let frame = try readFrame() {
                if case .response(let response) = frame, response.id == id { return response }
                deferred.append(frame)
            }
            return nil
        }
    }

    /// Returns the next server-initiated notification, so a subscription reads as a stream
    /// rather than as a series of replies. Returns nil at end of stream.
    public func nextNotification() throws -> (method: String, params: JSONValue?)? {
        try withReadLock {
            if let index = deferred.firstIndex(where: { frame in
                if case .notification = frame { return true }
                return false
            }) {
                guard case .notification(let method, let params) = deferred.remove(at: index) else {
                    return nil
                }
                return (method, params)
            }
            while let frame = try readFrame() {
                if case .notification(let method, let params) = frame { return (method, params) }
                deferred.append(frame)
            }
            return nil
        }
    }

    /// Returns the next frame of any kind, oldest deferred frame first. This is what makes
    /// "no frame is dropped" observable: a reply nobody awaited is still here afterwards.
    public func nextFrame() throws -> DanTermClientFrame? {
        try withReadLock {
            if deferred.isEmpty == false { return deferred.removeFirst() }
            return try readFrame()
        }
    }

    /// Cancels the session, waits for active transport operations, and fences later sends.
    public func cancel() {
        lifecycle.lock()
        switch lifecycleState {
        case .cancelled:
            lifecycle.unlock()
            return
        case .cancelling:
            while lifecycleState != .cancelled { lifecycle.wait() }
            lifecycle.unlock()
            return
        case .open:
            lifecycleState = .cancelling
            lifecycle.unlock()
        }

        monitor?.stop()
        transport.close()

        lifecycle.lock()
        lifecycleState = .cancelled
        lifecycle.broadcast()
        lifecycle.unlock()
    }

    /// Preserves the short-lived client's close spelling while using cancellation semantics.
    public func close() { cancel() }

    private static func clientError(
        for rejection: IpcConnectionRejectionReason,
        params: JSONValue?
    ) -> DanTermClientError {
        switch rejection {
        case .notAdmitted: .notAdmitted
        case .identityUnresolved: .identityUnresolved
        case .connectionLimit: .connectionLimit(IpcLivenessBound.read(from: params))
        case .auditUnavailable: .auditUnavailable
        }
    }

    /// Classifies one line. A frame carrying an id is a reply; anything else with a method
    /// is a notification. A line that is neither is skipped rather than failing the stream,
    /// because a peer that gained a frame kind must not break a client that predates it.
    private func readFrame() throws -> DanTermClientFrame? {
        while let line = try nextLine() {
            if let response = try? JSONDecoder().decode(JsonRpcResponse.self, from: line),
               response.id != nil,
               response.id != .null {
                // A pong answers a request this client made on its own behalf, so it is
                // absorbed here and never reaches a consumer or the deferred queue.
                if PeerLivenessMonitor.isPingReply(id: response.id) { continue }
                return .response(response)
            }
            if let request = try? JSONDecoder().decode(JsonRpcRequest.self, from: line) {
                return .notification(method: request.method, params: request.params)
            }
        }
        return nil
    }

    private func nextLine() throws -> Data? {
        while true {
            if unread.isEmpty == false { return unread.removeFirst() }
            if let dead = ifDead() { throw dead }
            if cancellationRequested { return nil }
            let chunk: Data
            do {
                monitor?.readWaitBegan()
                defer { monitor?.readWaitEnded() }
                chunk = try transport.receive()
            } catch {
                if let dead = ifDead() { throw dead }
                if cancellationRequested { return nil }
                throw error
            }
            if let dead = ifDead() { throw dead }
            if cancellationRequested { return nil }
            if chunk.isEmpty { return nil }
            for event in framer.append(chunk) {
                switch event {
                case .line(let line):
                    if line.isEmpty == false { unread.append(line) }
                case .oversized:
                    throw DanTermClientError.oversizedLine
                }
            }
        }
    }

    private var cancellationRequested: Bool {
        lifecycle.withLock { lifecycleState != .open }
    }

    /// The failure a woken operation reports: peer death when the watchdog ended this
    /// session, and plain cancellation when its owner did.
    private var endOfSessionError: DanTermClientError {
        ifDead() ?? .cancelled
    }

    /// Reports peer death once the watchdog has recorded it, so the same wake-up that
    /// cancellation causes is not mistaken for one the caller asked for.
    private func ifDead() -> DanTermClientError? {
        lifecycle.withLock { deathReason }
    }

    private func withReadLock<T>(_ operation: () throws -> T) rethrows -> T {
        readLock.lock()
        defer { readLock.unlock() }
        return try operation()
    }
}

extension DanTermClientSession: PeerLivenessMonitorDelegate {
    func sendLivenessPing(_ request: JsonRpcRequest) -> Bool {
        do {
            try send(request)
            return true
        } catch {
            return false
        }
    }

    func peerDeclaredSilent() {
        lifecycle.lock()
        // A session whose owner already cancelled it keeps the owner's outcome. The
        // watchdog can race a cancel -- its ping fails because the transport is closing --
        // and reporting that as peer death would show a user their own action as a loss.
        guard lifecycleState == .open else {
            lifecycle.unlock()
            return
        }
        deathReason = .peerSilent
        lifecycle.unlock()
        // Cancellation is the teardown: it wakes the parked read and releases the
        // transport's resources. The reason recorded above is what turns the wake-up
        // into a reported death rather than a silent end of stream.
        cancel()
    }
}
