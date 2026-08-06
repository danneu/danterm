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
    // nil paneId = act on the selected tab (menubar path); non-nil = act on the
    // pane's own tab, so a stale context menu still targets the pane it was built for.
    case toggleZoomPane(paneId: PaneId?)
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

    // Terminal session callbacks
    case sessionTitle(paneId: PaneId, title: String)
    case sessionCwd(paneId: PaneId, cwd: String?)
    case sessionBell(paneId: PaneId)
    case desktopNotification(paneId: PaneId, title: String, body: String)
    case sessionProgress(paneId: PaneId, state: ProgressState?)
    case sessionClosed(paneId: PaneId)
    case sessionCreationFailed(paneId: PaneId)

    // Alerts
    case markAlertRead(alertId: AlertId)
    case markAllAlertsRead
    case activateAlert(alertId: AlertId)
    case goToMostRecentAlertPane
    case setShowAllAlerts(Bool)
    case clearAlertsForPane(paneId: PaneId)

    // Config (launch and external reload)
    // Carries the font-family verdict because the core cannot compute it: the
    // impure caller resolves the name against the installed families and injects
    // the answer, so config and resolution can never be applied separately.
    case configLoaded(DanTermConfig, resolvedFontFamily: String?)
    // The resolution half on its own, for the save path: prefSave has already
    // committed the config it wrote, so only the verdict it could not compute is
    // missing. A full configLoaded would also reset the draft, discarding text
    // the panel deliberately keeps on screen (an invalid font size).
    case fontFamilyResolved(String?)

    // Preferences panel
    // The installed-family catalog is injected for the same reason the font
    // resolution is: the syntax-only core may not ask CoreText which families exist.
    // It rides in on open so the picker's choices are a snapshot taken when the panel
    // appeared, not a live query.
    case preferencesOpened(installedFontFamilies: [String] = [])
    case preferencesClosed
    case prefSetAlertClearMode(AlertClearMode)
    case prefSetRemoteTheme(String)
    case prefSetTheme(String?)
    case prefSetFontSize(String?)
    case prefSetFontFamily(String?)
    case prefResetAlertClearMode
    case prefResetRemoteTheme
    case prefResetTheme
    case prefResetFontSize
    case prefResetFontFamily
    case prefSave

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
    /// Cmd-G / Cmd-Shift-G: the menu bar has no pane in hand, so the focused pane is
    /// resolved in `update` the way `.startSearch` resolves it.
    case navigateFocusedSearch(direction: SearchDirection)
    case endSearch(paneId: PaneId)
    // Backend search callbacks: reported by whichever terminal engine owns the pane,
    // never crossing the C boundary, so they carry no backend in their names.
    case searchStarted(paneId: PaneId, needle: String)
    case searchTotalReported(paneId: PaneId, total: Int?)
    case searchSelectionReported(paneId: PaneId, selected: Int?)

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
    /// ContainerShape drops ratios; commandStarted: no projection reads
    /// lastCommand) or merely cosmetic and safe to throttle to ~13 Hz (title/cwd/
    /// progress, live search match count, background-pane alert badges, the
    /// remote/agent toolbar + per-pane theme a command event clears). update()
    /// still runs immediately, so the model stays current and the final value is
    /// never dropped; only the whole-model view sweep is deferred -- and the
    /// side-effecting commands these emit (.sendNotification, .scheduleCheckpoint)
    /// are not post-reconcile, so they still run inline. The runtime evaluates this
    /// on the pane-scoped message, so commandStarted/commandEnded opt in here;
    /// remoteSession start/report events stay inline. Eligibility is
    /// necessary but not sufficient: reconcileDecision still forces an inline
    /// reconcile when update() emitted a post-reconcile command, so opting a message
    /// in here is always safe.
    var coalescesReconcile: Bool {
        switch self {
        // Cosmetic chrome a TUI/search updates at 30-60 Hz: the sweep produces a
        // real but throttleable diff (tab title/subtitle, progress, the search
        // overlay's live "N/M" match count).
        case .sessionTitle, .sessionCwd, .sessionProgress,
             .searchTotalReported, .searchSelectionReported:
            return true
        // Window/divider live-resize fires this every tick, but ContainerShape
        // drops split ratios (see ReconcileTests "split ratio is excluded"), so
        // the sweep is an empty diff -- pure waste; defer it.
        case .splitRatioChanged:
            return true
        // Background-pane alert badges. A bell/notify storm (spinner, `printf '\a'`
        // loop, OSC 9 burst) fires one full sweep per event; the alert is inserted
        // into the model inline (badge never lost) and the desktop notification
        // rides a non-post-reconcile .sendNotification, so only the cosmetic badge
        // sweep (reconcileSidebar / reconcileWindowChrome / reconcileFocusBorders /
        // reconcilePaneChrome unread-alert counts) defers.
        case .sessionBell, .desktopNotification:
            return true
        // Shell-integration command events, one per prompt in a command loop.
        // commandStarted only sets pane.lastCommand, which no projection reads --
        // an empty view diff; commandEnded clears agent/remote/theme, which feed
        // only the pane toolbar (desiredPaneToolbar) and per-pane theme
        // (desiredPaneConfig) -- cosmetic, never ContainerShape.
        case .commandStarted, .commandEnded:
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
