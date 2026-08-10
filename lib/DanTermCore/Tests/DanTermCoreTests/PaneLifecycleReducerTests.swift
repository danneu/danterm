// Behavioral tests for the pure latest-value pane lifecycle reducer.
import Testing

@testable import DanTermCore

struct PaneLifecycleReducerTests {
    @Test("pane stream preserves ordered interleaving")
    func paneStreamPreservesOrdering() throws {
        let session = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        var stream = PaneLifecycleStream()

        _ = stream.apply(.integrationReady)
        _ = stream.apply(.commandStarted("claude"))
        _ = stream.apply(.agentAttached(session))
        _ = stream.apply(.remoteDetected)
        _ = stream.apply(.agentActivityChanged(session: session, activity: .waiting))
        _ = stream.apply(.commandEnded(exitStatus: 0))

        #expect(stream.snapshot.integration == .ready)
        #expect(stream.snapshot.command == .idle)
        #expect(stream.snapshot.connection == .remote(identity: nil))
        #expect(stream.snapshot.agent == .attached(session: session, activity: .waiting))
    }

    @Test("initial state has no reported live lifecycles")
    func initialStateIsEmpty() {
        #expect(PaneLifecycles() == PaneLifecycles(
            integration: .neverReported,
            command: .idle,
            connection: .local,
            agent: .none
        ))
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

        reducePaneLifecycles(&state, event: .commandEnded(exitStatus: 23))
        reducePaneLifecycles(&state, event: .commandEnded(exitStatus: 0))

        #expect(state.command == .idle)
    }

    @Test("command end leaves connection and agent lifetimes intact")
    func commandEndDoesNotEndIndependentLifetimes() throws {
        let session = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let remote = RemoteSession(user: "dan", host: "caja")
        let state = reduce([
            .integrationReady,
            .commandStarted("make test"),
            .remoteIdentityReported(remote),
            .agentAttached(session),
            .agentActivityChanged(session: session, activity: .waiting),
            .commandEnded(exitStatus: 1),
        ])

        #expect(state.integration == .ready)
        #expect(state.command == .idle)
        #expect(state.connection == .remote(identity: remote))
        #expect(state.agent == .attached(session: session, activity: .waiting))
    }

    @Test("remote detection preserves a reported identity")
    func remoteDetectionPreservesIdentity() {
        let remote = RemoteSession(user: "dan", host: "caja")
        let state = reduce([
            .remoteIdentityReported(remote),
            .remoteDetected,
        ])

        #expect(state.connection == .remote(identity: remote))
    }

    @Test("remote without identity is steady and upgrades in place")
    func identitylessRemoteUpgradesInPlace() {
        let remote = RemoteSession(user: "dan", host: "caja")
        var state = reduce([.remoteDetected, .remoteDetected])

        #expect(state.connection == .remote(identity: nil))

        reducePaneLifecycles(&state, event: .remoteIdentityReported(remote))

        #expect(state.connection == .remote(identity: remote))
    }

    @Test("nested remote reports restore the enclosing identity")
    func nestedRemoteReportsRestoreEnclosingIdentity() {
        let outer = RemoteSession(user: "dan", host: "outer")
        let inner = RemoteSession(user: "root", host: "inner")
        var state = reduce([
            .remoteDetected,
            .remoteIdentityReported(outer),
            .remoteDetected,
            .remoteIdentityReported(inner),
            .connectionEnded,
            .remoteIdentityReported(outer),
        ])

        #expect(state.connection == .remote(identity: outer))

        reducePaneLifecycles(&state, event: .connectionEnded)
        reducePaneLifecycles(&state, event: .connectionEnded)

        #expect(state.connection == .local)
    }

    @Test("nested identityless remote returns through the enclosing report")
    func nestedIdentitylessRemoteReturnsThroughEnclosingReport() {
        let outer = RemoteSession(user: "dan", host: "outer")
        let state = reduce([
            .remoteDetected,
            .remoteIdentityReported(outer),
            .remoteDetected,
            .connectionEnded,
            .remoteIdentityReported(outer),
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

        reducePaneLifecycles(&state, event: .agentDetached(session))
        reducePaneLifecycles(
            &state,
            event: .agentActivityChanged(session: session, activity: .working)
        )
        reducePaneLifecycles(&state, event: .agentDetached(session))

        #expect(state.agent == .none)
    }

    @Test("agent attachment starts working and replaces stale activity")
    func agentAttachmentStartsWorking() throws {
        let first = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let replacement = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        var state = reduce([
            .agentAttached(first),
            .agentActivityChanged(session: first, activity: .waiting),
        ])

        reducePaneLifecycles(&state, event: .agentAttached(replacement))

        #expect(state.agent == .attached(session: replacement, activity: .working))
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

        #expect(state.agent == .attached(session: current, activity: .working))
    }

    private func reduce(_ events: [PaneLifecycleEvent]) -> PaneLifecycles {
        var state = PaneLifecycles()
        for event in events {
            reducePaneLifecycles(&state, event: event)
        }
        return state
    }
}
