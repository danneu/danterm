// Owns the blocking session reader and makes cancellation a shell-delivery fence.
import Foundation
import Dispatch
import DanTermClient
import DanTermProtocol

/// One synchronous result from the connection reader to the shell.
public enum MobileConnectionRunnerEvent: Equatable, Sendable {
    /// Delivers one classified frame from the session reader.
    case frame(DanTermClientFrame)
    /// Delivers a named user-facing failure while the connection still accepts output.
    case failure(MobileConnectionState)
    /// Reports an ordinary peer close while the connection still accepts output.
    case ended
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
            enqueue(.ended)
        } catch let error as TCPSocketTransportError {
            enqueue(.failure(.failure(error)))
        } catch let error as DanTermClientError {
            enqueue(.failure(.failure(error)))
        } catch {
            // A non-TCP transport is outside the mobile runner's production path. Treat
            // its untyped failure as a local setup defect instead of inventing a UI state.
            enqueue(.failure(.deviceSetupFailure))
        }
    }

    /// Sends through the session's serialized writer path.
    public func send(_ request: JsonRpcRequest) throws {
        try session.send(request)
    }

    /// Stops delivery before waking and joining every active transport operation. The
    /// shell calls this outside the delivery closure, such as from its background handler.
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
