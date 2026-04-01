// Preferences panel: a floating utility window for editing DanTerm-specific settings.
// Changes take effect immediately (dispatched through the Elm loop) and are persisted
// to ~/.config/danterm/config. The panel syncs from model.config on external reloads.
import Cocoa

class PreferencesPanel: NSPanel, NSTextFieldDelegate {
    weak var runtime: AppRuntime?

    private let alertClearModePopup = NSPopUpButton()
    private let remoteThemeField = NSTextField()

    init(config: DanTermConfig, runtime: AppRuntime) {
        self.runtime = runtime
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        title = "Preferences"
        isReleasedWhenClosed = false
        center()
        buildUI()
        syncFromConfig(config)
    }

    // MARK: - Layout

    private func buildUI() {
        guard let contentView = contentView else { return }
        contentView.wantsLayer = true

        let padding: CGFloat = 20
        let rowHeight: CGFloat = 24
        let labelWidth: CGFloat = 120
        let controlX = padding + labelWidth + 8
        let controlWidth = contentView.bounds.width - controlX - padding
        var y = contentView.bounds.height - padding - rowHeight

        // Alert Clear Mode
        let alertLabel = makeLabel("Alert Clear Mode")
        alertLabel.frame = NSRect(x: padding, y: y, width: labelWidth, height: rowHeight)
        contentView.addSubview(alertLabel)

        alertClearModePopup.removeAllItems()
        alertClearModePopup.addItems(withTitles: ["Focus", "Manual"])
        alertClearModePopup.frame = NSRect(x: controlX, y: y, width: controlWidth, height: rowHeight)
        alertClearModePopup.target = self
        alertClearModePopup.action = #selector(alertClearModeChanged(_:))
        contentView.addSubview(alertClearModePopup)

        y -= rowHeight + 12

        // Remote Theme
        let themeLabel = makeLabel("Remote Theme")
        themeLabel.frame = NSRect(x: padding, y: y, width: labelWidth, height: rowHeight)
        contentView.addSubview(themeLabel)

        remoteThemeField.frame = NSRect(x: controlX, y: y, width: controlWidth, height: rowHeight)
        remoteThemeField.delegate = self
        remoteThemeField.placeholderString = DanTermConfig.default.remoteTheme
        contentView.addSubview(remoteThemeField)

        y -= rowHeight + 20

        // Bottom buttons
        let buttonWidth: CGFloat = 130
        let buttonHeight: CGFloat = 24
        let openConfigButton = NSButton(title: "Open Config File", target: self, action: #selector(openConfigFile(_:)))
        openConfigButton.bezelStyle = .push
        openConfigButton.frame = NSRect(x: padding, y: y, width: buttonWidth, height: buttonHeight)
        contentView.addSubview(openConfigButton)

        let reloadButton = NSButton(title: "Reload", target: self, action: #selector(reloadConfig(_:)))
        reloadButton.bezelStyle = .push
        reloadButton.frame = NSRect(x: contentView.bounds.width - padding - 80, y: y, width: 80, height: buttonHeight)
        contentView.addSubview(reloadButton)
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    // MARK: - Sync from model

    /// Update controls to reflect the current config (called on open and after external reload).
    func syncFromConfig(_ config: DanTermConfig) {
        switch config.alertClearMode {
        case .focus: alertClearModePopup.selectItem(at: 0)
        case .manual: alertClearModePopup.selectItem(at: 1)
        }
        remoteThemeField.stringValue = config.remoteTheme
    }

    // MARK: - Actions

    @objc private func alertClearModeChanged(_ sender: NSPopUpButton) {
        let mode: AlertClearMode = sender.indexOfSelectedItem == 0 ? .focus : .manual
        runtime?.send(.setAlertClearMode(mode))
    }

    // NSTextFieldDelegate: committed edit (Enter or focus loss).
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === remoteThemeField else { return }
        runtime?.send(.setRemoteTheme(field.stringValue))
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
