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
    case updateSidebarTabRow(tabId: TabId)
    case updateSidebarGroupRow(groupId: GroupId)
    case setWindowTitle(String)

    // Export
    case exportState(AppModelSnapshot)

    // System
    case sendNotification(alertId: AlertId, title: String, body: String)
    case showTerminateConfirmation(paneCount: Int)
    case showCloseTabConfirmation(tabId: TabId, tabTitle: String, paneCount: Int, isLastTab: Bool)
    case terminate
    case activateApp
    case setAppFocus(Bool)
    case dismissAlertsPopover
    case updateToolbarBellBadge(Int)
    case updateDockBadge(Int)

    // Theme
    case applyPaneTheme(paneId: PaneId)

    // Config persistence
    case saveDanTermConfigKey(key: String, value: String)
    case removeDanTermConfigKey(key: String)
    case reloadGhosttyConfig
    case syncPreferencesPanel

    // Persistence — triggers a debounced write of the model snapshot to disk.
    // Returned by state-mutating update() branches so the recovery file stays current.
    case scheduleCheckpoint

    // Search
    case sendStartSearch(paneId: PaneId)
    case showSearchOverlay(paneId: PaneId)
    case hideSearchOverlay(paneId: PaneId)
    case focusSearchField(paneId: PaneId)
    case sendSearchNeedle(paneId: PaneId, needle: String)
    case sendSearchNavigate(paneId: PaneId, direction: SearchDirection)
    case sendEndSearch(paneId: PaneId)

    // TODO
    case showTodoPopover(paneId: PaneId)
    case dismissTodoPopover
    case showClosePaneConfirmation(paneId: PaneId, uncompletedCount: Int)
}
