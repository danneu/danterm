// Pins the model contract for `ui.copyOnSelect`: the default-on typed setting,
// its propagation into the per-pane config key that reconcile pushes at the
// session, and the preferences draft/save leg that lets the user turn it off.
// The clipboard write itself belongs to the app layer -- the core only decides
// which panes should have copy-on-select armed.
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct ConfigCopyOnSelectTests {
    // MARK: - Pane projection

    @Test("desiredPaneConfig arms copy-on-select by default")
    func paneKeyArmsCopyOnSelectByDefault() {
        var model = makeModel()
        _ = createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId

        #expect(desiredPaneConfig(in: model)[paneId]?.copyOnSelect == true)
    }

    @Test("turning copy-on-select off changes the pane key so reconcile re-pushes")
    func paneKeyChangesWhenCopyOnSelectTurnsOff() {
        // Intent: the option reaches a live pane through the same keyed reconcile
        //   as theme and font, so a reload applies without a restart.
        // Why it exists: a key that did not carry the value would leave already
        //   mounted panes copying after the user turned the option off.
        // Scenario: spec-first; the user edits config.json and reloads.
        var model = makeModel()
        _ = createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let before = desiredPaneConfig(in: model)[paneId]

        var config = DanTermConfig.default
        config.copyOnSelect = false
        _ = update(&model, .configLoaded(config, resolvedFontFamily: nil))

        #expect(desiredPaneConfig(in: model)[paneId] != before, "reconcile must re-push")
        #expect(desiredPaneConfig(in: model)[paneId]?.copyOnSelect == false)
    }

    // MARK: - Preferences draft

    @Test("preferencesOpened seeds the copy-on-select draft from the committed config")
    func preferencesOpenedSeedsCopyOnSelectDraft() {
        var model = makeModel()
        model.config.copyOnSelect = false

        _ = update(&model, .preferencesOpened())

        #expect(model.preferencesDraft?.copyOnSelect == false)
    }

    @Test("prefSetCopyOnSelect changes only the draft")
    func prefSetCopyOnSelectChangesOnlyTheDraft() {
        var model = makeModel()
        _ = update(&model, .preferencesOpened())

        _ = update(&model, .prefSetCopyOnSelect(false))

        #expect(model.preferencesDraft?.copyOnSelect == false)
        #expect(model.config.copyOnSelect, "committed config only moves on save")
    }

    @Test("the copy-on-select checkbox renders the draft value")
    func copyOnSelectCheckboxRendersDraftValue() throws {
        var model = makeModel()
        _ = update(&model, .preferencesOpened())
        #expect(try #require(desiredPreferencesPanel(in: model)).copyOnSelect)

        _ = update(&model, .prefSetCopyOnSelect(false))

        #expect(try #require(desiredPreferencesPanel(in: model)).copyOnSelect == false)
    }

    @Test("configLoaded while the panel is open resets the copy-on-select draft")
    func configLoadedResetsCopyOnSelectDraft() {
        var model = makeModel()
        _ = update(&model, .preferencesOpened())
        _ = update(&model, .prefSetCopyOnSelect(false))

        _ = update(&model, .configLoaded(.default, resolvedFontFamily: nil))

        #expect(model.preferencesDraft?.copyOnSelect == true)
    }

    // MARK: - Save

    @Test("prefSave writes the drafted copy-on-select into the one config transaction")
    func prefSaveWritesCopyOnSelect() {
        var model = makeModel()
        _ = update(&model, .preferencesOpened())
        _ = update(&model, .prefSetCopyOnSelect(false))

        let commands = update(&model, .prefSave)

        #expect(model.config.copyOnSelect == false)
        #expect(commands.count == 1)
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config.copyOnSelect == false }
            return false
        })
    }
}
