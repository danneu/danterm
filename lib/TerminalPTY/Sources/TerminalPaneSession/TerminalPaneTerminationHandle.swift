// Process-lifetime access and retention for PTY host shutdown and quiescence.
import Dispatch
import Synchronization
import TerminalPTYHost

/// Lets the process backend retain and terminate a host without retaining its pane controller.
public struct TerminalPaneTerminationHandle: Sendable {
    private let host: TerminalPTYHost

    /// Captures process-lifetime access without exposing the host actor to app code.
    init(host: TerminalPTYHost) {
        self.host = host
    }

    /// Observes host quiescence without retaining the pane controller or initiating shutdown.
    public func whenQuiescent(_ observer: @escaping @Sendable () -> Void) {
        host.whenQuiescent(observer)
    }

    /// Requests the host's idempotent shutdown transaction from any process-lifetime owner.
    public func requestShutdown(
        completion: (@Sendable () -> Void)? = nil
    ) {
        host.requestShutdown(completion: completion)
    }
}

/// Keeps native pane ownership independent of controller and main-actor lifetimes.
public final class TerminalPaneTerminationRegistry: Sendable {
    private let storage = Mutex((
        nextID: UInt64(0),
        handles: [UInt64: TerminalPaneTerminationHandle]()
    ))

    public init() {}

    /// Retains a host until its own queue publishes irreversible quiescence.
    public func retain(_ handle: TerminalPaneTerminationHandle) {
        let id = storage.withLock { storage in
            let id = storage.nextID
            storage.nextID &+= 1
            storage.handles[id] = handle
            return id
        }
        handle.whenQuiescent { [weak self] in
            self?.storage.withLock { storage in
                _ = storage.handles.removeValue(forKey: id)
            }
        }
    }

    /// Requests every currently retained shutdown and blocks until all are quiescent.
    public func requestShutdownAndWait() {
        let snapshot = storage.withLock { Array($0.handles.values) }
        guard snapshot.isEmpty == false else { return }

        let completions = DispatchGroup()
        for handle in snapshot {
            completions.enter()
            handle.requestShutdown {
                completions.leave()
            }
        }
        completions.wait()
    }

    package var retainedCount: Int {
        storage.withLock { $0.handles.count }
    }
}
