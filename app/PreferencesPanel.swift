// Preferences panel: a floating utility window for editing DanTerm-specific settings.
// Changes are staged in a draft and committed to disk only when the user clicks Save.
// Each dirty field shows its previous committed value with a Reset button.
import Cocoa

class PreferencesPanel: NSPanel, NSTextFieldDelegate, NSWindowDelegate {
    weak var runtime: AppRuntime?

    // Ghostty settings
    private let ghosttyThemeField = NSTextField()
    private let ghosttyBrowseButton = NSButton()
    private let fontSizeField = NSTextField()

    // DanTerm settings
    private let alertClearModePopup = NSPopUpButton()
    private let remoteThemeField = NSTextField()
    private let browseButton = NSButton()

    // Dirty indicators (hidden when clean)
    private let ghosttyThemeDirtyRow = NSStackView()
    private let ghosttyThemePrevLabel = NSTextField(labelWithString: "")
    private let ghosttyThemeResetButton = NSButton()
    private let fontSizeDirtyRow = NSStackView()
    private let fontSizePrevLabel = NSTextField(labelWithString: "")
    private let fontSizeResetButton = NSButton()
    private let alertClearModeDirtyRow = NSStackView()
    private let alertClearModePrevLabel = NSTextField(labelWithString: "")
    private let alertClearModeResetButton = NSButton()
    private let remoteThemeDirtyRow = NSStackView()
    private let remoteThemePrevLabel = NSTextField(labelWithString: "")
    private let remoteThemeResetButton = NSButton()

    private let saveButton = NSButton()


    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 10),  // height is auto-sized
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "Preferences"
        isReleasedWhenClosed = false
        level = .normal  // don't float above modal dialogs
        isExcludedFromWindowsMenu = true  // keep out of the Window menu's auto window list
        delegate = self
        buildUI()
        center()
    }

    // MARK: - Layout

    private func buildUI() {
        guard let contentView = contentView else { return }

        // -- Form grid --
        let grid = NSGridView(views: [
            // Ghostty settings
            formRow("Theme", makeHStack([ghosttyThemeField, ghosttyBrowseButton])),
            dirtyRow(ghosttyThemeDirtyRow, ghosttyThemePrevLabel, ghosttyThemeResetButton,
                     action: #selector(resetTheme(_:))),
            formRow("Font Size", fontSizeField),
            dirtyRow(fontSizeDirtyRow, fontSizePrevLabel, fontSizeResetButton,
                     action: #selector(resetFontSize(_:))),
            // DanTerm settings
            formRow("Alert Clear Mode", alertClearModePopup),
            dirtyRow(alertClearModeDirtyRow, alertClearModePrevLabel, alertClearModeResetButton,
                     action: #selector(resetAlertClearMode(_:))),
            formRow("Remote Theme", makeHStack([remoteThemeField, browseButton])),
            dirtyRow(remoteThemeDirtyRow, remoteThemePrevLabel, remoteThemeResetButton,
                     action: #selector(resetRemoteTheme(_:))),
            formRow("Config file", makeHStack([
                makeButton("Open in editor", action: #selector(openConfigFile(_:))),
                makeButton("Reload", action: #selector(reloadConfig(_:))),
            ])),
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 130  // fixed label column width
        grid.column(at: 1).xPlacement = .fill
        // Vertically center labels with their adjacent controls. NSGridView rows
        // default to top alignment, which leaves labels sticking to the top of
        // rows containing taller controls (text fields, popups).
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 4
        // Add extra spacing before DanTerm section (Alert Clear Mode row).
        grid.row(at: 4).topPadding = 12
        // Add extra spacing before the "Config file" row.
        grid.row(at: 8).topPadding = 8

        // Configure Ghostty controls.
        ghosttyThemeField.delegate = self
        ghosttyThemeField.placeholderString = "Ghostty default"
        ghosttyThemeField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        ghosttyBrowseButton.title = "Browse…"
        ghosttyBrowseButton.bezelStyle = .push
        ghosttyBrowseButton.target = self
        ghosttyBrowseButton.action = #selector(browseGhosttyTheme(_:))
        ghosttyBrowseButton.setContentHuggingPriority(.required, for: .horizontal)
        ghosttyBrowseButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        fontSizeField.delegate = self
        fontSizeField.placeholderString = "Ghostty default"
        let fontSizeWidth = NSLayoutConstraint(item: fontSizeField, attribute: .width, relatedBy: .equal,
                                                toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 80)
        fontSizeWidth.priority = .defaultHigh
        fontSizeField.addConstraint(fontSizeWidth)

        // Configure DanTerm controls.
        alertClearModePopup.removeAllItems()
        alertClearModePopup.addItems(withTitles: ["Focus", "Manual"])
        alertClearModePopup.target = self
        alertClearModePopup.action = #selector(alertClearModeChanged(_:))

        remoteThemeField.delegate = self
        remoteThemeField.placeholderString = DanTermConfig.default.remoteTheme
        remoteThemeField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        browseButton.title = "Browse…"
        browseButton.bezelStyle = .push
        browseButton.target = self
        browseButton.action = #selector(browseRemoteTheme(_:))
        browseButton.setContentHuggingPriority(.required, for: .horizontal)
        browseButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // -- Separator --
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // -- Footer buttons --
        saveButton.title = "Save"
        saveButton.bezelStyle = .push
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(savePreferences(_:))
        saveButton.isEnabled = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPreferences(_:)))
        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1b}"

        let footerStack = NSStackView(views: [cancelButton, saveButton])
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.orientation = .horizontal
        footerStack.spacing = 8

        // -- Assemble --
        contentView.addSubview(grid)
        contentView.addSubview(separator)
        contentView.addSubview(footerStack)

        let padding: CGFloat = 20
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: padding),
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: padding),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),

            separator.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            footerStack.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            footerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -padding),
            footerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -padding),
        ])
    }

    /// Build a [label, control] row for the grid.
    private func formRow(_ labelText: String, _ control: NSView) -> [NSView] {
        [makeLabel(labelText), control]
    }

    /// Build a dirty-indicator row: empty label column, [prevLabel, resetButton] in control column.
    /// The row's container is hidden by default; apply() shows it when dirty.
    private func dirtyRow(
        _ container: NSStackView,
        _ prevLabel: NSTextField,
        _ resetButton: NSButton,
        action: Selector
    ) -> [NSView] {
        prevLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        prevLabel.textColor = .secondaryLabelColor
        prevLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        resetButton.title = "Reset"
        resetButton.bezelStyle = .inline
        resetButton.controlSize = .small
        resetButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        resetButton.target = self
        resetButton.action = action
        resetButton.setContentHuggingPriority(.required, for: .horizontal)

        container.orientation = .horizontal
        container.spacing = 4
        container.addArrangedSubview(prevLabel)
        container.addArrangedSubview(resetButton)
        container.isHidden = true
        return [NSGridCell.emptyContentView, container]
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

        if remoteThemeField.stringValue != projection.remoteThemeText {
            remoteThemeField.stringValue = projection.remoteThemeText
        }
        if ghosttyThemeField.stringValue != projection.ghosttyThemeText {
            ghosttyThemeField.stringValue = projection.ghosttyThemeText
        }
        if fontSizeField.stringValue != projection.fontSizeText {
            fontSizeField.stringValue = projection.fontSizeText
        }

        applyDirtyRow(ghosttyThemeDirtyRow, ghosttyThemePrevLabel, label: projection.ghosttyThemeDirtyLabel)
        applyDirtyRow(fontSizeDirtyRow, fontSizePrevLabel, label: projection.fontSizeDirtyLabel)
        applyDirtyRow(alertClearModeDirtyRow, alertClearModePrevLabel, label: projection.alertClearModeDirtyLabel)
        applyDirtyRow(remoteThemeDirtyRow, remoteThemePrevLabel, label: projection.remoteThemeDirtyLabel)

        if saveButton.isEnabled != projection.saveEnabled {
            saveButton.isEnabled = projection.saveEnabled
        }
    }

    /// Apply one dirty row while leaving unchanged labels alone.
    private func applyDirtyRow(_ row: NSStackView, _ labelField: NSTextField, label: String?) {
        let shouldHide = label == nil
        if row.isHidden != shouldHide {
            row.isHidden = shouldHide
        }
        if let label, labelField.stringValue != label {
            labelField.stringValue = label
        }
    }

    // MARK: - NSWindowDelegate

    // NSWindowDelegate: red-X / performClose. Translate the gesture to a model
    // intent; reconcile orders the panel out before AppKit performs its close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        runtime?.send(.preferencesClosed)
        return true
    }

    // MARK: - Actions

    @objc private func alertClearModeChanged(_ sender: NSPopUpButton) {
        let mode: AlertClearMode = sender.indexOfSelectedItem == 0 ? .focus : .manual
        runtime?.send(.prefSetAlertClearMode(mode))
    }

    // NSTextFieldDelegate: update draft as the user types for live dirty tracking.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === remoteThemeField {
            runtime?.send(.prefSetRemoteTheme(field.stringValue))
        } else if field === ghosttyThemeField {
            let text = field.stringValue
            runtime?.send(.prefSetTheme(text.isEmpty ? nil : text))
        } else if field === fontSizeField {
            let text = field.stringValue
            runtime?.send(.prefSetFontSize(text.isEmpty ? nil : text))
        }
    }

    @objc private func savePreferences(_ sender: Any?) {
        runtime?.send(.prefSave)
    }

    @objc private func cancelPreferences(_ sender: Any?) {
        runtime?.send(.preferencesClosed)
    }

    @objc private func resetAlertClearMode(_ sender: Any?) {
        runtime?.send(.prefResetAlertClearMode)
    }

    @objc private func resetRemoteTheme(_ sender: Any?) {
        runtime?.send(.prefResetRemoteTheme)
    }

    @objc private func resetTheme(_ sender: Any?) {
        runtime?.send(.prefResetTheme)
    }

    @objc private func resetFontSize(_ sender: Any?) {
        runtime?.send(.prefResetFontSize)
    }

    /// Present the theme picker sheet so the user can browse and select a Ghostty theme.
    @objc private func browseGhosttyTheme(_ sender: Any?) {
        let picker = RemoteThemePickerSheet()
        picker.currentThemeName = ghosttyThemeField.stringValue.isEmpty
            ? runtime?.model.committedGhosttyPrefs?.theme
            : ghosttyThemeField.stringValue
        picker.onSelect = { [weak self] themeName in
            self?.runtime?.send(.prefSetTheme(themeName))
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
            self?.runtime?.send(.prefSetRemoteTheme(themeName))
        }
        let sheetWindow = NSWindow(contentViewController: picker)
        sheetWindow.styleMask = [.titled]
        sheetWindow.isExcludedFromWindowsMenu = true  // host window for the picker; keep out of the Window menu
        beginSheet(sheetWindow) { _ in }
    }

    @objc private func openConfigFile(_ sender: Any?) {
        let path = DanTermConfigPaths.configFilePath()
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent().path
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: path) {
            let seed = "# DanTerm config — Ghostty keys + DanTerm-specific keys\n# https://github.com/danneu/danterm\n"
            fm.createFile(atPath: path, contents: seed.data(using: .utf8))
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func reloadConfig(_ sender: Any?) {
        runtime?.reloadAllConfig()
    }
}
