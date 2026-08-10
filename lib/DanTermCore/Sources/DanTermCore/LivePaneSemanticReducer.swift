// Pure latest-value semantic state for one pane. Transport admission, pane
// ownership, product projections, and history do not belong in this file.

/// Records whether a shell integration has ever announced readiness during the
/// current pane lifetime.
enum PaneSemanticIntegration: Equatable {
    case neverReported
    case ready
}

/// Holds the one complete command report that is currently running, without
/// retaining completed or replaced commands as history.
enum PaneSemanticCommand: Equatable {
    case idle
    case running(String)
}

/// Couples remote detection and its optional far-side identity so a local
/// connection with a remote identity cannot be represented.
enum PaneSemanticConnection: Equatable {
    case local
    case remote(identity: RemoteSession?)
}

/// Names only the root-agent activity states that bundled hook surfaces can
/// report without inference.
enum AgentActivity: Equatable {
    case working
    case waiting
    case idle
}

/// Couples an attached session with its optional reported activity so activity
/// cannot outlive or precede attachment in stored state.
enum PaneSemanticAgent: Equatable {
    case none
    case attached(session: AgentSession, activity: AgentActivity?)
}

/// Carries the independent live semantic facets owned by one pane.
struct PaneSemanticState: Equatable {
    var integration: PaneSemanticIntegration = .neverReported
    var command: PaneSemanticCommand = .idle
    var connection: PaneSemanticConnection = .local
    var agent: PaneSemanticAgent = .none
}

/// Defines the typed, pane-ordered events admitted by terminal and agent
/// boundaries before they reach the pure live reducer.
enum PaneSemanticEvent: Equatable {
    case integrationReady
    case commandStarted(String)
    case commandEnded(exitStatus: UInt8)
    case remoteDetected
    case remoteIdentityReported(RemoteSession)
    case connectionEnded
    case agentAttached(AgentSession)
    case agentActivityChanged(session: AgentSession, activity: AgentActivity)
    case agentDetached(AgentSession)
    case paneTornDown
}

/// Applies one admitted pane event without IO, ambient state, or retained
/// history; callers serialize events before invoking it.
func reducePaneSemantics(_ state: inout PaneSemanticState, event: PaneSemanticEvent) {
    switch event {
    case .integrationReady:
        state.integration = .ready

    case .commandStarted(let command):
        state.command = .running(command)

    case .commandEnded:
        guard case .running = state.command else { return }
        state.command = .idle

    case .remoteDetected:
        guard case .local = state.connection else { return }
        state.connection = .remote(identity: nil)

    case .remoteIdentityReported(let identity):
        state.connection = .remote(identity: identity)

    case .connectionEnded:
        state.connection = .local

    case .agentAttached(let session):
        state.agent = .attached(session: session, activity: .working)

    case let .agentActivityChanged(reportingSession, activity):
        guard case .attached(let currentSession, _) = state.agent,
              currentSession == reportingSession
        else {
            return
        }
        state.agent = .attached(session: currentSession, activity: activity)

    case .agentDetached(let reportingSession):
        guard case .attached(let currentSession, _) = state.agent,
              currentSession == reportingSession
        else {
            return
        }
        state.agent = .none

    case .paneTornDown:
        state = PaneSemanticState()
    }
}
