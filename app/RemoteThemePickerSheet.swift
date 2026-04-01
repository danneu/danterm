// Remote theme picker: a sheet presented on the preferences panel that lets
// users browse and select a Ghostty theme for remote (SSH) sessions. Uses the
// same swatch preview and search filtering as the sidebar theme browser.
import Cocoa

class RemoteThemePickerSheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// Called when the user picks a theme. The sheet dismisses itself before calling.
    var onSelect: ((String) -> Void)?

    /// Pre-selects this theme on appear.
    var currentThemeName: String?

    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let selectButton = NSButton(title: "Select", target: nil, action: nil)

    private var allNames: [String] = ThemeCatalog.shared.names
    private var filteredNames: [String] = ThemeCatalog.shared.names

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))

        searchField.placeholderString = "Filter themes"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(commitSelection)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ThemeName"))
        column.isEditable = false
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        selectButton.target = self
        selectButton.action = #selector(commitSelection)
        selectButton.keyEquivalent = "\r" // Enter
        selectButton.isEnabled = false

        // Layout
        for v in [searchField, scrollView, cancelButton, selectButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),

            cancelButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            selectButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            selectButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        selectCurrentThemeRow()
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Actions

    @objc private func commitSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredNames.count else { return }
        let name = filteredNames[row]
        dismiss()
        onSelect?(name)
    }

    @objc private func cancel() {
        dismiss()
    }

    private func dismiss() {
        guard let sheetWindow = view.window,
              let parent = sheetWindow.sheetParent else { return }
        parent.endSheet(sheetWindow)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            filteredNames = allNames
        } else {
            filteredNames = allNames.filter { $0.lowercased().contains(query) }
        }
        tableView.reloadData()
        selectCurrentThemeRow()
    }

    private func selectCurrentThemeRow() {
        guard let name = currentThemeName,
              let idx = filteredNames.firstIndex(of: name) else {
            tableView.deselectAll(nil)
            selectButton.isEnabled = false
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        tableView.scrollRowToVisible(idx)
        selectButton.isEnabled = true
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredNames.count
    }

    // MARK: - NSTableViewDelegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectButton.isEnabled = row >= 0 && row < filteredNames.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ThemePickerCell")
        let cell: ThemeBrowserCellView
        if let existing = tableView.makeView(withIdentifier: id, owner: nil) as? ThemeBrowserCellView {
            cell = existing
        } else {
            cell = ThemeBrowserCellView()
            cell.identifier = id

            let swatch = ColorSwatchView()
            swatch.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(swatch)
            cell.swatchView = swatch

            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.font = NSFont.systemFont(ofSize: 12)
            text.lineBreakMode = .byTruncatingTail
            cell.addSubview(text)
            cell.textField = text

            NSLayoutConstraint.activate([
                swatch.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                swatch.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                swatch.widthAnchor.constraint(equalToConstant: 50),
                swatch.heightAnchor.constraint(equalTo: cell.heightAnchor),
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                text.trailingAnchor.constraint(equalTo: swatch.leadingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        // Configure cell content
        let name = filteredNames[row]
        if name == currentThemeName {
            cell.textField?.stringValue = "\u{2713} \(name)"
        } else {
            cell.textField?.stringValue = name
        }
        cell.updateTextColor()
        if let tc = ThemeCatalog.shared.colors[name] {
            cell.swatchView?.colors = (tc.background, tc.foreground, tc.accent, tc.palette)
        } else {
            cell.swatchView?.colors = (.clear, .clear, .clear, [])
        }
        return cell
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        searchChanged(searchField)
    }
}
