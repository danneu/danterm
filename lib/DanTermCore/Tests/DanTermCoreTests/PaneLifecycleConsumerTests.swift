// Behavioral coverage for read-only consumers of the pane-owned live lifecycle snapshot.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

struct PaneLifecycleConsumerTests {
    @Test("pane inspection exposes every lifecycle as typed latest-value data")
    func paneInspectionExposesTypedLifecycles() throws {
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        let state = PaneLifecycles(
            integration: .ready,
            command: .running("swift test"),
            connection: .remote(identity: RemoteSession(user: "dan", host: "caja")),
            agent: .attached(session: agent, activity: .waiting)
        )

        let value = paneLifecyclesInspectionValue(state)

        #expect(value["integration"]?["state"]?.asString == "ready")
        #expect(value["command"]?["state"]?.asString == "running")
        #expect(value["command"]?["text"]?.asString == "swift test")
        #expect(value["connection"]?["state"]?.asString == "remote")
        #expect(value["connection"]?["identity"]?["user"]?.asString == "dan")
        #expect(value["connection"]?["identity"]?["host"]?.asString == "caja")
        #expect(value["agent"]?["state"]?.asString == "attached")
        #expect(value["agent"]?["session"]?["kind"]?.asString == "codex")
        #expect(value["agent"]?["session"]?["sessionId"]?.asString == "thread-1")
        #expect(value["agent"]?["activity"]?.asString == "waiting")
    }

    @Test("neutral pane inspection distinguishes absent, idle, local, and unattached lifecycles")
    func neutralPaneInspectionUsesExplicitStates() {
        let value = paneLifecyclesInspectionValue(PaneLifecycles())

        #expect(value["integration"]?["state"]?.asString == "neverReported")
        #expect(value["command"]?["state"]?.asString == "idle")
        #expect(value["connection"]?["state"]?.asString == "local")
        #expect(value["agent"]?["state"]?.asString == "none")
    }

    @Test("inspection preserves remote without identity and attached without activity")
    func paneInspectionPreservesOptionalLifecyclePayloads() throws {
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let state = PaneLifecycles(
            connection: .remote(identity: nil),
            agent: .attached(session: agent, activity: nil)
        )

        let value = paneLifecyclesInspectionValue(state)

        #expect(value["connection"]?["state"]?.asString == "remote")
        #expect(value["connection"]?["identity"] == .null)
        #expect(value["agent"]?["state"]?.asString == "attached")
        #expect(value["agent"]?["activity"] == .null)
    }

    @Test("an applied attachment is visible to the next synchronous inspection")
    func attachmentPrecedesInspection() throws {
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        var stream = PaneLifecycleStream()

        _ = stream.apply(.agentAttached(agent))
        let inspected = paneLifecyclesInspectionValue(stream.snapshot)

        #expect(inspected["agent"]?["state"]?.asString == "attached")
        #expect(inspected["agent"]?["session"]?["sessionId"]?.asString == "session-1")
    }

    @Test("command chrome shows only a currently running command lifecycle")
    func commandChromeDistinguishesRunningFromIdle() {
        var running = PaneLifecycles()
        running.command = .running("swift test")

        #expect(paneCommandChromeText(title: "zsh", cwd: "/work", lifecycles: running) == "swift test")
        #expect(paneCommandChromeText(title: "zsh", cwd: "/work", lifecycles: PaneLifecycles()) == "zsh \u{2013} /work")
    }
}
