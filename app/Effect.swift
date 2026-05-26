import Foundation
import DanTermProtocol

enum Effect {
    // Surface
    case createSurface(paneId: PaneId, cwd: String?, command: String?, launchCommand: String? = nil, waitAfterCommand: Bool = true)
    case destroySurface(paneId: PaneId)
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
    case showSelectedTab
    case rebuildTabContainer(tabId: TabId)
    case removeTabContainer(tabId: TabId)
    // Sidebar (reloadSidebar / setSidebarSelection / updateSidebarTabRow /
    // updateSidebarGroupRow) is now derived by reconcileSidebar from the model after
    // every send(); the granular NSOutlineView diff replaced these effects in Stage 5.
    // The window/content title is likewise derived by reconcileWindowChrome (Stage 6),
    // so setWindowTitle is gone.

    // Export
    case exportState(AppModelSnapshot)

    // IPC
    case ipcReply(reqId: UUID, result: JSONValue)
    case ipcError(reqId: UUID, code: Int, message: String)
    case readPaneText(reqId: UUID, paneId: PaneId, lineLimit: Int?)

    // System
    case sendNotification(alertId: AlertId, title: String, body: String)
    case showTerminateConfirmation(paneCount: Int)
    // `uncompletedTodoCount` rolls up the tab's own todos plus every pane's
    // todos in that tab (the same number the chrome's tab-todo badge shows).
    case showCloseTabConfirmation(tabId: TabId, tabTitle: String, paneCount: Int, isLastTab: Bool, uncompletedTodoCount: Int)
    case showCloseTabsConfirmation(tabIds: [TabId], tabCount: Int, totalPaneCount: Int, totalUncompletedTodos: Int, isQuit: Bool)
    case terminate
    case activateApp
    case setAppFocus(Bool)
    case dismissAlertsPopover
    // The dock + toolbar-bell unread badges are derived by reconcileWindowChrome (Stage 6).

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

extension Effect {
    /// Whether this command must run *after* `reconcile()` because it targets a view
    /// the reconciler creates. In Stage 4 only `focusSearchField` qualifies: it focuses
    /// the search field that `reconcilePaneChrome` builds, which does not exist until
    /// after reconcile. `makeFirstResponder` stays pre-reconcile because its
    /// `TerminalView` is still created by the effect-built container path (Stage 8 flips
    /// it once `reconcileContainers` mounts the view); `focusSurface` is pre-reconcile
    /// because it acts on an already-existing surface and deferring it is actively wrong.
    /// Exhaustive with no `default` so a new case cannot be added without classifying it.
    var isPostReconcile: Bool {
        switch self {
        case .focusSearchField:
            return true
        case .createSurface, .destroySurface, .sendText, .sendInputText, .sendInputKey,
             .focusSurface, .makeFirstResponder, .showSelectedTab, .rebuildTabContainer,
             .removeTabContainer, .exportState, .ipcReply, .ipcError,
             .readPaneText, .sendNotification, .showTerminateConfirmation,
             .showCloseTabConfirmation, .showCloseTabsConfirmation, .terminate, .activateApp,
             .setAppFocus, .dismissAlertsPopover,
             .applyPaneTheme, .saveDanTermConfigKey, .removeDanTermConfigKey,
             .reloadGhosttyConfig, .syncPreferencesPanel, .scheduleCheckpoint, .sendStartSearch,
             .sendSearchNeedle, .sendSearchNavigate, .sendEndSearch, .showTodoPopover,
             .dismissTodoPopover, .showTodoPopoverForTab, .dismissTodoPopoverForTab,
             .showClosePaneConfirmation:
            return false
        }
    }
}
