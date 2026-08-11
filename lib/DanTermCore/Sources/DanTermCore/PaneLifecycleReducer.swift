// Pure ordered lifecycle reports for one terminal session. Transport and
// product projections do not belong in this file.

/// Records whether a shell integration has ever announced readiness during the
/// current terminal-session lifetime.
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

/// Defines the lifecycle facts a terminal session can report to the pure model.
enum SessionReport: Equatable {
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

/// Applies one admitted report and keeps recovery memo updates atomic with the
/// lifecycle transition that accepted them.
func reduceSession(_ session: inout SessionModel, report: SessionReport) {
    switch report {
    case .integrationReady:
        session.integration = .ready

    case .commandStarted(let command):
        session.command = .running(command)
        session.lastCommand = command

    case .commandEnded:
        guard case .running = session.command else { return }
        session.command = .idle

    case .remoteDetected:
        guard case .local = session.connection else { return }
        session.connection = .remote(identity: nil)

    case .remoteIdentityReported(let identity):
        session.connection = .remote(identity: identity)

    case .connectionEnded:
        session.connection = .local

    case .agentAttached(let agentSession):
        session.agent = .attached(session: agentSession, activity: .working)
        session.lastAgentSession = agentSession

    case let .agentActivityChanged(reportingSession, activity):
        guard case .attached(let currentSession, _) = session.agent,
              currentSession == reportingSession
        else {
            return
        }
        session.agent = .attached(session: currentSession, activity: activity)

    case .agentDetached(let reportingSession):
        guard case .attached(let currentSession, _) = session.agent,
              currentSession == reportingSession
        else {
            return
        }
        session.agent = .none
        session.lastAgentSession = nil
    }
}
