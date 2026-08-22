// Remote theme picker: a sheet presented on the preferences panel that lets
// users browse and select a theme for remote (SSH) sessions. Uses the
// same swatch preview and search filtering as the sidebar theme browser.
import Cocoa

class RemoteThemePickerSheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// Called when the user picks a theme. The sheet dismisses itself before calling.
    var onSelect: ((String) -> Void)?

    /// Pre-selects this theme on appear.
    var currentThemeName: String?

    let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    let tableView = NSTableView()
    /// Built in `loadView`; the row owns the buttons, so these read them back
    /// for the enable/disable logic and the harness.
    private var actionRow: DialogActionRow!
    var selectButton: NSButton { actionRow.button(for: .defaultAction)! }
    var cancelButton: NSButton { actionRow.button(for: .cancel)! }

    private var allNames: [String]
    private var filteredNames: [String]

    /// Test entry point: inject theme names so the harness can assert row
    /// behavior without depending on the app bundle catalog.
    init(themeNames: [String] = ThemeCatalog.shared.names) {
        allNames = themeNames
        filteredNames = themeNames
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

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

        actionRow = DialogActionRow(actions: [
            DialogAction(title: "Select", role: .defaultAction, isEnabled: false) { [weak self] in
                self?.commitSelection()
            },
            DialogAction(title: "Cancel", role: .cancel) { [weak self] in self?.cancel() },
        ])

        // Layout
        for v in [searchField, scrollView, actionRow] as [NSView] {
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
            scrollView.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -12),

            actionRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            actionRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            actionRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
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
        filteredNames = filteredThemeNames(allNames, query: sender.stringValue)
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
        let name = filteredNames[row]
        return ThemeBrowserCellView.themeCell(
            in: tableView,
            reuseIdentifier: NSUserInterfaceItemIdentifier("ThemePickerCell"),
            themeName: name,
            isCurrentTheme: name == currentThemeName
        )
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        searchChanged(searchField)
    }
}
