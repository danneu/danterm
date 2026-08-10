// Command: the side effects `update()` returns for `AppRuntime.perform` to execute.
//
// `update()` is pure and returns ONLY commands -- real imperatives / external side
// effects (PTY create/text/key, focus moves, notifications,
// IPC reply/error/read, checkpoint, config persistence, modal confirmations, TODO
// popovers, export). Everything the view *shows* is a projection derived by
// `reconcile()` after every `send()`, so no view-sync/projection case lives here.
// The type name declares that invariant: it was renamed from `Effect` once the last
// projection case was gone, so the compiler now rejects reintroducing one.
import Foundation
import DanTermProtocol

enum Command {
    // Session
    case createSession(paneId: PaneId, cwd: String?, command: String?, launchCommand: String? = nil, waitAfterCommand: Bool = true)
    // Session *destruction* is a projection (reconcileSessionExistence tears down sessions
    // for panes gone from model.allPaneIds), so there is no destroy-session command.
    // The paste path, taken by IPC's top-level `text` field. Delivered through the
    // same safe-paste policy as the clipboard: control bytes stripped, bracketed-paste
    // markers applied when the child asked for them. Deliberately distinct from
    // sendInputText -- an untrusted blob must not be able to fake keystrokes.
    case sendText(paneId: PaneId, text: String)
    // The structured-input path, taken by IPC's `input` array alongside sendInputKey.
    // Delivered raw, with no stripping and no paste brackets, because the caller is
    // scripting a keyboard: vim and htop must see the characters as if typed.
    case sendInputText(paneId: PaneId, text: String)
    // One named/letter key with modifiers, encoded by the terminal's key encoder so
    // arrows, F-keys, C-c, and Esc reach the PTY as real escape sequences.
    case sendInputKey(paneId: PaneId, key: KeyName, mods: KeyMods)

    // Focus
    case focusSession(paneId: PaneId, focused: Bool)
    case makeFirstResponder(paneId: PaneId)

    // View
    // The per-tab SplitContainerViews are derived by reconcileContainers from the model
    // after every send() (Stage 8, eager): showSelectedTab / rebuildTabContainer /
    // removeTabContainer are gone. Sidebar (reloadSidebar / setSidebarSelection /
    // updateSidebarTabRow / updateSidebarGroupRow) is derived by reconcileSidebar (Stage 5),
    // and the window/content title by reconcileWindowChrome (Stage 6).

    // Export
    case exportState(AppModelSnapshot)

    // IPC
    case ipcReply(reqId: UUID, result: JSONValue)
    case ipcError(reqId: UUID, code: Int, message: String)
    case readPaneText(reqId: UUID, paneId: PaneId, lineLimit: Int?)
    case readPaneRowStructure(reqId: UUID, paneId: PaneId)
    case dumpPaneTape(reqId: UUID, paneId: PaneId)
    case followPaneTape(reqId: UUID, paneId: PaneId, fromNow: Bool)
    /// Routes one hook mutation through the live session owner and writes the
    /// IPC reply only after that owner has reduced and projected the event.
    case applyPaneSemanticIpc(reqId: UUID, paneId: PaneId, event: PaneSemanticEvent)

    // System
    // `paneId` is carried for grouping alone: it becomes the banner's thread
    // identifier so a chatty pane stacks into one Notification Center entry
    // instead of one per alert. Click routing still keys off `alertId`.
    case sendNotification(alertId: AlertId, paneId: PaneId, title: String, subtitle: String?, body: String)
    // `uncompletedTodoCount` rolls up the tab's own todos plus every pane's
    // todos in that tab (the same number the chrome's tab-todo badge shows).
    case showCloseTabConfirmation(tabId: TabId, tabTitle: String, paneCount: Int, isLastTab: Bool, uncompletedTodoCount: Int)
    case showCloseTabsConfirmation(tabIds: [TabId], tabCount: Int, totalPaneCount: Int, totalUncompletedTodos: Int, isQuit: Bool)
    case terminate
    case activateApp
    case dismissAlertsPopover
    // The dock + toolbar-bell unread badges are derived by reconcileWindowChrome (Stage 6).

    // Config persistence
    case saveDanTermConfig(DanTermConfig)

    // Persistence — triggers a debounced write of the model snapshot to disk.
    // Returned by state-mutating update() branches so the recovery file stays current.
    case scheduleCheckpoint

    // Search
    case sendStartSearch(paneId: PaneId)
    case focusSearchField(paneId: PaneId)
    case sendSearchNeedle(paneId: PaneId, needle: String)
    case sendSearchNavigate(paneId: PaneId, direction: SearchDirection)
    case sendEndSearch(paneId: PaneId)

    // TODO
    case showTodoPopover(paneId: PaneId)
    case dismissTodoPopover
    case showTodoPopoverForTab(tabId: TabId)
    case dismissTodoPopoverForTab
    case showClosePaneConfirmation(paneId: PaneId, uncompletedCount: Int)
    // The MRU tab switcher overlay is derived by reconcileSwitcher from model.mruCycle
    // after every send() (Stage 7); showSwitcherOverlay/hideSwitcherOverlay are gone.
}

extension Command {
    /// Whether this command must run *after* `reconcile()` because it targets a view
    /// the reconciler creates. Exactly `makeFirstResponder` and `focusSearchField`:
    /// `reconcileContainers` mounts a pane's `TerminalView` during reconcile (Stage 8),
    /// and `reconcilePaneChrome` builds the search field, so neither exists until after
    /// reconcile. `focusSession` stays pre-reconcile: it acts on an already-existing
    /// session, and deferring it is actively wrong -- a foreground createTab create-failure
    /// re-enters send() and re-focuses the fallback, which a deferred focusSession(old,false)
    /// would then defocus. (makeFirstResponder/focusSearchField safely no-op in that failure
    /// path: their pane was removed, so sessions[id] is nil.) Exhaustive with no `default`
    /// so a new case cannot be added without classifying it.
    var isPostReconcile: Bool {
        switch self {
        case .makeFirstResponder, .focusSearchField:
            return true
        case .createSession, .sendText, .sendInputText, .sendInputKey,
             .focusSession, .exportState, .ipcReply, .ipcError,
             .readPaneText, .readPaneRowStructure, .dumpPaneTape, .followPaneTape,
             .applyPaneSemanticIpc,
             .sendNotification,
             .showCloseTabConfirmation, .showCloseTabsConfirmation, .terminate, .activateApp,
             .dismissAlertsPopover,
             .saveDanTermConfig, .scheduleCheckpoint, .sendStartSearch,
             .sendSearchNeedle, .sendSearchNavigate, .sendEndSearch, .showTodoPopover,
             .dismissTodoPopover, .showTodoPopoverForTab, .dismissTodoPopoverForTab,
             .showClosePaneConfirmation:
            return false
        }
    }
}
