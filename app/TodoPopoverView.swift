/// Popover view controller for a pane's TODO list.
/// Shows a scrollable list of tasks with checkboxes, delete buttons,
/// drag-to-reorder, a "Clear completed" button, and a multiline input
/// that serves as both "add" and "edit" field.

import Cocoa

private let todoRowDragType = NSPasteboard.PasteboardType("com.danneu.danterm.todo-row")
private let todoRowId = NSUserInterfaceItemIdentifier("TodoRow")
private let maxInputHeight: CGFloat = 54  // ~3 lines at 12pt font

// MARK: - TodoTextInput

/// Reusable multiline text input: NSTextView inside NSScrollView.
/// Grows up to maxInputHeight, then scrolls. Enter submits, Shift+Enter inserts newline.
private class TodoTextInput: NSView {
    let scrollView = NSScrollView()
    let textView = NSTextView()

    /// Called when the user presses Enter (without Shift).
    var onSubmit: ((String) -> Void)?
    /// Called when the user presses Escape.
    var onCancel: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)

        textView.isRichText = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 3)
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: maxInputHeight),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    var string: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func selectAll() {
        textView.selectAll(nil)
    }
}

extension TodoTextInput: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            // Shift+Enter inserts a newline; plain Enter submits
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            onSubmit?(textView.string)
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}

// MARK: - TodoRowView

/// Reusable display-only row view: [checkbox | label | delete button].
/// Double-click handling is on the table view controller, not the row.
private class TodoRowView: NSView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let textField: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 12)
        tf.focusRingType = .none
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
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

    func configure(with item: TodoItem) {
        todoId = item.id
        checkbox.state = item.isDone ? .on : .off
        textField.toolTip = item.text

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
}

// MARK: - TodoPopoverViewController

class TodoPopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var runtime: AppRuntime?
    let paneId: PaneId
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "TODOs")
    private let clearButton = NSButton(title: "Clear completed", target: nil, action: nil)
    private let addInput = TodoTextInput()
    private let editLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "Editing — Esc to cancel")
        tf.font = .systemFont(ofSize: 10)
        tf.textColor = .secondaryLabelColor
        tf.isHidden = true
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }()
    private let emptyLabel = NSTextField(labelWithString: "No tasks yet")

    private var editingTodoId: UUID? = nil
    private var preEditDraft: String = ""

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

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sep)

        // Edit label (hidden by default)
        container.addSubview(editLabel)

        // Add/edit input (multiline)
        addInput.textView.setAccessibilityLabel("Add a task")
        container.addSubview(addInput)

        addInput.onSubmit = { [weak self] text in
            guard let self = self else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let editId = self.editingTodoId {
                self.runtime?.send(.editTodoText(paneId: self.paneId, todoId: editId, text: trimmed))
                self.exitEditMode(restoreDraft: false)
            } else {
                self.runtime?.send(.addTodo(paneId: self.paneId, text: trimmed))
                self.addInput.string = ""
            }
            self.rebuildRows()
        }

        addInput.onCancel = { [weak self] in
            guard let self = self else { return }
            if self.editingTodoId != nil {
                self.exitEditMode(restoreDraft: true)
            }
        }

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
            sep.bottomAnchor.constraint(equalTo: editLabel.topAnchor, constant: -4),

            editLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            editLabel.bottomAnchor.constraint(equalTo: addInput.topAnchor, constant: -2),

            addInput.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            addInput.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            addInput.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
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

        // If the task being edited was deleted/cleared, cancel edit mode
        if let editId = editingTodoId, !items.contains(where: { $0.id == editId }) {
            exitEditMode(restoreDraft: true)
        }
    }

    // MARK: - Edit Mode

    private func exitEditMode(restoreDraft: Bool) {
        editingTodoId = nil
        addInput.string = restoreDraft ? preEditDraft : ""
        preEditDraft = ""
        editLabel.isHidden = true
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

    @objc private func doubleClickRow(_ sender: Any?) {
        let row = tableView.clickedRow
        let items = todos
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        // Only stash the add draft when entering edit mode from add mode
        if editingTodoId == nil {
            preEditDraft = addInput.string
        }
        editingTodoId = item.id
        addInput.string = item.text
        editLabel.isHidden = false
        addInput.focus()
        addInput.selectAll()
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
