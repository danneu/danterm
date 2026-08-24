// Alerts popover views. The typed row cell owns every painted child so reuse
// cannot leave stale alert fields behind.

import Cocoa

/// Owns the complete alert-row hierarchy and applies one complete row projection.
final class AlertCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AlertCell")

    let iconView: NSImageView
    let titleField: NSTextField
    let bodyField: NSTextField
    let timeField: NSTextField
    let unreadDot: NSView
    let separator: NSBox

    override init(frame frameRect: NSRect) {
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor

        let titleField = SingleLineLabel.make()
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        let bodyField = NSTextField(labelWithString: "")
        bodyField.font = .systemFont(ofSize: NSFont.systemFontSize)
        bodyField.textColor = .secondaryLabelColor
        bodyField.lineBreakMode = .byTruncatingTail
        bodyField.translatesAutoresizingMaskIntoConstraints = false

        let timeField = NSTextField(labelWithString: "")
        timeField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        timeField.textColor = .tertiaryLabelColor
        timeField.translatesAutoresizingMaskIntoConstraints = false

        let unreadDot = NSView()
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        unreadDot.wantsLayer = true
        unreadDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        unreadDot.layer?.cornerRadius = 4

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        self.iconView = iconView
        self.titleField = titleField
        self.bodyField = bodyField
        self.timeField = timeField
        self.unreadDot = unreadDot
        self.separator = separator

        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        textField = titleField
        addSubview(iconView)
        addSubview(titleField)
        addSubview(bodyField)
        addSubview(timeField)
        addSubview(unreadDot)
        addSubview(separator)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: timeField.leadingAnchor, constant: -4),
            bodyField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            bodyField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            bodyField.trailingAnchor.constraint(lessThanOrEqualTo: unreadDot.leadingAnchor, constant: -4),
            timeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            timeField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            unreadDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            unreadDot.centerYAnchor.constraint(equalTo: bodyField.centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Replaces every variable presentation field with one projected alert row.
    func apply(_ alert: AlertRowProjection) {
        let iconName: String
        let iconDescription: String
        let iconTooltip: String
        switch alert.kind {
        case .bell:
            iconName = "bell.fill"
            iconDescription = "Bell alert"
            iconTooltip = "Via terminal bell"
        case .desktopNotification:
            iconName = "message.fill"
            iconDescription = "Desktop notification alert"
            iconTooltip = "Via OSC 777"
        }

        iconView.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: iconDescription)
        iconView.toolTip = iconTooltip
        titleField.stringValue = alert.title.text
        bodyField.stringValue = alert.body
        timeField.stringValue = alert.ageText
        unreadDot.isHidden = !alert.isUnread
    }
}

/// Coordinates the alerts popover controls, rows, and selection routing.
class AlertsPopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var runtime: AppRuntime?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "Alerts")
    private let markAllButton = NSButton(title: "Mark All Read", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No alerts")
    private let showAllCheckbox = NSButton(checkboxWithTitle: "Show all", target: nil, action: nil)
    private var projection = AlertsPopoverProjection(
        rows: [], showAll: false, markAllVisible: false, emptyText: "No unread alerts")

    override func loadView() {
        let size = NSSize(width: 320, height: 400)
        preferredContentSize = size

        // Use a wrapper that owns Auto Layout sizing. The inner container
        // pins to all edges and carries the width constraint so NSPopover
        // measures correctly.
        let wrapper = NSView(frame: NSRect(origin: .zero, size: size))
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)

        // Header
        headerLabel.font = .preferredFont(forTextStyle: .headline)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        markAllButton.target = self
        markAllButton.action = #selector(markAllRead)
        markAllButton.bezelStyle = .accessoryBarAction
        markAllButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        markAllButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(markAllButton)

        // Show all toggle
        showAllCheckbox.target = self
        showAllCheckbox.action = #selector(showAllToggled)
        showAllCheckbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        showAllCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(showAllCheckbox)

        // Table view with single column, no header
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("alert"))
        column.width = size.width
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Empty state
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            // Pin container to wrapper edges
            container.topAnchor.constraint(equalTo: wrapper.topAnchor),
            container.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            // Fixed width drives the popover size
            container.widthAnchor.constraint(equalToConstant: size.width),
            container.heightAnchor.constraint(equalToConstant: size.height),

            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            markAllButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            markAllButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            showAllCheckbox.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            showAllCheckbox.leadingAnchor.constraint(equalTo: headerLabel.trailingAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        self.view = wrapper
    }

    /// Render the latest model-derived popover state pushed by the reconciler.
    func apply(_ projection: AlertsPopoverProjection) {
        self.projection = projection
        showAllCheckbox.state = projection.showAll ? .on : .off
        if let emptyText = projection.emptyText {
            emptyLabel.stringValue = emptyText
            emptyLabel.isHidden = false
            scrollView.isHidden = true
        } else {
            emptyLabel.isHidden = true
            scrollView.isHidden = false
        }

        markAllButton.isHidden = !projection.markAllVisible
        tableView.reloadData()
    }

    // MARK: - NSTableViewDataSource

    /// NSTableViewDataSource: render one row for each projected alert.
    func numberOfRows(in tableView: NSTableView) -> Int {
        return projection.rows.count
    }

    // MARK: - NSTableViewDelegate

    /// NSTableViewDelegate: paint a reusable row from the projection used for clicks.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < projection.rows.count else { return nil }
        let cell = tableView.makeView(
            withIdentifier: AlertCellView.reuseIdentifier,
            owner: nil) as? AlertCellView ?? AlertCellView()
        cell.apply(projection.rows[row])
        return cell
    }

    /// NSTableViewDelegate: activate the alert represented by the selected rendered row.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < projection.rows.count else { return }
        runtime?.send(.activateAlert(alertId: projection.rows[row].id))
        tableView.deselectRow(row)
    }

    @objc private func showAllToggled() {
        runtime?.send(.setShowAllAlerts(showAllCheckbox.state == .on))
    }

    @objc private func markAllRead() {
        runtime?.send(.markAllAlertsRead)
    }

}
