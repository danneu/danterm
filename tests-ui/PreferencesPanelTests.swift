// UI-harness tests for the Preferences panel's font-family row: the combo box
// populated from the projection's injected catalog, the messages typing and
// picking dispatch, and the inline "not installed" warning. The pure projection
// tests (PreferencesFontFamilyTests) prove the values; only this harness can
// prove the AppKit control actually shows them and turns user gestures back into
// the right Msg.
import Cocoa

/// Registers Preferences-panel coverage in the standalone UI harness.
@MainActor
func preferencesPanelTests() {
    print("PreferencesPanel")

    uiTest("settings use a standard Mac window") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }

        try uiExpect(fx.panel.title == "DanTerm Settings", "single-pane settings should name the app")
        try uiExpect(!fx.panel.styleMask.contains(.utilityWindow),
                     "settings should not use the compact utility-panel title bar")
        try uiExpect(!fx.panel.styleMask.contains(.miniaturizable), "settings should not minimize")
        try uiExpect(!fx.panel.styleMask.contains(.resizable), "single-pane settings should not resize")
    }

    uiTest("settings use user-facing alert and config action labels") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        let titles = descendantControlTitles(in: fx.panel.contentView)

        try uiExpect(titles.contains("Clear Alerts"), "the alert setting should describe its effect")
        try uiExpect(titles.contains("On Focus"), "the selected alert value should read naturally")
        try uiExpect(titles.contains("Open Config File"), "the immediate config action should omit an ellipsis")
        try uiExpect(!titles.contains("Alert Clear Mode"), "the implementation label should not reach the UI")
        try uiExpect(!titles.contains("Open Config File..."), "an immediate action should not imply another step")
    }

    uiTest("the absent font warning collapses its grid row") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        guard let grid = fx.panel.contentView?.subviews.compactMap({ $0 as? NSGridView }).first else {
            throw UITestFailure(message: "expected settings grid")
        }

        try uiExpect(grid.row(at: 3).isHidden, "a hidden warning must not reserve vertical space")
    }

    uiTest("theme names are picker-only") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(themeText: "Monokai", remoteThemeText: "Purplepeter"))
        let fields = descendantTextFields(in: fx.panel.contentView)

        let theme = try uiRequire(fields.first { $0.stringValue == "Monokai" }, "expected theme field")
        let remote = try uiRequire(fields.first { $0.stringValue == "Purplepeter" }, "expected remote theme field")
        try uiExpect(!theme.isEditable, "theme changes should go through the picker")
        try uiExpect(!remote.isEditable, "remote theme changes should go through the picker")
    }

    uiTest("theme fields fill the same remaining row width") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(themeText: "Monokai Remastered", remoteThemeText: "Purplepeter"))
        fx.panel.contentView?.layoutSubtreeIfNeeded()
        let fields = descendantTextFields(in: fx.panel.contentView)
        let theme = try uiRequire(
            fields.first { $0.stringValue == "Monokai Remastered" },
            "expected theme field"
        )
        let remote = try uiRequire(
            fields.first { $0.stringValue == "Purplepeter" },
            "expected remote theme field"
        )

        try uiExpect(
            abs(theme.frame.width - remote.frame.width) < 0.5,
            "theme fields should consume the same available width: \(theme.frame.width), \(remote.frame.width)"
        )
    }

    uiTest("the label column reserves no width beyond its widest label") {
        // Intent: the right-aligned label column shrink-wraps its widest label,
        //   so every spare point of the form goes to the input controls.
        // Why it exists: NSGridView hands 100% of a grid's surplus width to
        //   column 0 and ignores content hugging entirely, so a form wider than
        //   its content pads the labels and starves the inputs. The panel used
        //   to assert a fixed 420pt window width, which produced exactly that.
        // Scenario: the reported gap between the window edge and "Remote Theme".
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(themeText: "Monokai Remastered", remoteThemeText: "Purplepeter"))
        fx.panel.contentView?.layoutSubtreeIfNeeded()
        guard let grid = fx.panel.contentView?.subviews.compactMap({ $0 as? NSGridView }).first else {
            throw UITestFailure(message: "expected settings grid")
        }
        let labels = rowLabels(in: grid)
        try uiExpect(labels.count >= 5, "expected the form's row labels, found \(labels.count)")

        let widest = try uiRequire(labels.min { $0.frame.minX < $1.frame.minX }, "expected a widest label")
        let deadSpace = widest.frame.minX - grid.bounds.minX

        try uiExpect(deadSpace < 4,
                     "the widest label '\(widest.stringValue)' should start at the form's leading edge, "
                     + "but \(deadSpace)pt of the label column is unused")
    }

    uiTest("the settings window is exactly as wide as its content needs") {
        // Intent: the panel's width is derived from its content, never asserted.
        // Why it exists: this is the invariant that makes the label-padding bug
        //   impossible. Any surplus width the window carries is surplus the grid
        //   will dump into the label column, so the fix is to have no surplus.
        // Scenario: spec-first.
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.contentView?.layoutSubtreeIfNeeded()
        guard let contentView = fx.panel.contentView else {
            throw UITestFailure(message: "expected a content view")
        }

        try uiExpect(
            abs(contentView.frame.width - contentView.fittingSize.width) < 0.5,
            "the window should size to its content: frame \(contentView.frame.width), "
            + "fitting \(contentView.fittingSize.width)"
        )
    }

    uiTest("the input controls get the full width the labels do not need") {
        // Intent: the control column is at least as wide as the panel declares
        //   it wants, so themes and font families stay readable.
        // Why it exists: before the width became content-driven, the controls
        //   were capped at the natural width of the two config buttons and every
        //   extra point went to the labels instead.
        // Scenario: spec-first.
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(themeText: "Monokai Remastered"))
        fx.panel.contentView?.layoutSubtreeIfNeeded()

        try uiExpect(
            fx.panel.fontFamilyCombo.frame.width >= preferencesControlColumnWidth,
            "the font-family combo should fill the control column, got \(fx.panel.fontFamilyCombo.frame.width)"
        )
    }

    uiTest("theme fallback warnings show inline and collapse when resolved") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        guard let grid = fx.panel.contentView?.subviews.compactMap({ $0 as? NSGridView }).first else {
            throw UITestFailure(message: "expected settings grid")
        }
        let localWarning = "Theme \"Missing Local\" is not available -- using the built-in dark theme."
        let remoteWarning = "Theme \"Missing Remote\" is not available -- using the built-in dark theme."

        fx.panel.apply(makeProjection(themeWarning: localWarning, remoteThemeWarning: remoteWarning))
        let visibleTitles = descendantControlTitles(in: fx.panel.contentView)
        try uiExpect(visibleTitles.contains(localWarning), "expected local fallback warning")
        try uiExpect(visibleTitles.contains(remoteWarning), "expected remote fallback warning")
        try uiExpect(!grid.row(at: 1).isHidden, "local warning row should expand")
        try uiExpect(!grid.row(at: 8).isHidden, "remote warning row should expand")

        fx.panel.apply(makeProjection())
        try uiExpect(grid.row(at: 1).isHidden, "resolved local warning row should collapse")
        try uiExpect(grid.row(at: 8).isHidden, "resolved remote warning row should collapse")
    }

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

    uiTest("picking a family from the list applies that family immediately") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(choices: [systemMonospaceFontChoiceTitle, "Menlo"]))

        fx.panel.fontFamilyCombo.selectItem(at: 1)

        try uiExpect(fx.runtime.sentMessages.count == 2, "expected a draft followed by a save")
        guard case .prefSetFontFamily(let family) = fx.runtime.sentMessages[0] else {
            throw UITestFailure(message: "expected prefSetFontFamily, got \(fx.runtime.sentMessages[0])")
        }
        try uiExpect(family == "Menlo", "expected the picked family, got \(family ?? "nil")")
        guard case .prefSave = fx.runtime.sentMessages[1] else {
            throw UITestFailure(message: "expected prefSave, got \(fx.runtime.sentMessages[1])")
        }
    }

    uiTest("picking the system-monospace entry applies the sentinel, not a font name") {
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

        guard case .prefSetFontFamily(let family) = fx.runtime.sentMessages.first else {
            throw UITestFailure(message: "expected prefSetFontFamily, got \(String(describing: fx.runtime.sentMessages.first))")
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

    uiTest("ending a text edit applies the drafted value") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }

        fx.panel.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: fx.panel.fontFamilyCombo)
        )

        guard case .prefSave = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "expected prefSave, got \(String(describing: fx.runtime.sentMessages.last))")
        }
    }

    uiTest("the font-size stepper updates the field and applies the size") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(fontSizeText: "13"))

        fx.panel.fontSizeStepper.doubleValue = 14
        _ = fx.panel.fontSizeStepper.sendAction(
            fx.panel.fontSizeStepper.action,
            to: fx.panel.fontSizeStepper.target
        )

        try uiExpect(fx.panel.fontSizeField.stringValue == "14", "the field should mirror the stepped size")
        try uiExpect(fx.runtime.sentMessages.count == 2, "expected a draft followed by a save")
        guard case .prefSetFontSize(let text) = fx.runtime.sentMessages[0] else {
            throw UITestFailure(message: "expected prefSetFontSize, got \(fx.runtime.sentMessages[0])")
        }
        try uiExpect(text == "14", "expected stepped size 14, got \(text ?? "nil")")
        guard case .prefSave = fx.runtime.sentMessages[1] else {
            throw UITestFailure(message: "expected prefSave, got \(fx.runtime.sentMessages[1])")
        }
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

    uiTest("the copy-on-select checkbox shows and immediately applies the projected value") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }

        fx.panel.apply(makeProjection(copyOnSelect: true))
        try uiExpect(fx.panel.copyOnSelectCheckbox.state == .on, "an armed option should tick the box")

        fx.panel.copyOnSelectCheckbox.performClick(nil)

        try uiExpect(fx.runtime.sentMessages.count == 2, "expected a draft followed by a save")
        guard case .prefSetCopyOnSelect(let enabled) = fx.runtime.sentMessages[0] else {
            throw UITestFailure(message: "expected prefSetCopyOnSelect, got \(fx.runtime.sentMessages[0])")
        }
        try uiExpect(enabled == false, "unticking should draft the option off")
        guard case .prefSave = fx.runtime.sentMessages[1] else {
            throw UITestFailure(message: "expected prefSave, got \(fx.runtime.sentMessages[1])")
        }

        fx.panel.apply(makeProjection(copyOnSelect: false))
        try uiExpect(fx.panel.copyOnSelectCheckbox.state == .off, "a disarmed option should untick the box")
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
    fontSizeText: String = "",
    themeText: String = "",
    remoteThemeText: String = "",
    warning: String? = nil,
    themeWarning: String? = nil,
    remoteThemeWarning: String? = nil,
    copyOnSelect: Bool = true
) -> PreferencesPanelProjection {
    PreferencesPanelProjection(
        selectedAlertClearMode: .focus,
        remoteThemeText: remoteThemeText,
        themeText: themeText,
        fontSizeText: fontSizeText,
        fontFamilyText: text,
        copyOnSelect: copyOnSelect,
        fontFamilyChoices: choices,
        fontFamilyWarning: warning,
        themeWarning: themeWarning,
        remoteThemeWarning: remoteThemeWarning
    )
}

private func descendantControlTitles(in view: NSView?) -> [String] {
    guard let view else { return [] }
    let ownTitle: [String]
    if let button = view as? NSButton {
        ownTitle = [button.title]
    } else if let field = view as? NSTextField, !field.isEditable {
        ownTitle = [field.stringValue]
    } else {
        ownTitle = []
    }
    return ownTitle + view.subviews.flatMap { descendantControlTitles(in: $0) }
}

/// The right-aligned form labels in the grid's first column, in row order.
private func rowLabels(in grid: NSGridView) -> [NSTextField] {
    (0..<grid.numberOfRows).compactMap { row in
        guard let label = grid.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField,
              label.alignment == .right
        else { return nil }
        return label
    }
}

private func descendantTextFields(in view: NSView?) -> [NSTextField] {
    guard let view else { return [] }
    let ownField = (view as? NSTextField).map { [$0] } ?? []
    return ownField + view.subviews.flatMap { descendantTextFields(in: $0) }
}

private func uiRequire<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else { throw UITestFailure(message: message) }
    return value
}
