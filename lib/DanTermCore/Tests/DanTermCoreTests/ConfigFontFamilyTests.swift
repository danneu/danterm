// Pins the model contract for the configurable terminal font family: the
// injected `resolvedFontFamily` verdict that rides along with every config
// application, its propagation into the per-pane config key, and the
// preferences draft/save leg that lets the user change the family. The core
// validates the family as syntax only and never asks CoreText whether it exists --
// it is handed the answer, exactly like ids and time -- so every test here injects the verdict rather
// than probing the machine. The CoreText probe itself is proved in
// DanTermSupport's FontAvailabilityTests; the AppKit picker and the "not
// installed" warning arrive with the preferences panel.
import Foundation
import DanTermProtocol
import Testing

@testable import DanTermCore

@Suite struct ConfigFontFamilyTests {
    // MARK: - Applying a config carries its resolution

    @Test("configLoaded stores the injected resolved family beside the config")
    func configLoadedStoresResolvedFamily() {
        var model = makeModel()
        var config = DanTermConfig.default
        config.fontFamily = "menlo"

        _ = update(&model, .configLoaded(config, resolvedFontFamily: "Menlo"))

        #expect(model.config.fontFamily == "menlo", "the request stays verbatim")
        #expect(model.resolvedFontFamily == "Menlo", "the canonical family comes from the caller")
    }

    @Test("configLoaded with an unresolved family leaves resolvedFontFamily nil")
    func configLoadedWithUnresolvedFamilyLeavesResolutionNil() {
        // Intent: a family the caller could not resolve still lands in
        //   model.config, but nothing reaches the render layer.
        // Why it exists: pins the soft-failure contract -- a typo'd family must
        //   never reach rendering without a verified, canonical resolution, and the
        //   app must still launch normally on it.
        // Scenario: spec-first; the user typed "Fira Codee" into config.json.
        var model = makeModel()
        var config = DanTermConfig.default
        config.fontFamily = "Fira Codee"

        _ = update(&model, .configLoaded(config, resolvedFontFamily: nil))

        #expect(model.config.fontFamily == "Fira Codee")
        #expect(model.resolvedFontFamily == nil)
    }

    @Test("re-applying a config without a family clears a previous resolution")
    func configLoadedWithoutFamilyClearsPreviousResolution() {
        // Intent: removing font.family and reloading returns the model to the
        //   system-monospace state.
        // Why it exists: guards the coherent config/resolution pair against drift --
        //   a stale resolution would keep panes on the old face after the key was deleted.
        // Scenario: spec-first; the user deletes font.family and reloads config.
        var model = makeModel()
        var config = DanTermConfig.default
        config.fontFamily = "Menlo"
        _ = update(&model, .configLoaded(config, resolvedFontFamily: "Menlo"))

        _ = update(&model, .configLoaded(.default, resolvedFontFamily: nil))

        #expect(model.config.fontFamily == nil)
        #expect(model.resolvedFontFamily == nil)
    }

    // MARK: - Pane projection

    @Test("desiredPaneConfig carries the resolved family, not the requested one")
    func desiredPaneConfigCarriesResolvedFamily() {
        // Intent: live panes are keyed on the resolved family so reconcile
        //   re-pushes when it changes, and only a verified family reaches them.
        // Why it exists: pins the projection boundary -- only the verified,
        //   canonical family may reach rendering, never the raw requested string.
        // Scenario: spec-first; config asks for "menlo", the probe canonicalizes
        //   it to "Menlo".
        var model = makeModel()
        _ = createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        var config = DanTermConfig.default
        config.fontFamily = "menlo"

        _ = update(&model, .configLoaded(config, resolvedFontFamily: "Menlo"))

        #expect(desiredPaneConfig(in: model)[paneId]?.fontFamily == "Menlo")
    }

    @Test("desiredPaneConfig key changes when the resolved family changes")
    func desiredPaneConfigKeyChangesWithResolvedFamily() {
        var model = makeModel()
        _ = createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let before = desiredPaneConfig(in: model)[paneId]

        var config = DanTermConfig.default
        config.fontFamily = "Menlo"
        _ = update(&model, .configLoaded(config, resolvedFontFamily: "Menlo"))

        #expect(desiredPaneConfig(in: model)[paneId] != before, "reconcile must re-push")
    }

    @Test("an unresolved family leaves the pane key on the system default")
    func unresolvedFamilyLeavesPaneKeyUnchanged() {
        var model = makeModel()
        _ = createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        let before = desiredPaneConfig(in: model)[paneId]

        var config = DanTermConfig.default
        config.fontFamily = "Fira Codee"
        _ = update(&model, .configLoaded(config, resolvedFontFamily: nil))

        #expect(desiredPaneConfig(in: model)[paneId] == before)
        #expect(desiredPaneConfig(in: model)[paneId]?.fontFamily == nil)
    }

    // MARK: - Preferences draft

    @Test("preferencesOpened seeds the font-family draft from the committed config")
    func preferencesOpenedSeedsFontFamilyDraft() {
        var model = makeModel()
        model.config.fontFamily = "Menlo"

        _ = update(&model, .preferencesOpened())

        #expect(model.preferencesDraft?.config.fontFamily == "Menlo")
    }

    @Test(".prefSet(.fontFamily) changes only the draft")
    func fontFamilyEditChangesOnlyTheDraft() {
        var model = makeModel()
        _ = update(&model, .preferencesOpened())

        _ = update(&model, .prefSet(.fontFamily("Menlo")))

        #expect(model.preferencesDraft?.config.fontFamily == "Menlo")
        #expect(model.config.fontFamily == nil, "committed config only moves on save")
    }

    @Test("configLoaded while the panel is open resets the font-family draft")
    func configLoadedResetsFontFamilyDraft() {
        var model = makeModel()
        _ = update(&model, .preferencesOpened())
        _ = update(&model, .prefSet(.fontFamily("Menlo")))

        var config = DanTermConfig.default
        config.fontFamily = "Courier"
        _ = update(&model, .configLoaded(config, resolvedFontFamily: "Courier"))

        #expect(model.preferencesDraft?.config.fontFamily == "Courier")
    }

    // MARK: - Save and coherent config application

    @Test("prefSave writes the drafted family into the one config transaction")
    func prefSaveWritesFontFamily() {
        var model = makeModel()
        _ = update(&model, .preferencesOpened())
        _ = update(&model, .prefSet(.fontFamily("Menlo")))

        let commands = update(&model, .prefSave)

        #expect(model.config.fontFamily == "Menlo")
        #expect(commands.count == 1)
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config.fontFamily == "Menlo" }
            return false
        })
    }

    @Test("prefSave still writes a family the machine cannot resolve")
    func prefSaveWritesUnresolvableFamily() {
        // Intent: saving a family that is not installed is not an error -- it is
        //   written to disk like any other value.
        // Why it exists: pins the "it is the user's file" rule; they may be about
        //   to install the font, and the syntax-only core never queries CoreText.
        // Scenario: spec-first; the user types a font they have not installed yet.
        var model = makeModel()
        _ = update(&model, .preferencesOpened())
        _ = update(&model, .prefSet(.fontFamily("Fira Codee")))

        let commands = update(&model, .prefSave)

        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config.fontFamily == "Fira Codee" }
            return false
        })
    }

    @Test("prefSave with a blank family removes the key")
    func prefSaveWithBlankFamilyRemovesTheKey() {
        var model = makeModel()
        model.config.fontFamily = "Menlo"
        _ = update(&model, .preferencesOpened())
        _ = update(&model, .prefSet(.fontFamily("   ")))

        let commands = update(&model, .prefSave)

        #expect(model.config.fontFamily == nil)
        #expect(model.preferencesDraft?.config.fontFamily == nil, "draft normalizes to the saved value")
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config.fontFamily == nil }
            return false
        })
    }

    @Test("saving a family and then resolving it repaints live panes")
    func saveThenResolveRepaintsLivePanes() throws {
        // Intent: a Preferences save reaches live panes without a reload step in
        //   between -- Save, then the resolution, and the pane key has moved.
        // Why it exists: pins that Preferences save resolves and applies the family
        //   coherently. prefSave alone cannot know whether the family exists, so the
        //   runtime feeds the verdict straight back and repaints panes without a reload.
        // Scenario: spec-first; the user picks Menlo in Preferences and hits Save.
        var model = makeModel()
        _ = createTab(&model)
        let paneId = model.groups[0].tabs[0].paneTree.focusedPaneId
        _ = update(&model, .preferencesOpened())
        _ = update(&model, .prefSet(.fontFamily("menlo")))

        let commands = update(&model, .prefSave)
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig = $0 { return true }
            return false
        })
        _ = update(&model, .fontFamilyResolved("Menlo"))

        #expect(desiredPaneConfig(in: model)[paneId]?.fontFamily == "Menlo")
        #expect(try #require(desiredPreferencesPanel(in: model)).fontFamilyText == "menlo",
                "the field echoes back the name that was committed, not the resolved one")
    }

    @Test("fontFamilyResolved carries the verdict alone, touching nothing else")
    func fontFamilyResolvedTouchesNothingElse() {
        // Intent: the post-save resolution message updates only
        //   `resolvedFontFamily`; the committed config and the open draft are
        //   left exactly as prefSave left them.
        // Why it exists: this is why the save path does not reuse configLoaded --
        //   that message resets the draft, which would wipe an invalid font size
        //   the panel deliberately keeps on screen so the user can fix it.
        // Scenario: spec-first; the user saves a font family while the font-size
        //   field still holds unparseable text.
        var model = makeModel()
        _ = update(&model, .preferencesOpened())
        _ = update(&model, .prefSet(.fontFamily("Menlo")))
        _ = update(&model, .prefSet(.fontSize("abc")))
        _ = update(&model, .prefSave)
        let configAfterSave = model.config

        let commands = update(&model, .fontFamilyResolved("Menlo"))

        #expect(model.resolvedFontFamily == "Menlo")
        #expect(model.config == configAfterSave)
        #expect(model.preferencesDraft?.fontSizeText == "abc", "the bad input stays visible")
        #expect(commands.isEmpty)
    }
}
