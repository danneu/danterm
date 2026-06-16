// Runtime bridge that performs update commands and synchronizes AppKit/Ghostty views.
import Cocoa
import DanTermProtocol
import GhosttyKit
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

// App runtime owns the mutable app model, performs the commands emitted by the
// pure update function, and bridges model changes into AppKit/Ghostty objects.
@MainActor
class AppRuntime {
    private struct StagedRestoreSession {
        let model: AppModel
        let surfaces: [PaneId: TerminalView]
        let tokenStore: PaneTokenStore
        let replayFiles: [PaneId: URL]
    }

    var model: AppModel
    // Ephemeral view state the reconciler reads as a second input (see ViewLocalState).
    // Today just the inline-rename target, set/cleared by SidebarView's rename paths and
    // read only by reconcileSidebar's rename guard.
    var viewLocalState = ViewLocalState()
    let ghosttyApp: GhosttyApp
    var surfaces: [PaneId: TerminalView] = [:]
    // Last libghostty occlusion value pushed for each live surface.
    // Cleared on teardown because restore/import can reuse pane IDs for fresh surfaces.
    private var surfaceVisibility: [PaneId: Bool] = [:]
    // Per-pass diff caches for the view reconciler (see Reconcile.swift).
    // Reset on teardown so a post-restore reconcile is a clean build.
    var caches = ReconcilerCaches()
    // internal (not private): the cross-file reconcileContainers extension reads/mutates it.
    var tabContainers: [TabId: SplitContainerView] = [:]
    var tokenStore = PaneTokenStore()
    weak var window: NSWindow?
    weak var sidebarView: SidebarView?
    weak var contentArea: NSView?
    weak var chromeView: WindowChromeView?
    var alertsPopover: NSPopover?
    private lazy var alertsPopoverDelegate = AlertsPopoverDelegateAdapter(runtime: self)
    var todoPopover: NSPopover?
    private var todoPopoverDelegate: TodoPopoverDelegateAdapter?
    var tabTodoPopover: NSPopover?
    private var tabTodoPopoverDelegate: TabTodoPopoverDelegateAdapter?
    // internal (not private): the cross-file reconcileThemeBrowser extension reads it.
    var themeBrowserView: ThemeBrowserView?
    // internal (not private): the cross-file reconcilePreferencesPanel extension reads it.
    var preferencesPanel: PreferencesPanel?
    // internal (not private): the cross-file reconcileQuitConfirmation extension reads it.
    var quitConfirmationPanel: QuitConfirmationPanel?
    // internal (not private): the cross-file reconcileSwitcher extension reads it.
    var switcherPanel: SwitcherPanel?
    private var switcherEventMonitor: Any?
    private var dragCoordinator: PaneDragCoordinator?
    private var replayFiles: [PaneId: URL] = [:]
    private static let replayDirectoryName = "danterm-scrollback"
    // Session persistence uses two tiers of checkpoints:
    //   Light  — pure model serialization (no scrollback), written after a 2s debounce
    //            following any state-mutating Msg. Cheap and frequent.
    //   Enriched — model + scrollback text read from live Ghostty surfaces, written on
    //              a 10 min repeating timer and once at clean termination. Expensive but
    //              gives full restore fidelity including terminal history.
    private let checkpointDebouncer = Debouncer(queue: .main)  // trailing debounce for light checkpoints
    private var enrichedCheckpointTimer: DispatchSourceTimer?  // repeating timer for enriched checkpoints
    private var checkpointPending = false                      // true while a debounced write is scheduled
    private var coalescedReconcileTimer: DispatchSourceTimer?   // rate-limited whole-model sweep
    // Serializes checkpoint writes and gives sync flushes one fence for pending async I/O.
    private static let checkpointIOQueue = DispatchQueue(label: "danterm.checkpoint.io", qos: .utility)
    private var searchDebouncers: [PaneId: Debouncer] = [:]
    private var ipcConnections: [UUID: IpcConnection] = [:]
    private var ipcServer: IpcServer?
    private static let checkpointDebounceInterval: TimeInterval = 2.0
    // Matches Ghostty's title coalesce interval: quick enough to feel live, slow
    // enough to avoid flickering chrome under terminal-title spam.
    private static let reconcileCoalesceInterval: TimeInterval = 0.075
    // Slowed from 60s to 10min until the libghostty memory leak is fixed.
    // https://github.com/danneu/danterm/issues/31
    private static let enrichedCheckpointInterval: TimeInterval = 600.0

    init(ghosttyApp: GhosttyApp) {
        self.ghosttyApp = ghosttyApp
        // Empty launch: one group, no tabs/leaves yet (panes live in leaves).
        self.model = AppModel(
            groups: [GroupModel(id: GroupId(rawValue: CoreEnv.live.newId()), name: "General")]
        )
        // Load DanTerm config before any tabs are created
        self.model.config = DanTermConfigParser.loadFromDisk()

        // Build the MRU switcher panel eagerly — pay first-frame cost at
        // launch instead of on every cmd-shift-i. Keep it offscreen until
        // reconcileSwitcher orders it front (mruCycle becomes non-nil).
        self.switcherPanel = SwitcherPanel()

        // Install the local NSEvent monitor that drives ephemeral keyboard modes.
        // It reads model flags to know whether a mode is active, but never mutates
        // the model directly; mutations go through send().
        installSwitcherEventMonitor()

        self.ipcServer = IpcServer(socketPath: controlSocketPath(), runtime: self)
        Task { await self.ipcServer?.start() }
    }

    deinit {
        if let monitor = switcherEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Ephemeral Mode Event Monitor

    private func installSwitcherEventMonitor() {
        switcherEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }

            let mods = self.normalizedSwitcherModifiers(from: event)

            if self.model.jumpMode != nil {
                switch event.type {
                case .keyDown:
                    let character = event.charactersIgnoringModifiers?.lowercased().first
                    let action = classifyJumpInput(
                        kind: .keyDown(keyCode: event.keyCode, character: character),
                        modifiers: mods,
                        jumpActive: true
                    )
                    switch action {
                    case .passthrough:
                        return event
                    case .activate:
                        return nil
                    case .commit(let char):
                        self.send(.jumpModeKeyPressed(char: char))
                        return nil
                    case .cancel:
                        self.send(.jumpModeCanceled)
                        return nil
                    }

                case .flagsChanged:
                    _ = classifyJumpInput(
                        kind: .flagsChanged,
                        modifiers: mods,
                        jumpActive: true
                    )
                    return event

                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    let action = classifyJumpInput(
                        kind: .mouseDown,
                        modifiers: mods,
                        jumpActive: true
                    )
                    if case .cancel = action {
                        return self.handleJumpModeMouseDown(event)
                    }
                    return event

                default:
                    return event
                }
            }

            if event.type == .keyDown {
                let character = event.charactersIgnoringModifiers?.lowercased().first
                let jumpAction = classifyJumpInput(
                    kind: .keyDown(keyCode: event.keyCode, character: character),
                    modifiers: mods,
                    jumpActive: false
                )
                if case .activate = jumpAction {
                    self.enterJumpMode()
                    return nil
                }
            }

            guard event.type == .keyDown || event.type == .flagsChanged else { return event }

            let kind: SwitcherInputKind = (event.type == .keyDown)
                ? .keyDown(keyCode: event.keyCode)
                : .flagsChanged

            let action = classifySwitcherInput(
                kind: kind,
                modifiers: mods,
                cycleActive: self.model.mruCycle != nil
            )

            switch action {
            case .passthrough: return event
            case .stepOlder:   self.send(.mruCycleStepped(direction: .older));  return nil
            case .stepNewer:   self.send(.mruCycleStepped(direction: .newer));  return nil
            case .cancel:      self.send(.mruCycleCanceled);                    return nil
            case .commit:      self.send(.mruCycleCommitted);                   return nil
            }
        }
    }

    private func normalizedSwitcherModifiers(from event: NSEvent) -> SwitcherModifiers {
        var mods: SwitcherModifiers = []
        let raw = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if raw.contains(.command) { mods.insert(.command) }
        if raw.contains(.shift)   { mods.insert(.shift) }
        if raw.contains(.option)  { mods.insert(.option) }
        if raw.contains(.control) { mods.insert(.control) }
        return mods
    }

    private func handleJumpModeMouseDown(_ event: NSEvent) -> NSEvent? {
        // A mouse click cancels jump mode, then continues to its original
        // target (returning the event passes the click through unmodified).
        send(.jumpModeCanceled)
        return event
    }

    func enterJumpMode() {
        let visibleTabs = sidebarView?.visibleTabIdsInRowOrder() ?? []
        send(.jumpModeActivated(visibleTabs: visibleTabs))
    }

    func send(_ msg: Msg) {
        guard let translatedMsg = translateMsg(msg, tokenForPane: { self.tokenStore.token(for: $0) }) else { return }

        let commands = update(&model, translatedMsg)
        // Command-phase split: most commands run before reconcile(); the few that
        // target a view the reconciler creates (Stage 4: only .focusSearchField,
        // whose search field reconcilePaneChrome builds) run after. See
        // Command.isPostReconcile.
        for command in commands where !command.isPostReconcile {
            perform(command)
        }
        let emitsPostReconcile = commands.contains { $0.isPostReconcile }
        switch reconcileDecision(
            for: translatedMsg,
            coalescedSweepPending: coalescedReconcileTimer != nil,
            emitsPostReconcile: emitsPostReconcile
        ) {
        case .reconcileNow:
            cancelCoalescedReconcile()
            reconcile()
        case .scheduleCoalesced:
            scheduleCoalescedReconcile()
        case .coalesceIntoPending:
            break
        }
        for command in commands where command.isPostReconcile {
            perform(command)
        }

        // Defensive backstop: cancel drag on app resign, in case the coordinator's
        // notification observer fires out of order.
        if case .appResignedActive = translatedMsg {
            cancelPaneDrag()
            // Flush pending light checkpoint so we don't lose state if the app
            // is killed while backgrounded (e.g. memory pressure, force quit).
            flushPendingCheckpoint()
        }
        // The chrome's tab-todo badge (and the dock/toolbar bell badges + window title)
        // now reconcile via reconcileWindowChrome from the model after every send().
    }

    /// Close pane-level shortcut help without dismissing the parent todo popover.
    func closeTodoShortcutHelpPopover() {
        (todoPopover?.contentViewController as? TodoPopoverViewController)?.closeShortcutHelpPopover()
    }

    /// Close tab-level shortcut help without dismissing the parent todo popover.
    func closeTabTodoShortcutHelpPopover() {
        (tabTodoPopover?.contentViewController as? TabTodoPopoverViewController)?.closeShortcutHelpPopover()
    }

    /// Dismiss child help before its pane parent so AppKit cannot refuse the parent close.
    private func dismissTodoPopoverPair() {
        closeTodoShortcutHelpPopover()
        todoPopover?.performClose(nil)
        todoPopover = nil
        todoPopoverDelegate = nil
    }

    /// Dismiss child help before its tab parent so AppKit cannot refuse the parent close.
    private func dismissTabTodoPopoverPair() {
        closeTabTodoShortcutHelpPopover()
        tabTodoPopover?.performClose(nil)
        tabTodoPopover = nil
        tabTodoPopoverDelegate = nil
    }

    /// Build, configure, and show a transient popover anchored to `anchor`, returning
    /// it so the caller can store it in the retained handle that owns its lifetime.
    /// Callers do their own pre-show VC setup and delegate lifetime management.
    private func presentTransientPopover(
        _ contentViewController: NSViewController,
        delegate: NSPopoverDelegate?,
        from anchor: NSView,
        preferredEdge: NSRectEdge = .minY
    ) -> NSPopover {
        let popover = NSPopover()
        popover.contentViewController = contentViewController
        popover.behavior = .transient
        popover.delegate = delegate
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
        return popover
    }

    func terminalView(for paneId: PaneId) -> TerminalView? {
        return surfaces[paneId]
    }

    /// Push effective model visibility to live libghostty surfaces, skipping unchanged panes.
    func syncSurfaceVisibility() {
        let windowVisible = window?.occlusionState.contains(.visible) ?? true
        let desired = effectiveSurfaceVisibility(in: model, windowVisible: windowVisible)

        for (paneId, view) in surfaces {
            guard let surface = view.surface else { continue }
            let visible = desired[paneId] ?? true
            if surfaceVisibility[paneId] != visible {
                ghostty_surface_set_occlusion(surface, visible)
                surfaceVisibility[paneId] = visible
            }
        }

        surfaceVisibility = surfaceVisibility.filter { paneId, _ in
            surfaces[paneId] != nil
        }
    }

    /// Push the active monitor's display id to every live surface so libghostty's
    /// per-surface CVDisplayLink re-syncs to that monitor's refresh rate.
    func syncSurfaceDisplayID() {
        guard let displayID = window?.screen?.displayID else { return }
        for (_, view) in surfaces {
            guard let surface = view.surface else { continue }
            ghostty_surface_set_display_id(surface, displayID)
        }

        // Mirror Ghostty's screen-change path: nudge backing properties on the
        // next main-loop turn because AppKit can skip the automatic callback.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (_, view) in self.surfaces {
                view.viewDidChangeBackingProperties()
            }
        }
    }

    /// Make the pane first responder; AppKit focus is the reparent/display-link
    /// recovery path for terminal activation.
    /// See docs/design/2026-05-27-terminal-focus-display-link.md.
    func focusPaneSurface(_ paneId: PaneId) {
        guard let view = surfaces[paneId] else { return }
        window?.makeFirstResponder(view)
    }

    var ipcSocketPath: URL {
        ipcServer?.socketPath ?? controlSocketPath()
    }

    func registerIpcConnection(_ connection: IpcConnection, for reqId: UUID) {
        ipcConnections[reqId] = connection
    }

    func stopIpcServer() {
        let socketPath = ipcSocketPath
        Task { await ipcServer?.stop() }
        try? FileManager.default.removeItem(at: socketPath)
    }

    // MARK: - Command Performer

    private func perform(_ command: Command) {
        switch command {
        case .createSurface(let paneId, let cwd, let command, let launchCommand, let waitAfterCommand):
            let token = tokenStore.generate(for: paneId)
            let envVars = terminalLaunchEnvironment(
                ipcSocketPath: ipcSocketPath.path,
                paneId: paneId,
                token: token
            )
            let view = makeTerminalView(
                paneId: paneId,
                workingDirectory: cwd,
                command: command,
                launchCommand: launchCommand,
                waitAfterCommand: waitAfterCommand,
                restoreCommandBehavior: .execute,
                envVars: envVars
            )
            surfaces[paneId] = view
            if view.surface == nil {
                send(.surfaceCreationFailed(paneId: paneId))
            }

        case .sendText(let paneId, let text):
            guard !text.isEmpty,
                  let surface = surfaces[paneId]?.surface else { break }
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
            }

        case .sendInputText(let paneId, let text):
            // Send a press-only key event with keycode 0 and the literal
            // UTF-8 text attached. Avoids paste stripping and bracketed-paste
            // markers so TUIs receive characters as if typed.
            guard !text.isEmpty,
                  let surface = surfaces[paneId]?.surface else { break }
            var ev = ghostty_input_key_s()
            ev.action = GHOSTTY_ACTION_PRESS
            ev.keycode = 0
            ev.mods = GHOSTTY_MODS_NONE
            ev.consumed_mods = GHOSTTY_MODS_NONE
            ev.unshifted_codepoint = 0
            ev.composing = false
            text.withCString { ptr in
                ev.text = ptr
                _ = ghostty_surface_key(surface, ev)
            }

        case .sendInputKey(let paneId, let key, let mods):
            // Press + matching release so a follow-up key event isn't
            // interpreted as auto-repeat. Ghostty's keymap layer handles
            // terminal encoding and DECCKM for us.
            guard let surface = surfaces[paneId]?.surface else { break }
            let (keycode, codepoint) = macKeyMapping(for: key)
            var ev = ghostty_input_key_s()
            ev.action = GHOSTTY_ACTION_PRESS
            ev.keycode = keycode
            ev.mods = ghosttyMods(mods)
            ev.consumed_mods = GHOSTTY_MODS_NONE
            ev.unshifted_codepoint = codepoint
            ev.composing = false
            ev.text = nil
            _ = ghostty_surface_key(surface, ev)
            ev.action = GHOSTTY_ACTION_RELEASE
            _ = ghostty_surface_key(surface, ev)

        case .focusSurface(let paneId, let focused):
            if let view = surfaces[paneId], let surface = view.surface {
                ghostty_surface_set_focus(surface, focused)
            }

        case .makeFirstResponder(let paneId):
            if let view = surfaces[paneId] {
                window?.makeFirstResponder(view)
            }

        case .sendNotification(let alertId, let title, let body):
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = [
                "alertId": alertId.rawValue.uuidString,
            ]
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            enqueueNotificationRequest(request)

        case .exportState(let snapshot):
            let enrichedSnapshot = graftScrollback(onto: snapshot, scrollbackByPaneId: scrollbackByPaneId())
            let initFile = toInitFile(snapshot: enrichedSnapshot)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data: Data
            do {
                data = try encoder.encode(initFile)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = "Failed to encode state: \(error.localizedDescription)"
                alert.runModal()
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "danterm-state.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            guard let window = window else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url)
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Save Failed"
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }

        case .ipcReply(let reqId, let result):
            guard let connection = ipcConnections.removeValue(forKey: reqId) else { break }
            connection.writeSuccess(reqId: reqId, result: result)

        case .ipcError(let reqId, let code, let message):
            guard let connection = ipcConnections.removeValue(forKey: reqId) else { break }
            connection.writeError(reqId: reqId, code: code, message: message)

        case .readPaneText(let reqId, let paneId, let lineLimit):
            guard let connection = ipcConnections.removeValue(forKey: reqId) else { break }
            guard let surface = surfaces[paneId]?.surface else {
                connection.writeError(reqId: reqId, code: -32603, message: "pane no longer available")
                break
            }
            guard let text = capturePaneText(surface: surface, lineLimit: lineLimit) else {
                connection.writeError(reqId: reqId, code: -32603, message: "failed to read pane text")
                break
            }
            connection.writeSuccess(reqId: reqId, result: .object(["text": .string(text)]))

        case .showCloseTabConfirmation(let tabId, let tabTitle, let paneCount, let isLastTab, let uncompletedTodoCount):
            runConfirmation(
                messageText: "Close tab \"\(tabTitle)\"?",
                informativeText: closeTabConfirmationCopy(
                    paneCount: paneCount,
                    uncompletedTodoCount: uncompletedTodoCount,
                    isLastTab: isLastTab
                ),
                confirmTitle: "Close Tab"
            ) { [weak self] isConfirm in
                self?.send(closeTabConfirmationResponse(isConfirm: isConfirm, tabId: tabId))
            }

        case .showCloseTabsConfirmation(let tabIds, let tabCount, let totalPaneCount, let totalUncompletedTodos, let isQuit):
            runConfirmation(
                messageText: isQuit ? "Close \(tabCount) tabs and quit DanTerm?" : "Close \(tabCount) tabs?",
                informativeText: closeTabsConfirmationCopy(
                    tabCount: tabCount,
                    totalPaneCount: totalPaneCount,
                    totalUncompletedTodos: totalUncompletedTodos,
                    isQuit: isQuit
                ),
                confirmTitle: "Close \(tabCount) Tabs"
            ) { [weak self] isConfirm in
                self?.send(closeTabsConfirmationResponse(isConfirm: isConfirm, ids: tabIds))
            }

        case .saveDanTermConfigKey(let key, let value):
            let path = DanTermConfigPaths.configFilePath()
            let url = URL(fileURLWithPath: path)
            let fm = FileManager.default
            let dir = url.deletingLastPathComponent().path
            if !fm.fileExists(atPath: dir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: path) {
                let seed = "# DanTerm config\n"
                fm.createFile(atPath: path, contents: seed.data(using: .utf8))
            }
            let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let updated = DanTermConfigWriter.setKey(key, value: value, in: existing)
            try? updated.write(to: url, atomically: true, encoding: .utf8)

        case .removeDanTermConfigKey(let key):
            let path = DanTermConfigPaths.configFilePath()
            let url = URL(fileURLWithPath: path)
            guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else { break }
            let updated = DanTermConfigWriter.removeKey(key, from: existing)
            try? updated.write(to: url, atomically: true, encoding: .utf8)

        case .reloadGhosttyConfig:
            reloadAllConfig()

        case .scheduleCheckpoint:
            scheduleDebouncedCheckpoint()

        case .terminate:
            cancelCoalescedReconcile()
            checkpointDebouncer.cancel()
            enrichedCheckpointTimer?.cancel()
            enrichedCheckpointTimer = nil
            for paneId in replayFiles.keys {
                cleanupReplayFile(for: paneId)
            }
            (NSApp.delegate as? AppDelegate)?.quitConfirmed = true
            NSApp.terminate(nil)

        case .activateApp:
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)

        case .setAppFocus(let focused):
            if let app = ghosttyApp.app {
                ghostty_app_set_focus(app, focused)
            }

        case .dismissAlertsPopover:
            alertsPopover?.performClose(nil)
            alertsPopover = nil

        // Search commands

        case .sendStartSearch(let paneId):
            if let view = surfaces[paneId], let surface = view.surface {
                let action = "start_search"
                _ = action.withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
                }
            }

        case .focusSearchField(let paneId):
            if let field = findPaneWrapper(for: paneId)?.searchOverlay?.searchField {
                window?.makeFirstResponder(field)
            }

        case .sendSearchNeedle(let paneId, let needle):
            // Debounce: immediate for empty or 3+ chars, 300ms for 1-2 chars
            let delay: TimeInterval = (needle.isEmpty || needle.count >= 3) ? 0 : 0.3
            let sendNeedle = { [weak self] in
                guard let self = self,
                      let view = self.surfaces[paneId],
                      let surface = view.surface else { return }
                let action = "search:\(needle)"
                _ = action.withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
                }
            }

            if delay == 0 {
                searchDebouncers[paneId]?.cancel()
                sendNeedle()
            } else {
                let debouncer = searchDebouncers[paneId] ?? {
                    let debouncer = Debouncer(queue: .main)
                    searchDebouncers[paneId] = debouncer
                    return debouncer
                }()
                debouncer.schedule(after: delay, perform: sendNeedle)
            }

        case .sendSearchNavigate(let paneId, let direction):
            if let view = surfaces[paneId], let surface = view.surface {
                let action = direction == .next ? "navigate_search:next" : "navigate_search:previous"
                _ = action.withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
                }
            }

        case .sendEndSearch(let paneId):
            searchDebouncers[paneId]?.cancel()
            searchDebouncers.removeValue(forKey: paneId)
            if let view = surfaces[paneId], let surface = view.surface {
                let action = "end_search"
                _ = action.withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
                }
            }

        // TODO popover

        case .showTodoPopover(let paneId):
            dismissTodoPopoverPair()
            guard let wrapper = findPaneWrapper(for: paneId) else { return }
            let vc = TodoPopoverViewController(paneId: paneId, runtime: self)
            let delegate = TodoPopoverDelegateAdapter(paneId: paneId, runtime: self)
            vc.loadViewIfNeeded()
            guard let projection = desiredPaneTodoPopover(paneId: paneId, in: model) else { return }
            vc.apply(projection)
            todoPopover = presentTransientPopover(vc, delegate: delegate, from: wrapper.todoButtonView)
            todoPopoverDelegate = delegate

        case .dismissTodoPopover:
            dismissTodoPopoverPair()

        case .showTodoPopoverForTab(let tabId):
            dismissTabTodoPopoverPair()
            guard let anchor = chromeView?.tabTodoButton else { return }
            let vc = TabTodoPopoverViewController(tabId: tabId, runtime: self)
            let delegate = TabTodoPopoverDelegateAdapter(tabId: tabId, runtime: self)
            vc.loadViewIfNeeded()
            guard let projection = desiredTabTodoPopover(tabId: tabId, in: model) else { return }
            vc.apply(projection)
            tabTodoPopover = presentTransientPopover(vc, delegate: delegate, from: anchor)
            tabTodoPopoverDelegate = delegate

        case .dismissTodoPopoverForTab:
            dismissTabTodoPopoverPair()

        case .showClosePaneConfirmation(let paneId, let uncompletedCount):
            let tasks = uncompletedCount == 1 ? "1 uncompleted task" : "\(uncompletedCount) uncompleted tasks"
            runConfirmation(
                messageText: "Close pane?",
                informativeText: "This pane has \(tasks).",
                confirmTitle: "Close Pane"
            ) { [weak self] isConfirm in
                guard isConfirm, let surface = self?.surfaces[paneId]?.surface else { return }
                ghostty_surface_request_close(surface)
            }
        }
    }

    // Deliver notifications only after checking authorization state so the
    // first real alert can recover if the launch-time prompt was skipped.
    // Both completion closures run off the main actor (the center dispatches
    // them on a background queue), so keep them free of main-actor state --
    // no model/view mutation here without hopping back to main.
    private func enqueueNotificationRequest(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request) { error in
                    if let error {
                        print("Failed to enqueue notification: \(error)")
                    }
                }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        print("Notification authorization request failed: \(error)")
                        return
                    }
                    guard granted else { return }
                    center.add(request) { error in
                        if let error {
                            print("Failed to enqueue notification: \(error)")
                        }
                    }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    // MARK: - Scrollback Replay Files

    /// Read text from one Ghostty point tag using line-based selection.
    private func readSurfaceRegion(
        surface: ghostty_surface_t,
        tag: ghostty_point_tag_e
    ) -> String? {
        let topLeft = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let bottomRight = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        let selection = ghostty_selection_s(top_left: topLeft, bottom_right: bottomRight, rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text_len > 0 else { return "" }
        guard let ptr = text.text else { return nil }
        let len = Int(text.text_len)
        return ptr.withMemoryRebound(to: UInt8.self, capacity: len) { reboundPtr in
            String(bytes: UnsafeBufferPointer(start: reboundPtr, count: len), encoding: .utf8)
        }
    }

    /// Capture visible text, or full written text tailed to a requested line count.
    private func capturePaneText(surface: ghostty_surface_t, lineLimit: Int?) -> String? {
        let tag: ghostty_point_tag_e = lineLimit == nil ? GHOSTTY_POINT_VIEWPORT : GHOSTTY_POINT_SCREEN
        guard let raw = readSurfaceRegion(surface: surface, tag: tag) else {
            return nil
        }
        guard let n = lineLimit else {
            return raw
        }
        return tailLines(raw, n: n)
    }

    /// Read full scrollback text from a ghostty surface using line-based selection.
    private func readScrollbackText(surface: ghostty_surface_t) -> String? {
        return readSurfaceRegion(surface: surface, tag: GHOSTTY_POINT_SCREEN)
    }

    /// Write scrollback text to a temp file for shell replay. Returns the file URL.
    private func writeReplayFile(scrollback: String) -> URL? {
        guard let data = scrollback.data(using: .utf8) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.replayDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return fileURL
    }

    /// Delete the replay file for a pane if one exists.
    private func cleanupReplayFile(for paneId: PaneId) {
        if let url = replayFiles.removeValue(forKey: paneId) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Tear down all runtime resources for one pane's surface. The body of the old
    /// `.destroySurface` perform arm, now owned by `reconcileSurfaceExistence` (which
    /// calls it for every pane absent from `model.allPaneIds`). `internal` so the
    /// cross-file reconcile extension can reach it.
    func tearDownSurface(_ paneId: PaneId) {
        tokenStore.remove(paneId)
        cleanupReplayFile(for: paneId)
        searchDebouncers[paneId]?.cancel()
        searchDebouncers.removeValue(forKey: paneId)
        if let view = surfaces.removeValue(forKey: paneId) {
            view.closeSurface()
        }
    }

    /// Delete all files in $TMPDIR/danterm-scrollback/ from prior sessions.
    func cleanupStaleReplayDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.replayDirectoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Session Checkpointing

    /// Schedule a light checkpoint after a debounce delay. Each call resets the
    /// timer so rapid-fire model changes (e.g. dragging a split divider) coalesce
    /// into a single disk write.
    private func scheduleDebouncedCheckpoint() {
        checkpointPending = true
        checkpointDebouncer.schedule(
            after: Self.checkpointDebounceInterval,
            leeway: .milliseconds(200)
        ) { [weak self] in
            self?.performLightCheckpoint(async: true)
        }
    }

    /// Defer the whole-model reconcile() sweep while title/cwd/progress messages
    /// arrive at high frequency. The timer reads the latest model when it fires.
    /// This is fixed-window coalescing; use Debouncer for trailing-edge debounce.
    private func scheduleCoalescedReconcile() {
        guard coalescedReconcileTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.reconcileCoalesceInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.coalescedReconcileTimer = nil
            self.reconcile()
        }
        timer.resume()
        coalescedReconcileTimer = timer
    }

    /// Cancel any deferred sweep because an inline reconcile will cover the latest model.
    private func cancelCoalescedReconcile() {
        coalescedReconcileTimer?.cancel()
        coalescedReconcileTimer = nil
    }

    /// Flush a pending debounced checkpoint immediately. Called on appResignedActive
    /// so we don't lose the last 2s of state changes when the user switches away.
    func flushPendingCheckpoint() {
        checkpointDebouncer.cancel()
        if checkpointPending {
            performLightCheckpoint(async: false)
        } else {
            Self.checkpointIOQueue.sync {}
        }
    }

    /// Start a repeating timer that writes enriched checkpoints (model +
    /// scrollback from live surfaces). Called once from applicationDidFinishLaunching.
    func startEnrichedCheckpointTimer() {
        enrichedCheckpointTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.enrichedCheckpointInterval,
            repeating: Self.enrichedCheckpointInterval,
            leeway: .seconds(30)
        )
        timer.setEventHandler { [weak self] in
            self?.performEnrichedCheckpoint(async: true)
        }
        timer.resume()
        enrichedCheckpointTimer = timer
    }

    /// Write a light checkpoint: pure model serialization with scrollback: nil.
    /// Cheap — no Ghostty surface interaction.
    private func performLightCheckpoint(async: Bool) {
        checkpointPending = false
        let initFile = toInitFile(model)
        writeCheckpoint(initFile, to: lightCheckpointURL(), async: async)
    }

    /// Read scrollback text from each live surface, keyed by pane id. The impure
    /// half of scrollback enrichment; the pure `graftScrollback(onto:...)` embeds
    /// this map into a snapshot's tree leaves.
    private func scrollbackByPaneId() -> [PaneId: String] {
        var result: [PaneId: String] = [:]
        for (paneId, view) in surfaces {
            guard let surface = view.surface,
                  let rawText = readScrollbackText(surface: surface),
                  let scrollback = truncateScrollback(rawText) else {
                continue
            }
            result[paneId] = scrollback
        }
        return result
    }

    /// Write an enriched checkpoint: model snapshot + scrollback text read from
    /// each live Ghostty surface. Expensive but gives full restore fidelity.
    /// Called by the periodic timer and once at clean termination.
    func performEnrichedCheckpoint(async: Bool) {
        let enrichedSnapshot = graftScrollback(onto: toSnapshot(model), scrollbackByPaneId: scrollbackByPaneId())
        writeCheckpoint(toInitFile(snapshot: enrichedSnapshot), to: enrichedCheckpointURL(), async: async)
    }

    /// Encode and atomically write a checkpoint to the given URL.
    /// Uses .sortedKeys for stable output (no .prettyPrinted — this is a machine file).
    private func writeCheckpoint(_ initFile: AppInitFile, to url: URL, async: Bool) {
        let dir = recoveryDirectoryURL()
        let work = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(initFile) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }

        if async {
            Self.checkpointIOQueue.async(execute: work)
        } else {
            Self.checkpointIOQueue.sync(execute: work)
        }
    }

    // MARK: - State Import

    /// Present a file picker, validate the chosen state file, and replace the current session.
    func importStateFromPanel(restoreCommandBehavior: RestoreCommandBehavior = .prefill) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.importState(from: url, restoreCommandBehavior: restoreCommandBehavior)
        }
    }

    /// Load a state file from disk, keeping the current session intact on any validation failure.
    func importState(from url: URL, restoreCommandBehavior: RestoreCommandBehavior = .prefill) {
        do {
            let data = try Data(contentsOf: url)
            let loaded = try loadValidatedInitFile(from: data)
            do {
                let staged = try stageValidatedRestore(loaded, restoreCommandBehavior: restoreCommandBehavior)
                commitRestoreSession(staged)
            } catch {
                showImportError(message: "Import failed while creating terminal surfaces.")
            }
        } catch let error as AppInitFileLoadError {
            showImportError(message: importErrorMessage(for: error))
        } catch {
            showImportError(message: error.localizedDescription)
        }
    }

    // MARK: - Pane Drag

    func startPaneDrag(paneId: PaneId) {
        cancelPaneDrag()
        guard let contentArea = contentArea else { return }
        guard let tab = selectedTab(in: model) else { return }

        let targetIds = allPaneIds(tab.rootNode).filter { $0 != paneId }

        // Build pane frame provider: converts PaneWrapperView frames to window coordinates
        let provider: (PaneId) -> NSRect? = { [weak self] targetPaneId in
            guard let self = self else { return nil }
            guard let wrapper = self.findPaneWrapper(for: targetPaneId) else { return nil }
            return wrapper.convert(wrapper.bounds, to: nil)
        }

        let coordinator = PaneDragCoordinator(
            sourcePaneId: paneId,
            contentView: contentArea,
            paneFrameProvider: provider,
            targetPaneIds: targetIds
        )
        dragCoordinator = coordinator
    }

    /// Convert a screen point to window coordinates and update the drag overlay.
    func updatePaneDrag(screenPoint: NSPoint) {
        guard let window = window else { return }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        dragCoordinator?.updateDrag(locationInWindow: windowPoint)
    }

    /// Return current pane-area drop if one is active (for use by NSDraggingSource endedAt).
    func currentPaneDrop() -> (source: PaneId, target: PaneId, intent: PaneDropIntent)? {
        return dragCoordinator?.currentDrop()
    }

    /// Tear down the drag coordinator overlay. Called after the NSDraggingSession ends.
    func endPaneDrag() {
        cancelPaneDrag()
    }

    func cancelPaneDrag() {
        guard dragCoordinator != nil else { return }
        dragCoordinator?.teardown()
        dragCoordinator = nil
    }

    /// Full config reload: Ghostty files, DanTerm config, then themed pane re-layering.
    func reloadAllConfig() {
        ghosttyApp.reloadConfig()
        reloadDanTermConfig()
        send(.ghosttyConfigReloaded)
    }

    /// Re-parse DanTerm-specific config keys and dispatch through the Elm loop.
    func reloadDanTermConfig() {
        let config = DanTermConfigParser.loadFromDisk()
        send(.configLoaded(config))
    }

    // MARK: - Preferences Panel

    /// Show or re-focus the preferences panel. Reads the live Ghostty config to
    /// seed the draft, then lets reconcile create/show from the model. The final
    /// makeKeyAndOrderFront call re-raises an already-open normal-level panel.
    func showPreferencesPanel() {
        let ghostty = GhosttyPrefs(
            theme: ghosttyApp.readConfigString(key: "theme"),
            fontSize: ghosttyApp.readConfigFloatString(key: "font-size")
        )
        send(.preferencesOpened(ghostty: ghostty))
        preferencesPanel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Theme Browser

    /// Toggle the theme browser panel on the right side of the content area.
    func toggleThemeBrowser() {
        if let existing = themeBrowserView {
            existing.removeFromSuperview()
            themeBrowserView = nil
            reconcileThemeBrowser()
            // Restore focus to the focused pane's surface
            if let tab = selectedTab(in: model),
               let view = surfaces[tab.focusedPaneId] {
                window?.makeFirstResponder(view)
            }
            return
        }
        guard let contentArea = contentArea else { return }

        let browser = ThemeBrowserView()
        browser.runtime = self
        contentArea.addSubview(browser)
        NSLayoutConstraint.activate([
            browser.topAnchor.constraint(equalTo: contentArea.topAnchor),
            browser.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            browser.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
        ])
        themeBrowserView = browser
        browser.reloadTable()
        reconcileThemeBrowser()
    }

    // MARK: - Snapshot Bootstrap

    /// Validate a raw snapshot (the --init path) then stage + commit it.
    func bootstrapFromSnapshot(_ snapshot: AppModelSnapshot, restoreCommandBehavior: RestoreCommandBehavior = .prefill) {
        guard let built = validateAndBuildDetailed(snapshot) else {
            print("[init] Snapshot validation failed, falling back to default startup")
            send(.createTab(inGroupId: nil))
            return
        }
        bootstrapFromValidatedRestore(
            ValidatedAppRestore(snapshot: snapshot, model: built.model, paneSnapshots: built.paneSnapshots),
            restoreCommandBehavior: restoreCommandBehavior
        )
    }

    /// Stage + commit an already-validated restore (the crash/clean-recovery path,
    /// where main.swift validated and merged the checkpoints up front). Avoids
    /// decoding/validating the recovered structure a second time.
    func bootstrapFromValidatedRestore(_ loaded: ValidatedAppRestore, restoreCommandBehavior: RestoreCommandBehavior = .prefill) {
        do {
            let staged = try stageValidatedRestore(loaded, restoreCommandBehavior: restoreCommandBehavior)
            commitRestoreSession(staged)
        } catch {
            print("[init] Snapshot surface creation failed, falling back to default startup")
            send(.createTab(inGroupId: nil))
        }
    }

    /// Build all runtime objects for a validated restore without touching the live session.
    private func stageValidatedRestore(
        _ loaded: ValidatedAppRestore,
        restoreCommandBehavior: RestoreCommandBehavior
    ) throws -> StagedRestoreSession {
        var stagedSurfaces: [PaneId: TerminalView] = [:]
        var stagedTokenStore = PaneTokenStore()
        var stagedReplayFiles: [PaneId: URL] = [:]

        do {
            for group in loaded.model.groups {
                for tab in group.tabs {
                    for paneId in allPaneIds(tab.rootNode) {
                        let ps = loaded.paneSnapshots[paneId]
                        let resolved = ps.map { resolveLaunch($0) }
                        let token = stagedTokenStore.generate(for: paneId)
                        var scrollbackFilePath: String?
                        if let replayText = recoveryReplayText(scrollback: ps?.scrollback, agentSession: ps?.agentSession),
                           let replayURL = writeReplayFile(scrollback: replayText) {
                            stagedReplayFiles[paneId] = replayURL
                            scrollbackFilePath = replayURL.path
                        }
                        let envVars = restoreLaunchEnvironment(
                            ipcSocketPath: ipcSocketPath.path,
                            paneId: paneId,
                            token: token,
                            scrollbackFilePath: scrollbackFilePath
                        )
                        let view = makeTerminalView(
                            paneId: paneId,
                            workingDirectory: resolved?.cwd,
                            command: resolved?.command,
                            launchCommand: nil,
                            waitAfterCommand: true,
                            restoreCommandBehavior: restoreCommandBehavior,
                            envVars: envVars
                        )
                        stagedSurfaces[paneId] = view
                        if view.surface == nil {
                            throw RestoreBuildError.surfaceCreationFailed
                        }
                    }
                }
            }

            return StagedRestoreSession(
                model: loaded.model,
                surfaces: stagedSurfaces,
                tokenStore: stagedTokenStore,
                replayFiles: stagedReplayFiles
            )
        } catch {
            discardRestoreSession(StagedRestoreSession(
                model: loaded.model,
                surfaces: stagedSurfaces,
                tokenStore: stagedTokenStore,
                replayFiles: stagedReplayFiles
            ))
            throw error
        }
    }

    /// Tear down live runtime resources before swapping in a replacement session.
    private func tearDownCurrentSession() {
        dismissStrandedPopovers()  // cancelPaneDrag + dismiss todo/tab-todo popover pairs
        alertsPopover?.performClose(nil)
        alertsPopover = nil
        model.todoPopover = nil  // session teardown bypasses the reconciler; clear directly
        // Hide/destroy before resetting caches so nil keeps meaning "already hidden"
        // for the first post-restore reconcile. Restored models carry no draft.
        preferencesPanel?.close()
        preferencesPanel = nil
        quitConfirmationPanel?.orderOut(nil)
        quitConfirmationPanel = nil

        for tabId in Array(tabContainers.keys) {
            removeTabContainer(tabId)
        }

        for paneId in Array(surfaces.keys) {
            cleanupReplayFile(for: paneId)
            if let view = surfaces.removeValue(forKey: paneId) {
                view.closeSurface()
            }
        }
        surfaceVisibility.removeAll()
        // The switcher panel persists across sessions; hide it before resetting
        // caches.switcher so nil continues to mean the panel is already hidden.
        switcherPanel?.orderOut(nil)
        // Reset reconciler caches by re-init so the first post-restore reconcile is
        // a clean build, not a stale diff (restore/import can reuse pane IDs).
        caches = ReconcilerCaches()
        for paneId in Array(replayFiles.keys) {
            cleanupReplayFile(for: paneId)
        }
        tokenStore = PaneTokenStore()
    }

    /// Swap a fully staged restore into the live runtime and refresh derived UI state.
    private func commitRestoreSession(_ staged: StagedRestoreSession) {
        tearDownCurrentSession()
        model = staged.model
        surfaces = staged.surfaces
        tokenStore = staged.tokenStore
        replayFiles = staged.replayFiles
        cancelCoalescedReconcile()

        // Restore bypasses update(); reconcile MRU here so the first
        // cmd-shift-i after a restore sees a populated mruOrder.
        reconcileMru(&model)

        // Drive the entire post-restore UI through reconcile() (clean build:
        // tearDownCurrentSession reset the caches). reconcileContainers builds every
        // tab's container eagerly from the nil containerShape cache -- selected visible,
        // the rest mounted+hidden -- and the chrome/sidebar/window passes build from
        // scratch. reconcileSurfaceExistence is a no-op (staged surfaces match allPaneIds).
        reconcile()

    }

    /// Dispose of a staged restore after a failed build so no temp state leaks into the live session.
    private func discardRestoreSession(_ staged: StagedRestoreSession) {
        for (_, view) in staged.surfaces {
            view.closeSurface()
        }
        for url in staged.replayFiles.values {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Construct a terminal view and attach DanTerm runtime metadata before first use.
    private func makeTerminalView(
        paneId: PaneId,
        workingDirectory: String?,
        command: String?,
        launchCommand: String?,
        waitAfterCommand: Bool,
        restoreCommandBehavior: RestoreCommandBehavior,
        envVars: [(String, String)]
    ) -> TerminalView {
        let view = TerminalView(
            ghosttyApp: ghosttyApp,
            workingDirectory: workingDirectory,
            command: command,
            launchCommand: launchCommand,
            waitAfterCommand: waitAfterCommand,
            restoreCommandBehavior: restoreCommandBehavior,
            envVars: envVars
        )
        view.bridge.paneId = paneId
        view.runtime = self
        view.scrollbarEnabled = ghosttyApp.scrollbarEnabled
        return view
    }

    private func importErrorMessage(for error: AppInitFileLoadError) -> String {
        switch error {
        case .decodeFailed:
            return "The selected file is not valid DanTerm JSON."
        case .unsupportedVersion(let version):
            return "Unsupported state file version: \(version)."
        case .invalidSnapshot:
            return "The selected state file failed snapshot validation."
        }
    }

    /// Run a two-button confirm/cancel alert and report both outcomes through one
    /// completion. This centralizes the sheet-vs-modal split and confirm-button
    /// mapping so close-confirmation callers keep their cancel cleanup paths.
    private func runConfirmation(
        messageText: String,
        informativeText: String,
        confirmTitle: String,
        onResponse: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if let window = window {
            alert.beginSheetModal(for: window) { response in
                onResponse(response == .alertFirstButtonReturn)
            }
        } else {
            onResponse(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func showImportError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Import Failed"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Pane Toolbars

    // Resolve via the existing PaneId -> TerminalView index. `internal` (not `private`)
    // so reconcilePaneChrome in Reconcile.swift can reach the live wrapper.
    func findPaneWrapper(for paneId: PaneId) -> PaneWrapperView? {
        surfaces[paneId]?.paneWrapper
    }

    // MARK: - View Building

    /// Build a split container for one tab and insert it below the theme browser overlay.
    /// `internal` so the cross-file reconcileContainers executor can build a container.
    func buildAndInsertContainer(for tab: TabModel) -> SplitContainerView {
        guard let contentArea = contentArea else { fatalError("contentArea unavailable") }
        let displayNode: SplitNodeModel
        if tab.isZoomed {
            displayNode = .leaf(model.pane(tab.focusedPaneId) ?? PaneModel(id: tab.focusedPaneId))
        } else {
            displayNode = tab.rootNode
        }

        // Defocus all surfaces before rebuilding
        for paneId in allPaneIds(tab.rootNode) {
            if let view = surfaces[paneId], let surface = view.surface {
                ghostty_surface_set_focus(surface, false)
            }
        }

        let container = SplitContainerView(
            rootNode: displayNode,
            surfaceLookup: { [weak self] paneId in self?.surfaces[paneId] },
            runtime: self,
            isZoomed: tab.isZoomed,
            hasSplits: { if case .leaf = tab.rootNode { return false } else { return true } }(),
            frame: contentArea.bounds
        )
        container.autoresizingMask = [.width, .height]
        if let browser = themeBrowserView {
            contentArea.addSubview(container, positioned: .below, relativeTo: browser)
        } else {
            contentArea.addSubview(container)
        }
        container.rebuild()
        tabContainers[tab.id] = container
        return container
    }

    /// Detach and forget the cached container for a removed tab. `internal` so the
    /// cross-file reconcileContainers executor (and tearDownCurrentSession) can call it.
    func removeTabContainer(_ tabId: TabId) {
        guard let container = tabContainers.removeValue(forKey: tabId) else { return }
        container.removeFromSuperview()
    }

    /// Cancel an in-flight pane drag and dismiss any open TODO popovers.
    /// `reconcileContainers` calls this when containerOpsStrandVisible says the
    /// visible container was hidden, rebuilt, or removed. The model record is
    /// cleared separately by reconcileTodoPopover in update().
    func dismissStrandedPopovers() {
        cancelPaneDrag()
        dismissTodoPopoverPair()
        dismissTabTodoPopoverPair()
    }

    /// Establish mount-time focus for a just-(re)built or newly-shown selected container.
    /// The folded `finalizeTabSelection` focus, minus the parts the reconciler now owns:
    /// the focus-border loop (reconcileFocusBorders), the toolbar refresh (reconcilePaneChrome
    /// + container cache invalidation), and the search-overlay rehydrate (reconcilePaneChrome).
    /// reconcile() calls this *after* reconcilePaneChrome so the search field exists when an
    /// active-search pane needs it. Scoped to the single selected container (never per built
    /// container) so eager-mounted hidden tabs don't fight for first responder.
    func applyMountTimeFocus(_ tabId: TabId?) {
        guard let tabId = tabId,
              let tab = tabById(tabId, in: model),
              tabContainers[tabId] != nil else { return }
        let browserFocus = themeBrowserView?.captureFocusTarget()
        let focusedId = tab.focusedPaneId
        // Focus the focused pane's surface -- unless the theme browser owns focus or the
        // pane has an active search (whose field is focused just below instead).
        if browserFocus == nil, model.searchState[focusedId] == nil,
           let focusedView = surfaces[focusedId] {
            window?.makeFirstResponder(focusedView)
        }
        // Active search on the focused pane: focus its (paneChrome-rebuilt) search field.
        if browserFocus == nil, model.searchState[focusedId] != nil,
           let field = findPaneWrapper(for: focusedId)?.searchOverlay?.searchField {
            window?.makeFirstResponder(field)
        }
        // The theme browser owns its own filter/focus; content updates via reconcileThemeBrowser.
        if let browser = themeBrowserView {
            if let target = browserFocus { browser.restoreFocus(target) }
        }
    }

    // MARK: - Alerts Popover

    func toggleAlertsPopover() {
        if let popover = alertsPopover, popover.isShown {
            popover.performClose(nil)
            alertsPopover = nil
            return
        }
        guard let anchor = chromeView?.bellButton else { return }
        let vc = AlertsPopoverViewController()
        vc.runtime = self
        vc.loadViewIfNeeded()
        vc.apply(desiredAlertsPopover(in: model))
        alertsPopover = presentTransientPopover(vc, delegate: alertsPopoverDelegate, from: anchor)
    }
}

/// NSPopoverDelegate adapter for the alerts popover. Alerts popover visibility is
/// AppKit-owned, so close events only clear the retained popover handle.
private final class AlertsPopoverDelegateAdapter: NSObject, NSPopoverDelegate {
    weak var runtime: AppRuntime?

    init(runtime: AppRuntime?) {
        self.runtime = runtime
    }

    /// NSPopoverDelegate: release the popover handle after click-away or programmatic close.
    func popoverDidClose(_ notification: Notification) {
        runtime?.alertsPopover = nil
    }
}

/// NSPopoverDelegate adapter for the per-pane TODO popover.
/// Sends .todoPopoverClosed when the popover closes for any reason (click-away,
/// programmatic, etc.) so model.todoPopover stays in sync.
private class TodoPopoverDelegateAdapter: NSObject, NSPopoverDelegate {
    weak var runtime: AppRuntime?
    let paneId: PaneId
    init(paneId: PaneId, runtime: AppRuntime?) {
        self.paneId = paneId
        self.runtime = runtime
    }
    /// NSPopoverDelegate: cascade-close shortcut help before the parent closes.
    func popoverWillClose(_ notification: Notification) {
        runtime?.closeTodoShortcutHelpPopover()
    }
    /// NSPopoverDelegate: keep model.todoPopover in sync after any close path.
    func popoverDidClose(_ notification: Notification) {
        runtime?.send(.todoPopoverClosed(paneId: paneId))
    }
}

/// NSPopoverDelegate adapter for the tab-level TODO popover. Mirrors the pane
/// adapter; sends .todoPopoverForTabClosed so model.todoPopover stays in sync.
class TabTodoPopoverDelegateAdapter: NSObject, NSPopoverDelegate {
    weak var runtime: AppRuntime?
    let tabId: TabId
    init(tabId: TabId, runtime: AppRuntime?) {
        self.tabId = tabId
        self.runtime = runtime
    }
    /// NSPopoverDelegate: cascade-close shortcut help before the parent closes.
    func popoverWillClose(_ notification: Notification) {
        runtime?.closeTabTodoShortcutHelpPopover()
    }
    /// NSPopoverDelegate: keep model.todoPopover in sync after any close path.
    func popoverDidClose(_ notification: Notification) {
        runtime?.send(.todoPopoverForTabClosed(tabId: tabId))
    }
}

/// Build the close-tab confirmation copy. Mentions panes when there is more
/// than one, and unfinished tasks when the rollup is non-zero, so the warning
/// matches what the chrome badge advertises.
func closeTabConfirmationCopy(paneCount: Int, uncompletedTodoCount: Int, isLastTab: Bool) -> String {
    var parts: [String] = []
    if paneCount > 1 {
        parts.append("\(paneCount) terminal panes")
    }
    if uncompletedTodoCount > 0 {
        let label = uncompletedTodoCount == 1 ? "1 unfinished task" : "\(uncompletedTodoCount) unfinished tasks"
        parts.append(label)
    }
    let prefix: String
    if parts.isEmpty {
        prefix = "This tab will be closed."
    } else if parts.count == 1 {
        prefix = "This tab has \(parts[0])."
    } else {
        prefix = "This tab has \(parts[0]) and \(parts[1])."
    }
    if isLastTab {
        return prefix + " Closing it will quit DanTerm."
    }
    return prefix
}

private enum RestoreBuildError: Error {
    case surfaceCreationFailed
}

// macOS hardware keycodes (kVK_*) for the closed `KeyName` set, plus the ASCII
// codepoint for letters so Ghostty's keymap layer encodes the right terminal
// bytes. Total: every enum case maps to a concrete (keycode, codepoint) pair.
private func macKeyMapping(for key: KeyName) -> (UInt32, UInt32) {
    switch key {
    case .named(let n):
        switch n {
        case .enter:  return (36, 0)
        case .tab:    return (48, 0)
        case .bspace: return (51, 0)
        case .escape: return (53, 0)
        case .up:     return (126, 0)
        case .down:   return (125, 0)
        case .left:   return (123, 0)
        case .right:  return (124, 0)
        case .home:   return (115, 0)
        case .end:    return (119, 0)
        case .pgUp:   return (116, 0)
        case .pgDn:   return (121, 0)
        case .delete: return (117, 0)
        case .f1:  return (122, 0)
        case .f2:  return (120, 0)
        case .f3:  return (99, 0)
        case .f4:  return (118, 0)
        case .f5:  return (96, 0)
        case .f6:  return (97, 0)
        case .f7:  return (98, 0)
        case .f8:  return (100, 0)
        case .f9:  return (101, 0)
        case .f10: return (109, 0)
        case .f11: return (103, 0)
        case .f12: return (111, 0)
        }
    case .letter(let c):
        let keycode = letterKeycodes[c] ?? 0
        let codepoint = UInt32(c.asciiValue ?? 0)
        return (keycode, codepoint)
    }
}

// kVK_ANSI_* keycodes for a-z. Non-sequential — these come from the original
// ADB keyboard layout and have stuck around.
private let letterKeycodes: [Character: UInt32] = [
    "a": 0,  "s": 1,  "d": 2,  "f": 3,  "h": 4,  "g": 5,  "z": 6,  "x": 7,
    "c": 8,  "v": 9,  "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
    "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
    "n": 45, "m": 46,
]

private func ghosttyMods(_ mods: KeyMods) -> ghostty_input_mods_e {
    var raw: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if mods.contains(.ctrl) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if mods.contains(.alt)  { raw |= GHOSTTY_MODS_ALT.rawValue }
    return ghostty_input_mods_e(raw)
}
