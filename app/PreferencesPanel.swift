// DanTerm's reusable Settings window and projection coordinator.
import Cocoa
import DanTermProtocol

/// The width the settings form gives its input controls. This is the only width
/// the panel states: the label column measures itself from its widest label, and
/// the window sizes to the sum. Nothing here may assert a window width -- an
/// NSGridView hands every surplus point to column 0 and ignores content hugging,
/// so a window wider than its content pads the labels and starves the inputs.
let preferencesControlColumnWidth: CGFloat = 320

/// Owns the application-wide settings controls and commits each completed edit.
class PreferencesPanel: NSWindow, NSComboBoxDelegate, NSWindowDelegate, NSToolbarDelegate,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    weak var runtime: AppRuntime?
    let generalSection = GeneralPreferencesViewController()
    let appearanceSection = AppearancePreferencesViewController()
    let keyboardSection = KeyboardPreferencesViewController()
    let remoteSection = RemotePreferencesViewController()
    private let detailHostController = NSViewController()
    private var installedSectionController: NSViewController?
    private(set) var keybindingEditorController: KeybindingEditorSheetController?
    private(set) var keybindingEditorSheet: NSWindow?
    private var keybindingRows: [KeybindingBrowserRow] = []
    private var isSyncingKeybindingSelection = false
    private(set) var resetAllAlert: NSAlert?

    /// The AppKit event being dispatched right now. Stored as a reader rather
    /// than read from `NSApp` at the call site so the UI suite can drive the
    /// "still dragging" and "gesture complete" cases without an event loop.
    var currentAppKitEvent: () -> NSEvent? = { NSApp.currentEvent }

    init(runtime: AppRuntime) {
        self.runtime = runtime
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
        configureToolbar()
        buildUI()
        if let contentView { setContentSize(contentView.fittingSize) }
        center()
    }

    // MARK: - Layout

    private func buildUI() {
        detailHostController.view = NSView()
        contentViewController = detailHostController
        configureSectionActions()
        showSection(.general)
    }

    private func configureSectionActions() {
        generalSection.alertClearModeControl.target = self
        generalSection.alertClearModeControl.action = #selector(alertClearModeChanged(_:))
        generalSection.copyOnSelectCheckbox.target = self
        generalSection.copyOnSelectCheckbox.action = #selector(copyOnSelectChanged(_:))
        generalSection.openConfigButton.target = self
        generalSection.openConfigButton.action = #selector(openConfigFile(_:))
        generalSection.reloadConfigButton.target = self
        generalSection.reloadConfigButton.action = #selector(reloadConfig(_:))

        appearanceSection.themeBrowseButton.target = self
        appearanceSection.themeBrowseButton.action = #selector(browseTheme(_:))
        appearanceSection.fontFamilyCombo.delegate = self
        appearanceSection.fontSizeField.delegate = self
        appearanceSection.fontSizeStepper.target = self
        appearanceSection.fontSizeStepper.action = #selector(fontSizeStepped(_:))
        appearanceSection.unfocusedPaneOpacitySlider.target = self
        appearanceSection.unfocusedPaneOpacitySlider.action = #selector(unfocusedPaneOpacityChanged(_:))
        appearanceSection.remoteThemeBrowseButton.target = self
        appearanceSection.remoteThemeBrowseButton.action = #selector(browseRemoteTheme(_:))

        keyboardSection.optionAsAltControl.target = self
        keyboardSection.optionAsAltControl.action = #selector(optionAsAltChanged(_:))
        keyboardSection.keybindingSearchField.delegate = self
        keyboardSection.keybindingTable.dataSource = self
        keyboardSection.keybindingTable.delegate = self
        keyboardSection.keybindingTable.target = self
        keyboardSection.keybindingTable.doubleAction = #selector(openSelectedKeybindingEditor)
        keyboardSection.keybindingTable.onReturn = { [weak self] in
            self?.openSelectedKeybindingEditor()
        }
        keyboardSection.resetAllItem.target = self
        keyboardSection.resetAllItem.action = #selector(resetAllKeybindings(_:))
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar
    }

    private func showSection(_ section: PreferencesSection) {
        let controller = sectionController(for: section)
        if installedSectionController !== controller {
            installedSectionController?.view.removeFromSuperview()
            installedSectionController?.removeFromParent()
            detailHostController.addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            detailHostController.view.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: detailHostController.view.topAnchor),
                controller.view.leadingAnchor.constraint(equalTo: detailHostController.view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: detailHostController.view.trailingAnchor),
                controller.view.bottomAnchor.constraint(equalTo: detailHostController.view.bottomAnchor),
            ])
            installedSectionController = controller
        }
        toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(section.title)
        if let contentView { setContentSize(contentView.fittingSize) }
    }

    /// Exhaustively maps model sections to their one owning controller.
    private func sectionController(for section: PreferencesSection) -> NSViewController {
        switch section {
        case .general: generalSection
        case .appearance: appearanceSection
        case .keybindings: keyboardSection
        case .remote: remoteSection
        }
    }

    // MARK: - Apply projection

    /// Apply the already-rendered preferences projection without recomputing model state.
    func apply(_ projection: PreferencesPanelProjection) {
        showSection(projection.section)
        if keyboardSection.keybindingSearchField.stringValue != projection.keybindingSearchText {
            keyboardSection.keybindingSearchField.stringValue = projection.keybindingSearchText
        }
        rebuildKeybindingRows(projection)
        reconcileKeybindingEditor(projection.keybindingEditor)
        reconcileResetAllConfirmation(projection.isResetAllKeybindingsConfirmationPresented)
        let alertIndex = projection.selectedAlertClearMode == .focus ? 0 : 1
        if generalSection.alertClearModeControl.selectedSegment != alertIndex {
            generalSection.alertClearModeControl.selectedSegment = alertIndex
        }
        let optionAsAltIndex = switch projection.optionAsAlt {
        case nil: 0
        case .left: 1
        case .right: 2
        case .both: 3
        }
        if keyboardSection.optionAsAltControl.selectedSegment != optionAsAltIndex {
            keyboardSection.optionAsAltControl.selectedSegment = optionAsAltIndex
        }

        let copyOnSelectState: NSControl.StateValue = projection.copyOnSelect ? .on : .off
        if generalSection.copyOnSelectCheckbox.state != copyOnSelectState {
            generalSection.copyOnSelectCheckbox.state = copyOnSelectState
        }
        appearanceSection.apply(projection)
        remoteSection.apply(projection)
    }

    private func rebuildKeybindingRows(_ projection: PreferencesPanelProjection) {
        isSyncingKeybindingSelection = true
        keybindingRows = []
        for group in projection.keybindingGroups {
            keybindingRows.append(.group(group.title))
            keybindingRows.append(contentsOf: group.actions.map(KeybindingBrowserRow.action))
        }
        keyboardSection.keybindingTable.reloadData()
        if let row = keybindingRows.firstIndex(where: { $0.action?.isSelected == true }) {
            keyboardSection.keybindingTable.selectRowIndexes(
                IndexSet(integer: row),
                byExtendingSelection: false
            )
        } else {
            keyboardSection.keybindingTable.deselectAll(nil)
        }
        isSyncingKeybindingSelection = false
        let diagnostic = projection.keybindingDiagnosticText
        keyboardSection.keybindingDiagnosticLabel.stringValue = diagnostic ?? ""
        keyboardSection.keybindingDiagnosticLabel.isHidden = diagnostic == nil
    }

    private func reconcileKeybindingEditor(_ projection: KeybindingEditorProjection?) {
        guard let projection else {
            if let sheet = keybindingEditorSheet, sheet.sheetParent != nil {
                endSheet(sheet)
            }
            keybindingEditorController = nil
            keybindingEditorSheet = nil
            return
        }
        let controller: KeybindingEditorSheetController
        if let existing = keybindingEditorController {
            controller = existing
        } else {
            controller = KeybindingEditorSheetController(runtime: runtime)
            let sheet = NSWindow(contentViewController: controller)
            sheet.styleMask = [.titled]
            sheet.title = "Edit Key Binding"
            sheet.isExcludedFromWindowsMenu = true
            keybindingEditorController = controller
            keybindingEditorSheet = sheet
            beginSheet(sheet) { [weak self, weak controller] _ in
                guard self?.keybindingEditorController === controller else { return }
                self?.keybindingEditorController = nil
                self?.keybindingEditorSheet = nil
            }
        }
        controller.apply(projection)
    }

    private func reconcileResetAllConfirmation(_ isPresented: Bool) {
        guard isPresented else {
            if let window = resetAllAlert?.window, window.sheetParent != nil {
                endSheet(window, returnCode: .cancel)
            }
            resetAllAlert = nil
            return
        }
        guard resetAllAlert == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Reset All Key Bindings?"
        alert.informativeText = "This restores every configurable command to its default shortcuts."
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        resetAllAlert = alert
        alert.beginSheetModal(for: self) { [weak self, weak alert] response in
            guard self?.resetAllAlert === alert else { return }
            self?.resetAllAlert = nil
            self?.runtime?.send(.prefKeybinding(response == .alertFirstButtonReturn
                ? .confirmResetAll : .cancelResetAll))
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        PreferencesSection.allCases.map { NSToolbarItem.Identifier($0.title) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let section = PreferencesSection.allCases.first(where: {
            $0.title == itemIdentifier.rawValue
        }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = section.title
        item.image = NSImage(
            systemSymbolName: section.systemSymbolName,
            accessibilityDescription: section.title
        )
        item.target = self
        item.action = #selector(selectSettingsSection(_:))
        return item
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        keybindingRows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard keybindingRows.indices.contains(row) else { return false }
        if case .group = keybindingRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let action = keybindingRows[safe: row]?.action else { return -1 }
        let oneLine = NSTextField(labelWithString: "M").intrinsicContentSize.height
        let shortcuts = NSTextField(labelWithString:
            action.shortcutVisualValues.joined(separator: "\n"))
        shortcuts.maximumNumberOfLines = 0
        shortcuts.lineBreakMode = .byWordWrapping
        let contentGrowth = max(0, shortcuts.intrinsicContentSize.height - oneLine)
        return tableView.rowHeight + contentGrowth
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard keybindingRows.indices.contains(row) else { return nil }
        switch keybindingRows[row] {
        case .group(let title):
            guard tableColumn == nil || tableColumn === tableView.tableColumns.first else { return nil }
            let cell = keybindingTextCell(
                in: tableView,
                identifier: "KeybindingGroupCell",
                text: title
            )
            guard let label = cell.textField else { return cell }
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return cell
        case .action(let action):
            switch tableColumn?.identifier.rawValue {
            case "Command":
                return keybindingTextCell(
                    in: tableView,
                    identifier: "KeybindingCommandCell",
                    text: action.title
                )
            case "Shortcuts":
                let cell = keybindingTextCell(
                    in: tableView,
                    identifier: "KeybindingShortcutsCell",
                    text: action.shortcutVisualValues.joined(separator: "\n")
                )
                guard let label = cell.textField else { return cell }
                label.alignment = .right
                label.maximumNumberOfLines = 0
                label.lineBreakMode = .byWordWrapping
                label.textColor = action.shortcutsAreApplied ? .labelColor : .tertiaryLabelColor
                label.setAccessibilityLabel(
                    action.shortcutAccessibilityValues.count == 1 ? "Shortcut" : "Shortcuts"
                )
                label.setAccessibilityValue(
                    action.shortcutAccessibilityValues.joined(separator: ", ")
                )
                return cell
            case "Status":
                let cell = keybindingTextCell(
                    in: tableView,
                    identifier: "KeybindingStatusCell",
                    text: action.stateText
                )
                guard let label = cell.textField else { return cell }
                label.textColor = .secondaryLabelColor
                return cell
            default:
                return nil
            }
        }
    }

    private func keybindingTextCell(
        in tableView: NSTableView,
        identifier: String,
        text: String
    ) -> NSTableCellView {
        let viewIdentifier = NSUserInterfaceItemIdentifier(identifier)
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: viewIdentifier, owner: nil)
            as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = viewIdentifier
            let label = NSTextField(labelWithString: "")
            cell.addSubview(label)
            cell.textField = label
        }
        cell.textField?.stringValue = text
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        keybindingRows[safe: row]?.action != nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingKeybindingSelection else { return }
        let action = keybindingRows[safe: keyboardSection.keybindingTable.selectedRow]?.action
        runtime?.send(.prefKeybinding(.selectBrowserAction(action?.id)))
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === keyboardSection.keybindingSearchField {
            runtime?.send(.prefKeybindingSearchChanged(field.stringValue))
            return
        }
        if field === appearanceSection.fontSizeField {
            runtime?.send(.prefSet(.fontSize(field.stringValue)))
        } else if field === appearanceSection.fontFamilyCombo {
            let text = field.stringValue
            runtime?.send(.prefSet(.fontFamily(text.isEmpty ? nil : text)))
        }
    }

    // MARK: - NSWindowDelegate

    // NSWindowDelegate: red-X / performClose. Translate the gesture to a model
    // intent; reconcile orders the panel out before AppKit performs its close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let sheet = keybindingEditorSheet, sheet.sheetParent != nil {
            endSheet(sheet)
        }
        keybindingEditorController = nil
        keybindingEditorSheet = nil
        if let window = resetAllAlert?.window, window.sheetParent != nil {
            endSheet(window, returnCode: .cancel)
        }
        resetAllAlert = nil
        runtime?.send(.prefSave)
        runtime?.send(.preferencesClosed)
        return true
    }

    // MARK: - Actions

    @objc private func alertClearModeChanged(_ sender: NSSegmentedControl) {
        let mode: AlertClearMode = sender.selectedSegment == 0 ? .focus : .manual
        applyPreferenceChange(.alertClearMode(mode))
    }

    @objc private func copyOnSelectChanged(_ sender: NSButton) {
        applyPreferenceChange(.copyOnSelect(sender.state == .on))
    }

    @objc private func optionAsAltChanged(_ sender: NSSegmentedControl) {
        let policy: OptionAsAlt? = switch sender.selectedSegment {
        case 1: .left
        case 2: .right
        case 3: .both
        default: nil
        }
        applyPreferenceChange(.optionAsAlt(policy))
    }

    // NSTextFieldDelegate: a completed text edit is one atomic config change.
    // AppKit can call this while reconcile hides the field, so report through the
    // outbox and let the active send frame finish before it dispatches the save.
    func controlTextDidEndEditing(_ obj: Notification) {
        runtime?.outbox.report([.prefSave])
    }

    // NSComboBoxDelegate: the user picked a family from the list. The selected
    // title goes into the draft verbatim, including the system-monospace entry --
    // the core normalizes that sentinel back to "no family", which is what keeps
    // this side free of special cases.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox,
              combo === appearanceSection.fontFamilyCombo,
              let title = combo.objectValueOfSelectedItem as? String
        else { return }
        applyPreferenceChange(.fontFamily(title))
    }

    /// A slider change is a live preview until its gesture ends. A mouse drag is
    /// one gesture that commits on release; every other change -- an arrow key,
    /// a Home/End jump, an accessibility action -- is complete on arrival, so it
    /// commits at once and the config file never waits for the panel to close.
    @objc private func unfocusedPaneOpacityChanged(_ sender: NSSlider) {
        runtime?.send(.prefSet(.unfocusedPaneOpacity(sender.doubleValue)))
        let event = currentAppKitEvent()
        if event?.type == .leftMouseDown || event?.type == .leftMouseDragged { return }
        runtime?.send(.prefSave)
    }

    @objc private func fontSizeStepped(_ sender: NSStepper) {
        let text = configFontSizeText(sender.doubleValue)
        appearanceSection.fontSizeField.stringValue = text
        applyPreferenceChange(.fontSize(text))
    }

    /// Present the theme picker sheet so the user can browse DanTerm's catalog.
    @objc private func browseTheme(_ sender: Any?) {
        let picker = RemoteThemePickerSheet()
        picker.currentThemeName = appearanceSection.themeField.stringValue.isEmpty
            ? runtime?.model.config.defaultTheme
            : appearanceSection.themeField.stringValue
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
        picker.currentThemeName = appearanceSection.remoteThemeField.stringValue.isEmpty
            ? runtime?.model.config.remoteTheme
            : appearanceSection.remoteThemeField.stringValue
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

    @objc private func selectSettingsSection(_ sender: NSToolbarItem) {
        guard let section = PreferencesSection.allCases.first(where: {
            $0.title == sender.itemIdentifier.rawValue
        }) else { return }
        runtime?.send(.prefSelectSection(section))
    }

    @objc private func resetAllKeybindings(_ sender: Any?) {
        runtime?.send(.prefKeybinding(.requestResetAll))
    }

    /// Opens the selected command from the table's Return and double-click paths.
    @objc func openSelectedKeybindingEditor() {
        guard let action = keybindingRows[safe: keyboardSection.keybindingTable.selectedRow]?.action
        else { return }
        runtime?.send(.prefKeybinding(.openEditor(action.id)))
    }

    private func applyPreferenceChange(_ edit: PreferenceEdit) {
        runtime?.send(.prefSet(edit))
        runtime?.send(.prefSave)
    }
}

/// Flattens projected categories and commands into native table row identities.
private enum KeybindingBrowserRow {
    case group(String)
    case action(KeybindingSettingsAction)

    var action: KeybindingSettingsAction? {
        guard case .action(let action) = self else { return nil }
        return action
    }
}

/// Adds the browser's Return edit gesture without moving model state into AppKit.
final class KeybindingBrowserTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x24 || event.keyCode == 0x4c {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Renders and reports one model-owned transactional keybinding editor sheet.
final class KeybindingEditorSheetController: NSViewController {
    weak var runtime: AppRuntime?
    let enableCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    let shortcutList = NSStackView()
    let addButton = NSButton(title: "Add", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)
    let diagnosticLabel = NSTextField(labelWithString: "")
    private var actionRow: DialogActionRow!
    var doneButton: NSButton { actionRow.button(for: .defaultAction)! }
    var cancelButton: NSButton { actionRow.button(for: .cancel)! }

    init(runtime: AppRuntime?) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        shortcutList.orientation = .vertical
        shortcutList.alignment = .leading
        shortcutList.spacing = 8
        enableCheckbox.target = self
        enableCheckbox.action = #selector(enabledChanged(_:))
        addButton.target = self
        addButton.action = #selector(addShortcut(_:))
        resetButton.target = self
        resetButton.action = #selector(resetToDefaults(_:))
        diagnosticLabel.textColor = .systemOrange
        diagnosticLabel.maximumNumberOfLines = 0
        diagnosticLabel.lineBreakMode = .byWordWrapping
        actionRow = DialogActionRow(actions: [
            DialogAction(title: "Done", role: .defaultAction) { [weak self] in
                self?.runtime?.send(.prefKeybinding(.acceptEditor))
            },
            DialogAction(title: "Cancel", role: .cancel) { [weak self] in
                self?.runtime?.send(.prefKeybinding(.closeEditor))
            },
        ])
        let controls = NSStackView(views: [addButton, resetButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        let stack = NSStackView(views: [enableCheckbox, shortcutList, controls,
                                        diagnosticLabel, actionRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = container
    }

    /// Rebuilds sheet rows from the complete candidate projection and focuses recording last.
    func apply(_ projection: KeybindingEditorProjection) {
        loadViewIfNeeded()
        title = projection.title
        enableCheckbox.state = projection.isEnabled ? .on : .off
        shortcutList.arrangedSubviews.forEach { child in
            shortcutList.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        var activeRecorder: KeybindingRecorderButton?
        for (index, shortcut) in projection.shortcuts.enumerated() {
            let value = NSTextField(labelWithString: shortcut.visual)
            value.textColor = projection.isEnabled ? .labelColor : .tertiaryLabelColor
            value.setAccessibilityLabel("Shortcut")
            value.setAccessibilityValue(shortcut.accessibilityValue)
            let recorder = KeybindingRecorderButton(title: projection.recordingTarget == .replacing(index)
                ? "Press Shortcut..." : "Change")
            recorder.actionID = projection.actionID
            recorder.replacementIndex = index
            configure(recorder, target: .replacing(index))
            let primary = NSButton(title: index == 0 ? "Primary" : "Make Primary", target: self,
                                   action: #selector(makePrimary(_:)))
            primary.tag = index
            primary.isEnabled = index != 0
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeShortcut(_:)))
            remove.tag = index
            remove.isHidden = !projection.canAddOrRemove
            let row = NSStackView(views: [value, recorder, primary, remove])
            row.orientation = .horizontal
            row.spacing = 8
            if let note = shortcut.moveNote {
                let noteLabel = NSTextField(labelWithString: note)
                noteLabel.textColor = .secondaryLabelColor
                let wrapper = NSStackView(views: [row, noteLabel])
                wrapper.orientation = .vertical
                wrapper.alignment = .leading
                shortcutList.addArrangedSubview(wrapper)
            } else {
                shortcutList.addArrangedSubview(row)
            }
            if projection.recordingTarget == .replacing(index) { activeRecorder = recorder }
        }
        addButton.isHidden = !projection.canAddOrRemove
        if projection.recordingTarget == .adding {
            addButton.isHidden = true
            let recorder = KeybindingRecorderButton(title: "Press Shortcut...")
            recorder.actionID = projection.actionID
            configure(recorder, target: .adding)
            shortcutList.addArrangedSubview(recorder)
            activeRecorder = recorder
        }
        let notes = [projection.removalNote, projection.diagnosticText].compactMap { $0 }
        diagnosticLabel.stringValue = notes.joined(separator: "\n")
        diagnosticLabel.isHidden = notes.isEmpty
        if let activeRecorder {
            view.window?.makeFirstResponder(activeRecorder)
        }
    }

    @objc override func cancelOperation(_ sender: Any?) {
        runtime?.send(.prefKeybinding(.closeEditor))
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        runtime?.send(.prefKeybinding(.setEditorEnabled(sender.state == .on)))
    }

    @objc private func addShortcut(_ sender: Any?) {
        runtime?.send(.prefKeybinding(.beginEditorRecording(chordAt: nil)))
    }

    @objc private func resetToDefaults(_ sender: Any?) {
        runtime?.send(.prefKeybinding(.resetEditor))
    }

    @objc private func makePrimary(_ sender: NSButton) {
        runtime?.send(.prefKeybinding(.makeEditorChordPrimary(at: sender.tag)))
    }

    @objc private func removeShortcut(_ sender: NSButton) {
        runtime?.send(.prefKeybinding(.removeEditorChord(at: sender.tag)))
    }

    private func configure(
        _ recorder: KeybindingRecorderButton,
        target: KeybindingEditorRecordingTarget
    ) {
        recorder.onBegin = { [weak self] _ in
            let index: Int?
            if case .replacing(let value) = target { index = value } else { index = nil }
            self?.runtime?.send(.prefKeybinding(.beginEditorRecording(chordAt: index)))
        }
        recorder.onCancel = { [weak self] in
            self?.runtime?.send(.prefKeybinding(.cancelEditorRecording))
        }
        recorder.onCapture = { [weak self] _, chord in
            self?.runtime?.send(.prefKeybinding(.recordEditorChord(chord)))
        }
        recorder.onDelete = { [weak self] _, index in
            self?.runtime?.send(.prefKeybinding(.removeEditorChord(at: index)))
        }
        recorder.onReject = { [weak self] diagnostic in
            self?.runtime?.send(.prefKeybinding(.rejectEditorRecording(diagnostic)))
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Captures one key equivalent before the main menu can invoke its current owner.
final class KeybindingRecorderButton: NSButton {
    var actionID = commandDescriptor(.openConfig).id
    var onBegin: ((KeybindingActionID) -> Void)?
    var onCancel: (() -> Void)?
    var onCapture: ((KeybindingActionID, KeyChord) -> Void)?
    var onDelete: ((KeybindingActionID, Int) -> Void)?
    var onReject: ((KeybindingDiagnostic) -> Void)?
    var replacementIndex: Int?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        target = self
        action = #selector(beginRecording(_:))
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording(_ sender: Any?) {
        onBegin?(actionID)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if event.keyCode == 0x35 {
            onCancel?()
            return true
        }
        if event.keyCode == 0x75, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           let replacementIndex {
            onDelete?(actionID, replacementIndex)
            return true
        }
        guard let chord = keyChord(from: event) else {
            onReject?(KeybindingDiagnostic(
                path: "keybindings.\(actionID.rawValue)",
                reason: "shortcut must use Cmd, Control, or Option with a representable key"
            ))
            return true
        }
        onCapture?(actionID, chord)
        return true
    }

}
