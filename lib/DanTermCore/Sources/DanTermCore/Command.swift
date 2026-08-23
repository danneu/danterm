// Command: the side effects `update()` returns for `AppRuntime.perform` to execute.
//
// `update()` is pure and returns ONLY commands -- real imperatives / external side
// effects (PTY create/text/key, focus moves, notifications,
// IPC reply/error/read, checkpoint, config persistence, export). Everything the view
// *shows* is a projection derived by
// `reconcile()` after every `send()`, so no view-sync/projection case lives here.
// The type name declares that invariant: it was renamed from `Effect` once the last
// projection case was gone, so the compiler now rejects reintroducing one.
import Foundation
import DanTermProtocol

/// Preserves the terminal meaning of one input item across pure dispatch and AppKit routing.
enum PaneInputItem: Equatable {
    case paste(String)
    case text(String)
    case key(KeyName, modifiers: KeyMods)
    case wheel(InputWheelDirection, column: Int, row: Int)
}

enum Command {
    // Session
    case createSession(sessionId: SessionId, paneId: PaneId, cwd: String?, command: String?, launchCommand: String? = nil)
    // Session *destruction* is a projection (reconcileSessionExistence tears down sessions
    // for panes gone from model.allPaneIds), so there is no destroy-session command.
    // Every input command carries `waitGeneration`: the agent wait the pane's session
    // held when `update()` dispatched the command, or nil when it held none. Scripted
    // input ends a wait exactly the way typing does, and the snapshot is taken here --
    // in the same pure dispatch that read the model -- so the value cannot age between
    // the read and the write.
    case submitPaneInput(
        paneId: PaneId,
        input: PaneInputItem,
        submissionId: InputSubmissionId,
        waitGeneration: AgentWaitGeneration? = nil
    )

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
    /// Asks AppKit for one tab's arranged geometry before pure dispatch chooses a split.
    case resolveAutosplit(
        reqId: UUID,
        caller: IpcCallerIdentity,
        tabId: TabId,
        launch: LaunchSpec?,
        background: Bool
    )
    case readPaneText(reqId: UUID, paneId: PaneId, lineLimit: Int?)
    case readPaneRowStructure(reqId: UUID, paneId: PaneId)
    case streamPaneTape(
        reqId: UUID,
        paneId: PaneId,
        capture: PaneTapeCaptureMode,
        start: PaneTapeStartPosition,
        policy: PaneTapeSyncPolicy
    )
    /// Answers a roster subscribe and registers the connection in one command. Both
    /// halves need the request's socket, and the reply consumes it, so splitting them
    /// into a reply plus a subscribe would leave the second half nothing to hold.
    /// The roster travels with the command because the core is what projects it.
    case subscribeRoster(reqId: UUID, roster: PaneRoster)
    // System
    // `paneId` is carried for grouping alone: it becomes the banner's thread
    // identifier so a chatty pane stacks into one Notification Center entry
    // instead of one per alert. Click routing still keys off `alertId`.
    // The title and subtitle are DanTerm's own derived presentation and land in
    // one-line notification slots; the body is the sender's text, kept verbatim.
    case sendNotification(alertId: AlertId, paneId: PaneId, title: DisplayLine, subtitle: DisplayLine?, body: String)
    case terminate
    case activateApp
    /// Resolves the launch recovery decision outside the answering send frame.
    case resolveLaunchRestore(restore: Bool)
    /// Replaces the live pane-host table with the table staged before restore dispatch.
    case installStagedRestoreSession
    // The dock + toolbar-bell unread badges are derived by reconcileWindowChrome (Stage 6).

    // Config persistence
    case saveDanTermConfig(DanTermConfig)

    // Search
    case sendSearchNeedle(paneId: PaneId, needle: String)
    case sendSearchNavigate(paneId: PaneId, direction: SearchDirection)
    case sendEndSearch(paneId: PaneId)

    // The MRU tab switcher overlay is derived by reconcileSwitcher from model.mruCycle
    // after every send() (Stage 7); showSwitcherOverlay/hideSwitcherOverlay are gone.
}
