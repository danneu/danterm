// Process-lifetime access to one PTY host's shutdown and quiescence callbacks.
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
