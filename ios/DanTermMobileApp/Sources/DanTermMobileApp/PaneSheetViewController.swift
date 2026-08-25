// The transient group, tab, and pane outline the phone can navigate.
//
// It replaces the permanent pane table: choosing a pane is something the user does now and
// then, so the list costs the terminal no vertical space and appears only while the choice
// is being made.
//
// It decides nothing about the roster. It reports the target a row already names and paints
// the outline it is given. Only the set of tabs expanded during this presentation lives here.
import ChipArtwork
import DanTermMobileKit
import DanTermProtocol
import UIKit

/// Presents the pane outline for as long as the user is choosing a pane.
@MainActor
final class PaneSheetViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    /// Reports the pane the user picked. The sheet dismisses itself on the way out, so a
    /// pick is one gesture and leaves the terminal on screen.
    var onSelect: ((PaneId) -> Void)?

    private let table = UITableView(frame: .zero, style: .plain)
    /// The hierarchy the table is showing, replaced whenever the projection moves.
    private var outline: MobilePaneOutline
    private var selectedPaneId: PaneId?
    /// The only navigation fact the sheet owns, bounded by this presentation's lifetime.
    private var expandedTabIds: Set<TabId>

    /// Seeds the outline and opens the projected current tab before the first layout.
    init(outline: MobilePaneOutline, selected: PaneId?) {
        self.outline = outline
        selectedPaneId = selected
        expandedTabIds = Set([outline.initiallyExpandedTabId].compactMap { $0 })
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Paints the outline as it stands while preserving only expansions that remain valid.
    func show(outline: MobilePaneOutline, selected: PaneId?) {
        guard self.outline != outline || selectedPaneId != selected else { return }
        let expandable = Set(outline.groups.flatMap(\.tabs).filter(\.isExpandable).map(\.tabId))
        expandedTabIds.formIntersection(expandable)
        self.outline = outline
        selectedPaneId = selected
        if isViewLoaded { table.reloadData() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A presented controller does not inherit the presenter's override, and the sheet
        // rises over the terminal's black, so it states the dark appearance itself.
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(white: 0.11, alpha: 1)
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 52
        table.register(UITableViewCell.self, forCellReuseIdentifier: "outline")
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        outline.groups.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(in: outline.groups[section]).count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        outline.groups[section].title.text
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "outline", for: indexPath)
        var content = cell.defaultContentConfiguration()
        switch rows(in: outline.groups[indexPath.section])[indexPath.row] {
        case .tab(let tab):
            content.text = tab.title.text
            content.image = UIImage(systemName: "rectangle.stack")
            cell.indentationLevel = 0
            if tab.isExpandable {
                cell.accessoryView = expansionButton(for: tab)
                cell.accessoryType = .none
            } else {
                cell.accessoryView = nil
                cell.accessoryType = tab.selectionPaneId == selectedPaneId ? .checkmark : .none
            }
        case .pane(let pane):
            content.text = pane.title.text
            content.image = chipImage(for: pane.chip)
            // Every pane row reserves the chip's box whether or not its image was drawn,
            // so a failed raster does not pull its title left out of the column.
            content.imageProperties.reservedLayoutSize = CGSize(
                width: Self.chipEdge,
                height: Self.chipEdge
            )
            cell.indentationLevel = 2
            cell.accessoryView = nil
            cell.accessoryType = pane.paneId == selectedPaneId ? .checkmark : .none
        }
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        return cell
    }

    /// One visible row, carrying the target the projection assigned it.
    private enum Row {
        case tab(MobilePaneTab)
        case pane(MobilePaneEntry)

        var selectionPaneId: PaneId {
            switch self {
            case .tab(let tab): tab.selectionPaneId
            case .pane(let pane): pane.paneId
            }
        }
    }

    /// Expands each tab into its panes only while this sheet says it is open.
    private func rows(in group: MobilePaneGroup) -> [Row] {
        group.tabs.flatMap { tab in
            var rows: [Row] = [.tab(tab)]
            if expandedTabIds.contains(tab.tabId) { rows += tab.panes.map(Row.pane) }
            return rows
        }
    }

    /// Makes the tab row's disclosure a separate gesture from selecting the row target.
    private func expansionButton(for tab: MobilePaneTab) -> UIButton {
        let button = UIButton(type: .system)
        let expanded = expandedTabIds.contains(tab.tabId)
        button.setImage(UIImage(systemName: expanded ? "chevron.down" : "chevron.right"), for: .normal)
        button.accessibilityLabel = expanded ? "Collapse \(tab.title.text)" : "Expand \(tab.title.text)"
        button.addAction(UIAction { [weak self] _ in
            self?.toggleExpansion(of: tab.tabId)
        }, for: .touchUpInside)
        return button
    }

    /// Changes the sheet-local expansion and repaints only the group that owns the tab.
    private func toggleExpansion(of tabId: TabId) {
        if expandedTabIds.remove(tabId) == nil { expandedTabIds.insert(tabId) }
        guard let section = outline.groups.firstIndex(where: { group in
            group.tabs.contains { $0.tabId == tabId }
        }) else { return }
        table.reloadSections(IndexSet(integer: section), with: .automatic)
    }

    /// The chip's edge in points. Sized against the row's own two lines of text rather
    /// than borrowed from the Mac sidebar's metric, which answers to a different row.
    private static let chipEdge: CGFloat = 18

    /// Wraps the chip the roster named in the image type a table cell wants.
    ///
    /// The colors are the agent's own: this row stands for one pane, as the macOS
    /// sidebar row does, not for one pane among a tab's others. The appearance comes
    /// from the trait collection rather than a constant, so the chip follows the
    /// style this sheet overrides itself to instead of drifting from it.
    private func chipImage(for kind: ChipKind) -> UIImage? {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 1
        let appearance: ChipAppearance = traitCollection.userInterfaceStyle == .light ? .light : .dark
        guard let drawn = kind.drawnImage(edge: Self.chipEdge, scale: scale, appearance: appearance)
        else { return nil }
        return UIImage(cgImage: drawn, scale: scale, orientation: .up)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let row = rows(in: outline.groups[indexPath.section])[indexPath.row]
        onSelect?(row.selectionPaneId)
        dismiss(animated: true)
    }
}
