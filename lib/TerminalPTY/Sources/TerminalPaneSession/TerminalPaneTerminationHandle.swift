// Process-lifetime access to one PTY host's orderly application-exit ladder.
import TerminalPTYHost

/// Lets the process backend retain and terminate a host without retaining its pane controller.
public struct TerminalPaneTerminationHandle: Sendable {
    private let host: TerminalPTYHost

    /// Captures process-lifetime access without exposing the host actor to app code.
    init(host: TerminalPTYHost) {
        self.host = host
    }

    /// Applies the bounded application-exit ladder and returns after native ownership is released.
    public func terminateForApplicationExit() async {
        await host.terminateForApplicationExit()
    }

    /// Submits process exit without creating a Swift task and signals only after
    /// the retained host has irreversibly released its native ownership.
    public func submitApplicationExitTermination(
        completion: @escaping @Sendable () -> Void
    ) {
        host.submitApplicationExitTermination(completion: completion)
    }
}
