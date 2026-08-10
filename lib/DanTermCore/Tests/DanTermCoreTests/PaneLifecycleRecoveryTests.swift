// Behavioral tests for the recovery-only pane lifecycle memo.
import Testing

@testable import DanTermCore

@Suite struct PaneLifecycleRecoveryTests {
    @Test("the last started command survives command end")
    func commandSurvivesEnd() {
        var stream = PaneLifecycleStream()
        var recovery = PaneLifecycleRecoveryState()

        recovery.apply(stream.apply(.commandStarted("vim")))
        recovery.apply(stream.apply(.commandEnded(exitStatus: 0)))

        #expect(recovery.snapshot.command == "vim")
    }

    @Test("agent recovery follows attach and detach")
    func agentFollowsAttachAndDetach() throws {
        let session = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        var stream = PaneLifecycleStream()
        var recovery = PaneLifecycleRecoveryState()

        recovery.apply(stream.apply(.agentAttached(session)))
        #expect(recovery.snapshot.agentSession == session)

        recovery.apply(stream.apply(.agentDetached(session)))
        #expect(recovery.snapshot.agentSession == nil)
    }
}
