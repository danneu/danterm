/// Popover view controller for a pane's TODO list.
/// Shows a scrollable list of tasks with checkboxes, inline editing, delete buttons,
/// drag-to-reorder, a "Clear completed" button, and an add-task text field.

import Cocoa

private let todoRowDragType = NSPasteboard.PasteboardType("com.danneu.danterm.todo-row")
private let todoRowId = NSUserInterfaceItemIdentifier("TodoRow")

// MARK: - TodoRowView

/// Reusable row view for a single TODO item: [checkbox | label | delete button].
/// The text field starts non-editable; double-clicking the row enters edit mode.
private class TodoRowView: NSView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let textField: NSTextField = {
        let tf = NSTextField(string: "")
        tf.font = .systemFont(ofSize: 12)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.isEditable = false  // enabled on double-click
        tf.focusRingType = .none
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }()
    let deleteButton: NSButton = {
        let btn = NSButton()
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete task")
        btn.imageScaling = .scaleProportionallyDown
        btn.contentTintColor = .tertiaryLabelColor
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    /// The UUID of the TodoItem this row is currently displaying.
    var todoId: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)

        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        checkbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(checkbox)
        addSubview(textField)
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),

            textField.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -4),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 16),
            deleteButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Configure this row for the given TodoItem. Resets editing state.
    func configure(with item: TodoItem) {
        todoId = item.id
        checkbox.state = item.isDone ? .on : .off
        textField.isEditable = false

        if item.isDone {
            textField.attributedStringValue = NSAttributedString(string: item.text, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: 12),
            ])
        } else {
            textField.stringValue = item.text
            textField.textColor = .labelColor
        }
    }

    /// Enter inline editing mode for this row's text field.
    func beginEditing() {
        textField.isEditable = true
        // Reset to plain string so the user edits raw text, not attributed
        let plain = textField.stringValue
        textField.stringValue = plain
        textField.textColor = .labelColor
        window?.makeFirstResponder(textField)
        textField.currentEditor()?.selectAll(nil)
    }

    func endEditing() {
        textField.isEditable = false
    }

    // Double-click anywhere on the row (except checkbox/delete) enters edit mode.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            beginEditing()
        } else {
            super.mouseDown(with: event)
        }
    }
}

// MARK: - TodoPopoverViewController

class TodoPopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var runtime: AppRuntime?
    let paneId: PaneId
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "TODOs")
    private let clearButton = NSButton(title: "Clear completed", target: nil, action: nil)
    private let addField = NSTextField()
    private let emptyLabel = NSTextField(labelWithString: "No tasks yet")

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
        column.width = size.width
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 32
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([todoRowDragType])
        tableView.doubleAction = #selector(doubleClickRow(_:))
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
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

        // Add field
        addField.placeholderString = "Add a task…"
        addField.font = .systemFont(ofSize: 12)
        addField.focusRingType = .none
        addField.translatesAutoresizingMaskIntoConstraints = false
        addField.delegate = self
        container.addSubview(addField)

        // Separator above add field
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sep)

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
            scrollView.bottomAnchor.constraint(equalTo: sep.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            sep.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: addField.topAnchor, constant: -6),

            addField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            addField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            addField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            addField.heightAnchor.constraint(equalToConstant: 24),
        ])

        self.view = wrapper
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuildRows()
    }

    func rebuildRows() {
        let items = todos
        let hasCompleted = items.contains(where: \.isDone)
        clearButton.isHidden = !hasCompleted
        emptyLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty
        tableView.reloadData()
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

        // Reuse or create a TodoRowView
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
        rowView.textField.delegate = self

        return rowView
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

    /// Double-click a row to enter edit mode on its text field.
    @objc private func doubleClickRow(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, let rowView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TodoRowView else { return }
        rowView.beginEditing()
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        guard let rowView = sender.superview as? TodoRowView,
              let todoId = rowView.todoId else { return }
        runtime?.send(.toggleTodoDone(paneId: paneId, todoId: todoId))
        rebuildRows()
    }

    @objc private func deleteTask(_ sender: NSButton) {
        guard let rowView = sender.superview as? TodoRowView,
              let todoId = rowView.todoId else { return }
        runtime?.send(.deleteTodo(paneId: paneId, todoId: todoId))
        rebuildRows()
    }

    @objc private func clearCompleted() {
        runtime?.send(.clearCompletedTodos(paneId: paneId))
        rebuildRows()
    }
}

// MARK: - NSTextFieldDelegate

extension TodoPopoverViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            if control === addField {
                // Add field: Enter adds a new task
                let text = addField.stringValue
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
                runtime?.send(.addTodo(paneId: paneId, text: text))
                addField.stringValue = ""
                rebuildRows()
                return true
            } else if let rowView = control.superview as? TodoRowView, let todoId = rowView.todoId {
                // Inline edit: Enter commits the edit
                let text = control.stringValue
                runtime?.send(.editTodoText(paneId: paneId, todoId: todoId, text: text))
                rowView.endEditing()
                rebuildRows()
                return true
            }
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            if let rowView = control.superview as? TodoRowView {
                rowView.endEditing()
            }
            control.window?.makeFirstResponder(nil)
            rebuildRows()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField,
              textField !== addField,
              let rowView = textField.superview as? TodoRowView,
              let todoId = rowView.todoId else { return }
        let text = textField.stringValue
        runtime?.send(.editTodoText(paneId: paneId, todoId: todoId, text: text))
        rowView.endEditing()
        rebuildRows()
    }
}
