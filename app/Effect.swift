import Foundation

enum Effect {
    // Surface
    case createSurface(paneId: PaneId, cwd: String?, command: String?)
    case destroySurface(paneId: PaneId)

    // Focus
    case focusSurface(paneId: PaneId, focused: Bool)
    case makeFirstResponder(paneId: PaneId)

    // View
    case rebuildContentView
    case updatePaneAlertBorder(paneId: PaneId)
    case reloadSidebar
    case reloadSidebarRow(tabId: TabId)
    case reloadSidebarGroupRow(groupId: GroupId)
    case setWindowTitle(String)

    // Export
    case exportState(AppModelSnapshot)

    // System
    case sendNotification(alertId: AlertId, title: String, body: String)
    case showTerminateConfirmation
    case showCloseTabConfirmation(tabId: TabId, tabTitle: String, paneCount: Int, isLastTab: Bool)
    case terminate
    case activateApp
    case setAppFocus(Bool)
    case dismissAlertsPopover
    case updateToolbarBellBadge(Int)
    case updateDockBadge(Int)

    // Persistence — triggers a debounced write of the model snapshot to disk.
    // Returned by state-mutating update() branches so the recovery file stays current.
    case scheduleCheckpoint
}
