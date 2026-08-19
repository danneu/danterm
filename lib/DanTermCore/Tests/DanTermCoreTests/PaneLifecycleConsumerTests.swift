// Behavioral coverage for PaneLifecycleConsumers.swift: the read-only consumers
// of session-owned lifecycle state -- the pane inspection fields, the command
// chrome text, and formatToolbarLabel's title/cwd rendering.
//
// Not here: the desiredPaneToolbar projection that consumes these strings. It is
// defined in Projections.swift and asserted in ProjectionsTests.swift.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

struct PaneLifecycleConsumerTests {
    @Test("pane inspection exposes every lifecycle as typed latest-value data")
    func paneInspectionExposesTypedLifecycles() throws {
        let agent = try #require(AgentSession(kind: "codex", sessionId: "thread-1"))
        let state = SessionModel(
            id: SessionId(),
            integration: .ready,
            command: .running("swift test"),
            connection: .remote(identity: RemoteSession(user: "dan", host: "caja")),
            agent: .attached(session: agent, activity: storedActivity(.waiting))
        )

        let value = paneLifecycleInspectionFields(state)

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
        let value = paneLifecycleInspectionFields(nil)

        #expect(value["integration"]?["state"]?.asString == "neverReported")
        #expect(value["command"]?["state"]?.asString == "idle")
        #expect(value["connection"]?["state"]?.asString == "local")
        #expect(value["agent"]?["state"]?.asString == "none")
    }

    @Test("inspection preserves remote without identity and attached without activity")
    func paneInspectionPreservesOptionalLifecyclePayloads() throws {
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let state = SessionModel(
            id: SessionId(),
            connection: .remote(identity: nil),
            agent: .attached(session: agent, activity: nil)
        )

        let value = paneLifecycleInspectionFields(state)

        #expect(value["connection"]?["state"]?.asString == "remote")
        #expect(value["connection"]?["identity"] == .null)
        #expect(value["agent"]?["state"]?.asString == "attached")
        #expect(value["agent"]?["activity"] == .null)
    }

    @Test("an applied attachment is visible to the next synchronous inspection")
    func attachmentPrecedesInspection() throws {
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        var session = SessionModel(id: SessionId())

        reduceSession(&session, report: .agentAttached(agent))
        let inspected = paneLifecycleInspectionFields(session)

        #expect(inspected["agent"]?["state"]?.asString == "attached")
        #expect(inspected["agent"]?["session"]?["sessionId"]?.asString == "session-1")
    }

    @Test("command chrome shows only a currently running command lifecycle")
    func commandChromeDistinguishesRunningFromIdle() {
        #expect(paneCommandChromeText(title: "zsh", cwd: "/work", command: "swift test") == "swift test")
        #expect(paneCommandChromeText(title: "zsh", cwd: "/work", command: nil) == "zsh \u{2013} /work")
    }

    // MARK: - formatToolbarLabel

    @Test("formatToolbarLabel: title only when cwd is nil")
    func formatToolbarLabelTitleOnlyWhenCwdIsNil() {
        // Intent: formatToolbarLabel(title, nil) renders just the title.
        // Why it exists: pins the cwd-nil rendering.
        // Scenario: spec-first title-only.
        #expect(formatToolbarLabel(title: "zsh", cwd: nil) == "zsh")
    }

    @Test("formatToolbarLabel: title equals cwd abbreviates home")
    func formatToolbarLabelTitleEqualsCwdAbbreviatesHome() {
        // Intent: when title == cwd and the path is under $HOME, the
        //   label abbreviates with ~/.
        // Why it exists: pins the abbreviation rule.
        // Scenario: spec-first title==cwd home abbreviation.
        let home = NSHomeDirectory()
        #expect(formatToolbarLabel(title: home + "/projects", cwd: home + "/projects") == "~/projects")
    }

    @Test("formatToolbarLabel: title differs from cwd shows both")
    func formatToolbarLabelTitleDiffersFromCwdShowsBoth() {
        // Intent: when title and cwd differ, the label renders
        //   "title \u{2013} ~/cwd".
        // Why it exists: pins the dual-render shape with the en-dash
        //   separator.
        // Scenario: spec-first title differs.
        let home = NSHomeDirectory()
        #expect(formatToolbarLabel(title: "vim", cwd: home + "/projects") == "vim \u{2013} ~/projects")
    }

    @Test("formatToolbarLabel: cwd outside home not abbreviated")
    func formatToolbarLabelCwdOutsideHomeNotAbbreviated() {
        // Intent: cwd outside $HOME is rendered verbatim.
        // Why it exists: pins the no-abbrev branch.
        // Scenario: spec-first cwd outside home.
        #expect(formatToolbarLabel(title: "zsh", cwd: "/tmp") == "zsh \u{2013} /tmp")
    }

    @Test("formatToolbarLabel: title equals cwd outside home")
    func formatToolbarLabelTitleEqualsCwdOutsideHome() {
        // Intent: title==cwd outside $HOME renders the path verbatim.
        // Why it exists: pins the identity branch for non-home paths.
        // Scenario: spec-first title==cwd outside home.
        #expect(formatToolbarLabel(title: "/tmp/foo", cwd: "/tmp/foo") == "/tmp/foo")
    }
}
