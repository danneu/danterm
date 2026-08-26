// DanTerm's reusable Settings window, General form, and Key Bindings editor.
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

    // Terminal appearance settings
    private let themeField = NSTextField()
    private let themeBrowseButton = NSButton()
    // The UI harness finds each warning's grid row from its label, so all three
    // labels have to be reachable from the harness.
    let themeWarningLabel = NSTextField(labelWithString: "")
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
    let alertClearModeControl = NSSegmentedControl(
        labels: ["On Focus", "Manually"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let copyOnSelectCheckbox = NSButton()
    let optionAsAltControl = NSSegmentedControl(
        labels: ["Native", "Left", "Right", "Both"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let remoteThemeField = NSTextField()
    private let browseButton = NSButton()
    let remoteThemeWarningLabel = NSTextField(labelWithString: "")
    private var remoteThemeWarningRow: NSGridRow?

    // Tailnet listener: read-only, because the listener is frozen at launch and an
    // editable field would promise a rebind the app never performs.
    private let tailnetConfiguredField = NSTextField()
    private let tailnetEndpointField = NSTextField()
    private let tailnetStatusField = NSTextField()
    private let tailnetNoteLabel = NSTextField(
        labelWithString: "Edit tailnet settings in the config file; they apply at the next launch."
    )
    private let generalView = NSView()
    let keybindingSearchField = NSSearchField()
    let keybindingActionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let keybindingTable = KeybindingBrowserTableView()
    let keybindingDiagnosticLabel = NSTextField(labelWithString: "")
    private let keybindingScrollView = NSScrollView()
    private(set) var keybindingEditorController: KeybindingEditorSheetController?
    private(set) var keybindingEditorSheet: NSWindow?
    private var keybindingRows: [KeybindingBrowserRow] = []
    private var isSyncingKeybindingSelection = false
    private(set) var resetAllAlert: NSAlert?
    private var generalConstraints: [NSLayoutConstraint] = []
    private var keybindingConstraints: [NSLayoutConstraint] = []

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
        configureToolbar()
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
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        // Vertically center labels with their adjacent controls. NSGridView rows
        // default to top alignment, which leaves labels sticking to the top of
        // rows containing taller controls (text fields, popups).
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8

        addRow(to: grid, formRow("Theme", themeControls))
        themeWarningRow = addWarningRow(to: grid, themeWarningLabel)
        addRow(to: grid, formRow("Font Family", fontFamilyCombo))
        fontFamilyWarningRow = addWarningRow(to: grid, fontFamilyWarningLabel)
        addRow(to: grid, formRow("Font Size", makeHStack([fontSizeField, fontSizeStepper])))
        addRow(to: grid, formRow("Clear Alerts", alertClearModeControl), topPadding: 8)
        addRow(to: grid, formRow("Option as Alt", optionAsAltControl))
        addRow(to: grid, [NSGridCell.emptyContentView, copyOnSelectCheckbox])
        addRow(to: grid, formRow("Remote Theme", remoteThemeControls), topPadding: 8)
        remoteThemeWarningRow = addWarningRow(to: grid, remoteThemeWarningLabel)
        addRow(
            to: grid,
            formRow("Config file", makeHStack([
                makeButton("Open Config File", action: #selector(openConfigFile(_:))),
                makeButton("Reload Config", action: #selector(reloadConfig(_:))),
            ])),
            topPadding: 4
        )
        addRow(to: grid, formRow("Tailnet", tailnetConfiguredField), topPadding: 8)
        addRow(to: grid, formRow("Endpoint", tailnetEndpointField))
        addRow(to: grid, formRow("Listener", tailnetStatusField))
        addRow(to: grid, [NSGridCell.emptyContentView, tailnetNoteLabel])

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
        alertClearModeControl.target = self
        alertClearModeControl.action = #selector(alertClearModeChanged(_:))

        optionAsAltControl.target = self
        optionAsAltControl.action = #selector(optionAsAltChanged(_:))

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
        generalView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(generalView)
        generalView.addSubview(grid)

        let padding: CGFloat = 20
        generalConstraints = [
            generalView.topAnchor.constraint(equalTo: contentView.topAnchor),
            generalView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            generalView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            generalView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            grid.topAnchor.constraint(equalTo: generalView.topAnchor, constant: padding),
            grid.leadingAnchor.constraint(equalTo: generalView.leadingAnchor, constant: padding),
            grid.trailingAnchor.constraint(equalTo: generalView.trailingAnchor, constant: -padding),
            grid.bottomAnchor.constraint(equalTo: generalView.bottomAnchor, constant: -padding),
        ]
        NSLayoutConstraint.activate(generalConstraints)
        buildKeybindingUI()
        showSection(.general)
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar
    }

    private func buildKeybindingUI() {
        guard let contentView else { return }
        keybindingSearchField.placeholderString = "Search Commands"
        keybindingSearchField.delegate = self
        keybindingDiagnosticLabel.textColor = .systemOrange
        keybindingDiagnosticLabel.maximumNumberOfLines = 0
        keybindingDiagnosticLabel.lineBreakMode = .byWordWrapping
        keybindingTable.headerView = nil
        keybindingTable.style = .fullWidth
        keybindingTable.rowSizeStyle = .default
        keybindingTable.columnAutoresizingStyle = .noColumnAutoresizing
        keybindingTable.usesAlternatingRowBackgroundColors = true
        keybindingTable.allowsEmptySelection = true
        keybindingTable.allowsMultipleSelection = false
        keybindingTable.dataSource = self
        keybindingTable.delegate = self
        keybindingTable.target = self
        keybindingTable.doubleAction = #selector(openSelectedKeybindingEditor)
        keybindingTable.onReturn = { [weak self] in self?.openSelectedKeybindingEditor() }
        for (identifier, width) in [("Command", 240.0), ("Shortcuts", 180.0),
                                    ("Status", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.width = width
            column.isEditable = false
            keybindingTable.addTableColumn(column)
        }
        keybindingScrollView.documentView = keybindingTable
        keybindingScrollView.hasVerticalScroller = true
        keybindingScrollView.drawsBackground = false
        let tableContentWidth = keybindingTable.tableColumns.reduce(CGFloat.zero) {
            $0 + $1.width + keybindingTable.intercellSpacing.width
        }
        let browserWidth = NSScrollView.frameSize(
            forContentSize: NSSize(width: tableContentWidth, height: 0),
            horizontalScrollerClass: nil,
            verticalScrollerClass: NSScroller.self,
            borderType: keybindingScrollView.borderType,
            controlSize: .regular,
            scrollerStyle: keybindingScrollView.scrollerStyle
        ).width

        let actions = keybindingActionsButton
        actions.addItem(withTitle: "Key Binding Actions")
        actions.lastItem?.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: "Key Binding Actions"
        )
        let resetAll = NSMenuItem(
            title: "Reset All Key Bindings...",
            action: #selector(resetAllKeybindings(_:)),
            keyEquivalent: ""
        )
        resetAll.target = self
        actions.menu?.addItem(resetAll)
        let header = NSStackView(views: [keybindingSearchField, actions])
        header.orientation = .horizontal
        header.spacing = 8
        let stack = NSStackView(views: [header, keybindingDiagnosticLabel, keybindingScrollView])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        keybindingConstraints = [
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            keybindingScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: browserWidth),
            keybindingScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ]
        stack.identifier = NSUserInterfaceItemIdentifier("KeyBindingsSection")
        stack.isHidden = true
    }

    private func showSection(_ section: PreferencesSection) {
        NSLayoutConstraint.deactivate(section == .general ? keybindingConstraints : generalConstraints)
        NSLayoutConstraint.activate(section == .general ? generalConstraints : keybindingConstraints)
        generalView.isHidden = section != .general
        if let keybindings = contentView?.subviews.first(where: { $0.identifier?.rawValue == "KeyBindingsSection" }) {
            keybindings.isHidden = section != .keybindings
        }
        toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(section == .general ? "General" : "KeyBindings")
        if let contentView { setContentSize(contentView.fittingSize) }
    }

    /// Append one row to the form and hand back the row it created. Every row in
    /// the form goes through here, so a row handle is only ever the return value
    /// of the call that built the row -- no statement names a row by position,
    /// and inserting or reordering a row cannot silently retarget another one.
    /// A non-zero `topPadding` marks a row that starts a new section.
    @discardableResult
    private func addRow(
        to grid: NSGridView,
        _ views: [NSView],
        topPadding: CGFloat = 0
    ) -> NSGridRow {
        let row = grid.addRow(with: views)
        row.topPadding = topPadding
        // State the control column's width on the cell itself, so the grid has no
        // surplus to hand column 0. Applying it here means a row added later
        // cannot miss it.
        if let control = views.dropFirst().first, control !== NSGridCell.emptyContentView {
            control.widthAnchor.constraint(
                greaterThanOrEqualToConstant: preferencesControlColumnWidth
            ).isActive = true
        }
        return row
    }

    /// Append a full-width warning row that stays collapsed until `apply(_:)`
    /// projects its warning. The label wraps at the control column: NSGridView
    /// gives a wrapping label no width to wrap against, so an unconstrained
    /// warning would stretch the panel to one long line.
    private func addWarningRow(to grid: NSGridView, _ label: NSTextField) -> NSGridRow {
        configureWarningLabel(label)
        label.preferredMaxLayoutWidth = preferencesControlColumnWidth
        label.isHidden = true
        let row = addRow(to: grid, [NSGridCell.emptyContentView, label])
        row.isHidden = true
        return row
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
        showSection(projection.section)
        if keybindingSearchField.stringValue != projection.keybindingSearchText {
            keybindingSearchField.stringValue = projection.keybindingSearchText
        }
        rebuildKeybindingRows(projection)
        reconcileKeybindingEditor(projection.keybindingEditor)
        reconcileResetAllConfirmation(projection.isResetAllKeybindingsConfirmationPresented)
        let alertIndex = projection.selectedAlertClearMode == .focus ? 0 : 1
        if alertClearModeControl.selectedSegment != alertIndex {
            alertClearModeControl.selectedSegment = alertIndex
        }
        let optionAsAltIndex = switch projection.optionAsAlt {
        case nil: 0
        case .left: 1
        case .right: 2
        case .both: 3
        }
        if optionAsAltControl.selectedSegment != optionAsAltIndex {
            optionAsAltControl.selectedSegment = optionAsAltIndex
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

    private func rebuildKeybindingRows(_ projection: PreferencesPanelProjection) {
        isSyncingKeybindingSelection = true
        keybindingRows = []
        for group in projection.keybindingGroups {
            keybindingRows.append(.group(group.title))
            keybindingRows.append(contentsOf: group.actions.map(KeybindingBrowserRow.action))
        }
        keybindingTable.reloadData()
        if let row = keybindingRows.firstIndex(where: { $0.action?.isSelected == true }) {
            keybindingTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            keybindingTable.deselectAll(nil)
        }
        isSyncingKeybindingSelection = false
        let diagnostic = projection.keybindingDiagnosticText
        keybindingDiagnosticLabel.stringValue = diagnostic ?? ""
        keybindingDiagnosticLabel.isHidden = diagnostic == nil
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
        [.init("General"), .init("KeyBindings")]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = itemIdentifier.rawValue == "General" ? "General" : "Key Bindings"
        item.image = NSImage(systemSymbolName: itemIdentifier.rawValue == "General" ? "gearshape" : "keyboard", accessibilityDescription: item.label)
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
        let action = keybindingRows[safe: keybindingTable.selectedRow]?.action
        runtime?.send(.prefKeybinding(.selectBrowserAction(action?.id)))
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === keybindingSearchField {
            runtime?.send(.prefKeybindingSearchChanged(field.stringValue))
            return
        }
        if field === fontSizeField {
            let text = field.stringValue
            runtime?.send(.prefSet(.fontSize(text.isEmpty ? nil : text)))
        } else if field === fontFamilyCombo {
            let text = field.stringValue
            runtime?.send(.prefSet(.fontFamily(text.isEmpty ? nil : text)))
        }
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

    @objc private func selectSettingsSection(_ sender: NSToolbarItem) {
        runtime?.send(.prefSelectSection(sender.itemIdentifier.rawValue == "General" ? .general : .keybindings))
    }

    @objc private func resetAllKeybindings(_ sender: Any?) {
        runtime?.send(.prefKeybinding(.requestResetAll))
    }

    /// Opens the selected command from the table's Return and double-click paths.
    @objc func openSelectedKeybindingEditor() {
        guard let action = keybindingRows[safe: keybindingTable.selectedRow]?.action else { return }
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
    var actionID: KeybindingActionID = "app.open-config"
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
        guard let chord = Self.chord(from: event) else {
            onReject?(KeybindingDiagnostic(
                path: "keybindings.\(actionID.rawValue)",
                reason: "shortcut must use Cmd, Control, or Option with a representable key"
            ))
            return true
        }
        onCapture?(actionID, chord)
        return true
    }

    /// Converts the active layout's unshifted logical key into the config grammar.
    static func chord(from event: NSEvent) -> KeyChord? {
        var modifiers: DanTermProtocol.KeyModifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let key: KeybindingKey?
        switch event.keyCode {
        case 0x24, 0x4c: key = .named(.enter)
        case 0x30: key = .named(.tab)
        case 0x31: key = .named(.space)
        case 0x33: key = .named(.backspace)
        case 0x35: key = .named(.escape)
        case 0x75: key = .named(.delete)
        case 0x72: key = .named(.insert)
        case 0x73: key = .named(.home)
        case 0x74: key = .named(.pageUp)
        case 0x77: key = .named(.end)
        case 0x79: key = .named(.pageDown)
        case 0x7b: key = .named(.left)
        case 0x7c: key = .named(.right)
        case 0x7d: key = .named(.down)
        case 0x7e: key = .named(.up)
        case 0x7a: key = .named(.f1)
        case 0x78: key = .named(.f2)
        case 0x63: key = .named(.f3)
        case 0x76: key = .named(.f4)
        case 0x60: key = .named(.f5)
        case 0x61: key = .named(.f6)
        case 0x62: key = .named(.f7)
        case 0x64: key = .named(.f8)
        case 0x65: key = .named(.f9)
        case 0x6d: key = .named(.f10)
        case 0x67: key = .named(.f11)
        case 0x6f: key = .named(.f12)
        case 0x69: key = .named(.f13)
        case 0x6b: key = .named(.f14)
        case 0x71: key = .named(.f15)
        case 0x6a: key = .named(.f16)
        case 0x40: key = .named(.f17)
        case 0x4f: key = .named(.f18)
        case 0x50: key = .named(.f19)
        case 0x5a: key = .named(.f20)
        default:
            let text = event.characters(byApplyingModifiers: [])?.lowercased()
            if text == "+" { key = .named(.plus) }
            else if let character = text?.first { key = .character(character) }
            else { key = nil }
        }
        guard let key else { return nil }
        return KeyChord(modifiers: modifiers, key: key)
    }
}
