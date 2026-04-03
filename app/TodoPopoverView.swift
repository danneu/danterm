/// Popover view controller for a pane's TODO list.
/// Shows a scrollable list of tasks with checkboxes, inline editing, delete buttons,
/// drag-to-reorder, a "Clear completed" button, and an add-task text field.

import Cocoa

private let todoRowDragType = NSPasteboard.PasteboardType("com.danneu.danterm.todo-row")

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
        return makeTodoRow(items[row])
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

    // MARK: - Row construction

    private func makeTodoRow(_ item: TodoItem) -> NSView {
        let row = NSView()

        // Checkbox
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
        checkbox.state = item.isDone ? .on : .off
        checkbox.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(checkbox)

        // Text field (editable)
        let textField = NSTextField(string: item.text)
        textField.font = .systemFont(ofSize: 12)
        textField.isBordered = false
        textField.drawsBackground = false
        textField.isEditable = true
        textField.focusRingType = .none
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.delegate = self
        textField.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)

        if item.isDone {
            // Strikethrough + dimmed for completed items
            let attributed = NSMutableAttributedString(string: item.text, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: 12),
            ])
            textField.attributedStringValue = attributed
        }
        row.addSubview(textField)

        // Delete button
        let deleteBtn = NSButton()
        deleteBtn.bezelStyle = .inline
        deleteBtn.isBordered = false
        deleteBtn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete task")
        deleteBtn.imageScaling = .scaleProportionallyDown
        deleteBtn.contentTintColor = .tertiaryLabelColor
        deleteBtn.target = self
        deleteBtn.action = #selector(deleteTask(_:))
        deleteBtn.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        deleteBtn.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(deleteBtn)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            checkbox.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            textField.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
            textField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            textField.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -4),

            deleteBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            deleteBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            deleteBtn.widthAnchor.constraint(equalToConstant: 16),
            deleteBtn.heightAnchor.constraint(equalToConstant: 16),
        ])

        return row
    }

    // MARK: - Actions

    @objc private func checkboxToggled(_ sender: NSButton) {
        guard let idStr = sender.identifier?.rawValue,
              let uuid = UUID(uuidString: idStr) else { return }
        runtime?.send(.toggleTodoDone(paneId: paneId, todoId: uuid))
        rebuildRows()
    }

    @objc private func deleteTask(_ sender: NSButton) {
        guard let idStr = sender.identifier?.rawValue,
              let uuid = UUID(uuidString: idStr) else { return }
        runtime?.send(.deleteTodo(paneId: paneId, todoId: uuid))
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
            } else if let idStr = control.identifier?.rawValue, let uuid = UUID(uuidString: idStr) {
                // Inline edit: Enter commits the edit
                let text = control.stringValue
                runtime?.send(.editTodoText(paneId: paneId, todoId: uuid, text: text))
                // Resign first responder to end editing
                control.window?.makeFirstResponder(nil)
                rebuildRows()
                return true
            }
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            // Escape: cancel editing, restore original text
            control.window?.makeFirstResponder(nil)
            rebuildRows()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField,
              textField !== addField,
              let idStr = textField.identifier?.rawValue,
              let uuid = UUID(uuidString: idStr) else { return }
        let text = textField.stringValue
        runtime?.send(.editTodoText(paneId: paneId, todoId: uuid, text: text))
        rebuildRows()
    }
}
