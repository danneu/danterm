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

/// Identifies one admitted `waiting` claim so a later input can name the exact
/// wait it ended.
///
/// Opaque and ephemeral: the number is only ever compared, never ordered or
/// read for meaning, and no snapshot persists it. It exists because a wait
/// raised after an input was submitted must survive that input's later
/// delivery, which a bare "the agent is waiting" bit cannot express.
struct AgentWaitGeneration: Equatable {
    let rawValue: UInt64
}

/// The stored form of agent activity, where `waiting` carries the generation
/// that identifies it.
///
/// Separate from `AgentActivity` because a reporter can only name the state; the
/// generation is DanTerm's, minted when the report is admitted. Coupling it to
/// the `waiting` case makes a generation without a wait unrepresentable.
enum AgentActivityState: Equatable {
    case working
    case waiting(generation: AgentWaitGeneration)
    case idle

    /// The state as a reporter named it, for every surface that shows activity
    /// and must not see the generation.
    var reported: AgentActivity {
        switch self {
        case .working: .working
        case .waiting: .waiting
        case .idle: .idle
        }
    }
}

/// Couples an attached session with its optional reported activity so activity
/// cannot outlive or precede attachment in stored state.
enum AgentLifecycle: Equatable {
    case none
    case attached(session: AgentSession, activity: AgentActivityState?)

    /// Decides whether input carrying `waitGeneration` retracts the wait this
    /// lifecycle currently holds.
    ///
    /// The one definition of the retraction rule. `reduceSession` guards with
    /// it, and a runtime fast path that drops an occurrence before it reaches
    /// `update()` must ask this and nothing else -- which is what makes removing
    /// such a fast path unable to change anything observable.
    func retractsWait(carrying waitGeneration: AgentWaitGeneration?) -> Bool {
        guard let waitGeneration,
              case .attached(_, .waiting(let current)) = self
        else {
            return false
        }
        return current == waitGeneration
    }
}

/// Defines the stored facts a terminal session can report to the pure model.
enum SessionReport: Equatable {
    case title(String)
    case cwd(String?)
    case progress(ProgressState?)
    case integrationReady
    case commandStarted(String)
    case commandEnded(exitStatus: UInt8)
    case connectionDeclared(ConnectionLifecycle)
    case agentAttached(AgentSession)
    case agentActivityChanged(session: AgentSession, activity: AgentActivity)
    case agentDetached(AgentSession)
    /// Reports that a user-directed pane input operation put every one of its
    /// bytes across the PTY, carrying the wait generation the model held when
    /// the operation was submitted.
    ///
    /// A hook may assert that a wait began, but only DanTerm can observe the
    /// user ending it, so this is the one report that ends a wait without the
    /// agent saying anything. It retracts rather than replaces: input says the
    /// wait is over, not what the agent does next. `nil` -- no wait was current
    /// at submission -- retracts nothing.
    case userInputDelivered(waitGeneration: AgentWaitGeneration?)
}

/// Applies one admitted report and keeps recovery memo updates atomic with the
/// session transition that accepted them.
func reduceSession(_ session: inout SessionModel, report: SessionReport) {
    switch report {
    case .title(let title):
        session.title = title

    case .cwd(let cwd):
        session.cwd = cwd

    case .progress(let progress):
        session.progress = progress

    case .integrationReady:
        session.integration = .ready

    // Progress is owned by the foreground command that reported it, so both
    // command boundaries end it. Only an explicit `OSC 9;4;0` used to clear it,
    // which left a pane pinned at the last value a killed or buggy program
    // reported, with nothing able to reset it.
    case .commandStarted(let command):
        session.command = .running(command)
        session.lastCommand = command
        session.progress = nil

    case .commandEnded:
        guard case .running = session.command else { return }
        session.command = .idle
        session.progress = nil

    case .connectionDeclared(let connection):
        session.connection = connection

    case .agentAttached(let agentSession):
        // No activity: attaching is not a report that the agent is doing
        // anything. Claude fires SessionStart at launch, so claiming `.working`
        // here left a pane at an untouched prompt reporting work indefinitely.
        session.agent = .attached(session: agentSession, activity: nil)
        session.lastAgentSession = agentSession

    case let .agentActivityChanged(reportingSession, activity):
        guard case .attached(let currentSession, _) = session.agent,
              currentSession == reportingSession
        else {
            return
        }
        let stored: AgentActivityState
        switch activity {
        case .working:
            stored = .working
        case .idle:
            stored = .idle
        // Every admitted wait renews the generation, including one that repeats
        // the visible state. Otherwise a wait raised while an input was in
        // flight would share the retiring wait's identity, and that input's
        // later delivery would erase a wait the user has not seen yet.
        case .waiting:
            stored = .waiting(generation: session.mintWaitGeneration())
        }
        session.agent = .attached(session: currentSession, activity: stored)

    case .userInputDelivered(let waitGeneration):
        guard case .attached(let currentSession, _) = session.agent,
              session.agent.retractsWait(carrying: waitGeneration)
        else {
            return
        }
        session.agent = .attached(session: currentSession, activity: nil)

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
