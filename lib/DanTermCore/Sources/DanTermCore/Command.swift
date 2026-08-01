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
    // Surface
    case createSurface(paneId: PaneId, cwd: String?, command: String?, launchCommand: String? = nil, waitAfterCommand: Bool = true)
    // Surface *destruction* is a projection (reconcileSurfaceExistence tears down surfaces
    // for panes gone from model.allPaneIds), so there is no destroySurface command.
    // Paste path (ghostty_surface_text). Strips control bytes and applies
    // bracketed-paste mode if active. Used by direct IPC callers that send
    // the top-level `text` field.
    case sendText(paneId: PaneId, text: String)
    // Structured-input text run, dispatched as a key event with keycode=0
    // through ghostty_surface_key. Bypasses paste-stripping and bracketed
    // paste so vim/htop see characters as if typed.
    case sendInputText(paneId: PaneId, text: String)
    // Single named/letter key event with optional modifiers, dispatched
    // through ghostty_surface_key so escape sequences (arrows, F-keys, C-c,
    // Esc) actually reach the PTY.
    case sendInputKey(paneId: PaneId, key: KeyName, mods: KeyMods)

    // Focus
    case focusSurface(paneId: PaneId, focused: Bool)
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
    case dumpPaneTape(reqId: UUID, paneId: PaneId)

    // System
    case sendNotification(alertId: AlertId, title: String, body: String)
    // `uncompletedTodoCount` rolls up the tab's own todos plus every pane's
    // todos in that tab (the same number the chrome's tab-todo badge shows).
    case showCloseTabConfirmation(tabId: TabId, tabTitle: String, paneCount: Int, isLastTab: Bool, uncompletedTodoCount: Int)
    case showCloseTabsConfirmation(tabIds: [TabId], tabCount: Int, totalPaneCount: Int, totalUncompletedTodos: Int, isQuit: Bool)
    case terminate
    case activateApp
    case setAppFocus(Bool)
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
    /// reconcile. `focusSurface` stays pre-reconcile: it acts on an already-existing
    /// surface, and deferring it is actively wrong -- a foreground createTab create-failure
    /// re-enters send() and re-focuses the fallback, which a deferred focusSurface(old,false)
    /// would then defocus. (makeFirstResponder/focusSearchField safely no-op in that failure
    /// path: their pane was removed, so surfaces[id] is nil.) Exhaustive with no `default`
    /// so a new case cannot be added without classifying it.
    var isPostReconcile: Bool {
        switch self {
        case .makeFirstResponder, .focusSearchField:
            return true
        case .createSurface, .sendText, .sendInputText, .sendInputKey,
             .focusSurface, .exportState, .ipcReply, .ipcError,
             .readPaneText, .dumpPaneTape, .sendNotification,
             .showCloseTabConfirmation, .showCloseTabsConfirmation, .terminate, .activateApp,
             .setAppFocus, .dismissAlertsPopover,
             .saveDanTermConfig, .scheduleCheckpoint, .sendStartSearch,
             .sendSearchNeedle, .sendSearchNavigate, .sendEndSearch, .showTodoPopover,
             .dismissTodoPopover, .showTodoPopoverForTab, .dismissTodoPopoverForTab,
             .showClosePaneConfirmation:
            return false
        }
    }
}
