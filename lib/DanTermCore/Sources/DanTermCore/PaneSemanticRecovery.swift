// Pure recovery projection for pane-owned semantics that intentionally outlives live facets.

/// Carries the two semantic values persisted for the next process launch.
struct PaneSemanticRecoverySnapshot: Equatable {
    var command: String?
    var agentSession: AgentSession?

    init(command: String? = nil, agentSession: AgentSession? = nil) {
        self.command = command
        self.agentSession = agentSession
    }
}

/// Retains recovery-only semantic state beside a pane's live semantic stream.
struct PaneSemanticRecoveryState {
    private(set) var snapshot = PaneSemanticRecoverySnapshot()

    /// Applies the semantic transition whose recovery projection may outlive its live facet.
    mutating func apply(_ transition: PaneSemanticTransition) {
        switch transition.event {
        case .commandStarted(let command):
            snapshot.command = command

        case .agentAttached(let session):
            guard transition.didChange else { return }
            snapshot.agentSession = session

        case .agentDetached:
            guard transition.didChange else { return }
            snapshot.agentSession = nil

        case .paneTornDown:
            snapshot = PaneSemanticRecoverySnapshot()

        case .integrationReady, .commandEnded, .remoteDetected,
             .remoteIdentityReported, .connectionEnded, .agentActivityChanged:
            break
        }
    }
}
