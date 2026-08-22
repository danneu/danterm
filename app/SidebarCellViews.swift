// Typed sidebar row cells. Each cell owns the complete view tree that its projection paints,
// so row updates cannot silently skip a child because an identifier lookup stopped matching.
import ChipArtwork
import Cocoa

/// Owns every painted child of a sidebar tab row and applies one complete tab projection.
final class SidebarTabCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("TabCell")

    let colorStripe: NSView
    let jumpBadge: NSTextField
    let chip: ChipView
    let titleField: NSTextField
    let leadingStack: NSStackView
    let paneStrip: PaneStripView
    let alertBadge: BadgeLabel
    let accessoryStack: NSStackView

    init(textFieldDelegate: NSTextFieldDelegate) {
        let colorStripe = NSView()
        colorStripe.translatesAutoresizingMaskIntoConstraints = false
        colorStripe.wantsLayer = true
        colorStripe.isHidden = true

        let jumpBadge = NSTextField(labelWithString: "")
        jumpBadge.translatesAutoresizingMaskIntoConstraints = false
        jumpBadge.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        jumpBadge.textColor = .alternateSelectedControlTextColor
        jumpBadge.alignment = .center
        jumpBadge.wantsLayer = true
        jumpBadge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        jumpBadge.layer?.cornerRadius = 5
        jumpBadge.layer?.masksToBounds = true
        jumpBadge.isHidden = true
        jumpBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let chip = ChipView(kind: .terminal, edge: ChipArtwork.sidebarSize)

        let titleField = SingleLineLabel.make()
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleField.isEditable = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.delegate = textFieldDelegate

        let leadingStack = NSStackView(views: [jumpBadge, chip, titleField])
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        leadingStack.orientation = .horizontal
        leadingStack.alignment = .centerY
        leadingStack.spacing = 4
        leadingStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let paneStrip = PaneStripView()

        let alertBadge = BadgeLabel()
        let accessoryStack = NSStackView(views: [alertBadge])
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.orientation = .horizontal
        accessoryStack.alignment = .top
        accessoryStack.spacing = 3
        accessoryStack.setHuggingPriority(.required, for: .horizontal)
        accessoryStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        self.colorStripe = colorStripe
        self.jumpBadge = jumpBadge
        self.chip = chip
        self.titleField = titleField
        self.leadingStack = leadingStack
        self.paneStrip = paneStrip
        self.alertBadge = alertBadge
        self.accessoryStack = accessoryStack

        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        textField = titleField
        addSubview(colorStripe)
        addSubview(leadingStack)
        addSubview(paneStrip)
        addSubview(accessoryStack)

        NSLayoutConstraint.activate([
            colorStripe.leadingAnchor.constraint(equalTo: leadingAnchor),
            colorStripe.topAnchor.constraint(equalTo: topAnchor),
            colorStripe.bottomAnchor.constraint(equalTo: bottomAnchor),
            colorStripe.widthAnchor.constraint(equalToConstant: 5),
            accessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            accessoryStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            leadingStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leadingStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            leadingStack.trailingAnchor.constraint(equalTo: accessoryStack.leadingAnchor, constant: -4),
            paneStrip.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            // Equal, not <=: the strip has no intrinsic width and fits itself
            // to whatever it is given, so it needs a definite one.
            paneStrip.trailingAnchor.constraint(
                equalTo: accessoryStack.leadingAnchor, constant: -4),
            paneStrip.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            jumpBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            jumpBadge.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Repaints the row while leaving the title lane under the field editor's control.
    func apply(_ tab: SidebarTabProjection, isEditingTitle: Bool) {
        if !isEditingTitle {
            titleField.stringValue = tab.displayTitle.text
            jumpBadge.stringValue = tab.jumpKey.map { String($0).uppercased() } ?? ""
            jumpBadge.isHidden = tab.jumpKey == nil
        }

        paneStrip.chips = tab.paneChips
        alertBadge.updateBadge(count: tab.unreadAlertCount)
        chip.kind = tab.chipKind

        if let color = tab.color {
            colorStripe.layer?.backgroundColor = color.nsColor.cgColor
            colorStripe.isHidden = false
        } else {
            colorStripe.layer?.backgroundColor = nil
            colorStripe.isHidden = true
        }
    }
}

/// Owns every painted child of a sidebar group row and applies one complete group projection.
final class SidebarGroupCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("GroupCell")

    let titleField: NSTextField
    let alertBadge: BadgeLabel
    let tabCountBadge: BadgeLabel
    let caretButton: NSButton
    let accessoryStack: NSStackView
    let separator: NSBox

    init(
        textFieldDelegate: NSTextFieldDelegate,
        caretTarget: AnyObject?,
        caretAction: Selector
    ) {
        let titleField = SingleLineLabel.make()
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .preferredFont(forTextStyle: .headline)
        titleField.isEditable = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.delegate = textFieldDelegate

        let alertBadge = BadgeLabel()
        let tabCountBadge = BadgeLabel(color: .systemGray)

        let caretButton = NSButton(
            image: NSImage(
                systemSymbolName: "chevron.right",
                accessibilityDescription: "Toggle Group")!,
            target: caretTarget,
            action: caretAction)
        caretButton.translatesAutoresizingMaskIntoConstraints = false
        caretButton.bezelStyle = .accessoryBarAction
        caretButton.isBordered = false
        caretButton.imageScaling = .scaleProportionallyDown
        caretButton.contentTintColor = .tertiaryLabelColor

        let accessoryStack = NSStackView(views: [alertBadge, tabCountBadge, caretButton])
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.orientation = .horizontal
        accessoryStack.alignment = .centerY
        accessoryStack.spacing = 2
        accessoryStack.setHuggingPriority(.required, for: .horizontal)
        accessoryStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        self.titleField = titleField
        self.alertBadge = alertBadge
        self.tabCountBadge = tabCountBadge
        self.caretButton = caretButton
        self.accessoryStack = accessoryStack
        self.separator = separator

        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        textField = titleField
        addSubview(titleField)
        addSubview(accessoryStack)
        addSubview(separator)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(equalTo: accessoryStack.leadingAnchor, constant: -4),
            accessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            accessoryStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            caretButton.widthAnchor.constraint(equalToConstant: 16),
            caretButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Repaints the row while leaving an actively edited title untouched.
    func apply(_ group: SidebarGroupProjection, isEditingTitle: Bool) {
        if !isEditingTitle {
            titleField.stringValue = group.name.text
        }
        separator.isHidden = group.isFirst
        let symbolName = group.isCollapsed ? "chevron.right" : "chevron.down"
        caretButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Toggle Group")
        alertBadge.updateBadge(count: group.unreadAlertCount)
        alertBadge.isHidden = group.unreadAlertCount == 0 || !group.isCollapsed
        tabCountBadge.stringValue = "\(group.tabCount)"
        tabCountBadge.isHidden = !group.isCollapsed
    }
}
