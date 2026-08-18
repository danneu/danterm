// Pins the pure half of the Preferences font-family picker: the installed-family
// catalog the impure caller injects when the panel opens, the choices/text/dirty
// values projected from it, and the "not installed" warning that clears the
// moment the user edits the field. The core validates syntax only and never asks
// CoreText anything -- the catalog arrives with `preferencesOpened` and the
// resolution verdict with `configLoaded` -- so every test here injects both. The AppKit wiring these
// values drive lives in the UI harness (PreferencesPanelTests).
import Foundation
import Testing
import DanTermProtocol

@testable import DanTermCore

@Suite struct PreferencesFontFamilyTests {
    private func openPanel(
        _ model: inout AppModel,
        installedFontFamilies: [String] = []
    ) {
        _ = update(
            &model,
            .preferencesOpened(installedFontFamilies: installedFontFamilies)
        )
    }

    // MARK: - Injected catalog

    @Test("the panel offers the injected families, system monospace first")
    func panelOffersInjectedFamilies() throws {
        // Intent: the choices the panel shows come from the catalog the runtime
        //   injected, in the order it supplied, behind the system-default entry.
        // Why it exists: pins that the core neither sorts nor sources the list --
        //   its syntax-only contract forbids querying CoreText -- while still owning the one entry
        //   that is not a font: the system-monospace default.
        // Scenario: spec-first; the user opens Preferences on a machine with a
        //   handful of families installed.
        var model = makeModel()
        openPanel(&model, installedFontFamilies: ["Courier", "Menlo", "SF Mono"])

        let projection = try #require(desiredPreferencesPanel(in: model))

        #expect(projection.fontFamilyChoices == [
            systemMonospaceFontChoiceTitle, "Courier", "Menlo", "SF Mono",
        ])
    }

    @Test("closing the panel drops the catalog")
    func closingPanelDropsCatalog() {
        var model = makeModel()
        openPanel(&model, installedFontFamilies: ["Menlo"])

        _ = update(&model, .preferencesClosed)

        #expect(model.installedFontFamilies.isEmpty, "the catalog is refreshed on each open")
    }

    // MARK: - Field text

    @Test("an unset family shows the system-monospace choice as the field text")
    func unsetFamilyShowsSystemMonospaceText() throws {
        var model = makeModel()
        openPanel(&model)

        let projection = try #require(desiredPreferencesPanel(in: model))

        #expect(projection.fontFamilyText == systemMonospaceFontChoiceTitle)
    }

    @Test("the committed family is the field text")
    func committedFamilyIsFieldText() throws {
        var model = makeModel()
        model.config.fontFamily = "Menlo"
        openPanel(&model)

        let projection = try #require(desiredPreferencesPanel(in: model))

        #expect(projection.fontFamilyText == "Menlo")
    }

    @Test("choosing the system-monospace entry is not a font name")
    func systemMonospaceChoiceIsNotAFontName() throws {
        // Intent: putting the system-monospace title in the field means "no
        //   family", not a family literally named that.
        // Why it exists: the combo box writes its selected item's title straight
        //   into the draft, so the one non-font entry has to normalize back to
        //   nil -- otherwise Save would persist the menu label as a font name.
        // Scenario: spec-first; the user picks System Monospace (Default) in the
        //   picker to go back to the built-in font.
        var model = makeModel()
        model.config.fontFamily = "Menlo"
        openPanel(&model)

        _ = update(&model, .prefSetFontFamily(systemMonospaceFontChoiceTitle))
        let commands = update(&model, .prefSave)

        #expect(model.config.fontFamily == nil)
        #expect(hasEffect(commands) {
            if case .saveDanTermConfig(let config) = $0 { return config.fontFamily == nil }
            return false
        })
    }

    // MARK: - Warning

    @Test("an unresolved committed family warns in the panel")
    func unresolvedFamilyWarns() throws {
        // Intent: a configured family the machine does not have is reported
        //   inline in Preferences, naming the font and the fallback.
        // Why it exists: this is the whole non-modal feedback channel for a
        //   soft, fully-recovered config failure -- without it a typo renders
        //   the system font with no signal at all.
        // Scenario: spec-first; the user typed "Fira Codee" into config.json and
        //   opens Preferences to see why nothing changed.
        var model = makeModel()
        var config = DanTermConfig.default
        config.fontFamily = "Fira Codee"
        _ = update(&model, .configLoaded(config, resolvedFontFamily: nil))
        openPanel(&model)

        let projection = try #require(desiredPreferencesPanel(in: model))

        #expect(
            projection.fontFamilyWarning
                == "Font \"Fira Codee\" is not installed -- using the system monospace font."
        )
    }

    @Test("a resolved family carries no warning")
    func resolvedFamilyHasNoWarning() throws {
        var model = makeModel()
        var config = DanTermConfig.default
        config.fontFamily = "menlo"
        _ = update(&model, .configLoaded(config, resolvedFontFamily: "Menlo"))
        openPanel(&model)

        #expect(try #require(desiredPreferencesPanel(in: model)).fontFamilyWarning == nil)
    }

    @Test("the warning clears as soon as the field is edited away")
    func warningClearsOnEdit() throws {
        // Intent: the warning describes the text currently in the field; editing
        //   the field to anything else clears it.
        // Why it exists: the warning names a specific font, so leaving it up
        //   while the user types a different name would describe text that is no
        //   longer on screen -- and the new name has not been resolved yet.
        // Scenario: spec-first; the user starts correcting "Fira Codee" in the
        //   Preferences font field.
        var model = makeModel()
        var config = DanTermConfig.default
        config.fontFamily = "Fira Codee"
        _ = update(&model, .configLoaded(config, resolvedFontFamily: nil))
        openPanel(&model)

        _ = update(&model, .prefSetFontFamily("Fira Code"))

        #expect(try #require(desiredPreferencesPanel(in: model)).fontFamilyWarning == nil)
    }

    @Test("the warning returns when the field is edited back to the bad name")
    func warningReturnsOnRevert() throws {
        var model = makeModel()
        var config = DanTermConfig.default
        config.fontFamily = "Fira Codee"
        _ = update(&model, .configLoaded(config, resolvedFontFamily: nil))
        openPanel(&model)
        _ = update(&model, .prefSetFontFamily("Fira Code"))

        _ = update(&model, .prefSetFontFamily("Fira Codee"))

        #expect(try #require(desiredPreferencesPanel(in: model)).fontFamilyWarning != nil)
    }
}
