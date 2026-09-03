// Owns the controls and layout for each Settings section. The window remains
// the projection coordinator and action target.
import Cocoa
import DanTermProtocol

/// Gives every form section the same two-column layout and width contract.
class PreferencesFormSectionController: NSViewController {
    let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private let contentStack = NSStackView()

    init(identifier: String) {
        super.init(nibName: nil, bundle: nil)
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        contentStack.identifier = NSUserInterfaceItemIdentifier(identifier)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.addArrangedSubview(grid)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = NSView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            grid.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
        view = container
    }

    /// Adds one form row and applies the shared control-column width invariant.
    @discardableResult
    func addRow(_ views: [NSView]) -> NSGridRow {
        let row = grid.addRow(with: views)
        if let control = views.dropFirst().first, control !== NSGridCell.emptyContentView {
            control.widthAnchor.constraint(
                greaterThanOrEqualToConstant: preferencesControlColumnWidth
            ).isActive = true
        }
        return row
    }

    /// Adds a warning row directly after the setting whose fallback it explains.
    func addWarningRow(_ label: NSTextField) -> NSGridRow {
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .systemOrange
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = preferencesControlColumnWidth
        label.isHidden = true
        let row = addRow([NSGridCell.emptyContentView, label])
        row.isHidden = true
        return row
    }

    /// Adds non-form content below the grid while keeping one section layout owner.
    func addContentView(_ contentView: NSView) {
        contentStack.addArrangedSubview(contentView)
        contentView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    func formRow(_ labelText: String, _ control: NSView) -> [NSView] {
        let label = NSTextField(labelWithString: labelText)
        label.alignment = .right
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        return [label, control]
    }

    func makeHStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 4
        return stack
    }
}

/// Owns the general behavior and config-file controls.
final class GeneralPreferencesViewController: PreferencesFormSectionController {
    let alertClearModeControl = NSSegmentedControl(
        labels: ["On Focus", "Manually"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let copyOnSelectCheckbox = NSButton()
    let openConfigButton = NSButton(title: "Open Config File", target: nil, action: nil)
    let reloadConfigButton = NSButton(title: "Reload Config", target: nil, action: nil)

    init() {
        super.init(identifier: "GeneralSection")
        copyOnSelectCheckbox.setButtonType(.switch)
        copyOnSelectCheckbox.title = "Copy selection to clipboard"
        openConfigButton.bezelStyle = .push
        reloadConfigButton.bezelStyle = .push
        addRow([NSGridCell.emptyContentView, copyOnSelectCheckbox])
        addRow(formRow("Clear Alerts", alertClearModeControl))
        addRow(formRow("Config file", makeHStack([openConfigButton, reloadConfigButton])))
    }

    required init?(coder: NSCoder) { nil }
}

/// Owns theme, font, and pane-appearance controls and their warning rows.
final class AppearancePreferencesViewController: PreferencesFormSectionController {
    let themeField = NSTextField()
    let themeBrowseButton = NSButton()
    let themeWarningLabel = NSTextField(labelWithString: "")
    private var themeWarningRow: NSGridRow!
    let fontFamilyCombo = NSComboBox()
    let fontFamilyWarningLabel = NSTextField(labelWithString: "")
    private var fontFamilyWarningRow: NSGridRow!
    let fontSizeField = NSTextField()
    let fontSizeStepper = NSStepper()
    let unfocusedPaneOpacitySlider = NSSlider()
    let unfocusedPaneOpacityLabel = NSTextField(labelWithString: "")
    let remoteThemeField = NSTextField()
    let remoteThemeBrowseButton = NSButton()
    let remoteThemeWarningLabel = NSTextField(labelWithString: "")
    private var remoteThemeWarningRow: NSGridRow!

    init() {
        super.init(identifier: "AppearanceSection")

        themeField.isEditable = false
        themeField.isSelectable = true
        themeField.placeholderString = DanTermConfig.default.resolvedDefaultTheme
        configureBrowseButton(themeBrowseButton)

        fontFamilyCombo.usesDataSource = false
        fontFamilyCombo.isEditable = true
        fontFamilyCombo.completes = true
        fontFamilyCombo.numberOfVisibleItems = 12

        fontSizeField.placeholderString = configFontSizeText(DanTermConfig.default.resolvedFontSize)
        let fontSizeWidth = fontSizeField.widthAnchor.constraint(equalToConstant: 80)
        fontSizeWidth.priority = .defaultHigh
        fontSizeWidth.isActive = true
        fontSizeStepper.minValue = DanTermConfig.fontSizeRange.lowerBound
        fontSizeStepper.maxValue = DanTermConfig.fontSizeRange.upperBound
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false

        unfocusedPaneOpacitySlider.minValue = DanTermConfig.unfocusedPaneOpacityRange.lowerBound
        unfocusedPaneOpacitySlider.maxValue = DanTermConfig.unfocusedPaneOpacityRange.upperBound
        unfocusedPaneOpacitySlider.isContinuous = true
        unfocusedPaneOpacityLabel.alignment = .right
        unfocusedPaneOpacityLabel.textColor = .secondaryLabelColor
        let readoutWidth = unfocusedPaneOpacityLabel.widthAnchor.constraint(equalToConstant: 44)
        readoutWidth.priority = .defaultHigh
        readoutWidth.isActive = true

        remoteThemeField.isEditable = false
        remoteThemeField.isSelectable = true
        remoteThemeField.placeholderString = DanTermConfig.default.remoteTheme
        configureBrowseButton(remoteThemeBrowseButton)

        let themeControls = makeHStack([themeField, themeBrowseButton])
        themeControls.distribution = .fill
        addRow(formRow("Theme", themeControls))
        themeWarningRow = addWarningRow(themeWarningLabel)
        addRow(formRow("Font Family", fontFamilyCombo))
        fontFamilyWarningRow = addWarningRow(fontFamilyWarningLabel)
        addRow(formRow("Font Size", makeHStack([fontSizeField, fontSizeStepper])))
        addRow(formRow(
            "Unfocused Panes",
            makeHStack([unfocusedPaneOpacitySlider, unfocusedPaneOpacityLabel])
        ))
        let remoteThemeControls = makeHStack([remoteThemeField, remoteThemeBrowseButton])
        remoteThemeControls.distribution = .fill
        addRow(formRow("Remote Theme", remoteThemeControls))
        remoteThemeWarningRow = addWarningRow(remoteThemeWarningLabel)
    }

    required init?(coder: NSCoder) { nil }

    /// Applies all appearance fields without deriving model state in AppKit.
    func apply(_ projection: PreferencesPanelProjection) {
        if remoteThemeField.stringValue != projection.remoteThemeText {
            remoteThemeField.stringValue = projection.remoteThemeText
        }
        if themeField.stringValue != projection.themeText {
            themeField.stringValue = projection.themeText
        }
        if fontSizeField.stringValue != projection.fontSizeText {
            fontSizeField.stringValue = projection.fontSizeText
        }
        fontSizeStepper.doubleValue = projection.fontSizeStepperValue
        if fontFamilyCombo.objectValues as? [String] != projection.fontFamilyChoices {
            fontFamilyCombo.removeAllItems()
            fontFamilyCombo.addItems(withObjectValues: projection.fontFamilyChoices)
        }
        if fontFamilyCombo.stringValue != projection.fontFamilyText {
            fontFamilyCombo.stringValue = projection.fontFamilyText
        }
        if unfocusedPaneOpacitySlider.doubleValue != projection.unfocusedPaneOpacity {
            unfocusedPaneOpacitySlider.doubleValue = projection.unfocusedPaneOpacity
        }
        if unfocusedPaneOpacityLabel.stringValue != projection.unfocusedPaneOpacityText {
            unfocusedPaneOpacityLabel.stringValue = projection.unfocusedPaneOpacityText
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

    private func configureBrowseButton(_ button: NSButton) {
        button.title = "Browse…"
        button.bezelStyle = .push
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func applyWarning(_ warning: String?, label: NSTextField, row: NSGridRow) {
        let shouldHide = warning == nil
        label.isHidden = shouldHide
        row.isHidden = shouldHide
        if let warning, label.stringValue != warning {
            label.stringValue = warning
        }
    }
}

/// Owns the Option-as-Alt control and native keybinding browser.
final class KeyboardPreferencesViewController: PreferencesFormSectionController {
    let optionAsAltControl = NSSegmentedControl(
        labels: ["Native", "Left", "Right", "Both"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let keybindingSearchField = NSSearchField()
    let keybindingActionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let keybindingTable = KeybindingBrowserTableView()
    let keybindingDiagnosticLabel = NSTextField(labelWithString: "")
    let keybindingScrollView = NSScrollView()
    let resetAllItem = NSMenuItem(
        title: "Reset All Key Bindings...",
        action: nil,
        keyEquivalent: ""
    )

    init() {
        super.init(identifier: "KeyboardSection")
        addRow(formRow("Option as Alt", optionAsAltControl))

        keybindingSearchField.placeholderString = "Search Commands"
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
        for (identifier, width) in [("Command", 240.0), ("Shortcuts", 180.0), ("Status", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.width = width
            column.isEditable = false
            keybindingTable.addTableColumn(column)
        }
        keybindingScrollView.documentView = keybindingTable
        keybindingScrollView.hasVerticalScroller = true
        keybindingScrollView.drawsBackground = false

        keybindingActionsButton.addItem(withTitle: "Key Binding Actions")
        keybindingActionsButton.lastItem?.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: "Key Binding Actions"
        )
        keybindingActionsButton.menu?.addItem(resetAllItem)
        let header = NSStackView(views: [keybindingSearchField, keybindingActionsButton])
        header.orientation = .horizontal
        header.spacing = 8
        let browser = NSStackView(views: [header, keybindingDiagnosticLabel, keybindingScrollView])
        browser.orientation = .vertical
        browser.spacing = 10
        addContentView(browser)

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
        keybindingScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: browserWidth).isActive = true
        keybindingScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
    }

    required init?(coder: NSCoder) { nil }
}

/// Owns launch-frozen tailnet listener facts and their config-file note.
final class RemotePreferencesViewController: PreferencesFormSectionController {
    let tailnetConfiguredField = NSTextField()
    let tailnetEndpointField = NSTextField()
    let tailnetStatusField = NSTextField()
    let tailnetNoteLabel = NSTextField(
        labelWithString: "Edit tailnet settings in the config file; they apply at the next launch."
    )

    init() {
        super.init(identifier: "RemoteSection")
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

        addRow(formRow("Tailnet", tailnetConfiguredField))
        addRow(formRow("Endpoint", tailnetEndpointField))
        addRow(formRow("Listener", tailnetStatusField))
        addRow([NSGridCell.emptyContentView, tailnetNoteLabel])
    }

    required init?(coder: NSCoder) { nil }

    /// Applies listener facts without making the launch-frozen fields editable.
    func apply(_ projection: PreferencesPanelProjection) {
        if tailnetConfiguredField.stringValue != projection.tailnetConfiguredText {
            tailnetConfiguredField.stringValue = projection.tailnetConfiguredText
        }
        if tailnetEndpointField.stringValue != projection.tailnetEndpointText {
            tailnetEndpointField.stringValue = projection.tailnetEndpointText
        }
        if tailnetStatusField.stringValue != projection.tailnetStatusText {
            tailnetStatusField.stringValue = projection.tailnetStatusText
        }
    }
}
