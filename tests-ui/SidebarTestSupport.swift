// Shared sidebar UI harness helpers. Sidebar suites drive the production
// reconcile owner through this file instead of rebuilding its pipeline.
import Cocoa

/// Drives the production sidebar reconciler and optionally materializes every row.
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
