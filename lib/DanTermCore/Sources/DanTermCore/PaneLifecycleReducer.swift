// Pure ordered lifecycle state for one pane. Transport admission, pane
// ownership, product projections, and history do not belong in this file.

/// Records whether a shell integration has ever announced readiness during the
/// current pane lifetime.
enum IntegrationLatch: Equatable {
    case neverReported
    case ready
}

/// Holds the one complete command report that is currently running, without
/// retaining completed or replaced commands as history.
enum CommandLifecycle: Equatable {
    case idle
    case running(String)
}

/// Couples remote detection and its optional far-side identity so a local
/// connection with a remote identity cannot be represented.
enum ConnectionLifecycle: Equatable {
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
enum AgentLifecycle: Equatable {
    case none
    case attached(session: AgentSession, activity: AgentActivity?)
}

/// Owns the pane-reported lifecycles selected by D1's per-fact test, admitted
/// under D2, and kept exclusive under D3 in
/// docs/design/2026-08-10-terminal-reported-pane-facts.md.
struct PaneLifecycles: Equatable {
    var integration: IntegrationLatch = .neverReported
    var command: CommandLifecycle = .idle
    var connection: ConnectionLifecycle = .local
    var agent: AgentLifecycle = .none
}

/// Defines the typed, pane-ordered events admitted by terminal and agent
/// boundaries before they reach the pure live reducer.
enum PaneLifecycleEvent: Equatable {
    case integrationReady
    case commandStarted(String)
    case commandEnded(exitStatus: UInt8)
    case remoteDetected
    case remoteIdentityReported(RemoteSession)
    case connectionEnded
    case agentAttached(AgentSession)
    case agentActivityChanged(session: AgentSession, activity: AgentActivity)
    case agentDetached(AgentSession)
}

/// Describes one serialized lifecycle input together with the complete snapshots
/// immediately before and after it was reduced.
struct PaneLifecycleTransition: Equatable {
    let event: PaneLifecycleEvent
    let previous: PaneLifecycles
    let current: PaneLifecycles

    /// Lets product projections suppress idempotent and stale inputs without
    /// reimplementing lifecycle transition rules.
    var didChange: Bool { previous != current }
}

/// Owns the ordered reducer state that a pane session stores beside its terminal
/// and lifecycle state.
struct PaneLifecycleStream {
    private(set) var snapshot = PaneLifecycles()

    /// Applies one already-admitted pane event and returns immutable transition
    /// data for product projections and read-only consumers.
    mutating func apply(_ event: PaneLifecycleEvent) -> PaneLifecycleTransition {
        let previous = snapshot
        reducePaneLifecycles(&snapshot, event: event)
        return PaneLifecycleTransition(event: event, previous: previous, current: snapshot)
    }
}

/// Applies one admitted pane event without IO, ambient state, or retained
/// history; callers serialize events before invoking it.
func reducePaneLifecycles(_ state: inout PaneLifecycles, event: PaneLifecycleEvent) {
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

    }
}
