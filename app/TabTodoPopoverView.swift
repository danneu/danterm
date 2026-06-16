/// Popover view controller for the tab-level TODO list, anchored to the
/// chrome's right-side button. Shows the active tab's own to-dos plus a
/// roll-up section per pane in the tab. Tab items and pane roll-up items are
/// edited in an explicit editor mode; new items are added to the tab section
/// from the list-mode compose field.

import Cocoa

private let tabTodoRowDragType = NSPasteboard.PasteboardType("com.danneu.danterm.tab-todo-row")
private let tabHeaderRowId = NSUserInterfaceItemIdentifier("TabTodoHeader")
private let paneHeaderRowId = NSUserInterfaceItemIdentifier("PaneTodoHeader")
private let tabTodoEmptyRowId = NSUserInterfaceItemIdentifier("TabTodoEmptyRow")

private struct TabTodoDragPayload: Codable {
    enum Source: Equatable {
        case tab
        case pane(UUID)
    }

    let source: Source
    let todoId: UUID
}

extension TabTodoDragPayload.Source: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case paneId
    }

    private enum Kind: String, Codable {
        case tab
        case pane
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .tab:
            self = .tab
        case .pane:
            self = .pane(try container.decode(UUID.self, forKey: .paneId))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tab:
            try container.encode(Kind.tab, forKey: .kind)
        case .pane(let paneId):
            try container.encode(Kind.pane, forKey: .kind)
            try container.encode(paneId, forKey: .paneId)
        }
    }
}

// MARK: - Header row view

/// Bold/secondary header row used for both the tab section and pane sections.
/// The pane variant is a button: clicking the header focuses the pane.
private final class TabTodoHeaderRowView: NSView {
    let titleLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        tf.textColor = .secondaryLabelColor
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(title: String) {
        titleLabel.stringValue = title
    }
}

// MARK: - Empty row view

/// Secondary placeholder row shown under each empty tab or pane section.
private final class TabTodoEmptyRowView: NSView {
    private let label: NSTextField = {
        let tf = NSTextField(labelWithString: "No todo items")
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        tf.textColor = .secondaryLabelColor
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
}

// MARK: - View Controller

class TabTodoPopoverViewController: TodoPopoverControllerBase {
    let tabId: TabId
    private let newButton = NSButton(title: "New (\u{2318}N)", target: nil, action: nil)

    private var popoverState = TodoPopoverState<TabTodoEditTarget>()
    private var projection: TabTodoPopoverProjection
    private var rows: [TabTodoRow] { projection.rows }

    init(tabId: TabId, runtime: AppRuntime?) {
        self.tabId = tabId
        self.projection = TabTodoPopoverProjection(
            tabId: tabId,
            rows: [],
            paneOrder: [],
            tabHasCompleted: false
        )
        super.init(runtime: runtime)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var composeDraft: String {
        get { popoverState.composeDraft }
        set { popoverState.setComposeDraft(newValue) }
    }

    override func clearComposeDraft() {
        popoverState.clearComposeDraft()
    }

    override var isEditing: Bool { popoverState.isEditing }

    override func applyStoredProjection() {
        apply(projection)
    }

    override var parentTodoPopover: NSPopover? { runtime?.tabTodoPopover }

    override var shortcutHelpScope: TodoShortcutScope { .tab }

    override var headerTitle: String { "Tab To-Do" }

    override func headerActionButtons() -> [NSView] {
        newButton.target = self
        newButton.action = #selector(focusComposeAction(_:))
        newButton.bezelStyle = .accessoryBarAction
        newButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        newButton.translatesAutoresizingMaskIntoConstraints = false
        return [clearButton, newButton]
    }

    override var composePlaceholder: String? { "Add a tab task…" }

    override var tableColumnIdentifier: String { "tabtodo" }

    override func registerDragTypes(on tableView: NSTableView) {
        tableView.registerForDraggedTypes([tabTodoRowDragType])
    }

    /// Render the latest model projection while preserving view-local drafts,
    /// selection, and first responder when their targets still exist.
    func apply(_ newProjection: TabTodoPopoverProjection) {
        let composeWasFirstResponder = view.window?.firstResponder === addInput.textView
        let editWasFirstResponder = view.window?.firstResponder === editInput.textView
        let tableWasFirstResponder = view.window?.firstResponder === tableView
        let saveWasFirstResponder = view.window?.firstResponder === saveButton
        let cancelWasFirstResponder = view.window?.firstResponder === cancelButton
        let selectedTarget = selectedEditTarget()
        let selectedRowBeforeReload = tableView.selectedRow
        let wasEditing = popoverState.isEditing
        let previousEditTarget = popoverState.editTarget
        let editDraft = editInput.string
        popoverState.setComposeDraft(addInput.string)

        projection = newProjection
        popoverState.reconcileEditTarget { target in
            resolveTabTodoEditTarget(target, in: newProjection)
        }
        if let editTarget = popoverState.editTarget {
            editTitleLabel.stringValue = editTitle(for: editTarget)
            if wasEditing,
               let previousEditTarget,
               tabTodoTargetsReferToSameTodo(previousEditTarget, editTarget) {
                editInput.string = editDraft
            } else if let item = item(for: editTarget) {
                editInput.string = item.text
            }
        }
        let resolvedSelectedTarget = selectedTarget.flatMap {
            resolveTabTodoEditTarget($0, in: newProjection)
        }
        syncModeVisibility()
        isSyncingTableSelection = true
        tableView.reloadData()
        if let target = popoverState.editTarget {
            if let newIndex = rowIndex(for: target) {
                tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        } else if let resolvedSelectedTarget,
                  let newIndex = rowIndex(for: resolvedSelectedTarget) {
            tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isSyncingTableSelection = false

        if (wasEditing && !popoverState.isEditing) || (selectedTarget != nil && resolvedSelectedTarget == nil) {
            selectNearestSelectableRow(near: selectedRowBeforeReload, focus: false)
        }
        restoreFirstResponder(
            composeWasFirstResponder: composeWasFirstResponder,
            editWasFirstResponder: editWasFirstResponder,
            tableWasFirstResponder: tableWasFirstResponder,
            saveWasFirstResponder: saveWasFirstResponder,
            cancelWasFirstResponder: cancelWasFirstResponder
        )
    }

    // MARK: - Focus and edit transitions

    private func selectedEditTarget() -> TabTodoEditTarget? {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return nil }
        return rows[row].editTarget
    }

    private func item(for target: TabTodoEditTarget) -> TodoItem? {
        rows.first { $0.editTarget == target }?.item
    }

    private func rowIndex(for target: TabTodoEditTarget) -> Int? {
        rows.firstIndex { $0.editTarget == target }
    }

    private func setSelectedRow(_ row: Int) {
        guard rows.indices.contains(row), rows[row].isSelectable else { return }
        isSyncingTableSelection = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        isSyncingTableSelection = false
    }

    private func selectTarget(_ target: TabTodoEditTarget) -> Bool {
        guard let row = rowIndex(for: target) else { return false }
        setSelectedRow(row)
        return true
    }

    private func selectResolvedTarget(_ target: TabTodoEditTarget) -> Bool {
        guard let resolved = resolveTabTodoEditTarget(target, in: projection) else { return false }
        return selectTarget(resolved)
    }

    private func selectNearestSelectableRow(near row: Int, focus: Bool = true) {
        if rows.indices.contains(row), rows[row].isSelectable {
            setSelectedRow(row)
            if focus { view.window?.makeFirstResponder(tableView) }
            return
        }
        if let next = nextSelectableRow(in: rows, from: row, delta: 1, canSelect: { $0.isSelectable }) {
            setSelectedRow(next)
            if focus { view.window?.makeFirstResponder(tableView) }
            return
        }
        if let previous = nextSelectableRow(in: rows, from: min(row, rows.count), delta: -1, canSelect: { $0.isSelectable }) {
            setSelectedRow(previous)
            if focus { view.window?.makeFirstResponder(tableView) }
            return
        }
        if focus {
            focusComposeInput()
        } else {
            tableView.deselectAll(nil)
        }
    }

    @discardableResult
    override func focusListFromInput() -> Bool {
        popoverState.setComposeDraft(addInput.string)
        var row = tableView.selectedRow
        if !rows.indices.contains(row) || !rows[row].isSelectable {
            guard let firstRow = firstSelectableRow(in: rows, canSelect: { $0.isSelectable }) else { return false }
            row = firstRow
        }
        setSelectedRow(row)
        popoverState.selectRow(selectedEditTarget())
        syncModeVisibility()
        view.window?.makeFirstResponder(tableView)
        return true
    }

    override func enterEditForSelectedRow() {
        guard let target = selectedEditTarget(), let item = item(for: target) else { return }
        popoverState.enterEdit(target: target, itemText: item.text)
        editInput.string = item.text
        editTitleLabel.stringValue = editTitle(for: target)
        syncModeVisibility()
        view.window?.makeFirstResponder(editInput.textView)
        editInput.textView.moveToEndOfDocument(nil)
    }

    @discardableResult
    override func saveEditThenReturnToList() -> Bool {
        switch popoverState.saveEdit(text: editInput.string) {
        case .saved(let target, let text):
            saveEdit(target: target, text: text)
            syncModeVisibility()
            _ = selectResolvedTarget(target)
            view.window?.makeFirstResponder(tableView)
            return true
        case .rejected:
            view.window?.makeFirstResponder(editInput.textView)
            return false
        }
    }

    override func addTodoAndStayInCompose() {
        let text = addInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let previousTabTodoIds = Set(rows.compactMap { row -> UUID? in
            if case .tabItem(let item) = row { return item.id }
            return nil
        })
        runtime?.send(.addTabTodo(tabId: tabId, text: text))
        popoverState.clearComposeDraft()
        addInput.string = ""
        if let target = newlyAddedTabTodoTarget(
            previousTabTodoIds: previousTabTodoIds,
            in: projection
        ) {
            _ = selectTarget(target)
        }
        view.window?.makeFirstResponder(addInput.textView)
    }

    override func cancelEditAndReturnToList() {
        guard let target = popoverState.editTarget else { return }
        popoverState.cancelEdit()
        syncModeVisibility()
        if selectResolvedTarget(target) {
            view.window?.makeFirstResponder(tableView)
        } else {
            focusListFromInput()
        }
    }

    private func saveEdit(target: TabTodoEditTarget, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch target {
        case .tab(let todoId):
            runtime?.send(.editTabTodoText(tabId: tabId, todoId: todoId, text: trimmed))
        case .pane(let paneId, let todoId):
            runtime?.send(.editTodoText(paneId: paneId, todoId: todoId, text: trimmed))
        }
    }

    private func editTitle(for target: TabTodoEditTarget) -> String {
        switch target {
        case .tab:
            return "Edit tab task"
        case .pane(let paneId, _):
            let title = paneTitle(for: paneId) ?? "pane"
            return "Edit pane task: \(title)"
        }
    }

    private func paneTitle(for paneId: PaneId) -> String? {
        for row in rows {
            if case .paneSectionHeader(let rowPaneId, let title) = row, rowPaneId == paneId {
                return title
            }
        }
        return nil
    }

    private func sectionItemCount(for destination: TodoDestination) -> Int {
        switch destination {
        case .tab:
            return rows.count { row in
                if case .tabItem = row { return true }
                return false
            }
        case .pane(let paneId):
            return rows.count { row in
                if case .paneItem(let rowPaneId, _) = row { return rowPaneId == paneId }
                return false
            }
        }
    }

    override func syncModeVisibility() {
        let editMode = popoverState.isEditing
        clearButton.isHidden = editMode || !projection.tabHasCompleted
        newButton.isHidden = editMode
        editContainer.isHidden = !editMode
        scrollView.isHidden = editMode
        bottomStack.isHidden = editMode
        if editMode {
            installEditKeyLoop()
        } else {
            tearDownEditKeyLoop()
            addInput.string = popoverState.composeDraft
        }
    }

    // MARK: - NSTableViewDataSource

    override func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .tabSectionHeader:
            let view = (tableView.makeView(withIdentifier: tabHeaderRowId, owner: self) as? TabTodoHeaderRowView) ?? TabTodoHeaderRowView()
            view.identifier = tabHeaderRowId
            view.configure(title: "This tab")
            return view

        case .tabItem(let item):
            let rowView = (tableView.makeView(withIdentifier: todoRowId, owner: self) as? TodoRowView) ?? TodoRowView()
            rowView.identifier = todoRowId
            rowView.configure(with: item)
            rowView.checkbox.target = self
            rowView.checkbox.action = #selector(tabCheckboxToggled(_:))
            rowView.deleteButton.target = self
            rowView.deleteButton.action = #selector(tabDeleteTask(_:))
            return rowView

        case .tabEmptyPlaceholder:
            let view = (tableView.makeView(withIdentifier: tabTodoEmptyRowId, owner: self) as? TabTodoEmptyRowView) ?? TabTodoEmptyRowView()
            view.identifier = tabTodoEmptyRowId
            return view

        case .paneSectionHeader(_, let title):
            let view = (tableView.makeView(withIdentifier: paneHeaderRowId, owner: self) as? TabTodoHeaderRowView) ?? TabTodoHeaderRowView()
            view.identifier = paneHeaderRowId
            view.configure(title: title)
            return view

        case .paneItem(_, let item):
            // Reuse TodoRowView so pane items have the same shape as tab items
            // (checkbox + label + delete). Toggling/deleting routes to the
            // pane's existing Msgs.
            let rowView = (tableView.makeView(withIdentifier: todoRowId, owner: self) as? TodoRowView) ?? TodoRowView()
            rowView.identifier = todoRowId
            rowView.configure(with: item)
            rowView.checkbox.target = self
            rowView.checkbox.action = #selector(paneCheckboxToggled(_:))
            rowView.deleteButton.target = self
            rowView.deleteButton.action = #selector(paneDeleteTask(_:))
            return rowView

        case .paneEmptyPlaceholder:
            let view = (tableView.makeView(withIdentifier: tabTodoEmptyRowId, owner: self) as? TabTodoEmptyRowView) ?? TabTodoEmptyRowView()
            view.identifier = tabTodoEmptyRowId
            return view
        }
    }

    /// NSTableViewDelegate: only todo item rows are selectable; headers stay inert.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        // Block clicks on checkboxes/delete buttons from also selecting the row.
        if let event = NSApp.currentEvent, event.type == .leftMouseDown,
           let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) {
            let point = tableView.convert(event.locationInWindow, from: nil)
            let localPoint = rowView.convert(point, from: tableView)
            if let hit = rowView.hitTest(localPoint), hit is NSButton { return false }
        }
        switch rows[row] {
        case .tabItem, .paneItem:
            return true
        case .tabEmptyPlaceholder, .paneEmptyPlaceholder:
            return false
        case .paneSectionHeader(let paneId, _):
            // Side-effect on click: focus the pane and dismiss the popover so
            // the user lands in the terminal. Return false so the row doesn't
            // visually select.
            runtime?.focusPaneSurface(paneId)
            view.window?.close()
            return false
        case .tabSectionHeader:
            return false
        }
    }

    /// NSTableViewDelegate: render section headers with AppKit's group-row style.
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        return rows[row].isHeader
    }

    /// NSTableViewDelegate: row selection stays in list mode and never edits
    /// the compose draft.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingTableSelection else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count,
              let newTarget = rows[row].editTarget else { return }
        popoverState.selectRow(newTarget)
    }

    // MARK: - Drag move/reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < rows.count else { return nil }
        let payload: TabTodoDragPayload
        switch rows[row] {
        case .tabItem(let item):
            payload = TabTodoDragPayload(source: .tab, todoId: item.id)
        case .paneItem(let paneId, let item):
            payload = TabTodoDragPayload(source: .pane(paneId.rawValue), todoId: item.id)
        case .tabSectionHeader, .tabEmptyPlaceholder, .paneSectionHeader, .paneEmptyPlaceholder:
            return nil
        }
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(json, forType: tabTodoRowDragType)
        return pbItem
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let operation = tabTodoDropOperation(from: dropOperation),
              resolveTabTodoDropTarget(
                rows: rows,
                tabId: tabId,
                proposedRow: row,
                dropOperation: operation
              ) != nil else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let pbItem = info.draggingPasteboard.pasteboardItems?.first,
              let json = pbItem.string(forType: tabTodoRowDragType),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TabTodoDragPayload.self, from: data),
              let runtime = runtime,
              let operation = tabTodoDropOperation(from: dropOperation),
              let target = resolveTabTodoDropTarget(
                rows: rows,
                tabId: tabId,
                proposedRow: row,
                dropOperation: operation
              ) else { return false }

        let source = todoSource(from: payload.source, tabId: tabId)
        let targetToSelect: TabTodoEditTarget
        switch target.destination {
        case .tab:
            targetToSelect = .tab(todoId: payload.todoId)
        case .pane(let paneId):
            targetToSelect = .pane(paneId: paneId, todoId: payload.todoId)
        }
        if sameTodoBucket(source: source, destination: target.destination) {
            switch source {
            case .tab(let sourceTabId):
                runtime.send(.reorderTabTodo(tabId: sourceTabId, todoId: payload.todoId, toIndex: target.atIndex))
            case .pane(let sourcePaneId):
                runtime.send(.reorderTodo(paneId: sourcePaneId, todoId: payload.todoId, toIndex: target.atIndex))
            }
        } else {
            runtime.send(.moveTodo(
                from: source,
                todoId: payload.todoId,
                to: target.destination,
                atIndex: target.atIndex
            ))
        }
        _ = selectTarget(targetToSelect)
        return true
    }

    // MARK: - Actions

    @objc private func tabCheckboxToggled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < rows.count, case .tabItem(let item) = rows[row] else { return }
        let selectedTarget = selectedEditTarget()
        runtime?.send(.toggleTabTodoDone(tabId: tabId, todoId: item.id))
        if let selectedTarget { _ = selectResolvedTarget(selectedTarget) }
    }

    @objc private func tabDeleteTask(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < rows.count, case .tabItem(let item) = rows[row] else { return }
        let selectedTarget = selectedEditTarget()
        runtime?.send(.deleteTabTodo(tabId: tabId, todoId: item.id))
        if let selectedTarget { _ = selectResolvedTarget(selectedTarget) }
    }

    @objc private func paneCheckboxToggled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < rows.count,
              case .paneItem(let paneId, let item) = rows[row] else { return }
        let selectedTarget = selectedEditTarget()
        runtime?.send(.setTodoDone(paneId: paneId, todoId: item.id, isDone: !item.isDone))
        if let selectedTarget { _ = selectResolvedTarget(selectedTarget) }
    }

    @objc private func paneDeleteTask(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < rows.count,
              case .paneItem(let paneId, let item) = rows[row] else { return }
        let selectedTarget = selectedEditTarget()
        runtime?.send(.deleteTodo(paneId: paneId, todoId: item.id))
        if let selectedTarget { _ = selectResolvedTarget(selectedTarget) }
    }

    @objc override func clearCompleted() {
        let selectedTarget = selectedEditTarget()
        runtime?.send(.clearCompletedTabTodos(tabId: tabId))
        if let selectedTarget { _ = selectResolvedTarget(selectedTarget) }
    }

    private func toggleSelectedTodoDone() {
        guard let target = selectedEditTarget() else { return }
        switch target {
        case .tab(let todoId):
            runtime?.send(.toggleTabTodoDone(tabId: tabId, todoId: todoId))
        case .pane(let paneId, let todoId):
            runtime?.send(.toggleTodoDone(paneId: paneId, todoId: todoId))
        }
        _ = selectResolvedTarget(target)
        view.window?.makeFirstResponder(tableView)
    }

    private func deleteSelectedTodo() {
        let row = tableView.selectedRow
        guard let target = selectedEditTarget() else { return }
        switch target {
        case .tab(let todoId):
            runtime?.send(.deleteTabTodo(tabId: tabId, todoId: todoId))
        case .pane(let paneId, let todoId):
            runtime?.send(.deleteTodo(paneId: paneId, todoId: todoId))
        }
        selectNearestSelectableRow(near: row)
    }

    private func reorderSelectedTodo(delta: Int) {
        let row = tableView.selectedRow
        guard rows.indices.contains(row),
              let target = selectedEditTarget(),
              let currentIndex = sectionLocalIndex(
                  rows: rows,
                  at: row,
                  isHeader: { $0.isHeader },
                  sectionId: { $0.sectionIdentifier }
              ) else { return }

        let sectionIdentifier = rows[row].sectionIdentifier
        let currentSectionCount = rows.count {
            $0.isSelectable && $0.sectionIdentifier == sectionIdentifier
        }
        guard let step = resolveTabTodoReorderStep(
            current: target,
            paneOrder: projection.paneOrder,
            tabId: tabId,
            currentIndex: currentIndex,
            currentSectionCount: currentSectionCount,
            destinationSectionCount: { destination in
                self.sectionItemCount(for: destination)
            },
            delta: delta
        ) else { return }

        let targetToSelect: TabTodoEditTarget
        switch step {
        case .reorderInSection(let destination):
            switch target {
            case .tab(let todoId):
                runtime?.send(.reorderTabTodo(tabId: tabId, todoId: todoId, toIndex: destination))
            case .pane(let paneId, let todoId):
                runtime?.send(.reorderTodo(paneId: paneId, todoId: todoId, toIndex: destination))
            }
            targetToSelect = target
        case .moveToBucket(let destination, let atIndex):
            guard let item = item(for: target) else { return }
            let source: TodoSource
            switch target {
            case .tab:
                source = .tab(tabId)
            case .pane(let paneId, _):
                source = .pane(paneId)
            }
            runtime?.send(.moveTodo(from: source, todoId: item.id, to: destination, atIndex: atIndex))
            switch destination {
            case .tab:
                targetToSelect = .tab(todoId: item.id)
            case .pane(let paneId):
                targetToSelect = .pane(paneId: paneId, todoId: item.id)
            }
        }
        _ = selectTarget(targetToSelect)
        view.window?.makeFirstResponder(tableView)
    }

    private func moveSelection(delta: Int) {
        let row = tableView.selectedRow
        guard let nextRow = nextSelectableRow(in: rows, from: row, delta: delta, canSelect: { $0.isSelectable }) else { return }
        setSelectedRow(nextRow)
    }

    private func moveSelectedTodoToAdjacentBucket(delta: Int) -> Bool {
        guard view.window?.firstResponder === tableView || isEditing else { return false }
        if isEditing {
            _ = saveEditThenReturnToList()
        }
        guard let current = selectedEditTarget(),
              let item = item(for: current),
              let destination = resolveTabTodoBucketStep(
                current: current,
                paneOrder: projection.paneOrder,
                tabId: tabId,
                delta: delta
              ) else { return true }

        let source: TodoSource
        switch current {
        case .tab:
            source = .tab(tabId)
        case .pane(let paneId, _):
            source = .pane(paneId)
        }

        runtime?.send(.moveTodo(from: source, todoId: item.id, to: destination, atIndex: 0))
        let newTarget: TabTodoEditTarget
        switch destination {
        case .tab:
            newTarget = .tab(todoId: item.id)
        case .pane(let paneId):
            newTarget = .pane(paneId: paneId, todoId: item.id)
        }
        _ = selectTarget(newTarget)
        view.window?.makeFirstResponder(tableView)
        return true
    }

    override func handleListKeyDown(_ event: NSEvent) -> Bool {
        let action = classifyListAction(key: todoListKey(from: event), modifiers: todoKeyModifiers(from: event))
        switch action {
        case .moveSelection(let delta):
            moveSelection(delta: delta)
            return true
        case .enterEdit:
            enterEditForSelectedRow()
            return true
        case .toggleDone:
            toggleSelectedTodoDone()
            return true
        case .deleteRow:
            deleteSelectedTodo()
            return true
        case .reorder(let delta):
            reorderSelectedTodo(delta: delta)
            return true
        case .moveBucket(let delta):
            return moveSelectedTodoToAdjacentBucket(delta: delta)
        case .focusInput:
            focusComposeInput()
            return true
        case .showShortcutHelp:
            toggleShortcutHelp(nil)
            return true
        case .unhandled:
            return false
        }
    }

    override func performTodoKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = todoKeyModifiers(from: event)
        let key = todoListKey(from: event)
        if classifyListAction(key: key, modifiers: modifiers) == .showShortcutHelp {
            toggleShortcutHelp(nil)
            return true
        }
        if modifiers == [.command, .shift] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h", "l":
                return true
            default:
                return false
            }
        }

        guard modifiers == [.command] else { return false }
        switch key {
        case .enter:
            if isEditing {
                _ = saveEditThenReturnToList()
            } else if view.window?.firstResponder === addInput.textView {
                addTodoAndStayInCompose()
            }
            return true
        case .n:
            focusComposeFromShortcut()
            return true
        case .backspace:
            guard view.window?.firstResponder === tableView else { return false }
            deleteSelectedTodo()
            return true
        default:
            return false
        }
    }

    override func closePopoverFromList() {
        runtime?.send(.toggleTodoPopoverForTab(tabId: tabId))
    }
}

private func tabTodoDropOperation(from operation: NSTableView.DropOperation) -> TabTodoDropOperation? {
    switch operation {
    case .on:
        return .on
    case .above:
        return .above
    default:
        return nil
    }
}

private func todoSource(from payloadSource: TabTodoDragPayload.Source, tabId: TabId) -> TodoSource {
    switch payloadSource {
    case .tab:
        return .tab(tabId)
    case .pane(let uuid):
        return .pane(PaneId(rawValue: uuid))
    }
}

private func sameTodoBucket(source: TodoSource, destination: TodoDestination) -> Bool {
    switch (source, destination) {
    case (.tab(let sourceId), .tab(let destinationId)):
        return sourceId == destinationId
    case (.pane(let sourceId), .pane(let destinationId)):
        return sourceId == destinationId
    case (.tab, .pane), (.pane, .tab):
        return false
    }
}

private func tabTodoTargetsReferToSameTodo(_ lhs: TabTodoEditTarget, _ rhs: TabTodoEditTarget) -> Bool {
    switch (lhs, rhs) {
    case (.tab(let left), .tab(let right)),
         (.tab(let left), .pane(_, let right)),
         (.pane(_, let left), .tab(let right)),
         (.pane(_, let left), .pane(_, let right)):
        return left == right
    }
}
