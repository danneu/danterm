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
    case reloadSidebar
    case reloadSidebarRow(tabId: TabId)
    case reloadSidebarGroupRow(groupId: GroupId)
    case setWindowTitle(String)

    // System
    case sendNotification(title: String, body: String, tabId: TabId, paneId: PaneId)
    case requestNotificationPermission
    case showTerminateConfirmation
    case showCloseTabConfirmation(tabId: TabId, tabTitle: String, paneCount: Int, isLastTab: Bool)
    case terminate
    case activateApp
    case setAppFocus(Bool)
    case updateDockBadge(Int)
}
