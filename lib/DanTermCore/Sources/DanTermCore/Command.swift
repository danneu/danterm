// Command: the side effects `update()` returns for `AppRuntime.perform` to execute.
//
// `update()` is pure and returns ONLY commands -- real imperatives / external side
// effects (PTY create/text/key, focus moves, notifications,
// IPC reply/error/read, checkpoint, config persistence, TODO
// popovers, export). Everything the view *shows* is a projection derived by
// `reconcile()` after every `send()`, so no view-sync/projection case lives here.
// The type name declares that invariant: it was renamed from `Effect` once the last
// projection case was gone, so the compiler now rejects reintroducing one.
import Foundation
import DanTermProtocol

enum Command {
    // Session
    case createSession(sessionId: SessionId, paneId: PaneId, cwd: String?, command: String?, launchCommand: String? = nil)
    // Session *destruction* is a projection (reconcileSessionExistence tears down sessions
    // for panes gone from model.allPaneIds), so there is no destroy-session command.
    // The paste path, taken by IPC's top-level `text` field. Delivered through the
    // same safe-paste policy as the clipboard: control bytes stripped, bracketed-paste
    // markers applied when the child asked for them. Deliberately distinct from
    // sendInputText -- an untrusted blob must not be able to fake keystrokes.
    case sendText(paneId: PaneId, text: String, submissionId: InputSubmissionId? = nil)
    // The structured-input path, taken by IPC's `input` array alongside sendInputKey.
    // Delivered raw, with no stripping and no paste brackets, because the caller is
    // scripting a keyboard: vim and htop must see the characters as if typed.
    case sendInputText(paneId: PaneId, text: String, submissionId: InputSubmissionId? = nil)
    // One named/letter key with modifiers, encoded by the terminal's key encoder so
    // arrows, F-keys, C-c, and Esc reach the PTY as real escape sequences.
    case sendInputKey(paneId: PaneId, key: KeyName, mods: KeyMods, submissionId: InputSubmissionId? = nil)

    // Focus
    case focusSession(paneId: PaneId, focused: Bool)

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
    case readDoctorPermissions(reqId: UUID)
    case readFocusInfo(reqId: UUID)
    case readPaneText(reqId: UUID, paneId: PaneId, lineLimit: Int?)
    case readPaneRowStructure(reqId: UUID, paneId: PaneId)
    case dumpPaneTape(reqId: UUID, paneId: PaneId)
    case followPaneTape(reqId: UUID, paneId: PaneId, fromNow: Bool)
    // System
    // `paneId` is carried for grouping alone: it becomes the banner's thread
    // identifier so a chatty pane stacks into one Notification Center entry
    // instead of one per alert. Click routing still keys off `alertId`.
    // The title and subtitle are DanTerm's own derived presentation and land in
    // one-line notification slots; the body is the sender's text, kept verbatim.
    case sendNotification(alertId: AlertId, paneId: PaneId, title: DisplayLine, subtitle: DisplayLine?, body: String)
    case terminate
    case activateApp
    case dismissAlertsPopover
    // The dock + toolbar-bell unread badges are derived by reconcileWindowChrome (Stage 6).

    // Config persistence
    case saveDanTermConfig(DanTermConfig)

    // Search
    case sendStartSearch(paneId: PaneId)
    case sendSearchNeedle(paneId: PaneId, needle: String)
    case sendSearchNavigate(paneId: PaneId, direction: SearchDirection)
    case sendEndSearch(paneId: PaneId)

    // TODO
    case showTodoPopover(owner: TodoOwner)
    case dismissTodoPopover(owner: TodoOwner)
    // The MRU tab switcher overlay is derived by reconcileSwitcher from model.mruCycle
    // after every send() (Stage 7); showSwitcherOverlay/hideSwitcherOverlay are gone.
}
