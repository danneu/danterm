// Behavioral tests for lifecycle transitions in the session report reducer.
import Testing

@testable import DanTermCore

struct PaneLifecycleReducerTests {
    @Test("pane stream preserves ordered interleaving")
    func paneStreamPreservesOrdering() throws {
        let session = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        var state = SessionModel(id: SessionId())

        for report: SessionReport in [
            .integrationReady,
            .commandStarted("claude"),
            .agentAttached(session),
            .connectionDeclared(.remote(identity: nil)),
            .agentActivityChanged(session: session, activity: .waiting),
            .commandEnded(exitStatus: 0),
        ] {
            reduceSession(&state, report: report)
        }

        #expect(state.integration == .ready)
        #expect(state.command == .idle)
        #expect(state.connection == .remote(identity: nil))
        #expect(state.agent == .attached(session: session, activity: .waiting))
    }

    @Test("initial state has no reported live lifecycles")
    func initialStateIsEmpty() {
        let state = SessionModel(id: SessionId())
        #expect(state.integration == .neverReported)
        #expect(state.command == .idle)
        #expect(state.connection == .local)
        #expect(state.agent == .none)
    }

    @Test("integration readiness is idempotent")
    func integrationReadinessIsIdempotent() {
        let state = reduce([.integrationReady, .integrationReady])

        #expect(state.integration == .ready)
        #expect(state.command == .idle)
        #expect(state.connection == .local)
        #expect(state.agent == .none)
    }

    @Test("new command replaces a dangling command and end while idle is ignored")
    func commandTransitionsAreTotal() {
        var state = reduce([
            .commandEnded(exitStatus: 90),
            .commandStarted("first command"),
            .commandStarted("replacement command"),
        ])

        #expect(state.command == .running("replacement command"))

        reduceSession(&state, report: .commandEnded(exitStatus: 23))
        reduceSession(&state, report: .commandEnded(exitStatus: 0))

        #expect(state.command == .idle)
    }

    @Test("command end leaves connection and agent lifetimes intact")
    func commandEndDoesNotEndIndependentLifetimes() throws {
        let session = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let remote = RemoteSession(user: "dan", host: "caja")
        let state = reduce([
            .integrationReady,
            .commandStarted("make test"),
            .connectionDeclared(.remote(identity: remote)),
            .agentAttached(session),
            .agentActivityChanged(session: session, activity: .waiting),
            .commandEnded(exitStatus: 1),
        ])

        #expect(state.integration == .ready)
        #expect(state.command == .idle)
        #expect(state.connection == .remote(identity: remote))
        #expect(state.agent == .attached(session: session, activity: .waiting))
    }

    // Intent: reported progress belongs to the foreground command that emitted
    // it, so a command boundary in either direction ends it.
    // Why it exists: progress was only ever cleared by an explicit `OSC 9;4;0`.
    // A program that exited without sending one -- killed, crashed, or just
    // buggy -- pinned the pane's indicator at its last reported value forever,
    // with no command, menu item, or CLI able to reset it.
    // Scenario: a Claude pane reported 0% and was interrupted before it could
    // clear, leaving an idle pane showing an active progress bar.
    @Test("a command boundary ends the progress that command reported")
    func commandBoundariesEndReportedProgress() {
        var state = reduce([
            .commandStarted("claude"),
            .progress(.set(percent: 0)),
            .commandEnded(exitStatus: 130),
        ])

        #expect(state.progress == nil)

        // A command that dies without a reported end still cannot leak its
        // progress into the next one.
        reduceSession(&state, report: .commandStarted("just test"))
        reduceSession(&state, report: .progress(.indeterminate))
        reduceSession(&state, report: .commandStarted("just test-ui"))

        #expect(state.progress == nil)
    }

    @Test("connection declarations assign the whole state and identical reports are steady")
    func connectionDeclarationsAreAssignments() {
        let remote = RemoteSession(user: "dan", host: "caja")
        var state = reduce([
            .connectionDeclared(.remote(identity: remote)),
            .connectionDeclared(.remote(identity: nil)),
        ])

        #expect(state.connection == .remote(identity: nil))
        let beforeRepeatedDeclaration = state
        reduceSession(&state, report: .connectionDeclared(.remote(identity: nil)))
        #expect(state == beforeRepeatedDeclaration)

        reduceSession(&state, report: .connectionDeclared(.local))

        #expect(state.connection == .local)
    }

    @Test("nested connection return restores the enclosing declaration without a stack")
    func nestedConnectionReturnRestoresEnclosingDeclaration() {
        let outer = RemoteSession(user: "dan", host: "outer")
        let inner = RemoteSession(user: "root", host: "inner")
        let state = reduce([
            .connectionDeclared(.remote(identity: outer)),
            .connectionDeclared(.remote(identity: nil)),
            .connectionDeclared(.remote(identity: inner)),
            .connectionDeclared(.remote(identity: outer)),
        ])

        #expect(state.connection == .remote(identity: outer))
    }

    @Test("agent activity requires an attachment and detach is idempotent")
    func agentTransitionsAreTotal() throws {
        let session = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        var state = reduce([
            .agentActivityChanged(session: session, activity: .working),
            .agentAttached(session),
            .agentActivityChanged(session: session, activity: .working),
            .agentActivityChanged(session: session, activity: .waiting),
            .agentActivityChanged(session: session, activity: .idle),
        ])

        #expect(state.agent == .attached(session: session, activity: .idle))

        reduceSession(&state, report: .agentDetached(session))
        reduceSession(
            &state,
            report: .agentActivityChanged(session: session, activity: .working)
        )
        reduceSession(&state, report: .agentDetached(session))

        #expect(state.agent == .none)
    }

    // Intent: attaching reports no activity, and clears whatever the previous
    // session reported.
    // Why it exists: attachment used to claim `.working`, which is a state no
    // hook ever sent. A Claude pane sitting at an empty prompt reported working
    // indefinitely, because Claude fires SessionStart at launch and the next
    // event is the Stop of a turn the user had not started yet.
    // Scenario: a pane attaches, reports waiting, then a second agent replaces
    // the first.
    @Test("agent attachment reports no activity and replaces stale activity")
    func agentAttachmentReportsNoActivity() throws {
        let first = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let replacement = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        var state = reduce([.agentAttached(first)])

        #expect(state.agent == .attached(session: first, activity: nil))

        reduceSession(&state, report: .agentActivityChanged(session: first, activity: .waiting))
        reduceSession(&state, report: .agentAttached(replacement))

        #expect(state.agent == .attached(session: replacement, activity: nil))
    }

    @Test("stale agent events cannot mutate a replacement session")
    func staleAgentEventsDoNotMutateReplacement() throws {
        let stale = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let current = try #require(AgentSession(kind: "claude", sessionId: "session-2"))
        let state = reduce([
            .agentAttached(stale),
            .agentAttached(current),
            .agentActivityChanged(session: stale, activity: .waiting),
            .agentDetached(stale),
        ])

        #expect(state.agent == .attached(session: current, activity: nil))
    }

    private func reduce(_ reports: [SessionReport]) -> SessionModel {
        var state = SessionModel(id: SessionId())
        for report in reports {
            reduceSession(&state, report: report)
        }
        return state
    }
}
