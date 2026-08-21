// Shared sidebar UI harness helpers. Sidebar suites drive the production
// reconcile owner through this file instead of rebuilding its pipeline.
import Cocoa
import ChipArtwork
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

/// Drives the production sidebar reconciler and optionally materializes every row.
@MainActor
@discardableResult
func applySidebarTestModel(
    _ model: AppModel,
    using driver: SidebarReconcileDriver,
    to sidebar: SidebarView,
    outline: NSOutlineView,
    materializeRows: Bool = true
) -> SidebarReconcileResult {
    let result = driver.reconcile(model, in: sidebar)
    if materializeRows {
        materializeSidebarRows(sidebar, outline: outline)
    }
    return result
}

/// Begins an inline rename the way production does: the model records the
/// target and the reconcile pass hands the field editor over. The view has no
/// entry point of its own, so every suite opens an editor through here.
@MainActor
@discardableResult
func beginRenameThroughModel(
    _ target: RenameTarget,
    in model: inout AppModel,
    driver: SidebarReconcileDriver,
    sidebar: SidebarView,
    outline: NSOutlineView
) -> SidebarReconcileResult {
    _ = recordRenameBegin(target, in: &model)
    return applySidebarTestModel(model, using: driver, to: sidebar, outline: outline)
}

/// Records one rename begin in the model and returns the session it minted, the
/// way `update(.beginSidebarRename)` does. The UI harness compiles the model but
/// not the reducer, so the mint is spelled out here; a begin on a row an earlier
/// session already edited still mints its own identity, which is what makes the
/// pass open an editor again.
@discardableResult
func recordRenameBegin(_ target: RenameTarget, in model: inout AppModel) -> RenameSessionId {
    let session = RenameSessionId(rawValue: UUID())
    model.sidebarRename = SidebarRenameSession(id: session, target: target)
    return session
}

/// Lets the main queue deliver what the code under test posted, until `condition`
/// holds. The deadline is a hang guard, not a measurement: a passing run satisfies
/// the condition on the first turn.
///
/// A suspension, not a nested run loop. The suite runs inside a main-queue work
/// item, and a serial queue does not re-enter itself, so spinning a run loop here
/// would never dequeue the block the code under test just posted. Suspending
/// releases the work item, and the queue delivers before the next resume.
func pumpMainQueue(
    untilTrue condition: () -> Bool,
    timeout: TimeInterval = 5,
    file: String = #file,
    line: Int = #line
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            throw UITestFailure(
                message: "timed out waiting for the main queue to deliver (\(file):\(line))")
        }
        await pumpMainQueueOnce()
    }
}

/// Gives the main queue one turn, so a report that had a chance to arrive has
/// taken it. Meant to expire: the point is to let delivery happen before asserting
/// that nothing arrived.
@MainActor
func pumpMainQueueOnce() async {
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(5))
}

/// Materializes every visible outline row after a reconcile pass.
func materializeSidebarRows(_ sidebar: SidebarView, outline: NSOutlineView) {
    sidebar.layoutSubtreeIfNeeded()
    outline.layoutSubtreeIfNeeded()
    for row in 0..<outline.numberOfRows {
        _ = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
        _ = outline.rowView(atRow: row, makeIfNecessary: true)
    }
}

/// Finds the sidebar's outline view without exposing it from production code.
func sidebarOutlineView(in view: NSView) -> NSOutlineView? {
    if let outline = view as? NSOutlineView { return outline }
    for subview in view.subviews {
        if let found = sidebarOutlineView(in: subview) { return found }
    }
    return nil
}

/// Returns the materialized cell for one projected sidebar entity.
func sidebarCell<Cell: NSTableCellView>(
    for target: RenameTarget,
    in outline: NSOutlineView,
    file: String = #file,
    line: Int = #line
) throws -> Cell {
    for row in 0..<outline.numberOfRows {
        guard let item = outline.item(atRow: row) as? SidebarItem else { continue }
        let matches: Bool = {
            switch (target, item.kind) {
            case (.tab(let expected), .tab(let tab)): return expected == tab.id
            case (.group(let expected), .group(let group)): return expected == group.id
            default: return false
            }
        }()
        guard matches,
              let cell = outline.view(
                atColumn: 0, row: row, makeIfNecessary: true) as? Cell
        else { continue }
        return cell
    }
    throw UITestFailure(message: "missing cell for \(target) (\(file):\(line))")
}

/// Returns the current outline row for one tab.
func sidebarTabRow(
    for tabId: TabId,
    in outline: NSOutlineView,
    file: String = #file,
    line: Int = #line
) throws -> Int {
    for row in 0..<outline.numberOfRows {
        guard let item = outline.item(atRow: row) as? SidebarItem,
              case .tab(let tab) = item.kind,
              tab.id == tabId
        else { continue }
        return row
    }
    throw UITestFailure(message: "missing row for tab \(tabId) (\(file):\(line))")
}

/// Returns the visible tab ids in outline row order.
func sidebarTabIds(in outline: NSOutlineView) -> [TabId] {
    (0..<outline.numberOfRows).compactMap { row in
        guard let item = outline.item(atRow: row) as? SidebarItem,
              case .tab(let tab) = item.kind
        else { return nil }
        return tab.id
    }
}

/// Builds the common unread bell fixture for sidebar projection tests.
func sidebarBellAlert(paneId: PaneId) -> AlertModel {
    AlertModel(
        id: AlertId(),
        kind: .bell,
        paneId: paneId,
        title: "bell",
        body: "",
        createdAt: Date(timeIntervalSince1970: 0),
        isUnread: true)
}

// MARK: - Unmaterialized-cell staging

/// Makes the sidebar's next materialized-cell lookup for one row report nothing,
/// the way AppKit does for a row it has not built a view for yet, and restores
/// itself afterwards.
///
/// The reconcile loop retries through that state, and nothing else can put AppKit
/// into it on demand, so the lookup is a given collaborator on `SidebarView` and
/// this is the suite's stand-in for it. Matching on the item at the queried row
/// rather than on a row number is what keeps the stage correct across an insert
/// or a collapse that moves rows before the pass runs.
@MainActor
private func forceNextUnmaterializedCell(
    matching isTarget: @escaping (SidebarItem) -> Bool,
    in sidebar: SidebarView,
    outline: NSOutlineView
) {
    let underlying = sidebar.materializedCell
    var pending = true
    sidebar.materializedCell = { [weak outline] row in
        if pending,
           let item = outline?.item(atRow: row) as? SidebarItem,
           isTarget(item)
        {
            pending = false
            return nil
        }
        return underlying(row)
    }
}

@MainActor
func forceNextUnmaterializedCell(
    forTab tab: TabId,
    in sidebar: SidebarView,
    outline: NSOutlineView
) {
    forceNextUnmaterializedCell(
        matching: { item in
            guard case .tab(let projection) = item.kind else { return false }
            return projection.id == tab
        },
        in: sidebar,
        outline: outline
    )
}

@MainActor
func forceNextUnmaterializedCell(
    forGroup group: GroupId,
    in sidebar: SidebarView,
    outline: NSOutlineView
) {
    forceNextUnmaterializedCell(
        matching: { item in
            guard case .group(let projection) = item.kind else { return false }
            return projection.id == group
        },
        in: sidebar,
        outline: outline
    )
}
