// The pane scope for the shared TODO popover controller: a flat list of one
// pane's tasks with checkboxes, delete buttons, drag-to-reorder, and a
// "Clear completed" button. This file holds only what is specific to that list
// -- its rows, cells, drag payload, and messages. The popover's behavior lives
// once in TodoPopoverController.swift.

import Cocoa

private let todoRowDragType = NSPasteboard.PasteboardType("com.danneu.danterm.todo-row")

/// A pane TODO list, addressed by pane id. Its edit target is the todo id
/// itself, because a pane todo never changes owner.
struct PaneTodoPopoverScope: TodoPopoverScope {
    let paneId: PaneId
    var projection: PaneTodoPopoverProjection

    init(paneId: PaneId) {
        self.paneId = paneId
        self.projection = PaneTodoPopoverProjection(paneId: paneId, rows: [], hasCompleted: false)
    }

    // MARK: Static chrome

    static let headerTitle = "Pane To-Do"
    static let tableColumnIdentifier = "todo"
    static let composePlaceholder: String? = nil
    static let shortcutHelpScope = TodoShortcutScope.pane
    static let dragType = todoRowDragType
    static let headerComposeButtonTitles: [String] = []
    static let emptyListMessage: String? = "No tasks yet"
    static let handlesBucketMoves = false

    static func projection(from projection: TodoPopoverProjection) -> PaneTodoPopoverProjection? {
        guard case .pane(let pane) = projection else { return nil }
        return pane
    }

    // MARK: Content

    private var todos: [TodoItem] { projection.rows }

    var rows: [TodoPopoverRow<TodoId>] {
        projection.rows.map {
            TodoPopoverRow(item: $0, editTarget: $0.id, isSelectable: true, isHeader: false)
        }
    }

    var hasCompleted: Bool { projection.hasCompleted }

    func cellView(atRow index: Int, in tableView: NSTableView, actions: TodoPopoverCellActions) -> NSView? {
        guard todos.indices.contains(index) else { return nil }
        let rowView = (tableView.makeView(withIdentifier: todoRowId, owner: actions.target) as? TodoRowView)
            ?? TodoRowView()
        rowView.identifier = todoRowId
        rowView.configure(with: todos[index])
        rowView.checkbox.target = actions.target
        rowView.checkbox.action = actions.checkbox
        rowView.deleteButton.target = actions.target
        rowView.deleteButton.action = actions.delete
        return rowView
    }

    func rowClick(atRow index: Int) -> TodoPopoverRowClick { .ignored }

    // MARK: Target resolution

    func resolve(_ target: TodoId) -> TodoId? {
        todos.contains { $0.id == target } ? target : nil
    }

    func refersToSameTodo(_ lhs: TodoId, _ rhs: TodoId) -> Bool { lhs == rhs }

    func editTitle(for target: TodoId) -> String { "Edit pane task" }

    // MARK: Msg construction

    private var owner: TodoOwner { .pane(paneId) }

    func addMsg(text: String) -> Msg { .addTodo(owner: owner, text: text) }

    func editMsg(target: TodoId, text: String) -> Msg {
        .editTodoText(owner: owner, todoId: target, text: text)
    }

    func deleteMsg(target: TodoId) -> Msg { .deleteTodo(owner: owner, todoId: target) }

    func toggleDoneMsg(target: TodoId) -> Msg { .toggleTodoDone(owner: owner, todoId: target) }

    /// The pane list toggles rather than stating the new value, so two clicks
    /// racing the model still land on the value the user last saw.
    func checkboxMsg(target: TodoId, isDone: Bool) -> Msg { .toggleTodoDone(owner: owner, todoId: target) }

    func clearCompletedMsg() -> Msg { .clearCompletedTodos(owner: owner) }

    func dismissMsg() -> Msg { .toggleTodoPopover(owner: owner) }

    func reorder(atRow index: Int, delta: Int) -> TodoPopoverMutation<TodoId>? {
        let destination = index + delta
        guard todos.indices.contains(index), todos.indices.contains(destination) else { return nil }
        let target = todos[index].id
        return TodoPopoverMutation(
            msg: .reorderTodo(owner: owner, todoId: target, toIndex: destination),
            select: target
        )
    }

    /// A pane list has no adjacent bucket to move into; `handlesBucketMoves`
    /// keeps the controller from ever asking.
    func bucketMove(from target: TodoId, delta: Int) -> TodoPopoverMutation<TodoId>? { nil }

    func addContext() {}

    /// Adding a pane task leaves the selection where the user put it.
    func targetAfterAdd(_ context: Void) -> TodoId? { nil }

    // MARK: Drag and drop

    func pasteboardWriter(atRow index: Int) -> NSPasteboardWriting? {
        guard todos.indices.contains(index) else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(todos[index].id.rawValue.uuidString, forType: todoRowDragType)
        return pbItem
    }

    func validateDrop(proposedRow: Int, operation: NSTableView.DropOperation) -> NSDragOperation {
        operation == .above ? .move : []
    }

    func acceptDrop(
        pasteboard: NSPasteboard,
        row: Int,
        operation: NSTableView.DropOperation
    ) -> TodoPopoverDrop<TodoId>? {
        guard let pbItem = pasteboard.pasteboardItems?.first,
              let idString = pbItem.string(forType: todoRowDragType),
              let uuid = UUID(uuidString: idString) else { return nil }
        return TodoPopoverDrop(
            msg: .reorderTodo(owner: owner, todoId: TodoId(rawValue: uuid), toIndex: row),
            selection: .restorePrevious
        )
    }
}
