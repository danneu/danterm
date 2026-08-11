// Tests the session-lifecycle product policy that remains in update and the pure
// theme projection derived from session-owned connection state.
import Foundation
import Testing

@testable import DanTermCore

struct UpdateRemoteTests {
    @Test("effective theme derives from connection, pane choice, and config")
    func effectiveThemeDerivationTable() {
        var pane = PaneModel(id: PaneId())
        var config = DanTermConfig.default
        config.defaultTheme = "Default"
        config.remoteTheme = "Remote"
        pane.session = SessionModel(id: SessionId())
        #expect(effectiveTheme(for: pane, config: config) == "Default")
        pane.session?.connection = .remote(identity: nil)
        #expect(effectiveTheme(for: pane, config: config) == "Remote")

        pane.theme = "Pane"
        pane.session?.connection = .local
        #expect(effectiveTheme(for: pane, config: config) == "Pane")
        pane.session?.connection = .remote(identity: nil)
        #expect(effectiveTheme(for: pane, config: config) == "Remote")
    }

    @Test("remote theme changes project immediately without pane mutation")
    func remoteThemeChangesProjectImmediately() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let sessionId = model.pane(paneId)!.session!.id
        update(&model, .sessionReport(sessionId: sessionId, report: .remoteDetected))
        let paneBefore = model.pane(paneId)

        var reloaded = model.config
        reloaded.remoteTheme = "Grape"
        _ = update(&model, .configLoaded(reloaded, resolvedFontFamily: nil))
        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Grape")
        #expect(model.pane(paneId) == paneBefore)

        _ = update(&model, .preferencesOpened())
        _ = update(&model, .prefSetRemoteTheme("Ocean"))
        _ = update(&model, .prefSave)
        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Ocean")
        #expect(model.pane(paneId) == paneBefore)
    }

    @Test("setting a pane theme while remote changes only its later local theme")
    func setPaneThemeWhileRemoteChangesLaterLocalTheme() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let sessionId = model.pane(paneId)!.session!.id
        update(&model, .sessionReport(sessionId: sessionId, report: .remoteDetected))

        _ = update(&model, .setPaneTheme(paneId: paneId, themeName: "Solarized"))

        #expect(desiredPaneConfig(in: model)[paneId]?.theme == model.config.remoteTheme)
        update(&model, .sessionReport(sessionId: sessionId, report: .connectionEnded))
        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Solarized")
    }

    @Test("lifecycle recovery projection changes only for persisted transitions")
    func lifecycleRecoveryProjectionChangesOnlyForPersistedTransitions() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        let sessionId = try #require(model.pane(paneId)?.session?.id)

        func changesProjection(_ report: SessionReport) -> Bool {
            let before = LightCheckpointProjection(snapshot: toSnapshot(model))
            update(&model, .sessionReport(sessionId: sessionId, report: report))
            let after = LightCheckpointProjection(snapshot: toSnapshot(model))
            return before != after
        }

        #expect(changesProjection(.commandStarted("make")))
        #expect(changesProjection(.commandEnded(exitStatus: 0)) == false)
        #expect(changesProjection(.remoteDetected) == false)
        #expect(changesProjection(.remoteIdentityReported(
            RemoteSession(user: "dan", host: "caja")
        )) == false)
        #expect(changesProjection(.agentAttached(agent)))
        #expect(changesProjection(.agentActivityChanged(
            session: agent,
            activity: .idle
        )) == false)
        #expect(changesProjection(.commandStarted("test")))
        #expect(changesProjection(.commandEnded(exitStatus: 0)) == false)
        #expect(changesProjection(.agentDetached(agent)))
        #expect(changesProjection(.connectionEnded) == false)
    }
}
