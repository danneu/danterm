// The seam between the one TODO popover controller and the kind of TODO list it
// shows. `TodoPopoverController` owns the whole algorithm -- projection apply,
// selection preservation, focus, key routing -- and asks a `TodoPopoverScope`
// for everything that differs between the pane list and the tab list: its row
// shape, its cells, its chrome text, and the `Msg` for each mutating action.
// Nothing here reaches back into the controller, so a scope stays a plain value.
// Keep the algorithm itself in TodoPopoverController.swift.

import Cocoa

/// One table row as the controller sees it. The scope keeps its own richer row
/// type; this is the slice the shared algorithm needs to select, edit, and
/// group rows without knowing what they are.
struct TodoPopoverRow<EditTarget: Equatable> {
    let item: TodoItem?
    let editTarget: EditTarget?
    let isSelectable: Bool
    let isHeader: Bool
}

/// A scope-decided model change plus the row to select once it lands. The
/// controller dispatches the message and selects the target against the rows
/// the re-entrant apply installed during `send`.
struct TodoPopoverMutation<EditTarget: Equatable> {
    let msg: Msg
    let select: EditTarget
}

/// An accepted drop: the message to dispatch and what stays selected after it.
/// The two scopes deliberately differ here -- the pane list keeps the row that
/// was selected before the drop, the tab list follows the dropped todo to its
/// new owner.
struct TodoPopoverDrop<EditTarget: Equatable> {
    enum Selection {
        case restorePrevious
        case target(EditTarget)
    }

    let msg: Msg
    let selection: Selection
}

/// The side effect a click on a row carries beyond selecting it. The tab list
/// uses this so a pane section header focuses that pane and dismisses the
/// popover instead of selecting.
enum TodoPopoverRowClick: Equatable {
    case ignored
    case focusPane(PaneId)
}

/// The controller-side target and selectors a scope wires into the buttons of
/// the cells it builds, so cells route back through the one shared handler
/// rather than a per-scope action.
struct TodoPopoverCellActions {
    let target: AnyObject
    let checkbox: Selector
    let delete: Selector
}

/// Everything `TodoPopoverController` cannot know about the list it is showing.
/// Each requirement is scope-specific by construction, so none carries a
/// default: a new TODO scope that forgets one fails to compile rather than
/// silently inheriting the wrong list's behavior.
protocol TodoPopoverScope {
    /// The reconciler projection this scope renders.
    associatedtype Projection: Equatable
    /// The token that identifies one editable todo inside this scope. It
    /// survives the todo moving between owners when the scope says it does.
    associatedtype EditTarget: Equatable
    /// What the scope must remember from before an add dispatch to find the
    /// row that appeared afterwards.
    associatedtype AddContext

    // MARK: Static chrome

    static var headerTitle: String { get }
    static var tableColumnIdentifier: String { get }
    static var composePlaceholder: String? { get }
    static var shortcutHelpScope: TodoShortcutScope { get }
    static var dragType: NSPasteboard.PasteboardType { get }
    /// Extra header buttons beside "Clear completed". The controller wires each
    /// to the compose shortcut and hides them all in edit mode.
    static var headerComposeButtonTitles: [String] { get }
    /// Text centered over the list when the scope has no rows at all, or nil
    /// when the scope renders its own placeholder rows instead.
    static var emptyListMessage: String? { get }
    /// Whether this scope claims the Shift-H/L and Cmd-Shift-H/L bucket keys.
    /// A scope that does not claim them must let them bubble.
    static var handlesBucketMoves: Bool { get }

    /// Pull this scope's projection out of the reconciler's one popover enum.
    static func projection(from projection: TodoPopoverProjection) -> Projection?

    // MARK: Content

    var projection: Projection { get set }
    var rows: [TodoPopoverRow<EditTarget>] { get }
    /// Drives "Clear completed" visibility.
    var hasCompleted: Bool { get }

    /// Building cells is the one requirement that touches AppKit, so it is the
    /// one requirement bound to the main actor.
    @MainActor
    func cellView(atRow index: Int, in tableView: NSTableView, actions: TodoPopoverCellActions) -> NSView?
    func rowClick(atRow index: Int) -> TodoPopoverRowClick

    // MARK: Target resolution

    /// Re-find `target` in the current projection, retargeting it if the todo
    /// it names moved, or nil once the todo is gone.
    func resolve(_ target: EditTarget) -> EditTarget?
    /// Whether two targets name the same todo, which is what decides if an
    /// in-progress edit draft survives a reconcile.
    func refersToSameTodo(_ lhs: EditTarget, _ rhs: EditTarget) -> Bool
    func editTitle(for target: EditTarget) -> String

    // MARK: Msg construction

    func addMsg(text: String) -> Msg
    func editMsg(target: EditTarget, text: String) -> Msg
    func deleteMsg(target: EditTarget) -> Msg
    /// The keyboard Space toggle, which never states the resulting value.
    func toggleDoneMsg(target: EditTarget) -> Msg
    /// The row checkbox, which the two scopes deliberately express differently.
    func checkboxMsg(target: EditTarget, isDone: Bool) -> Msg
    func clearCompletedMsg() -> Msg
    func dismissMsg() -> Msg

    /// Shift-J/K from the row at `index`, or nil when the move has nowhere to go.
    func reorder(atRow index: Int, delta: Int) -> TodoPopoverMutation<EditTarget>?
    /// Shift-H/L from `target`, or nil when there is no adjacent bucket. Only
    /// reached when `handlesBucketMoves` is true.
    func bucketMove(from target: EditTarget, delta: Int) -> TodoPopoverMutation<EditTarget>?

    /// Snapshot taken before an add dispatch; `targetAfterAdd` reads it against
    /// the projection the re-entrant apply installed.
    func addContext() -> AddContext
    func targetAfterAdd(_ context: AddContext) -> EditTarget?

    // MARK: Drag and drop

    func pasteboardWriter(atRow index: Int) -> NSPasteboardWriting?
    func validateDrop(proposedRow: Int, operation: NSTableView.DropOperation) -> NSDragOperation
    func acceptDrop(
        pasteboard: NSPasteboard,
        row: Int,
        operation: NSTableView.DropOperation
    ) -> TodoPopoverDrop<EditTarget>?
}

/// The only non-generic seam out of the TODO popover controller. The reconciler
/// and the runtime drive whichever scope is open without naming its type.
@MainActor
protocol TodoPopoverApplying: AnyObject {
    /// Render `projection` if it belongs to this controller's scope.
    func apply(_ projection: TodoPopoverProjection)
    func closeShortcutHelpPopover()
}
