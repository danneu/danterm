import Foundation

enum Msg {
    // User actions
    case createTab(inGroupId: GroupId?)
    case selectTab(id: TabId)
    case closeTab(id: TabId)
    case splitPane(direction: SplitNodeModel.Direction)
    case closePane(paneId: PaneId)
    case focusDirection(direction: SplitNodeModel.Direction, side: SplitNodeModel.Side)
    case createGroup(name: String)
    case deleteGroup(id: GroupId, moveTabs: Bool)
    case renameGroup(id: GroupId, name: String)
    case moveTab(tabId: TabId, toGroupId: GroupId, atIndex: Int)
    case reorderGroup(groupId: GroupId, toIndex: Int)
    case toggleGroupCollapse(groupId: GroupId)
    case paneBecameFirstResponder(paneId: PaneId)

    // Ghostty callbacks
    case surfaceTitle(paneId: PaneId, title: String)
    case surfaceCwd(paneId: PaneId, cwd: String)
    case surfaceBell(paneId: PaneId)
    case surfaceClosed(paneId: PaneId)
    case surfaceCreationFailed(paneId: PaneId)

    // Lifecycle
    case appBecameActive
    case appResignedActive
    case notificationClicked(tabId: TabId, paneId: PaneId?)
    case confirmTerminate
    case cancelTerminate
    case terminate

    // View
    case splitRatioChanged(splitId: SplitId, ratio: CGFloat)
}
