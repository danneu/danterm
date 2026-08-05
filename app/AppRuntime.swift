// Runtime bridge that performs update commands and synchronizes AppKit/Ghostty views.
import Cocoa
import DanTermProtocol
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

/// Resolve DanTerm's process-temporary root, with a harness-only override
/// because macOS Foundation ignores a launched app's `TMPDIR` value.
func danTermTemporaryDirectoryURL(fileManager: FileManager = .default) -> URL {
    #if DANTERM_TERMINAL_CHARACTERIZATION || DANTERM_TERMINAL_BENCHMARK
    if let path = ProcessInfo.processInfo.environment["DANTERM_TERMINAL_CHARACTERIZATION_TEMP_ROOT"] {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    #endif
    return fileManager.temporaryDirectory
}

/// Centralize the replay directory used by restore writes, stale cleanup, and
/// the characterization isolation probe so all three observe the same path.
func scrollbackReplayDirectoryURL(fileManager: FileManager = .default) -> URL {
    scrollbackReplayDirectoryURL(
        identity: DanTermInstanceIdentity(),
        temporaryDirectory: danTermTemporaryDirectoryURL(fileManager: fileManager)
    )
}

#if DANTERM_TERMINAL_CHARACTERIZATION
/// Records terminal boundary events so opt-in characterization harnesses can
/// assert callback conformance without exposing backend details.
@MainActor
func recordTerminalCharacterizationEvent(_ event: TerminalSessionEvent) {
    let description: String
    switch event {
    case .titleChanged(let title):
        description = "session.titleChanged:\(title)"
    case .cwdChanged(let cwd):
        description = "session.cwdChanged:\(cwd)"
    case .bell:
        description = "session.bell"
    case .desktopNotification(let title, let body):
        description = "session.desktopNotification:\(title):\(body)"
    case .progress(let progress):
        description = "session.progress:\(String(describing: progress))"
    case .searchStarted(let needle):
        description = "session.searchStarted:\(needle)"
    case .searchTotal(let total):
        description = "session.searchTotal:\(String(describing: total))"
    case .searchSelected(let selected):
        description = "session.searchSelected:\(String(describing: selected))"
    case .becameFirstResponder:
        description = "session.becameFirstResponder"
    case .closeRequested:
        description = "session.closeRequested"
    }
    appendTerminalCharacterizationEvent(description)
}

/// Records process-wide boundary events without serializing Ghostty preference
/// details that are already covered by pure event translation tests.
@MainActor
func recordTerminalCharacterizationEvent(_ event: TerminalBackendEvent) {
    let description: String
    switch event {
    case .configReloaded:
        description = "backend.configReloaded"
    case .configChanged(_, let scrollbarEnabled):
        description = "backend.configChanged:scrollbar=\(scrollbarEnabled)"
    case .quitRequested:
        description = "backend.quitRequested"
    }
    appendTerminalCharacterizationEvent(description)
}

/// Marks a complete frame reaching the visible Swift terminal view so harnesses
/// can prove hidden and idle panes do not schedule rendering work.
@MainActor
func recordTerminalCharacterizationPlanDelivery() {
    appendTerminalCharacterizationEvent("session.planDelivered")
}

/// Marks an effective pane visibility transition before it reaches the backend,
/// giving harnesses an ordering fence for hidden-output and reveal assertions.
@MainActor
func recordTerminalCharacterizationVisibilityChange(paneId: PaneId, visible: Bool) {
    appendTerminalCharacterizationEvent(
        "session.visibilityChanged:\(paneId.rawValue.uuidString):\(visible)"
    )
}

@MainActor
private func appendTerminalCharacterizationEvent(_ description: String) {
    guard let path = ProcessInfo.processInfo.environment[
        "DANTERM_TERMINAL_CHARACTERIZATION_EVENT_LOG"
    ] else { return }
    let data = Data("\(description)\n".utf8)
    if FileManager.default.fileExists(atPath: path) == false {
        FileManager.default.createFile(atPath: path, contents: data)
        return
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    defer { try? handle.close() }
    do {
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    } catch {
        print("[characterization] Failed to record terminal event: \(error)")
    }
}
#endif

/// Encodes and queues one complete follow batch off the main actor, completing after its last line.
private func writePaneTapeFollowRecords(
    _ records: [JSONValue],
    connection: IpcConnection,
    subscriptionId: UUID,
    completion: @escaping @Sendable (Bool) -> Void
) {
    precondition(records.isEmpty == false)
    DispatchQueue.global(qos: .utility).async {
        for (index, record) in records.enumerated() {
            let isLast = index == records.index(before: records.endIndex)
            connection.writeNotification(
                method: Methods.paneTapeEvent,
                params: .object([
                    "subscription": .string(subscriptionId.uuidString),
                    "record": record,
                ]),
                completion: isLast ? completion : nil
            )
        }
    }
}

// App runtime owns the mutable app model, performs the commands emitted by the
// pure update function, and bridges model changes into AppKit/Ghostty objects.
@MainActor
class AppRuntime {
    private struct StagedRestoreSession {
        let model: AppModel
        let surfaces: [PaneId: any TerminalSession]
        let replayFiles: [PaneId: URL]
    }

    var model: AppModel
    private let configStore: DanTermConfigStore
    private let notificationAuthorizationPolicy: NotificationAuthorizationPolicy
    private var pendingConfigError: Error?
    // Ephemeral view state the reconciler reads as a second input (see ViewLocalState).
    // Today just the inline-rename target, set/cleared by SidebarView's rename paths and
    // read only by reconcileSidebar's rename guard.
    var viewLocalState = ViewLocalState()
    let terminalBackend: any TerminalBackend
    var surfaces: [PaneId: any TerminalSession] = [:]
    // Last libghostty occlusion value pushed for each live surface.
    // Cleared on teardown because restore/import can reuse pane IDs for fresh surfaces.
    private var surfaceVisibility: [PaneId: Bool] = [:]
    // Per-pass diff caches for the view reconciler (see Reconcile.swift).
    // Reset on teardown so a post-restore reconcile is a clean build.
    var caches = ReconcilerCaches()
    // internal (not private): the cross-file reconcileContainers extension reads/mutates it.
    var tabContainers: [TabId: SplitContainerView] = [:]
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
    // Session persistence uses two tiers of checkpoints:
    //   Light  — pure model serialization (no scrollback), written after a 2s debounce
    //            following any state-mutating Msg. Cheap and frequent.
    //   Enriched -- model + primary history, mutation-driven for Swift and temporarily
    //               periodic for Ghostty, plus one final synchronous clean-exit write.
    private let checkpointDebouncer = Debouncer(queue: .main)  // trailing debounce for light checkpoints
    private var enrichedCheckpointTimer: DispatchSourceTimer?  // one owned enriched-checkpoint timer
    private var recoveryPolicy = RecoveryCheckpointPolicy(
        window: UInt64(600 * NSEC_PER_SEC)
    )
    private var checkpointPending = false                      // true while a debounced write is scheduled
    private var coalescedReconcileTimer: DispatchSourceTimer?   // rate-limited whole-model sweep
    // Serializes checkpoint writes and gives sync flushes one fence for pending async I/O.
    private static let checkpointIOQueue = DispatchQueue(label: "danterm.checkpoint.io", qos: .utility)
    private var searchDebouncers: [PaneId: Debouncer] = [:]
    private var ipcConnections: [UUID: IpcConnection] = [:]
    private var paneTapeFollowSubscriptions = PaneTapeFollowSubscriptions()
    private var paneTapeFollowConnections: [UUID: IpcConnection] = [:]
    private var paneTapeFollowTimer: DispatchSourceTimer?
    private var ipcServer: IpcServer?
    private static let checkpointDebounceInterval: TimeInterval = 2.0
    // Matches Ghostty's title coalesce interval: quick enough to feel live, slow
    // enough to avoid flickering chrome under terminal-title spam.
    private static let reconcileCoalesceInterval: TimeInterval = 0.075
    private static let paneTapeFollowInterval: TimeInterval = 0.05
    // Slowed from 60s to 10min until the libghostty memory leak is fixed.
    // https://github.com/danneu/danterm/issues/31
    private static let enrichedCheckpointInterval: TimeInterval = 600.0

    init(
        terminalBackend: any TerminalBackend,
        configStore: DanTermConfigStore = DanTermConfigStore(),
        notificationAuthorizationPolicy: NotificationAuthorizationPolicy = .requestIfNeeded
    ) {
        self.terminalBackend = terminalBackend
        self.configStore = configStore
        self.notificationAuthorizationPolicy = notificationAuthorizationPolicy
        // Empty launch: one group, no tabs/leaves yet (panes live in leaves).
        self.model = AppModel(
            groups: [GroupModel(id: GroupId(rawValue: CoreEnv.live.newId()), name: "General")]
        )
        // Load DanTerm config before any tabs are created. This is the one apply
        // path that cannot go through send() -- the Elm loop is not running yet --
        // so it assigns the same pair configLoaded does, via the same resolver.
        let launchConfig: DanTermConfig
        do {
            launchConfig = try configStore.load()
        } catch {
            launchConfig = .default
            self.pendingConfigError = error
        }
        self.model.config = launchConfig
        self.model.resolvedFontFamily = resolveConfiguredFontFamily(launchConfig)

        terminalBackend.onEvent = { [weak self] event in
            guard let self else { return }
            #if DANTERM_TERMINAL_CHARACTERIZATION
            recordTerminalCharacterizationEvent(event)
            #endif
            if case .configChanged(_, let scrollbarEnabled) = event {
                for session in self.surfaces.values {
                    session.setScrollbarEnabled(scrollbarEnabled)
                }
            }
            self.send(terminalMessage(for: event))
        }

        // Build the MRU switcher panel eagerly — pay first-frame cost at
        // launch instead of on every cmd-shift-i. Keep it offscreen until
        // reconcileSwitcher orders it front (mruCycle becomes non-nil).
        self.switcherPanel = SwitcherPanel()

        // Install the local NSEvent monitor that drives ephemeral keyboard modes.
        // It reads model flags to know whether a mode is active, but never mutates
        // the model directly; mutations go through send().
        installSwitcherEventMonitor()

        do {
            self.ipcServer = try IpcServer(socketPath: controlSocketPath(), runtime: self)
            Task { await self.ipcServer?.start() }
        } catch {
            self.ipcServer = nil
            print("Failed to start DanTerm IPC server: \(error)")
        }
    }

    deinit {
        if let monitor = switcherEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        paneTapeFollowTimer?.cancel()
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
        let commands = update(&model, msg)
        // Command-phase split: most commands run before reconcile(); the few that
        // target a view the reconciler creates (Stage 4: only .focusSearchField,
        // whose search field reconcilePaneChrome builds) run after. See
        // Command.isPostReconcile.
        for command in commands where !command.isPostReconcile {
            perform(command)
        }
        let emitsPostReconcile = commands.contains { $0.isPostReconcile }
        switch reconcileDecision(
            for: msg,
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
        if case .appResignedActive = msg {
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

    /// Push effective model visibility to live terminal sessions, skipping unchanged panes.
    func syncSurfaceVisibility() {
        let windowVisible = window?.occlusionState.contains(.visible) ?? true
        let desired = effectiveSurfaceVisibility(in: model, windowVisible: windowVisible)

        for (paneId, session) in surfaces {
            let visible = desired[paneId] ?? true
            if surfaceVisibility[paneId] != visible {
                #if DANTERM_TERMINAL_CHARACTERIZATION
                recordTerminalCharacterizationVisibilityChange(paneId: paneId, visible: visible)
                #endif
                session.setVisible(visible)
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
        for session in surfaces.values {
            session.setDisplayID(displayID)
        }

        // Mirror Ghostty's screen-change path: nudge backing properties on the
        // next main-loop turn because AppKit can skip the automatic callback.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for session in self.surfaces.values {
                session.refreshBackingProperties()
            }
        }
    }

    /// Make the pane first responder; AppKit focus is the reparent/display-link
    /// recovery path for terminal activation.
    /// See docs/design/2026-05-27-terminal-focus-display-link.md.
    func focusPaneSurface(_ paneId: PaneId) {
        guard let session = surfaces[paneId] else { return }
        window?.makeFirstResponder(session.hostView)
    }

    var ipcSocketPath: URL? {
        ipcServer?.socketPath
    }

    func registerIpcConnection(_ connection: IpcConnection, for reqId: UUID) {
        ipcConnections[reqId] = connection
    }

    /// Drops all streams owned by a closed socket before another polling fence can start.
    func ipcConnectionClosed(_ connectionId: UUID) {
        paneTapeFollowSubscriptions.connectionClosed(connectionId)
        paneTapeFollowConnections.removeValue(forKey: connectionId)
        stopPaneTapeFollowTimerIfIdle()
    }

    private func beginPaneTapeFollow(
        reqId: UUID,
        paneId: PaneId,
        fromNow: Bool,
        connection: IpcConnection,
        session: any TerminalSession
    ) {
        guard let prepareStart = session.paneTapeFollowStart(fromNow: fromNow) else {
            connection.writeError(
                reqId: reqId,
                code: -32603,
                message: "pane tape unavailable for this terminal backend"
            )
            return
        }
        let subscriptionId = UUID()
        DispatchQueue.global(qos: .utility).async {
            do {
                let start = try prepareStart()
                connection.writeSuccess(reqId: reqId, result: start.record) { succeeded in
                    DispatchQueue.main.async { [weak self] in
                        self?.finishPaneTapeFollowStart(
                            succeeded: succeeded,
                            subscriptionId: subscriptionId,
                            paneId: paneId,
                            connection: connection,
                            start: start
                        )
                    }
                }
            } catch {
                connection.writeError(
                    reqId: reqId,
                    code: -32603,
                    message: "failed to encode pane tape"
                )
            }
        }
    }

    private func finishPaneTapeFollowStart(
        succeeded: Bool,
        subscriptionId: UUID,
        paneId: PaneId,
        connection: IpcConnection,
        start: PaneTapeFollowStart
    ) {
        guard succeeded else { return }
        guard surfaces[paneId] != nil else {
            writePaneTapeFollowNotification(
                connection: connection,
                subscriptionId: subscriptionId,
                record: makePaneTapeFollowEndRecord(),
                closeAfterWrite: true
            )
            return
        }
        paneTapeFollowConnections[connection.id] = connection
        paneTapeFollowSubscriptions.add(
            id: subscriptionId,
            connectionId: connection.id,
            paneId: paneId.rawValue,
            cursor: start.cursor
        )
        ensurePaneTapeFollowTimer()
    }

    private func ensurePaneTapeFollowTimer() {
        guard paneTapeFollowTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: Self.paneTapeFollowInterval,
            leeway: .milliseconds(10)
        )
        timer.setEventHandler { [weak self] in
            self?.pollPaneTapeFollowers()
        }
        paneTapeFollowTimer = timer
        timer.resume()
    }

    private func stopPaneTapeFollowTimerIfIdle() {
        guard paneTapeFollowSubscriptions.count == 0 else { return }
        paneTapeFollowTimer?.cancel()
        paneTapeFollowTimer = nil
    }

    private func pollPaneTapeFollowers() {
        for fetch in paneTapeFollowSubscriptions.beginFetches() {
            guard let connection = paneTapeFollowConnections[fetch.connectionId] else {
                paneTapeFollowSubscriptions.completeDelivery(
                    subscriptionId: fetch.subscriptionId,
                    succeeded: false
                )
                continue
            }
            let paneId = PaneId(rawValue: fetch.paneId)
            guard let session = surfaces[paneId] else {
                endPaneTapeFollowers(for: paneId)
                continue
            }
            guard let prepareBatch = session.paneTapeFollowBatch(from: fetch.cursor) else {
                paneTapeFollowSubscriptions.completeDelivery(
                    subscriptionId: fetch.subscriptionId,
                    succeeded: false
                )
                paneTapeFollowConnections.removeValue(forKey: connection.id)
                connection.close()
                continue
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    let snapshot = try prepareBatch()
                    let batch = makePaneTapeFollowBatch(from: snapshot)
                    DispatchQueue.main.async { [weak self] in
                        self?.deliverPaneTapeFollowBatch(
                            subscriptionId: fetch.subscriptionId,
                            connection: connection,
                            batch: batch
                        )
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.paneTapeFollowSubscriptions.completeDelivery(
                            subscriptionId: fetch.subscriptionId,
                            succeeded: false
                        )
                        self?.paneTapeFollowConnections.removeValue(forKey: connection.id)
                        self?.stopPaneTapeFollowTimerIfIdle()
                        connection.close()
                    }
                }
            }
        }
        stopPaneTapeFollowTimerIfIdle()
    }

    private func deliverPaneTapeFollowBatch(
        subscriptionId: UUID,
        connection: IpcConnection,
        batch: PaneTapeFollowBatch
    ) {
        guard let accepted = paneTapeFollowSubscriptions.finishFetch(
            subscriptionId: subscriptionId,
            batch: batch
        ) else { return }
        guard accepted.records.isEmpty == false else {
            paneTapeFollowSubscriptions.completeDelivery(
                subscriptionId: subscriptionId,
                succeeded: true
            )
            return
        }

        writePaneTapeFollowRecords(
            accepted.records,
            connection: connection,
            subscriptionId: subscriptionId
        ) { [weak self] succeeded in
            DispatchQueue.main.async { [weak self] in
                self?.paneTapeFollowSubscriptions.completeDelivery(
                    subscriptionId: subscriptionId,
                    succeeded: succeeded
                )
                if succeeded == false {
                    self?.paneTapeFollowConnections.removeValue(forKey: connection.id)
                }
                self?.stopPaneTapeFollowTimerIfIdle()
            }
        }
    }

    private func endPaneTapeFollowers(for paneId: PaneId) {
        for end in paneTapeFollowSubscriptions.paneClosed(paneId.rawValue) {
            guard let connection = paneTapeFollowConnections.removeValue(
                forKey: end.connectionId
            ) else { continue }
            writePaneTapeFollowNotification(
                connection: connection,
                subscriptionId: end.subscriptionId,
                record: end.record,
                closeAfterWrite: true
            )
        }
        stopPaneTapeFollowTimerIfIdle()
    }

    private func writePaneTapeFollowNotification(
        connection: IpcConnection,
        subscriptionId: UUID,
        record: JSONValue,
        closeAfterWrite: Bool
    ) {
        DispatchQueue.global(qos: .utility).async {
            connection.writeNotification(
                method: Methods.paneTapeEvent,
                params: .object([
                    "subscription": .string(subscriptionId.uuidString),
                    "record": record,
                ]),
                closeAfterWrite: closeAfterWrite
            )
        }
    }

    func stopIpcServer() {
        ipcServer?.stop()
        ipcServer = nil
    }

    // MARK: - Command Performer

    private func perform(_ command: Command) {
        switch command {
        case .createSurface(let paneId, let cwd, let command, let launchCommand, let waitAfterCommand):
            let envVars = terminalLaunchEnvironment(
                ipcSocketPath: ipcSocketPath?.path,
                paneId: paneId
            )
            guard let session = makeTerminalSession(
                paneId: paneId,
                workingDirectory: cwd,
                command: command,
                launchCommand: launchCommand,
                waitAfterCommand: waitAfterCommand,
                envVars: envVars,
                themeName: model.pane(paneId).map {
                    effectiveTheme(for: $0, config: model.config)
                },
                fontSize: model.config.resolvedFontSize,
                fontFamily: model.resolvedFontFamily
            ) else {
                send(.surfaceCreationFailed(paneId: paneId))
                break
            }
            surfaces[paneId] = session

        case .sendText(let paneId, let text):
            surfaces[paneId]?.sendText(text)

        case .sendInputText(let paneId, let text):
            surfaces[paneId]?.sendInputText(text)

        case .sendInputKey(let paneId, let key, let mods):
            surfaces[paneId]?.sendInputKey(key, modifiers: mods)

        case .focusSurface(let paneId, let focused):
            surfaces[paneId]?.setFocused(focused)

        case .makeFirstResponder(let paneId):
            if let session = surfaces[paneId] {
                window?.makeFirstResponder(session.hostView)
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
            guard let session = surfaces[paneId] else {
                connection.writeError(reqId: reqId, code: -32603, message: "pane no longer available")
                break
            }
            let raw = lineLimit == nil ? session.readViewportText() : session.readFullHistoryText()
            guard let raw else {
                connection.writeError(reqId: reqId, code: -32603, message: "failed to read pane text")
                break
            }
            let text = lineLimit.map { tailLines(raw, n: $0) } ?? raw
            connection.writeSuccess(reqId: reqId, result: .object(["text": .string(text)]))

        case .dumpPaneTape(let reqId, let paneId):
            guard let connection = ipcConnections.removeValue(forKey: reqId) else { break }
            guard let session = surfaces[paneId] else {
                connection.writeError(reqId: reqId, code: -32603, message: "pane no longer available")
                break
            }
            switch preparePaneTapeDump(encoder: session.flightRecordingEncoder()) {
            case .error(let code, let message):
                connection.writeError(
                    reqId: reqId,
                    code: code,
                    message: message
                )
            case .encode(let encode):
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let data = try encode()
                        let recording = try JSONDecoder().decode(JSONValue.self, from: data)
                        connection.writeSuccess(reqId: reqId, result: recording)
                    } catch {
                        connection.writeError(
                            reqId: reqId,
                            code: -32603,
                            message: "failed to encode pane tape"
                        )
                    }
                }
            }

        case .followPaneTape(let reqId, let paneId, let fromNow):
            guard let connection = ipcConnections.removeValue(forKey: reqId) else { break }
            guard let session = surfaces[paneId] else {
                connection.writeError(
                    reqId: reqId,
                    code: -32603,
                    message: "pane no longer available"
                )
                break
            }
            beginPaneTapeFollow(
                reqId: reqId,
                paneId: paneId,
                fromNow: fromNow,
                connection: connection,
                session: session
            )

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

        case .saveDanTermConfig(let config):
            do {
                try configStore.save(config)
            } catch {
                presentConfigError(error)
            }
            // The save leg of I4. prefSave already committed `config` to the model
            // but could not know whether its family is installed; the resolution
            // follows here so live panes repaint without a reload or restart. Sent
            // even when the write failed, because the running settings still apply.
            send(.fontFamilyResolved(resolveConfiguredFontFamily(config)))

        case .scheduleCheckpoint:
            scheduleDebouncedCheckpoint()

        case .terminate:
            cancelCoalescedReconcile()
            paneTapeFollowTimer?.cancel()
            paneTapeFollowTimer = nil
            paneTapeFollowSubscriptions.removeAll()
            paneTapeFollowConnections.removeAll()
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
            terminalBackend.setAppFocused(focused)

        case .dismissAlertsPopover:
            alertsPopover?.performClose(nil)
            alertsPopover = nil

        // Search commands

        case .sendStartSearch(let paneId):
            surfaces[paneId]?.startSearch()

        case .focusSearchField(let paneId):
            if let field = findPaneWrapper(for: paneId)?.searchOverlay?.searchField {
                window?.makeFirstResponder(field)
            }

        case .sendSearchNeedle(let paneId, let needle):
            // Debounce: immediate for empty or 3+ chars, 300ms for 1-2 chars
            let delay: TimeInterval = (needle.isEmpty || needle.count >= 3) ? 0 : 0.3
            let sendNeedle = { [weak self] in
                guard let self else { return }
                self.surfaces[paneId]?.setSearchNeedle(needle)
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
            surfaces[paneId]?.navigateSearch(direction)

        case .sendEndSearch(let paneId):
            searchDebouncers[paneId]?.cancel()
            searchDebouncers.removeValue(forKey: paneId)
            surfaces[paneId]?.endSearch()

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
                guard isConfirm else { return }
                self?.surfaces[paneId]?.requestClose()
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
        let permitsAuthorizationRequest = notificationAuthorizationPolicy.permitsRequest
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request) { error in
                    if let error {
                        print("Failed to enqueue notification: \(error)")
                    }
                }
            case .notDetermined:
                guard permitsAuthorizationRequest else { return }
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

    /// Write scrollback text to a temp file for shell replay. Returns the file URL.
    private func writeReplayFile(scrollback: String) -> URL? {
        guard let data = scrollback.data(using: .utf8) else { return nil }
        let dir = scrollbackReplayDirectoryURL()
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
        endPaneTapeFollowers(for: paneId)
        cleanupReplayFile(for: paneId)
        searchDebouncers[paneId]?.cancel()
        searchDebouncers.removeValue(forKey: paneId)
        if let session = surfaces.removeValue(forKey: paneId) {
            session.tearDown()
        }
    }

    /// Delete this identity's replay files from prior sessions.
    func cleanupStaleReplayDirectory() {
        cleanupStaleScrollbackReplayDirectory(
            identity: DanTermInstanceIdentity(),
            temporaryDirectory: danTermTemporaryDirectoryURL()
        )
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

    /// Defer the whole-model reconcile() sweep while cosmetic title/cwd/progress,
    /// background alert-badge, and shell command-event messages arrive at high
    /// frequency. The timer reads the latest model when it fires. This is
    /// fixed-window coalescing; use Debouncer for trailing-edge debounce.
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

    /// Starts the temporary repeating Ghostty fallback; Swift schedules from mutations.
    func startEnrichedCheckpointTimer() {
        enrichedCheckpointTimer?.cancel()
        enrichedCheckpointTimer = nil
        guard terminalBackend.recoveryScheduling == .periodicFallback else { return }
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

    /// Fences terminal owners before synchronously capturing the final enriched checkpoint.
    func prepareRecoveryForApplicationExit() {
        enrichedCheckpointTimer?.cancel()
        enrichedCheckpointTimer = nil
        for session in surfaces.values {
            session.fenceForApplicationExit()
        }
        _ = recoveryPolicy.terminate()
        performEnrichedCheckpoint(async: false)
    }

    private func notePrimaryHistoryMutation() {
        guard terminalBackend.recoveryScheduling == .eventDriven else { return }
        applyRecoveryAction(recoveryPolicy.mutation(at: DispatchTime.now().uptimeNanoseconds))
    }

    private func applyRecoveryAction(_ action: RecoveryCheckpointAction) {
        switch action {
        case .none:
            break
        case .schedule(let deadline):
            enrichedCheckpointTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.enrichedCheckpointTimer = nil
                self.applyRecoveryAction(
                    self.recoveryPolicy.deadlineReached(at: deadline)
                )
            }
            timer.resume()
            enrichedCheckpointTimer = timer
        case .write(let revision):
            performEnrichedCheckpoint(async: true) { [weak self] succeeded in
                guard let self else { return }
                self.applyRecoveryAction(
                    self.recoveryPolicy.writeCompleted(
                        revision: revision,
                        succeeded: succeeded,
                        at: DispatchTime.now().uptimeNanoseconds
                    )
                )
            }
        case .cancel:
            enrichedCheckpointTimer?.cancel()
            enrichedCheckpointTimer = nil
        }
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
        for (paneId, session) in surfaces {
            // Read only what the truncation below can keep. Retained history is sized by the
            // pane's whole scrollback budget, so projecting all of it to store this tail made
            // every checkpoint cost the capacity instead of what it writes.
            guard let rawText = session.readPrimaryHistoryTail(
                      maxLines: scrollbackRetentionMaxLines,
                      maxChars: scrollbackRetentionMaxChars
                  ),
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
    func performEnrichedCheckpoint(
        async: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        let enrichedSnapshot = graftScrollback(onto: toSnapshot(model), scrollbackByPaneId: scrollbackByPaneId())
        writeCheckpoint(
            toInitFile(snapshot: enrichedSnapshot),
            to: enrichedCheckpointURL(),
            async: async,
            completion: completion
        )
    }

    /// Encode and atomically write a checkpoint to the given URL.
    /// Uses .sortedKeys for stable output (no .prettyPrinted — this is a machine file).
    private func writeCheckpoint(
        _ initFile: AppInitFile,
        to url: URL,
        async: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        let dir = recoveryDirectoryURL()
        let work = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let succeeded: Bool
            do {
                let data = try encoder.encode(initFile)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                succeeded = true
            } catch {
                succeeded = false
            }
            guard let completion else { return }
            DispatchQueue.main.async {
                completion(succeeded)
            }
        }

        if async {
            Self.checkpointIOQueue.async(execute: work)
        } else {
            Self.checkpointIOQueue.sync(execute: work)
        }
    }

    // MARK: - State Import

    /// Present a file picker, validate the chosen state file, and replace the current session.
    func importStateFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.importState(from: url)
        }
    }

    /// Load a state file from disk, keeping the current session intact on any validation failure.
    func importState(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let loaded = try loadValidatedInitFile(from: data)
            do {
                let staged = try stageValidatedRestore(loaded)
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
        terminalBackend.reloadConfig()
        reloadDanTermConfig()
        send(.ghosttyConfigReloaded)
    }

    /// Re-parse DanTerm-specific config keys and dispatch through the Elm loop.
    func reloadDanTermConfig() {
        do {
            applyDanTermConfig(try configStore.load())
        } catch {
            applyDanTermConfig(.default)
            presentConfigError(error)
        }
    }

    /// Resolve-and-apply (I4): resolve the config's requested font family against
    /// the installed families, then hand config and verdict to the core together
    /// so `model.config` and `model.resolvedFontFamily` cannot drift apart. Launch
    /// assigns the same pair by hand for want of a running Elm loop, and the save
    /// path sends the resolution alone because prefSave already committed the
    /// config; all three go through `resolveConfiguredFontFamily`.
    private func applyDanTermConfig(_ config: DanTermConfig) {
        send(.configLoaded(config, resolvedFontFamily: resolveConfiguredFontFamily(config)))
    }

    // MARK: - Preferences Panel

    /// Show or re-focus the preferences panel. Projects the live JSON config into
    /// the draft, then lets reconcile create/show from the model. The final
    /// makeKeyAndOrderFront call re-raises an already-open normal-level panel.
    func showPreferencesPanel() {
        send(.preferencesOpened(
            ghostty: GhosttyPrefs(
                theme: model.config.defaultTheme,
                fontSize: model.config.fontSize.map(configFontSizeText)
            ),
            // Snapshotted per open (AR1): the core may not query CoreText, and a
            // font installed while the panel sits open is not worth a watcher.
            installedFontFamilies: installedFontFamilyNames()
        ))
        preferencesPanel?.makeKeyAndOrderFront(nil)
    }

    /// Seeds and opens the valid v1 JSON file shared by both config menu entry points.
    func openDanTermConfig() {
        do {
            try configStore.seedIfMissing()
            NSWorkspace.shared.open(configStore.url)
        } catch {
            presentConfigError(error)
        }
    }

    /// Presents a launch-time config failure after AppDelegate has installed the main window.
    func presentPendingConfigError() {
        guard let error = pendingConfigError else { return }
        pendingConfigError = nil
        presentConfigError(error)
    }

    private func presentConfigError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "DanTerm Config Error"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
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
               let session = surfaces[tab.focusedPaneId] {
                window?.makeFirstResponder(session.hostView)
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
    func bootstrapFromSnapshot(_ snapshot: AppModelSnapshot) {
        guard let built = validateAndBuildDetailed(snapshot) else {
            print("[init] Snapshot validation failed, falling back to default startup")
            send(.createTab(inGroupId: nil))
            return
        }
        bootstrapFromValidatedRestore(
            ValidatedAppRestore(snapshot: snapshot, model: built.model, paneSnapshots: built.paneSnapshots)
        )
    }

    /// Stage + commit an already-validated restore (the crash/clean-recovery path,
    /// where main.swift validated and merged the checkpoints up front). Avoids
    /// decoding/validating the recovered structure a second time.
    func bootstrapFromValidatedRestore(_ loaded: ValidatedAppRestore) {
        do {
            let staged = try stageValidatedRestore(loaded)
            commitRestoreSession(staged)
        } catch {
            print("[init] Snapshot surface creation failed, falling back to default startup")
            send(.createTab(inGroupId: nil))
        }
    }

    /// Build all runtime objects for a validated restore without touching the live session.
    private func stageValidatedRestore(_ loaded: ValidatedAppRestore) throws -> StagedRestoreSession {
        var stagedSurfaces: [PaneId: any TerminalSession] = [:]
        var stagedReplayFiles: [PaneId: URL] = [:]

        do {
            for group in loaded.model.groups {
                for tab in group.tabs {
                    for paneId in allPaneIds(tab.rootNode) {
                        let ps = loaded.paneSnapshots[paneId]
                        let resolved = ps.map { resolveLaunch($0) }
                        var scrollbackFilePath: String?
                        if let replayText = recoveryReplayText(scrollback: ps?.scrollback, agentSession: ps?.agentSession),
                           let replayURL = writeReplayFile(scrollback: replayText) {
                            stagedReplayFiles[paneId] = replayURL
                            scrollbackFilePath = replayURL.path
                        }
                        let envVars = restoreLaunchEnvironment(
                            ipcSocketPath: ipcSocketPath?.path,
                            paneId: paneId,
                            scrollbackFilePath: scrollbackFilePath,
                            command: resolved?.command
                        )
                        guard let session = makeTerminalSession(
                            paneId: paneId,
                            workingDirectory: resolved?.cwd,
                            command: nil,
                            launchCommand: nil,
                            waitAfterCommand: true,
                            envVars: envVars,
                            themeName: loaded.model.pane(paneId).map {
                                effectiveTheme(for: $0, config: loaded.model.config)
                            },
                            fontSize: loaded.model.config.resolvedFontSize,
                            fontFamily: loaded.model.resolvedFontFamily
                        ) else {
                            throw RestoreBuildError.surfaceCreationFailed
                        }
                        stagedSurfaces[paneId] = session
                    }
                }
            }

            return StagedRestoreSession(
                model: loaded.model,
                surfaces: stagedSurfaces,
                replayFiles: stagedReplayFiles
            )
        } catch {
            discardRestoreSession(StagedRestoreSession(
                model: loaded.model,
                surfaces: stagedSurfaces,
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
            endPaneTapeFollowers(for: paneId)
            cleanupReplayFile(for: paneId)
            if let session = surfaces.removeValue(forKey: paneId) {
                session.tearDown()
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
    }

    /// Swap a fully staged restore into the live runtime and refresh derived UI state.
    private func commitRestoreSession(_ staged: StagedRestoreSession) {
        tearDownCurrentSession()
        model = staged.model
        surfaces = staged.surfaces
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
        for session in staged.surfaces.values {
            session.tearDown()
        }
        for url in staged.replayFiles.values {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Construct one backend session and install its pane-scoped event translation.
    private func makeTerminalSession(
        paneId: PaneId,
        workingDirectory: String?,
        command: String?,
        launchCommand: String?,
        waitAfterCommand: Bool,
        envVars: [(String, String)],
        themeName: String?,
        fontSize: Double,
        fontFamily: String?
    ) -> (any TerminalSession)? {
        let request = TerminalSessionRequest(
            workingDirectory: workingDirectory,
            command: command,
            launchCommand: launchCommand,
            waitAfterCommand: waitAfterCommand,
            environment: envVars,
            themeName: themeName,
            fontSize: fontSize,
            fontFamily: fontFamily
        )
        guard let session = terminalBackend.createSession(request) else { return nil }
        session.onEvent = { [weak self] event in
            #if DANTERM_TERMINAL_CHARACTERIZATION
            recordTerminalCharacterizationEvent(event)
            #endif
            self?.send(terminalMessage(for: event, paneId: paneId))
        }
        let initialRecoveryCandidate = session.readPrimaryHistoryText() ?? ""
        session.onPrimaryHistoryMutation = { [weak self] in self?.notePrimaryHistoryMutation() }
        if truncateScrollback(initialRecoveryCandidate) != nil {
            notePrimaryHistoryMutation()
        }
        return session
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

    // Resolve via the existing PaneId -> TerminalSession index. `internal` (not `private`)
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
            surfaces[paneId]?.setFocused(false)
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
           let focusedSession = surfaces[focusedId] {
            window?.makeFirstResponder(focusedSession.hostView)
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
