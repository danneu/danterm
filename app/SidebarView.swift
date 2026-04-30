import Cocoa

// MARK: - TabColor → NSColor

extension TabColor {
    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .gray: return .systemGray
        }
    }

    /// 12×12 filled circle image for use in menus.
    var swatchImage: NSImage {
        let size = NSSize(width: 12, height: 12)
        return NSImage(size: size, flipped: false) { rect in
            self.nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}

// MARK: - SidebarItem (reference-type wrapper for NSOutlineView identity stability)

class SidebarItem {
    let id: UUID
    var kind: Kind
    enum Kind {
        case group(GroupModel)
        case tab(TabModel)
    }

    init(id: UUID, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

// MARK: - SidebarRowView

/// NSTableRowView subclass that lets us pin a single row to AppKit's
/// emphasized (accent-colored) selection drawing regardless of first-
/// responder state. The terminal pane always holds first responder, so
/// without this the focused tab would draw grey instead of blue.
final class SidebarRowView: NSTableRowView {
    var forceEmphasizedSelection = false { didSet { needsDisplay = true } }

    /// AppKit consults `isEmphasized` when drawing the selection: true
    /// -> accent color, false -> secondary grey. We force true for the
    /// focused row, otherwise pass through so genuine emphasis (e.g.
    /// inline rename promoting the field editor) still works.
    override var isEmphasized: Bool {
        get { (isSelected && forceEmphasizedSelection) || super.isEmphasized }
        set { super.isEmphasized = newValue }
    }
}

// MARK: - SidebarOutlineView

class SidebarOutlineView: NSOutlineView {
    weak var sidebarView: SidebarView?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else { return nil }

        let item = self.item(atRow: clickedRow)
        if let sidebarItem = item as? SidebarItem {
            switch sidebarItem.kind {
            case .group(let group):
                return sidebarView?.contextMenu(for: group)
            case .tab(let tab):
                return sidebarView?.contextMenu(forTab: tab, clickedRow: clickedRow)
            }
        }
        return nil
    }

    /// Hide the native disclosure triangle for all rows. Group rows use a
    /// custom caret button on the right side instead.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        return .zero
    }

    /// Stretch all cells to full width (no indentation for child rows).
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        frame.origin.x = 0
        frame.size.width = bounds.width
        return frame
    }

    /// Returns the tab whose alert badge contains `point` (in outline-view coords), or nil.
    func tabForBadgeHit(at point: NSPoint) -> TabModel? {
        let clickedRow = row(at: point)
        guard clickedRow >= 0,
              let sidebarItem = item(atRow: clickedRow) as? SidebarItem,
              case .tab(let tab) = sidebarItem.kind,
              let cell = view(atColumn: 0, row: clickedRow, makeIfNecessary: false),
              let badge = visibleAlertBadge(in: cell)
        else { return nil }
        let badgePoint = badge.convert(point, from: self)
        return badge.bounds.contains(badgePoint) ? tab : nil
    }

    /// Left-clicking the alert badge clears alerts for that tab.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let tab = tabForBadgeHit(at: point) {
            sidebarView?.runtime?.send(.clearAlertsForTab(tabId: tab.id))
            return
        }
        super.mouseDown(with: event)
    }

override var acceptsFirstResponder: Bool { false }
}

// MARK: - SidebarView

class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let scrollView = NSScrollView()
    private let outlineView = SidebarOutlineView()
    private var isReloading = false
    weak var runtime: AppRuntime?

    // Cached sidebar items for outline view identity stability
    private var tabItemCache: [TabId: SidebarItem] = [:]
    private var groupItemCache: [GroupId: SidebarItem] = [:]
    // Current ordered items (groups and their tabs)
    private var rootItems: [SidebarItem] = []
    private var childItems: [GroupId: [SidebarItem]] = [:]
    private var currentModel: AppModel?

    private var isSingleGroupMode: Bool {
        currentModel?.groups.count == 1
    }

    // Drag types
    private static let tabDragType = NSPasteboard.PasteboardType("com.danterm.tab")
    private static let groupDragType = NSPasteboard.PasteboardType("com.danterm.group")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup() {
        outlineView.sidebarView = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TabColumn"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.style = .fullWidth
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsEmptySelection = false
        outlineView.allowsMultipleSelection = true
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.indentationPerLevel = 0

        outlineView.registerForDraggedTypes([SidebarView.tabDragType, SidebarView.groupDragType, paneDragType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.target = self
        outlineView.doubleAction = #selector(outlineViewDoubleClicked)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

    }

    // MARK: - Actions

    @objc private func outlineViewDoubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        guard let sidebarItem = outlineView.item(atRow: row) as? SidebarItem else { return }
        switch sidebarItem.kind {
        case .tab(let tab):
            beginRenamingTab(tab.id)
        case .group(let group):
            beginRenamingGroup(group.id)
        }
    }

    @objc private func caretClicked(_ sender: NSButton) {
        guard let rawId = objc_getAssociatedObject(sender, &AssociatedKeys.groupId) as? UUID else { return }
        let groupId = GroupId(rawValue: rawId)
        guard let item = groupItemCache[groupId] else { return }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
    }

    // MARK: - Reconcile & Reload

    private func reconcile(model: AppModel) {
        currentModel = model
        var newRootItems: [SidebarItem] = []
        var newChildItems: [GroupId: [SidebarItem]] = [:]

        if isSingleGroupMode {
            // Single group: tabs are root items
            let group = model.groups[0]
            for tab in group.tabs {
                let item = tabItemCache[tab.id] ?? SidebarItem(id: tab.id.rawValue, kind: .tab(tab))
                item.kind = .tab(tab)
                tabItemCache[tab.id] = item
                newRootItems.append(item)
            }
        } else {
            for group in model.groups {
                let groupItem = groupItemCache[group.id] ?? SidebarItem(id: group.id.rawValue, kind: .group(group))
                groupItem.kind = .group(group)
                groupItemCache[group.id] = groupItem
                newRootItems.append(groupItem)

                var tabItems: [SidebarItem] = []
                for tab in group.tabs {
                    let tabItem = tabItemCache[tab.id] ?? SidebarItem(id: tab.id.rawValue, kind: .tab(tab))
                    tabItem.kind = .tab(tab)
                    tabItemCache[tab.id] = tabItem
                    tabItems.append(tabItem)
                }
                newChildItems[group.id] = tabItems
            }
        }

        rootItems = newRootItems
        childItems = newChildItems
    }

    func reload(model: AppModel) {
        isReloading = true
        defer { isReloading = false }

        // Snapshot the user's multi-selection by tab id BEFORE reconcile.
        let priorSelectedTabIds: Set<TabId> = Set(
            outlineView.selectedRowIndexes.compactMap { row in
                guard let item = outlineView.item(atRow: row) as? SidebarItem,
                      case .tab(let tab) = item.kind else { return nil }
                return tab.id
            })

        reconcile(model: model)
        outlineView.reloadData()

        // Restore collapse state
        if !isSingleGroupMode {
            for group in model.groups {
                if let item = groupItemCache[group.id] {
                    if group.isCollapsed {
                        outlineView.collapseItem(item)
                    } else {
                        outlineView.expandItem(item)
                    }
                }
            }
        }

        // Liveness derived from the model — NOT tabItemCache, which isn't
        // pruned in reconcile and would carry stale ids of closed tabs.
        let liveTabIds: Set<TabId> = Set(
            model.groups.flatMap(\.tabs).map(\.id))
        let restoreSet = resolveReloadSelection(
            priorSelectedTabIds: priorSelectedTabIds,
            liveTabIds: liveTabIds,
            selectedTabId: model.selectedTabId)

        // Restore in two phases so AppKit's `selectedRow` (the last
        // selected row, per docs) ends up on `model.selectedTabId` —
        // important for shift-click range start and arrow-key behavior.
        var nonFocusRows = IndexSet()
        var focusRow: Int? = nil
        for id in restoreSet {
            guard let item = tabItemCache[id] else { continue }
            let row = outlineView.row(forItem: item)
            guard row >= 0 else { continue }
            if id == model.selectedTabId {
                focusRow = row
            } else {
                nonFocusRows.insert(row)
            }
        }
        if let f = focusRow {
            if nonFocusRows.isEmpty {
                outlineView.selectRowIndexes(
                    IndexSet(integer: f), byExtendingSelection: false)
            } else {
                outlineView.selectRowIndexes(
                    nonFocusRows, byExtendingSelection: false)
                outlineView.selectRowIndexes(
                    IndexSet(integer: f), byExtendingSelection: true)
            }
        } else if !nonFocusRows.isEmpty {
            outlineView.selectRowIndexes(
                nonFocusRows, byExtendingSelection: false)
        }

        // Scroll the model's currently-selected tab into view.
        if let selectedTabId = model.selectedTabId,
           let item = tabItemCache[selectedTabId] {
            let row = outlineView.row(forItem: item)
            if row >= 0 { outlineView.scrollRowToVisible(row) }
        }
    }

    /// Mutate an existing tab cell's subviews in place (title, subtitle, badge,
    /// color stripe) without destroying the cell view. This avoids the view churn
    /// of reloadData(forRowIndexes:) and preserves the field editor during inline
    /// rename — skipTitle prevents clobbering the text being edited while still
    /// updating badge/subtitle/color. Offscreen or uncached rows are silently
    /// skipped; they'll render from current state when scrolled into view.
    func updateTabRow(tabId: TabId, model: AppModel) {
        currentModel = model
        // Update cached item data
        for group in model.groups {
            if let tab = group.tabs.first(where: { $0.id == tabId }) {
                tabItemCache[tabId]?.kind = .tab(tab)
                break
            }
        }
        guard let item = tabItemCache[tabId] else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              case .tab(let tab) = item.kind else { return }
        let isEditing = cell.textField?.currentEditor() != nil
        configureTabCell(cell, tab: tab, skipTitle: isEditing)
    }

    /// In-place group row update — same rationale as updateTabRow. Updates the
    /// group name, collapse caret, and bell badge without recreating the cell.
    func updateGroupRow(groupId: GroupId, model: AppModel) {
        currentModel = model
        if let group = model.groups.first(where: { $0.id == groupId }) {
            groupItemCache[groupId]?.kind = .group(group)
        }
        guard let item = groupItemCache[groupId] else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              case .group(let group) = item.kind else { return }
        let isEditing = cell.textField?.currentEditor() != nil
        configureGroupCell(cell, group: group, skipTitle: isEditing)
    }

    // MARK: - Inline Rename

    func beginRenamingGroup(_ groupId: GroupId) {
        guard let item = groupItemCache[groupId] else { return }
        beginRenaming(item: item, target: .group(groupId))
    }

    func beginRenamingTab(_ tabId: TabId) {
        guard let item = tabItemCache[tabId] else { return }
        beginRenaming(item: item, target: .tab(tabId))
    }

    private func beginRenaming(item: SidebarItem, target: RenameTarget) {
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        guard let cellView = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return }
        guard let textField = cellView.textField else { return }
        objc_setAssociatedObject(textField, &AssociatedKeys.renameTarget, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        textField.isEditable = true
        textField.selectText(nil)
        window?.makeFirstResponder(textField)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return rootItems.count
        }
        if let sidebarItem = item as? SidebarItem, case .group(let group) = sidebarItem.kind {
            return childItems[group.id]?.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return rootItems[index]
        }
        let sidebarItem = item as! SidebarItem
        guard case .group(let group) = sidebarItem.kind else { return rootItems[0] }
        return childItems[group.id]![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if isSingleGroupMode { return false }
        guard let sidebarItem = item as? SidebarItem else { return false }
        if case .group = sidebarItem.kind { return true }
        return false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let sidebarItem = item as? SidebarItem else { return 40 }
        if case .group = sidebarItem.kind { return 30 }
        return 40
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let sidebarItem = item as? SidebarItem else { return nil }
        switch sidebarItem.kind {
        case .group(let group):
            return makeGroupCell(for: group)
        case .tab(let tab):
            return makeTabCell(for: tab)
        }
    }

    /// NSOutlineViewDelegate: provide our SidebarRowView so the focused
    /// tab stays accent-colored even while the terminal pane holds first
    /// responder. Called for every visible row after each reloadData.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = SidebarRowView()
        let rowTabId: TabId? = {
            guard let sidebarItem = item as? SidebarItem,
                  case .tab(let tab) = sidebarItem.kind else { return nil }
            return tab.id
        }()
        rowView.forceEmphasizedSelection = shouldForceSidebarRowEmphasis(
            rowTabId: rowTabId,
            focusedTabId: currentModel?.selectedTabId)
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let sidebarItem = item as? SidebarItem else { return false }
        if case .tab = sidebarItem.kind { return true }
        return false
    }

    /// With multi-select enabled, AppKit fires this notification for every
    /// row added/removed. `outlineView.selectedRow` is documented as the
    /// last-selected row, which we treat as the "focused" tab. Only
    /// dispatch `.selectTab` when that focus actually changed, so
    /// shift-click range selection doesn't spam redundant messages.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        let row = outlineView.selectedRow
        guard row >= 0,
              let sidebarItem = outlineView.item(atRow: row) as? SidebarItem,
              case .tab(let tab) = sidebarItem.kind else { return }
        if tab.id != currentModel?.selectedTabId {
            runtime?.send(.selectTab(id: tab.id))
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isReloading else { return }
        guard let sidebarItem = notification.userInfo?["NSObject"] as? SidebarItem,
              case .group(let group) = sidebarItem.kind else { return }
        runtime?.send(.toggleGroupCollapse(groupId: group.id))
        applyGroupCollapseState(for: sidebarItem, collapsed: true)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isReloading else { return }
        guard let sidebarItem = notification.userInfo?["NSObject"] as? SidebarItem,
              case .group(let group) = sidebarItem.kind else { return }
        runtime?.send(.toggleGroupCollapse(groupId: group.id))
        applyGroupCollapseState(for: sidebarItem, collapsed: false)
    }

    private func applyGroupCollapseState(for sidebarItem: SidebarItem, collapsed: Bool) {
        guard case .group(let group) = sidebarItem.kind else { return }
        let row = outlineView.row(forItem: sidebarItem)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        if let stack = cell.subviews.first(where: { $0.identifier?.rawValue == "groupAccessoryStack" }) as? NSStackView {
            if let caretButton = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "groupCaretButton" }) as? NSButton {
                let symbolName = collapsed ? "chevron.right" : "chevron.down"
                caretButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Toggle Group")
            }
            if let bellBadge = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "groupBellBadge" }) as? NSTextField {
                let count = groupUnreadAlertCount(for: group, alerts: currentModel?.alerts ?? [])
                bellBadge.updateBadge(count: count)
                if !collapsed { bellBadge.isHidden = true }
            }
            if let tabCountBadge = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "groupTabCountBadge" }) as? NSTextField {
                tabCountBadge.stringValue = "\(group.tabs.count)"
                tabCountBadge.isHidden = !collapsed
            }
        }
    }

    // MARK: - Drag & Drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let sidebarItem = item as? SidebarItem else { return nil }
        let pbItem = NSPasteboardItem()
        switch sidebarItem.kind {
        case .tab(let tab):
            pbItem.setString(tab.id.rawValue.uuidString, forType: SidebarView.tabDragType)
            return pbItem
        case .group(let group):
            pbItem.setString(group.id.rawValue.uuidString, forType: SidebarView.groupDragType)
            return pbItem
        }
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Reject drops in empty space below all rows. NSOutlineView proposes
        // item=nil, index=0 for this region which would show the insertion
        // marker at the top of the list — confusing and not useful.
        if isDragBelowContent(info) { return [] }

        let pb = info.draggingPasteboard

        if pb.string(forType: SidebarView.tabDragType) != nil {
            if isSingleGroupMode {
                if item == nil && index != NSOutlineViewDropOnItemIndex {
                    outlineView.setDropItem(nil, dropChildIndex: index)
                    return .move
                }
                return []
            }
            if let sidebarItem = item as? SidebarItem, case .group(let group) = sidebarItem.kind {
                if index == NSOutlineViewDropOnItemIndex {
                    let childCount = childItems[group.id]?.count ?? 0
                    outlineView.setDropItem(item, dropChildIndex: childCount)
                }
                return .move
            }
            return []
        }

        if pb.string(forType: SidebarView.groupDragType) != nil {
            if item == nil && index >= 0 {
                return .move
            }
            return []
        }

        // Pane drag: accept drops between tab rows (insertion) or onto tab rows (merge)
        if pb.string(forType: paneDragType) != nil {
            if isSingleGroupMode {
                // Drop between root tab items → insertion marker
                if item == nil && index != NSOutlineViewDropOnItemIndex {
                    return .move
                }
                // Drop onto a tab row → merge pane into that tab
                if let sidebarItem = item as? SidebarItem, case .tab = sidebarItem.kind,
                   index == NSOutlineViewDropOnItemIndex {
                    return .move
                }
                return []
            }
            // Multi-group mode
            if let sidebarItem = item as? SidebarItem {
                switch sidebarItem.kind {
                case .group(let group):
                    if index == NSOutlineViewDropOnItemIndex {
                        // Drop onto collapsed group → append at end
                        let childCount = childItems[group.id]?.count ?? 0
                        outlineView.setDropItem(item, dropChildIndex: childCount)
                    }
                    // Drop between group's tabs → insertion marker
                    return .move
                case .tab:
                    if index == NSOutlineViewDropOnItemIndex {
                        // Drop onto a tab row → merge pane into that tab
                        return .move
                    }
                    return []
                }
            }
            return []
        }

        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pb = info.draggingPasteboard

        // Multi-row drags put one NSPasteboardItem per dragged row on the
        // pasteboard; reading `pb.string(forType:)` would only return the
        // first one. Iterate `pasteboardItems` to pick up every tab id.
        let tabIds: [TabId] = (pb.pasteboardItems ?? []).compactMap { pbItem in
            guard let str = pbItem.string(forType: SidebarView.tabDragType),
                  let raw = UUID(uuidString: str) else { return nil }
            return TabId(rawValue: raw)
        }
        if !tabIds.isEmpty {
            let targetGroupId: GroupId
            if isSingleGroupMode {
                guard let model = currentModel else { return false }
                targetGroupId = model.groups[0].id
            } else if let sidebarItem = item as? SidebarItem, case .group(let group) = sidebarItem.kind {
                targetGroupId = group.id
            } else {
                return false
            }
            runtime?.send(.moveTabs(
                tabIds: tabIds, toGroupId: targetGroupId, atIndex: index))
            return true
        }

        if let groupIdStr = pb.string(forType: SidebarView.groupDragType),
           let rawId = UUID(uuidString: groupIdStr) {
            runtime?.send(.reorderGroup(groupId: GroupId(rawValue: rawId), toIndex: index))
            return true
        }

        // Pane drag
        if let paneIdStr = pb.string(forType: paneDragType),
           let rawId = UUID(uuidString: paneIdStr) {
            let paneId = PaneId(rawValue: rawId)

            // Drop onto a tab row → merge pane into that tab
            if let sidebarItem = item as? SidebarItem, case .tab(let tab) = sidebarItem.kind,
               index == NSOutlineViewDropOnItemIndex {
                runtime?.send(.movePaneToTab(paneId: paneId, targetTabId: tab.id))
                return true
            }

            // Drop between tabs → create new tab at insertion index
            let groupId: GroupId
            if isSingleGroupMode {
                guard let model = currentModel else { return false }
                groupId = model.groups[0].id
            } else if let sidebarItem = item as? SidebarItem, case .group(let group) = sidebarItem.kind {
                groupId = group.id
            } else {
                return false
            }
            runtime?.send(.movePaneToNewTab(paneId: paneId, inGroupId: groupId, atIndex: index))
            return true
        }

        return false
    }

    // MARK: - Context Menus

    func contextMenu(for group: GroupModel) -> NSMenu? {
        let menu = NSMenu()

        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(contextNewTab(_:)), keyEquivalent: "")
        newTabItem.target = self
        newTabItem.representedObject = group.id.rawValue
        menu.addItem(newTabItem)

        menu.addItem(NSMenuItem.separator())

        let renameItem = NSMenuItem(title: "Rename Group", action: #selector(contextRenameGroup(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = group.id.rawValue
        menu.addItem(renameItem)

        let deleteItem = NSMenuItem(title: "Delete Group", action: #selector(contextDeleteGroup(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = group.id.rawValue
        deleteItem.isEnabled = (currentModel?.groups.count ?? 0) > 1
        menu.addItem(deleteItem)

        return menu
    }

    /// Resolve the tab ids targeted by a context-menu action using the
    /// Finder/Mail rule (helper lives in ModelOperations.swift so it's
    /// unit-tested without AppKit).
    private func contextTargetTabIds(clickedRow: Int) -> [TabId] {
        return resolveContextTargets(
            clickedRow: clickedRow,
            selectedRows: outlineView.selectedRowIndexes,
            tabIdAtRow: { [weak self] row in
                guard let self = self,
                      let item = self.outlineView.item(atRow: row) as? SidebarItem,
                      case .tab(let tab) = item.kind else { return nil }
                return tab.id
            })
    }

    /// Build the tab context menu, applying the multi-select convention:
    /// items that act on the whole selection get a `(N tabs)` suffix
    /// when N > 1; singular form means "this clicked row only". The
    /// `Rename Tab` action is singular-only and always targets the
    /// clicked row.
    func contextMenu(forTab tab: TabModel, clickedRow: Int) -> NSMenu? {
        guard let model = currentModel else { return nil }

        let targetIds = contextTargetTabIds(clickedRow: clickedRow)
        guard !targetIds.isEmpty else { return nil }

        // Look up live TabModels in visual order, dropping stale ids.
        let targetSet = Set(targetIds)
        var targetTabs: [TabModel] = []
        for g in model.groups {
            for t in g.tabs where targetSet.contains(t.id) {
                targetTabs.append(t)
            }
        }
        guard !targetTabs.isEmpty else { return nil }
        let count = targetTabs.count
        let suffix = count > 1 ? " (\(count) tabs)" : ""

        let menu = NSMenu()

        // Rename Tab — singular-only, always targets the clicked row.
        let renameItem = NSMenuItem(
            title: "Rename Tab",
            action: #selector(contextRenameTab(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = tab.id.rawValue
        menu.addItem(renameItem)

        // Clear Custom Title — show if any selected tab has one.
        if targetTabs.contains(where: { $0.customTitle != nil }) {
            let item = NSMenuItem(
                title: "Clear Custom Title\(suffix)",
                action: #selector(contextClearCustomTitles(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = TabIdsBox(ids: targetIds)
            menu.addItem(item)
        }

        // Color submenu
        menu.addItem(NSMenuItem.separator())
        let colors = targetTabs.map(\.color)
        let allSameColor = colors.allSatisfy { $0 == colors.first }
        let sharedColor: TabColor? = allSameColor ? (colors.first ?? nil) : nil
        let anyHasColor = colors.contains { $0 != nil }

        let colorItem = NSMenuItem(
            title: "Color\(suffix)", action: nil, keyEquivalent: "")
        // Show parent swatch only when all selected tabs share the same
        // non-nil color. Mixed selections leave the swatch off.
        if let s = sharedColor {
            colorItem.image = s.swatchImage
        }
        let colorSubmenu = NSMenu()
        if anyHasColor {
            let clearItem = NSMenuItem(
                title: "Clear Color",
                action: #selector(contextSetTabColors(_:)),
                keyEquivalent: "")
            clearItem.target = self
            clearItem.representedObject = SetTabColorsInfo(tabIds: targetIds, color: nil)
            colorSubmenu.addItem(clearItem)
            colorSubmenu.addItem(NSMenuItem.separator())
        }
        for color in TabColor.allCases {
            let item = NSMenuItem(
                title: color.rawValue.capitalized,
                action: #selector(contextSetTabColors(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = SetTabColorsInfo(tabIds: targetIds, color: color)
            item.image = color.swatchImage
            // Checkmark only when all selected tabs share this color.
            if allSameColor && sharedColor == color {
                item.state = .on
            }
            colorSubmenu.addItem(item)
        }
        colorItem.submenu = colorSubmenu
        menu.addItem(colorItem)

        // Clear Alerts — show if any selected tab has unread alerts.
        let anyHasAlerts = targetTabs.contains {
            unreadAlertCount(for: $0, alerts: model.alerts) > 0
        }
        if anyHasAlerts {
            menu.addItem(NSMenuItem.separator())
            let item = NSMenuItem(
                title: "Clear Alerts\(suffix)",
                action: #selector(contextClearAlerts(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = TabIdsBox(ids: targetIds)
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Move to New Group — same no-op rule as before: hide when the
        // action would extract every live tab (rejected by update).
        let totalTabs = model.groups.reduce(0) { $0 + $1.tabs.count }
        let isAllLiveTabs = totalTabs > 0 && targetIds.count == totalTabs
        if !isAllLiveTabs {
            let item = NSMenuItem(
                title: "Move to New Group\(suffix)",
                action: #selector(contextExtractTabs(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = TabIdsBox(ids: targetIds)
            menu.addItem(item)
        }

        // Close — the "Tab" noun is dropped so the suffix doesn't read
        // redundantly ("Close (3 tabs)" vs. "Close Tab (3 tabs)").
        let closeItem = NSMenuItem(
            title: "Close\(suffix)",
            action: #selector(contextCloseTabs(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = TabIdsBox(ids: targetIds)
        menu.addItem(closeItem)

        return menu
    }

    @objc private func contextNewTab(_ sender: NSMenuItem) {
        guard let rawId = sender.representedObject as? UUID else { return }
        runtime?.send(.createTab(inGroupId: GroupId(rawValue: rawId)))
    }

    @objc private func contextRenameGroup(_ sender: NSMenuItem) {
        guard let rawId = sender.representedObject as? UUID else { return }
        let groupId = GroupId(rawValue: rawId)
        DispatchQueue.main.async { [weak self] in
            self?.beginRenamingGroup(groupId)
        }
    }

    @objc private func contextDeleteGroup(_ sender: NSMenuItem) {
        guard let rawId = sender.representedObject as? UUID else { return }
        let groupId = GroupId(rawValue: rawId)
        guard let model = currentModel else { return }

        switch deleteGroupAction(for: groupId, in: model) {
        case .deleteImmediately(let gid):
            runtime?.send(.deleteGroup(id: gid, moveTabs: false))
        case .confirm(let gid, let name, let tabCount):
            let alert = NSAlert()
            alert.messageText = "Delete group \"\(name)\"?"
            alert.informativeText = "This group has \(tabCount) tab(s)."
            let groupIdx = model.groups.firstIndex(where: { $0.id == gid })!
            let adjIdx = adjacentGroupIndex(deletingAt: groupIdx, count: model.groups.count)!
            let destName = model.groups[adjIdx].name
            alert.addButton(withTitle: "Move to \(destName)")
            alert.addButton(withTitle: "Close Tabs")
            alert.addButton(withTitle: "Cancel")
            guard let window = window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn:
                    self?.runtime?.send(.deleteGroup(id: gid, moveTabs: true))
                case .alertSecondButtonReturn:
                    self?.runtime?.send(.deleteGroup(id: gid, moveTabs: false))
                default:
                    break
                }
            }
        case nil:
            break
        }
    }

    /// Single-tab picks route through .setTabColor so the existing
    /// "pick the same color again to clear it" toggle UX is preserved
    /// (also used by the keyboard shortcut path). Multi-tab picks route
    /// through .setTabColors which sets the color on every tab without
    /// toggling.
    @objc private func contextSetTabColors(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? SetTabColorsInfo,
              !info.tabIds.isEmpty else { return }
        if info.tabIds.count == 1 {
            runtime?.send(.setTabColor(tabId: info.tabIds[0], color: info.color))
        } else {
            runtime?.send(.setTabColors(tabIds: info.tabIds, color: info.color))
        }
    }

    @objc private func contextRenameTab(_ sender: NSMenuItem) {
        guard let rawId = sender.representedObject as? UUID else { return }
        let tabId = TabId(rawValue: rawId)
        DispatchQueue.main.async { [weak self] in
            self?.beginRenamingTab(tabId)
        }
    }

    @objc private func contextClearCustomTitles(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? TabIdsBox,
              !box.ids.isEmpty else { return }
        if box.ids.count == 1 {
            runtime?.send(.renameTab(id: box.ids[0], name: nil))
        } else {
            runtime?.send(.clearCustomTitles(tabIds: box.ids))
        }
    }

    @objc private func contextClearAlerts(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? TabIdsBox,
              !box.ids.isEmpty else { return }
        if box.ids.count == 1 {
            runtime?.send(.clearAlertsForTab(tabId: box.ids[0]))
        } else {
            runtime?.send(.clearAlertsForTabs(tabIds: box.ids))
        }
    }

    /// Closing N tabs dispatches N .requestCloseTab calls so each tab's
    /// per-pane "running command" confirmation flow runs independently.
    @objc private func contextCloseTabs(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? TabIdsBox else { return }
        for id in box.ids {
            runtime?.send(.requestCloseTab(id: id))
        }
    }

    /// Mirrors AppDelegate.newGroup: send the action, then begin inline
    /// rename on the freshly-created group (diffed via group-id snapshot
    /// against currentModel, which the .reloadSidebar effect refreshed
    /// during send).
    @objc private func contextExtractTabs(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? TabIdsBox,
              !box.ids.isEmpty else { return }
        let existingIds = Set(currentModel?.groups.map(\.id) ?? [])
        runtime?.send(.extractTabsToNewGroup(
            tabIds: box.ids, groupName: "New group"))
        if let newGroup = currentModel?.groups.first(
            where: { !existingIds.contains($0.id) }) {
            let groupId = newGroup.id
            DispatchQueue.main.async { [weak self] in
                self?.beginRenamingGroup(groupId)
            }
        }
    }

    // MARK: - Cell Factories

    private func makeGroupCell(for group: GroupModel) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier("GroupCell")

        if let existing = outlineView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
            configureGroupCell(existing, group: group)
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = cellId

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .boldSystemFont(ofSize: 11)
        textField.lineBreakMode = .byTruncatingTail
        textField.isEditable = false
        textField.delegate = self
        cell.addSubview(textField)
        cell.textField = textField

        let bellBadge = NSTextField.makeBadge()
        bellBadge.identifier = NSUserInterfaceItemIdentifier("groupBellBadge")

        let tabCountBadge = NSTextField.makeBadge(color: .systemGray)
        tabCountBadge.identifier = NSUserInterfaceItemIdentifier("groupTabCountBadge")

        let caretButton = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Toggle Group")!, target: self, action: #selector(caretClicked(_:)))
        caretButton.translatesAutoresizingMaskIntoConstraints = false
        caretButton.bezelStyle = .accessoryBarAction
        caretButton.isBordered = false
        caretButton.imageScaling = .scaleProportionallyDown
        caretButton.contentTintColor = .tertiaryLabelColor
        caretButton.identifier = NSUserInterfaceItemIdentifier("groupCaretButton")

        let accessoryStack = NSStackView(views: [bellBadge, tabCountBadge, caretButton])
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.orientation = .horizontal
        accessoryStack.alignment = .centerY
        accessoryStack.spacing = 2
        accessoryStack.identifier = NSUserInterfaceItemIdentifier("groupAccessoryStack")
        cell.addSubview(accessoryStack)

        // Thin separator line at top edge, hidden for the first group
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.identifier = NSUserInterfaceItemIdentifier("groupSeparator")
        cell.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: cell.topAnchor),
            separator.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            separator.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: accessoryStack.leadingAnchor, constant: -4),
            accessoryStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            accessoryStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            caretButton.widthAnchor.constraint(equalToConstant: 16),
            caretButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        configureGroupCell(cell, group: group)
        return cell
    }

    /// Apply current group state to an existing cell's subviews. Shared by
    /// makeGroupCell (initial population) and updateGroupRow (in-place refresh).
    /// skipTitle protects the field editor during inline group rename.
    private func configureGroupCell(_ cell: NSTableCellView, group: GroupModel, skipTitle: Bool = false) {
        if !skipTitle {
            cell.textField?.stringValue = group.name
        }
        cell.textField?.tag = group.id.rawValue.hashValue
        // Hide separator for the first group
        let isFirstGroup = group.id == currentModel?.groups.first?.id
        if let separator = cell.subviews.first(where: { $0.identifier?.rawValue == "groupSeparator" }) {
            separator.isHidden = isFirstGroup
        }
        if let stack = cell.subviews.first(where: { $0.identifier?.rawValue == "groupAccessoryStack" }) as? NSStackView {
            if let caretButton = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "groupCaretButton" }) as? NSButton {
                let symbolName = group.isCollapsed ? "chevron.right" : "chevron.down"
                caretButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Toggle Group")
                objc_setAssociatedObject(caretButton, &AssociatedKeys.groupId, group.id.rawValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            if let bellBadge = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "groupBellBadge" }) as? NSTextField {
                let count = groupUnreadAlertCount(for: group, alerts: currentModel?.alerts ?? [])
                bellBadge.updateBadge(count: count)
                if !group.isCollapsed { bellBadge.isHidden = true }
            }
            if let tabCountBadge = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "groupTabCountBadge" }) as? NSTextField {
                tabCountBadge.stringValue = "\(group.tabs.count)"
                tabCountBadge.isHidden = !group.isCollapsed
            }
        }
    }

    private func makeTabCell(for tab: TabModel) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier("TabCell")
        let subtitleId = NSUserInterfaceItemIdentifier("subtitle")
        let bellDotId = NSUserInterfaceItemIdentifier("bellDot")
        let colorStripeId = NSUserInterfaceItemIdentifier("colorStripe")
        let accessoryStackId = NSUserInterfaceItemIdentifier("tabAccessoryStack")

        let cell: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId

            // Color stripe: 3px vertical bar on the left edge
            let colorStripe = NSView()
            colorStripe.identifier = colorStripeId
            colorStripe.translatesAutoresizingMaskIntoConstraints = false
            colorStripe.wantsLayer = true
            colorStripe.isHidden = true
            cell.addSubview(colorStripe)

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = .systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingTail
            textField.isEditable = false
            textField.delegate = self
            cell.addSubview(textField)
            cell.textField = textField

            let subtitleField = NSTextField(labelWithString: "")
            subtitleField.identifier = subtitleId
            subtitleField.translatesAutoresizingMaskIntoConstraints = false
            subtitleField.font = .systemFont(ofSize: 10)
            subtitleField.textColor = .secondaryLabelColor
            subtitleField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(subtitleField)

            let bellBadge = NSTextField.makeBadge()
            bellBadge.identifier = bellDotId
            let accessoryStack = NSStackView(views: [bellBadge])
            accessoryStack.translatesAutoresizingMaskIntoConstraints = false
            accessoryStack.orientation = .horizontal
            accessoryStack.alignment = .top
            accessoryStack.spacing = 0
            accessoryStack.identifier = accessoryStackId
            cell.addSubview(accessoryStack)

            NSLayoutConstraint.activate([
                colorStripe.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                colorStripe.topAnchor.constraint(equalTo: cell.topAnchor),
                colorStripe.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
                colorStripe.widthAnchor.constraint(equalToConstant: 5),
                accessoryStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                accessoryStack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(lessThanOrEqualTo: accessoryStack.leadingAnchor, constant: -4),
                textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                subtitleField.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
                subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: accessoryStack.leadingAnchor, constant: -4),
                subtitleField.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 1),
            ])
        }

        configureTabCell(cell, tab: tab)
        return cell
    }

    /// Apply current tab state to an existing cell's subviews. Shared by
    /// makeTabCell (initial population) and updateTabRow (in-place refresh).
    /// When skipTitle is true the text field is left untouched so the field
    /// editor isn't clobbered during inline rename.
    private func configureTabCell(_ cell: NSTableCellView, tab: TabModel, skipTitle: Bool = false) {
        let subtitleId = NSUserInterfaceItemIdentifier("subtitle")
        let bellDotId = NSUserInterfaceItemIdentifier("bellDot")
        let colorStripeId = NSUserInterfaceItemIdentifier("colorStripe")
        let accessoryStackId = NSUserInterfaceItemIdentifier("tabAccessoryStack")

        if !skipTitle {
            cell.textField?.stringValue = tab.displayTitle
        }
        if let subtitleField = cell.subviews.first(where: { $0.identifier == subtitleId }) as? NSTextField {
            subtitleField.stringValue = tab.subtitle ?? ""
            subtitleField.isHidden = tab.subtitle == nil
        }
        if let stack = cell.subviews.first(where: { $0.identifier == accessoryStackId }) as? NSStackView,
           let bellBadge = stack.arrangedSubviews.first(where: { $0.identifier == bellDotId }) as? NSTextField {
            let count = unreadAlertCount(for: tab, alerts: currentModel?.alerts ?? [])
            bellBadge.updateBadge(count: count)
        }
        if let stripe = cell.subviews.first(where: { $0.identifier == colorStripeId }) {
            if let color = tab.color {
                stripe.layer?.backgroundColor = color.nsColor.cgColor
                stripe.isHidden = false
            } else {
                stripe.isHidden = true
            }
        }
    }

    /// Returns true if the drag cursor is in empty space below all outline view rows.
    private func isDragBelowContent(_ info: NSDraggingInfo) -> Bool {
        let location = outlineView.convert(info.draggingLocation, from: nil)
        let rowCount = outlineView.numberOfRows
        guard rowCount > 0 else { return true }
        let lastRowRect = outlineView.rect(ofRow: rowCount - 1)
        return location.y > lastRowRect.maxY
    }

    // MARK: - Inline Rename Cleanup

    /// Shared cleanup for all rename-exit paths: disables editing, clears the
    /// rename target, and resyncs the row from cached model state. The optional
    /// target parameter lets doCommandBy pass the saved target (since it clears
    /// the associated object before calling).
    private func finishInlineRename(textField: NSTextField, target: RenameTarget? = nil) {
        let resolvedTarget = target
            ?? objc_getAssociatedObject(textField, &AssociatedKeys.renameTarget) as? RenameTarget
        textField.isEditable = false
        objc_setAssociatedObject(textField, &AssociatedKeys.renameTarget, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Resync the row's title from cached model state now that the field editor
        // is gone. During rename, skipTitle prevented title updates; this ensures
        // the cell reflects the current model regardless of whether a rename Msg
        // follows.
        switch resolvedTarget {
        case .tab(let tabId):
            guard let item = tabItemCache[tabId] else { return }
            let row = outlineView.row(forItem: item)
            guard row >= 0,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                  case .tab(let tab) = item.kind else { return }
            configureTabCell(cell, tab: tab)
        case .group(let groupId):
            guard let item = groupItemCache[groupId] else { return }
            let row = outlineView.row(forItem: item)
            guard row >= 0,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                  case .group(let group) = item.kind else { return }
            configureGroupCell(cell, group: group)
        case nil:
            break
        }
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - NSTextFieldDelegate (inline rename)

extension SidebarView: NSTextFieldDelegate {
    /// Enter and Esc are the sole authority for inline rename completion.
    /// Enter commits the rename; Esc cancels (reverts). Both restore focus to
    /// the active terminal pane. The target is cleared before makeFirstResponder
    /// so that textShouldEndEditing (if AppKit fires it during resign) is a no-op.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let isConfirm = commandSelector == #selector(NSResponder.insertNewline(_:))
        let isCancel  = commandSelector == #selector(NSResponder.cancelOperation(_:))
        guard isConfirm || isCancel,
              let textField = control as? NSTextField else { return false }

        // 1. Capture rename context before clearing.
        let target = objc_getAssociatedObject(
            textField, &AssociatedKeys.renameTarget) as? RenameTarget
        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)

        // 2. Clear target so textShouldEndEditing (if AppKit fires it
        //    during makeFirstResponder) is a no-op.
        objc_setAssociatedObject(
            textField, &AssociatedKeys.renameTarget, nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // 3. End editing (removes field editor, commits text to stringValue).
        window?.makeFirstResponder(nil)

        // 4. Resync cell from model (overwrites committed text for cancel;
        //    for confirm the rename below will update it again immediately).
        finishInlineRename(textField: textField, target: target)

        // 5. Compute and dispatch messages synchronously.
        let action: RenameAction? = {
            switch target {
            case .tab(let tabId): return .tab(tabId)
            case .group(let groupId): return .group(groupId)
            case nil: return nil
            }
        }()
        for msg in renameCompletionMessages(
            isConfirm: isConfirm, action: action, newName: newName
        ) {
            runtime?.send(msg)
        }

        return true
    }

    /// Click-away path: commits the rename without restoring focus (user moved
    /// focus intentionally). When doCommandBy already cleared the target, this
    /// sees nil and is a no-op — preventing double-dispatch.
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard let textField = control as? NSTextField else { return true }
        let target = objc_getAssociatedObject(textField, &AssociatedKeys.renameTarget) as? RenameTarget
        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)

        switch target {
        case .tab(let tabId):
            let name: String? = newName.isEmpty ? nil : newName
            DispatchQueue.main.async { [weak self] in
                self?.runtime?.send(.renameTab(id: tabId, name: name))
            }
        case .group(let groupId):
            if !newName.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.runtime?.send(.renameGroup(id: groupId, name: newName))
                }
            }
        case nil:
            break
        }

        finishInlineRename(textField: textField)
        return true
    }
}

// MARK: - Helpers

/// Tracks whether an inline-editing text field is renaming a tab or a group.
private enum RenameTarget {
    case tab(TabId)
    case group(GroupId)
}

private enum AssociatedKeys {
    static var groupId: UInt8 = 0
    static var renameTarget: UInt8 = 0
}

private class SetTabColorsInfo: NSObject {
    let tabIds: [TabId]
    let color: TabColor?
    init(tabIds: [TabId], color: TabColor?) {
        self.tabIds = tabIds
        self.color = color
    }
}

private class TabIdsBox: NSObject {
    let ids: [TabId]
    init(ids: [TabId]) { self.ids = ids }
}
