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

/// One preferences control's new value. Naming every control in one payload
/// lets a single `.prefSet` reducer arm hold the sole "only while the panel is
/// open" guard, instead of repeating it once per field.
enum PreferenceEdit {
    case alertClearMode(AlertClearMode)
    case remoteTheme(String)
    case theme(String?)
    // Raw text rather than a number: a half-typed size must survive until save.
    case fontSize(String?)
    case fontFamily(String?)
    case copyOnSelect(Bool)
}

/// Names every model transition the keybinding editor can request.
enum KeybindingPreferenceEdit {
    case selectBrowserAction(KeybindingActionID?)
    case openEditor(KeybindingActionID)
    case closeEditor
    case beginEditorRecording(chordAt: Int?)
    case cancelEditorRecording
    case rejectEditorRecording(KeybindingDiagnostic)
    case recordEditorChord(KeyChord)
    case removeEditorChord(at: Int)
    case makeEditorChordPrimary(at: Int)
    case setEditorEnabled(Bool)
    case resetEditor
    case acceptEditor
    case requestResetAll
    case cancelResetAll
    case confirmResetAll
}

enum Msg {
    // User actions
    case createTab(inGroupId: GroupId, position: TabInsertPosition = .afterSelected, launch: LaunchSpec? = nil, background: Bool = false)
    case createTabInSelectedGroup(position: TabInsertPosition = .afterSelected, launch: LaunchSpec? = nil, background: Bool = false)
    case selectTab(id: TabId)
    case requestCloseTab(id: TabId)
    case requestCloseTabs(ids: [TabId])
    case splitPane(paneId: PaneId, direction: SplitNodeModel.Direction, launch: LaunchSpec? = nil, background: Bool = false)
    case splitFocusedPane(direction: SplitNodeModel.Direction, launch: LaunchSpec? = nil, background: Bool = false)
    case closePane(paneId: PaneId)
    case requestCloseOtherPanes(paneId: PaneId)
    case focusDirection(direction: SplitNodeModel.Direction, side: SplitNodeModel.Side)
    case createGroup(name: String, launch: LaunchSpec? = nil, background: Bool = false)
    case createGroupInteractively(name: String)
    case requestDeleteGroup(id: GroupId)
    case deleteGroup(id: GroupId, moveTabs: Bool)
    case renameGroup(id: GroupId, name: String)
    case moveTabs(tabIds: [TabId], toGroupId: GroupId, atIndex: Int)
    case extractTabsToNewGroup(tabIds: [TabId], groupName: String)
    case extractTabsToNewGroupInteractively(tabIds: [TabId], groupName: String)
    case reorderGroup(groupId: GroupId, toIndex: Int)
    case toggleGroupCollapse(groupId: GroupId)
    case selectAdjacentTab(direction: TabDirection)
    case paneBecameFirstResponder(paneId: PaneId)
    case searchFieldBecameFirstResponder(paneId: PaneId)
    // nil paneId = act on the selected tab (menubar path); non-nil = act on the
    // pane's own tab, so a stale context menu still targets the pane it was built for.
    case toggleZoomPane(paneId: PaneId?)
    case movePane(source: PaneId, target: PaneId, intent: PaneDropIntent)
    case movePaneToTab(paneId: PaneId, targetTabId: TabId)
    case movePaneToNewTab(paneId: PaneId, inGroupId: GroupId, atIndex: Int)
    case setTabColors(tabIds: [TabId], color: TabColor?)
    case requestSetTabColors(tabIds: [TabId], requested: TabColor?)
    case clearCustomTitles(tabIds: [TabId])
    case clearAlertsForTabs(tabIds: [TabId])
    case setPaneTheme(paneId: PaneId, themeName: String?)
    case toggleThemeBrowser
    // Font-size zoom for one pane. nil paneId = the selected tab's focused pane
    // (menubar path), matching .toggleZoomPane.
    case adjustPaneFontSize(paneId: PaneId?, steps: Int)
    case resetPaneFontSize(paneId: PaneId?)
    // The only two writers of a pane's grid override: a client claims a grid,
    // and a clear returns the pane to its slot-derived size. The clear serves
    // both the fit request and the Mac take-back gesture, whose nil paneId
    // means the selected tab's focused pane.
    case setPaneGridOverride(paneId: PaneId, grid: PaneGridOverride)
    case clearPaneGridOverride(paneId: PaneId?)
    case renameTab(id: TabId, name: String?)
    // The one way an inline sidebar rename begins. Every writer -- the menu
    // commands, a double-click on a row, and the group-creating messages --
    // sends it, so the model is a truthful record of the open edit session and
    // the reconcile pass stays the only thing that opens an editor.
    case beginSidebarRename(target: RenameTarget)
    // Names the session that ended, so an end arriving after a successor rename
    // already opened cannot retract it -- including a successor editing the
    // same row.
    case sidebarRenameEnded(session: RenameSessionId)

    // IPC
    case ipcRequest(reqId: UUID, caller: IpcCallerIdentity, request: IpcRequest)
    case ipcRequestDecodeFailed(reqId: UUID, error: IpcRequestDecodeError)
    case autosplitResolved(
        reqId: UUID,
        caller: IpcCallerIdentity,
        tabId: TabId,
        resolution: AutosplitResolution?,
        launch: LaunchSpec?,
        background: Bool
    )

    // Internal confirmed close -- do not send from UI directly.
    case closeTab(id: TabId)

    // User-visible confirmation responses
    case answerConfirmation(id: ConfirmationId, answer: ConfirmationAnswer)

    // User-visible notices
    case noticeReported(NoticeSubject)
    case noticeAnswered(id: NoticeId, answer: NoticeAnswer)

    // Whole-model restore still enters through the reducer so every normalizer applies.
    case restoreSession(AppModel)

    // Export
    case exportState

    // Terminal session callbacks
    case sessionReport(sessionId: SessionId, report: SessionReport)
    case sessionBell(sessionId: SessionId)
    case sessionNotification(sessionId: SessionId, title: String, body: String)
    case sessionEnded(sessionId: SessionId)
    case sessionCreationFailed(sessionId: SessionId)
    case sessionProcessStarted(sessionId: SessionId)
    case sessionProcessExited(sessionId: SessionId)
    case inputSubmissionCompleted(id: InputSubmissionId, result: InputSubmissionResult)
    case launchInputCompleted(sessionId: SessionId, result: InputSubmissionResult)

    // Alerts
    case markAllAlertsRead
    case toggleAlertsPopover
    case alertsPopoverClosed
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

    // Tailnet listener (launch-frozen, published by the IPC server)
    // The server authors this value and sends it on every transition, including the
    // one a retry produces long after launch. The core stores it and never derives
    // one of its own, so every surface reporting it reports the same thing.
    case tailnetStatusChanged(DanTermTailnetStatus)

    // Preferences panel
    // Machine and bundle catalogs ride in on open because the pure core cannot
    // query CoreText or read packaged theme resources. Each is one snapshot for
    // the lifetime of the panel rather than a live query.
    case preferencesOpened(
        installedFontFamilies: [String] = [],
        availableThemeNames: [String] = []
    )
    case preferencesClosed
    case prefSet(PreferenceEdit)
    case prefKeybinding(KeybindingPreferenceEdit)
    case prefSelectSection(PreferencesSection)
    case prefKeybindingSearchChanged(String)
    case prefSave

    // Lifecycle
    case appBecameActive
    case appResignedActive
    case requestQuit
    case terminate
    case runtimeWillShutdown

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
    // Opening search is not among them -- `.startSearch` writes that state itself.
    case searchTotalReported(paneId: PaneId, total: Int?)
    case searchSelectionReported(paneId: PaneId, selected: Int?)

    // TODO
    case toggleTodoPopover(owner: TodoOwner)
    case todoPopoverClosed(owner: TodoOwner)
    case addTodo(owner: TodoOwner, text: String)
    case toggleTodoDone(owner: TodoOwner, todoId: TodoId)
    case setTodoDone(owner: TodoOwner, todoId: TodoId, isDone: Bool)
    case editTodoText(owner: TodoOwner, todoId: TodoId, text: String)
    case deleteTodo(owner: TodoOwner, todoId: TodoId)
    case reorderTodo(owner: TodoOwner, todoId: TodoId, toIndex: Int)
    case clearCompletedTodos(owner: TodoOwner)
    case requestClosePane(paneId: PaneId)

    // Tab-level TODO
    case moveTodo(from: TodoOwner, todoId: TodoId, to: TodoOwner, atIndex: Int)

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
    /// coalesce. A message opts in when its sweep is cosmetic and safe to
    /// throttle to ~13 Hz (title/cwd/
    /// progress, live search match count, background-pane alert badges, the
    /// remote/agent toolbar + per-pane theme a command event clears). update()
    /// still runs immediately, so the model stays current and the final value is
    /// never dropped; only the whole-model view sweep is deferred -- and the
    /// side-effecting commands these emit (such as .sendNotification) still run
    /// inline. The runtime evaluates this
    /// on the pane-scoped message, so command and activity transitions opt in
    /// here while attach/detach transitions stay inline.
    var coalescesReconcile: Bool {
        switch self {
        // Cosmetic chrome a TUI/search updates at 30-60 Hz: the sweep produces a
        // real but throttleable diff (tab title/subtitle, progress, the search
        // overlay's live "N/M" match count).
        case .searchTotalReported, .searchSelectionReported:
            return true
        // Background-pane alert badges. A bell/notify storm (spinner, `printf '\a'`
        // loop, OSC 9 burst) fires one full sweep per event; the alert is inserted
        // into the model inline (badge never lost) and the desktop notification
        // rides an inline .sendNotification, so only the cosmetic badge
        // sweep (reconcileSidebar / reconcileWindowChrome / reconcileFocusBorders /
        // reconcilePaneChrome unread-alert counts) defers.
        case .sessionBell, .sessionNotification:
            return true
        case .sessionReport(_, let report):
            switch report {
            case .title, .cwd, .progress, .commandStarted, .commandEnded,
                 .connectionDeclared, .agentActivityChanged, .userInputDelivered:
                return true
            case .integrationReady, .agentAttached, .agentDetached:
                return false
            }
        default:
            return false
        }
    }
}

/// Pure function: determines what messages doCommandBy should dispatch
/// for Enter (confirm) vs Esc (cancel).
func renameCompletionMessages(
    isConfirm: Bool,
    session: RenameSessionId,
    target: RenameTarget,
    newName: String
) -> [Msg] {
    var msgs: [Msg] = []
    if isConfirm {
        switch target {
        case .tab(let tabId):
            let name: String? = newName.isEmpty ? nil : newName
            msgs.append(.renameTab(id: tabId, name: name))
        case .group(let groupId):
            if !newName.isEmpty {
                msgs.append(.renameGroup(id: groupId, name: newName))
            }
        }
    }
    msgs.append(.sidebarRenameEnded(session: session))
    return msgs
}
