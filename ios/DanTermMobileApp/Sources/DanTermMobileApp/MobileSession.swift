// Opens one blocking client conversation and hands its frames to the main-actor shell.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Dispatch
import Foundation

/// Transfers a fully handshaken session and its opening roster to the shell.
struct MobileSessionBootstrap: Sendable {
    let session: DanTermClientSession
    let roster: PaneRoster
    let serverVersion: String
}

/// Keeps establishment failures inside the shell's complete typed-cause vocabulary.
///
/// It carries the cause rather than the user-facing state because the shell's reconnect
/// policy schedules on the cause; the state it presents is derived from it.
enum MobileSessionBootstrapResult: Sendable {
    case connected(MobileSessionBootstrap)
    case failed(MobileConnectionFailure)
}

/// Owns a cancellable connection attempt before the long-lived runner takes over.
final class MobileSessionAttempt: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let lock = NSLock()
    private var session: DanTermClientSession?
    private var cancelled = false

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Opens and handshakes on a worker thread before transferring session ownership.
    func start(deliver: @Sendable @escaping (MobileSessionBootstrapResult) -> Void) {
        let thread = Thread { [self] in
            do {
                // No socket receive timeout: a TCP stream is under the liveness contract,
                // so the session's own watchdog bounds the wait -- by its establishment
                // policy until hello arrives, and by the server's advertised bound after.
                // A socket timeout here would be a second, differently tuned silence rule
                // about the same connection.
                let transport = try TCPSocketTransport(
                    host: host,
                    port: port,
                    connectTimeout: 5,
                    receiveTimeout: nil,
                    sendTimeout: 5
                )
                let opened = DanTermClientSession(transport: transport)
                var handedOff = false
                defer {
                    if handedOff == false { opened.cancel() }
                }
                lock.withLock { session = opened }
                if lock.withLock({ cancelled }) {
                    opened.cancel()
                    return
                }
                let hello = try opened.handshake()
                let requestId = MobileRequestId(UUID().uuidString)
                try opened.send(JsonRpcRequest(
                    id: requestId.jsonValue,
                    method: IpcRequestMethod.roster.rawValue,
                    params: .object([:])
                ))
                // No reply and no error: the frames ran out, which is the peer closing
                // the connection it had already handshaken on.
                guard let reply = try opened.awaitReply(id: requestId.jsonValue) else {
                    deliver(.failed(.transport(.peerClosed, phase: .establishing)))
                    return
                }
                if let error = reply.error {
                    deliver(.failed(.requestRefused(reason: error.message)))
                    return
                }
                guard let result = reply.result else {
                    deliver(.failed(.deviceSetup))
                    return
                }
                guard let roster = PaneRoster(jsonValue: result) else {
                    deliver(.failed(.deviceSetup))
                    return
                }
                handedOff = true
                deliver(.connected(MobileSessionBootstrap(
                    session: opened,
                    roster: roster,
                    serverVersion: hello.appVersion
                )))
            } catch let error as TCPSocketTransportError {
                deliver(.failed(.transport(error, phase: .establishing)))
            } catch let error as DanTermClientError {
                // Everything this closure does is establishment, up to and including the
                // opening roster, so silence here means the Mac never answered.
                deliver(.failed(.conversation(error, phase: .establishing)))
            } catch {
                deliver(.failed(.deviceSetup))
            }
        }
        thread.name = "danterm-mobile-connect"
        thread.start()
    }

    /// Unblocks any active socket operation and prevents a pending connection from continuing.
    func cancel() {
        let active = lock.withLock { () -> DanTermClientSession? in
            cancelled = true
            return session
        }
        active?.cancel()
    }
}
