// Runtime bridge that performs update effects and synchronizes AppKit/Ghostty views.
import Cocoa
import DanTermProtocol
import GhosttyKit
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

// App runtime owns the mutable app model, performs side effects emitted by the
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
    let ghosttyApp: GhosttyApp
    var surfaces: [PaneId: TerminalView] = [:]
    // Last libghostty occlusion value pushed for each live surface.
    // Cleared on teardown because restore/import can reuse pane IDs for fresh surfaces.
    private var surfaceVisibility: [PaneId: Bool] = [:]
    var tokenStore = PaneTokenStore()
    weak var window: NSWindow?
    weak var sidebarView: SidebarView?
    weak var contentArea: NSView?
    weak var chromeView: WindowChromeView?
    var alertsPopover: NSPopover?
    var todoPopover: NSPopover?
    private var todoPopoverDelegate: TodoPopoverDelegateAdapter?
    var tabTodoPopover: NSPopover?
    private var tabTodoPopoverDelegate: TabTodoPopoverDelegateAdapter?
    private var themeBrowserView: ThemeBrowserView?
    private var preferencesPanel: PreferencesPanel?
    private var quitConfirmationPanel: QuitConfirmationPanel?
    private var switcherPanel: SwitcherPanel?
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
    private var checkpointTimer: DispatchSourceTimer?          // debounce timer for light checkpoints
    private var enrichedCheckpointTimer: DispatchSourceTimer?  // repeating timer for enriched checkpoints
    private var checkpointPending = false                      // true while a debounced write is scheduled
    private var searchDebounceTimers: [PaneId: DispatchSourceTimer] = [:]
    private var ipcConnections: [UUID: IpcConnection] = [:]
    private var ipcServer: IpcServer?
    private static let checkpointDebounceInterval: TimeInterval = 2.0
    // Slowed from 60s to 10min until the libghostty memory leak is fixed.
    // https://github.com/danneu/danterm/issues/31
    private static let enrichedCheckpointInterval: TimeInterval = 600.0

    init(ghosttyApp: GhosttyApp) {
        self.ghosttyApp = ghosttyApp
        self.model = AppModel(
            groups: [GroupModel(id: GroupId(), name: "General")],
            panes: [:]
        )
        // Load DanTerm config before any tabs are created
        self.model.config = DanTermConfigParser.loadFromDisk()

        // Build the MRU switcher panel eagerly — pay first-frame cost at
        // launch instead of on every cmd-shift-i. Keep it offscreen until
        // showSwitcherOverlay fires.
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

    private func screenPoint(for event: NSEvent) -> NSPoint {
        if let window = event.window ?? self.window {
            let screenRect = window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero))
            return screenRect.origin
        }
        return NSEvent.mouseLocation
    }

    private func handleJumpModeMouseDown(_ event: NSEvent) -> NSEvent? {
        // Mouse clicks always cancel jump mode but continue to the original
        // target; SidebarView owns the hit-test details for sidebar clicks.
        _ = sidebarView?.containsScreenPoint(screenPoint(for: event)) ?? false
        send(.jumpModeCanceled)
        return event
    }

    func enterJumpMode() {
        let visibleTabs = sidebarView?.visibleTabIdsInRowOrder() ?? []
        send(.jumpModeActivated(visibleTabs: visibleTabs))
    }

    func send(_ msg: Msg) {
        guard let translatedMsg = translateMsg(msg, tokenForPane: { self.tokenStore.token(for: $0) }) else { return }

        let oldUnreadCount = totalUnreadAlertCount(model: model)
        let effects = update(&model, translatedMsg)
        for effect in effects {
            perform(effect)
        }
        syncSurfaceVisibility()
        if model.pendingConfirmation == .terminate {
            quitConfirmationPanel?.configure(paneCount: model.panes.count)
        }
        let newUnreadCount = totalUnreadAlertCount(model: model)
        if newUnreadCount != oldUnreadCount {
            perform(.updateDockBadge(newUnreadCount))
            perform(.updateToolbarBellBadge(newUnreadCount))
        }

        // Defensive backstop: cancel drag on app resign, in case the coordinator's
        // notification observer fires out of order.
        if case .appResignedActive = translatedMsg {
            cancelPaneDrag()
            // Flush pending light checkpoint so we don't lose state if the app
            // is killed while backgrounded (e.g. memory pressure, force quit).
            flushPendingCheckpoint()
        }

        // Refresh pane toolbar after title/cwd/progress/remote-state/todo changes,
        // and refresh the chrome's tab-todo badge when a pane todo change lives in
        // the active tab (the badge rolls up tab + every pane in that tab).
        switch translatedMsg {
        case .surfaceTitle(let paneId, _), .surfaceCwd(let paneId, _), .surfaceProgress(let paneId, _),
             .remoteSessionStarted(let paneId), .remoteSessionReported(let paneId, _), .commandEnded(let paneId):
            refreshPaneToolbar(for: paneId)

        case .addTodo(let paneId, _), .toggleTodoDone(let paneId, _),
             .setTodoDone(let paneId, _, _),
             .editTodoText(let paneId, _, _), .deleteTodo(let paneId, _),
             .reorderTodo(let paneId, _, _), .clearCompletedTodos(let paneId):
            refreshPaneToolbar(for: paneId)
            if paneIsInActiveTab(paneId) { refreshTabTodoButton() }

        case .addTabTodo(let tabId, _), .toggleTabTodoDone(let tabId, _),
             .setTabTodoDone(let tabId, _, _),
             .editTabTodoText(let tabId, _, _), .deleteTabTodo(let tabId, _),
             .reorderTabTodo(let tabId, _, _), .clearCompletedTabTodos(let tabId):
            if tabId == model.selectedTabId { refreshTabTodoButton() }

        case .moveTodo(let from, _, let to, _):
            if case .pane(let paneId) = from { refreshPaneToolbar(for: paneId) }
            if case .pane(let paneId) = to { refreshPaneToolbar(for: paneId) }
            let movedTabId: TabId? = {
                switch (from, to) {
                case (.tab(let tabId), _), (_, .tab(let tabId)):
                    return tabId
                case (.pane(let paneId), _):
                    return tabForPane(paneId, in: model)?.id
                }
            }()
            if let tabId = movedTabId, tabId == model.selectedTabId {
                refreshTabTodoButton()
            }

        case .selectTab, .closeTab, .closePane, .createTab, .splitPane,
             .movePaneToTab, .movePaneToNewTab, .mruCycleCommitted, .mruCycleOneShot,
             .jumpModeKeyPressed:
            // Selection or tab-membership changes shift which tab the chrome
            // badge represents. Selection-affecting branches refresh too.
            refreshTabTodoButton()

        default:
            break
        }
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

    private func paneIsInActiveTab(_ paneId: PaneId) -> Bool {
        guard let selId = model.selectedTabId else { return false }
        return tabForPane(paneId, in: model)?.id == selId
    }

    /// Push the active tab's roll-up counts into the chrome's right-side button.
    /// Renders neutral when there's no active tab so the badge isn't stale.
    func refreshTabTodoButton() {
        guard let button = chromeView?.tabTodoButton else { return }
        if let tabId = model.selectedTabId {
            let rollup = tabTodoRollup(tabId, in: model)
            button.update(totalCount: rollup.total, uncompletedCount: rollup.uncompleted)
        } else {
            button.update(totalCount: 0, uncompletedCount: 0)
        }
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

    /// Make the given pane's surface the first responder. The view dispatches
    /// `.paneBecameFirstResponder` from its becomeFirstResponder override, so
    /// the model update + chrome refresh follow naturally. No-op when the
    /// surface isn't live.
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

    // MARK: - Effect Performer

    private func perform(_ effect: Effect) {
        switch effect {
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

        case .destroySurface(let paneId):
            tokenStore.remove(paneId)
            cleanupReplayFile(for: paneId)
            searchDebounceTimers[paneId]?.cancel()
            searchDebounceTimers.removeValue(forKey: paneId)
            if let view = surfaces.removeValue(forKey: paneId) {
                view.closeSurface()
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

        case .rebuildContentView:
            rebuildContentView()

        case .refreshPaneBorder(let paneId):
            let isFocused = isFocusedAndVisible(paneId, in: model)
            let hasBell = paneHasUnreadAlert(paneId, alerts: model.alerts)
            surfaces[paneId]?.setFocusBorder(isFocused, hasBell: hasBell)

        case .reloadSidebar:
            sidebarView?.reload(model: model)

        case .setSidebarSelection(let tabId):
            sidebarView?.applySelection(tabId: tabId, model: model)

        case .updateSidebarTabRow(let tabId):
            sidebarView?.updateTabRow(tabId: tabId, model: model)

        case .updateSidebarGroupRow(let groupId):
            sidebarView?.updateGroupRow(groupId: groupId, model: model)

        case .setWindowTitle(let title):
            window?.title = title
            refreshContentTitlebar()

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
            let enrichedSnapshot = enrichSnapshot(snapshot)
            let initFile = AppInitFile(version: 1, model: enrichedSnapshot)

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
            let alert = NSAlert()
            alert.messageText = "Close tab \"\(tabTitle)\"?"
            alert.informativeText = closeTabConfirmationCopy(
                paneCount: paneCount,
                uncompletedTodoCount: uncompletedTodoCount,
                isLastTab: isLastTab
            )
            alert.addButton(withTitle: "Close Tab")
            alert.addButton(withTitle: "Cancel")
            if let window = window {
                alert.beginSheetModal(for: window) { [weak self] response in
                    let isConfirm = response == .alertFirstButtonReturn
                    self?.send(closeTabConfirmationResponse(isConfirm: isConfirm, tabId: tabId))
                }
            } else {
                let response = alert.runModal()
                let isConfirm = response == .alertFirstButtonReturn
                self.send(closeTabConfirmationResponse(isConfirm: isConfirm, tabId: tabId))
            }

        case .showCloseTabsConfirmation(let tabIds, let tabCount, let totalPaneCount, let totalUncompletedTodos, let isQuit):
            let alert = NSAlert()
            alert.messageText = isQuit ? "Close \(tabCount) tabs and quit DanTerm?" : "Close \(tabCount) tabs?"
            alert.informativeText = closeTabsConfirmationCopy(
                tabCount: tabCount,
                totalPaneCount: totalPaneCount,
                totalUncompletedTodos: totalUncompletedTodos,
                isQuit: isQuit
            )
            alert.addButton(withTitle: "Close \(tabCount) Tabs")
            alert.addButton(withTitle: "Cancel")
            if let window = window {
                alert.beginSheetModal(for: window) { [weak self] response in
                    let isConfirm = response == .alertFirstButtonReturn
                    self?.send(closeTabsConfirmationResponse(isConfirm: isConfirm, ids: tabIds))
                }
            } else {
                let response = alert.runModal()
                let isConfirm = response == .alertFirstButtonReturn
                self.send(closeTabsConfirmationResponse(isConfirm: isConfirm, ids: tabIds))
            }

        case .showTerminateConfirmation(let paneCount):
            if quitConfirmationPanel == nil {
                quitConfirmationPanel = QuitConfirmationPanel(runtime: self)
            }
            quitConfirmationPanel?.configure(paneCount: paneCount)
            quitConfirmationPanel?.center(on: window)
            quitConfirmationPanel?.makeKeyAndOrderFront(nil)

        case .applyPaneTheme(let paneId):
            applyPaneConfig(paneId: paneId)

        case .saveDanTermConfigKey(let key, let value):
            let path = DanTermConfigParser.configFilePath()
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
            let path = DanTermConfigParser.configFilePath()
            let url = URL(fileURLWithPath: path)
            guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else { break }
            let updated = DanTermConfigWriter.removeKey(key, from: existing)
            try? updated.write(to: url, atomically: true, encoding: .utf8)

        case .reloadGhosttyConfig:
            reloadAllConfig()

        case .syncPreferencesPanel:
            preferencesPanel?.sync(
                committed: model.config,
                draft: model.preferencesDraft,
                ghostty: model.committedGhosttyPrefs
            )

        case .scheduleCheckpoint:
            scheduleDebouncedCheckpoint()

        case .terminate:
            checkpointTimer?.cancel()
            checkpointTimer = nil
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

        case .updateToolbarBellBadge(let count):
            chromeView?.updateBellBadge(count: count)

        case .updateDockBadge(let count):
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
            NSApp.dockTile.display()

        // Search effects

        case .sendStartSearch(let paneId):
            if let view = surfaces[paneId], let surface = view.surface {
                let action = "start_search"
                _ = action.withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
                }
            }

        case .showSearchOverlay(let paneId):
            guard let search = model.searchState[paneId],
                  let contentArea = contentArea else { return }
            findPaneWrapper(for: paneId, in: contentArea)?.showSearchOverlay(search: search, runtime: self)

        case .hideSearchOverlay(let paneId):
            guard let contentArea = contentArea else { return }
            findPaneWrapper(for: paneId, in: contentArea)?.hideSearchOverlay()

        case .focusSearchField(let paneId):
            guard let contentArea = contentArea else { return }
            if let field = findPaneWrapper(for: paneId, in: contentArea)?.searchOverlay?.searchField {
                window?.makeFirstResponder(field)
            }

        case .sendSearchNeedle(let paneId, let needle):
            // Debounce: immediate for empty or 3+ chars, 300ms for 1-2 chars
            searchDebounceTimers[paneId]?.cancel()
            searchDebounceTimers.removeValue(forKey: paneId)

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
                sendNeedle()
            } else {
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + delay)
                timer.setEventHandler(handler: sendNeedle)
                timer.resume()
                searchDebounceTimers[paneId] = timer
            }

        case .sendSearchNavigate(let paneId, let direction):
            if let view = surfaces[paneId], let surface = view.surface {
                let action = direction == .next ? "navigate_search:next" : "navigate_search:previous"
                _ = action.withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
                }
            }

        case .sendEndSearch(let paneId):
            searchDebounceTimers[paneId]?.cancel()
            searchDebounceTimers.removeValue(forKey: paneId)
            if let view = surfaces[paneId], let surface = view.surface {
                let action = "end_search"
                _ = action.withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
                }
            }

        // TODO popover

        case .showTodoPopover(let paneId):
            dismissTodoPopoverPair()
            guard let contentArea = contentArea,
                  let wrapper = findPaneWrapper(for: paneId, in: contentArea) else { return }
            let anchor = wrapper.todoButtonView
            let vc = TodoPopoverViewController(paneId: paneId, runtime: self)
            let delegate = TodoPopoverDelegateAdapter(paneId: paneId, runtime: self)
            let popover = NSPopover()
            popover.contentViewController = vc
            popover.behavior = .transient
            popover.delegate = delegate
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            todoPopover = popover
            todoPopoverDelegate = delegate

        case .dismissTodoPopover:
            dismissTodoPopoverPair()

        case .showTodoPopoverForTab(let tabId):
            dismissTabTodoPopoverPair()
            guard let anchor = chromeView?.tabTodoButton else { return }
            let vc = TabTodoPopoverViewController(tabId: tabId, runtime: self)
            let delegate = TabTodoPopoverDelegateAdapter(tabId: tabId, runtime: self)
            let popover = NSPopover()
            popover.contentViewController = vc
            popover.behavior = .transient
            popover.delegate = delegate
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            tabTodoPopover = popover
            tabTodoPopoverDelegate = delegate

        case .dismissTodoPopoverForTab:
            dismissTabTodoPopoverPair()

        case .showClosePaneConfirmation(let paneId, let uncompletedCount):
            let alert = NSAlert()
            let tasks = uncompletedCount == 1 ? "1 uncompleted task" : "\(uncompletedCount) uncompleted tasks"
            alert.messageText = "Close pane?"
            alert.informativeText = "This pane has \(tasks)."
            alert.addButton(withTitle: "Close Pane")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if let window = window {
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn {
                        if let surface = self?.surfaces[paneId]?.surface {
                            ghostty_surface_request_close(surface)
                        }
                    }
                }
            }

        case .refreshPaneToolbar(let paneId):
            refreshPaneToolbar(for: paneId)

        case .showSwitcherOverlay:
            // Idempotent: render and order-front. Don't makeKeyAndOrderFront
            // — the panel is non-activating; key would steal first responder.
            switcherPanel?.render(from: model)
            switcherPanel?.centerOnScreen(of: window)
            switcherPanel?.orderFront(nil)

        case .hideSwitcherOverlay:
            switcherPanel?.orderOut(nil)
        }
    }

    // Deliver notifications only after checking authorization state so the
    // first real alert can recover if the launch-time prompt was skipped.
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
        checkpointTimer?.cancel()
        checkpointPending = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.checkpointDebounceInterval)
        timer.setEventHandler { [weak self] in
            self?.performLightCheckpoint()
        }
        timer.resume()
        checkpointTimer = timer
    }

    /// Flush a pending debounced checkpoint immediately. Called on appResignedActive
    /// so we don't lose the last 2s of state changes when the user switches away.
    func flushPendingCheckpoint() {
        guard checkpointPending else { return }
        checkpointTimer?.cancel()
        checkpointTimer = nil
        performLightCheckpoint()
    }

    /// Start a repeating 60s timer that writes enriched checkpoints (model +
    /// scrollback from live surfaces). Called once from applicationDidFinishLaunching.
    func startEnrichedCheckpointTimer() {
        enrichedCheckpointTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.enrichedCheckpointInterval, repeating: Self.enrichedCheckpointInterval)
        timer.setEventHandler { [weak self] in
            self?.performEnrichedCheckpoint()
        }
        timer.resume()
        enrichedCheckpointTimer = timer
    }

    /// Write a light checkpoint: pure model serialization with scrollback: nil.
    /// Cheap — no Ghostty surface interaction.
    private func performLightCheckpoint() {
        checkpointPending = false
        let initFile = toInitFile(model)
        writeCheckpoint(initFile, to: lightCheckpointURL())
    }

    /// Enrich a snapshot's panes with scrollback text read from live surfaces.
    private func enrichSnapshot(_ snapshot: AppModelSnapshot) -> AppModelSnapshot {
        let enrichedPanes: [PaneSnapshot] = snapshot.panes.map { ps in
            guard let idStr = ps.id,
                  let uuid = UUID(uuidString: idStr),
                  let view = surfaces[PaneId(rawValue: uuid)],
                  let surface = view.surface,
                  let rawText = readScrollbackText(surface: surface),
                  let scrollback = truncateScrollback(rawText) else {
                return ps
            }
            return PaneSnapshot(
                id: ps.id, title: ps.title, cwd: ps.cwd,
                launch: ps.launch, scrollback: scrollback, theme: ps.theme
            )
        }
        return AppModelSnapshot(
            groups: snapshot.groups,
            panes: enrichedPanes,
            selectedTabId: snapshot.selectedTabId
        )
    }

    /// Write an enriched checkpoint: model snapshot + scrollback text read from
    /// each live Ghostty surface. Expensive but gives full restore fidelity.
    /// Called by the 60s periodic timer and once at clean termination.
    func performEnrichedCheckpoint() {
        let enrichedSnapshot = enrichSnapshot(toSnapshot(model))
        writeCheckpoint(AppInitFile(version: 1, model: enrichedSnapshot), to: enrichedCheckpointURL())
    }

    /// Encode and atomically write a checkpoint to the given URL.
    /// Uses .sortedKeys for stable output (no .prettyPrinted — this is a machine file).
    private func writeCheckpoint(_ initFile: AppInitFile, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(initFile) else { return }
        let dir = recoveryDirectoryURL()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
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
            guard let self = self, let contentArea = self.contentArea else { return nil }
            guard let wrapper = self.findPaneWrapper(for: targetPaneId, in: contentArea) else { return nil }
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

    // MARK: - Per-Pane Theme

    /// Apply the pane's effective theme to its surface.
    /// Uses remoteThemeOverride (if set) over the user's theme.
    /// If effective theme is nil, reloads the base config (clearing any override).
    func applyPaneConfig(paneId: PaneId) {
        guard let view = surfaces[paneId], let surface = view.surface,
              let pane = model.panes[paneId] else { return }
        if let theme = effectiveTheme(for: pane) {
            guard let config = ghosttyApp.loadConfigWithTheme(theme) else { return }
            ghostty_surface_update_config(surface, config)
            ghostty_config_free(config)
        } else {
            ghosttyApp.reloadConfig(surface: surface, soft: false)
        }
    }

    /// Re-apply config for all panes that have a non-nil effective theme.
    /// Called after app-wide config reload.
    func reapplyAllPaneThemes() {
        for (paneId, pane) in model.panes where effectiveTheme(for: pane) != nil {
            applyPaneConfig(paneId: paneId)
        }
    }

    /// Full config reload: Ghostty files → pane theme re-application → DanTerm config.
    func reloadAllConfig() {
        ghosttyApp.reloadConfig()
        reapplyAllPaneThemes()
        reloadDanTermConfig()
    }

    /// Re-parse DanTerm-specific config keys and dispatch through the Elm loop.
    func reloadDanTermConfig() {
        let config = DanTermConfigParser.loadFromDisk()
        send(.configLoaded(config))
    }

    // MARK: - Preferences Panel

    /// Show or re-focus the preferences panel. Created lazily on first call.
    /// Dispatches .preferencesOpened which is idempotent — only creates a draft
    /// on the closed → open transition; re-focus just resyncs.
    func showPreferencesPanel() {
        if preferencesPanel == nil {
            preferencesPanel = PreferencesPanel(runtime: self)
        }
        let ghostty = GhosttyPrefs(
            theme: ghosttyApp.readConfigString(key: "theme"),
            fontSize: ghosttyApp.readConfigFloatString(key: "font-size")
        )
        send(.preferencesOpened(ghostty: ghostty))
        preferencesPanel!.makeKeyAndOrderFront(nil)
    }

    // MARK: - Theme Browser

    /// Toggle the theme browser panel on the right side of the content area.
    func toggleThemeBrowser() {
        if let existing = themeBrowserView {
            existing.removeFromSuperview()
            themeBrowserView = nil
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
        browser.reloadFromRuntime()
        themeBrowserView = browser
    }

    // MARK: - Snapshot Bootstrap

    func bootstrapFromSnapshot(_ snapshot: AppModelSnapshot, restoreCommandBehavior: RestoreCommandBehavior = .prefill) {
        guard let built = validateAndBuildDetailed(snapshot) else {
            print("[init] Snapshot validation failed, falling back to default startup")
            send(.createTab(inGroupId: nil))
            return
        }
        let loaded = ValidatedAppRestore(snapshot: snapshot, model: built.model, paneSnapshots: built.paneSnapshots)
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
                        var envVars: [(String, String)] = [("DANTERM_TOKEN", token)]
                        if let scrollback = ps?.scrollback,
                           let replayURL = writeReplayFile(scrollback: scrollback) {
                            stagedReplayFiles[paneId] = replayURL
                            envVars.append(("DANTERM_RESTORE_SCROLLBACK_FILE", replayURL.path))
                        }
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
        cancelPaneDrag()
        alertsPopover?.performClose(nil)
        alertsPopover = nil
        dismissTodoPopoverPair()
        dismissTabTodoPopoverPair()
        model.todoPopover = nil
        preferencesPanel?.close()
        preferencesPanel = nil
        quitConfirmationPanel?.orderOut(nil)
        quitConfirmationPanel = nil

        for paneId in Array(surfaces.keys) {
            cleanupReplayFile(for: paneId)
            if let view = surfaces.removeValue(forKey: paneId) {
                view.closeSurface()
            }
        }
        surfaceVisibility.removeAll()
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

        // Restore bypasses update(); reconcile MRU here so the first
        // cmd-shift-i after a restore sees a populated mruOrder.
        reconcileMru(&model)

        refreshContentTitlebar()
        rebuildContentView()
        syncSurfaceVisibility()
        sidebarView?.reload(model: model)
        let unreadCount = totalUnreadAlertCount(model: model)
        chromeView?.updateBellBadge(count: unreadCount)
        NSApp.dockTile.badgeLabel = unreadCount > 0 ? "\(unreadCount)" : nil
        NSApp.dockTile.display()

        // Apply per-pane themes after surfaces are live
        reapplyAllPaneThemes()
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

    private func showImportError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Import Failed"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Content Titlebar

    /// Update the window chrome title with the selected tab's display title.
    /// Called from .setWindowTitle effect (emitted on tab select, rename, title/cwd changes).
    func refreshContentTitlebar() {
        guard let tab = selectedTab(in: model) else {
            chromeView?.updateTitle("")
            return
        }
        chromeView?.updateTitle(tab.displayTitle)
    }

    // MARK: - Pane Toolbars

    func refreshPaneToolbars() {
        guard let contentArea = contentArea else { return }
        forEachPaneWrapper(in: contentArea) { wrapper in
            let (title, cwd) = paneToolbarText(for: wrapper.paneId, in: model)
            let progress = model.panes[wrapper.paneId]?.progress
            let isRemote = model.panes[wrapper.paneId]?.isRemote ?? false
            let remoteSession = model.panes[wrapper.paneId]?.remoteSession
            let alertCount = model.alerts.count { $0.paneId == wrapper.paneId && $0.isUnread }
            let todos = model.panes[wrapper.paneId]?.todos ?? []
            let totalTodo = todos.count
            let uncompletedTodo = todos.count { !$0.isDone }
            wrapper.updateToolbar(title: title, cwd: cwd, progress: progress, isRemote: isRemote, remoteSession: remoteSession, unreadAlertCount: alertCount, totalTodoCount: totalTodo, uncompletedTodoCount: uncompletedTodo)
        }
    }

    private func refreshPaneToolbar(for paneId: PaneId) {
        guard let contentArea = contentArea else { return }
        let (title, cwd) = paneToolbarText(for: paneId, in: model)
        let progress = model.panes[paneId]?.progress
        let isRemote = model.panes[paneId]?.isRemote ?? false
        let remoteSession = model.panes[paneId]?.remoteSession
        let alertCount = model.alerts.count { $0.paneId == paneId && $0.isUnread }
        let todos = model.panes[paneId]?.todos ?? []
        let totalTodo = todos.count
        let uncompletedTodo = todos.count { !$0.isDone }
        findPaneWrapper(for: paneId, in: contentArea)?.updateToolbar(title: title, cwd: cwd, progress: progress, isRemote: isRemote, remoteSession: remoteSession, unreadAlertCount: alertCount, totalTodoCount: totalTodo, uncompletedTodoCount: uncompletedTodo)
    }

    private func findPaneWrapper(for paneId: PaneId, in view: NSView) -> PaneWrapperView? {
        for sub in view.subviews {
            if let wrapper = sub as? PaneWrapperView {
                if wrapper.paneId == paneId { return wrapper }
            } else if let found = findPaneWrapper(for: paneId, in: sub) {
                return found
            }
        }
        return nil
    }

    private func forEachPaneWrapper(in view: NSView, _ body: (PaneWrapperView) -> Void) {
        for sub in view.subviews {
            if let wrapper = sub as? PaneWrapperView {
                body(wrapper)
            } else {
                forEachPaneWrapper(in: sub, body)
            }
        }
    }

    // MARK: - View Building

    private func rebuildContentView() {
        cancelPaneDrag()
        dismissTodoPopoverPair()
        dismissTabTodoPopoverPair()
        model.todoPopover = nil
        guard let contentArea = contentArea else { return }

        // Capture browser focus before subview removal so we can restore it after reattachment
        let browserFocus = themeBrowserView?.captureFocusTarget()

        // Remove old content
        for subview in contentArea.subviews {
            subview.removeFromSuperview()
        }

        guard let tab = selectedTab(in: model) else { return }

        let displayNode: SplitNodeModel
        if tab.isZoomed {
            displayNode = .leaf(tab.focusedPaneId)
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
        contentArea.addSubview(container)
        container.rebuild()

        // Set focus borders based on model state (skip green border for single-pane tabs)
        let focusedId = tab.focusedPaneId
        for paneId in allPaneIds(displayNode) {
            let isFocused = isFocusedAndVisible(paneId, in: model)
            let hasBell = paneHasUnreadAlert(paneId, alerts: model.alerts)
            surfaces[paneId]?.setFocusBorder(isFocused, hasBell: hasBell)
        }

        // Focus the right pane — but only if the theme browser doesn't own focus.
        // This responder guard protects any overlay UI from being clobbered by rebuild.
        if browserFocus == nil {
            if model.searchState[focusedId] == nil {
                if let focusedView = surfaces[focusedId] {
                    window?.makeFirstResponder(focusedView)
                }
            }
        }

        refreshPaneToolbars()
        refreshContentTitlebar()
        // Refresh the chrome's tab-todo badge: restore-from-snapshot bypasses
        // update() and lands here, so without this the badge would render
        // neutral until the next refresh-emitting message.
        refreshTabTodoButton()

        // Rehydrate search overlays for panes with active search
        for (paneId, search) in model.searchState {
            findPaneWrapper(for: paneId, in: contentArea)?.showSearchOverlay(search: search, runtime: self)
        }
        // If search is active on the focused pane, focus its text field (unless browser has focus)
        if browserFocus == nil,
           model.searchState[focusedId] != nil,
           let field = findPaneWrapper(for: focusedId, in: contentArea)?.searchOverlay?.searchField {
            window?.makeFirstResponder(field)
        }

        // Rehydrate theme browser panel if open
        if let browser = themeBrowserView {
            contentArea.addSubview(browser)
            NSLayoutConstraint.activate([
                browser.topAnchor.constraint(equalTo: contentArea.topAnchor),
                browser.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
                browser.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            ])
            browser.reloadFromRuntime()
            // Restore focus to browser if it owned focus before rebuild
            if let target = browserFocus {
                browser.restoreFocus(target)
            }
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
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        alertsPopover = popover
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
