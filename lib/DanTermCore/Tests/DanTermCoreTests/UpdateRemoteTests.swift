// Swift Testing migration of the legacy `tests/UpdateRemoteTests.swift`
// harness suite. Pins remote-session detection and remote-theme handling:
// remoteSessionStarted (isRemote + remoteThemeOverride from config.remoteTheme,
// user theme preserved, stale remoteSession cleared), remoteSessionReported
// (first-call sets, second-call no-ops on same session, theme apply only on
// first transition), commandEnded (clears isRemote / remoteSession /
// remoteThemeOverride, no command emission), missing-pane fail-closed,
// effectiveTheme override-vs-user-vs-nil resolution, setPaneTheme during
// remote (user theme only), and configLoaded propagation (model.config update
// + remote-pane theme reapply).
import Foundation
import Testing

@testable import DanTermCore

@Suite struct UpdateRemoteTests {
    @Test("remoteSessionStarted sets isRemote")
    func remoteSessionStartedSetsIsRemote() {
        // Intent: remoteSessionStarted flips isRemote and projects the
        //   default Purplepeter remote theme into the pane config.
        // Why it exists: pins the bare entry into the remote state.
        // Scenario: spec-first remote start.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        #expect(model.pane(paneId)?.isRemote == true, "pane should be remote")
        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Purplepeter")
    }

    @Test("remoteSessionStarted sets remoteThemeOverride without changing theme")
    func remoteSessionStartedSetsOverrideWithoutChangingUserTheme() {
        // Intent: remote start sets remoteThemeOverride but leaves
        //   pane.theme (the user's choice) untouched.
        // Why it exists: pins the override-vs-user-theme separation.
        // Scenario: spec-first override + preserve user.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.theme = "MyCustomTheme" }
        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        #expect(model.pane(paneId)?.theme == "MyCustomTheme", "user theme should be unchanged")
        #expect(model.pane(paneId)?.remoteThemeOverride == "Purplepeter", "remote override should be set")
    }

    @Test("remoteSessionStarted uses config.remoteTheme")
    func remoteSessionStartedUsesConfigRemoteTheme() {
        // Intent: the override theme comes from model.config.remoteTheme
        //   (not a hardcoded default).
        // Why it exists: pins the config source.
        // Scenario: spec-first config-driven override.
        var model = makeModel()
        model.config.remoteTheme = "Ocean"
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        #expect(model.pane(paneId)?.remoteThemeOverride == "Ocean", "should use config remote theme")
    }

    @Test("remoteSessionStarted clears stale remoteSession")
    func remoteSessionStartedClearsStaleRemoteSession() {
        // Intent: remoteSessionStarted resets remoteSession to nil if a
        //   stale value was hanging around.
        // Why it exists: pins the freshness invariant.
        // Scenario: spec-first stale clear.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.remoteSession = RemoteSession(user: "dan", host: "caja") }
        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        #expect(model.pane(paneId)?.remoteSession == nil, "stale remote session should be cleared")
    }

    @Test("remoteSessionReported sets remoteSession and isRemote on first call")
    func remoteSessionReportedSetsSessionAndIsRemoteFirstCall() {
        // Intent: first remoteSessionReported sets isRemote, stores the
        //   session, and projects the override theme.
        // Why it exists: pins the first-transition contract.
        // Scenario: spec-first first report.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let session = RemoteSession(user: "dan", host: "caja")

        _ = update(&model, .remoteSessionReported(paneId: paneId, session: session))
        #expect(model.pane(paneId)?.isRemote == true, "pane should be remote")
        #expect(model.pane(paneId)?.remoteSession == session, "session should be stored")
        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Purplepeter")
    }

    @Test("remoteSessionReported applies remoteThemeOverride only on first transition")
    func remoteSessionReportedAppliesOverrideOnlyOnFirstTransition() {
        // Intent: remoteSessionReported applies override only on the
        //   first transition into remote; subsequent reports leave
        //   override alone and emit no commands.
        // Why it exists: pins the one-shot theme apply rule.
        // Scenario: spec-first first vs subsequent.
        var model = makeModel()
        model.config.remoteTheme = "Ocean"
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        _ = update(&model, .remoteSessionReported(paneId: paneId, session: RemoteSession(user: "dan", host: "caja")))
        #expect(model.pane(paneId)?.remoteThemeOverride == "Ocean")
        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Ocean")

        let secondEffects = update(&model, .remoteSessionReported(paneId: paneId, session: RemoteSession(user: "dan", host: "silverstone")))
        #expect(model.pane(paneId)?.remoteThemeOverride == "Ocean")
        #expect(secondEffects.count == 0, "remote-to-remote session update should not reapply theme")
    }

    @Test("remoteSessionReported with same session is no-op")
    func remoteSessionReportedWithSameSessionIsNoOp() {
        // Intent: a second report with the identical session is a no-op.
        // Why it exists: pins the identity short-circuit.
        // Scenario: spec-first same-session.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let session = RemoteSession(user: "dan", host: "caja")
        _ = update(&model, .remoteSessionReported(paneId: paneId, session: session))

        let commands = update(&model, .remoteSessionReported(paneId: paneId, session: session))
        #expect(model.pane(paneId)?.remoteSession == session)
        #expect(commands.count == 0, "unchanged session should produce no commands")
    }

    @Test("remoteSessionReported with different session updates without theme reapply")
    func remoteSessionReportedWithDifferentSessionUpdatesNoReapply() {
        // Intent: a different session while already remote replaces the
        //   session but does NOT reapply theme.
        // Why it exists: pins the one-shot theme apply rule (negative
        //   case for in-flight session changes).
        // Scenario: spec-first session-change no-reapply.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .remoteSessionReported(paneId: paneId, session: RemoteSession(user: "dan", host: "caja")))
        let nextSession = RemoteSession(user: "root", host: "silverstone")

        let commands = update(&model, .remoteSessionReported(paneId: paneId, session: nextSession))
        #expect(model.pane(paneId)?.remoteSession == nextSession)
        #expect(commands.count == 0, "changed session while already remote should not reapply theme")
    }

    @Test("remoteSessionReported on missing pane returns empty commands")
    func remoteSessionReportedOnMissingPaneReturnsEmpty() {
        // Intent: a report for a missing pane is a no-op.
        // Why it exists: pins fail-closed for stale pane ids.
        // Scenario: spec-first stale-pane report.
        var model = makeModel()
        let commands = update(&model, .remoteSessionReported(paneId: PaneId(), session: RemoteSession(user: "dan", host: "caja")))
        #expect(commands.count == 0, "no commands for missing pane")
    }

    @Test("commandEnded clears isRemote and remoteThemeOverride")
    func commandEndedClearsIsRemoteAndOverride() {
        // Intent: commandEnded clears isRemote, remoteSession, and the
        //   override; the per-pane config projection key drops.
        // Why it exists: pins the exit-from-remote cleanup.
        // Scenario: spec-first exit clean.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.isRemote = true }
        model.updatePane(paneId) { $0.remoteSession = RemoteSession(user: "dan", host: "caja") }
        model.updatePane(paneId) { $0.remoteThemeOverride = "Purplepeter" }
        let commands = update(&model, .commandEnded(paneId: paneId))
        #expect(model.pane(paneId)?.isRemote == false)
        #expect(model.pane(paneId)?.remoteSession == nil, "remote session should be cleared")
        #expect(model.pane(paneId)?.remoteThemeOverride == nil, "override should be cleared")
        #expect(desiredPaneConfig(in: model)[paneId] == nil, "cleared override without user theme -> no config key")
        #expect(commands.count == 0)
    }

    @Test("commandEnded clears remoteSession too")
    func commandEndedClearsRemoteSession() {
        // Intent: commandEnded clears remoteSession even when no
        //   override is set.
        // Why it exists: pins the symmetric cleanup branch.
        // Scenario: spec-first commandEnded clears session.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.isRemote = true }
        model.updatePane(paneId) { $0.remoteSession = RemoteSession(user: "dan", host: "caja") }
        let commands = update(&model, .commandEnded(paneId: paneId))
        #expect(model.pane(paneId)?.isRemote == false)
        #expect(model.pane(paneId)?.remoteSession == nil, "remote session should be cleared")
        #expect(commands.count == 0, "no theme command when no override was set")
    }

    @Test("commandEnded clears agentSession and checkpoints local pane")
    func commandEndedClearsAgentSessionAndCheckpointsLocalPane() throws {
        // Intent: commandEnded clears a live agentSession even for the
        //   common local-pane case with no remoteThemeOverride.
        // Why it exists: prevents a stale crash-recovery hint from being
        //   persisted after the agent returns control to the prompt.
        // Scenario: Claude exits in a local pane, so CMD_END is the detach
        //   signal and must checkpoint the cleared agent session.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        let session = try #require(AgentSession(kind: "claude", sessionId: "4f3a2b1c"))
        model.updatePane(paneId) { $0.agentSession = session }

        let commands = update(&model, .commandEnded(paneId: paneId))

        #expect(model.pane(paneId)?.agentSession == nil)
        #expect(hasEffect(commands) { if case .scheduleCheckpoint = $0 { return true }; return false })
    }

    @Test("commandEnded on non-remote pane is no-op")
    func commandEndedOnNonRemotePaneIsNoOp() {
        // Intent: commandEnded on a pane not marked remote is a no-op.
        // Why it exists: pins the idempotent-cleanup rule.
        // Scenario: spec-first non-remote commandEnded.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        let commands = update(&model, .commandEnded(paneId: paneId))
        #expect(model.pane(paneId)?.isRemote == false, "pane should remain non-remote")
        #expect(commands.count == 0, "no commands expected")
    }

    @Test("remoteSessionStarted on missing pane returns empty commands")
    func remoteSessionStartedOnMissingPaneReturnsEmpty() {
        // Intent: remoteSessionStarted on a missing pane is a no-op.
        // Why it exists: pins fail-closed for stale pane ids.
        // Scenario: spec-first stale-pane start.
        var model = makeModel()
        let fakePaneId = PaneId()
        let commands = update(&model, .remoteSessionStarted(paneId: fakePaneId))
        #expect(commands.count == 0, "no commands for missing pane")
    }

    @Test("commandEnded on missing pane returns empty commands")
    func commandEndedOnMissingPaneReturnsEmpty() {
        // Intent: commandEnded on a missing pane is a no-op.
        // Why it exists: pins fail-closed for stale pane ids.
        // Scenario: spec-first stale-pane commandEnded.
        var model = makeModel()
        let fakePaneId = PaneId()
        let commands = update(&model, .commandEnded(paneId: fakePaneId))
        #expect(commands.count == 0, "no commands for missing pane")
    }

    @Test("remote lifecycle: start then end restores theme")
    func remoteLifecycleStartEndRestoresTheme() {
        // Intent: a full start+end lifecycle preserves the user's
        //   pane.theme; only the override appears and then disappears.
        // Why it exists: pins the round-trip invariant.
        // Scenario: spec-first lifecycle.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        model.updatePane(paneId) { $0.theme = "Dracula" }
        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        #expect(model.pane(paneId)?.remoteThemeOverride == "Purplepeter")
        #expect(model.pane(paneId)?.theme == "Dracula", "user theme preserved")

        _ = update(&model, .commandEnded(paneId: paneId))
        #expect(model.pane(paneId)?.remoteThemeOverride == nil)
        #expect(model.pane(paneId)?.theme == "Dracula", "user theme still there")
    }

    @Test("effectiveTheme returns override when set")
    func effectiveThemeReturnsOverrideWhenSet() {
        // Intent: effectiveTheme prefers the remote override.
        // Why it exists: pins the override-wins rule.
        // Scenario: spec-first override wins.
        var pane = PaneModel(id: PaneId())
        pane.theme = "Dracula"
        pane.remoteThemeOverride = "Purplepeter"
        #expect(effectiveTheme(for: pane) == "Purplepeter")
    }

    @Test("effectiveTheme falls back to user theme")
    func effectiveThemeFallsBackToUserTheme() {
        // Intent: effectiveTheme returns pane.theme when no override is
        //   set.
        // Why it exists: pins the user-theme fallback.
        // Scenario: spec-first user fallback.
        var pane = PaneModel(id: PaneId())
        pane.theme = "Dracula"
        #expect(effectiveTheme(for: pane) == "Dracula")
    }

    @Test("effectiveTheme returns nil when both are nil")
    func effectiveThemeReturnsNilWhenBothNil() {
        // Intent: effectiveTheme returns nil when neither user theme
        //   nor override is set.
        // Why it exists: pins the both-nil branch.
        // Scenario: spec-first both nil.
        let pane = PaneModel(id: PaneId())
        #expect(effectiveTheme(for: pane) == nil, "should be nil")
    }

    @Test("setPaneTheme while remote changes user theme not override")
    func setPaneThemeWhileRemoteChangesUserThemeNotOverride() {
        // Intent: setPaneTheme during a remote session changes the user
        //   theme; the override stays in place.
        // Why it exists: pins the user-theme isolation during remote.
        // Scenario: spec-first set-during-remote.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId

        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        _ = update(&model, .setPaneTheme(paneId: paneId, themeName: "Solarized"))
        #expect(model.pane(paneId)?.theme == "Solarized", "user theme should change")
        #expect(model.pane(paneId)?.remoteThemeOverride == "Purplepeter", "override unchanged")
    }

    // MARK: - configLoaded

    @Test("configLoaded updates model.config")
    func configLoadedUpdatesModelConfig() {
        // Intent: configLoaded replaces model.config with the new value.
        // Why it exists: pins the bare config replacement.
        // Scenario: spec-first config replace.
        var model = makeModel()
        var newConfig = DanTermConfig()
        newConfig.remoteTheme = "Grape"
        let commands = update(&model, .configLoaded(newConfig))
        #expect(model.config.remoteTheme == "Grape")
        #expect(commands.count == 0)
    }

    @Test("configLoaded reapplies remote theme to remote panes")
    func configLoadedReappliesRemoteThemeToRemotePanes() {
        // Intent: configLoaded propagates the new remote theme to every
        //   remote pane's remoteThemeOverride.
        // Why it exists: pins the live remote-theme propagation.
        // Scenario: spec-first config propagation.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .remoteSessionStarted(paneId: paneId))
        #expect(model.pane(paneId)?.remoteThemeOverride == "Purplepeter")

        var newConfig = DanTermConfig()
        newConfig.remoteTheme = "Grape"
        let commands = update(&model, .configLoaded(newConfig))
        #expect(model.pane(paneId)?.remoteThemeOverride == "Grape", "remote pane should get new theme")
        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Grape")
        #expect(commands.count == 0)
    }

    @Test("configLoaded with same config emits no commands")
    func configLoadedWithSameConfigEmitsNoCommands() {
        // Intent: configLoaded with the existing config is a no-op (no
        //   theme reapply).
        // Why it exists: pins the no-op-on-equality rule.
        // Scenario: spec-first same-config no-op.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .remoteSessionStarted(paneId: paneId))

        let commands = update(&model, .configLoaded(DanTermConfig.default))
        #expect(commands.count == 0)
    }

    // MARK: - setAlertClearMode (via pref draft + save)

    @Test("pref save alertClearMode updates model and emits save")
    func prefSaveAlertClearModeUpdatesModelEmitsSave() {
        // Intent: pref save with a dirty alertClearMode updates config
        //   and emits saveDanTermConfigKey.
        // Why it exists: pins the alert-mode save path (also covered in
        //   UpdatePreferencesTests; preserved here for the remote-side
        //   suite's coverage of the pref-save surface).
        // Scenario: spec-first save alert mode.
        var model = makeModel()
        _ = update(&model, .preferencesOpened(ghostty: GhosttyPrefs()))
        _ = update(&model, .prefSetAlertClearMode(.manual))
        let commands = update(&model, .prefSave)
        #expect(model.config.alertClearMode == .manual)
        #expect(hasEffect(commands) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "alert-clear-mode" && value == "manual"
            }
            return false
        }, "should emit saveDanTermConfigKey")
    }

    @Test("pref save alertClearMode with same value does not emit save key")
    func prefSaveAlertClearModeSameValueDoesNotEmitKey() {
        // Intent: pref save with an unchanged draft emits no
        //   saveDanTermConfigKey.
        // Why it exists: pins the no-op-on-clean rule from the remote
        //   suite's pref-save surface.
        // Scenario: spec-first clean save.
        var model = makeModel()
        _ = update(&model, .preferencesOpened(ghostty: GhosttyPrefs()))
        let commands = update(&model, .prefSave)
        #expect(commands.count == 0)
        #expect(!hasEffect(commands) {
            if case .saveDanTermConfigKey = $0 { return true }
            return false
        }, "should not emit saveDanTermConfigKey")
    }

    // MARK: - setRemoteTheme (via pref draft + save)

    @Test("pref save remoteTheme updates model and saves")
    func prefSaveRemoteThemeUpdatesModelAndSaves() {
        // Intent: pref save with a dirty remoteTheme updates config and
        //   emits saveDanTermConfigKey for "remote-theme".
        // Why it exists: pins the remote-theme save path (mirror of the
        //   UpdatePreferencesTests entry; preserved for remote-side
        //   coverage).
        // Scenario: spec-first save remote theme.
        var model = makeModel()
        _ = update(&model, .preferencesOpened(ghostty: GhosttyPrefs()))
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let commands = update(&model, .prefSave)
        #expect(model.config.remoteTheme == "Grape")
        #expect(hasEffect(commands) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "remote-theme" && value == "Grape"
            }
            return false
        }, "should emit saveDanTermConfigKey")
    }

    @Test("pref save remoteTheme updates remote panes")
    func prefSaveRemoteThemeUpdatesRemotePanes() {
        // Intent: pref save with a dirty remoteTheme propagates the new
        //   theme to live remote panes' override + per-pane config.
        // Why it exists: pins the cross-suite remote propagation path.
        // Scenario: spec-first remote panes update via prefs.
        var model = makeModel()
        createTab(&model)
        let paneId = model.groups[0].tabs[0].focusedPaneId
        _ = update(&model, .remoteSessionStarted(paneId: paneId))

        _ = update(&model, .preferencesOpened(ghostty: GhosttyPrefs()))
        _ = update(&model, .prefSetRemoteTheme("Grape"))
        let commands = update(&model, .prefSave)
        #expect(model.pane(paneId)?.remoteThemeOverride == "Grape")
        #expect(desiredPaneConfig(in: model)[paneId]?.theme == "Grape")
        #expect(hasEffect(commands) {
            if case .saveDanTermConfigKey(let key, let value) = $0 {
                return key == "remote-theme" && value == "Grape"
            }
            return false
        }, "should save remote theme")
    }
}
