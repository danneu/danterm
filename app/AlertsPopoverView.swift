/// Popover view controller for the alerts feed.
/// Shows a scrollable list of alert rows with unread dots, relative timestamps,
/// and a "Mark All Read" button. Click a row to activate the alert.

import Cocoa

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

    /// NSTableViewDelegate: build a row from the same projection used for clicks.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < projection.rows.count else { return nil }
        return makeAlertRow(projection.rows[row])
    }

    /// NSTableViewDelegate: activate the alert represented by the selected rendered row.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < projection.rows.count else { return }
        runtime?.send(.activateAlert(alertId: projection.rows[row].id))
        tableView.deselectRow(row)
    }

    private func makeAlertRow(_ alert: AlertRowProjection) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        // Icon
        let iconName = alert.kind == .bell ? "bell.fill" : "message.fill"
        let iconTooltip = alert.kind == .bell ? "Via terminal bell" : "Via OSC 777"
        let icon = NSImageView(image: NSImage(systemSymbolName: iconName, accessibilityDescription: nil)!)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        icon.toolTip = iconTooltip
        row.addSubview(icon)

        // Title
        let titleField = NSTextField(labelWithString: alert.title)
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(titleField)

        // Body
        let bodyField = NSTextField(labelWithString: alert.body)
        bodyField.font = .systemFont(ofSize: NSFont.systemFontSize)
        bodyField.textColor = .secondaryLabelColor
        bodyField.lineBreakMode = .byTruncatingTail
        bodyField.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(bodyField)

        // Time
        let timeField = NSTextField(labelWithString: relativeTime(alert.createdAt))
        timeField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        timeField.textColor = .tertiaryLabelColor
        timeField.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(timeField)

        // Unread dot
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        dot.layer?.cornerRadius = 4
        dot.isHidden = !alert.isUnread
        row.addSubview(dot)

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(sep)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 52),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleField.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: timeField.leadingAnchor, constant: -4),
            bodyField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            bodyField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            bodyField.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -4),
            timeField.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            timeField.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            dot.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            dot.centerYAnchor.constraint(equalTo: bodyField.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            sep.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        return row
    }

    @objc private func showAllToggled() {
        runtime?.send(.setShowAllAlerts(showAllCheckbox.state == .on))
    }

    @objc private func markAllRead() {
        runtime?.send(.markAllAlertsRead)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return "\(days)d"
    }
}
