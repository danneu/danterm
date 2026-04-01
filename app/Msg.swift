import Foundation

enum TabDirection {
    case prev
    case next
}

enum PaneDropIntent {
    case splitTop, splitBottom, splitLeft, splitRight, swap
}

enum SearchDirection {
    case next
    case previous
}

enum Msg {
    // User actions
    case createTab(inGroupId: GroupId?)
    case selectTab(id: TabId)
    case requestCloseTab(id: TabId)
    case splitPane(paneId: PaneId? = nil, direction: SplitNodeModel.Direction)
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
    case movePaneToNewTab(paneId: PaneId, inGroupId: GroupId, atIndex: Int)
    case setTabColor(tabId: TabId, color: TabColor?)
    case setPaneTheme(paneId: PaneId, themeName: String?)
    case renameTab(id: TabId, name: String?)
    case sidebarRenameEnded

    // Internal (confirmed close — do not send from UI directly)
    case closeTab(id: TabId)

    // Command tracking
    case commandStarted(paneId: PaneId, command: String)
    case commandEnded(paneId: PaneId)

    // Remote detection
    case remoteSessionStarted(paneId: PaneId)

    // Export
    case exportState

    // Ghostty callbacks
    case surfaceTitle(paneId: PaneId, title: String)
    case surfaceCwd(paneId: PaneId, cwd: String)
    case surfaceBell(paneId: PaneId)
    case desktopNotification(paneId: PaneId, title: String, body: String)
    case surfaceProgress(paneId: PaneId, state: ProgressState?)
    case surfaceClosed(paneId: PaneId)
    case surfaceCreationFailed(paneId: PaneId)

    // Alerts
    case markAlertRead(alertId: AlertId)
    case markAllAlertsRead
    case activateAlert(alertId: AlertId)
    case goToMostRecentAlertPane
    case setShowAllAlerts(Bool)
    case clearAlertsForPane(paneId: PaneId)
    case ackTabAlerts
    case clearAlertsForTab(tabId: TabId)

    // Config
    case configLoaded(DanTermConfig)

    // Lifecycle
    case appBecameActive
    case appResignedActive
    case requestQuit
    case confirmTerminate
    case cancelTerminate
    case terminate

    // View
    case splitRatioChanged(splitId: SplitId, ratio: CGFloat)

    // Search
    case startSearch
    case searchNeedleChanged(paneId: PaneId, needle: String)
    case searchNavigate(paneId: PaneId, direction: SearchDirection)
    case endSearch(paneId: PaneId)
    // Ghostty search callbacks
    case ghosttyStartSearch(paneId: PaneId, needle: String)
    case ghosttySearchTotal(paneId: PaneId, total: Int?)
    case ghosttySearchSelected(paneId: PaneId, selected: Int?)
}

/// Which entity was being renamed (used by renameCompletionMessages).
enum RenameAction {
    case tab(TabId)
    case group(GroupId)
}

/// Pure function: determines what messages doCommandBy should dispatch
/// for Enter (confirm) vs Esc (cancel).
func renameCompletionMessages(
    isConfirm: Bool,
    action: RenameAction?,
    newName: String
) -> [Msg] {
    var msgs: [Msg] = []
    if isConfirm {
        switch action {
        case .tab(let tabId):
            let name: String? = newName.isEmpty ? nil : newName
            msgs.append(.renameTab(id: tabId, name: name))
        case .group(let groupId):
            if !newName.isEmpty {
                msgs.append(.renameGroup(id: groupId, name: newName))
            }
        case nil:
            break
        }
    }
    msgs.append(.sidebarRenameEnded)
    return msgs
}
