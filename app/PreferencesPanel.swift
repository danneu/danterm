// DanTerm's single-pane settings window and its native AppKit form controls.
import Cocoa
import DanTermProtocol

/// The width the settings form gives its input controls. This is the only width
/// the panel states: the label column measures itself from its widest label, and
/// the window sizes to the sum. Nothing here may assert a window width -- an
/// NSGridView hands every surplus point to column 0 and ignores content hugging,
/// so a window wider than its content pads the labels and starves the inputs.
let preferencesControlColumnWidth: CGFloat = 320

/// Owns the application-wide settings controls and commits each completed edit.
class PreferencesPanel: NSWindow, NSComboBoxDelegate, NSWindowDelegate {
    weak var runtime: AppRuntime?

    // Terminal appearance settings
    private let themeField = NSTextField()
    private let themeBrowseButton = NSButton()
    private let themeWarningLabel = NSTextField(labelWithString: "")
    private var themeWarningRow: NSGridRow?
    // The UI harness drives the paired controls to prove a step updates the
    // visible text and commits one settings change.
    let fontSizeField = NSTextField()
    let fontSizeStepper = NSStepper()
    // The UI harness reads these three to prove the projection reaches the
    // font-family controls and that gestures dispatch the right Msg.
    let fontFamilyCombo = NSComboBox()
    let fontFamilyWarningLabel = NSTextField(labelWithString: "")
    private var fontFamilyWarningRow: NSGridRow?

    // DanTerm settings
    private let alertClearModePopup = NSPopUpButton()
    let copyOnSelectCheckbox = NSButton()
    private let remoteThemeField = NSTextField()
    private let browseButton = NSButton()
    private let remoteThemeWarningLabel = NSTextField(labelWithString: "")
    private var remoteThemeWarningRow: NSGridRow?

    // Tailnet listener: read-only, because the listener is frozen at launch and an
    // editable field would promise a rebind the app never performs.
    private let tailnetConfiguredField = NSTextField()
    private let tailnetEndpointField = NSTextField()
    private let tailnetStatusField = NSTextField()
    private let tailnetNoteLabel = NSTextField(
        labelWithString: "Edit tailnet settings in the config file; they apply at the next launch."
    )

    init(runtime: AppRuntime) {
        self.runtime = runtime
        // A placeholder rect. The form's real size comes from its content below,
        // so no dimension is stated here.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "DanTerm Settings"
        isReleasedWhenClosed = false
        level = .normal  // don't float above modal dialogs
        isExcludedFromWindowsMenu = true  // keep out of the Window menu's auto window list
        delegate = self
        buildUI()
        if let contentView { setContentSize(contentView.fittingSize) }
        center()
    }

    // MARK: - Layout

    private func buildUI() {
        guard let contentView = contentView else { return }

        // -- Form grid --
        let themeControls = makeHStack([themeField, themeBrowseButton])
        let remoteThemeControls = makeHStack([remoteThemeField, browseButton])
        themeControls.distribution = .fill
        remoteThemeControls.distribution = .fill
        let grid = NSGridView(views: [
            formRow("Theme", themeControls),
            [NSGridCell.emptyContentView, themeWarningLabel],
            formRow("Font Family", fontFamilyCombo),
            [NSGridCell.emptyContentView, fontFamilyWarningLabel],
            formRow("Font Size", makeHStack([fontSizeField, fontSizeStepper])),
            formRow("Clear Alerts", alertClearModePopup),
            [NSGridCell.emptyContentView, copyOnSelectCheckbox],
            formRow("Remote Theme", remoteThemeControls),
            [NSGridCell.emptyContentView, remoteThemeWarningLabel],
            formRow("Config file", makeHStack([
                makeButton("Open Config File", action: #selector(openConfigFile(_:))),
                makeButton("Reload Config", action: #selector(reloadConfig(_:))),
            ])),
            // The tailnet section goes last so the row indices above it, which the
            // warning rows and the UI harness both address by number, stay put.
            formRow("Tailnet", tailnetConfiguredField),
            formRow("Endpoint", tailnetEndpointField),
            formRow("Listener", tailnetStatusField),
            [NSGridCell.emptyContentView, tailnetNoteLabel],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        // Vertically center labels with their adjacent controls. NSGridView rows
        // default to top alignment, which leaves labels sticking to the top of
        // rows containing taller controls (text fields, popups).
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.row(at: 5).topPadding = 8
        grid.row(at: 7).topPadding = 8
        grid.row(at: 9).topPadding = 4
        grid.row(at: 10).topPadding = 8
        themeWarningRow = grid.row(at: 1)
        themeWarningRow?.isHidden = true
        fontFamilyWarningRow = grid.row(at: 3)
        fontFamilyWarningRow?.isHidden = true
        remoteThemeWarningRow = grid.row(at: 8)
        remoteThemeWarningRow?.isHidden = true

        // State the control column's width on the cells themselves, so the grid
        // has no surplus to hand column 0. Every row is constrained, not one
        // chosen row, so reordering or removing a row cannot silently drop it.
        for row in 0..<grid.numberOfRows {
            guard let content = grid.cell(atColumnIndex: 1, rowIndex: row).contentView,
                  content !== NSGridCell.emptyContentView
            else { continue }
            content.widthAnchor.constraint(
                greaterThanOrEqualToConstant: preferencesControlColumnWidth
            ).isActive = true
        }

        // Configure terminal appearance controls.
        themeField.isEditable = false
        themeField.isSelectable = true
        themeField.placeholderString = DanTermConfig.default.resolvedDefaultTheme

        themeBrowseButton.title = "Browse…"
        themeBrowseButton.bezelStyle = .push
        themeBrowseButton.target = self
        themeBrowseButton.action = #selector(browseTheme(_:))
        themeBrowseButton.setContentHuggingPriority(.required, for: .horizontal)
        themeBrowseButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Editable so the user can type a PostScript alias or a family they are
        // about to install; `completes` makes the installed list searchable by
        // prefix instead of forcing a scroll through every family on the machine.
        fontFamilyCombo.delegate = self
        fontFamilyCombo.usesDataSource = false
        fontFamilyCombo.isEditable = true
        fontFamilyCombo.completes = true
        fontFamilyCombo.numberOfVisibleItems = 12

        configureWarningLabel(themeWarningLabel)
        configureWarningLabel(fontFamilyWarningLabel)
        configureWarningLabel(remoteThemeWarningLabel)
        // NSGridView gives a wrapping label no width to wrap against, so it would
        // otherwise stretch the panel to one long line. Wrap at the control
        // column so a warning never widens the form past the row it explains.
        for label in [themeWarningLabel, fontFamilyWarningLabel, remoteThemeWarningLabel] {
            label.preferredMaxLayoutWidth = preferencesControlColumnWidth
            label.isHidden = true
        }

        fontSizeField.delegate = self
        fontSizeField.placeholderString = configFontSizeText(DanTermConfig.default.resolvedFontSize)
        let fontSizeWidth = NSLayoutConstraint(item: fontSizeField, attribute: .width, relatedBy: .equal,
                                                toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 80)
        fontSizeWidth.priority = .defaultHigh
        fontSizeField.addConstraint(fontSizeWidth)

        fontSizeStepper.minValue = DanTermConfig.fontSizeRange.lowerBound
        fontSizeStepper.maxValue = DanTermConfig.fontSizeRange.upperBound
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeStepped(_:))

        // Configure DanTerm controls.
        alertClearModePopup.removeAllItems()
        alertClearModePopup.addItems(withTitles: ["On Focus", "Manually"])
        alertClearModePopup.target = self
        alertClearModePopup.action = #selector(alertClearModeChanged(_:))

        copyOnSelectCheckbox.setButtonType(.switch)
        copyOnSelectCheckbox.title = "Copy selection to clipboard"
        copyOnSelectCheckbox.target = self
        copyOnSelectCheckbox.action = #selector(copyOnSelectChanged(_:))

        remoteThemeField.isEditable = false
        remoteThemeField.isSelectable = true
        remoteThemeField.placeholderString = DanTermConfig.default.remoteTheme

        browseButton.title = "Browse…"
        browseButton.bezelStyle = .push
        browseButton.target = self
        browseButton.action = #selector(browseRemoteTheme(_:))
        browseButton.setContentHuggingPriority(.required, for: .horizontal)
        browseButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        for field in [tailnetConfiguredField, tailnetEndpointField, tailnetStatusField] {
            field.isEditable = false
            field.isSelectable = true
            field.isBezeled = false
            field.drawsBackground = false
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
            field.preferredMaxLayoutWidth = preferencesControlColumnWidth
        }
        tailnetNoteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tailnetNoteLabel.textColor = .secondaryLabelColor
        tailnetNoteLabel.lineBreakMode = .byWordWrapping
        tailnetNoteLabel.maximumNumberOfLines = 0
        tailnetNoteLabel.preferredMaxLayoutWidth = preferencesControlColumnWidth

        // -- Assemble --
        contentView.addSubview(grid)

        let padding: CGFloat = 20
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding),
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            grid.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -padding),
        ])
    }

    /// Build a [label, control] row for the grid.
    private func formRow(_ labelText: String, _ control: NSView) -> [NSView] {
        [makeLabel(labelText), control]
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func makeHStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 4
        return stack
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .push
        return button
    }

    // MARK: - Apply projection

    /// Apply the already-rendered preferences projection without recomputing model state.
    func apply(_ projection: PreferencesPanelProjection) {
        let alertIndex = projection.selectedAlertClearMode == .focus ? 0 : 1
        if alertClearModePopup.indexOfSelectedItem != alertIndex {
            alertClearModePopup.selectItem(at: alertIndex)
        }

        let copyOnSelectState: NSControl.StateValue = projection.copyOnSelect ? .on : .off
        if copyOnSelectCheckbox.state != copyOnSelectState {
            copyOnSelectCheckbox.state = copyOnSelectState
        }

        if remoteThemeField.stringValue != projection.remoteThemeText {
            remoteThemeField.stringValue = projection.remoteThemeText
        }
        if themeField.stringValue != projection.themeText {
            themeField.stringValue = projection.themeText
        }
        if fontSizeField.stringValue != projection.fontSizeText {
            fontSizeField.stringValue = projection.fontSizeText
        }
        fontSizeStepper.doubleValue = Double(projection.fontSizeText)
            .map(DanTermConfig.boundedFontSize) ?? DanTermConfig.default.resolvedFontSize
        if fontFamilyCombo.objectValues as? [String] != projection.fontFamilyChoices {
            fontFamilyCombo.removeAllItems()
            fontFamilyCombo.addItems(withObjectValues: projection.fontFamilyChoices)
        }
        if fontFamilyCombo.stringValue != projection.fontFamilyText {
            fontFamilyCombo.stringValue = projection.fontFamilyText
        }

        if tailnetConfiguredField.stringValue != projection.tailnetConfiguredText {
            tailnetConfiguredField.stringValue = projection.tailnetConfiguredText
        }
        if tailnetEndpointField.stringValue != projection.tailnetEndpointText {
            tailnetEndpointField.stringValue = projection.tailnetEndpointText
        }
        if tailnetStatusField.stringValue != projection.tailnetStatusText {
            tailnetStatusField.stringValue = projection.tailnetStatusText
        }

        applyWarning(projection.themeWarning, label: themeWarningLabel, row: themeWarningRow)
        applyWarning(
            projection.fontFamilyWarning,
            label: fontFamilyWarningLabel,
            row: fontFamilyWarningRow
        )
        applyWarning(
            projection.remoteThemeWarning,
            label: remoteThemeWarningLabel,
            row: remoteThemeWarningRow
        )
    }

    private func configureWarningLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .systemOrange
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
    }

    /// Show or hide the inline font warning. This is the whole feedback channel
    /// for a font that is configured but not installed: the failure is soft and
    /// already recovered, so it must never become a modal that re-fires every
    /// launch.
    private func applyWarning(_ warning: String?, label: NSTextField, row: NSGridRow?) {
        let shouldHide = warning == nil
        if label.isHidden != shouldHide {
            label.isHidden = shouldHide
        }
        if row?.isHidden != shouldHide {
            row?.isHidden = shouldHide
        }
        if let warning, label.stringValue != warning {
            label.stringValue = warning
        }
    }

    // MARK: - NSWindowDelegate

    // NSWindowDelegate: red-X / performClose. Translate the gesture to a model
    // intent; reconcile orders the panel out before AppKit performs its close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        runtime?.send(.prefSave)
        runtime?.send(.preferencesClosed)
        return true
    }

    // MARK: - Actions

    @objc private func alertClearModeChanged(_ sender: NSPopUpButton) {
        let mode: AlertClearMode = sender.indexOfSelectedItem == 0 ? .focus : .manual
        applyPreferenceChange(.alertClearMode(mode))
    }

    @objc private func copyOnSelectChanged(_ sender: NSButton) {
        applyPreferenceChange(.copyOnSelect(sender.state == .on))
    }

    // NSTextFieldDelegate: retain partial text in the model until editing ends.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === fontSizeField {
            let text = field.stringValue
            runtime?.send(.prefSet(.fontSize(text.isEmpty ? nil : text)))
        } else if field === fontFamilyCombo {
            let text = field.stringValue
            runtime?.send(.prefSet(.fontFamily(text.isEmpty ? nil : text)))
        }
    }

    // NSTextFieldDelegate: a completed text edit is one atomic config change.
    func controlTextDidEndEditing(_ obj: Notification) {
        runtime?.send(.prefSave)
    }

    // NSComboBoxDelegate: the user picked a family from the list. The selected
    // title goes into the draft verbatim, including the system-monospace entry --
    // the core normalizes that sentinel back to "no family", which is what keeps
    // this side free of special cases.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo === fontFamilyCombo,
              let title = combo.objectValueOfSelectedItem as? String
        else { return }
        applyPreferenceChange(.fontFamily(title))
    }

    @objc private func fontSizeStepped(_ sender: NSStepper) {
        let text = configFontSizeText(sender.doubleValue)
        fontSizeField.stringValue = text
        applyPreferenceChange(.fontSize(text))
    }

    /// Present the theme picker sheet so the user can browse DanTerm's catalog.
    @objc private func browseTheme(_ sender: Any?) {
        let picker = RemoteThemePickerSheet()
        picker.currentThemeName = themeField.stringValue.isEmpty
            ? runtime?.model.config.defaultTheme
            : themeField.stringValue
        picker.onSelect = { [weak self] themeName in
            self?.applyPreferenceChange(.theme(themeName))
        }
        let sheetWindow = NSWindow(contentViewController: picker)
        sheetWindow.styleMask = [.titled]
        sheetWindow.isExcludedFromWindowsMenu = true  // host window for the picker; keep out of the Window menu
        beginSheet(sheetWindow) { _ in }
    }

    /// Present the theme picker sheet so the user can browse and select a remote theme.
    @objc private func browseRemoteTheme(_ sender: Any?) {
        let picker = RemoteThemePickerSheet()
        picker.currentThemeName = remoteThemeField.stringValue.isEmpty
            ? runtime?.model.config.remoteTheme
            : remoteThemeField.stringValue
        picker.onSelect = { [weak self] themeName in
            self?.applyPreferenceChange(.remoteTheme(themeName))
        }
        let sheetWindow = NSWindow(contentViewController: picker)
        sheetWindow.styleMask = [.titled]
        sheetWindow.isExcludedFromWindowsMenu = true  // host window for the picker; keep out of the Window menu
        beginSheet(sheetWindow) { _ in }
    }

    @objc private func openConfigFile(_ sender: Any?) {
        runtime?.send(.prefSave)
        runtime?.openDanTermConfig()
    }

    @objc private func reloadConfig(_ sender: Any?) {
        runtime?.send(.prefSave)
        runtime?.reloadDanTermConfig()
    }

    private func applyPreferenceChange(_ edit: PreferenceEdit) {
        runtime?.send(.prefSet(edit))
        runtime?.send(.prefSave)
    }
}
