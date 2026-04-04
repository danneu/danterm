/// Popover view controller for a pane's TODO list.
/// Shows a scrollable list of tasks with checkboxes, delete buttons,
/// drag-to-reorder, a "Clear completed" button, and a multiline input
/// that serves as both "add" and "edit" field. Clicking a row uses native
/// table selection to enter edit mode; Enter saves, Esc cancels.

import Cocoa

private let todoRowDragType = NSPasteboard.PasteboardType("com.danneu.danterm.todo-row")
private let todoRowId = NSUserInterfaceItemIdentifier("TodoRow")

// MARK: - TodoRowView

/// Reusable display-only row view: [checkbox | label | delete button].
private class TodoRowView: NSView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let textField: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 12)
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }()
    let deleteButton: NSButton = {
        let btn = NSButton()
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete task")
        btn.imageScaling = .scaleProportionallyDown
        btn.contentTintColor = .tertiaryLabelColor
        return btn
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)

        let stack = NSStackView(views: [checkbox, textField, deleteButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        checkbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 16),
            deleteButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func configure(with item: TodoItem) {
        checkbox.state = item.isDone ? .on : .off
        textField.toolTip = item.text

        // Collapse multiline text to single display line
        let oneLine = item.text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if item.isDone {
            textField.attributedStringValue = NSAttributedString(string: oneLine, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: 12),
            ])
        } else {
            textField.stringValue = oneLine
            textField.textColor = .labelColor
        }
    }
}

// MARK: - TodoPopoverViewController

class TodoPopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var runtime: AppRuntime?
    let paneId: PaneId
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "To-Do")
    private let clearButton = NSButton(title: "Clear completed", target: nil, action: nil)
    private let addInput = TodoInputView()
    private let editLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "Editing — Esc to cancel")
        tf.font = .systemFont(ofSize: 10)
        tf.textColor = .secondaryLabelColor
        tf.isHidden = true
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }()
    private let emptyLabel = NSTextField(labelWithString: "No tasks yet")

    private var editState = TodoEditState()
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

        let wrapper = NSView(frame: NSRect(origin: .zero, size: size))
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)

        // Header
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        clearButton.target = self
        clearButton.action = #selector(clearCompleted)
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.font = .systemFont(ofSize: 11)
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
        tableView.registerForDraggedTypes([todoRowDragType])

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Empty state
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
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
        view.window?.makeFirstResponder(addInput.textView)
    }

    func rebuildRows() {
        let items = todos
        clearButton.isHidden = !items.contains(where: \.isDone)
        emptyLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty
        let wasEditingId = editState.editingTodoId
        isSyncingTableSelection = true
        tableView.reloadData()
        if wasEditingId != nil {
            if editState.editingTodoWasDeleted(from: items) {
                isSyncingTableSelection = false
                exitEditMode(restoreDraft: true)
            } else if let newIndex = items.firstIndex(where: { $0.id == wasEditingId }) {
                tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
                isSyncingTableSelection = false
            } else {
                isSyncingTableSelection = false
            }
        } else {
            isSyncingTableSelection = false
        }
    }

    // MARK: - Edit Mode

    private func exitEditMode(restoreDraft: Bool) {
        let restoredText = restoreDraft ? editState.cancel() : { editState.submit(); return "" }()
        addInput.string = restoredText
        editLabel.isHidden = true
        isSyncingTableSelection = true
        tableView.deselectAll(nil)
        isSyncingTableSelection = false
    }

    private func submitField() {
        let text = addInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let editId = editState.editingTodoId {
            runtime?.send(.editTodoText(paneId: paneId, todoId: editId, text: text))
            exitEditMode(restoreDraft: false)
        } else {
            runtime?.send(.addTodo(paneId: paneId, text: text))
            addInput.string = ""
        }
        rebuildRows()
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

    /// Prevent checkbox/delete clicks from selecting the row (and entering edit mode).
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return true }
        let point = tableView.convert(event.locationInWindow, from: nil)
        guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { return true }
        let localPoint = rowView.convert(point, from: tableView)
        if let hitView = rowView.hitTest(localPoint), hitView is NSButton { return false }
        return true
    }

    /// Selection-based edit mode entry: selecting a row loads its text into the editor.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingTableSelection else { return }
        let items = todos
        let row = tableView.selectedRow

        // Clicked empty space while editing — cancel like Esc
        if row < 0, editState.editingTodoId != nil {
            exitEditMode(restoreDraft: true)
            return
        }

        guard row >= 0, row < items.count else { return }
        let newItem = items[row]

        let fieldText = addInput.string
        if let autoSave = editState.beginEditing(item: newItem, fieldText: fieldText) {
            runtime?.send(.editTodoText(paneId: paneId, todoId: autoSave.autoSaveId, text: autoSave.text))
            // Refresh old row immediately so saved text is visible
            if let oldIndex = items.firstIndex(where: { $0.id == autoSave.autoSaveId }) {
                isSyncingTableSelection = true
                tableView.reloadData(forRowIndexes: IndexSet(integer: oldIndex),
                                     columnIndexes: IndexSet(integer: 0))
                isSyncingTableSelection = false
            }
        }

        addInput.string = newItem.text
        editLabel.isHidden = false
        view.window?.makeFirstResponder(addInput.textView)
        addInput.textView.selectAll(nil)
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
}

// MARK: - NSTextViewDelegate

extension TodoPopoverViewController: NSTextViewDelegate {
    /// NSTextViewDelegate: route keyboard commands through the pure classifier.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === addInput.textView else { return false }

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
            submitField()
            return true
        case .insertNewline:
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case .cancelEdit:
            exitEditMode(restoreDraft: true)
            return true
        case .dismiss:
            return true
        case .moveFocusForward:
            view.window?.selectNextKeyView(nil)
            return true
        case .moveFocusBackward:
            view.window?.selectPreviousKeyView(nil)
            return true
        case .unhandled:
            return false
        }
    }
}
