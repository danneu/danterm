// Message definitions for DanTerm's unidirectional update loop.
import Foundation
import DanTermProtocol

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

enum MruDirection {
    case older  // step toward less-recently-used (advance cursorIndex)
    case newer  // step toward more-recently-used (retreat cursorIndex)
}

// Where a newly-created tab lands within its target group.
// `afterSelected` keeps the new tab next to the current one (Cmd-T).
// `atGroupEnd` always appends, regardless of selection (Cmd-Shift-T).
// `afterTab` inserts immediately after a specific tab in the target group.
enum TabInsertPosition {
    case afterSelected
    case atGroupEnd
    case afterTab(TabId)
}

enum TodoSource: Equatable {
    case tab(TabId)
    case pane(PaneId)
}

enum TodoDestination: Equatable {
    case tab(TabId)
    case pane(PaneId)
}

enum Msg {
    // User actions
    case createTab(inGroupId: GroupId?, position: TabInsertPosition = .afterSelected, launch: LaunchSpec? = nil, background: Bool = false)
    case selectTab(id: TabId)
    case requestCloseTab(id: TabId)
    case requestCloseTabs(ids: [TabId])
    case splitPane(paneId: PaneId? = nil, direction: SplitNodeModel.Direction, launch: LaunchSpec? = nil, background: Bool = false)
    case closePane(paneId: PaneId)
    case focusDirection(direction: SplitNodeModel.Direction, side: SplitNodeModel.Side)
    case createGroup(name: String, launch: LaunchSpec? = nil)
    case deleteGroup(id: GroupId, moveTabs: Bool)
    case renameGroup(id: GroupId, name: String)
    case moveTabs(tabIds: [TabId], toGroupId: GroupId, atIndex: Int)
    case extractTabsToNewGroup(tabIds: [TabId], groupName: String)
    case reorderGroup(groupId: GroupId, toIndex: Int)
    case toggleGroupCollapse(groupId: GroupId)
    case selectAdjacentTab(direction: TabDirection)
    case paneBecameFirstResponder(paneId: PaneId)
    case toggleZoomPane
    case movePane(source: PaneId, target: PaneId, intent: PaneDropIntent)
    case movePaneToTab(paneId: PaneId, targetTabId: TabId)
    case movePaneToNewTab(paneId: PaneId, inGroupId: GroupId, atIndex: Int)
    case setTabColors(tabIds: [TabId], color: TabColor?)
    case clearCustomTitles(tabIds: [TabId])
    case clearAlertsForTabs(tabIds: [TabId])
    case setPaneTheme(paneId: PaneId, themeName: String?)
    case renameTab(id: TabId, name: String?)
    case sidebarRenameEnded

    // IPC
    case ipcRequest(reqId: UUID, method: String, params: JSONValue, context: IpcRequestContext)

    // Internal (confirmed close — do not send from UI directly)
    case closeTab(id: TabId)
    case confirmCloseTab(id: TabId)
    case cancelCloseTab
    case confirmCloseTabs(ids: [TabId])
    case cancelCloseTabs

    // Command tracking
    case commandStarted(paneId: PaneId, command: String)
    case commandEnded(paneId: PaneId)

    // Remote detection
    case remoteSessionStarted(paneId: PaneId)
    case remoteSessionReported(paneId: PaneId, session: RemoteSession)

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

    // Config (external reload)
    case configLoaded(DanTermConfig)
    case ghosttyConfigReloaded

    // Preferences panel
    case preferencesOpened(ghostty: GhosttyPrefs)
    case preferencesClosed
    case prefSetAlertClearMode(AlertClearMode)
    case prefSetRemoteTheme(String)
    case prefSetTheme(String?)
    case prefSetFontSize(String?)
    case prefResetAlertClearMode
    case prefResetRemoteTheme
    case prefResetTheme
    case prefResetFontSize
    case prefSave
    case ghosttyPrefsRefreshed(GhosttyPrefs)

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

    // TODO
    case toggleTodoPopover(paneId: PaneId)
    case todoPopoverClosed(paneId: PaneId)
    case addTodo(paneId: PaneId, text: String)
    case toggleTodoDone(paneId: PaneId, todoId: UUID)
    case setTodoDone(paneId: PaneId, todoId: UUID, isDone: Bool)
    case editTodoText(paneId: PaneId, todoId: UUID, text: String)
    case deleteTodo(paneId: PaneId, todoId: UUID)
    case reorderTodo(paneId: PaneId, todoId: UUID, toIndex: Int)
    case clearCompletedTodos(paneId: PaneId)
    case requestClosePane(paneId: PaneId)

    // Tab-level TODO
    case toggleTodoPopoverForTab(tabId: TabId)
    case todoPopoverForTabClosed(tabId: TabId)
    case addTabTodo(tabId: TabId, text: String)
    case toggleTabTodoDone(tabId: TabId, todoId: UUID)
    case setTabTodoDone(tabId: TabId, todoId: UUID, isDone: Bool)
    case editTabTodoText(tabId: TabId, todoId: UUID, text: String)
    case deleteTabTodo(tabId: TabId, todoId: UUID)
    case reorderTabTodo(tabId: TabId, todoId: UUID, toIndex: Int)
    case moveTodo(from: TodoSource, todoId: UUID, to: TodoDestination, atIndex: Int)
    case clearCompletedTabTodos(tabId: TabId)

    // MRU tab switcher
    case mruCycleStepped(direction: MruDirection)  // hold path: tapped cmd-shift-i/-o
    case mruCycleCommitted                          // hold path: released cmd or shift
    case mruCycleCanceled                           // pressed Esc while cycling
    case mruCycleOneShot(direction: MruDirection)  // menu fallback: step + commit atomically

    // Tab jump mode
    case jumpModeActivated(visibleTabs: [TabId])
    case jumpModeKeyPressed(char: Character)
    case jumpModeCanceled
}

extension Msg {
    /// Whether this message is eligible to defer its reconcile() sweep so bursts
    /// coalesce. A message opts in when its sweep is either empty (split-ratio:
    /// ContainerShape drops ratios) or merely cosmetic and safe to throttle to
    /// ~13 Hz (title/cwd/progress, live search match count). update() still runs
    /// immediately, so the model stays current and the final value is never
    /// dropped; only the whole-model view sweep is deferred. The runtime evaluates
    /// this on the translated message, keeping title-channel IPC events on the
    /// inline path. Eligibility is necessary but not sufficient: reconcileDecision
    /// still forces an inline reconcile when update() emitted a post-reconcile
    /// command, so opting a message in here is always safe.
    var coalescesReconcile: Bool {
        switch self {
        // Cosmetic chrome a TUI/search updates at 30-60 Hz: the sweep produces a
        // real but throttleable diff (tab title/subtitle, progress, the search
        // overlay's live "N/M" match count).
        case .surfaceTitle, .surfaceCwd, .surfaceProgress,
             .ghosttySearchTotal, .ghosttySearchSelected:
            return true
        // Window/divider live-resize fires this every tick, but ContainerShape
        // drops split ratios (see ReconcileTests "split ratio is excluded"), so
        // the sweep is an empty diff -- pure waste; defer it.
        case .splitRatioChanged:
            return true
        default:
            return false
        }
    }
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
