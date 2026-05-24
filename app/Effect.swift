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
    case refreshPaneBorder(paneId: PaneId)
    case reloadSidebar
    case setSidebarSelection(tabId: TabId)
    case updateSidebarTabRow(tabId: TabId)
    case updateSidebarGroupRow(groupId: GroupId)
    case setWindowTitle(String)

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
    case updateToolbarBellBadge(Int)
    case updateDockBadge(Int)

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
    case showSearchOverlay(paneId: PaneId)
    case hideSearchOverlay(paneId: PaneId)
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
    case refreshPaneToolbar(paneId: PaneId)

    // MRU tab switcher overlay
    case showSwitcherOverlay   // ensure panel is visible and redrawn from model
    case hideSwitcherOverlay   // order panel out
}
