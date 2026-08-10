// Tests the pane-semantic product policy that remains in update and the pure
// theme projection derived from pane-owned connection snapshots.
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
        let local = PaneSemanticState()
        let remote = PaneSemanticState(connection: .remote(identity: nil))

        #expect(effectiveTheme(for: pane, config: config, semantics: local) == "Default")
        #expect(effectiveTheme(for: pane, config: config, semantics: remote) == "Remote")

        pane.theme = "Pane"
        #expect(effectiveTheme(for: pane, config: config, semantics: local) == "Pane")
        #expect(effectiveTheme(for: pane, config: config, semantics: remote) == "Remote")
    }

    @Test("remote theme changes project immediately without pane mutation")
    func remoteThemeChangesProjectImmediately() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let semantics = [paneId: PaneSemanticState(connection: .remote(identity: nil))]
        let paneBefore = model.pane(paneId)

        var reloaded = model.config
        reloaded.remoteTheme = "Grape"
        _ = update(&model, .configLoaded(reloaded, resolvedFontFamily: nil))
        #expect(desiredPaneConfig(in: model, semanticSnapshots: semantics)[paneId]?.theme == "Grape")
        #expect(model.pane(paneId) == paneBefore)

        _ = update(&model, .preferencesOpened())
        _ = update(&model, .prefSetRemoteTheme("Ocean"))
        _ = update(&model, .prefSave)
        #expect(desiredPaneConfig(in: model, semanticSnapshots: semantics)[paneId]?.theme == "Ocean")
        #expect(model.pane(paneId) == paneBefore)
    }

    @Test("setting a pane theme while remote changes only its later local theme")
    func setPaneThemeWhileRemoteChangesLaterLocalTheme() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let remote = [paneId: PaneSemanticState(connection: .remote(identity: nil))]

        _ = update(&model, .setPaneTheme(paneId: paneId, themeName: "Solarized"))

        #expect(desiredPaneConfig(in: model, semanticSnapshots: remote)[paneId]?.theme == model.config.remoteTheme)
        #expect(desiredPaneConfig(in: model, semanticSnapshots: [:])[paneId]?.theme == "Solarized")
    }

    @Test("semantic transition scheduling follows product policy")
    func semanticTransitionScheduling() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        var stream = PaneSemanticStream()

        func sendsCheckpoint(_ transition: PaneSemanticTransition) -> Bool {
            update(&model, .paneSemanticsChanged(paneId: paneId, transition: transition)).contains {
                if case .scheduleCheckpoint = $0 { return true }
                return false
            }
        }

        #expect(sendsCheckpoint(stream.apply(.commandStarted("make"))))
        #expect(sendsCheckpoint(stream.apply(.commandEnded(exitStatus: 0))) == false)
        #expect(sendsCheckpoint(stream.apply(.remoteDetected)) == false)
        #expect(sendsCheckpoint(stream.apply(.remoteIdentityReported(
            RemoteSession(user: "dan", host: "caja")
        ))) == false)
        #expect(sendsCheckpoint(stream.apply(.agentAttached(agent))))
        #expect(sendsCheckpoint(stream.apply(.agentActivityChanged(
            session: agent,
            activity: .idle
        ))) == false)
        #expect(sendsCheckpoint(stream.apply(.commandStarted("test"))))
        #expect(sendsCheckpoint(stream.apply(.commandEnded(exitStatus: 0))))
        #expect(sendsCheckpoint(stream.apply(.agentDetached(agent))))
        #expect(sendsCheckpoint(stream.apply(.connectionEnded)) == false)
    }
}
