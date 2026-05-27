/// Popover view controller for a pane's TODO list.
/// Shows a scrollable list of tasks with checkboxes, delete buttons,
/// drag-to-reorder, a "Clear completed" button, and explicit list/edit modes.
/// List mode keeps the bottom input for new tasks only; edit mode swaps the
/// list for a larger editor with Save and Cancel buttons.

import Cocoa

private let todoRowDragType = NSPasteboard.PasteboardType("com.danneu.danterm.todo-row")

private final class PaneTodoPopoverRootView: NSView {
    var handleKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class PaneTodoTableView: NSTableView {
    var handleListKeyDown: ((NSEvent) -> Bool)?
    var handleCancelOperation: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if handleListKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if handleCancelOperation?() == true { return }
        super.cancelOperation(sender)
    }
}

// MARK: - TodoPopoverViewController

class TodoPopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var runtime: AppRuntime?
    let paneId: PaneId
    private let tableView = PaneTodoTableView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "Pane To-Do")
    private let clearButton = NSButton(title: "Clear completed", target: nil, action: nil)
    private let helpButton = NSButton()
    private let addInput = TodoInputView()
    private let composeHintLabel = makeTodoShortcutHintLabel()
    private let editTitleLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "Edit pane task")
        tf.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        tf.textColor = .labelColor
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }()
    private let editInput = TodoInputView(placeholder: "Edit task...", visibleLineCount: TodoInputView.editVisibleLineCount)
    private let editHintLabel = makeTodoShortcutHintLabel()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var bottomStack: NSStackView!
    private var editContainer: NSStackView!
    private let emptyLabel = NSTextField(labelWithString: "No tasks yet")

    private var popoverState = TodoPopoverState<UUID>()
    private var isSyncingTableSelection = false
    private var shortcutHelpPopover: NSPopover?
    private var projection: PaneTodoPopoverProjection

    private var todos: [TodoItem] { projection.rows }

    init(paneId: PaneId, runtime: AppRuntime?) {
        self.paneId = paneId
        self.runtime = runtime
        self.projection = PaneTodoPopoverProjection(paneId: paneId, rows: [], hasCompleted: false)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let size = NSSize(width: 320, height: 400)
        preferredContentSize = size

        let wrapper = PaneTodoPopoverRootView(frame: NSRect(origin: .zero, size: size))
        wrapper.handleKeyEquivalent = { [weak self] event in
            self?.performTodoKeyEquivalent(with: event) ?? false
        }
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)

        // Header
        headerLabel.font = .preferredFont(forTextStyle: .headline)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        clearButton.target = self
        clearButton.action = #selector(clearCompleted)
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let headerActions = NSStackView(views: [clearButton])
        headerActions.orientation = .horizontal
        headerActions.alignment = .centerY
        headerActions.spacing = 6
        headerActions.detachesHiddenViews = true
        headerActions.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerActions)

        configureTodoShortcutHelpButton(helpButton, target: self, action: #selector(toggleShortcutHelp(_:)))
        container.addSubview(helpButton)

        // Table
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("todo"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableRowDoubleClicked(_:))
        tableView.handleListKeyDown = { [weak self] event in
            self?.handleListKeyDown(event) ?? false
        }
        tableView.handleCancelOperation = { [weak self] in
            self?.closePopoverFromList()
            return true
        }
        tableView.registerForDraggedTypes([todoRowDragType])

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Empty state
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        saveButton.target = self
        saveButton.action = #selector(saveEditButtonClicked(_:))
        saveButton.bezelStyle = .rounded

        cancelButton.target = self
        cancelButton.action = #selector(cancelEditButtonClicked(_:))
        cancelButton.bezelStyle = .rounded

        editInput.textView.delegate = self

        let editButtons = NSStackView(views: [saveButton, cancelButton])
        editButtons.orientation = .horizontal
        editButtons.alignment = .centerY
        editButtons.spacing = 8

        editContainer = NSStackView(views: [editTitleLabel, editInput, editHintLabel, editButtons])
        editContainer.orientation = .vertical
        editContainer.alignment = .leading
        editContainer.spacing = 8
        editContainer.translatesAutoresizingMaskIntoConstraints = false
        editContainer.isHidden = true
        container.addSubview(editContainer)

        // Bottom stack: [separator, addInput]
        let sep = NSBox()
        sep.boxType = .separator

        addInput.textView.delegate = self

        bottomStack = NSStackView(views: [sep, addInput, composeHintLabel])
        bottomStack.orientation = .vertical
        bottomStack.alignment = .leading
        bottomStack.spacing = 4
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        // NSStackView collapses hidden views automatically
        bottomStack.detachesHiddenViews = true
        container.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: wrapper.topAnchor),
            container.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: size.width),
            container.heightAnchor.constraint(equalToConstant: size.height),

            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerActions.leadingAnchor, constant: -8),
            headerActions.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            headerActions.trailingAnchor.constraint(equalTo: helpButton.leadingAnchor, constant: -6),
            helpButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            helpButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            editContainer.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            editContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            editContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            editContainer.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12),
            editInput.widthAnchor.constraint(equalTo: editContainer.widthAnchor),

            bottomStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            bottomStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            bottomStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            sep.widthAnchor.constraint(equalTo: bottomStack.widthAnchor),
            addInput.widthAnchor.constraint(equalTo: bottomStack.widthAnchor),
        ])

        self.view = wrapper
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        apply(projection)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusInitialMode()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        closeShortcutHelpPopover()
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

    private var isEditing: Bool { popoverState.isEditing }

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

    private func restoreFirstResponder(
        composeWasFirstResponder: Bool,
        editWasFirstResponder: Bool,
        tableWasFirstResponder: Bool,
        saveWasFirstResponder: Bool,
        cancelWasFirstResponder: Bool
    ) {
        guard let window = view.window else { return }
        if isEditing {
            if editWasFirstResponder {
                window.makeFirstResponder(editInput.textView)
            } else if saveWasFirstResponder {
                window.makeFirstResponder(saveButton)
            } else if cancelWasFirstResponder {
                window.makeFirstResponder(cancelButton)
            }
            return
        }
        if editWasFirstResponder || saveWasFirstResponder || cancelWasFirstResponder {
            if tableView.selectedRow >= 0 {
                window.makeFirstResponder(tableView)
            } else {
                focusComposeInput()
            }
            return
        }
        if composeWasFirstResponder {
            window.makeFirstResponder(addInput.textView)
        } else if tableWasFirstResponder {
            if tableView.selectedRow >= 0 {
                window.makeFirstResponder(tableView)
            } else {
                focusComposeInput()
            }
        }
    }

    private func focusInitialMode() {
        focusComposeInput()
    }

    @discardableResult
    private func focusListFromInput() -> Bool {
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

    private func focusComposeInput() {
        addInput.string = popoverState.composeDraft
        syncModeVisibility()
        view.window?.makeFirstResponder(addInput.textView)
        addInput.textView.moveToEndOfDocument(nil)
    }

    private func enterEditForSelectedRow() {
        guard let item = selectedTodo() else { return }
        popoverState.enterEdit(target: item.id, itemText: item.text)
        editInput.string = item.text
        editTitleLabel.stringValue = "Edit pane task"
        syncModeVisibility()
        view.window?.makeFirstResponder(editInput.textView)
        editInput.textView.moveToEndOfDocument(nil)
    }

    @discardableResult
    private func saveEditThenReturnToList() -> Bool {
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

    private func saveEditThenFocusCompose(clearingDraft: Bool) {
        guard saveEditThenReturnToList() else { return }
        if clearingDraft {
            popoverState.clearComposeDraft()
        }
        focusComposeInput()
    }

    private func cancelEditAndReturnToList() {
        guard let editId = popoverState.editTarget else { return }
        popoverState.cancelEdit()
        syncModeVisibility()
        _ = selectTodo(id: editId)
        view.window?.makeFirstResponder(tableView)
    }

    private func addTodoAndStayInCompose() {
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

    private func syncModeVisibility() {
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

    private func installEditKeyLoop() {
        editInput.textView.nextKeyView = saveButton
        saveButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = editInput.textView
    }

    private func tearDownEditKeyLoop() {
        editInput.textView.nextKeyView = nil
        saveButton.nextKeyView = nil
        cancelButton.nextKeyView = nil
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
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

    @objc private func clearCompleted() {
        let selectedIdBeforeMutation = selectedTodo()?.id
        runtime?.send(.clearCompletedTodos(paneId: paneId))
        if let selectedIdBeforeMutation {
            _ = selectTodo(id: selectedIdBeforeMutation)
        }
    }

    @objc private func tableRowDoubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        enterEditForSelectedRow()
    }

    @objc private func saveEditButtonClicked(_ sender: Any?) {
        _ = saveEditThenReturnToList()
    }

    @objc private func cancelEditButtonClicked(_ sender: Any?) {
        cancelEditAndReturnToList()
    }

    @objc private func toggleShortcutHelp(_ sender: Any?) {
        if shortcutHelpPopover != nil {
            closeShortcutHelpPopover()
        } else {
            showShortcutHelpPopover()
        }
    }

    /// Close shortcut help before the parent popover closes or reanchors.
    func closeShortcutHelpPopover() {
        guard let popover = shortcutHelpPopover else { return }
        popover.performClose(nil)
    }

    /// Show help as a child popover while preserving parent click-away state.
    private func showShortcutHelpPopover() {
        guard shortcutHelpPopover == nil else {
            closeShortcutHelpPopover()
            return
        }
        guard let parentPopover = runtime?.todoPopover else { return }
        let savedResponder = view.window?.firstResponder
        let popover = NSPopover()
        let controller = TodoShortcutHelpViewController(
            scope: .pane,
            parentPopover: parentPopover,
            parentView: view,
            savedResponder: savedResponder
        ) { [weak self, weak popover] in
            guard let self, self.shortcutHelpPopover === popover else { return }
            self.shortcutHelpPopover = nil
        }
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        popover.delegate = controller
        controller.popover = popover
        parentPopover.behavior = .applicationDefined
        shortcutHelpPopover = popover
        popover.show(relativeTo: helpButton.bounds, of: helpButton, preferredEdge: .minY)
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

    private func handleListKeyDown(_ event: NSEvent) -> Bool {
        let action = classifyListAction(key: listKey(from: event), modifiers: keyModifiers(from: event))
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

    private func performTodoKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = keyModifiers(from: event)
        let key = listKey(from: event)
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

    private func closePopoverFromList() {
        runtime?.send(.toggleTodoPopover(paneId: paneId))
    }
}

// MARK: - NSTextViewDelegate

extension TodoPopoverViewController: NSTextViewDelegate {
    /// NSTextViewDelegate: route keyboard commands through the pure classifier.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === addInput.textView || textView === editInput.textView else { return false }
        if commandSelector == #selector(insertNewline(_:)),
           let event = NSApp.currentEvent,
           event.modifierFlags.contains(.command) {
            return performTodoKeyEquivalent(with: event)
        }
        if commandSelector == #selector(deleteBackward(_:)),
           NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            return false
        }

        // Map ObjC selector + modifiers to domain-level InputKey
        let key: InputKey
        if commandSelector == #selector(insertNewline(_:)) {
            key = NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .shiftEnter : .enter
        } else if commandSelector == #selector(cancelOperation(_:)) {
            key = .escape
        } else if commandSelector == #selector(deleteBackward(_:)) {
            key = .backspace
        } else if commandSelector == #selector(insertTab(_:)) {
            key = .tab
        } else if commandSelector == #selector(insertBacktab(_:)) {
            key = .backtab
        } else {
            key = .other
        }

        let action = classifyInputAction(
            key: key,
            isEditing: isEditing,
            fieldEmpty: textView.string.isEmpty
        )

        switch action {
        case .submit:
            if isEditing {
                _ = saveEditThenReturnToList()
            } else {
                addTodoAndStayInCompose()
            }
            return true
        case .insertNewline:
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case .cancelEdit:
            cancelEditAndReturnToList()
            return true
        case .dismiss:
            if !focusListFromInput() {
                closePopoverFromList()
            }
            return true
        case .moveFocusForward:
            if isEditing {
                view.window?.selectNextKeyView(nil)
            } else {
                _ = focusListFromInput()
            }
            return true
        case .moveFocusBackward:
            if isEditing {
                view.window?.selectPreviousKeyView(nil)
            } else {
                _ = focusListFromInput()
            }
            return true
        case .unhandled:
            if key == .backtab { return true }
            return false
        }
    }

    /// NSTextViewDelegate: keep the compose draft live while adding a new item.
    func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === addInput.textView else { return }
        guard !isEditing else { return }
        popoverState.setComposeDraft(addInput.string)
    }
}

private func keyModifiers(from event: NSEvent) -> KeyModifiers {
    var modifiers = KeyModifiers()
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command) { modifiers.insert(.command) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    return modifiers
}

private func listKey(from event: NSEvent) -> ListKey {
    switch event.keyCode {
    case 36, 76:
        return .enter
    case 48:
        return event.modifierFlags.contains(.shift) ? .backtab : .tab
    case 49:
        return .space
    case 51:
        return .backspace
    case 125:
        return .downArrow
    case 126:
        return .upArrow
    default:
        break
    }

    switch event.charactersIgnoringModifiers?.lowercased() {
    case "h":
        return .h
    case "j":
        return .j
    case "k":
        return .k
    case "l":
        return .l
    case "/", "?":
        return .slash
    case "n":
        return .n
    default:
        return .other
    }
}
