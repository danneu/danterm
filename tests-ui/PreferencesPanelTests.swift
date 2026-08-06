// UI-harness tests for the Preferences panel's font-family row: the combo box
// populated from the projection's injected catalog, the messages typing and
// picking dispatch, and the inline "not installed" warning. The pure projection
// tests (PreferencesFontFamilyTests) prove the values; only this harness can
// prove the AppKit control actually shows them and turns user gestures back into
// the right Msg.
import Cocoa

/// Registers Preferences-panel coverage in the GhosttyKit-free UI harness.
func preferencesPanelTests() {
    print("PreferencesPanel")

    uiTest("the font-family combo box lists the projected choices in order") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }

        fx.panel.apply(makeProjection(choices: [
            systemMonospaceFontChoiceTitle, "Courier", "Menlo",
        ]))

        let items = fx.panel.fontFamilyCombo.objectValues as? [String]
        try uiExpect(items == [systemMonospaceFontChoiceTitle, "Courier", "Menlo"],
                     "combo items should mirror the projection: \(items ?? [])")
        try uiExpect(fx.panel.fontFamilyCombo.stringValue == systemMonospaceFontChoiceTitle,
                     "an unset family should display the system-monospace entry")
    }

    uiTest("picking a family from the list drafts that family") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(choices: [systemMonospaceFontChoiceTitle, "Menlo"]))

        fx.panel.fontFamilyCombo.selectItem(at: 1)

        try uiExpect(fx.runtime.sentMessages.count == 1, "expected exactly one message")
        guard case .prefSetFontFamily(let family) = fx.runtime.sentMessages[0] else {
            throw UITestFailure(message: "expected prefSetFontFamily, got \(fx.runtime.sentMessages[0])")
        }
        try uiExpect(family == "Menlo", "expected the picked family, got \(family ?? "nil")")
    }

    uiTest("picking the system-monospace entry drafts the sentinel, not a font name") {
        // Intent: the one non-font entry round-trips through the same message as
        //   every family, and the core is what turns it back into "no family".
        // Why it exists: pins the seam that keeps the AppKit side free of
        //   special cases -- the panel writes the selected title verbatim, so the
        //   sentinel has to survive the trip to stay meaningful.
        // Scenario: spec-first; the user picks System Monospace (Default) to drop
        //   a custom family.
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(text: "Menlo", choices: [systemMonospaceFontChoiceTitle, "Menlo"]))

        fx.panel.fontFamilyCombo.selectItem(at: 0)

        guard case .prefSetFontFamily(let family) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "expected prefSetFontFamily, got \(String(describing: fx.runtime.sentMessages.last))")
        }
        try uiExpect(family == systemMonospaceFontChoiceTitle,
                     "expected the sentinel title, got \(family ?? "nil")")
    }

    uiTest("typing a family drafts the typed text") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(choices: [systemMonospaceFontChoiceTitle, "Menlo"]))

        fx.panel.fontFamilyCombo.stringValue = "Fira Code"
        fx.panel.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: fx.panel.fontFamilyCombo)
        )

        guard case .prefSetFontFamily(let family) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "expected prefSetFontFamily, got \(String(describing: fx.runtime.sentMessages.last))")
        }
        try uiExpect(family == "Fira Code", "expected the typed text, got \(family ?? "nil")")
    }

    uiTest("clearing the field drafts no family at all") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(text: "Menlo", choices: [systemMonospaceFontChoiceTitle, "Menlo"]))

        fx.panel.fontFamilyCombo.stringValue = ""
        fx.panel.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: fx.panel.fontFamilyCombo)
        )

        guard case .prefSetFontFamily(let family) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "expected prefSetFontFamily, got \(String(describing: fx.runtime.sentMessages.last))")
        }
        try uiExpect(family == nil, "an empty field means no family, got \(family ?? "nil")")
    }

    uiTest("a projected warning shows inline and lays out") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        let warning = "Font \"Fira Codee\" is not installed -- using the system monospace font."

        fx.panel.apply(makeProjection(text: "Fira Codee", warning: warning))
        fx.panel.contentView?.layoutSubtreeIfNeeded()

        try uiExpect(fx.panel.fontFamilyWarningLabel.isHidden == false, "warning label should be visible")
        try uiExpect(fx.panel.fontFamilyWarningLabel.stringValue == warning, "warning text mismatch")
        try uiExpect(fx.panel.contentView?.hasAmbiguousLayout == false,
                     "the warning row must not leave the panel ambiguously laid out")
        try uiExpect((fx.panel.contentView?.fittingSize.height ?? 0) > 0, "panel should size itself")
    }

    uiTest("a projection without a warning hides the label") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(text: "Fira Codee", warning: "Font \"Fira Codee\" is not installed."))

        fx.panel.apply(makeProjection(text: "Fira Code"))
        fx.panel.contentView?.layoutSubtreeIfNeeded()

        try uiExpect(fx.panel.fontFamilyWarningLabel.isHidden, "warning label should be hidden")
        try uiExpect(fx.panel.contentView?.hasAmbiguousLayout == false,
                     "hiding the warning must not leave the panel ambiguously laid out")
    }

    uiTest("the font-family Reset button asks the model to restore the committed family") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(text: "Courier", dirtyLabel: "Prev: Menlo"))

        try uiExpect(fx.panel.fontFamilyDirtyRow.isHidden == false, "dirty row should show for an edited family")
        fx.panel.fontFamilyResetButton.performClick(nil)

        guard case .prefResetFontFamily = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "expected prefResetFontFamily, got \(String(describing: fx.runtime.sentMessages.last))")
        }
    }
}

// MARK: - Fixture

private struct PreferencesFixture {
    let runtime: AppRuntime
    let panel: PreferencesPanel
}

private func makePreferencesFixture() -> PreferencesFixture {
    let runtime = AppRuntime()
    let panel = PreferencesPanel(runtime: runtime)
    return PreferencesFixture(runtime: runtime, panel: panel)
}

private func makeProjection(
    text: String = systemMonospaceFontChoiceTitle,
    choices: [String] = [systemMonospaceFontChoiceTitle],
    warning: String? = nil,
    dirtyLabel: String? = nil
) -> PreferencesPanelProjection {
    PreferencesPanelProjection(
        selectedAlertClearMode: .focus,
        remoteThemeText: "",
        themeText: "",
        fontSizeText: "",
        fontFamilyText: text,
        fontFamilyChoices: choices,
        fontFamilyWarning: warning,
        themeDirtyLabel: nil,
        fontSizeDirtyLabel: nil,
        fontFamilyDirtyLabel: dirtyLabel,
        alertClearModeDirtyLabel: nil,
        remoteThemeDirtyLabel: nil,
        saveEnabled: false
    )
}
