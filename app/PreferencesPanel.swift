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
    private let alertClearModePrevLabel = NSTextField(labelWithString: "")
    private let alertClearModeResetButton = NSButton()
    private let remoteThemePrevLabel = NSTextField(labelWithString: "")
    private let remoteThemeResetButton = NSButton()

    private let saveButton = NSButton()

    /// Set during sync(); used by windowShouldClose to block dirty closes.
    private var isDirty = false

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "Preferences"
        isReleasedWhenClosed = false
        delegate = self
        center()
        buildUI()
    }

    // MARK: - Layout

    private func buildUI() {
        guard let contentView = contentView else { return }
        contentView.wantsLayer = true

        let padding: CGFloat = 20
        let rowHeight: CGFloat = 24
        let dirtyRowHeight: CGFloat = 18
        let labelWidth: CGFloat = 120
        let controlX = padding + labelWidth + 8
        let controlWidth = contentView.bounds.width - controlX - padding
        var y = contentView.bounds.height - padding - rowHeight

        // -- Alert Clear Mode --
        let alertLabel = makeLabel("Alert Clear Mode")
        alertLabel.frame = NSRect(x: padding, y: y, width: labelWidth, height: rowHeight)
        contentView.addSubview(alertLabel)

        alertClearModePopup.removeAllItems()
        alertClearModePopup.addItems(withTitles: ["Focus", "Manual"])
        alertClearModePopup.frame = NSRect(x: controlX, y: y, width: controlWidth, height: rowHeight)
        alertClearModePopup.target = self
        alertClearModePopup.action = #selector(alertClearModeChanged(_:))
        contentView.addSubview(alertClearModePopup)

        y -= dirtyRowHeight + 2

        // Dirty indicator for alert clear mode
        configureDirtyRow(
            prevLabel: alertClearModePrevLabel,
            resetButton: alertClearModeResetButton,
            action: #selector(resetAlertClearMode(_:)),
            y: y, controlX: controlX, controlWidth: controlWidth, height: dirtyRowHeight,
            in: contentView
        )

        y -= rowHeight + 8

        // -- Remote Theme --
        let themeLabel = makeLabel("Remote Theme")
        themeLabel.frame = NSRect(x: padding, y: y, width: labelWidth, height: rowHeight)
        contentView.addSubview(themeLabel)

        let browseWidth: CGFloat = 75
        let fieldWidth = controlWidth - browseWidth - 4
        remoteThemeField.frame = NSRect(x: controlX, y: y, width: fieldWidth, height: rowHeight)
        remoteThemeField.delegate = self
        remoteThemeField.placeholderString = DanTermConfig.default.remoteTheme
        contentView.addSubview(remoteThemeField)

        browseButton.title = "Browse…"
        browseButton.bezelStyle = .push
        browseButton.frame = NSRect(x: controlX + fieldWidth + 4, y: y, width: browseWidth, height: rowHeight)
        browseButton.target = self
        browseButton.action = #selector(browseRemoteTheme(_:))
        contentView.addSubview(browseButton)

        y -= dirtyRowHeight + 2

        // Dirty indicator for remote theme
        configureDirtyRow(
            prevLabel: remoteThemePrevLabel,
            resetButton: remoteThemeResetButton,
            action: #selector(resetRemoteTheme(_:)),
            y: y, controlX: controlX, controlWidth: controlWidth, height: dirtyRowHeight,
            in: contentView
        )

        y -= rowHeight + 8

        // -- Config file --
        let configLabel = makeLabel("Config file")
        configLabel.frame = NSRect(x: padding, y: y, width: labelWidth, height: rowHeight)
        contentView.addSubview(configLabel)

        let openButton = NSButton(title: "Open in editor", target: self, action: #selector(openConfigFile(_:)))
        openButton.bezelStyle = .push
        openButton.frame = NSRect(x: controlX, y: y, width: 110, height: rowHeight)
        contentView.addSubview(openButton)

        let reloadButton = NSButton(title: "Reload", target: self, action: #selector(reloadConfig(_:)))
        reloadButton.bezelStyle = .push
        reloadButton.frame = NSRect(x: controlX + 110 + 4, y: y, width: 70, height: rowHeight)
        contentView.addSubview(reloadButton)

        y -= rowHeight + 12

        // -- Separator --
        let separator = NSBox()
        separator.boxType = .separator
        separator.frame = NSRect(x: 0, y: y, width: contentView.bounds.width, height: 1)
        contentView.addSubview(separator)

        let buttonHeight: CGFloat = 24
        y -= buttonHeight + 8
        let rightEdge = contentView.bounds.width - padding

        // Footer: action buttons right-aligned (Cancel, Save)
        saveButton.title = "Save"
        saveButton.bezelStyle = .push
        saveButton.keyEquivalent = "\r"  // Return key — makes this the primary (blue) button
        saveButton.frame = NSRect(x: rightEdge - 80, y: y, width: 80, height: buttonHeight)
        saveButton.target = self
        saveButton.action = #selector(savePreferences(_:))
        saveButton.isEnabled = false
        contentView.addSubview(saveButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPreferences(_:)))
        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1b}"  // Escape key
        cancelButton.frame = NSRect(x: rightEdge - 80 - 8 - 80, y: y, width: 80, height: buttonHeight)
        contentView.addSubview(cancelButton)
    }

    /// Configure a dirty-indicator row: "Prev: {value}" label + "Reset" button.
    private func configureDirtyRow(
        prevLabel: NSTextField,
        resetButton: NSButton,
        action: Selector,
        y: CGFloat, controlX: CGFloat, controlWidth: CGFloat, height: CGFloat,
        in view: NSView
    ) {
        let resetWidth: CGFloat = 50
        prevLabel.font = .systemFont(ofSize: 11)
        prevLabel.textColor = .secondaryLabelColor
        prevLabel.alignment = .left
        prevLabel.frame = NSRect(x: controlX, y: y, width: controlWidth - resetWidth - 4, height: height)
        prevLabel.isHidden = true
        view.addSubview(prevLabel)

        resetButton.title = "Reset"
        resetButton.bezelStyle = .inline
        resetButton.controlSize = .small
        resetButton.font = .systemFont(ofSize: 10)
        resetButton.frame = NSRect(x: controlX + controlWidth - resetWidth, y: y, width: resetWidth, height: height)
        resetButton.target = self
        resetButton.action = action
        resetButton.isHidden = true
        view.addSubview(resetButton)
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    // MARK: - Sync from model

    /// Update controls and dirty indicators from committed config and draft state.
    func sync(committed: DanTermConfig, draft: PreferencesDraft?) {
        guard let draft = draft else {
            // No draft — show committed values, hide all dirty indicators.
            syncControls(from: committed)
            hideDirtyIndicators()
            isDirty = false
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

        // Alert clear mode dirty indicator.
        alertClearModePrevLabel.isHidden = !alertDirty
        alertClearModeResetButton.isHidden = !alertDirty
        if alertDirty {
            let displayValue = committed.alertClearMode == .focus ? "Focus" : "Manual"
            alertClearModePrevLabel.stringValue = "Prev: \(displayValue)"
        }

        // Remote theme dirty indicator.
        remoteThemePrevLabel.isHidden = !themeDirty
        remoteThemeResetButton.isHidden = !themeDirty
        if themeDirty {
            remoteThemePrevLabel.stringValue = "Prev: \(committed.remoteTheme)"
        }

        isDirty = alertDirty || themeDirty
        saveButton.isEnabled = isDirty
    }

    private func syncControls(from config: DanTermConfig) {
        switch config.alertClearMode {
        case .focus: alertClearModePopup.selectItem(at: 0)
        case .manual: alertClearModePopup.selectItem(at: 1)
        }
        remoteThemeField.stringValue = config.remoteTheme
    }

    private func hideDirtyIndicators() {
        alertClearModePrevLabel.isHidden = true
        alertClearModeResetButton.isHidden = true
        remoteThemePrevLabel.isHidden = true
        remoteThemeResetButton.isHidden = true
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
