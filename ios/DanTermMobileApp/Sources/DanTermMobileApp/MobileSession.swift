// Opens one blocking client conversation and hands its frames to the main-actor shell.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Dispatch
import Foundation

/// Transfers a fully handshaken session and its first pane list to the shell.
struct MobileSessionBootstrap: Sendable {
    let session: DanTermClientSession
    let panes: [MobilePaneListItem]
    let serverVersion: String
}

/// Keeps background setup failures inside the shell's complete state vocabulary.
enum MobileSessionBootstrapResult: Sendable {
    case connected(MobileSessionBootstrap)
    case failed(MobileConnectionState)
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
                let requestId = JSONValue.string(UUID().uuidString)
                try opened.send(JsonRpcRequest(
                    id: requestId,
                    method: IpcRequestMethod.ls.rawValue,
                    params: .object([:])
                ))
                guard let reply = try opened.awaitReply(id: requestId) else {
                    deliver(.failed(.connectionLost))
                    return
                }
                if let error = reply.error {
                    deliver(.failed(.requestRefused(reason: error.message)))
                    return
                }
                guard let result = reply.result else {
                    deliver(.failed(.deviceSetupFailure))
                    return
                }
                let panes = try projectPaneList(from: result)
                handedOff = true
                deliver(.connected(MobileSessionBootstrap(
                    session: opened,
                    panes: panes,
                    serverVersion: hello.appVersion
                )))
            } catch let error as TCPSocketTransportError {
                deliver(.failed(.failure(error)))
            } catch let error as DanTermClientError {
                deliver(.failed(.failure(error)))
            } catch {
                deliver(.failed(.deviceSetupFailure))
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
