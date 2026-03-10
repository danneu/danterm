import Foundation

enum TabDirection {
    case prev
    case next
}

enum PaneDropIntent {
    case splitTop, splitBottom, splitLeft, splitRight, swap
}

enum Msg {
    // User actions
    case createTab(inGroupId: GroupId?)
    case selectTab(id: TabId)
    case requestCloseTab(id: TabId)
    case splitPane(direction: SplitNodeModel.Direction)
    case closePane(paneId: PaneId)
    case focusDirection(direction: SplitNodeModel.Direction, side: SplitNodeModel.Side)
    case createGroup(name: String)
    case deleteGroup(id: GroupId, moveTabs: Bool)
    case renameGroup(id: GroupId, name: String)
    case moveTab(tabId: TabId, toGroupId: GroupId, atIndex: Int)
    case reorderGroup(groupId: GroupId, toIndex: Int)
    case toggleGroupCollapse(groupId: GroupId)
    case selectAdjacentTab(direction: TabDirection)
    case paneBecameFirstResponder(paneId: PaneId)
    case toggleZoomPane
    case movePane(source: PaneId, target: PaneId, intent: PaneDropIntent)
    case movePaneToTab(paneId: PaneId, targetTabId: TabId)
    case setTabColor(tabId: TabId, color: TabColor?)
    case renameTab(id: TabId, name: String?)

    // Internal (confirmed close — do not send from UI directly)
    case closeTab(id: TabId)

    // Command tracking
    case commandStarted(paneId: PaneId, command: String)

    // Export
    case exportState

    // Ghostty callbacks
    case surfaceTitle(paneId: PaneId, title: String)
    case surfaceCwd(paneId: PaneId, cwd: String)
    case surfaceBell(paneId: PaneId)
    case desktopNotification(paneId: PaneId, title: String, body: String)
    case surfaceClosed(paneId: PaneId)
    case surfaceCreationFailed(paneId: PaneId)

    // Alerts
    case markAlertRead(alertId: AlertId)
    case markAllAlertsRead
    case activateAlert(alertId: AlertId)

    // Lifecycle
    case appBecameActive
    case appResignedActive
    case confirmTerminate
    case cancelTerminate
    case terminate

    // View
    case splitRatioChanged(splitId: SplitId, ratio: CGFloat)
}
