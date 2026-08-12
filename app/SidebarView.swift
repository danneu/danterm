// AppKit sidebar outline view for tabs, groups, selection, drag/drop, and rename UI.
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

// MARK: - SidebarRowView

/// Owns full-width sidebar cell placement and keeps the focused row's selection
/// emphasized while the terminal pane holds first responder.
final class SidebarRowView: NSTableRowView {
    var forceEmphasizedSelection = false {
        didSet {
            if forceEmphasizedSelection != oldValue {
                needsDisplay = true
                refreshHostedPaneStrips()
            }
        }
    }

    // NSTableRowView: selection is set by the outline view without reloading the
    // row, so this is the only place a hosted pane strip can learn that the
    // color behind it changed.
    override var isSelected: Bool {
        get { super.isSelected }
        set {
            super.isSelected = newValue
            refreshHostedPaneStrips()
        }
    }

    /// AppKit consults `isEmphasized` when drawing the selection: true
    /// -> accent color, false -> secondary grey. We force true for the
    /// focused row, otherwise pass through so genuine emphasis (e.g.
    /// inline rename promoting the field editor) still works.
    override var isEmphasized: Bool {
        get { (isSelected && forceEmphasizedSelection) || super.isEmphasized }
        set {
            super.isEmphasized = newValue
            refreshHostedPaneStrips()
        }
    }

    /// The color AppKit fills this row with, or nil when it draws no selection.
    /// Mirrors `.regular` highlight style: accent when emphasized, secondary
    /// grey when not.
    private var selectionBackground: NSColor? {
        guard isSelected else { return nil }
        return isEmphasized
            ? .selectedContentBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
    }

    /// Tells any hosted pane strip what is painted behind it, so its state-dot
    /// rings match the row instead of a fixed neutral that reads as a halo.
    private func refreshHostedPaneStrips() {
        let background = selectionBackground
        for cell in subviews.compactMap({ $0 as? NSTableCellView }) {
            for strip in cell.subviews.compactMap({ $0 as? PaneStripView }) {
                strip.rowBackground = background
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // NSOutlineView resizes materialized rows without necessarily scheduling layout.
        resizeHostedCells()
    }

    override func layout() {
        super.layout()
        resizeHostedCells()
        // Covers a cell materialized or reused into an already-selected row,
        // which never goes through the selection setters above.
        refreshHostedPaneStrips()
    }

    private func resizeHostedCells() {
        for cell in subviews.compactMap({ $0 as? NSTableCellView }) {
            cell.frame = bounds
        }
    }
}

// MARK: - SidebarOutlineView

class SidebarOutlineView: NSOutlineView {
    weak var sidebarView: SidebarView?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let hitRow = row(at: point)
        guard hitRow >= 0, let sidebarItem = item(atRow: hitRow) as? SidebarItem else { return nil }

        let built: NSMenu?
        switch sidebarItem.kind {
        case .group(let group):
            built = sidebarView?.contextMenu(forGroupId: group.id)
        case .tab(let tab):
            built = sidebarView?.contextMenu(forTabId: tab.id, clickedRow: hitRow)
        }
        guard let built else { return nil }
        return menuHighlightingClickedRow(built) { super.menu(for: event) }
    }

    /// Hide the native disclosure triangle for all rows. Group rows use a
    /// custom caret button on the right side instead.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        return .zero
    }

    /// Returns the tab whose alert badge contains `point` (in outline-view coords), or nil.
    func tabForBadgeHit(at point: NSPoint) -> TabId? {
        let clickedRow = row(at: point)
        guard clickedRow >= 0,
              let sidebarItem = item(atRow: clickedRow) as? SidebarItem,
              case .tab(let tab) = sidebarItem.kind,
              let cell = view(atColumn: 0, row: clickedRow, makeIfNecessary: false),
              let badge = visibleAlertBadge(in: cell)
        else { return nil }
        let badgePoint = badge.convert(point, from: self)
        return badge.bounds.contains(badgePoint) ? tab.id : nil
    }

    // NSResponder: routes alert-badge clicks to .clearAlertsForTabs, and pre-empts
    // AppKit's deferred selection narrowing so multi-selection clicks feel snappy.
    override func mouseDown(with event: NSEvent) {
        sidebarView?.finishActiveRenameForPointerInteraction()
        let point = convert(event.locationInWindow, from: nil)
        if let tabId = tabForBadgeHit(at: point) {
            sidebarView?.runtime?.send(.clearAlertsForTabs(tabIds: [tabId]))
            return
        }
        let plainClick = event.modifierFlags.intersection([.shift, .command]).isEmpty
        let clickedRow = row(at: point)
        // Pre-empt AppKit's NSEvent.doubleClickInterval-deferred selection narrowing
        // on a plain click into a multi-selection: AppKit waits ~500ms after mouseUp
        // to disambiguate single vs. double click, which delays both the focus shift
        // AND the visual deselection of the other rows. Narrowing now via
        // selectRowIndexes synchronously fires selectionDidChange, which dispatches
        // .selectTab through the existing handler. AppKit's eventual narrowing
        // becomes a no-op.
        if plainClick,
           numberOfSelectedRows > 1,
           clickedRow >= 0,
           isRowSelected(clickedRow),
           let sidebarItem = item(atRow: clickedRow) as? SidebarItem,
           case .tab = sidebarItem.kind {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
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

    private var store = SidebarItemStore()
    private var tabItemCache: [TabId: SidebarItem] { store.tabItemCache }
    private var groupItemCache: [GroupId: SidebarItem] { store.groupItemCache }
    private var rootItems: [SidebarItem] { store.rootItems }
    private var childItems: [GroupId: [SidebarItem]] { store.childItems }
    private var currentModel: AppModel?

#if DANTERM_UI_TEST
    /// UI-harness seam that forces the next in-place update for selected rows down
    /// the visible-but-unmaterialized branch without depending on AppKit timing.
    var testForceNextNilCellTabIds: Set<TabId> = []
    var testForceNextNilCellGroupIds: Set<GroupId> = []
#endif

    /// Row structure of the last applied projection: single-group mode promotes
    /// tabs to root rows and shows no group rows. Stored rather than re-derived
    /// from `currentModel` so the data source and the drop handlers describe the
    /// rows that are actually mounted, and so this fact has one source.
    private var isSingleGroupMode = false

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

    /// Entry point for the reconcileSidebar pass: apply an ordered row-op script to the
    /// NSOutlineView, then reapply the view-owned selection. `isReloading` suppresses the
    /// selectionDidChange / collapse feedback loop while we mutate. Mirrors what the old
    /// imperative `reload(model:)` / `applySelection(...)` did (snapshot selection ->
    /// mutate -> resolveReloadSelection -> restore), but the mutation is now the granular
    /// op list rather than a full reloadData -- so the field editor and unchanged rows
    /// survive (an empty op list is a pure selection refresh).
    ///
    /// `projection` is what the rows are painted from; `model` serves the interaction
    /// path (context menus, drag and drop, selection) alone. Both come from one
    /// reconcile instant, so they cannot disagree.
    @discardableResult
    func applySidebarOps(
        _ ops: [SidebarRowOp],
        model: AppModel,
        projection: SidebarProjection,
        clearActiveRename: Bool
    ) -> (tabs: Set<TabId>, groups: Set<GroupId>) {
        isReloading = true
        defer { isReloading = false }
        let priorFocusedTabId = currentModel?.selectedTabId
        currentModel = model
        isSingleGroupMode = projection.isSingleGroupMode
        var unappliedTabIds = Set<TabId>()
        var unappliedGroupIds = Set<GroupId>()

        // End an orphaned inline edit before its row is removed/moved (the guard already
        // cleared the sidecar). Clearing the per-field associated object first makes the
        // resign-triggered textShouldEndEditing a no-op (no stray rename Msg).
        if clearActiveRename {
            cancelActiveInlineRename()
        } else {
            cancelAbandonedInlineRenameIfNeeded()
        }

        // Snapshot the user's multi-selection by tab id BEFORE the rows move.
        let priorSelectedTabIds = Set(selectedTabIds())

        for op in ops {
            applyRowOp(
                op,
                projection: projection,
                unappliedTabIds: &unappliedTabIds,
                unappliedGroupIds: &unappliedGroupIds)
        }

        // Reapply selection (NSOutlineView-owned) through the existing pure rule, then
        // refresh the forced-accent emphasis on the surviving rows.
        let restoreSet = resolveReloadSelection(
            priorSelectedTabIds: priorSelectedTabIds,
            liveTabIds: liveTabIds(in: model),
            selectedTabId: model.selectedTabId)
        applyRestoreSelection(
            restoreSet,
            selectedTabId: model.selectedTabId,
            projection: projection,
            unappliedTabIds: &unappliedTabIds,
            unappliedGroupIds: &unappliedGroupIds)
        // Empty-op cosmetic sweeps can leave already-visible row emphasis alone.
        // New/reused rows get their flag when NSOutlineView asks for a row view.
        if !ops.isEmpty || priorFocusedTabId != model.selectedTabId {
            refreshRowEmphasis(focusedTabId: model.selectedTabId)
        }

        // Reveal only on real focus changes; cosmetic reconcile sweeps must not
        // fight a user who has manually scrolled the focused row off-screen.
        if let selectedTabId = model.selectedTabId,
           selectedTabId != priorFocusedTabId,
           let item = tabItemCache[selectedTabId] {
            let row = outlineView.row(forItem: item)
            if row >= 0 { outlineView.scrollRowToVisible(row) }
        }
        return (unappliedTabIds, unappliedGroupIds)
    }

    /// Apply one ordered op, keeping the dataSource backing store (rootItems / childItems
    /// / item caches) in lockstep with the NSOutlineView mutation -- update the array,
    /// then issue the matching insert/remove with the same index (the contract for the
    /// animated row methods). Indices are relative to the running state (the op list is a
    /// sequential script). In single-group mode tabs are root rows (parent nil); in
    /// multi-group mode they are children of their group item.
    private func applyRowOp(
        _ op: SidebarRowOp,
        projection: SidebarProjection,
        unappliedTabIds: inout Set<TabId>,
        unappliedGroupIds: inout Set<GroupId>
    ) {
        switch op {
        case .reloadAll:
            rebuildAllRows(projection: projection)

        case .insertGroup(let id, let index):
            guard store.apply(op, projection: projection),
                  let item = groupItemCache[id],
                  let group = projection.group(id)
            else { return }
            outlineView.insertItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])
            // Inserts default expanded; match the projection (a setGroupCollapsed op may
            // also follow for a collapsed insert -- idempotent).
            if group.isCollapsed { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }

        case .removeGroup(let index):
            guard store.apply(op, projection: projection) else { return }
            outlineView.removeItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])

        case .reloadGroup(let id):
            _ = store.apply(op, projection: projection)
            if updateGroupRow(groupId: id, projection: projection) {
                unappliedGroupIds.insert(id)
            }

        case .setGroupCollapsed(let id, let collapsed):
            _ = store.apply(op, projection: projection)
            guard let item = groupItemCache[id] else { return }
            if collapsed { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
            applyGroupCollapseState(for: item, collapsed: collapsed)

        case .insertTab(_, let groupId, let index):
            guard store.apply(op, projection: projection) else { return }
            if isSingleGroupMode {
                outlineView.insertItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])
            } else {
                guard let parent = groupItemCache[groupId] else { return }
                outlineView.insertItems(at: IndexSet(integer: index), inParent: parent, withAnimation: [])
            }

        case .removeTab(let groupId, let index):
            guard store.apply(op, projection: projection) else { return }
            if isSingleGroupMode {
                outlineView.removeItems(at: IndexSet(integer: index), inParent: nil, withAnimation: [])
            } else {
                guard let parent = groupItemCache[groupId] else { return }
                outlineView.removeItems(at: IndexSet(integer: index), inParent: parent, withAnimation: [])
            }

        case .reloadTab(let id):
            _ = store.apply(op, projection: projection)
            if updateTabRow(tabId: id, projection: projection) {
                unappliedTabIds.insert(id)
            }
        }
    }

    /// reloadAll executor: rebuild the backing item lists and reloadData (first reconcile
    /// and single<->multi group-mode flips). Selection is restored by the caller after.
    private func rebuildAllRows(projection: SidebarProjection) {
        store.apply(.reloadAll, projection: projection)
        outlineView.reloadData()
        restoreCollapseState(projection: projection)
    }

    /// Re-apply each group's expanded/collapsed state after a full reloadData (which
    /// resets expansion). No-op in single-group mode (tabs are roots, no group rows).
    private func restoreCollapseState(projection: SidebarProjection) {
        guard !isSingleGroupMode else { return }
        for group in projection.groups {
            guard let item = groupItemCache[group.id] else { continue }
            if group.isCollapsed { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
        }
    }

    /// A cell dequeued from NSOutlineView's reuse pool can carry a stranded inline
    /// rename: AppKit aborts a live field editor on programmatic selection changes and
    /// collapseItem with NO NSTextFieldDelegate callback, leaving `isEditable = true`.
    /// An editable NSTextField reports no intrinsic width, so a poisoned cell renders
    /// its title ~2pt wide no matter what stringValue holds (the 2026-06-11 blank
    /// tab-title incident). Belt-and-braces reset at the reuse boundary.
    private func resetRecycledRenameState(_ cell: NSTableCellView) {
        guard let textField = cell.textField else { return }
        if textField.currentEditor() != nil { textField.abortEditing() }
        guard textField.isEditable else { return }
        textField.isEditable = false
        objc_setAssociatedObject(textField, &AssociatedKeys.renameTarget, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Commit a live rename before an outline interaction lets AppKit change selection.
    /// The delegate's click-away path deliberately leaves the clicked destination focused.
    func finishActiveRenameForPointerInteraction() {
        guard let target = runtime?.viewLocalState.sidebarRenameTarget,
              let textField = textField(for: target)
        else { return }
        guard textField.currentEditor() != nil else {
            cancelAbandonedInlineRenameIfNeeded()
            return
        }
        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        objc_setAssociatedObject(
            textField, &AssociatedKeys.renameTarget, nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        textField.abortEditing()
        finishInlineRename(textField: textField, target: target)

        switch target {
        case .tab(let id):
            let name: String? = newName.isEmpty ? nil : newName
            runtime?.send(.renameTab(id: id, name: name))
        case .group(let id):
            guard !newName.isEmpty else { return }
            runtime?.send(.renameGroup(id: id, name: newName))
        }
    }

    /// Cancel a structurally orphaned rename without dispatching a rename message.
    private func cancelActiveInlineRename() {
        for row in 0..<outlineView.numberOfRows {
            guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let textField = cell.textField,
                  let target = objc_getAssociatedObject(
                    textField, &AssociatedKeys.renameTarget) as? RenameTarget
            else { continue }
            objc_setAssociatedObject(textField, &AssociatedKeys.renameTarget, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if textField.currentEditor() != nil { textField.abortEditing() }
            finishInlineRename(textField: textField, target: target)
            break
        }
    }

    /// Reconciliation owns the rename sidecar, so it also repairs AppKit silently
    /// discarding the matching field editor before delegate cleanup can run.
    private func cancelAbandonedInlineRenameIfNeeded() {
        guard let target = runtime?.viewLocalState.sidebarRenameTarget else { return }
        guard let textField = textField(for: target), textField.currentEditor() != nil else {
            runtime?.viewLocalState.sidebarRenameTarget = nil
            if let textField = textField(for: target) {
                finishInlineRename(textField: textField, target: target)
            }
            return
        }
    }

    private func textField(for target: RenameTarget) -> NSTextField? {
        let item: SidebarItem? = {
            switch target {
            case .tab(let id): return tabItemCache[id]
            case .group(let id): return groupItemCache[id]
            }
        }()
        guard let item else { return nil }
        let row = outlineView.row(forItem: item)
        guard row >= 0,
              let cell = outlineView.view(
                atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
        else { return nil }
        return cell.textField
    }

    /// Restore AppKit selection so multi-selection stays live while the focused
    /// row remains the last selected row for shift-click and keyboard range use.
    private func applyRestoreSelection(
        _ restoreSet: Set<TabId>,
        selectedTabId: TabId?,
        projection: SidebarProjection,
        unappliedTabIds: inout Set<TabId>,
        unappliedGroupIds: inout Set<GroupId>
    ) {
        var nonFocusRows = IndexSet()
        var focusRow: Int? = nil
        for id in restoreSet {
            guard let item = tabItemCache[id] else { continue }
            let row = outlineView.row(forItem: item)
            guard row >= 0 else { continue }
            if id == selectedTabId {
                focusRow = row
            } else {
                nonFocusRows.insert(row)
            }
        }

        // A cosmetic sweep often asks for the selection NSOutlineView already has.
        // Skip only when both the selected set and focused lead row already match
        // the two-phase restore below.
        let liveSelection = outlineView.selectedRowIndexes
        var targetSelection = restoreSet.isEmpty ? liveSelection : nonFocusRows
        if !restoreSet.isEmpty, let f = focusRow { targetSelection.insert(f) }
        let leadMatches = focusRow.map { outlineView.selectedRow == $0 } ?? true
        if targetSelection == liveSelection && leadMatches { return }

        // A programmatic selectRowIndexes that CHANGES the selection aborts a live
        // field editor with NO NSTextFieldDelegate callback, stranding
        // isEditable = true on the cell (and from there into the reuse pool -- the
        // 2026-06-11 blank-tab-title bug; Cmd-T's spawn+select reconcile is exactly
        // this). End the edit through the proper path first, then resync the row
        // from the new model since the guard suppressed its reload while editing.
        if let target = runtime?.viewLocalState.sidebarRenameTarget {
            var intended = nonFocusRows
            if let f = focusRow { intended.insert(f) }
            let willChangeSelection = (focusRow != nil || !nonFocusRows.isEmpty || !restoreSet.isEmpty)
                && intended != outlineView.selectedRowIndexes
            if willChangeSelection {
                runtime?.viewLocalState.sidebarRenameTarget = nil
                cancelActiveInlineRename()
                switch target {
                case .tab(let id):
                    if updateTabRow(tabId: id, projection: projection) {
                        unappliedTabIds.insert(id)
                    }
                case .group(let id):
                    if updateGroupRow(groupId: id, projection: projection) {
                        unappliedGroupIds.insert(id)
                    }
                }
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
        } else if !restoreSet.isEmpty {
            // The target can be hidden inside a collapsed group. The granular op path
            // may not reloadData, so clear any stale visible row selection here.
            outlineView.selectRowIndexes(
                IndexSet(), byExtendingSelection: false)
        }
    }

    /// Recompute row emphasis in place after a selection-only update.
    private func refreshRowEmphasis(focusedTabId: TabId?) {
        for row in 0..<outlineView.numberOfRows {
            guard let rowView = outlineView.rowView(
                atRow: row, makeIfNecessary: false) as? SidebarRowView else { continue }
            let rowTabId: TabId? = {
                guard let item = outlineView.item(atRow: row) as? SidebarItem,
                      case .tab(let tab) = item.kind else { return nil }
                return tab.id
            }()
            rowView.forceEmphasizedSelection = shouldForceSidebarRowEmphasis(
                rowTabId: rowTabId,
                focusedTabId: focusedTabId)
        }
    }

    /// Mutate an existing tab cell's subviews in place. Returns true only when an
    /// on-screen row could not fetch its cell, so the caller should retain the old
    /// projection and retry the reload in a later reconcile pass.
    func updateTabRow(tabId: TabId, projection: SidebarProjection) -> Bool {
        guard let item = store.updateTabItem(tabId: tabId, projection: projection) else { return false }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return false }
        let isVisible = outlineView.visibleRect.intersects(outlineView.rect(ofRow: row))
#if DANTERM_UI_TEST
        if testForceNextNilCellTabIds.remove(tabId) != nil {
            return isVisible
        }
#endif
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
        else { return isVisible }
        guard case .tab(let tab) = item.kind else { return false }
        let isEditing = cell.textField?.currentEditor() != nil
        configureTabCell(cell, tab: tab, skipTitle: isEditing)
        return false
    }

    /// In-place group row update. Returns true only when an on-screen row could
    /// not fetch its cell, so the caller should retain and retry the reload attrs.
    func updateGroupRow(groupId: GroupId, projection: SidebarProjection) -> Bool {
        guard let item = store.updateGroupItem(groupId: groupId, projection: projection) else { return false }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return false }
        let isVisible = outlineView.visibleRect.intersects(outlineView.rect(ofRow: row))
#if DANTERM_UI_TEST
        if testForceNextNilCellGroupIds.remove(groupId) != nil {
            return isVisible
        }
#endif
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
        else { return isVisible }
        guard case .group(let group) = item.kind else { return false }
        let isEditing = cell.textField?.currentEditor() != nil
        configureGroupCell(cell, group: group, skipTitle: isEditing)
        return false
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
        // Mirror the rename target into the sidecar -- the reconciler's authoritative
        // "which row is editing" signal. Set AFTER makeFirstResponder: if that ended a
        // prior inline edit, the prior field's finish path cleared the (shared) sidecar
        // synchronously, so setting it here ensures this target wins. Synchronous and
        // before any send(), so a row never reconciles mid-edit.
        runtime?.viewLocalState.sidebarRenameTarget = target
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
                bellBadge.updateBadge(count: group.unreadAlertCount)
                if !collapsed { bellBadge.isHidden = true }
            }
            if let tabCountBadge = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "groupTabCountBadge" }) as? NSTextField {
                tabCountBadge.stringValue = "\(group.tabCount)"
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

    /// Interaction path: takes the row's id and reads enablement off the live
    /// model, so the menu never depends on what the row last painted.
    func contextMenu(forGroupId groupId: GroupId) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(contextNewTab(_:)), keyEquivalent: "")
        newTabItem.target = self
        newTabItem.representedObject = groupId.rawValue
        menu.addItem(newTabItem)

        menu.addItem(NSMenuItem.separator())

        let renameItem = NSMenuItem(title: "Rename Group", action: #selector(contextRenameGroup(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = groupId.rawValue
        menu.addItem(renameItem)

        let deleteItem = NSMenuItem(title: "Delete Group", action: #selector(contextDeleteGroup(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = groupId.rawValue
        deleteItem.isEnabled = (currentModel?.groups.count ?? 0) > 1
        menu.addItem(deleteItem)

        return menu
    }

    /// Tabs currently multi-selected in the sidebar. Steady-state non-empty
    /// because allowsEmptySelection=false (line 191). The compactMap's
    /// `case .tab` guard is defensive: outlineView(_:shouldSelectItem:)
    /// already prevents group rows from entering the selection, so the
    /// filter mirrors the reload-snapshot pattern at line ~285 for
    /// consistency rather than covering a real steady-state case.
    /// Feeds AppDelegate's menubar batch router so Tab menu actions act on the
    /// user's real selection instead of just the focused tab.
    func selectedTabIds() -> [TabId] {
        return outlineView.selectedRowIndexes.compactMap { row in
            guard let item = outlineView.item(atRow: row) as? SidebarItem,
                  case .tab(let tab) = item.kind else { return nil }
            return tab.id
        }
    }

    /// Public: returns visible tab ids in top-to-bottom row order.
    /// Group rows and collapsed-group children are excluded by NSOutlineView's
    /// visible row model.
    func visibleTabIdsInRowOrder() -> [TabId] {
        return (0..<outlineView.numberOfRows).compactMap { row in
            guard let item = outlineView.item(atRow: row) as? SidebarItem,
                  case .tab(let tab) = item.kind else { return nil }
            return tab.id
        }
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
    func contextMenu(forTabId tabId: TabId, clickedRow: Int) -> NSMenu? {
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
        menu.autoenablesItems = false

        // Rename Tab — singular-only, always targets the clicked row.
        let renameItem = NSMenuItem(
            title: "Rename Tab",
            action: #selector(contextRenameTab(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = tabId.rawValue
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
        colorSubmenu.autoenablesItems = false
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

    /// Toggle-off: re-applying a color that every targeted tab already has
    /// clears them all. Resolved at the dispatcher before sending; the Msg
    /// layer always replaces. The policy lives in `resolveColorForBatch`
    /// and is shared with the keyboard/menu path in AppDelegate.
    @objc private func contextSetTabColors(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? SetTabColorsInfo,
              !info.tabIds.isEmpty,
              let model = runtime?.model else { return }
        let resolved = resolveColorForBatch(
            tabIds: info.tabIds, requested: info.color, in: model)
        runtime?.send(.setTabColors(tabIds: info.tabIds, color: resolved))
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
        runtime?.send(.clearCustomTitles(tabIds: box.ids))
    }

    @objc private func contextClearAlerts(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? TabIdsBox,
              !box.ids.isEmpty else { return }
        runtime?.send(.clearAlertsForTabs(tabIds: box.ids))
    }

    /// Close the selected tab batch through one confirmation flow so mixed
    /// simple and confirmation-needed tabs are handled uniformly.
    @objc private func contextCloseTabs(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? TabIdsBox else { return }
        runtime?.send(.requestCloseTabs(ids: box.ids))
    }

    /// Mirrors AppDelegate.newGroup: send the action, then begin inline
    /// rename on the freshly-created group (diffed via group-id snapshot
    /// against currentModel, which reconcileSidebar refreshed during send).
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

    private func makeGroupCell(for group: SidebarGroupProjection) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier("GroupCell")

        if let existing = outlineView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
            resetRecycledRenameState(existing)
            configureGroupCell(existing, group: group)
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = cellId

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .preferredFont(forTextStyle: .headline)
        textField.lineBreakMode = .byTruncatingTail
        textField.isEditable = false
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        accessoryStack.setHuggingPriority(.required, for: .horizontal)
        accessoryStack.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            textField.trailingAnchor.constraint(equalTo: accessoryStack.leadingAnchor, constant: -4),
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
    private func configureGroupCell(
        _ cell: NSTableCellView, group: SidebarGroupProjection, skipTitle: Bool = false
    ) {
        if !skipTitle {
            cell.textField?.stringValue = group.name
        }
        cell.textField?.tag = group.id.rawValue.hashValue
        // Hide separator for the first group
        if let separator = cell.subviews.first(where: { $0.identifier?.rawValue == "groupSeparator" }) {
            separator.isHidden = group.isFirst
        }
        if let stack = cell.subviews.first(where: { $0.identifier?.rawValue == "groupAccessoryStack" }) as? NSStackView {
            if let caretButton = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "groupCaretButton" }) as? NSButton {
                let symbolName = group.isCollapsed ? "chevron.right" : "chevron.down"
                caretButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Toggle Group")
                objc_setAssociatedObject(caretButton, &AssociatedKeys.groupId, group.id.rawValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            if let bellBadge = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "groupBellBadge" }) as? NSTextField {
                bellBadge.updateBadge(count: group.unreadAlertCount)
                if !group.isCollapsed { bellBadge.isHidden = true }
            }
            if let tabCountBadge = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "groupTabCountBadge" }) as? NSTextField {
                tabCountBadge.stringValue = "\(group.tabCount)"
                tabCountBadge.isHidden = !group.isCollapsed
            }
        }
    }

    private func makeTabCell(for tab: SidebarTabProjection) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier("TabCell")
        let subtitleId = NSUserInterfaceItemIdentifier("subtitle")
        let bellDotId = NSUserInterfaceItemIdentifier("bellDot")
        let colorStripeId = NSUserInterfaceItemIdentifier("colorStripe")
        let accessoryStackId = NSUserInterfaceItemIdentifier("tabAccessoryStack")
        let leadingStackId = NSUserInterfaceItemIdentifier("tabLeadingStack")
        let chipId = NSUserInterfaceItemIdentifier("tabChip")
        let paneStripId = NSUserInterfaceItemIdentifier("tabPaneStrip")

        let cell: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
            resetRecycledRenameState(existing)
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
            textField.font = .systemFont(ofSize: NSFont.systemFontSize)
            textField.lineBreakMode = .byTruncatingTail
            textField.isEditable = false
            textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textField.delegate = self
            cell.textField = textField

            let chip = ChipView(kind: .terminal, edge: ChipArtwork.sidebarSize)
            chip.identifier = chipId

            let leadingStack = NSStackView(views: [chip, textField])
            leadingStack.translatesAutoresizingMaskIntoConstraints = false
            leadingStack.orientation = .horizontal
            leadingStack.alignment = .centerY
            leadingStack.spacing = 4
            leadingStack.identifier = leadingStackId
            leadingStack.setHuggingPriority(.defaultLow, for: .horizontal)
            cell.addSubview(leadingStack)

            let subtitleField = NSTextField(labelWithString: "")
            subtitleField.identifier = subtitleId
            subtitleField.translatesAutoresizingMaskIntoConstraints = false
            subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            subtitleField.textColor = .secondaryLabelColor
            subtitleField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(subtitleField)

            // Occupies the subtitle's line, and only one of the two is ever shown.
            let paneStrip = PaneStripView()
            paneStrip.identifier = paneStripId
            paneStrip.isHidden = true
            cell.addSubview(paneStrip)

            let bellBadge = NSTextField.makeBadge()
            bellBadge.identifier = bellDotId
            let accessoryStack = NSStackView(views: [bellBadge])
            accessoryStack.translatesAutoresizingMaskIntoConstraints = false
            accessoryStack.orientation = .horizontal
            accessoryStack.alignment = .top
            accessoryStack.spacing = 3
            accessoryStack.identifier = accessoryStackId
            accessoryStack.setHuggingPriority(.required, for: .horizontal)
            accessoryStack.setContentCompressionResistancePriority(.required, for: .horizontal)
            cell.addSubview(accessoryStack)

            NSLayoutConstraint.activate([
                colorStripe.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                colorStripe.topAnchor.constraint(equalTo: cell.topAnchor),
                colorStripe.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
                colorStripe.widthAnchor.constraint(equalToConstant: 5),
                accessoryStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                accessoryStack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                leadingStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                leadingStack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                leadingStack.trailingAnchor.constraint(equalTo: accessoryStack.leadingAnchor, constant: -4),
                subtitleField.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
                subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: accessoryStack.leadingAnchor, constant: -4),
                subtitleField.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 1),
                paneStrip.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
                // Equal, not <=: the strip has no intrinsic width and fits itself
                // to whatever it is given, so it needs a definite one.
                paneStrip.trailingAnchor.constraint(
                    equalTo: accessoryStack.leadingAnchor, constant: -4),
                paneStrip.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 2),
            ])
        }

        configureTabCell(cell, tab: tab)
        return cell
    }

    /// Apply current tab state to an existing cell's subviews. Shared by
    /// makeTabCell (initial population) and updateTabRow (in-place refresh).
    /// When skipTitle is true the text field is left untouched so the field
    /// editor isn't clobbered during inline rename.
    private func configureTabCell(
        _ cell: NSTableCellView, tab: SidebarTabProjection, skipTitle: Bool = false
    ) {
        let subtitleId = NSUserInterfaceItemIdentifier("subtitle")
        let bellDotId = NSUserInterfaceItemIdentifier("bellDot")
        let jumpBadgeId = NSUserInterfaceItemIdentifier("jumpModeBadge")
        let colorStripeId = NSUserInterfaceItemIdentifier("colorStripe")
        let accessoryStackId = NSUserInterfaceItemIdentifier("tabAccessoryStack")
        let leadingStackId = NSUserInterfaceItemIdentifier("tabLeadingStack")
        let chipId = NSUserInterfaceItemIdentifier("tabChip")
        let paneStripId = NSUserInterfaceItemIdentifier("tabPaneStrip")

        if !skipTitle {
            cell.textField?.stringValue = tab.displayTitle
        }
        // A multi-pane tab spends its second line enumerating its panes; only a
        // single-pane tab shows a cwd there.
        if let subtitleField = cell.subviews.first(where: { $0.identifier == subtitleId }) as? NSTextField {
            subtitleField.stringValue = tab.subtitle ?? ""
            subtitleField.isHidden = tab.subtitle == nil || !tab.paneChips.isEmpty
        }
        if let paneStrip = cell.subviews.first(where: { $0.identifier == paneStripId }) as? PaneStripView {
            paneStrip.chips = tab.paneChips
            paneStrip.isHidden = tab.paneChips.isEmpty
        }
        if let stack = cell.subviews.first(where: { $0.identifier == accessoryStackId }) as? NSStackView {
            if let bellBadge = stack.arrangedSubviews.first(where: { $0.identifier == bellDotId }) as? NSTextField {
                bellBadge.updateBadge(count: tab.unreadAlertCount)
            }
        }
        if let leadingStack = cell.subviews.first(where: { $0.identifier == leadingStackId }) as? NSStackView,
           let chip = leadingStack.arrangedSubviews.first(where: { $0.identifier == chipId }) as? ChipView
        {
            // Outside the skipTitle guard: an inline rename owns the title field,
            // not the chip, and the pane can attach an agent mid-rename.
            chip.kind = tab.chipKind
        }
        if !skipTitle,
           let leadingStack = cell.subviews.first(where: { $0.identifier == leadingStackId }) as? NSStackView
        {
            let existingJumpBadge = leadingStack.arrangedSubviews.first(where: { $0.identifier == jumpBadgeId }) as? NSTextField
            if let key = tab.jumpKey {
                let badge = existingJumpBadge ?? makeJumpModeBadge(identifier: jumpBadgeId)
                badge.stringValue = String(key).uppercased()
                badge.isHidden = false
                if existingJumpBadge == nil {
                    leadingStack.insertArrangedSubview(badge, at: 0)
                }
            } else if let existingJumpBadge {
                leadingStack.removeArrangedSubview(existingJumpBadge)
                existingJumpBadge.removeFromSuperview()
            }
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

    private func makeJumpModeBadge(identifier: NSUserInterfaceItemIdentifier) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .alternateSelectedControlTextColor
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        label.layer?.cornerRadius = 5
        label.layer?.masksToBounds = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            label.heightAnchor.constraint(equalToConstant: 20),
        ])
        return label
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
        // Clear the sidecar first -- this is the common sink for every finish path
        // (doCommandBy Enter/Esc and textShouldEndEditing click-away). It runs
        // synchronously before doCommandBy's synchronous sends and before
        // textShouldEndEditing's deferred send, so the next reconcile sees no rename
        // target and applies the row's reload normally.
        runtime?.viewLocalState.sidebarRenameTarget = nil
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

// `RenameTarget` now lives in Model.swift (hoisted so the reconciler can read the
// inline-rename target via the ViewLocalState sidecar). The associated-object dance
// below stays as the field editor's own bookkeeping; the sidecar is the copy the
// reconciler reads.
// Nothing reads or writes these bytes; only `&key` is taken, for an address that
// stays put. `nonisolated(unsafe)` states that -- there is no shared state here
// to protect, just a stable location.
private enum AssociatedKeys {
    nonisolated(unsafe) static var groupId: UInt8 = 0
    nonisolated(unsafe) static var renameTarget: UInt8 = 0
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
