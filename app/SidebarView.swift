import Cocoa

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

    private static let tabInsetX: CGFloat = 5

    /// Hide the native disclosure triangle for all rows. Group rows use a
    /// custom caret button on the right side instead.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        return .zero
    }

    /// Stretch cells to full width. Tab rows get a small left inset.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        if let sidebarItem = item(atRow: row) as? SidebarItem {
            switch sidebarItem.kind {
            case .tab:
                frame.origin.x = Self.tabInsetX
                frame.size.width = bounds.width - Self.tabInsetX
            case .group:
                frame.origin.x = 0
                frame.size.width = bounds.width
            }
        }
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
        outlineView.allowsEmptySelection = true
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.indentationPerLevel = 0

        outlineView.registerForDraggedTypes([SidebarView.tabDragType, SidebarView.groupDragType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        // Bottom bar with + tab and + group buttons
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(separator)

        let addTabButton = NSButton(image: NSImage(named: NSImage.addTemplateName)!, target: self, action: #selector(addTabClicked))
        addTabButton.translatesAutoresizingMaskIntoConstraints = false
        addTabButton.bezelStyle = .accessoryBarAction
        addTabButton.isBordered = false
        addTabButton.imageScaling = .scaleProportionallyDown
        addTabButton.toolTip = "New Tab"
        bottomBar.addSubview(addTabButton)

        let addGroupButton = NSButton(image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "New Group")!, target: self, action: #selector(addGroupClicked))
        addGroupButton.translatesAutoresizingMaskIntoConstraints = false
        addGroupButton.bezelStyle = .accessoryBarAction
        addGroupButton.isBordered = false
        addGroupButton.imageScaling = .scaleProportionallyDown
        addGroupButton.toolTip = "New Group"
        bottomBar.addSubview(addGroupButton)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            addTabButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 4),
            addTabButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            addTabButton.widthAnchor.constraint(equalToConstant: 24),
            addTabButton.heightAnchor.constraint(equalToConstant: 24),
            addGroupButton.leadingAnchor.constraint(equalTo: addTabButton.trailingAnchor, constant: 4),
            addGroupButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            addGroupButton.widthAnchor.constraint(equalToConstant: 24),
            addGroupButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(bottomBar)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    // MARK: - Actions

    @objc private func addTabClicked() {
        runtime?.send(.createTab(inGroupId: nil))
    }

    @objc private func addGroupClicked() {
        runtime?.send(.createGroup(name: "Untitled"))
        if let lastGroup = runtime?.model.groups.last, !lastGroup.isDefault {
            beginRenamingGroup(lastGroup.id)
        }
    }

    @objc private func addTabToGroup(_ sender: NSButton) {
        guard let rawId = objc_getAssociatedObject(sender, &AssociatedKeys.groupId) as? UUID else { return }
        runtime?.send(.createTab(inGroupId: GroupId(rawValue: rawId)))
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

        // Select current tab
        if let selectedTabId = model.selectedTabId, let item = tabItemCache[selectedTabId] {
            let row = outlineView.row(forItem: item)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        guard let cellView = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return }
        guard let textField = cellView.textField else { return }
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
            let panes = currentModel?.panes ?? [:]
            let count = groupBellCount(for: group, panes: panes)
            bellBadge.stringValue = "\(count)"
            bellBadge.isHidden = count == 0 || !collapsed
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
            if !group.isDefault {
                pbItem.setString(group.id.rawValue.uuidString, forType: SidebarView.groupDragType)
                return pbItem
            }
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
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
            if item == nil && index > 0 {
                return .move
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

        return false
    }

    // MARK: - Context Menus

    func contextMenu(for group: GroupModel) -> NSMenu? {
        guard !group.isDefault else { return nil }
        let menu = NSMenu()

        let renameItem = NSMenuItem(title: "Rename Group", action: #selector(contextRenameGroup(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = group.id.rawValue
        menu.addItem(renameItem)

        let deleteItem = NSMenuItem(title: "Delete Group", action: #selector(contextDeleteGroup(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = group.id.rawValue
        menu.addItem(deleteItem)

        return menu
    }

    func contextMenu(for tab: TabModel) -> NSMenu? {
        guard let model = currentModel else { return nil }

        let menu = NSMenu()
        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(contextCloseTab(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = tab.id.rawValue
        menu.addItem(closeItem)

        if model.groups.count > 1, let currentGroup = groupForTab(tab.id, in: model) {
            menu.addItem(NSMenuItem.separator())

            let moveItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            for group in model.groups where group.id != currentGroup.id {
                let item = NSMenuItem(title: group.name, action: #selector(contextMoveTab(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = MoveTabInfo(tabId: tab.id, targetGroupId: group.id, targetGroupTabCount: group.tabs.count)
                submenu.addItem(item)
            }

            moveItem.submenu = submenu
            menu.addItem(moveItem)
        }
        return menu
    }

    @objc private func contextRenameGroup(_ sender: NSMenuItem) {
        guard let rawId = sender.representedObject as? UUID else { return }
        beginRenamingGroup(GroupId(rawValue: rawId))
    }

    @objc private func contextDeleteGroup(_ sender: NSMenuItem) {
        guard let rawId = sender.representedObject as? UUID else { return }
        let groupId = GroupId(rawValue: rawId)
        guard let model = currentModel,
              let group = model.groups.first(where: { $0.id == groupId }) else { return }

        let alert = NSAlert()
        alert.messageText = "Delete group \"\(group.name)\"?"
        if group.tabs.isEmpty {
            alert.informativeText = "This group has no tabs."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard let window = window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.runtime?.send(.deleteGroup(id: groupId, moveTabs: false))
                }
            }
        } else {
            alert.informativeText = "This group has \(group.tabs.count) tab(s)."
            alert.addButton(withTitle: "Move to General")
            alert.addButton(withTitle: "Close Tabs")
            alert.addButton(withTitle: "Cancel")
            guard let window = window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn:
                    self?.runtime?.send(.deleteGroup(id: groupId, moveTabs: true))
                case .alertSecondButtonReturn:
                    self?.runtime?.send(.deleteGroup(id: groupId, moveTabs: false))
                default:
                    break
                }
            }
        }
    }

    @objc private func contextMoveTab(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? MoveTabInfo else { return }
        runtime?.send(.moveTab(tabId: info.tabId, toGroupId: info.targetGroupId, atIndex: info.targetGroupTabCount))
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

        let bellBadge = NSTextField(labelWithString: "")
        bellBadge.identifier = NSUserInterfaceItemIdentifier("groupBellBadge")
        bellBadge.translatesAutoresizingMaskIntoConstraints = false
        bellBadge.font = .boldSystemFont(ofSize: 9)
        bellBadge.textColor = .white
        bellBadge.alignment = .center
        bellBadge.wantsLayer = true
        bellBadge.layer?.backgroundColor = NSColor.systemRed.cgColor
        bellBadge.layer?.cornerRadius = 6
        bellBadge.layer?.masksToBounds = true
        bellBadge.isHidden = true
        cell.addSubview(bellBadge)

        let caretButton = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Toggle Group")!, target: self, action: #selector(caretClicked(_:)))
        caretButton.translatesAutoresizingMaskIntoConstraints = false
        caretButton.bezelStyle = .accessoryBarAction
        caretButton.isBordered = false
        caretButton.imageScaling = .scaleProportionallyDown
        caretButton.contentTintColor = .tertiaryLabelColor
        caretButton.identifier = NSUserInterfaceItemIdentifier("groupCaretButton")
        cell.addSubview(caretButton)

        let addButton = NSButton(image: NSImage(named: NSImage.addTemplateName)!, target: self, action: #selector(addTabToGroup(_:)))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .accessoryBarAction
        addButton.isBordered = false
        addButton.imageScaling = .scaleProportionallyDown
        addButton.toolTip = "New Tab in Group"
        addButton.identifier = NSUserInterfaceItemIdentifier("groupAddButton")
        cell.addSubview(addButton)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: bellBadge.leadingAnchor, constant: -4),
            bellBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),
            bellBadge.heightAnchor.constraint(equalToConstant: 12),
            bellBadge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            bellBadge.trailingAnchor.constraint(equalTo: caretButton.leadingAnchor, constant: -2),
            caretButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: 2),
            caretButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            caretButton.widthAnchor.constraint(equalToConstant: 16),
            caretButton.heightAnchor.constraint(equalToConstant: 16),
            addButton.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            addButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 16),
            addButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        configureGroupCell(cell, group: group)
        return cell
    }

    private func configureGroupCell(_ cell: NSTableCellView, group: GroupModel) {
        cell.textField?.stringValue = group.name
        cell.textField?.tag = group.id.rawValue.hashValue
        if let addButton = cell.subviews.first(where: { $0.identifier?.rawValue == "groupAddButton" }) as? NSButton {
            objc_setAssociatedObject(addButton, &AssociatedKeys.groupId, group.id.rawValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if let caretButton = cell.subviews.first(where: { $0.identifier?.rawValue == "groupCaretButton" }) as? NSButton {
            let symbolName = group.isCollapsed ? "chevron.right" : "chevron.down"
            caretButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Toggle Group")
            objc_setAssociatedObject(caretButton, &AssociatedKeys.groupId, group.id.rawValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if let bellBadge = cell.subviews.first(where: { $0.identifier?.rawValue == "groupBellBadge" }) as? NSTextField {
            let panes = currentModel?.panes ?? [:]
            let count = groupBellCount(for: group, panes: panes)
            bellBadge.stringValue = "\(count)"
            bellBadge.isHidden = count == 0 || !group.isCollapsed
        }
    }

    private func makeTabCell(for tab: TabModel) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier("TabCell")
        let subtitleId = NSUserInterfaceItemIdentifier("subtitle")
        let bellDotId = NSUserInterfaceItemIdentifier("bellDot")

        let cell: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = .systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField

            let subtitleField = NSTextField(labelWithString: "")
            subtitleField.identifier = subtitleId
            subtitleField.translatesAutoresizingMaskIntoConstraints = false
            subtitleField.font = .systemFont(ofSize: 10)
            subtitleField.textColor = .secondaryLabelColor
            subtitleField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(subtitleField)

            let bellBadge = NSTextField(labelWithString: "")
            bellBadge.identifier = bellDotId
            bellBadge.translatesAutoresizingMaskIntoConstraints = false
            bellBadge.font = .boldSystemFont(ofSize: 10)
            bellBadge.textColor = .white
            bellBadge.alignment = .center
            bellBadge.wantsLayer = true
            bellBadge.layer?.backgroundColor = NSColor.systemRed.cgColor
            bellBadge.layer?.cornerRadius = 7
            bellBadge.layer?.masksToBounds = true
            cell.addSubview(bellBadge)

            NSLayoutConstraint.activate([
                bellBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
                bellBadge.heightAnchor.constraint(equalToConstant: 14),
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

        cell.textField?.stringValue = tab.title
        if let subtitleField = cell.subviews.first(where: { $0.identifier == subtitleId }) as? NSTextField {
            subtitleField.stringValue = tab.subtitle ?? ""
            subtitleField.isHidden = tab.subtitle == nil
        }
        if let bellBadge = cell.subviews.first(where: { $0.identifier == bellDotId }) as? NSTextField {
            let panes = currentModel?.panes ?? [:]
            let count = bellCount(for: tab, panes: panes)
            bellBadge.stringValue = "\(count)"
            bellBadge.isHidden = count == 0
        }
        return cell
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
        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        if newName.isEmpty { return false }

        if let model = currentModel,
           let group = model.groups.first(where: { $0.id.rawValue.hashValue == textField.tag }) {
            let groupId = group.id
            // Defer to avoid reentrant reloadData while text field is ending editing
            DispatchQueue.main.async { [weak self] in
                self?.runtime?.send(.renameGroup(id: groupId, name: newName))
            }
        }
        textField.isEditable = false
        return true
    }
}

// MARK: - Helpers

private enum AssociatedKeys {
    static var groupId: UInt8 = 0
}

private class MoveTabInfo: NSObject {
    let tabId: TabId
    let targetGroupId: GroupId
    let targetGroupTabCount: Int
    init(tabId: TabId, targetGroupId: GroupId, targetGroupTabCount: Int) {
        self.tabId = tabId
        self.targetGroupId = targetGroupId
        self.targetGroupTabCount = targetGroupTabCount
    }
}
