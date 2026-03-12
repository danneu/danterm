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
                return sidebarView?.contextMenu(for: tab)
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
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.indentationPerLevel = 0

        outlineView.registerForDraggedTypes([SidebarView.tabDragType, SidebarView.groupDragType, paneDragType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
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

        // Select current tab and scroll it into view
        if let selectedTabId = model.selectedTabId, let item = tabItemCache[selectedTabId] {
            let row = outlineView.row(forItem: item)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            }
        }
    }

    func reloadRow(tabId: TabId, model: AppModel) {
        currentModel = model
        // Update cached item data
        for group in model.groups {
            if let tab = group.tabs.first(where: { $0.id == tabId }) {
                tabItemCache[tabId]?.kind = .tab(tab)
                break
            }
        }
        guard let item = tabItemCache[tabId] else {
            reload(model: model)
            return
        }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else {
            reload(model: model)
            return
        }
        outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    func reloadGroupRow(groupId: GroupId, model: AppModel) {
        currentModel = model
        if let group = model.groups.first(where: { $0.id == groupId }) {
            groupItemCache[groupId]?.kind = .group(group)
        }
        guard let item = groupItemCache[groupId] else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
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
        if case .group = sidebarItem.kind { return 24 }
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

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let sidebarItem = item as? SidebarItem else { return false }
        if case .tab = sidebarItem.kind { return true }
        return false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        if let sidebarItem = outlineView.item(atRow: row) as? SidebarItem,
           case .tab(let tab) = sidebarItem.kind {
            runtime?.send(.selectTab(id: tab.id))
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isReloading else { return }
        guard let sidebarItem = notification.userInfo?["NSObject"] as? SidebarItem,
              case .group(let group) = sidebarItem.kind else { return }
        runtime?.send(.toggleGroupCollapse(groupId: group.id))
        updateGroupRow(for: sidebarItem, collapsed: true)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isReloading else { return }
        guard let sidebarItem = notification.userInfo?["NSObject"] as? SidebarItem,
              case .group(let group) = sidebarItem.kind else { return }
        runtime?.send(.toggleGroupCollapse(groupId: group.id))
        updateGroupRow(for: sidebarItem, collapsed: false)
    }

    private func updateGroupRow(for sidebarItem: SidebarItem, collapsed: Bool) {
        guard case .group(let group) = sidebarItem.kind else { return }
        let row = outlineView.row(forItem: sidebarItem)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        if let caretButton = cell.subviews.first(where: { $0.identifier?.rawValue == "groupCaretButton" }) as? NSButton {
            let symbolName = collapsed ? "chevron.right" : "chevron.down"
            caretButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Toggle Group")
        }
        if let bellBadge = cell.subviews.first(where: { $0.identifier?.rawValue == "groupBellBadge" }) as? NSTextField {
            let count = groupUnreadAlertCount(for: group, alerts: currentModel?.alerts ?? [])
            bellBadge.updateBadge(count: count)
            if !collapsed { bellBadge.isHidden = true }
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

        if let tabIdStr = pb.string(forType: SidebarView.tabDragType),
           let rawId = UUID(uuidString: tabIdStr) {
            let tabId = TabId(rawValue: rawId)
            let targetGroupId: GroupId
            if isSingleGroupMode {
                guard let model = currentModel else { return false }
                targetGroupId = model.groups[0].id
            } else if let sidebarItem = item as? SidebarItem, case .group(let group) = sidebarItem.kind {
                targetGroupId = group.id
            } else {
                return false
            }
            runtime?.send(.moveTab(tabId: tabId, toGroupId: targetGroupId, atIndex: index))
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

    func contextMenu(for tab: TabModel) -> NSMenu? {
        guard currentModel != nil else { return nil }

        let menu = NSMenu()

        let renameItem = NSMenuItem(title: "Rename Tab", action: #selector(contextRenameTab(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = tab.id.rawValue
        menu.addItem(renameItem)

        if tab.customTitle != nil {
            let clearItem = NSMenuItem(title: "Clear Custom Title", action: #selector(contextClearCustomTitle(_:)), keyEquivalent: "")
            clearItem.target = self
            clearItem.representedObject = tab.id.rawValue
            menu.addItem(clearItem)
        }

        // Color submenu
        menu.addItem(NSMenuItem.separator())
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorSubmenu = NSMenu()
        for color in TabColor.allCases {
            let item = NSMenuItem(title: color.rawValue.capitalized, action: #selector(contextSetTabColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = SetTabColorInfo(tabId: tab.id, color: color)
            // Show a filled circle swatch tinted to the color
            let swatch = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: color.rawValue)!
            item.image = swatch.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            item.image?.isTemplate = false
            // Apply color tint via a custom subclass isn't needed — use contentTintColor on the menu item's view
            // Instead, create a colored swatch image
            let size = NSSize(width: 12, height: 12)
            let coloredImage = NSImage(size: size, flipped: false) { rect in
                color.nsColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            item.image = coloredImage
            if tab.color == color {
                item.state = .on
            }
            colorSubmenu.addItem(item)
        }
        colorSubmenu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear Color", action: #selector(contextSetTabColor(_:)), keyEquivalent: "")
        clearItem.target = self
        clearItem.representedObject = SetTabColorInfo(tabId: tab.id, color: nil)
        colorSubmenu.addItem(clearItem)
        colorItem.submenu = colorSubmenu
        menu.addItem(colorItem)

        menu.addItem(NSMenuItem.separator())

        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(contextCloseTab(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = tab.id.rawValue
        menu.addItem(closeItem)

        return menu
    }

    @objc private func contextNewTab(_ sender: NSMenuItem) {
        guard let rawId = sender.representedObject as? UUID else { return }
        runtime?.send(.createTab(inGroupId: GroupId(rawValue: rawId)))
    }

    @objc private func contextRenameGroup(_ sender: NSMenuItem) {
        guard let rawId = sender.representedObject as? UUID else { return }
        beginRenamingGroup(GroupId(rawValue: rawId))
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

    @objc private func contextSetTabColor(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? SetTabColorInfo else { return }
        runtime?.send(.setTabColor(tabId: info.tabId, color: info.color))
    }

    @objc private func contextRenameTab(_ sender: NSMenuItem) {
        guard let rawId = sender.representedObject as? UUID else { return }
        beginRenamingTab(TabId(rawValue: rawId))
    }

    @objc private func contextClearCustomTitle(_ sender: NSMenuItem) {
        guard let rawId = sender.representedObject as? UUID else { return }
        runtime?.send(.renameTab(id: TabId(rawValue: rawId), name: nil))
    }

    @objc private func contextCloseTab(_ sender: NSMenuItem) {
        guard let rawId = sender.representedObject as? UUID else { return }
        let tabId = TabId(rawValue: rawId)
        runtime?.send(.requestCloseTab(id: tabId))
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
        cell.addSubview(bellBadge)

        let caretButton = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Toggle Group")!, target: self, action: #selector(caretClicked(_:)))
        caretButton.translatesAutoresizingMaskIntoConstraints = false
        caretButton.bezelStyle = .accessoryBarAction
        caretButton.isBordered = false
        caretButton.imageScaling = .scaleProportionallyDown
        caretButton.contentTintColor = .tertiaryLabelColor
        caretButton.identifier = NSUserInterfaceItemIdentifier("groupCaretButton")
        cell.addSubview(caretButton)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: bellBadge.leadingAnchor, constant: -4),
            bellBadge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            bellBadge.trailingAnchor.constraint(equalTo: caretButton.leadingAnchor, constant: -2),
            caretButton.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            caretButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            caretButton.widthAnchor.constraint(equalToConstant: 16),
            caretButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        configureGroupCell(cell, group: group)
        return cell
    }

    private func configureGroupCell(_ cell: NSTableCellView, group: GroupModel) {
        cell.textField?.stringValue = group.name
        cell.textField?.tag = group.id.rawValue.hashValue
        if let caretButton = cell.subviews.first(where: { $0.identifier?.rawValue == "groupCaretButton" }) as? NSButton {
            let symbolName = group.isCollapsed ? "chevron.right" : "chevron.down"
            caretButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Toggle Group")
            objc_setAssociatedObject(caretButton, &AssociatedKeys.groupId, group.id.rawValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if let bellBadge = cell.subviews.first(where: { $0.identifier?.rawValue == "groupBellBadge" }) as? NSTextField {
            let count = groupUnreadAlertCount(for: group, alerts: currentModel?.alerts ?? [])
            bellBadge.updateBadge(count: count)
            if !group.isCollapsed { bellBadge.isHidden = true }
        }
    }

    private func makeTabCell(for tab: TabModel) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier("TabCell")
        let subtitleId = NSUserInterfaceItemIdentifier("subtitle")
        let bellDotId = NSUserInterfaceItemIdentifier("bellDot")
        let colorStripeId = NSUserInterfaceItemIdentifier("colorStripe")

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
            cell.addSubview(bellBadge)

            NSLayoutConstraint.activate([
                colorStripe.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                colorStripe.topAnchor.constraint(equalTo: cell.topAnchor),
                colorStripe.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
                colorStripe.widthAnchor.constraint(equalToConstant: 3),
                bellBadge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                bellBadge.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                subtitleField.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
                subtitleField.trailingAnchor.constraint(equalTo: textField.trailingAnchor),
                subtitleField.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 1),
            ])
        }

        cell.textField?.stringValue = tab.displayTitle
        if let subtitleField = cell.subviews.first(where: { $0.identifier == subtitleId }) as? NSTextField {
            subtitleField.stringValue = tab.subtitle ?? ""
            subtitleField.isHidden = tab.subtitle == nil
        }
        if let bellBadge = cell.subviews.first(where: { $0.identifier == bellDotId }) as? NSTextField {
            let count = unreadAlertCount(for: tab, alerts: currentModel?.alerts ?? [])
            bellBadge.updateBadge(count: count)
        }

        // Color stripe
        if let stripe = cell.subviews.first(where: { $0.identifier == colorStripeId }) {
            if let color = tab.color {
                stripe.layer?.backgroundColor = color.nsColor.cgColor
                stripe.isHidden = false
            } else {
                stripe.isHidden = true
            }
        }

        return cell
    }

    /// Returns true if the drag cursor is in empty space below all outline view rows.
    private func isDragBelowContent(_ info: NSDraggingInfo) -> Bool {
        let location = outlineView.convert(info.draggingLocation, from: nil)
        let rowCount = outlineView.numberOfRows
        guard rowCount > 0 else { return true }
        let lastRowRect = outlineView.rect(ofRow: rowCount - 1)
        return location.y > lastRowRect.maxY
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - NSTextFieldDelegate (inline rename)

extension SidebarView: NSTextFieldDelegate {
    /// Force Enter/Escape to always end editing. By default, AppKit skips
    /// textShouldEndEditing when the value hasn't changed, leaving the field
    /// editor active. Resigning first responder ensures editing ends regardless.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
           commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard let textField = control as? NSTextField else { return true }
        let target = objc_getAssociatedObject(textField, &AssociatedKeys.renameTarget) as? RenameTarget
        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)

        switch target {
        case .tab(let tabId):
            // Empty string clears custom title
            let name: String? = newName.isEmpty ? nil : newName
            DispatchQueue.main.async { [weak self] in
                self?.runtime?.send(.renameTab(id: tabId, name: name))
            }
        case .group(let groupId):
            // Reject empty for groups (existing behavior)
            if newName.isEmpty {
                objc_setAssociatedObject(textField, &AssociatedKeys.renameTarget, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                textField.isEditable = false
                return false
            }
            DispatchQueue.main.async { [weak self] in
                self?.runtime?.send(.renameGroup(id: groupId, name: newName))
            }
        case nil:
            break
        }

        objc_setAssociatedObject(textField, &AssociatedKeys.renameTarget, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        textField.isEditable = false
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

private class SetTabColorInfo: NSObject {
    let tabId: TabId
    let color: TabColor?
    init(tabId: TabId, color: TabColor?) {
        self.tabId = tabId
        self.color = color
    }
}
