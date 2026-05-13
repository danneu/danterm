/// Popover view controller for the tab-level TODO list, anchored to the
/// chrome's right-side button. Shows the active tab's own to-dos plus a
/// roll-up section per pane in the tab. Tab items and pane roll-up items are
/// editable from the keyboard; new items are added to the tab section.

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

private final class TabTodoPopoverRootView: NSView {
    var handleKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class TabTodoTableView: NSTableView {
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

class TabTodoPopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var runtime: AppRuntime?
    let tabId: TabId
    private let tableView = TabTodoTableView()
    private let scrollView = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "Tab To-Do")
    private let clearButton = NSButton(title: "Clear completed", target: nil, action: nil)
    private let addInput = TodoInputView(placeholder: "Add a tab task…")
    private let editLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "Editing - Esc to cancel - Enter to save")
        tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.textColor = .secondaryLabelColor
        tf.isHidden = true
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }()

    private var editTarget: TabTodoEditTarget?
    private var composeDraft = ""
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
        guard let runtime = runtime else { return [] }
        return buildTabTodoRows(model: runtime.model, tabId: tabId)
    }

    override func loadView() {
        let size = NSSize(width: 320, height: 400)
        preferredContentSize = size

        let wrapper = TabTodoPopoverRootView(frame: NSRect(origin: .zero, size: size))
        wrapper.handleKeyEquivalent = { [weak self] event in
            self?.performTodoKeyEquivalent(with: event) ?? false
        }
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
        tableView.target = self
        tableView.doubleAction = #selector(tableRowDoubleClicked(_:))
        tableView.handleListKeyDown = { [weak self] event in
            self?.handleListKeyDown(event) ?? false
        }
        tableView.handleCancelOperation = { [weak self] in
            self?.closePopoverFromList()
            return true
        }
        tableView.registerForDraggedTypes([tabTodoRowDragType])

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

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
        let selectedTarget = selectedEditTarget()
        let selectedRowBeforeReload = tableView.selectedRow
        rows = buildRows()
        let tabItems = tabTodos
        clearButton.isHidden = !tabItems.contains(where: \.isDone)
        let wasEditingTarget = editTarget
        isSyncingTableSelection = true
        tableView.reloadData()
        if let target = wasEditingTarget {
            if item(for: target) == nil {
                editTarget = nil
                editLabel.isHidden = true
                isSyncingTableSelection = false
                selectNearestSelectableRow(near: selectedRowBeforeReload)
            } else if let newIndex = rowIndex(for: target) {
                tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
                isSyncingTableSelection = false
            } else {
                isSyncingTableSelection = false
            }
        } else if let selectedTarget,
                  let newIndex = rowIndex(for: selectedTarget) {
            tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
            isSyncingTableSelection = false
        } else {
            isSyncingTableSelection = false
        }
    }

    // MARK: - Focus and edit transitions

    private var isEditing: Bool { editTarget != nil }

    private func selectedEditTarget() -> TabTodoEditTarget? {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return nil }
        return rows[row].editTarget
    }

    private func item(for target: TabTodoEditTarget) -> TodoItem? {
        switch target {
        case .tab(let todoId):
            return tabTodos.first { $0.id == todoId }
        case .pane(let paneId, let todoId):
            return runtime?.model.panes[paneId]?.todos.first { $0.id == todoId }
        }
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

    private func populateInputFromSelection() {
        let row = tableView.selectedRow
        guard rows.indices.contains(row), let text = rows[row].itemText else { return }
        addInput.string = text
    }

    private func selectNearestSelectableRow(near row: Int) {
        if rows.indices.contains(row), rows[row].isSelectable {
            setSelectedRow(row)
            populateInputFromSelection()
            view.window?.makeFirstResponder(tableView)
            return
        }
        if let next = nextSelectableRow(in: rows, from: row, delta: 1, canSelect: { $0.isSelectable }) {
            setSelectedRow(next)
            populateInputFromSelection()
            view.window?.makeFirstResponder(tableView)
            return
        }
        if let previous = nextSelectableRow(in: rows, from: min(row, rows.count), delta: -1, canSelect: { $0.isSelectable }) {
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
        var row = tableView.selectedRow
        if !rows.indices.contains(row) || !rows[row].isSelectable {
            guard let firstRow = firstSelectableRow(in: rows, canSelect: { $0.isSelectable }) else { return false }
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
            editTarget = nil
            editLabel.isHidden = true
        }
        addInput.string = composeDraft
        view.window?.makeFirstResponder(addInput.textView)
        addInput.textView.moveToEndOfDocument(nil)
    }

    private func enterEditForSelectedRow() {
        guard let target = selectedEditTarget(), let item = item(for: target) else { return }
        if let oldTarget = editTarget, oldTarget != target {
            saveEdit(target: oldTarget, text: addInput.string)
        }
        editTarget = target
        addInput.string = item.text
        editLabel.isHidden = false
        view.window?.makeFirstResponder(addInput.textView)
        addInput.textView.selectAll(nil)
    }

    @discardableResult
    private func saveEditThenReturnToList() -> Bool {
        guard let target = editTarget else { return false }
        let text = addInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        saveEdit(target: target, text: text)
        editTarget = nil
        editLabel.isHidden = true
        rebuildRows()
        _ = selectTarget(target)
        addInput.string = text
        view.window?.makeFirstResponder(tableView)
        return true
    }

    private func addTodoAndStayInCompose() {
        let text = addInput.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        runtime?.send(.addTabTodo(tabId: tabId, text: text))
        composeDraft = ""
        addInput.string = ""
        rebuildRows()
        view.window?.makeFirstResponder(addInput.textView)
    }

    private func cancelEditAndReturnToList() {
        guard let target = editTarget else { return }
        editTarget = nil
        editLabel.isHidden = true
        if selectTarget(target) {
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

    /// NSTableViewDelegate: selection changes update the passive input preview.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingTableSelection else { return }
        let row = tableView.selectedRow
        if row < 0, editTarget != nil {
            cancelEditAndReturnToList()
            return
        }
        guard row >= 0, row < rows.count,
              let newTarget = rows[row].editTarget,
              let newText = rows[row].itemText else { return }

        if let oldTarget = editTarget, oldTarget != newTarget {
            saveEdit(target: oldTarget, text: addInput.string)
            editTarget = nil
            editLabel.isHidden = true
            rebuildRows()
            _ = selectTarget(newTarget)
            addInput.string = newText
            return
        }
        addInput.string = newText
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
        guard let runtime = runtime,
              let operation = tabTodoDropOperation(from: dropOperation),
              resolveTabTodoDropTarget(
                rows: rows,
                model: runtime.model,
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
                model: runtime.model,
                tabId: tabId,
                proposedRow: row,
                dropOperation: operation
              ) else { return false }

        let source = todoSource(from: payload.source, tabId: tabId)
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

    @objc private func tableRowDoubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        enterEditForSelectedRow()
    }

    private func toggleSelectedTodoDone() {
        guard let target = selectedEditTarget() else { return }
        let previewText = addInput.string
        switch target {
        case .tab(let todoId):
            runtime?.send(.toggleTabTodoDone(tabId: tabId, todoId: todoId))
        case .pane(let paneId, let todoId):
            runtime?.send(.toggleTodoDone(paneId: paneId, todoId: todoId))
        }
        rebuildRows()
        _ = selectTarget(target)
        addInput.string = previewText
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
        rebuildRows()
        selectNearestSelectableRow(near: row)
    }

    private func reorderSelectedTodo(delta: Int) {
        let row = tableView.selectedRow
        let destinationRow = row + delta
        guard rows.indices.contains(row),
              rows.indices.contains(destinationRow),
              rows[destinationRow].isSelectable,
              rows[row].sectionIdentifier == rows[destinationRow].sectionIdentifier,
              let target = selectedEditTarget(),
              let destination = sectionLocalIndex(
                  rows: rows,
                  at: destinationRow,
                  isHeader: { $0.isHeader },
                  sectionId: { $0.sectionIdentifier }
              ) else { return }

        switch target {
        case .tab(let todoId):
            runtime?.send(.reorderTabTodo(tabId: tabId, todoId: todoId, toIndex: destination))
        case .pane(let paneId, let todoId):
            runtime?.send(.reorderTodo(paneId: paneId, todoId: todoId, toIndex: destination))
        }
        rebuildRows()
        _ = selectTarget(target)
        populateInputFromSelection()
        view.window?.makeFirstResponder(tableView)
    }

    private func moveSelection(delta: Int) {
        let row = tableView.selectedRow
        guard let nextRow = nextSelectableRow(in: rows, from: row, delta: delta, canSelect: { $0.isSelectable }) else { return }
        setSelectedRow(nextRow)
        populateInputFromSelection()
    }

    private func moveSelectedTodoToAdjacentBucket(delta: Int) -> Bool {
        guard view.window?.firstResponder === tableView || isEditing else { return false }
        if isEditing {
            _ = saveEditThenReturnToList()
        }
        guard let current = selectedEditTarget(),
              let item = item(for: current),
              let tab = tab,
              let destination = resolveTabTodoBucketStep(
                current: current,
                paneOrder: allPaneIds(tab.rootNode),
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
        rebuildRows()
        let newTarget: TabTodoEditTarget
        switch destination {
        case .tab:
            newTarget = .tab(todoId: item.id)
        case .pane(let paneId):
            newTarget = .pane(paneId: paneId, todoId: item.id)
        }
        _ = selectTarget(newTarget)
        populateInputFromSelection()
        view.window?.makeFirstResponder(tableView)
        return true
    }

    private func handleListKeyDown(_ event: NSEvent) -> Bool {
        let action = classifyListAction(key: tabListKey(from: event), modifiers: tabKeyModifiers(from: event))
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
        case .focusInput:
            focusComposeInput()
            return true
        case .unhandled:
            return false
        }
    }

    private func performTodoKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = tabKeyModifiers(from: event)
        if modifiers == [.command, .shift] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h":
                return moveSelectedTodoToAdjacentBucket(delta: -1)
            case "l":
                return moveSelectedTodoToAdjacentBucket(delta: 1)
            default:
                return false
            }
        }

        guard modifiers == [.command] else { return false }
        switch tabListKey(from: event) {
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
        runtime?.send(.toggleTodoPopoverForTab(tabId: tabId))
    }
}

// MARK: - NSTextViewDelegate

extension TabTodoPopoverViewController: NSTextViewDelegate {
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
            isEditing: editTarget != nil,
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

    /// NSTextViewDelegate: keep the compose draft live while adding a tab item.
    func textDidChange(_ notification: Notification) {
        guard view.window?.firstResponder === addInput.textView, !isEditing else { return }
        composeDraft = addInput.string
    }
}

private func tabKeyModifiers(from event: NSEvent) -> KeyModifiers {
    var modifiers = KeyModifiers()
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command) { modifiers.insert(.command) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    return modifiers
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

private func tabListKey(from event: NSEvent) -> ListKey {
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
    case "j":
        return .j
    case "k":
        return .k
    case "n":
        return .n
    default:
        return .other
    }
}
