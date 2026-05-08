/// Popover view controller for the tab-level TODO list, anchored to the
/// chrome's right-side button. Shows the active tab's own to-dos plus a
/// read-only roll-up section per pane in the tab. Tab items are full-featured
/// (add/edit/delete/reorder); pane items are check/uncheck only.

import Cocoa

private let tabTodoRowDragType = NSPasteboard.PasteboardType("com.danneu.danterm.tab-todo-row")
private let tabHeaderRowId = NSUserInterfaceItemIdentifier("TabTodoHeader")
private let paneHeaderRowId = NSUserInterfaceItemIdentifier("PaneTodoHeader")

// MARK: - Row enum

enum TabTodoRow {
    case tabSectionHeader
    case tabItem(TodoItem)
    case paneSectionHeader(paneId: PaneId, title: String)
    case paneItem(paneId: PaneId, item: TodoItem)
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

// MARK: - View Controller

class TabTodoPopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var runtime: AppRuntime?
    let tabId: TabId
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "Tab To-Do")
    private let clearButton = NSButton(title: "Clear completed", target: nil, action: nil)
    private let addInput = TodoInputView(placeholder: "Add a tab task…")
    private let editLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "Editing — Esc to cancel")
        tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.textColor = .secondaryLabelColor
        tf.isHidden = true
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }()
    private let emptyLabel = NSTextField(labelWithString: "No tasks yet")

    private var editState = TodoEditState()
    private var isSyncingTableSelection = false
    private var rows: [TabTodoRow] = []

    init(tabId: TabId, runtime: AppRuntime?) {
        self.tabId = tabId
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private var tab: TabModel? {
        guard let model = runtime?.model else { return nil }
        return tabById(tabId, in: model)
    }

    private var tabTodos: [TodoItem] { tab?.todos ?? [] }

    /// Build the row enum from the current model.
    private func buildRows() -> [TabTodoRow] {
        guard let runtime = runtime, let tab = tab else { return [] }
        var result: [TabTodoRow] = []
        result.append(.tabSectionHeader)
        for item in tab.todos {
            result.append(.tabItem(item))
        }
        for paneId in allPaneIds(tab.rootNode) {
            guard let pane = runtime.model.panes[paneId] else { continue }
            guard !pane.todos.isEmpty else { continue }
            result.append(.paneSectionHeader(paneId: paneId, title: pane.title))
            for item in pane.todos {
                result.append(.paneItem(paneId: paneId, item: item))
            }
        }
        return result
    }

    /// Index range (start, endExclusive) of tab items in `rows`. Used to clamp
    /// drag-reorder drops so a tab item can't be dropped inside a pane section.
    private func tabItemRange() -> (start: Int, end: Int)? {
        guard !rows.isEmpty, case .tabSectionHeader = rows[0] else { return nil }
        var end = 1
        while end < rows.count, case .tabItem = rows[end] { end += 1 }
        return (1, end)
    }

    override func loadView() {
        let size = NSSize(width: 320, height: 400)
        preferredContentSize = size

        let wrapper = NSView(frame: NSRect(origin: .zero, size: size))
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)

        headerLabel.font = .preferredFont(forTextStyle: .headline)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        clearButton.target = self
        clearButton.action = #selector(clearCompleted)
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(clearButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tabtodo"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([tabTodoRowDragType])

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        let sep = NSBox()
        sep.boxType = .separator

        addInput.textView.delegate = self

        let bottomStack = NSStackView(views: [sep, editLabel, addInput])
        bottomStack.orientation = .vertical
        bottomStack.alignment = .leading
        bottomStack.spacing = 4
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
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
        rows = buildRows()
        let tabItems = tabTodos
        clearButton.isHidden = !tabItems.contains(where: \.isDone)
        let totalRows = rows.count
        emptyLabel.isHidden = totalRows > 1 // > 1 means we have items beyond the tab header
        scrollView.isHidden = totalRows <= 1
        let wasEditingId = editState.editingTodoId
        isSyncingTableSelection = true
        tableView.reloadData()
        if wasEditingId != nil {
            if editState.editingTodoWasDeleted(from: tabItems) {
                isSyncingTableSelection = false
                exitEditMode(restoreDraft: true)
            } else if let newIndex = rows.firstIndex(where: {
                if case .tabItem(let item) = $0 { return item.id == wasEditingId }
                return false
            }) {
                tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
                isSyncingTableSelection = false
            } else {
                isSyncingTableSelection = false
            }
        } else {
            isSyncingTableSelection = false
        }
    }

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
            runtime?.send(.editTabTodoText(tabId: tabId, todoId: editId, text: text))
            exitEditMode(restoreDraft: false)
        } else {
            runtime?.send(.addTabTodo(tabId: tabId, text: text))
            addInput.string = ""
        }
        rebuildRows()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

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
        }
    }

    /// Only tab items are selectable (selection drives the edit-mode entry).
    /// Pane section headers fire a focus-pane side effect on click without
    /// becoming selected. Other rows do nothing on click.
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
        case .tabItem:
            return true
        case .paneSectionHeader(let paneId, _):
            // Side-effect on click: focus the pane and dismiss the popover so
            // the user lands in the terminal. Return false so the row doesn't
            // visually select.
            runtime?.focusPaneSurface(paneId)
            view.window?.close()
            return false
        case .tabSectionHeader, .paneItem:
            return false
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingTableSelection else { return }
        let row = tableView.selectedRow
        if row < 0, editState.editingTodoId != nil {
            exitEditMode(restoreDraft: true)
            return
        }
        guard row >= 0, row < rows.count, case .tabItem(let newItem) = rows[row] else { return }

        let fieldText = addInput.string
        if let autoSave = editState.beginEditing(item: newItem, fieldText: fieldText) {
            runtime?.send(.editTabTodoText(tabId: tabId, todoId: autoSave.autoSaveId, text: autoSave.text))
            if let oldIndex = rows.firstIndex(where: {
                if case .tabItem(let item) = $0 { return item.id == autoSave.autoSaveId }
                return false
            }) {
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

    // MARK: - Drag reorder (tab items only)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < rows.count, case .tabItem(let item) = rows[row] else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(item.id.uuidString, forType: tabTodoRowDragType)
        return pbItem
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above else { return [] }
        guard let range = tabItemRange() else { return [] }
        // Allow drops between any two tab items, plus the slot just before the
        // tab section header's first child and just after the last tab item.
        if row >= range.start && row <= range.end { return .move }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let pbItem = info.draggingPasteboard.pasteboardItems?.first,
              let idStr = pbItem.string(forType: tabTodoRowDragType),
              let uuid = UUID(uuidString: idStr),
              let range = tabItemRange() else { return false }
        // Translate table row -> tab-todo array index by subtracting the section header offset.
        let tabIndex = max(0, row - range.start)
        runtime?.send(.reorderTabTodo(tabId: tabId, todoId: uuid, toIndex: tabIndex))
        rebuildRows()
        return true
    }

    // MARK: - Actions

    @objc private func tabCheckboxToggled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < rows.count, case .tabItem(let item) = rows[row] else { return }
        runtime?.send(.toggleTabTodoDone(tabId: tabId, todoId: item.id))
        rebuildRows()
    }

    @objc private func tabDeleteTask(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < rows.count, case .tabItem(let item) = rows[row] else { return }
        runtime?.send(.deleteTabTodo(tabId: tabId, todoId: item.id))
        rebuildRows()
    }

    @objc private func paneCheckboxToggled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < rows.count,
              case .paneItem(let paneId, let item) = rows[row] else { return }
        runtime?.send(.setTodoDone(paneId: paneId, todoId: item.id, isDone: !item.isDone))
        rebuildRows()
    }

    @objc private func paneDeleteTask(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < rows.count,
              case .paneItem(let paneId, let item) = rows[row] else { return }
        runtime?.send(.deleteTodo(paneId: paneId, todoId: item.id))
        rebuildRows()
    }

    @objc private func clearCompleted() {
        runtime?.send(.clearCompletedTabTodos(tabId: tabId))
        rebuildRows()
    }
}

// MARK: - NSTextViewDelegate

extension TabTodoPopoverViewController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === addInput.textView else { return false }

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
