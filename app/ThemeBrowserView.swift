// Theme browser panel: an overlay anchored to the right side of the content area.
// Lists the whole DanTerm theme catalog with search filtering. Selecting a theme
// (via click or keyboard navigation) applies it to the focused pane immediately.
import Cocoa

enum ThemeBrowserFocusTarget {
    case searchField
    case table
}

/// Minimal clipboard surface ThemeBrowserView needs, split out so lifetime
/// tests can observe Copy Name without touching AppKit pasteboard services.
protocol ThemeNamePasteboard: AnyObject {
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: ThemeNamePasteboard {}

/// Table view that builds a fresh context menu per right-click, so the browser
/// never stores a menu that could anchor itself through `representedObject`.
class ThemeBrowserTableView: NSTableView {
    weak var browserView: ThemeBrowserView?

    // NSView: AppKit calls this on right-click / control-click and pops up the returned menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let browserView else { return nil }
        let row = row(at: convert(event.locationInWindow, from: nil))
        let menu = NSMenu()
        browserView.buildThemeContextMenu(into: menu, forRow: row)
        return menu.items.isEmpty ? nil : menu
    }
}

class ThemeBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var runtime: AppRuntime?

    private let backgroundView: NSVisualEffectView
    private let headerLabel: NSTextField
    let resetButton: NSButton
    let closeButton: NSButton
    let searchField: NSSearchField
    private let scrollView: NSScrollView
    let tableView: ThemeBrowserTableView

    private var allNames: [String] = []
    private var filteredNames: [String] = []
    private var currentThemeName: String?
    /// Pasteboard seam for Copy Name. Production uses the general pasteboard;
    /// tests inject a recorder so assertions never touch clipboard services.
    var pasteboard: ThemeNamePasteboard = NSPasteboard.general

    /// Strong context-menu payload that keeps this ephemeral browser alive for
    /// the menu item's lifetime while carrying the stable copied theme name.
    final class MenuPayload {
        let themeName: String
        let anchor: ThemeBrowserView

        init(themeName: String, anchor: ThemeBrowserView) {
            self.themeName = themeName
            self.anchor = anchor
        }
    }

    /// Designated initializer with an injected theme-name list so tests can
    /// assert row behavior without depending on the app bundle catalog.
    init(frame frameRect: NSRect = .zero, themeNames: [String]) {
        backgroundView = NSVisualEffectView()
        backgroundView.material = .sidebar
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active

        headerLabel = NSTextField(labelWithString: "Themes")
        headerLabel.font = .preferredFont(forTextStyle: .headline)
        headerLabel.textColor = .labelColor

        // "Reset" clears the pane's theme override, reverting it to the configured default theme.
        resetButton = NSButton(title: "Reset", target: nil, action: nil)
        resetButton.bezelStyle = .inline
        resetButton.controlSize = .small
        resetButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        resetButton.isHidden = true

        closeButton = NSButton()
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.contentTintColor = .secondaryLabelColor

        searchField = NSSearchField()
        searchField.placeholderString = "Filter themes"

        tableView = ThemeBrowserTableView()
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .plain

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ThemeName"))
        column.isEditable = false
        tableView.addTableColumn(column)

        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false

        addSubview(backgroundView)
        addSubview(headerLabel)
        addSubview(resetButton)
        addSubview(closeButton)
        addSubview(searchField)
        addSubview(scrollView)

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 250),

            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),

            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            resetButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            resetButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),

            closeButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            searchField.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        resetButton.target = self
        resetButton.action = #selector(resetTheme)

        closeButton.target = self
        closeButton.action = #selector(closeBrowser)

        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.browserView = self

        allNames = themeNames
        filteredNames = allNames
    }

    /// Production entry point: theme names come from the bundled catalog.
    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, themeNames: ThemeCatalog.shared.names)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Public

    /// Reload all rows when the browser is first opened.
    func reloadTable() {
        tableView.reloadData()
    }

    /// Single entry point the reconciler uses to push focused-pane theme content.
    /// Filter text and focus stay view-local.
    func apply(_ proj: ThemeBrowserProjection) {
        let old = currentThemeName
        currentThemeName = proj.currentThemeName
        resetButton.isHidden = currentThemeName == nil
        var rows = IndexSet()
        if let old, let idx = filteredNames.firstIndex(of: old) { rows.insert(idx) }
        if let currentThemeName, let idx = filteredNames.firstIndex(of: currentThemeName) {
            rows.insert(idx)
        }
        if !rows.isEmpty {
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        }
        selectCurrentThemeRow()
    }

    /// Check whether this browser currently owns the window's first responder.
    /// NSSearchField gotcha: when focused, window.firstResponder is the field
    /// editor (NSTextView), not the search field itself.
    func captureFocusTarget() -> ThemeBrowserFocusTarget? {
        guard let responder = window?.firstResponder else { return nil }
        if let tv = responder as? NSTextView,
           tv === window?.fieldEditor(false, for: searchField) {
            return .searchField
        }
        if responder as AnyObject === tableView { return .table }
        return nil
    }

    /// Restore focus to the given target after reattachment.
    func restoreFocus(_ target: ThemeBrowserFocusTarget) {
        switch target {
        case .searchField: window?.makeFirstResponder(searchField)
        case .table: window?.makeFirstResponder(tableView)
        }
    }

    // MARK: - Actions

    /// Clear the pane's theme override, reverting it to the configured default theme.
    @objc private func resetTheme() {
        guard currentThemeName != nil else { return }
        guard let runtime = runtime,
              let tab = selectedTab(in: runtime.model) else { return }
        runtime.send(.setPaneTheme(paneId: tab.focusedPaneId, themeName: nil))
    }

    @objc private func closeBrowser() {
        runtime?.toggleThemeBrowser()
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

    /// Select and scroll to the row matching the current theme.
    private func selectCurrentThemeRow() {
        guard let name = currentThemeName,
              let idx = filteredNames.firstIndex(of: name) else {
            tableView.deselectAll(nil)
            return
        }
        guard tableView.selectedRow != idx else { return }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        tableView.scrollRowToVisible(idx)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredNames.count
    }

    // MARK: - NSTableViewDelegate

    // Selection-driven preview: fires for both click and keyboard navigation.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredNames.count else { return }
        let name = filteredNames[row]
        guard name != currentThemeName else { return }
        guard let runtime = runtime,
              let tab = selectedTab(in: runtime.model) else { return }
        runtime.send(.setPaneTheme(paneId: tab.focusedPaneId, themeName: name))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let name = filteredNames[row]
        return ThemeBrowserCellView.themeCell(
            in: tableView,
            reuseIdentifier: NSUserInterfaceItemIdentifier("ThemeCell"),
            themeName: name,
            isCurrentTheme: name == currentThemeName
        )
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        searchChanged(searchField)
    }

    // MARK: - Context menu

    /// Fill `menu` with the right-click items for `row`, using NSTableView
    /// hit-test semantics where -1 means the click missed every row.
    func buildThemeContextMenu(into menu: NSMenu, forRow row: Int) {
        menu.removeAllItems()
        guard row >= 0, row < filteredNames.count else { return }
        let item = NSMenuItem(title: "Copy Name", action: #selector(copyThemeName(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuPayload(themeName: filteredNames[row], anchor: self)
        menu.addItem(item)
    }

    @objc private func copyThemeName(_ sender: NSMenuItem) {
        guard let name = (sender.representedObject as? MenuPayload)?.themeName else { return }
        pasteboard.clearContents()
        pasteboard.setString(name, forType: .string)
    }
}
