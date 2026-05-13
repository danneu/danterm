/// Popover view controller for a pane's TODO list.
/// Shows a scrollable list of tasks with checkboxes, delete buttons,
/// drag-to-reorder, a "Clear completed" button, and a multiline input
/// that serves as both "add" and "edit" field. Selecting a row previews it;
/// double-click, Tab, or Return enters edit mode and Return saves edits.

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
    private let headerLabel = NSTextField(labelWithString: "To-Do")
    private let clearButton = NSButton(title: "Clear completed", target: nil, action: nil)
    private let addInput = TodoInputView()
    private let editLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "Editing - Esc to cancel - Enter to save")
        tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.textColor = .secondaryLabelColor
        tf.isHidden = true
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }()
    private let emptyLabel = NSTextField(labelWithString: "No tasks yet")

    private var editState = TodoEditState()
    private var composeDraft = ""
    private var isSyncingTableSelection = false

    private var todos: [TodoItem] { runtime?.model.panes[paneId]?.todos ?? [] }

    init(paneId: PaneId, runtime: AppRuntime?) {
        self.paneId = paneId
        self.runtime = runtime
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
        container.addSubview(clearButton)

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

        // Bottom stack: [separator, editLabel (collapsible), addInput]
        let sep = NSBox()
        sep.boxType = .separator

        addInput.textView.delegate = self

        let bottomStack = NSStackView(views: [sep, editLabel, addInput])
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
            clearButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            bottomStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            bottomStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            bottomStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            sep.widthAnchor.constraint(equalTo: bottomStack.widthAnchor),
            editLabel.leadingAnchor.constraint(equalTo: bottomStack.leadingAnchor, constant: 4),
            addInput.widthAnchor.constraint(equalTo: bottomStack.widthAnchor),
        ])

        self.view = wrapper
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuildRows()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusInitialMode()
    }

    func rebuildRows() {
        let items = todos
        let selectedId = selectedTodo()?.id
        let selectedRowBeforeReload = tableView.selectedRow
        clearButton.isHidden = !items.contains(where: \.isDone)
        emptyLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty
        let wasEditingId = editState.editingTodoId
        isSyncingTableSelection = true
        tableView.reloadData()
        if let editId = wasEditingId {
            if !items.contains(where: { $0.id == editId }) {
                editState.submit()
                editLabel.isHidden = true
                isSyncingTableSelection = false
                selectNearestSelectableRow(near: selectedRowBeforeReload)
            } else if let newIndex = items.firstIndex(where: { $0.id == editId }) {
                tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
                isSyncingTableSelection = false
            } else {
                isSyncingTableSelection = false
            }
        } else if let selectedId,
                  let newIndex = items.firstIndex(where: { $0.id == selectedId }) {
            tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
            isSyncingTableSelection = false
        } else {
            isSyncingTableSelection = false
        }
    }

    // MARK: - Focus and edit transitions

    private var isEditing: Bool { editState.editingTodoId != nil }

    private func selectedTodo() -> TodoItem? {
        let row = tableView.selectedRow
        let items = todos
        guard row >= 0, row < items.count else { return nil }
        return items[row]
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

    private func populateInputFromSelection() {
        guard let item = selectedTodo() else { return }
        addInput.string = item.text
    }

    private func selectNearestSelectableRow(near row: Int) {
        let items = todos
        if items.indices.contains(row) {
            setSelectedRow(row)
            populateInputFromSelection()
            view.window?.makeFirstResponder(tableView)
            return
        }
        if let previous = nextSelectableRow(in: items, from: min(row, items.count), delta: -1, canSelect: { _ in true }) {
            setSelectedRow(previous)
            populateInputFromSelection()
            view.window?.makeFirstResponder(tableView)
            return
        }
        focusComposeInput()
    }

    private func focusInitialMode() {
        focusComposeInput()
    }

    @discardableResult
    private func focusListFromInput() -> Bool {
        composeDraft = addInput.string
        let items = todos
        var row = tableView.selectedRow
        if !items.indices.contains(row) {
            guard let firstRow = firstSelectableRow(in: items, canSelect: { _ in true }) else { return false }
            row = firstRow
        }
        setSelectedRow(row)
        populateInputFromSelection()
        editLabel.isHidden = true
        view.window?.makeFirstResponder(tableView)
        return true
    }

    private func focusComposeInput() {
        if isEditing {
            editState.submit()
            editLabel.isHidden = true
        }
        addInput.string = composeDraft
        view.window?.makeFirstResponder(addInput.textView)
        addInput.textView.moveToEndOfDocument(nil)
    }

    private func enterEditForSelectedRow() {
        guard let item = selectedTodo() else { return }
        if let oldId = editState.editingTodoId, oldId != item.id {
            saveEdit(todoId: oldId, text: addInput.string)
        }
        editState.editingTodoId = item.id
        addInput.string = item.text
        editLabel.isHidden = false
        view.window?.makeFirstResponder(addInput.textView)
        addInput.textView.selectAll(nil)
    }

    @discardableResult
    private func saveEditThenReturnToList() -> Bool {
        guard let editId = editState.editingTodoId else { return false }
        let text = addInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        saveEdit(todoId: editId, text: text)
        editState.submit()
        editLabel.isHidden = true
        rebuildRows()
        _ = selectTodo(id: editId)
        addInput.string = text
        view.window?.makeFirstResponder(tableView)
        return true
    }

    private func addTodoAndStayInCompose() {
        let text = addInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        runtime?.send(.addTodo(paneId: paneId, text: text))
        composeDraft = ""
        addInput.string = ""
        rebuildRows()
        view.window?.makeFirstResponder(addInput.textView)
    }

    private func cancelEditAndReturnToList() {
        guard let editId = editState.editingTodoId else { return }
        editState.submit()
        editLabel.isHidden = true
        if selectTodo(id: editId) {
            populateInputFromSelection()
            view.window?.makeFirstResponder(tableView)
        } else {
            focusListFromInput()
        }
    }

    private func saveEditThenFocusCompose() {
        guard saveEditThenReturnToList() else { return }
        focusComposeInput()
    }

    private func saveEdit(todoId: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runtime?.send(.editTodoText(paneId: paneId, todoId: todoId, text: trimmed))
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

    /// NSTableViewDelegate: selection changes update the passive input preview.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingTableSelection else { return }
        let items = todos
        let row = tableView.selectedRow

        if row < 0, editState.editingTodoId != nil {
            cancelEditAndReturnToList()
            return
        }

        guard row >= 0, row < items.count else { return }
        let newItem = items[row]

        if let editId = editState.editingTodoId, editId != newItem.id {
            saveEdit(todoId: editId, text: addInput.string)
            editState.submit()
            editLabel.isHidden = true
            rebuildRows()
            _ = selectTodo(id: newItem.id)
            addInput.string = newItem.text
            return
        }

        addInput.string = newItem.text
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
        runtime?.send(.reorderTodo(paneId: paneId, todoId: uuid, toIndex: row))
        rebuildRows()
        return true
    }

    // MARK: - Actions

    @objc private func checkboxToggled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < todos.count else { return }
        runtime?.send(.toggleTodoDone(paneId: paneId, todoId: todos[row].id))
        rebuildRows()
    }

    @objc private func deleteTask(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < todos.count else { return }
        runtime?.send(.deleteTodo(paneId: paneId, todoId: todos[row].id))
        rebuildRows()
    }

    @objc private func clearCompleted() {
        runtime?.send(.clearCompletedTodos(paneId: paneId))
        rebuildRows()
    }

    @objc private func tableRowDoubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        enterEditForSelectedRow()
    }

    private func toggleSelectedTodoDone() {
        guard let item = selectedTodo() else { return }
        let previewText = addInput.string
        runtime?.send(.toggleTodoDone(paneId: paneId, todoId: item.id))
        rebuildRows()
        _ = selectTodo(id: item.id)
        addInput.string = previewText
        view.window?.makeFirstResponder(tableView)
    }

    private func deleteSelectedTodo() {
        let row = tableView.selectedRow
        guard let item = selectedTodo() else { return }
        runtime?.send(.deleteTodo(paneId: paneId, todoId: item.id))
        rebuildRows()
        selectNearestSelectableRow(near: row)
    }

    private func reorderSelectedTodo(delta: Int) {
        let row = tableView.selectedRow
        let destination = row + delta
        guard let item = selectedTodo(), todos.indices.contains(destination) else { return }
        runtime?.send(.reorderTodo(paneId: paneId, todoId: item.id, toIndex: destination))
        rebuildRows()
        _ = selectTodo(id: item.id)
        populateInputFromSelection()
        view.window?.makeFirstResponder(tableView)
    }

    private func moveSelection(delta: Int) {
        let items = todos
        let row = tableView.selectedRow
        guard let nextRow = nextSelectableRow(in: items, from: row, delta: delta, canSelect: { _ in true }) else { return }
        setSelectedRow(nextRow)
        populateInputFromSelection()
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
        case .unhandled:
            return false
        }
    }

    private func performTodoKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = keyModifiers(from: event)
        guard modifiers == [.command] else { return false }
        switch listKey(from: event) {
        case .enter:
            if isEditing {
                _ = saveEditThenReturnToList()
            } else if view.window?.firstResponder === addInput.textView {
                addTodoAndStayInCompose()
            }
            return true
        case .n:
            if isEditing {
                saveEditThenFocusCompose()
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
        guard textView === addInput.textView else { return false }
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
            isEditing: editState.editingTodoId != nil,
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
            _ = focusListFromInput()
            return true
        case .moveFocusBackward:
            return true
        case .unhandled:
            if key == .backtab { return true }
            return false
        }
    }

    /// NSTextViewDelegate: keep the compose draft live while adding a new item.
    func textDidChange(_ notification: Notification) {
        guard view.window?.firstResponder === addInput.textView, !isEditing else { return }
        composeDraft = addInput.string
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
    case "n":
        return .n
    default:
        return .other
    }
}
