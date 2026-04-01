// Preferences panel: a floating utility window for editing DanTerm-specific settings.
// Changes are staged in a draft and committed to disk only when the user clicks Save.
// Each dirty field shows its previous committed value with a Reset button.
import Cocoa

class PreferencesPanel: NSPanel, NSTextFieldDelegate, NSWindowDelegate {
    weak var runtime: AppRuntime?

    private let alertClearModePopup = NSPopUpButton()
    private let remoteThemeField = NSTextField()
    private let browseButton = NSButton()

    // Dirty indicators (hidden when clean)
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
        delegate = self
        buildUI()
        center()
    }

    // MARK: - Layout

    private func buildUI() {
        guard let contentView = contentView else { return }

        // -- Form grid --
        let grid = NSGridView(views: [
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
        grid.rowSpacing = 4
        // Add extra spacing before the "Config file" row.
        grid.row(at: 4).topPadding = 8

        // Configure controls.
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
    /// The row's container is hidden by default; sync() shows it when dirty.
    private func dirtyRow(
        _ container: NSStackView,
        _ prevLabel: NSTextField,
        _ resetButton: NSButton,
        action: Selector
    ) -> [NSView] {
        prevLabel.font = .systemFont(ofSize: 11)
        prevLabel.textColor = .secondaryLabelColor
        prevLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        resetButton.title = "Reset"
        resetButton.bezelStyle = .inline
        resetButton.controlSize = .small
        resetButton.font = .systemFont(ofSize: 10)
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

    // MARK: - Sync from model

    /// Update controls and dirty indicators from committed config and draft state.
    func sync(committed: DanTermConfig, draft: PreferencesDraft?) {
        guard let draft = draft else {
            // No draft — show committed values, hide dirty indicators.
            switch committed.alertClearMode {
            case .focus: alertClearModePopup.selectItem(at: 0)
            case .manual: alertClearModePopup.selectItem(at: 1)
            }
            remoteThemeField.stringValue = committed.remoteTheme
            alertClearModeDirtyRow.isHidden = true
            remoteThemeDirtyRow.isHidden = true
            saveButton.isEnabled = false
            return
        }

        // Set control values from draft.
        switch draft.alertClearMode {
        case .focus: alertClearModePopup.selectItem(at: 0)
        case .manual: alertClearModePopup.selectItem(at: 1)
        }
        remoteThemeField.stringValue = draft.remoteTheme

        // Compute per-field dirtiness.
        let alertDirty = draft.alertClearMode != committed.alertClearMode
        let themeDirty = resolveRemoteTheme(draft.remoteTheme) != committed.remoteTheme

        alertClearModeDirtyRow.isHidden = !alertDirty
        if alertDirty {
            let displayValue = committed.alertClearMode == .focus ? "Focus" : "Manual"
            alertClearModePrevLabel.stringValue = "Prev: \(displayValue)"
        }

        remoteThemeDirtyRow.isHidden = !themeDirty
        if themeDirty {
            remoteThemePrevLabel.stringValue = "Prev: \(committed.remoteTheme)"
        }

        saveButton.isEnabled = alertDirty || themeDirty
    }

    // MARK: - NSWindowDelegate

    // NSWindowDelegate: clean up draft state when the panel closes.
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
        guard let field = obj.object as? NSTextField, field === remoteThemeField else { return }
        runtime?.send(.prefSetRemoteTheme(field.stringValue))
    }

    @objc private func savePreferences(_ sender: Any?) {
        runtime?.send(.prefSave)
    }

    @objc private func cancelPreferences(_ sender: Any?) {
        runtime?.send(.preferencesClosed)
        close()
    }

    @objc private func resetAlertClearMode(_ sender: Any?) {
        runtime?.send(.prefResetAlertClearMode)
    }

    @objc private func resetRemoteTheme(_ sender: Any?) {
        runtime?.send(.prefResetRemoteTheme)
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
        beginSheet(sheetWindow) { _ in }
    }

    @objc private func openConfigFile(_ sender: Any?) {
        let path = DanTermConfigParser.configFilePath()
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
