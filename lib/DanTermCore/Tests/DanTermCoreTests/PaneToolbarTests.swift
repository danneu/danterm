// Swift Testing coverage for toolbar label formatting from the legacy
// `tests/PaneToolbarTests.swift` harness suite. Pins the title-only,
// title-equals-cwd abbreviation, title-differs, outside-home, and outside-home
// identity cases.
import Foundation
import Testing

@testable import DanTermCore

@Suite struct PaneToolbarTests {
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

/// The toolbar strings the projection composes. They used to be composed by
/// `PaneWrapperView.updateToolbar` out of raw model values, which put untrusted
/// terminal-reported text -- a title, a cwd, a remote user and host -- together
/// inside a view. The composition is the projection's job, so it is asserted
/// here rather than through a window.
@Suite struct PaneToolbarCompositionTests {
    @Test("the label is the title and cwd while no command runs")
    func labelIsTitleAndCwdWhenIdle() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        update(&model, .sessionReport(sessionId: sessionId, report: .title("vim")))
        update(&model, .sessionReport(sessionId: sessionId, report: .cwd("/tmp")))

        #expect(desiredPaneToolbar(in: model)[paneId]?.label == "vim \u{2013} /tmp")
    }

    @Test("a running command takes over the label")
    func runningCommandTakesOverTheLabel() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        update(&model, .sessionReport(sessionId: sessionId, report: .title("vim")))
        update(&model, .sessionReport(sessionId: sessionId, report: .cwd("/tmp")))
        update(&model, .sessionReport(sessionId: sessionId, report: .commandStarted("swift test")))

        #expect(desiredPaneToolbar(in: model)[paneId]?.label == "swift test")
    }

    @Test("a remote identity composes the pill's user@host")
    func remoteIdentityComposesThePill() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        update(&model, .sessionReport(sessionId: sessionId, report: .connectionDeclared(
            .remote(identity: RemoteSession(user: "dan", host: "caja")))))

        let render = try #require(desiredPaneToolbar(in: model)[paneId])
        #expect(render.remoteLabel == "dan@caja")
        #expect(render.isRemote)
    }

    // The pill's visibility follows its composed value being nil, so a remote
    // connection with no identity yet still shows the bare remote marker.
    @Test("a remote connection with no identity composes no pill text")
    func remoteWithoutIdentityHasNoPillText() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        update(&model, .sessionReport(sessionId: sessionId, report: .connectionDeclared(
            .remote(identity: nil))))

        let render = try #require(desiredPaneToolbar(in: model)[paneId])
        #expect(render.remoteLabel == nil)
        #expect(render.isRemote)
    }

    @Test("a local pane composes no remote pill")
    func localPaneHasNoRemotePill() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).focusedPaneId

        let render = try #require(desiredPaneToolbar(in: model)[paneId])
        #expect(render.remoteLabel == nil)
        #expect(render.isRemote == false)
    }

    // Why it exists: the tooltip is the only place the full session id is
    // reachable once the agent pill is hidden for a kind the chip can name.
    @Test("the chip tooltip names the agent kind and its full session id")
    func chipTooltipNamesTheAgent() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        let claude = try #require(AgentSession(kind: "claude", sessionId: "abc123"))

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(claude)))

        let render = try #require(desiredPaneToolbar(in: model)[paneId])
        #expect(render.chipTooltip == "claude session abc123")
        #expect(render.chipKind == .claude)
    }

    @Test("an agent the chip names is not also spelled out in the pill")
    func namedAgentHasNoPillText() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        let claude = try #require(AgentSession(kind: "claude", sessionId: "abc123"))

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(claude)))

        #expect(desiredPaneToolbar(in: model)[paneId]?.agentLabel == nil)
    }

    @Test("an agent with no chip of its own is named in the pill")
    func unknownAgentIsNamedInThePill() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        let aider = try #require(AgentSession(kind: "aider", sessionId: "abc123"))

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(aider)))

        let render = try #require(desiredPaneToolbar(in: model)[paneId])
        #expect(render.agentLabel == "aider")
        #expect(render.chipKind == .agent)
    }

    @Test("detaching an agent clears both the tooltip and the pill")
    func detachingClearsAgentText() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = try #require(selectedTab(in: model)).focusedPaneId
        let sessionId = try #require(model.pane(paneId)?.session?.id)
        let aider = try #require(AgentSession(kind: "aider", sessionId: "abc123"))

        update(&model, .sessionReport(sessionId: sessionId, report: .agentAttached(aider)))
        update(&model, .sessionReport(sessionId: sessionId, report: .agentDetached(aider)))

        let render = try #require(desiredPaneToolbar(in: model)[paneId])
        #expect(render.chipTooltip == nil)
        #expect(render.agentLabel == nil)
    }
}
