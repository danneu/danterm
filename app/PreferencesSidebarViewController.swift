// Owns the native source-list navigation for the Settings window. Section
// state remains model-owned; this controller only presents projections and
// reports user proposals.
import Cocoa

/// Presents every model-defined Settings section without accepting local selection state.
final class PreferencesSidebarViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate {
    let tableView = NSTableView()
    var onSelect: ((PreferencesSection) -> Void)?

    var selectedSection: PreferencesSection? {
        section(at: tableView.selectedRow)
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SettingsSection"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view = scrollView
    }

    /// Applies model selection without sending the same selection back to the model.
    func apply(_ section: PreferencesSection) {
        guard let row = PreferencesSection.allCases.firstIndex(of: section) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        PreferencesSection.allCases.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let section = section(at: row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SettingsSectionCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        cell.textField?.stringValue = section.title
        cell.imageView?.image = NSImage(
            systemSymbolName: section.systemSymbolName,
            accessibilityDescription: section.title
        )
        return cell
    }

    func tableView(_ tableView: NSTableView,
                   selectionIndexesForProposedSelection proposedSelection: IndexSet) -> IndexSet {
        if let row = proposedSelection.first,
           let section = section(at: row),
           section != selectedSection {
            onSelect?(section)
        }
        return tableView.selectedRowIndexes
    }

    private func section(at row: Int) -> PreferencesSection? {
        guard PreferencesSection.allCases.indices.contains(row) else { return nil }
        return PreferencesSection.allCases[row]
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let imageView = NSImageView()
        let textField = NSTextField(labelWithString: "")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
