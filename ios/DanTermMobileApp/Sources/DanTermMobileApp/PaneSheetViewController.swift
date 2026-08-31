// The transient group, tab, and pane outline the phone can navigate.
//
// It replaces the permanent pane table: choosing a pane is something the user does now and
// then, so the list costs the terminal no vertical space and appears only while the choice
// is being made.
//
// It decides nothing about the roster. It reports the target an item already names and paints
// the outline it is given. UIKit owns the hierarchy, disclosure controls, and expansion state.
import ChipArtwork
import DanTermMobileKit
import DanTermProtocol
import UIKit

/// Presents the pane outline for as long as the user is choosing a pane.
@MainActor
final class PaneSheetViewController: UIViewController, UICollectionViewDelegate {
    /// Reports the pane the user picked. The sheet dismisses itself on the way out, so a
    /// pick is one gesture and leaves the terminal on screen.
    var onSelect: ((PaneId) -> Void)?

    /// The outline's own row identity is the data source's item identity, so a row the
    /// outline names can be refreshed without translation.
    private typealias Item = MobilePaneRow

    private let collectionView: UICollectionView
    /// The hierarchy the collection view is showing, replaced whenever the projection moves.
    private var outline: MobilePaneOutline
    private var selectedPaneId: PaneId?
    private var dataSource: UICollectionViewDiffableDataSource<GroupId, Item>!
    private var needsInitialSelectionPositioning = true

    /// Seeds the outline and opens the projected current tab before the first layout.
    init(outline: MobilePaneOutline, selected: PaneId?) {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.headerMode = .firstItemInSection
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        self.outline = outline
        selectedPaneId = selected
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Paints the outline as it stands, redrawing rows in place whenever it can.
    ///
    /// Laying the list out again returns the reader to the top of it, and an agent renames
    /// its pane several times a second, so a rebuild is reserved for an update that moves
    /// the rows themselves.
    func show(outline: MobilePaneOutline, selected: PaneId?) {
        guard self.outline != outline || selectedPaneId != selected else { return }
        guard isViewLoaded else {
            self.outline = outline
            selectedPaneId = selected
            return
        }
        let refreshedRows = outline.rowsNeedingRefresh(
            since: self.outline,
            previousSelection: selectedPaneId,
            selection: selected
        )
        // Read the system's expansion state against the outline still on screen.
        let expandedTabIds = refreshedRows == nil ? currentExpandedTabIds() : []
        self.outline = outline
        selectedPaneId = selected
        if let refreshedRows {
            refresh(refreshedRows)
        } else {
            applyOutline(expanding: expandedTabIds, animatingDifferences: true)
        }
    }

    /// Redraws the named rows from the outline now held, leaving the list's scroll
    /// position, expansions, and every other row untouched.
    private func refresh(_ rows: Set<Item>) {
        var snapshot = dataSource.snapshot()
        // A collapsed tab's panes are absent from the flattened snapshot, and they are
        // configured from the outline when the tab next opens.
        let visible = rows.filter { snapshot.indexOfItem($0) != nil }
        guard !visible.isEmpty else { return }
        snapshot.reconfigureItems(Array(visible))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // A presented controller does not inherit the presenter's override, and the sheet
        // rises over the terminal's black, so it states the dark appearance itself.
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(white: 0.11, alpha: 1)
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, item in
            self?.configure(cell, for: item)
        }
        dataSource = UICollectionViewDiffableDataSource<GroupId, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: registration,
                for: indexPath,
                item: item
            )
        }

        let expandedTabId = outline.initiallyExpandedTabId(for: selectedPaneId)
        let initiallyExpanded = Set([expandedTabId].compactMap { $0 })
        applyOutline(expanding: initiallyExpanded, animatingDifferences: false)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // UIKit has now attached and laid out the medium sheet, so its final viewport can
        // satisfy the requested scroll position instead of later replacing an early offset.
        view.layoutIfNeeded()
        positionInitialSelectionIfNeeded()
    }

    /// Rebuilds the outer sections and their UIKit-owned hierarchical snapshots.
    private func applyOutline(
        expanding expandedTabIds: Set<TabId>,
        animatingDifferences: Bool
    ) {
        // This snapshot names sections and no items, so applying it empties the list and
        // drops its scroll position. Only a change in the sections themselves earns that;
        // the section snapshots below carry every item.
        let sectionIds = outline.groups.map(\.groupId)
        if dataSource.snapshot().sectionIdentifiers != sectionIds {
            var snapshot = NSDiffableDataSourceSnapshot<GroupId, Item>()
            snapshot.appendSections(sectionIds)
            dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
        }

        for group in outline.groups {
            var section = NSDiffableDataSourceSectionSnapshot<Item>()
            let groupItem = Item.group(group.groupId)
            section.append([groupItem])
            let tabItems = group.tabs.map { Item.tab($0.tabId) }
            section.append(tabItems, to: groupItem)
            for tab in group.tabs where tab.isExpandable {
                section.append(tab.panes.map { Item.pane($0.paneId) }, to: .tab(tab.tabId))
            }
            section.expand([groupItem])
            section.expand(group.tabs.compactMap { tab in
                tab.isExpandable && expandedTabIds.contains(tab.tabId) ? .tab(tab.tabId) : nil
            })
            dataSource.apply(
                section,
                to: group.groupId,
                animatingDifferences: animatingDifferences
            )
        }
    }

    /// Reads the system outline state before a roster update replaces its snapshots.
    private func currentExpandedTabIds() -> Set<TabId> {
        var result: Set<TabId> = []
        for group in outline.groups {
            let section = dataSource.snapshot(for: group.groupId)
            for tab in group.tabs {
                let item = Item.tab(tab.tabId)
                if section.contains(item), section.isExpanded(item) { result.insert(tab.tabId) }
            }
        }
        return result
    }

    /// Configures one list cell from the projected outline and lets UIKit indent it.
    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        var content = cell.defaultContentConfiguration()
        switch item {
        case .group(let groupId):
            content.text = group(with: groupId)?.title.text
            cell.accessories = []
        case .tab(let tabId):
            guard let tab = tab(with: tabId) else { return }
            content.text = tab.title.text
            content.image = UIImage(systemName: "rectangle.stack")
            if tab.isExpandable {
                let options = UICellAccessory.OutlineDisclosureOptions(style: .cell)
                cell.accessories = [.outlineDisclosure(options: options)]
            } else {
                cell.accessories = tab.selectionPaneId == selectedPaneId ? [.checkmark()] : []
            }
        case .pane(let paneId):
            guard let pane = pane(with: paneId) else { return }
            content.text = pane.title.text
            content.image = chipImage(for: pane.chip)
            // Every pane row reserves the chip's box whether or not its image was drawn,
            // so a failed raster does not pull its title left out of the column.
            content.imageProperties.reservedLayoutSize = CGSize(
                width: Self.chipEdge,
                height: Self.chipEdge
            )
            cell.accessories = pane.paneId == selectedPaneId ? [.checkmark()] : []
        }
        cell.contentConfiguration = content
        cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
    }

    /// Finds a group by the identity carried in a diffable item.
    private func group(with groupId: GroupId) -> MobilePaneGroup? {
        outline.groups.first { $0.groupId == groupId }
    }

    /// Finds a tab by the identity carried in a diffable item.
    private func tab(with tabId: TabId) -> MobilePaneTab? {
        outline.groups.lazy.flatMap(\.tabs).first { $0.tabId == tabId }
    }

    /// Finds a pane by the identity carried in a diffable item.
    private func pane(with paneId: PaneId) -> MobilePaneEntry? {
        outline.groups.lazy.flatMap(\.tabs).flatMap(\.panes).first { $0.paneId == paneId }
    }

    /// Scrolls once after the sheet has its final presentation geometry.
    private func positionInitialSelectionIfNeeded() {
        guard needsInitialSelectionPositioning, let selectedPaneId else { return }
        collectionView.layoutIfNeeded()
        let item = dataSource.indexPath(for: .pane(selectedPaneId)) != nil
            ? Item.pane(selectedPaneId)
            : outline.groups.lazy
                .flatMap(\.tabs)
                .first(where: { $0.panes.contains { $0.paneId == selectedPaneId } })
                .map { Item.tab($0.tabId) }
        guard let item, let indexPath = dataSource.indexPath(for: item) else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        needsInitialSelectionPositioning = false
    }

    /// The chip's edge in points. Sized against the row's own two lines of text rather
    /// than borrowed from the Mac sidebar's metric, which answers to a different row.
    private static let chipEdge: CGFloat = 18

    /// Wraps the chip the roster named in the image type a list cell wants.
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

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        if case .group = item { return false }
        return true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        let selection: PaneId?
        switch item {
        case .group:
            selection = nil
        case .tab(let tabId):
            selection = tab(with: tabId)?.selectionPaneId
        case .pane(let paneId):
            selection = paneId
        }
        guard let selection else { return }
        onSelect?(selection)
        dismiss(animated: true)
    }
}
