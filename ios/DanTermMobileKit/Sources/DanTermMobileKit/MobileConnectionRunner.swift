// Owns the blocking session reader and makes cancellation a shell-delivery fence.
import Foundation
import Dispatch
import DanTermClient
import DanTermProtocol

/// One synchronous result from the connection reader to the shell.
public enum MobileConnectionRunnerEvent: Equatable, Sendable {
    /// Delivers one classified frame from the session reader.
    case frame(DanTermClientFrame)
    /// Reports the typed cause that ended this connection. It is typed rather than a
    /// user-facing state because the shell's reconnect policy schedules on the cause: a
    /// dropped stream is worth another attempt and a malformed line is not, and both
    /// present the same words.
    case failed(MobileConnectionFailure)
}

/// Runs one session reader and guarantees that cancellation outlives all shell callbacks.
public final class MobileConnectionRunner: @unchecked Sendable {
    private let session: DanTermClientSession
    private let deliveryQueue: DispatchQueue
    private let deliveryLock = NSRecursiveLock()
    private let deliver: @Sendable (MobileConnectionRunnerEvent) -> Void
    private var acceptsDelivery = true

    /// Binds one session lifetime to one serialized shell-delivery path. The main queue
    /// is the default so UIKit can consume events without a second asynchronous hop.
    public init(
        session: DanTermClientSession,
        deliveryQueue: DispatchQueue = .main,
        deliver: @Sendable @escaping (MobileConnectionRunnerEvent) -> Void
    ) {
        self.session = session
        self.deliveryQueue = DispatchQueue(
            label: "com.danneu.danterm.mobile-connection-delivery",
            target: deliveryQueue
        )
        self.deliver = deliver
    }

    /// Reads until the stream ends or cancellation fences the delivery path. Call this
    /// exactly once, on a thread the shell reserves for blocking session reads.
    public func run() {
        do {
            while let frame = try session.nextFrame() {
                enqueue(.frame(frame))
            }
            // A clean end of frames is the peer closing the connection it was serving.
            enqueue(.failed(.transport(.peerClosed, phase: .established)))
        } catch let error as TCPSocketTransportError {
            enqueue(.failed(.transport(error, phase: .established)))
        } catch let error as DanTermClientError {
            enqueue(.failed(.conversation(error, phase: .established)))
        } catch {
            // A non-TCP transport is outside the mobile runner's production path. Treat
            // its untyped failure as a local defect instead of inventing a cause.
            enqueue(.failed(.deviceSetup))
        }
    }

    /// Sends through the session's serialized writer path.
    public func send(_ request: JsonRpcRequest) throws {
        try session.send(request)
    }

    /// Stops delivery before waking and joining every active transport operation. The
    /// delivery lock is recursive so the shell may also call this from inside a delivery,
    /// which is how one connection's first reported cause fences every later one.
    public func cancel() {
        deliveryLock.withLock { acceptsDelivery = false }
        session.cancel()
    }

    private func enqueue(_ event: MobileConnectionRunnerEvent) {
        deliveryQueue.async { [weak self] in
            self?.deliverIfActive(event)
        }
    }

    private func deliverIfActive(_ event: MobileConnectionRunnerEvent) {
        deliveryLock.withLock {
            guard acceptsDelivery else { return }
            deliver(event)
        }
    }
}
