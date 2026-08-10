// Tests the pane-lifecycle product policy that remains in update and the pure
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
        let local = PaneLifecycles()
        let remote = PaneLifecycles(connection: .remote(identity: nil))

        #expect(effectiveTheme(for: pane, config: config, lifecycles: local) == "Default")
        #expect(effectiveTheme(for: pane, config: config, lifecycles: remote) == "Remote")

        pane.theme = "Pane"
        #expect(effectiveTheme(for: pane, config: config, lifecycles: local) == "Pane")
        #expect(effectiveTheme(for: pane, config: config, lifecycles: remote) == "Remote")
    }

    @Test("remote theme changes project immediately without pane mutation")
    func remoteThemeChangesProjectImmediately() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let lifecycles = [paneId: PaneLifecycles(connection: .remote(identity: nil))]
        let paneBefore = model.pane(paneId)

        var reloaded = model.config
        reloaded.remoteTheme = "Grape"
        _ = update(&model, .configLoaded(reloaded, resolvedFontFamily: nil))
        #expect(desiredPaneConfig(
            in: model,
            livePaneState: PaneLifecyclesView(lifecyclesByPaneId: lifecycles)
        )[paneId]?.theme == "Grape")
        #expect(model.pane(paneId) == paneBefore)

        _ = update(&model, .preferencesOpened())
        _ = update(&model, .prefSetRemoteTheme("Ocean"))
        _ = update(&model, .prefSave)
        #expect(desiredPaneConfig(
            in: model,
            livePaneState: PaneLifecyclesView(lifecyclesByPaneId: lifecycles)
        )[paneId]?.theme == "Ocean")
        #expect(model.pane(paneId) == paneBefore)
    }

    @Test("setting a pane theme while remote changes only its later local theme")
    func setPaneThemeWhileRemoteChangesLaterLocalTheme() {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let remote = [paneId: PaneLifecycles(connection: .remote(identity: nil))]

        _ = update(&model, .setPaneTheme(paneId: paneId, themeName: "Solarized"))

        #expect(desiredPaneConfig(
            in: model,
            livePaneState: PaneLifecyclesView(lifecyclesByPaneId: remote)
        )[paneId]?.theme == model.config.remoteTheme)
        #expect(desiredPaneConfig(in: model, livePaneState: PaneLifecyclesView())[paneId]?.theme == "Solarized")
    }

    @Test("lifecycle recovery projection changes only for persisted transitions")
    func lifecycleRecoveryProjectionChangesOnlyForPersistedTransitions() throws {
        var model = makeModel()
        createTab(&model)
        let paneId = selectedTab(in: model)!.focusedPaneId
        let agent = try #require(AgentSession(kind: "claude", sessionId: "session-1"))
        var stream = PaneLifecycleStream()
        var recovery = PaneLifecycleRecoveryState()

        func changesProjection(_ transition: PaneLifecycleTransition) -> Bool {
            let before = LightCheckpointProjection(
                snapshot: toSnapshot(model),
                lifecycleRecoveryByPaneId: [paneId: recovery.snapshot]
            )
            recovery.apply(transition)
            let after = LightCheckpointProjection(
                snapshot: toSnapshot(model),
                lifecycleRecoveryByPaneId: [paneId: recovery.snapshot]
            )
            return before != after
        }

        #expect(changesProjection(stream.apply(.commandStarted("make"))))
        #expect(changesProjection(stream.apply(.commandEnded(exitStatus: 0))) == false)
        #expect(changesProjection(stream.apply(.remoteDetected)) == false)
        #expect(changesProjection(stream.apply(.remoteIdentityReported(
            RemoteSession(user: "dan", host: "caja")
        ))) == false)
        #expect(changesProjection(stream.apply(.agentAttached(agent))))
        #expect(changesProjection(stream.apply(.agentActivityChanged(
            session: agent,
            activity: .idle
        ))) == false)
        #expect(changesProjection(stream.apply(.commandStarted("test"))))
        #expect(changesProjection(stream.apply(.commandEnded(exitStatus: 0))) == false)
        #expect(changesProjection(stream.apply(.agentDetached(agent))))
        #expect(changesProjection(stream.apply(.connectionEnded)) == false)
    }
}
