// Theme browser panel: an overlay anchored to the right side of the content area.
// Lists all available Ghostty themes with search filtering. Selecting a theme
// (via click or keyboard navigation) applies it to the focused pane immediately.
import Cocoa

enum ThemeBrowserFocusTarget {
    case searchField
    case table
}

/// Tiny terminal thumbnail: bg-colored rounded rect with "test█" text in the upper area
/// and a 6-color ANSI palette bar flush against the bottom edge.
private final class ColorSwatchView: NSView {
    var colors: (bg: NSColor, fg: NSColor, accent: NSColor, palette: [NSColor]) =
        (.clear, .clear, .clear, []) {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 2)
        let cornerRadius: CGFloat = 3
        let barHeight: CGFloat = 3

        // Clip to rounded rect so the palette bar respects the corner radius.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

        // Background fill
        colors.bg.setFill()
        NSBezierPath.fill(rect)

        // Palette color bar flush against left/right/bottom edges
        if colors.palette.count == 6 {
            let barY = rect.minY
            let segWidth = rect.width / 6
            for (i, color) in colors.palette.enumerated() {
                color.setFill()
                // Last segment extends to the right edge to avoid rounding gaps.
                let x = rect.minX + segWidth * CGFloat(i)
                let w = (i == 5) ? rect.maxX - x : segWidth
                NSBezierPath.fill(NSRect(x: x, y: barY, width: w, height: barHeight))
            }
        }

        // "test█" sized to fill the area above the bar, with "test" bold.
        let textArea = NSRect(x: rect.minX, y: rect.minY + barHeight, width: rect.width, height: rect.height - barHeight)
        let padding: CGFloat = 3
        let available = textArea.width - padding * 2
        var fontSize: CGFloat = textArea.height
        var textSize = NSSize.zero
        var boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        var regularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        while fontSize > 4 {
            boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            regularFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let probe = NSMutableAttributedString(string: "test", attributes: [.font: boldFont])
            probe.append(NSAttributedString(string: "\u{2588}", attributes: [.font: regularFont]))
            textSize = probe.size()
            if textSize.width <= available && textSize.height <= textArea.height { break }
            fontSize -= 0.5
        }
        let text = NSMutableAttributedString(
            string: "test",
            attributes: [.font: boldFont, .foregroundColor: colors.fg]
        )
        text.append(NSAttributedString(
            string: "\u{2588}",
            attributes: [.font: regularFont, .foregroundColor: colors.accent]
        ))
        let textX = textArea.midX - textSize.width / 2
        let textY = textArea.midY - textSize.height / 2
        text.draw(at: NSPoint(x: textX, y: textY))

        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Theme list cell that follows AppKit's selected/unselected text contrast rules.
private final class ThemeBrowserCellView: NSTableCellView {
    var swatchView: ColorSwatchView?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColor() }
    }

    /// Use the system-selected text color for highlighted rows and the normal label color otherwise.
    func updateTextColor() {
        textField?.textColor = backgroundStyle == .emphasized
            ? .alternateSelectedControlTextColor
            : .labelColor
    }
}

class ThemeBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var runtime: AppRuntime?

    private let backgroundView: NSVisualEffectView
    private let headerLabel: NSTextField
    private let resetButton: NSButton
    private let closeButton: NSButton
    private let searchField: NSSearchField
    private let scrollView: NSScrollView
    private let tableView: NSTableView

    private var allNames: [String] = []
    private var filteredNames: [String] = []
    private var currentThemeName: String?

    override init(frame: NSRect) {
        backgroundView = NSVisualEffectView()
        backgroundView.material = .sidebar
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active

        headerLabel = NSTextField(labelWithString: "Themes")
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        headerLabel.textColor = .labelColor

        // "Reset" clears the DanTerm theme override, reverting to the user's Ghostty config.
        resetButton = NSButton(title: "Reset", target: nil, action: nil)
        resetButton.bezelStyle = .inline
        resetButton.controlSize = .small
        resetButton.font = NSFont.systemFont(ofSize: 11)
        resetButton.isHidden = true

        closeButton = NSButton()
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.contentTintColor = .secondaryLabelColor

        searchField = NSSearchField()
        searchField.placeholderString = "Filter themes"

        tableView = NSTableView()
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

        super.init(frame: frame)

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

        allNames = ThemeCatalog.shared.names
        filteredNames = allNames
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Public

    /// Sync the panel's state with the runtime's focused pane and current theme.
    func reloadFromRuntime() {
        guard let runtime = runtime else { return }
        if let tab = selectedTab(in: runtime.model) {
            currentThemeName = runtime.model.panes[tab.focusedPaneId]?.theme
        } else {
            currentThemeName = nil
        }
        resetButton.isHidden = currentThemeName == nil
        tableView.reloadData()
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

    /// Clear the DanTerm theme override, reverting to the user's Ghostty config.
    @objc private func resetTheme() {
        guard let runtime = runtime,
              let tab = selectedTab(in: runtime.model) else { return }
        runtime.send(.setPaneTheme(paneId: tab.focusedPaneId, themeName: nil))
        currentThemeName = nil
        resetButton.isHidden = true
        tableView.deselectAll(nil)
        tableView.reloadData()
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
        let oldName = currentThemeName
        currentThemeName = name
        resetButton.isHidden = false
        // Partial reload: update only affected rows so selection is not cleared
        var rows = IndexSet(integer: row)
        if let old = oldName, let idx = filteredNames.firstIndex(of: old) { rows.insert(idx) }
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ThemeCell")
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
