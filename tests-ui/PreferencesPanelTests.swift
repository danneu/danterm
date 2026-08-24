// UI-harness tests for the reusable Settings window. They cover its General
// controls, Key Bindings toolbar section and recorder, and the AppKit gestures
// that turn projected values back into model messages.
import Cocoa
import ChipArtwork
import DanTermProtocol
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

/// Registers Preferences-panel coverage in the standalone UI harness.
@MainActor
func preferencesPanelTests() async {
    print("PreferencesPanel")

    await uiTest("settings use a standard Mac window") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }

        try uiExpect(fx.panel.title == "DanTerm Settings", "single-pane settings should name the app")
        try uiExpect(!fx.panel.styleMask.contains(.utilityWindow),
                     "settings should not use the compact utility-panel title bar")
        try uiExpect(!fx.panel.styleMask.contains(.miniaturizable), "settings should not minimize")
        try uiExpect(!fx.panel.styleMask.contains(.resizable), "single-pane settings should not resize")
    }

    await uiTest("settings use user-facing alert and config action labels") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        let titles = descendantControlTitles(in: fx.panel.contentView)

        try uiExpect(titles.contains("Clear Alerts"), "the alert setting should describe its effect")
        try uiExpect(titles.contains("On Focus"), "the selected alert value should read naturally")
        try uiExpect(titles.contains("Open Config File"), "the immediate config action should omit an ellipsis")
        try uiExpect(!titles.contains("Alert Clear Mode"), "the implementation label should not reach the UI")
        try uiExpect(!titles.contains("Open Config File..."), "an immediate action should not imply another step")
    }

    await uiTest("the alert clear mode uses one exclusive segmented control") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }

        try uiExpect(fx.panel.alertClearModeControl.trackingMode == .selectOne,
                     "the alert modes should be mutually exclusive")
        try uiExpect(fx.panel.alertClearModeControl.segmentCount == 2,
                     "the control should expose both alert modes")
        try uiExpect(fx.panel.alertClearModeControl.label(forSegment: 0) == "On Focus",
                     "the first segment should name focus clearing")
        try uiExpect(fx.panel.alertClearModeControl.label(forSegment: 1) == "Manually",
                     "the second segment should name manual clearing")

        fx.panel.apply(makeProjection(selectedAlertClearMode: .manual))
        try uiExpect(fx.panel.alertClearModeControl.selectedSegment == 1,
                     "the projection should select the manual segment")

        fx.runtime.sentMessages.removeAll()
        fx.panel.alertClearModeControl.selectedSegment = 0
        fx.panel.alertClearModeControl.sendAction(
            fx.panel.alertClearModeControl.action,
            to: fx.panel.alertClearModeControl.target
        )

        try uiExpect(fx.runtime.sentMessages.count == 2, "expected a draft followed by a save")
        guard case .prefSet(.alertClearMode(.focus)) = fx.runtime.sentMessages[0] else {
            throw UITestFailure(message: "expected focus alert mode, got \(fx.runtime.sentMessages[0])")
        }
        guard case .prefSave = fx.runtime.sentMessages[1] else {
            throw UITestFailure(message: "expected prefSave, got \(fx.runtime.sentMessages[1])")
        }
    }

    await uiTest("Option-as-Alt shows and applies all four policies") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        let choices: [(OptionAsAlt?, Int)] = [
            (nil, 0),
            (.left, 1),
            (.right, 2),
            (.both, 3),
        ]

        try uiExpect(fx.panel.optionAsAltControl.trackingMode == .selectOne,
                     "Option policies should be mutually exclusive")
        try uiExpect(fx.panel.optionAsAltControl.segmentCount == 4,
                     "the control should expose Native, Left, Right, and Both")
        try uiExpect(
            (0..<4).compactMap { fx.panel.optionAsAltControl.label(forSegment: $0) }
                == ["Native", "Left", "Right", "Both"],
            "the Option policy labels diverged"
        )

        for (policy, segment) in choices {
            fx.panel.apply(makeProjection(optionAsAlt: policy))
            try uiExpect(fx.panel.optionAsAltControl.selectedSegment == segment,
                         "the projection did not select segment \(segment)")

            fx.runtime.sentMessages.removeAll()
            fx.panel.optionAsAltControl.selectedSegment = segment
            fx.panel.optionAsAltControl.sendAction(
                fx.panel.optionAsAltControl.action,
                to: fx.panel.optionAsAltControl.target
            )

            try uiExpect(fx.runtime.sentMessages.count == 2, "expected a draft followed by a save")
            guard case .prefSet(.optionAsAlt(let reported)) = fx.runtime.sentMessages[0] else {
                throw UITestFailure(message: "expected an Option-as-Alt edit")
            }
            try uiExpect(reported == policy, "segment \(segment) reported the wrong policy")
            guard case .prefSave = fx.runtime.sentMessages[1] else {
                throw UITestFailure(message: "expected prefSave")
            }
        }
    }

    await uiTest("toolbar switches to a stable native keybinding table") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        let action = KeybindingSettingsAction(
            id: "tab.new", title: "New Tab", chords: [KeyChord(compact: "cmd+t")!],
            stateText: "Default",
            shortcutVisualValues: ["⌘T"], shortcutAccessibilityValues: ["Command-T"],
            shortcutsAreApplied: true, isSelected: false
        )

        fx.panel.apply(makeProjection(
            section: .keybindings,
            keybindingGroups: [KeybindingSettingsGroup(title: "Tabs", actions: [action])]
        ))

        try uiExpect(fx.panel.toolbar?.selectedItemIdentifier?.rawValue == "KeyBindings",
                     "the model-selected toolbar section should remain selected")
        try uiExpect(fx.panel.keybindingTable.numberOfRows == 2,
                     "the table should hold one category row and one command row")
        try uiExpect(fx.panel.tableView(fx.panel.keybindingTable, isGroupRow: 0),
                     "the category should use a native group row")
        let categoryCell = try uiRequire(
            fx.panel.keybindingTable.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? NSTableCellView,
            "the native table should render the projected category"
        )
        let commandCell = try uiRequire(
            fx.panel.keybindingTable.view(atColumn: 0, row: 1, makeIfNecessary: true)
                as? NSTableCellView,
            "the native table should render the projected command"
        )
        let statusCell = try uiRequire(
            fx.panel.keybindingTable.view(atColumn: 2, row: 1, makeIfNecessary: true)
                as? NSTableCellView,
            "the native table should render the projected state"
        )
        try uiExpect(categoryCell.textField?.stringValue == "Tabs",
                     "the category should show its title")
        try uiExpect(commandCell.textField?.stringValue == "New Tab",
                     "the command should show its title")
        try uiExpect(statusCell.textField?.stringValue == "Default",
                     "the command should show its state")
        let titles = descendantControlTitles(in: fx.panel.contentView)
        try uiExpect(!titles.contains("Show") && !titles.contains("Hide"),
                     "the browser should not expose disclosure controls")
        try uiExpect(
            fx.panel.keybindingActionsButton.item(withTitle: "Reset All Key Bindings...") != nil,
            "Reset All should live in the trailing action menu"
        )

        fx.panel.keybindingSearchField.stringValue = "focus"
        fx.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                   object: fx.panel.keybindingSearchField))
        guard case .prefKeybindingSearchChanged("focus") = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "search should update model-owned filter state")
        }
    }

    await uiTest("browser selection and edit entry points report model intents") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        let action = KeybindingSettingsAction(
            id: "tab.new", title: "New Tab", chords: [KeyChord(compact: "cmd+t")!],
            stateText: "Default", shortcutVisualValues: ["\u{2318}T"],
            shortcutAccessibilityValues: ["Command-T"], shortcutsAreApplied: true,
            isSelected: false
        )
        fx.panel.apply(makeProjection(
            section: .keybindings,
            keybindingGroups: [KeybindingSettingsGroup(title: "Tabs", actions: [action])]
        ))

        fx.panel.keybindingTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        fx.panel.tableViewSelectionDidChange(Notification(
            name: NSTableView.selectionDidChangeNotification, object: fx.panel.keybindingTable
        ))
        guard case .prefKeybinding(.selectBrowserAction("tab.new")) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "selection should report the command id")
        }

        let returnEvent = try uiRequire(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 0x24
        ), "expected a synthetic Return event")
        fx.panel.keybindingTable.keyDown(with: returnEvent)
        guard case .prefKeybinding(.openEditor("tab.new")) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "Return should open the selected command")
        }
        fx.runtime.sentMessages.removeAll()
        let doubleAction = try uiRequire(
            fx.panel.keybindingTable.doubleAction,
            "the table should install a double-click action"
        )
        _ = NSApp.sendAction(
            doubleAction,
            to: fx.panel.keybindingTable.target,
            from: fx.panel.keybindingTable
        )
        guard case .prefKeybinding(.openEditor("tab.new")) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "double-click should open the selected command")
        }
        fx.runtime.sentMessages.removeAll()
        fx.panel.apply(makeProjection(section: .keybindings))
        try uiExpect(fx.runtime.sentMessages.isEmpty,
                     "a projection reload should not report its own selection cleanup")
    }

    await uiTest("recording projection focuses the attached sheet recorder") {
        // Intent: the recorder owns key equivalents as soon as recording begins.
        // Why it exists: the 2026-08-21 recorder was focused while its row was
        //   still detached, so AppKit rejected it and shortcuts kept dispatching.
        // Scenario: an attached editor sheet projects its add-shortcut recorder as active.
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        let editor = KeybindingEditorProjection(
            actionID: "tab.new", title: "New Tab", isEnabled: true,
            shortcuts: [KeybindingEditorShortcutProjection(
                chord: KeyChord(compact: "cmd+t")!, visual: "\u{2318}T",
                accessibilityValue: "Command-T", moveNote: nil
            )],
            canAddOrRemove: true, recordingTarget: .adding,
            diagnosticText: nil, removalNote: nil
        )

        fx.panel.apply(makeProjection(
            section: .keybindings,
            keybindingEditor: editor
        ))

        let recorder = try uiRequire(
            fx.panel.keybindingEditorSheet?.firstResponder as? KeybindingRecorderButton,
            "the active recorder should become first responder after its row is attached"
        )
        try uiExpect(recorder.window === fx.panel.keybindingEditorSheet,
                     "the focused recorder should belong to the attached sheet")
    }

    await uiTest("sheet controls report transactional editor actions") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        let editor = KeybindingEditorProjection(
            actionID: "tab.new", title: "New Tab", isEnabled: true,
            shortcuts: [KeybindingEditorShortcutProjection(
                chord: KeyChord(compact: "cmd+t")!, visual: "\u{2318}T",
                accessibilityValue: "Command-T", moveNote: "Moved from Close Tab"
            ), KeybindingEditorShortcutProjection(
                chord: KeyChord(compact: "cmd+option+t")!, visual: "\u{2325}\u{2318}T",
                accessibilityValue: "Option-Command-T", moveNote: nil
            )],
            canAddOrRemove: true, recordingTarget: nil,
            diagnosticText: nil, removalNote: nil
        )
        fx.panel.apply(makeProjection(section: .keybindings, keybindingEditor: editor))
        let controller = try uiRequire(
            fx.panel.keybindingEditorController,
            "an editor projection should present one retained sheet controller"
        )
        try uiExpect(fx.panel.keybindingEditorSheet?.title.contains("New Tab") == true,
                     "the sheet should identify the command being edited")

        controller.addButton.performClick(nil)
        guard case .prefKeybinding(.beginEditorRecording(chordAt: nil)) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "Add should begin recording a new shortcut")
        }
        controller.enableCheckbox.performClick(nil)
        guard case .prefKeybinding(.setEditorEnabled(false)) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "the enable control should stage disabled state")
        }
        controller.resetButton.performClick(nil)
        guard case .prefKeybinding(.resetEditor) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "Reset to Defaults should reset the candidate")
        }
        let buttons = descendantButtons(in: controller.view)
        try uiRequire(buttons.first { $0.title == "Make Primary" },
                      "an alternate shortcut should offer Make Primary").performClick(nil)
        guard case .prefKeybinding(.makeEditorChordPrimary(at: 1)) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "Make Primary should report its shortcut index")
        }
        try uiRequire(buttons.first { $0.title == "Remove" && $0.tag == 1 },
                      "an alternate shortcut should offer Remove").performClick(nil)
        guard case .prefKeybinding(.removeEditorChord(at: 1)) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "Remove should report its shortcut index")
        }
        try uiExpect(descendantControlTitles(in: controller.view).contains("Moved from Close Tab"),
                     "the sheet should keep a visible prior-owner note")
        controller.cancelButton.performClick(nil)
        guard case .prefKeybinding(.closeEditor) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "Cancel should discard the sheet candidate")
        }
        controller.doneButton.performClick(nil)
        guard case .prefKeybinding(.acceptEditor) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "Done should accept the whole candidate")
        }
    }

    await uiTest("recorder claims an assigned menu equivalent before dispatch") {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                              styleMask: .titled, backing: .buffered, defer: false)
        let recorder = KeybindingRecorderButton(title: "Press Shortcut...")
        recorder.actionID = "tab.new"
        window.contentView = recorder
        window.makeFirstResponder(recorder)
        var captured: KeyChord?
        var canceled = false
        recorder.onCapture = { _, chord in captured = chord }
        recorder.onCancel = { canceled = true }
        let event = try uiRequire(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17
        ), "expected a synthetic key event")

        let handled = recorder.performKeyEquivalent(with: event)

        try uiExpect(handled, "the recorder should claim the equivalent")
        try uiExpect(captured?.compact == "cmd+t", "the recorder should emit the canonical chord")

        let escape = try uiRequire(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 0x35
        ), "expected a synthetic Escape event")
        try uiExpect(recorder.performKeyEquivalent(with: escape),
                     "the recorder should claim Escape while active")
        try uiExpect(canceled, "Escape should cancel recording through its own callback")
    }

    await uiTest("a warning row expands only for its own warning") {
        // Intent: each of the three warning rows collapses and expands on its own
        //   warning, and on no other row's.
        // Why it exists: the rows used to be addressed by literal grid index, so
        //   inserting or reordering a form row silently pointed a warning at the
        //   wrong row. Finding each row from its own label is what rules that out.
        // Scenario: spec-first; the configured font family is not installed, but
        //   both themes resolve.
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        let grid = try settingsGrid(in: fx.panel)
        let theme = try row(in: grid, containing: fx.panel.themeWarningLabel)
        let fontFamily = try row(in: grid, containing: fx.panel.fontFamilyWarningLabel)
        let remoteTheme = try row(in: grid, containing: fx.panel.remoteThemeWarningLabel)

        try uiExpect(theme.isHidden && fontFamily.isHidden && remoteTheme.isHidden,
                     "a hidden warning must not reserve vertical space")

        fx.panel.apply(makeProjection(warning: "Font \"Fira Codee\" is not installed."))

        try uiExpect(!fontFamily.isHidden, "the projected font warning should expand its own row")
        try uiExpect(theme.isHidden, "the theme row should stay collapsed")
        try uiExpect(remoteTheme.isHidden, "the remote theme row should stay collapsed")
    }

    await uiTest("only the rows that start a section carry top padding") {
        // Intent: section spacing belongs to the row that starts the section, and
        //   to no other row.
        // Why it exists: the padding used to be applied to four literal row
        //   indices, so inserting a row above them moved the section breaks onto
        //   unrelated rows without failing anything.
        // Scenario: spec-first.
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        let grid = try settingsGrid(in: fx.panel)
        let sectionStarts: Set<String> = ["Clear Alerts", "Remote Theme", "Config file", "Tailnet"]

        for label in rowLabels(in: grid) {
            let padded = try row(in: grid, containing: label).topPadding > 0
            let shouldPad = sectionStarts.contains(label.stringValue)
            try uiExpect(padded == shouldPad,
                         "row '\(label.stringValue)': expected top padding \(shouldPad), got \(padded)")
        }
        for view: NSView in [fx.panel.themeWarningLabel, fx.panel.fontFamilyWarningLabel,
                             fx.panel.remoteThemeWarningLabel, fx.panel.copyOnSelectCheckbox] {
            try uiExpect(try row(in: grid, containing: view).topPadding == 0,
                         "a row inside a section should carry no top padding")
        }
    }

    await uiTest("theme names are picker-only") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(themeText: "Monokai", remoteThemeText: "Purplepeter"))
        let fields = descendantTextFields(in: fx.panel.contentView)

        let theme = try uiRequire(fields.first { $0.stringValue == "Monokai" }, "expected theme field")
        let remote = try uiRequire(fields.first { $0.stringValue == "Purplepeter" }, "expected remote theme field")
        try uiExpect(!theme.isEditable, "theme changes should go through the picker")
        try uiExpect(!remote.isEditable, "remote theme changes should go through the picker")
    }

    await uiTest("theme fields fill the same remaining row width") {
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

    await uiTest("the label column reserves no width beyond its widest label") {
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
        let grid = try settingsGrid(in: fx.panel)
        let labels = rowLabels(in: grid)
        try uiExpect(labels.count >= 5, "expected the form's row labels, found \(labels.count)")

        let widest = try uiRequire(labels.min { $0.frame.minX < $1.frame.minX }, "expected a widest label")
        let deadSpace = widest.frame.minX - grid.bounds.minX

        try uiExpect(deadSpace < 4,
                     "the widest label '\(widest.stringValue)' should start at the form's leading edge, "
                     + "but \(deadSpace)pt of the label column is unused")
    }

    await uiTest("the settings window is exactly as wide as its content needs") {
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

    await uiTest("the input controls get the full width the labels do not need") {
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

    await uiTest("theme fallback warnings show inline and collapse when resolved") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        let grid = try settingsGrid(in: fx.panel)
        let localRow = try row(in: grid, containing: fx.panel.themeWarningLabel)
        let remoteRow = try row(in: grid, containing: fx.panel.remoteThemeWarningLabel)
        let localWarning = "Theme \"Missing Local\" is not available -- using the built-in dark theme."
        let remoteWarning = "Theme \"Missing Remote\" is not available -- using the built-in dark theme."

        fx.panel.apply(makeProjection(themeWarning: localWarning, remoteThemeWarning: remoteWarning))
        let visibleTitles = descendantControlTitles(in: fx.panel.contentView)
        try uiExpect(visibleTitles.contains(localWarning), "expected local fallback warning")
        try uiExpect(visibleTitles.contains(remoteWarning), "expected remote fallback warning")
        try uiExpect(!localRow.isHidden, "local warning row should expand")
        try uiExpect(!remoteRow.isHidden, "remote warning row should expand")

        fx.panel.apply(makeProjection())
        try uiExpect(localRow.isHidden, "resolved local warning row should collapse")
        try uiExpect(remoteRow.isHidden, "resolved remote warning row should collapse")
    }

    await uiTest("the font-family combo box lists the projected choices in order") {
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

    await uiTest("picking a family from the list applies that family immediately") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(choices: [systemMonospaceFontChoiceTitle, "Menlo"]))

        fx.panel.fontFamilyCombo.selectItem(at: 1)

        try uiExpect(fx.runtime.sentMessages.count == 2, "expected a draft followed by a save")
        guard case .prefSet(.fontFamily(let family)) = fx.runtime.sentMessages[0] else {
            throw UITestFailure(message: "expected .prefSet(.fontFamily), got \(fx.runtime.sentMessages[0])")
        }
        try uiExpect(family == "Menlo", "expected the picked family, got \(family ?? "nil")")
        guard case .prefSave = fx.runtime.sentMessages[1] else {
            throw UITestFailure(message: "expected prefSave, got \(fx.runtime.sentMessages[1])")
        }
    }

    await uiTest("picking the system-monospace entry applies the sentinel, not a font name") {
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

        guard case .prefSet(.fontFamily(let family)) = fx.runtime.sentMessages.first else {
            throw UITestFailure(message: "expected .prefSet(.fontFamily), got \(String(describing: fx.runtime.sentMessages.first))")
        }
        try uiExpect(family == systemMonospaceFontChoiceTitle,
                     "expected the sentinel title, got \(family ?? "nil")")
    }

    await uiTest("typing a family drafts the typed text") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(choices: [systemMonospaceFontChoiceTitle, "Menlo"]))

        fx.panel.fontFamilyCombo.stringValue = "Fira Code"
        fx.panel.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: fx.panel.fontFamilyCombo)
        )

        guard case .prefSet(.fontFamily(let family)) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "expected .prefSet(.fontFamily), got \(String(describing: fx.runtime.sentMessages.last))")
        }
        try uiExpect(family == "Fira Code", "expected the typed text, got \(family ?? "nil")")
    }

    await uiTest("clearing the field drafts no family at all") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(text: "Menlo", choices: [systemMonospaceFontChoiceTitle, "Menlo"]))

        fx.panel.fontFamilyCombo.stringValue = ""
        fx.panel.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: fx.panel.fontFamilyCombo)
        )

        guard case .prefSet(.fontFamily(let family)) = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "expected .prefSet(.fontFamily), got \(String(describing: fx.runtime.sentMessages.last))")
        }
        try uiExpect(family == nil, "an empty field means no family, got \(family ?? "nil")")
    }

    await uiTest("ending a text edit applies the drafted value") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }

        fx.panel.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: fx.panel.fontFamilyCombo)
        )
        try await pumpMainQueue(untilTrue: { !fx.runtime.sentMessages.isEmpty })

        guard case .prefSave = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "expected prefSave, got \(String(describing: fx.runtime.sentMessages.last))")
        }
    }

    await uiTest("ending a text edit during reconcile waits for the send frame") {
        // Intent: AppKit field-editor teardown cannot dispatch while a projection
        //   apply still holds a reconciler cache inout.
        // Why it exists: the 2026-08-21 Key Bindings settings crash hid the active
        //   General field and synchronously re-entered reconcile from this delegate.
        // Scenario: a reconcile frame causes editing to end while switching sections.
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }

        var dispatchedInsideFrame = false
        fx.runtime.outbox.withFrame {
            fx.panel.controlTextDidEndEditing(
                Notification(name: NSControl.textDidEndEditingNotification,
                             object: fx.panel.fontFamilyCombo)
            )
            dispatchedInsideFrame = !fx.runtime.sentMessages.isEmpty
        }

        try uiExpect(!dispatchedInsideFrame,
                     "the save must wait until the reconcile frame exits")
        guard case .prefSave = fx.runtime.sentMessages.last else {
            throw UITestFailure(message: "expected deferred prefSave, got \(String(describing: fx.runtime.sentMessages.last))")
        }
    }

    await uiTest("the font-size stepper updates the field and applies the size") {
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
        guard case .prefSet(.fontSize(let text)) = fx.runtime.sentMessages[0] else {
            throw UITestFailure(message: "expected .prefSet(.fontSize), got \(fx.runtime.sentMessages[0])")
        }
        try uiExpect(text == "14", "expected stepped size 14, got \(text ?? "nil")")
        guard case .prefSave = fx.runtime.sentMessages[1] else {
            throw UITestFailure(message: "expected prefSave, got \(fx.runtime.sentMessages[1])")
        }
    }

    await uiTest("a projected warning shows inline and lays out") {
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

    await uiTest("a projection without a warning hides the label") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(text: "Fira Codee", warning: "Font \"Fira Codee\" is not installed."))

        fx.panel.apply(makeProjection(text: "Fira Code"))
        fx.panel.contentView?.layoutSubtreeIfNeeded()

        try uiExpect(fx.panel.fontFamilyWarningLabel.isHidden, "warning label should be hidden")
        try uiExpect(fx.panel.contentView?.hasAmbiguousLayout == false,
                     "hiding the warning must not leave the panel ambiguously laid out")
    }

    await uiTest("the copy-on-select checkbox shows and immediately applies the projected value") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }

        fx.panel.apply(makeProjection(copyOnSelect: true))
        try uiExpect(fx.panel.copyOnSelectCheckbox.state == .on, "an armed option should tick the box")

        fx.panel.copyOnSelectCheckbox.performClick(nil)

        try uiExpect(fx.runtime.sentMessages.count == 2, "expected a draft followed by a save")
        guard case .prefSet(.copyOnSelect(let enabled)) = fx.runtime.sentMessages[0] else {
            throw UITestFailure(message: "expected .prefSet(.copyOnSelect), got \(fx.runtime.sentMessages[0])")
        }
        try uiExpect(enabled == false, "unticking should draft the option off")
        guard case .prefSave = fx.runtime.sentMessages[1] else {
            throw UITestFailure(message: "expected prefSave, got \(fx.runtime.sentMessages[1])")
        }

        fx.panel.apply(makeProjection(copyOnSelect: false))
        try uiExpect(fx.panel.copyOnSelectCheckbox.state == .off, "a disarmed option should untick the box")
    }

    await uiTest("the tailnet section shows the projected base, endpoint, and status") {
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }

        fx.panel.apply(makeProjection(
            tailnetConfiguredText: "100.64.0.1:7000",
            tailnetEndpointText: "100.64.0.1:7001",
            tailnetStatusText: "Listening"
        ))
        let titles = descendantControlTitles(in: fx.panel.contentView)

        try uiExpect(titles.contains("Tailnet"), "the section should name itself")
        try uiExpect(titles.contains("100.64.0.1:7000"), "expected the configured base")
        try uiExpect(titles.contains("100.64.0.1:7001"), "expected this instance's derived endpoint")
        try uiExpect(titles.contains("Listening"), "expected the live listener status")
    }

    await uiTest("the tailnet section is read-only and says when an edit takes effect") {
        // Intent: nothing in the tailnet section accepts an edit, and the panel
        //   tells the user that a config change reaches the listener at the next
        //   launch.
        // Why it exists: the listener is launch-frozen, so an editable-looking
        //   field would promise a rebind the app never performs.
        // Scenario: spec-first; the user opens Settings to check which endpoint
        //   this instance answers on.
        let fx = makePreferencesFixture()
        defer { fx.panel.close() }
        fx.panel.apply(makeProjection(
            tailnetConfiguredText: "100.64.0.1:7000",
            tailnetEndpointText: "100.64.0.1:7001",
            tailnetStatusText: "Waiting -- no local interface holds 100.64.0.1"
        ))
        let fields = descendantTextFields(in: fx.panel.contentView)

        for text in ["100.64.0.1:7000", "100.64.0.1:7001",
                     "Waiting -- no local interface holds 100.64.0.1"] {
            let field = try uiRequire(fields.first { $0.stringValue == text }, "expected field \(text)")
            try uiExpect(!field.isEditable, "the tailnet section should not accept edits: \(text)")
        }
        let titles = descendantControlTitles(in: fx.panel.contentView)
        try uiExpect(titles.contains { $0.contains("next launch") },
                     "the section should say a config change applies at the next launch")
    }

}

// MARK: - Fixture

private struct PreferencesFixture {
    let runtime: RecordingAppRuntime
    let panel: PreferencesPanel
}

private func makePreferencesFixture() -> PreferencesFixture {
    let runtime = makeUITestRuntime()
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
    selectedAlertClearMode: AlertClearMode = .focus,
    optionAsAlt: OptionAsAlt? = nil,
    copyOnSelect: Bool = true,
    tailnetConfiguredText: String = "Not configured",
    tailnetEndpointText: String = "None",
    tailnetStatusText: String = "Disabled -- no tailnet endpoint is configured",
    section: PreferencesSection = .general,
    keybindingGroups: [KeybindingSettingsGroup] = [],
    keybindingEditor: KeybindingEditorProjection? = nil,
    isResetAllKeybindingsConfirmationPresented: Bool = false
) -> PreferencesPanelProjection {
    PreferencesPanelProjection(
        section: section,
        keybindingSearchText: "",
        keybindingGroups: keybindingGroups,
        keybindingDiagnosticText: nil,
        keybindingEditor: keybindingEditor,
        isResetAllKeybindingsConfirmationPresented: isResetAllKeybindingsConfirmationPresented,
        selectedAlertClearMode: selectedAlertClearMode,
        remoteThemeText: remoteThemeText,
        themeText: themeText,
        fontSizeText: fontSizeText,
        fontFamilyText: text,
        copyOnSelect: copyOnSelect,
        optionAsAlt: optionAsAlt,
        fontFamilyChoices: choices,
        fontFamilyWarning: warning,
        themeWarning: themeWarning,
        remoteThemeWarning: remoteThemeWarning,
        tailnetConfiguredText: tailnetConfiguredText,
        tailnetEndpointText: tailnetEndpointText,
        tailnetStatusText: tailnetStatusText
    )
}

private func descendantControlTitles(in view: NSView?) -> [String] {
    guard let view else { return [] }
    let ownTitle: [String]
    if let button = view as? NSButton {
        ownTitle = [button.title]
    } else if let segmentedControl = view as? NSSegmentedControl {
        ownTitle = (0..<segmentedControl.segmentCount).compactMap {
            segmentedControl.label(forSegment: $0)
        }
    } else if let field = view as? NSTextField, !field.isEditable {
        ownTitle = [field.stringValue]
    } else {
        ownTitle = []
    }
    return ownTitle + view.subviews.flatMap { descendantControlTitles(in: $0) }
}

private func descendantButtons(in view: NSView?) -> [NSButton] {
    guard let view else { return [] }
    let ownButton = (view as? NSButton).map { [$0] } ?? []
    return ownButton + view.subviews.flatMap { descendantButtons(in: $0) }
}

private func settingsGrid(in panel: PreferencesPanel) throws -> NSGridView {
    try uiRequire(
        descendantViews(in: panel.contentView).compactMap({ $0 as? NSGridView }).first,
        "expected settings grid"
    )
}

private func descendantViews(in view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { descendantViews(in: $0) }
}

/// Find a form row from a view it holds, never from a row number, so the
/// assertion follows the row when the form is reordered.
private func row(in grid: NSGridView, containing view: NSView) throws -> NSGridRow {
    try uiRequire(grid.cell(for: view)?.row, "expected a grid row holding \(view)")
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
