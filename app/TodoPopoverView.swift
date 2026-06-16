// Popover view controller for a pane's TODO list.
// Shows a scrollable list of tasks with checkboxes, delete buttons,
// drag-to-reorder, a "Clear completed" button, and explicit list/edit modes.
// List mode keeps the bottom input for new tasks only; edit mode swaps the
// list for a larger editor with Save and Cancel buttons.

import Cocoa

private let todoRowDragType = NSPasteboard.PasteboardType("com.danneu.danterm.todo-row")

// MARK: - TodoPopoverViewController

class TodoPopoverViewController: TodoPopoverControllerBase {
    let paneId: PaneId
    private let emptyLabel = NSTextField(labelWithString: "No tasks yet")

    private var popoverState = TodoPopoverState<UUID>()
    private var projection: PaneTodoPopoverProjection

    private var todos: [TodoItem] { projection.rows }

    init(paneId: PaneId, runtime: AppRuntime?) {
        self.paneId = paneId
        self.projection = PaneTodoPopoverProjection(paneId: paneId, rows: [], hasCompleted: false)
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

    override var parentTodoPopover: NSPopover? { runtime?.todoPopover }

    override var shortcutHelpScope: TodoShortcutScope { .pane }

    override var headerTitle: String { "Pane To-Do" }

    override var tableColumnIdentifier: String { "todo" }

    override func registerDragTypes(on tableView: NSTableView) {
        tableView.registerForDraggedTypes([todoRowDragType])
    }

    override func installEmptyState(in container: NSView) {
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    /// Render the latest model projection while preserving view-local drafts,
    /// selection, and first responder when their targets still exist.
    func apply(_ newProjection: PaneTodoPopoverProjection) {
        let composeWasFirstResponder = view.window?.firstResponder === addInput.textView
        let editWasFirstResponder = view.window?.firstResponder === editInput.textView
        let tableWasFirstResponder = view.window?.firstResponder === tableView
        let saveWasFirstResponder = view.window?.firstResponder === saveButton
        let cancelWasFirstResponder = view.window?.firstResponder === cancelButton
        let selectedId = selectedTodo()?.id
        let selectedRowBeforeReload = tableView.selectedRow
        let wasEditing = popoverState.isEditing
        let previousEditTarget = popoverState.editTarget
        let editDraft = editInput.string
        popoverState.setComposeDraft(addInput.string)

        projection = newProjection
        popoverState.reconcileEditTarget { target in
            newProjection.rows.contains { $0.id == target } ? target : nil
        }
        if let editId = popoverState.editTarget {
            editTitleLabel.stringValue = "Edit pane task"
            if wasEditing, editId == previousEditTarget {
                editInput.string = editDraft
            } else if let item = todo(id: editId) {
                editInput.string = item.text
            }
        }
        syncModeVisibility()
        isSyncingTableSelection = true
        tableView.reloadData()
        if let editId = popoverState.editTarget {
            if let newIndex = todos.firstIndex(where: { $0.id == editId }) {
                tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
            } else {
                tableView.deselectAll(nil)
            }
        } else if let selectedId,
                  let newIndex = todos.firstIndex(where: { $0.id == selectedId }) {
            tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isSyncingTableSelection = false

        let selectedDisappeared = selectedId != nil && !todos.contains { $0.id == selectedId }
        if (wasEditing && !popoverState.isEditing) || selectedDisappeared {
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

    private func selectedTodo() -> TodoItem? {
        let row = tableView.selectedRow
        let items = todos
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    private func todo(id: UUID) -> TodoItem? {
        todos.first { $0.id == id }
    }

    private func setSelectedRow(_ row: Int) {
        guard todos.indices.contains(row) else { return }
        isSyncingTableSelection = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        isSyncingTableSelection = false
    }

    private func selectTodo(id: UUID) -> Bool {
        guard let row = todos.firstIndex(where: { $0.id == id }) else { return false }
        setSelectedRow(row)
        return true
    }

    private func selectNearestSelectableRow(near row: Int, focus: Bool = true) {
        let items = todos
        if items.indices.contains(row) {
            setSelectedRow(row)
            if focus { view.window?.makeFirstResponder(tableView) }
            return
        }
        if let previous = nextSelectableRow(in: items, from: min(row, items.count), delta: -1, canSelect: { _ in true }) {
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
        let items = todos
        var row = tableView.selectedRow
        if !items.indices.contains(row) {
            guard let firstRow = firstSelectableRow(in: items, canSelect: { _ in true }) else { return false }
            row = firstRow
        }
        setSelectedRow(row)
        popoverState.selectRow(selectedTodo()?.id)
        syncModeVisibility()
        view.window?.makeFirstResponder(tableView)
        return true
    }

    override func enterEditForSelectedRow() {
        guard let item = selectedTodo() else { return }
        popoverState.enterEdit(target: item.id, itemText: item.text)
        editInput.string = item.text
        editTitleLabel.stringValue = "Edit pane task"
        syncModeVisibility()
        view.window?.makeFirstResponder(editInput.textView)
        editInput.textView.moveToEndOfDocument(nil)
    }

    @discardableResult
    override func saveEditThenReturnToList() -> Bool {
        switch popoverState.saveEdit(text: editInput.string) {
        case .saved(let editId, let text):
            saveEdit(todoId: editId, text: text)
            syncModeVisibility()
            _ = selectTodo(id: editId)
            view.window?.makeFirstResponder(tableView)
            return true
        case .rejected:
            view.window?.makeFirstResponder(editInput.textView)
            return false
        }
    }

    override func cancelEditAndReturnToList() {
        guard let editId = popoverState.editTarget else { return }
        popoverState.cancelEdit()
        syncModeVisibility()
        _ = selectTodo(id: editId)
        view.window?.makeFirstResponder(tableView)
    }

    override func addTodoAndStayInCompose() {
        let text = addInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        runtime?.send(.addTodo(paneId: paneId, text: text))
        popoverState.clearComposeDraft()
        addInput.string = ""
        view.window?.makeFirstResponder(addInput.textView)
    }

    private func saveEdit(todoId: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runtime?.send(.editTodoText(paneId: paneId, todoId: todoId, text: trimmed))
    }

    override func syncModeVisibility() {
        let editMode = popoverState.isEditing
        clearButton.isHidden = editMode || !projection.hasCompleted
        editContainer.isHidden = !editMode
        scrollView.isHidden = editMode || todos.isEmpty
        emptyLabel.isHidden = editMode || !todos.isEmpty
        bottomStack.isHidden = editMode
        if editMode {
            installEditKeyLoop()
        } else {
            tearDownEditKeyLoop()
            addInput.string = popoverState.composeDraft
        }
    }

    // MARK: - NSTableViewDataSource

    override func numberOfRows(in tableView: NSTableView) -> Int {
        return todos.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let items = todos
        guard row < items.count else { return nil }
        let item = items[row]

        let rowView: TodoRowView
        if let reused = tableView.makeView(withIdentifier: todoRowId, owner: self) as? TodoRowView {
            rowView = reused
        } else {
            rowView = TodoRowView()
            rowView.identifier = todoRowId
        }

        rowView.configure(with: item)
        rowView.checkbox.target = self
        rowView.checkbox.action = #selector(checkboxToggled(_:))
        rowView.deleteButton.target = self
        rowView.deleteButton.action = #selector(deleteTask(_:))

        return rowView
    }

    /// NSTableViewDelegate: prevent checkbox/delete clicks from selecting the row.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return true }
        let point = tableView.convert(event.locationInWindow, from: nil)
        guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { return true }
        let localPoint = rowView.convert(point, from: tableView)
        if let hitView = rowView.hitTest(localPoint), hitView is NSButton { return false }
        return true
    }

    /// NSTableViewDelegate: row selection stays in list mode and never edits
    /// the compose draft.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingTableSelection else { return }
        let items = todos
        let row = tableView.selectedRow

        guard row >= 0, row < items.count else { return }
        popoverState.selectRow(items[row].id)
    }

    // MARK: - Drag reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let items = todos
        guard row < items.count else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(items[row].id.uuidString, forType: todoRowDragType)
        return pbItem
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .above { return .move }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let pbItem = info.draggingPasteboard.pasteboardItems?.first,
              let idStr = pbItem.string(forType: todoRowDragType),
              let uuid = UUID(uuidString: idStr) else { return false }
        let selectedIdBeforeMutation = selectedTodo()?.id
        runtime?.send(.reorderTodo(paneId: paneId, todoId: uuid, toIndex: row))
        if let selectedIdBeforeMutation {
            _ = selectTodo(id: selectedIdBeforeMutation)
        }
        return true
    }

    // MARK: - Actions

    @objc private func checkboxToggled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < todos.count else { return }
        let selectedIdBeforeMutation = selectedTodo()?.id
        runtime?.send(.toggleTodoDone(paneId: paneId, todoId: todos[row].id))
        if let selectedIdBeforeMutation {
            _ = selectTodo(id: selectedIdBeforeMutation)
        }
    }

    @objc private func deleteTask(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < todos.count else { return }
        let selectedIdBeforeMutation = selectedTodo()?.id
        runtime?.send(.deleteTodo(paneId: paneId, todoId: todos[row].id))
        if let selectedIdBeforeMutation {
            _ = selectTodo(id: selectedIdBeforeMutation)
        }
    }

    @objc override func clearCompleted() {
        let selectedIdBeforeMutation = selectedTodo()?.id
        runtime?.send(.clearCompletedTodos(paneId: paneId))
        if let selectedIdBeforeMutation {
            _ = selectTodo(id: selectedIdBeforeMutation)
        }
    }

    private func toggleSelectedTodoDone() {
        guard let item = selectedTodo() else { return }
        runtime?.send(.toggleTodoDone(paneId: paneId, todoId: item.id))
        _ = selectTodo(id: item.id)
        view.window?.makeFirstResponder(tableView)
    }

    private func deleteSelectedTodo() {
        let row = tableView.selectedRow
        guard let item = selectedTodo() else { return }
        runtime?.send(.deleteTodo(paneId: paneId, todoId: item.id))
        selectNearestSelectableRow(near: row)
    }

    private func reorderSelectedTodo(delta: Int) {
        let row = tableView.selectedRow
        let destination = row + delta
        guard let item = selectedTodo(), todos.indices.contains(destination) else { return }
        runtime?.send(.reorderTodo(paneId: paneId, todoId: item.id, toIndex: destination))
        _ = selectTodo(id: item.id)
        view.window?.makeFirstResponder(tableView)
    }

    private func moveSelection(delta: Int) {
        let items = todos
        let row = tableView.selectedRow
        guard let nextRow = nextSelectableRow(in: items, from: row, delta: delta, canSelect: { _ in true }) else { return }
        setSelectedRow(nextRow)
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
        case .moveBucket:
            return false
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
            if isEditing {
                saveEditThenFocusCompose(clearingDraft: true)
            } else {
                focusComposeInput()
            }
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
        runtime?.send(.toggleTodoPopover(paneId: paneId))
    }
}
