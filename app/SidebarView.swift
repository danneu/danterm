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
        for cell in subviews.compactMap({ $0 as? SidebarTabCellView }) {
            cell.paneStrip.rowBackground = background
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
              let cell = view(
                atColumn: 0, row: clickedRow,
                makeIfNecessary: false) as? SidebarTabCellView,
              !cell.alertBadge.isHidden
        else { return nil }
        let badgePoint = cell.alertBadge.convert(point, from: self)
        return cell.alertBadge.bounds.contains(badgePoint) ? tab.id : nil
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

/// The view's record of which text field owns the live inline rename, and the
/// only way to give that record up.
///
/// The view has to keep this record because AppKit destroys a field editor with
/// no delegate callback, so the model cannot derive who owns one. Two records of
/// one session then have to stay in step, and `take()` is what makes that
/// structural instead of conventional: it is the sole clear, and it hands back the
/// end the model is owed, so no teardown site can drop a session silently the way
/// the reuse-pool branch used to.
private struct ActiveRenameSlot {
    private var current: (session: SidebarRenameSession, textField: NSTextField)?

    /// What the caller needs to finish the teardown, plus the identity that names
    /// the session in everything it reports.
    struct TornDown {
        let session: RenameSessionId
        let target: RenameTarget
        let textField: NSTextField

        /// The end this teardown owes the model.
        var end: Msg { .sidebarRenameEnded(session: session) }
    }

    var target: RenameTarget? { current?.session.target }
    var textField: NSTextField? { current?.textField }
    var isOpen: Bool { current != nil }

    func owns(_ textField: NSTextField) -> Bool { current?.textField === textField }
    func isSession(_ id: RenameSessionId) -> Bool { current?.session.id == id }

    mutating func open(_ session: SidebarRenameSession, textField: NSTextField) {
        current = (session, textField)
    }

    /// Clears the record and returns what its teardown owes: nil when no session
    /// is open, so a caller can always ask without knowing.
    mutating func take() -> TornDown? {
        guard let taken = current else { return nil }
        current = nil
        return TornDown(
            session: taken.session.id,
            target: taken.session.target,
            textField: taken.textField)
    }
}

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
    private var appliedProjection: SidebarProjection?
    private var activeRename = ActiveRenameSlot()

    /// Identifies the row whose exact field owns the live inline rename session.
    var activeRenameTarget: RenameTarget? { activeRename.target }

    /// Fetches the cell already materialized for a row, or nothing when AppKit has
    /// not built one. Given rather than read straight off the outline view, because
    /// "on screen but not yet materialized" is a real state the reconcile loop must
    /// retry through, and nothing else can put AppKit into it on demand.
    lazy var materializedCell: (Int) -> NSView? = { [weak outlineView] row in
        outlineView?.view(atColumn: 0, row: row, makeIfNecessary: false)
    }

    /// Row structure of the last applied projection: single-group mode promotes
    /// tabs to root rows and shows no group rows.
    private var isSingleGroupMode: Bool {
        appliedProjection?.isSingleGroupMode ?? false
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
        doubleClickRow(outlineView.clickedRow)
    }

    /// Asks the model to begin the rename the double-clicked row names. Split
    /// from the `@objc` action so a caller can name the row: `clickedRow` is
    /// only meaningful inside AppKit's own event dispatch.
    func doubleClickRow(_ row: Int) {
        guard row >= 0 else { return }
        guard let sidebarItem = outlineView.item(atRow: row) as? SidebarItem else { return }
        switch sidebarItem.kind {
        case .tab(let tab):
            runtime?.send(.beginSidebarRename(target: .tab(tab.id)))
        case .group(let group):
            runtime?.send(.beginSidebarRename(target: .group(group.id)))
        }
    }

    @objc private func caretClicked(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard row >= 0,
              let item = outlineView.item(atRow: row) as? SidebarItem,
              case .group = item.kind else { return }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
    }

    // MARK: - Reconcile & Reload

    // reconcile-pass-lint: no-send begin
    //
    // Everything down to the matching end marker runs inside the sidebar
    // reconcile pass. A pass originates no Msg: a fact it discovers goes to
    // `report(_:)`, and the runtime's outbox dispatches it after the sweep, once
    // every pass cache has advanced. See the Read-Only Model Rule in
    // docs/design/2026-05-27-model-driven-view-reconciliation.md.
    // scripts/reconcile-pass-lint.sh enforces this region.

    /// Executes row ops for `SidebarReconcileDriver`, its only production caller, then
    /// reapplies the view-owned selection. `isReloading` suppresses the
    /// selectionDidChange / collapse feedback loop while we mutate. Mirrors what the old
    /// imperative `reload(model:)` / `applySelection(...)` did (snapshot selection ->
    /// mutate -> resolveReloadSelection -> restore), but the mutation is now the granular
    /// op list rather than a full reloadData -- so the field editor and unchanged rows
    /// survive (an empty op list is a pure selection refresh).
    ///
    /// `projection` paints the rows and supplies every interaction fact, so handlers
    /// always describe the same state that NSOutlineView currently displays.
    ///
    /// A fact the pass discovers about the view -- today, that a live rename ended
    /// and what its draft was -- goes into the runtime's outbox, which delivers it
    /// only after this sweep returns. The pass must not send it itself: a send from
    /// mid-traversal re-enters the whole sweep before the driver advances its
    /// projection cache, so the nested pass would diff the new model against a
    /// stale cache and issue row ops against an outline that is mid-mutation.
    @discardableResult
    func applySidebarOps(
        _ ops: [SidebarRowOp],
        projection: SidebarProjection,
        renameTargetToEnd: RenameTarget?
    ) -> (
        tabs: Set<TabId>,
        groups: Set<GroupId>,
        groupRenders: [GroupId: SidebarGroupProjection.Rendered]
    ) {
        isReloading = true
        defer { isReloading = false }
        let priorFocusedTabId = appliedProjection?.selectedTabId
        let priorRename = appliedProjection?.rename
        appliedProjection = projection
        var unappliedTabIds = Set<TabId>()
        var unappliedGroupIds = Set<GroupId>()
        var appliedGroupRenders: [GroupId: SidebarGroupProjection.Rendered] = [:]

        // End an orphaned inline edit before its row is removed or moved. The view
        // clears its session first, so a resign-triggered delegate callback is a no-op.
        if let renameTargetToEnd {
            endActiveRename(renameTargetToEnd)
        } else {
            cancelAbandonedInlineRenameIfNeeded()
        }

        // Snapshot the user's multi-selection by tab id BEFORE the rows move.
        let priorSelectedTabIds = Set(selectedTabIds())

        for op in ops {
            let shouldContinue = applyRowOp(
                op,
                projection: projection,
                unappliedTabIds: &unappliedTabIds,
                unappliedGroupIds: &unappliedGroupIds,
                appliedGroupRenders: &appliedGroupRenders)
            if !shouldContinue { break }
        }

        // Reapply selection (NSOutlineView-owned) through the existing pure rule, then
        // refresh the forced-accent emphasis on the surviving rows.
        let restoreSet = resolveReloadSelection(
            priorSelectedTabIds: priorSelectedTabIds,
            liveTabIds: Set(projection.groups.flatMap(\.tabs).map(\.id)),
            selectedTabId: projection.selectedTabId)
        applyRestoreSelection(
            restoreSet,
            selectedTabId: projection.selectedTabId,
            projection: projection,
            unappliedTabIds: &unappliedTabIds,
            unappliedGroupIds: &unappliedGroupIds,
            appliedGroupRenders: &appliedGroupRenders)
        // Empty-op cosmetic sweeps can leave already-visible row emphasis alone.
        // New/reused rows get their flag when NSOutlineView asks for a row view.
        if !ops.isEmpty || priorFocusedTabId != projection.selectedTabId {
            refreshRowEmphasis(focusedTabId: projection.selectedTabId)
        }

        // Reveal only on real focus changes; cosmetic reconcile sweeps must not
        // fight a user who has manually scrolled the focused row off-screen.
        if let selectedTabId = projection.selectedTabId,
           selectedTabId != priorFocusedTabId,
           let item = tabItemCache[selectedTabId] {
            let row = outlineView.row(forItem: item)
            if row >= 0 { outlineView.scrollRowToVisible(row) }
        }
        // The comparison is on the session, not the row: a second rename of a row
        // whose editor AppKit destroyed silently is a new session, and the view has
        // to open an editor for it.
        if let request = projection.rename,
           request.id != priorRename?.id,
           !activeRename.isSession(request.id) {
            beginRenaming(request)
        }
        return (unappliedTabIds, unappliedGroupIds, appliedGroupRenders)
    }

    /// Apply one ordered op and return whether the current script remains valid.
    private func applyRowOp(
        _ op: SidebarRowOp,
        projection: SidebarProjection,
        unappliedTabIds: inout Set<TabId>,
        unappliedGroupIds: inout Set<GroupId>,
        appliedGroupRenders: inout [GroupId: SidebarGroupProjection.Rendered]
    ) -> Bool {
        switch store.apply(op, projection: projection) {
        case .reloadAll(let collapseStates):
            if let target = activeRenameTarget {
                endActiveRename(target)
            }
            rebuildAllRows(groupCollapseStates: collapseStates)
            for group in projection.groups where !projection.isSingleGroupMode {
                appliedGroupRenders[group.id] = group.rendered
            }
            return false

        case .insert(_, let index, let parent, let collapseState):
            outlineView.insertItems(
                at: IndexSet(integer: index),
                inParent: parent,
                withAnimation: [])
            if let collapseState {
                if collapseState.collapsed {
                    outlineView.collapseItem(collapseState.item)
                } else {
                    outlineView.expandItem(collapseState.item)
                }
                if case .group(let group) = collapseState.item.kind {
                    appliedGroupRenders[group.id] = group.rendered
                }
            }
            return true

        case .remove(_, let index, let parent):
            outlineView.removeItems(
                at: IndexSet(integer: index),
                inParent: parent,
                withAnimation: [])
            return true

        case .setGroupCollapsed(let item, let collapsed):
            if collapsed { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
            if case .group(let group) = item.kind {
                if let applied = updateGroupRow(item) {
                    appliedGroupRenders[group.id] = applied
                } else {
                    unappliedGroupIds.insert(group.id)
                }
            }
            return true

        case .repaint(let item):
            switch item.kind {
            case .tab(let tab):
                if updateTabRow(item) { unappliedTabIds.insert(tab.id) }
            case .group(let group):
                if let applied = updateGroupRow(item) {
                    appliedGroupRenders[group.id] = applied
                } else {
                    unappliedGroupIds.insert(group.id)
                }
            }
            return true
        }
    }

    /// Reload the rebuilt store and restore the group states it returned.
    private func rebuildAllRows(groupCollapseStates: [SidebarGroupCollapseState]) {
        outlineView.reloadData()
        for state in groupCollapseStates {
            if state.collapsed {
                outlineView.collapseItem(state.item)
            } else {
                outlineView.expandItem(state.item)
            }
        }
    }

    /// A cell dequeued from NSOutlineView's reuse pool can carry a stranded inline
    /// rename: AppKit aborts a live field editor on programmatic selection changes and
    /// collapseItem with NO NSTextFieldDelegate callback, leaving `isEditable = true`.
    /// An editable NSTextField reports no intrinsic width, so a poisoned cell renders
    /// its title ~2pt wide no matter what stringValue holds (the 2026-06-11 blank
    /// tab-title incident). Belt-and-braces reset at the reuse boundary.
    func resetRecycledRenameState(_ cell: NSTableCellView) {
        guard let textField = cell.textField else { return }
        if activeRename.owns(textField), let torn = activeRename.take() {
            report([torn.end])
        }
        if textField.currentEditor() != nil { textField.abortEditing() }
        textField.isEditable = false
    }

    /// Commits and tears down the live rename, reporting what the teardown owes the
    /// model: the commit carrying the draft text, then the end of ownership.
    private func finishActiveRename() {
        guard activeRename.isOpen else { return }
        guard activeRename.textField?.currentEditor() != nil else {
            cancelAbandonedInlineRenameIfNeeded()
            return
        }
        guard let torn = activeRename.take() else { return }
        let newName = torn.textField.stringValue.trimmingCharacters(in: .whitespaces)
        torn.textField.abortEditing()
        finishInlineRename(textField: torn.textField, target: torn.target)
        report(renameCompletionMessages(
            isConfirm: true, session: torn.session,
            target: torn.target, newName: newName))
    }

    /// Ends the matching view-owned session before a structural operation invalidates it.
    /// The projection guard has already decided this rename is over, so the view only
    /// tears the session down and reports the end.
    func endActiveRename(_ target: RenameTarget) {
        guard activeRename.target == target, let torn = activeRename.take() else { return }
        if torn.textField.currentEditor() != nil { torn.textField.abortEditing() }
        finishInlineRename(textField: torn.textField, target: torn.target)
        report([torn.end])
    }

    /// Repairs AppKit silently discarding the owned field editor before delegate cleanup.
    /// The same repair serves a pointer interaction and a pass, because neither one
    /// has to guess how the end is delivered.
    private func cancelAbandonedInlineRenameIfNeeded() {
        guard activeRename.isOpen,
              activeRename.textField?.currentEditor() == nil,
              let torn = activeRename.take() else { return }
        finishInlineRename(textField: torn.textField, target: torn.target)
        report([torn.end])
    }

    /// Restore AppKit selection so multi-selection stays live while the focused
    /// row remains the last selected row for shift-click and keyboard range use.
    private func applyRestoreSelection(
        _ restoreSet: Set<TabId>,
        selectedTabId: TabId?,
        projection: SidebarProjection,
        unappliedTabIds: inout Set<TabId>,
        unappliedGroupIds: inout Set<GroupId>,
        appliedGroupRenders: inout [GroupId: SidebarGroupProjection.Rendered]
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
        if let target = activeRenameTarget {
            var intended = nonFocusRows
            if let f = focusRow { intended.insert(f) }
            let willChangeSelection = (focusRow != nil || !nonFocusRows.isEmpty || !restoreSet.isEmpty)
                && intended != outlineView.selectedRowIndexes
            if willChangeSelection {
                endActiveRename(target)
                switch target {
                case .tab(let id):
                    if let item = store.updateTabItem(tabId: id, projection: projection),
                       updateTabRow(item) {
                        unappliedTabIds.insert(id)
                    }
                case .group(let id):
                    if let item = store.updateGroupItem(groupId: id, projection: projection) {
                        if let applied = updateGroupRow(item) {
                            appliedGroupRenders[id] = applied
                        } else {
                            unappliedGroupIds.insert(id)
                        }
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

    /// Hands the field editor to `request`, after the predecessor session reports
    /// whatever it owed the model. The model records the request before the pass
    /// runs, so a request this view cannot honor -- an unmounted row, or a row
    /// inside a collapsed group -- reports its own end, or the model would keep
    /// claiming a session that is not on screen.
    private func beginRenaming(_ request: SidebarRenameSession) {
        finishActiveRename()
        let item: SidebarItem? = {
            switch request.target {
            case .tab(let id): return tabItemCache[id]
            case .group(let id): return groupItemCache[id]
            }
        }()
        guard let item,
              case let row = outlineView.row(forItem: item), row >= 0,
              let cellView = outlineView.view(
                atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let textField = cellView.textField
        else {
            report([.sidebarRenameEnded(session: request.id)])
            return
        }
        activeRename.open(request, textField: textField)
        textField.isEditable = true
        textField.selectText(nil)
        window?.makeFirstResponder(textField)
    }

    // reconcile-pass-lint: no-send end

    /// Hands a fact this view discovered about itself to the runtime's outbox --
    /// the sole channel out of the view. It is never a dispatch: the outbox holds
    /// the fact until the outermost send frame closes, or wakes a drain on the next
    /// main-queue turn when no frame is open. That is what lets a teardown report
    /// from anywhere, including AppKit's own row traversal, and what keeps delivery
    /// independent of this view still being alive.
    private func report(_ messages: [Msg]) {
        runtime?.outbox.report(messages)
    }

    /// Commit a live rename before an outline interaction lets AppKit change selection.
    /// The delegate's click-away path deliberately leaves the clicked destination focused.
    ///
    /// The teardown gets a send frame of its own, which is what delivers its
    /// messages in this turn: a pointer interaction runs inside no frame, and the
    /// commit and its end have to reach the model before the selection changes the
    /// rest of the event drives. The frame ends here rather than wrapping the whole
    /// event for the same reason -- a reconcile between the two would act on a model
    /// still claiming a session this view has already given up.
    func finishActiveRenameForPointerInteraction() {
        guard let outbox = runtime?.outbox else {
            // No runtime to deliver to, but the teardown still has to happen: the
            // view must not keep an editor the interaction has ended.
            finishActiveRename()
            return
        }
        outbox.withFrame { finishActiveRename() }
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
    func updateTabRow(_ item: SidebarItem) -> Bool {
        guard case .tab(let tab) = item.kind else { return false }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return false }
        let isVisible = outlineView.visibleRect.intersects(outlineView.rect(ofRow: row))
        guard let cell = materializedCell(row) as? SidebarTabCellView
        else { return isVisible }
        let isEditing = cell.titleField.currentEditor() != nil
        cell.apply(tab, isEditingTitle: isEditing)
        return false
    }

    /// Paints a group row and returns the effective value stored for later mounting.
    /// A visible row with no materialized cell returns nil so the caller retries it.
    func updateGroupRow(_ item: SidebarItem) -> SidebarGroupProjection.Rendered? {
        guard case .group(var group) = item.kind else { return nil }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return group.rendered }
        let isVisible = outlineView.visibleRect.intersects(outlineView.rect(ofRow: row))
        guard let cell = materializedCell(row) as? SidebarGroupCellView
        else { return isVisible ? nil : group.rendered }
        let isEditing = cell.titleField.currentEditor() != nil
        if isEditing {
            group.rendered.name = DisplayLine(cell.titleField.stringValue)
            item.kind = .group(group)
        }
        cell.apply(group.rendered, isEditingTitle: isEditing)
        return group.rendered
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
            focusedTabId: appliedProjection?.selectedTabId)
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
        if tab.id != appliedProjection?.selectedTabId {
            runtime?.send(.selectTab(id: tab.id))
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isReloading else { return }
        guard let sidebarItem = notification.userInfo?["NSObject"] as? SidebarItem,
              case .group(let group) = sidebarItem.kind else { return }
        runtime?.send(.toggleGroupCollapse(groupId: group.id))
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isReloading else { return }
        guard let sidebarItem = notification.userInfo?["NSObject"] as? SidebarItem,
              case .group(let group) = sidebarItem.kind else { return }
        runtime?.send(.toggleGroupCollapse(groupId: group.id))
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
                guard let projectedId = appliedProjection?.singleGroupDropTargetId else { return false }
                targetGroupId = projectedId
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
                guard let projectedId = appliedProjection?.singleGroupDropTargetId else { return false }
                groupId = projectedId
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

    /// Interaction path: takes the row's id and reads enablement from the
    /// projection that supplied the mounted row.
    func contextMenu(forGroupId groupId: GroupId) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(menuItem(title: "New Tab", sends: .createTab(inGroupId: groupId)))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(menuItem(
            title: "Rename Group",
            sends: .beginSidebarRename(target: .group(groupId)),
            timing: .afterMenuTracking))

        let deleteItem = menuItem(
            title: "Delete Group", sends: .requestDeleteGroup(id: groupId))
        deleteItem.isEnabled = appliedProjection?.canDeleteGroups ?? false
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
        guard let projection = appliedProjection else { return nil }

        let targetIds = contextTargetTabIds(clickedRow: clickedRow)
        guard !targetIds.isEmpty else { return nil }

        // Look up projected tabs in visual order, dropping stale ids.
        let targetSet = Set(targetIds)
        var targetTabs: [SidebarTabProjection] = []
        for g in projection.groups {
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
        menu.addItem(menuItem(
            title: "Rename Tab",
            sends: .beginSidebarRename(target: .tab(tabId)),
            timing: .afterMenuTracking))

        // Clear Custom Title — show if any selected tab has one.
        if targetTabs.contains(where: \.hasCustomTitle) {
            menu.addItem(menuItem(
                title: "Clear Custom Title\(suffix)",
                sends: .clearCustomTitles(tabIds: targetIds)))
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
            // The reducer resolves toggle-off against its current domain state.
            colorSubmenu.addItem(menuItem(
                title: "Clear Color",
                sends: .requestSetTabColors(tabIds: targetIds, requested: nil)))
            colorSubmenu.addItem(NSMenuItem.separator())
        }
        for color in TabColor.allCases {
            let item = menuItem(
                title: color.rawValue.capitalized,
                sends: .requestSetTabColors(tabIds: targetIds, requested: color))
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
        let anyHasAlerts = targetTabs.contains { $0.alertBadge != nil }
        if anyHasAlerts {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(menuItem(
                title: "Clear Alerts\(suffix)",
                sends: .clearAlertsForTabs(tabIds: targetIds)))
        }

        menu.addItem(NSMenuItem.separator())

        // Move to New Group — same no-op rule as before: hide when the
        // action would extract every live tab (rejected by update).
        let totalTabs = projection.groups.reduce(0) { $0 + $1.tabs.count }
        let isAllLiveTabs = totalTabs > 0 && targetIds.count == totalTabs
        if !isAllLiveTabs {
            // The reducer extracts the tabs and projects one inline-rename request.
            menu.addItem(menuItem(
                title: "Move to New Group\(suffix)",
                sends: .extractTabsToNewGroupInteractively(
                    tabIds: targetIds, groupName: "New group")))
        }

        // Close — the "Tab" noun is dropped so the suffix doesn't read
        // redundantly ("Close (3 tabs)" vs. "Close Tab (3 tabs)"). The whole
        // batch goes through one confirmation flow, so mixed simple and
        // confirmation-needed tabs are handled uniformly.
        menu.addItem(menuItem(
            title: "Close\(suffix)", sends: .requestCloseTabs(ids: targetIds)))

        return menu
    }

    /// Builds one context-menu item from the outcome it names, so the action and
    /// the entity it targets are one value. The payload holds the constructed
    /// `Msg`, which keeps every id typed from here to `send`.
    private func menuItem(
        title: String,
        sends msg: Msg,
        timing: SidebarMenuAction.Timing = .immediate
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: #selector(contextMenuItemFired(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = SidebarMenuAction(msg: msg, timing: timing)
        return item
    }

    @objc private func contextMenuItemFired(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? SidebarMenuAction else { return }
        switch action.timing {
        case .immediate:
            runtime?.send(action.msg)
        case .afterMenuTracking:
            DispatchQueue.main.async { [weak self] in
                self?.runtime?.send(action.msg)
            }
        }
    }

    // MARK: - Cell Factories

    private func makeGroupCell(for group: SidebarGroupProjection) -> NSView {
        if let existing = outlineView.makeView(
            withIdentifier: SidebarGroupCellView.reuseIdentifier,
            owner: nil) as? SidebarGroupCellView
        {
            resetRecycledRenameState(existing)
            existing.apply(group.rendered, isEditingTitle: false)
            return existing
        }

        let cell = SidebarGroupCellView(
            textFieldDelegate: self,
            caretTarget: self,
            caretAction: #selector(caretClicked(_:)))
        cell.apply(group.rendered, isEditingTitle: false)
        return cell
    }

    private func makeTabCell(for tab: SidebarTabProjection) -> NSView {
        let cell: SidebarTabCellView
        if let existing = outlineView.makeView(
            withIdentifier: SidebarTabCellView.reuseIdentifier,
            owner: nil) as? SidebarTabCellView
        {
            resetRecycledRenameState(existing)
            cell = existing
        } else {
            cell = SidebarTabCellView(textFieldDelegate: self)
        }

        cell.apply(tab, isEditingTitle: false)
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

    // MARK: - Inline Rename Cleanup

    /// Restores one ended rename field from the latest cached model-backed row state.
    private func finishInlineRename(textField: NSTextField, target: RenameTarget) {
        textField.isEditable = false

        // Resync the row's title from cached model state now that the field editor
        // is gone. During rename, skipTitle prevented title updates; this ensures
        // the cell reflects the current model regardless of whether a rename Msg
        // follows.
        switch target {
        case .tab(let tabId):
            guard let item = tabItemCache[tabId] else { return }
            let row = outlineView.row(forItem: item)
            guard row >= 0,
                  let cell = outlineView.view(
                    atColumn: 0, row: row,
                    makeIfNecessary: false) as? SidebarTabCellView,
                  case .tab(let tab) = item.kind else { return }
            cell.apply(tab, isEditingTitle: false)
        case .group(let groupId):
            guard let item = groupItemCache[groupId] else { return }
            let row = outlineView.row(forItem: item)
            guard row >= 0,
                  let cell = outlineView.view(
                    atColumn: 0, row: row,
                    makeIfNecessary: false) as? SidebarGroupCellView,
                  case .group(let group) = item.kind else { return }
            cell.apply(group.rendered, isEditingTitle: false)
        }
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - NSTextFieldDelegate (inline rename)

extension SidebarView: NSTextFieldDelegate {
    // NSTextFieldDelegate: Enter and Esc are the sole authority for inline rename
    // completion. Enter commits the rename; Esc cancels (reverts). Both restore
    // focus to the active terminal pane. The session is taken before
    // makeFirstResponder so that textShouldEndEditing (if AppKit fires it during
    // resign) is a no-op.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let isConfirm = commandSelector == #selector(NSResponder.insertNewline(_:))
        let isCancel  = commandSelector == #selector(NSResponder.cancelOperation(_:))
        guard isConfirm || isCancel,
              let textField = control as? NSTextField,
              activeRename.owns(textField),
              let torn = activeRename.take() else { return false }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        window?.makeFirstResponder(nil)
        finishInlineRename(textField: textField, target: torn.target)
        report(renameCompletionMessages(
            isConfirm: isConfirm, session: torn.session,
            target: torn.target, newName: newName))
        return true
    }

    // NSTextFieldDelegate: the click-away path. It commits the rename without
    // restoring focus, because the user moved focus intentionally. A callback from
    // any field except the owned one is inert.
    //
    // Returning `true` is what permits AppKit to go on tearing down the field
    // editor after this callback returns, so nothing here may reconcile: a pass
    // would reload the row whose editor AppKit still holds. Reporting is safe
    // because the outbox never delivers on the reporting stack -- with no send
    // frame open it wakes a drain on the next turn, which is the queue hop this
    // path used to build for itself.
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard let textField = control as? NSTextField,
              activeRename.owns(textField),
              let torn = activeRename.take() else { return true }
        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        report(renameCompletionMessages(
            isConfirm: true, session: torn.session,
            target: torn.target, newName: newName))
        finishInlineRename(textField: textField, target: torn.target)
        return true
    }
}

// MARK: - Helpers

/// The outcome one sidebar context-menu item carries: the message it sends and
/// when it sends it. Holding the already-constructed `Msg` keeps every id typed
/// from menu build to `send`, so an item cannot name an entity of a different
/// kind than its action targets.
private struct SidebarMenuAction {
    /// `afterMenuTracking` hops one main-queue turn. The rename items need it:
    /// the model's rename begin drives a reconcile pass that installs a field
    /// editor, and AppKit is still tearing the menu down.
    enum Timing {
        case immediate
        case afterMenuTracking
    }

    let msg: Msg
    let timing: Timing
}
