// Pure recovery projection for pane-owned state that intentionally outlives live lifecycles.

/// Carries the two lifecycle-derived values persisted for the next process launch.
struct PaneLifecycleRecoverySnapshot: Equatable {
    var command: String?
    var agentSession: AgentSession?

    init(command: String? = nil, agentSession: AgentSession? = nil) {
        self.command = command
        self.agentSession = agentSession
    }
}

/// Retains recovery-only state beside a pane's live lifecycle stream.
struct PaneLifecycleRecoveryState {
    private(set) var snapshot = PaneLifecycleRecoverySnapshot()

    /// Applies the transition whose recovery projection may outlive its live lifecycle.
    mutating func apply(_ transition: PaneLifecycleTransition) {
        switch transition.event {
        case .commandStarted(let command):
            snapshot.command = command

        case .agentAttached(let session):
            guard transition.didChange else { return }
            snapshot.agentSession = session

        case .agentDetached:
            guard transition.didChange else { return }
            snapshot.agentSession = nil

        case .integrationReady, .commandEnded, .remoteDetected,
             .remoteIdentityReported, .connectionEnded, .agentActivityChanged:
            break
        }
    }
}
