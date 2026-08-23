// The tab scope for the shared TODO popover controller: the active tab's own
// to-dos plus a roll-up section per pane in the tab, with section headers,
// per-section placeholders, bucket moves, and cross-section drags. This file
// holds only what is specific to that list -- its rows, cells, drag payload,
// and messages. The popover's behavior lives once in TodoPopoverController.swift.

import Cocoa

private let tabTodoRowDragType = NSPasteboard.PasteboardType("com.danneu.danterm.tab-todo-row")
private let tabHeaderRowId = NSUserInterfaceItemIdentifier("TabTodoHeader")
private let paneHeaderRowId = NSUserInterfaceItemIdentifier("PaneTodoHeader")
private let tabTodoEmptyRowId = NSUserInterfaceItemIdentifier("TabTodoEmptyRow")

private struct TabTodoDragPayload: Codable {
    enum Source: Equatable {
        case tab
        case pane(PaneId)
    }

    let source: Source
    let todoId: TodoId

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
            self = .pane(try container.decode(PaneId.self, forKey: .paneId))
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
/// The pane variant acts as a button: clicking the header focuses the pane.
private final class TabTodoHeaderRowView: NSView {
    let titleLabel: NSTextField = {
        let tf = SingleLineLabel.make()
        tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        tf.textColor = .secondaryLabelColor
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

// MARK: - Scope

/// A tab TODO list, addressed by tab id. Its edit target carries an owner as
/// well as a todo id, because a tab todo moves between the tab bucket and its
/// pane buckets while the user is looking at it.
struct TabTodoPopoverScope: TodoPopoverScope {
    let tabId: TabId
    var projection: TabTodoPopoverProjection

    init(tabId: TabId) {
        self.tabId = tabId
        self.projection = TabTodoPopoverProjection(
            tabId: tabId,
            rows: [],
            paneOrder: [],
            tabHasCompleted: false
        )
    }

    // MARK: Static chrome

    static let headerTitle = "Tab To-Do"
    static let tableColumnIdentifier = "tabtodo"
    static let composePlaceholder: String? = "Add a tab task…"
    static let shortcutHelpScope = TodoShortcutScope.tab
    static let dragType = tabTodoRowDragType
    static let headerComposeButtonTitles = ["New (\u{2318}N)"]
    static let emptyListMessage: String? = nil
    static let handlesBucketMoves = true

    static func projection(from projection: TodoPopoverProjection) -> TabTodoPopoverProjection? {
        guard case .tab(let tab) = projection else { return nil }
        return tab
    }

    // MARK: Content

    private var sourceRows: [TabTodoRow] { projection.rows }

    var rows: [TodoPopoverRow<TabTodoEditTarget>] {
        projection.rows.map {
            TodoPopoverRow(
                item: $0.item,
                editTarget: $0.editTarget,
                isSelectable: $0.isSelectable,
                isHeader: $0.isHeader
            )
        }
    }

    var hasCompleted: Bool { projection.tabHasCompleted }

    func cellView(atRow index: Int, in tableView: NSTableView, actions: TodoPopoverCellActions) -> NSView? {
        guard sourceRows.indices.contains(index) else { return nil }
        switch sourceRows[index] {
        case .tabSectionHeader:
            let view = (tableView.makeView(withIdentifier: tabHeaderRowId, owner: actions.target)
                as? TabTodoHeaderRowView) ?? TabTodoHeaderRowView()
            view.identifier = tabHeaderRowId
            view.configure(title: "This tab")
            return view

        case .tabItem(_, let item), .paneItem(_, let item):
            // Tab and pane items share TodoRowView so a rolled-up pane task
            // looks the same as a tab task; the row's edit target is what
            // routes its checkbox and delete to the right owner.
            let rowView = (tableView.makeView(withIdentifier: todoRowId, owner: actions.target)
                as? TodoRowView) ?? TodoRowView()
            rowView.identifier = todoRowId
            rowView.configure(with: item)
            rowView.checkbox.target = actions.target
            rowView.checkbox.action = actions.checkbox
            rowView.deleteButton.target = actions.target
            rowView.deleteButton.action = actions.delete
            return rowView

        case .paneSectionHeader(_, let title):
            let view = (tableView.makeView(withIdentifier: paneHeaderRowId, owner: actions.target)
                as? TabTodoHeaderRowView) ?? TabTodoHeaderRowView()
            view.identifier = paneHeaderRowId
            view.configure(title: title.text)
            return view

        case .tabEmptyPlaceholder, .paneEmptyPlaceholder:
            let view = (tableView.makeView(withIdentifier: tabTodoEmptyRowId, owner: actions.target)
                as? TabTodoEmptyRowView) ?? TabTodoEmptyRowView()
            view.identifier = tabTodoEmptyRowId
            return view
        }
    }

    func rowClick(atRow index: Int) -> TodoPopoverRowClick {
        guard sourceRows.indices.contains(index),
              case .paneSectionHeader(let paneId, _) = sourceRows[index] else { return .ignored }
        return .focusPane(paneId)
    }

    // MARK: Target resolution

    func resolve(_ target: TabTodoEditTarget) -> TabTodoEditTarget? {
        resolveTabTodoEditTarget(target, in: projection)
    }

    /// Owner is deliberately ignored: an edit follows its todo across a bucket
    /// move, so the draft survives when only the owner changed.
    func refersToSameTodo(_ lhs: TabTodoEditTarget, _ rhs: TabTodoEditTarget) -> Bool {
        lhs.id == rhs.id
    }

    func editTitle(for target: TabTodoEditTarget) -> String {
        switch target.owner {
        case .tab:
            return "Edit tab task"
        case .pane(let paneId):
            return "Edit pane task: \(paneTitle(for: paneId) ?? "pane")"
        }
    }

    private func paneTitle(for paneId: PaneId) -> String? {
        for row in sourceRows {
            if case .paneSectionHeader(let rowPaneId, let title) = row, rowPaneId == paneId {
                return title.text
            }
        }
        return nil
    }

    private func item(for target: TabTodoEditTarget) -> TodoItem? {
        sourceRows.first { $0.editTarget == target }?.item
    }

    // MARK: Msg construction

    func addMsg(text: String) -> Msg { .addTodo(owner: .tab(tabId), text: text) }

    func editMsg(target: TabTodoEditTarget, text: String) -> Msg {
        .editTodoText(owner: target.owner, todoId: target.id, text: text)
    }

    func deleteMsg(target: TabTodoEditTarget) -> Msg {
        .deleteTodo(owner: target.owner, todoId: target.id)
    }

    func toggleDoneMsg(target: TabTodoEditTarget) -> Msg {
        .toggleTodoDone(owner: target.owner, todoId: target.id)
    }

    /// Rolled-up pane rows can be shown while another surface edits the same
    /// todo, so the checkbox states the value it just drew rather than toggling.
    func checkboxMsg(target: TabTodoEditTarget, isDone: Bool) -> Msg {
        .setTodoDone(owner: target.owner, todoId: target.id, isDone: isDone)
    }

    func clearCompletedMsg() -> Msg { .clearCompletedTodos(owner: .tab(tabId)) }

    func dismissMsg() -> Msg { .toggleTodoPopover(owner: .tab(tabId)) }

    func reorder(atRow index: Int, delta: Int) -> TodoPopoverMutation<TabTodoEditTarget>? {
        let rows = sourceRows
        guard rows.indices.contains(index),
              let target = rows[index].editTarget,
              let currentIndex = sectionLocalIndex(
                  rows: rows,
                  at: index,
                  isHeader: { $0.isHeader },
                  sectionId: { $0.sectionIdentifier }
              ) else { return nil }

        let sectionIdentifier = rows[index].sectionIdentifier
        let currentSectionCount = rows.count {
            $0.isSelectable && $0.sectionIdentifier == sectionIdentifier
        }
        guard let step = resolveTabTodoReorderStep(
            current: target,
            paneOrder: projection.paneOrder,
            tabId: tabId,
            currentIndex: currentIndex,
            currentSectionCount: currentSectionCount,
            destinationSectionCount: { sectionItemCount(for: $0) },
            delta: delta
        ) else { return nil }

        switch step {
        case .reorderInSection(let destination):
            return TodoPopoverMutation(
                msg: .reorderTodo(owner: target.owner, todoId: target.id, toIndex: destination),
                select: target
            )
        case .moveToBucket(let destination, let atIndex):
            guard let item = item(for: target) else { return nil }
            return TodoPopoverMutation(
                msg: .moveTodo(from: target.owner, todoId: item.id, to: destination, atIndex: atIndex),
                select: .init(owner: destination, id: item.id)
            )
        }
    }

    func bucketMove(from target: TabTodoEditTarget, delta: Int) -> TodoPopoverMutation<TabTodoEditTarget>? {
        guard let item = item(for: target),
              let destination = resolveTabTodoBucketStep(
                  current: target,
                  paneOrder: projection.paneOrder,
                  tabId: tabId,
                  delta: delta
              ) else { return nil }
        return TodoPopoverMutation(
            msg: .moveTodo(from: target.owner, todoId: item.id, to: destination, atIndex: 0),
            select: .init(owner: destination, id: item.id)
        )
    }

    private func sectionItemCount(for destination: TodoOwner) -> Int {
        switch destination {
        case .tab:
            return sourceRows.count { row in
                if case .tabItem = row { return true }
                return false
            }
        case .pane(let paneId):
            return sourceRows.count { row in
                if case .paneItem(let rowPaneId, _) = row { return rowPaneId == paneId }
                return false
            }
        }
    }

    /// The tab section's todo ids before an add, so the row that appears
    /// afterwards can be told from the ones that were already there.
    func addContext() -> Set<TodoId> {
        Set(sourceRows.compactMap { row -> TodoId? in
            if case .tabItem(_, let item) = row { return item.id }
            return nil
        })
    }

    func targetAfterAdd(_ context: Set<TodoId>) -> TabTodoEditTarget? {
        newlyAddedTabTodoTarget(previousTabTodoIds: context, in: projection)
    }

    // MARK: Drag and drop

    func pasteboardWriter(atRow index: Int) -> NSPasteboardWriting? {
        guard sourceRows.indices.contains(index) else { return nil }
        let payload: TabTodoDragPayload
        switch sourceRows[index] {
        case .tabItem(_, let item):
            payload = TabTodoDragPayload(source: .tab, todoId: item.id)
        case .paneItem(let paneId, let item):
            payload = TabTodoDragPayload(source: .pane(paneId), todoId: item.id)
        case .tabSectionHeader, .tabEmptyPlaceholder, .paneSectionHeader, .paneEmptyPlaceholder:
            return nil
        }
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(json, forType: tabTodoRowDragType)
        return pbItem
    }

    func validateDrop(proposedRow: Int, operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let dropOperation = tabTodoDropOperation(from: operation),
              dropTarget(proposedRow: proposedRow, operation: dropOperation) != nil else { return [] }
        return .move
    }

    func acceptDrop(
        pasteboard: NSPasteboard,
        row: Int,
        operation: NSTableView.DropOperation
    ) -> TodoPopoverDrop<TabTodoEditTarget>? {
        guard let pbItem = pasteboard.pasteboardItems?.first,
              let json = pbItem.string(forType: tabTodoRowDragType),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TabTodoDragPayload.self, from: data),
              let dropOperation = tabTodoDropOperation(from: operation),
              let target = dropTarget(proposedRow: row, operation: dropOperation) else { return nil }

        let source = todoSource(from: payload.source, tabId: tabId)
        let msg: Msg
        if sameTodoBucket(source: source, destination: target.destination) {
            msg = .reorderTodo(owner: source, todoId: payload.todoId, toIndex: target.atIndex)
        } else {
            msg = .moveTodo(
                from: source,
                todoId: payload.todoId,
                to: target.destination,
                atIndex: target.atIndex
            )
        }
        return TodoPopoverDrop(
            msg: msg,
            selection: .target(.init(owner: target.destination, id: payload.todoId))
        )
    }

    private func dropTarget(
        proposedRow: Int,
        operation: TabTodoDropOperation
    ) -> (destination: TodoOwner, atIndex: Int)? {
        resolveTabTodoDropTarget(
            rows: sourceRows,
            tabId: tabId,
            proposedRow: proposedRow,
            dropOperation: operation
        )
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

private func todoSource(from payloadSource: TabTodoDragPayload.Source, tabId: TabId) -> TodoOwner {
    switch payloadSource {
    case .tab:
        return .tab(tabId)
    case .pane(let paneId):
        return .pane(paneId)
    }
}

private func sameTodoBucket(source: TodoOwner, destination: TodoOwner) -> Bool {
    switch (source, destination) {
    case (.tab(let sourceId), .tab(let destinationId)):
        return sourceId == destinationId
    case (.pane(let sourceId), .pane(let destinationId)):
        return sourceId == destinationId
    case (.tab, .pane), (.pane, .tab):
        return false
    }
}
