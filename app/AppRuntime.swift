// Runtime bridge that performs update commands and synchronizes the AppKit view tree.
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
    case .bell:
        description = "session.bell"
    case .report(let report):
        description = "session.report:\(String(describing: report))"
    case .desktopNotification(let title, let body):
        description = "session.desktopNotification:\(title):\(body)"
    case .searchStarted(let needle):
        description = "session.searchStarted:\(needle)"
    case .searchTotal(let total):
        description = "session.searchTotal:\(String(describing: total))"
    case .searchSelected(let selected):
        description = "session.searchSelected:\(String(describing: selected))"
    case .becameFirstResponder:
        description = "session.becameFirstResponder"
    case .processStarted:
        description = "session.processStarted"
    case .processExited:
        description = "session.processExited"
    case .processLaunchFailed:
        description = "session.processLaunchFailed"
    case .closeRequested:
        description = "session.closeRequested"
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

/// Holds one follow stream's transport resources, so ending that stream retires exactly its
/// own socket handle, shutdown census entry, and recorder notice -- never a sibling's.
///
/// Deliberately separate from `PaneTapeFollowSubscriptions`: subscriber state and transport
/// have different lifetimes, and the tape broker will keep a cursor across a dropped
/// connection while replacing everything here.
@MainActor
private struct PaneTapeFollowTransport {
    let connection: IpcConnection
    /// Registers the stream in the shutdown census. Its cancel closure closes the socket,
    /// which is right for app teardown and wrong for one stream ending, so every teardown
    /// short of shutdown retires this token with `run` instead of `cancel`.
    let shutdownToken: AppRuntimeSchedulingToken?
    var noticeRegistration: PaneTapeFollowNoticeRegistration?
}

// App runtime owns the mutable app model, performs the commands emitted by the
// pure update function, and bridges model changes into AppKit objects and live sessions.
@MainActor
class AppRuntime {
    private struct StagedRestoreSession {
        let model: AppModel
        let sessions: [PaneId: any TerminalSession]
        let replayFiles: [PaneId: URL]
    }

    var model: AppModel
    private let configStore: DanTermConfigStore
    private let notificationAuthorizationPolicy: NotificationAuthorizationPolicy
    private var pendingConfigError: Error?
    let terminalBackend: SwiftTerminalBackend
    var sessions: [PaneId: any TerminalSession] = [:]
    // Runtime lifetime roots for pane chrome. A container only reparents wrappers.
    var paneHosts: [PaneId: PaneHost] = [:]
    // Last occlusion value pushed for each live session.
    // Cleared on teardown because restore/import can reuse pane IDs for fresh sessions.
    // Cross-file presentation lifecycle forwarding diffs effective visibility here.
    var paneVisibility: [PaneId: Bool] = [:]
    // Kept separate from pane visibility so an occluded wake remains deferred.
    var renderingAvailable = true
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
    /// Reports click-away closure for the cross-file alerts-popover existence pass.
    lazy var alertsPopoverDelegate = AlertsPopoverDelegateAdapter(runtime: self)
    var todoPopover: NSPopover?
    /// Retains the reporting delegate while the projected TODO popover is open.
    var todoPopoverDelegate: TodoPopoverDelegateAdapter?
    // internal (not private): the cross-file reconcileThemeBrowser extension reads it.
    var themeBrowserView: ThemeBrowserView?
    // internal (not private): the cross-file reconcilePreferencesPanel extension reads it.
    var preferencesPanel: PreferencesPanel?
    // internal (not private): the cross-file reconcileConfirmation extension reads it.
    var confirmationPanel: ConfirmationPanel?
    // internal (not private): the cross-file reconcileSwitcher extension reads it.
    var switcherPanel: SwitcherPanel?
    private var switcherEventMonitor: Any?
    private var switcherEventMonitorToken: AppRuntimeSchedulingToken?
    private var dragCoordinator: PaneDragCoordinator?
    private var replayFiles: [PaneId: URL] = [:]
    // Session persistence uses two tiers of checkpoints:
    //   Light  -- model-owned recovery state (no scrollback), written in a fixed
    //            2s coalescing window after the persisted projection changes.
    //   Enriched -- model + primary history, driven by primary-history mutations,
    //               plus one final synchronous clean-exit write.
    private var lightCheckpointTimer: DispatchSourceTimer?
    private var lightCheckpointTimerToken: AppRuntimeSchedulingToken?
    private var lightCheckpointBaseline: LightCheckpointProjection?
    private var enrichedCheckpointTimer: DispatchSourceTimer?  // one owned enriched-checkpoint timer
    private var enrichedCheckpointTimerToken: AppRuntimeSchedulingToken?
    private var recoveryPolicy = RecoveryCheckpointPolicy(
        window: UInt64(600 * NSEC_PER_SEC)
    )
    private var coalescedReconcileTimer: DispatchSourceTimer?   // rate-limited whole-model sweep
    private var coalescedReconcileTimerToken: AppRuntimeSchedulingToken?
    // Serializes checkpoint encode+write work and gives sync flushes one fence for pending I/O.
    private static let checkpointWriter = CheckpointWriter()
    // Export gets its own queue rather than sharing the checkpoint one. Nothing orders an export
    // against a checkpoint -- it goes to a path the user just picked -- and sharing would put a
    // multi-megabyte export inside the fence the quit checkpoint drains, so quitting mid-export
    // would wait on it.
    private static let exportWriter = CheckpointWriter(label: "danterm.export.io")
    private var searchDebouncers: [PaneId: Debouncer] = [:]
    private var searchDebouncerTokens: [PaneId: AppRuntimeSchedulingToken] = [:]
    private var ipcConnections: [UUID: IpcConnection] = [:]
    private var ipcConnectionTokens: [UUID: AppRuntimeSchedulingToken] = [:]
    private var paneTapeFollowSubscriptions = PaneTapeFollowSubscriptions()
    // Keyed by subscription id, like the subscriptions themselves. Anything coarser is shared
    // by sibling streams and cannot be retired one stream at a time.
    private var paneTapeFollowTransports: [UUID: PaneTapeFollowTransport] = [:]
    private var ipcServer: IpcServer?
    private var ipcServerToken: AppRuntimeSchedulingToken?
    private var sessionSubscriptionTokens: [ObjectIdentifier: AppRuntimeSchedulingToken] = [:]
    let schedulingLifecycle = AppRuntimeSchedulingLifecycle()
    private static let checkpointCoalesceInterval: TimeInterval = 2.0
    // Coalescing window for the reconcile pass, sized for its noisiest driver: a
    // shell that rewrites its OSC 0/2 title on every prompt. 75ms still reads as
    // instant to a human, and it collapses a burst of title writes into one chrome
    // update instead of a visible flicker.
    private static let reconcileCoalesceInterval: TimeInterval = 0.075

    init(
        terminalBackend: SwiftTerminalBackend,
        configStore: DanTermConfigStore = DanTermConfigStore(),
        notificationAuthorizationPolicy: NotificationAuthorizationPolicy = .requestIfNeeded,
        startsApplicationServices: Bool = true
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
        self.lightCheckpointBaseline = LightCheckpointProjection(snapshot: toSnapshot(model))

        // Build the MRU switcher panel eagerly — pay first-frame cost at
        // launch instead of on every cmd-shift-i. Keep it offscreen until
        // reconcileSwitcher orders it front (mruCycle becomes non-nil).
        self.switcherPanel = startsApplicationServices ? SwitcherPanel() : nil

        // Install the local NSEvent monitor that drives ephemeral keyboard modes.
        // It reads model flags to know whether a mode is active, but never mutates
        // the model directly; mutations go through send().
        if startsApplicationServices {
            installSwitcherEventMonitor()
        }

        if startsApplicationServices {
            do {
                let server = try IpcServer(socketPath: controlSocketPath(), runtime: self)
                self.ipcServer = server
                self.ipcServerToken = schedulingLifecycle.arm(.ipcServer) {
                    server.stop()
                }
                let startToken = schedulingLifecycle.arm(.deferredCallback, cancel: {})
                Task { [weak self, weak server] in
                    guard let self, let startToken else { return }
                    guard self.schedulingLifecycle.run(startToken, action: {}) else { return }
                    await server?.start()
                }
            } catch {
                self.ipcServer = nil
                print("Failed to start DanTerm IPC server: \(error)")
            }
        }
    }

    deinit {
        // AppDelegate creates, owns, and releases the runtime on the main actor; deinit is
        // nonisolated in this language mode, so encode that owner guarantee for the fallback.
        MainActor.assumeIsolated {
            schedulingLifecycle.shutdown()
        }
    }

    // MARK: - Ephemeral Mode Event Monitor

    private func installSwitcherEventMonitor() {
        guard schedulingLifecycle.isActive else { return }
        let eventHandler: (NSEvent) -> NSEvent? = { [weak self] event in
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
        guard let monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: eventHandler
        ) else { return }
        switcherEventMonitor = monitor
        switcherEventMonitorToken = schedulingLifecycle.arm(.eventMonitor) {
            NSEvent.removeMonitor(monitor)
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
        guard schedulingLifecycle.isActive else { return }
        let commands = update(&model, msg)
        for command in commands {
            perform(command)
        }
        switch reconcileDecision(
            for: msg,
            coalescedSweepPending: coalescedReconcileTimer != nil
        ) {
        case .reconcileNow:
            cancelCoalescedReconcile()
            reconcile()
        case .scheduleCoalesced:
            scheduleCoalescedReconcile()
        case .coalesceIntoPending:
            break
        }
        scheduleLightCheckpointIfNeeded()

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
        (todoPopover?.contentViewController as? TabTodoPopoverViewController)?.closeShortcutHelpPopover()
    }

    /// Close tab-level shortcut help without dismissing the parent todo popover.
    func closeTabTodoShortcutHelpPopover() {
        (todoPopover?.contentViewController as? TabTodoPopoverViewController)?.closeShortcutHelpPopover()
    }

    /// Detach close reporting, dismiss child help, then silently close its parent.
    func dismissTodoPopoverSilently() {
        closeTodoShortcutHelpPopover()
        todoPopover?.delegate = nil
        todoPopoverDelegate = nil
        todoPopover?.performClose(nil)
        todoPopover = nil
    }

    /// Build, configure, and show a transient popover anchored to `anchor`, returning
    /// it so the caller can store it in the retained handle that owns its lifetime.
    /// Callers do their own pre-show VC setup and delegate lifetime management.
    func presentTransientPopover(
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

    /// Re-reads every live session's backing scale after the window changes screens.
    /// Deferred one main-loop turn because AppKit can skip the automatic
    /// backing-properties callback on a screen change.
    func refreshSessionsForScreenChange() {
        guard let callback = captureDeferredCallback({ runtime in
            for session in runtime.sessions.values {
                session.refreshBackingProperties()
            }
        }) else { return }
        DispatchQueue.main.async {
            callback()
        }
    }

    /// Captures one main-actor callback that becomes inert when runtime shutdown wins the race.
    private func captureDeferredCallback(
        _ action: @escaping (AppRuntime) -> Void
    ) -> (() -> Void)? {
        guard let token = schedulingLifecycle.arm(.deferredCallback, cancel: {}) else {
            return nil
        }
        return { [weak self] in
            guard let self else { return }
            self.schedulingLifecycle.run(token) {
                action(self)
            }
        }
    }

    /// Record pane focus selected from AppKit chrome; reconciliation applies it.
    func focusPaneSession(_ paneId: PaneId) {
        send(.paneBecameFirstResponder(paneId: paneId))
    }

    var ipcSocketPath: URL? {
        ipcServer?.socketPath
    }

    func registerIpcConnection(_ connection: IpcConnection, for reqId: UUID) {
        guard schedulingLifecycle.isActive else {
            connection.close()
            return
        }
        ipcConnections[reqId] = connection
        ipcConnectionTokens[reqId] = schedulingLifecycle.arm(.subscription) {
            connection.close()
        }
    }

    /// Drops all streams owned by a closed socket before another append edge can fetch.
    func ipcConnectionClosed(_ connectionId: UUID) {
        guard schedulingLifecycle.isActive else { return }
        let requestIds = ipcConnections.compactMap { reqId, connection in
            connection.id == connectionId ? reqId : nil
        }
        for reqId in requestIds {
            ipcConnections.removeValue(forKey: reqId)
            schedulingLifecycle.cancel(ipcConnectionTokens.removeValue(forKey: reqId))
        }
        for subscriptionId in paneTapeFollowSubscriptions.connectionClosed(connectionId) {
            retirePaneTapeFollowTransport(subscriptionId)
        }
    }

    /// Streams one finite capture: the start record as the reply, then this dump's own gap,
    /// events, and terminator as notifications on the same socket.
    ///
    /// The fence is taken here, once, before any record is built. Everything after it works
    /// from that one copy, so output arriving mid-delivery, or the pane closing outright,
    /// cannot add to or truncate a dump that already stated its boundary. This capture holds
    /// no subscription: its id only routes its records to the socket that asked for them.
    private func dumpPaneTape(
        reqId: UUID,
        connection: IpcConnection,
        session: any TerminalSession
    ) {
        guard schedulingLifecycle.isActive else {
            connection.close()
            return
        }
        guard let prepareDump = session.paneTapeDump() else {
            connection.writeError(
                reqId: reqId,
                code: -32603,
                message: "pane has no terminal to read a tape from"
            )
            return
        }
        let captureId = UUID()
        DispatchQueue.global(qos: .utility).async {
            do {
                let dump = try prepareDump()
                // Both writes are enqueued from this one utility-queue block, so every record
                // is encoded here rather than on the main actor -- a dump can carry the whole
                // retained tape, and the main actor is drawing panes. Order still holds: each
                // call encodes inline and hands its bytes to the connection's serial write
                // queue, so the start record reaches the socket ahead of everything after it.
                connection.writeSuccess(reqId: reqId, result: dump.start.record)
                writePaneTapeRecords(
                    makePaneTapeDumpRecords(after: dump),
                    connection: connection,
                    subscriptionId: captureId
                )
            } catch {
                connection.writeError(
                    reqId: reqId,
                    code: -32603,
                    message: "failed to encode pane tape"
                )
            }
        }
    }

    private func beginPaneTapeFollow(
        reqId: UUID,
        paneId: PaneId,
        fromNow: Bool,
        connection: IpcConnection,
        session: any TerminalSession
    ) {
        guard schedulingLifecycle.isActive else {
            connection.close()
            return
        }
        guard let prepareStart = session.paneTapeFollowStart(fromNow: fromNow) else {
            connection.writeError(
                reqId: reqId,
                code: -32603,
                message: "pane has no terminal to read a tape from"
            )
            return
        }
        let subscriptionId = UUID()
        guard let callbackToken = schedulingLifecycle.arm(.deferredCallback, cancel: {}) else {
            connection.close()
            return
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                let start = try prepareStart()
                connection.writeSuccess(reqId: reqId, result: start.record) { [weak self] succeeded in
                    guard let self else { return }
                    self.schedulingLifecycle.run(callbackToken) {
                        self.finishPaneTapeFollowStart(
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
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.schedulingLifecycle.run(callbackToken, action: {})
                }
            }
        }
    }

    private func finishPaneTapeFollowStart(
        succeeded: Bool,
        subscriptionId: UUID,
        paneId: PaneId,
        connection: IpcConnection,
        start: PaneTapeStart
    ) {
        guard schedulingLifecycle.isActive else { return }
        guard succeeded else { return }
        // The pane went away between the start reply and this callback. The client is owed the
        // same terminator a pane close writes; its socket stays open for its other work.
        guard let session = sessions[paneId] else {
            writePaneTapeRecords(
                [makePaneTapeEndRecord(reason: .paneClosed)],
                connection: connection,
                subscriptionId: subscriptionId
            )
            return
        }
        paneTapeFollowSubscriptions.add(
            id: subscriptionId,
            connectionId: connection.id,
            paneId: paneId.rawValue,
            cursor: start.cursor
        )
        paneTapeFollowTransports[subscriptionId] = PaneTapeFollowTransport(
            connection: connection,
            shutdownToken: schedulingLifecycle.arm(
                .subscription,
                cancel: { connection.close() }
            )
        )
        guard let noticeRegistration = session.addPaneTapeFollowNotice(
            id: subscriptionId,
            cursor: start.cursor,
            // This hop is real, unlike the ones the write completions used to need: the notice
            // fires on the PTY host's owner queue, and that queue has no business learning
            // about the main actor just to save the crossing.
            notify: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.paneTapeFollowEventsAvailable(subscriptionId)
                    }
                }
            }
        ) else {
            failPaneTapeFollow(subscriptionId)
            return
        }
        paneTapeFollowTransports[subscriptionId]?.noticeRegistration = noticeRegistration
    }

    private func paneTapeFollowEventsAvailable(_ subscriptionId: UUID) {
        guard schedulingLifecycle.isActive else { return }
        guard let fetch = paneTapeFollowSubscriptions.eventsAvailable(subscriptionId) else {
            return
        }
        fetchPaneTapeFollow(fetch)
    }

    private func fetchPaneTapeFollow(_ fetch: PaneTapeFollowFetch) {
        guard let connection = paneTapeFollowTransports[fetch.subscriptionId]?.connection else {
            dropPaneTapeFollow(fetch.subscriptionId)
            return
        }
        let paneId = PaneId(rawValue: fetch.paneId)
        guard let session = sessions[paneId] else {
            endPaneTapeFollowers(for: paneId)
            return
        }
        guard let prepareBatch = session.paneTapeFollowBatch(
            subscriptionId: fetch.subscriptionId,
            from: fetch.cursor
        ) else {
            failPaneTapeFollow(fetch.subscriptionId)
            return
        }
        guard let callbackToken = schedulingLifecycle.arm(
            .deferredCallback,
            cancel: {}
        ) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let snapshot = try prepareBatch()
                let batch = makePaneTapeBatch(from: snapshot)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.schedulingLifecycle.run(callbackToken) {
                        self.deliverPaneTapeFollowBatch(
                            subscriptionId: fetch.subscriptionId,
                            connection: connection,
                            batch: batch
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.schedulingLifecycle.run(callbackToken) {
                        self.failPaneTapeFollow(fetch.subscriptionId)
                    }
                }
            }
        }
    }

    private func deliverPaneTapeFollowBatch(
        subscriptionId: UUID,
        connection: IpcConnection,
        batch: PaneTapeBatch
    ) {
        guard schedulingLifecycle.isActive else { return }
        guard let accepted = paneTapeFollowSubscriptions.finishFetch(
            subscriptionId: subscriptionId,
            batch: batch
        ) else { return }
        guard accepted.records.isEmpty == false else {
            if let fetch = paneTapeFollowSubscriptions.completeDelivery(
                subscriptionId: subscriptionId
            ) {
                fetchPaneTapeFollow(fetch)
            }
            return
        }
        guard let callbackToken = schedulingLifecycle.arm(.deferredCallback, cancel: {}) else {
            return
        }

        writePaneTapeRecords(
            accepted.records,
            connection: connection,
            subscriptionId: subscriptionId
        ) { [weak self] succeeded in
            guard let self else { return }
            self.schedulingLifecycle.run(callbackToken) {
                // The transport closed the socket itself on a failed write, so this stream
                // ends at EOF rather than with a record nothing can carry.
                guard succeeded else {
                    self.dropPaneTapeFollow(subscriptionId)
                    return
                }
                if let fetch = self.paneTapeFollowSubscriptions.completeDelivery(
                    subscriptionId: subscriptionId
                ) {
                    self.fetchPaneTapeFollow(fetch)
                }
            }
        }
    }

    /// Ends one stream whose socket is still writable, on an internal failure the client
    /// would otherwise only see as silence.
    private func failPaneTapeFollow(_ subscriptionId: UUID) {
        guard let end = paneTapeFollowSubscriptions.end(
            subscriptionId,
            reason: .streamFailed
        ) else { return }
        writePaneTapeFollowEnd(end)
    }

    /// Retires one stream whose transport is already gone. The peer sees EOF, not an `end`.
    private func dropPaneTapeFollow(_ subscriptionId: UUID) {
        paneTapeFollowSubscriptions.remove(subscriptionId)
        retirePaneTapeFollowTransport(subscriptionId)
    }

    private func endPaneTapeFollowers(for paneId: PaneId) {
        for end in paneTapeFollowSubscriptions.paneClosed(paneId.rawValue) {
            writePaneTapeFollowEnd(end)
        }
    }

    /// Retires one ended stream's transport and writes its terminator on the way out, so the
    /// record goes to that subscription's own socket and lands after every batch already
    /// accepted for it.
    private func writePaneTapeFollowEnd(_ end: PaneTapeFollowEnd) {
        guard let connection = retirePaneTapeFollowTransport(end.subscriptionId) else { return }
        writePaneTapeRecords(
            [end.record],
            connection: connection,
            subscriptionId: end.subscriptionId
        )
    }

    /// Releases exactly one stream's transport resources and hands back its connection, so a
    /// sibling on the same socket or pane keeps its notice, its census entry, and its writes.
    ///
    /// The census token is retired with `run`, not `cancel`: cancelling fires the closure that
    /// closes the socket, and the socket belongs to the client, not to this one stream.
    @discardableResult
    private func retirePaneTapeFollowTransport(_ subscriptionId: UUID) -> IpcConnection? {
        guard let transport = paneTapeFollowTransports.removeValue(
            forKey: subscriptionId
        ) else { return nil }
        transport.noticeRegistration?.cancel()
        if let token = transport.shutdownToken {
            schedulingLifecycle.run(token, action: {})
        }
        return transport.connection
    }

    func stopIpcServer() {
        schedulingLifecycle.cancel(ipcServerToken)
        ipcServerToken = nil
        ipcServer = nil
    }

    /// Transfers one pending IPC request out of the shutdown census before replying.
    private func takeIpcConnection(for reqId: UUID) -> IpcConnection? {
        guard let connection = ipcConnections.removeValue(forKey: reqId) else { return nil }
        if let token = ipcConnectionTokens.removeValue(forKey: reqId) {
            schedulingLifecycle.run(token, action: {})
        }
        return connection
    }

    /// Permanently cancels runtime-owned scheduling without duplicating native PTY teardown.
    func shutdown() {
        guard schedulingLifecycle.isActive else { return }

        for command in update(&model, .runtimeWillShutdown) {
            perform(command)
        }

        // App teardown, not a stream ending: closing the socket is what gives a follower the
        // EOF the CLI contract documents for an abrupt exit.
        for subscriptionId in paneTapeFollowSubscriptions.removeAll() {
            retirePaneTapeFollowTransport(subscriptionId)?.close()
        }
        ipcConnections.removeAll()
        ipcConnectionTokens.removeAll()
        for session in sessions.values {
            session.onEvent = nil
            session.onPrimaryHistoryMutation = nil
        }
        sessionSubscriptionTokens.removeAll()

        schedulingLifecycle.shutdown()

        switcherEventMonitor = nil
        switcherEventMonitorToken = nil
        lightCheckpointTimer = nil
        lightCheckpointTimerToken = nil
        enrichedCheckpointTimer = nil
        enrichedCheckpointTimerToken = nil
        coalescedReconcileTimer = nil
        coalescedReconcileTimerToken = nil
        searchDebouncers.removeAll()
        searchDebouncerTokens.removeAll()
        ipcServer = nil
        ipcServerToken = nil
    }

    // MARK: - Command Performer

    private func perform(_ command: Command) {
        switch command {
        case .createSession(let sessionId, let paneId, let cwd, let command, let launchCommand):
            let envVars = terminalLaunchEnvironment(
                ipcSocketPath: ipcSocketPath?.path,
                paneId: paneId
            )
            guard let session = makeTerminalSession(
                sessionId: sessionId,
                paneId: paneId,
                workingDirectory: cwd,
                command: command,
                launchCommand: launchCommand,
                waitAfterCommand: true,
                envVars: envVars,
                themeName: model.pane(paneId).map {
                    effectiveTheme(for: $0, config: model.config)
                },
                fontSize: model.pane(paneId).map {
                    effectiveFontSize(for: $0, config: model.config)
                } ?? model.config.resolvedFontSize,
                fontFamily: model.resolvedFontFamily
            ) else {
                send(.sessionCreationFailed(sessionId: sessionId))
                break
            }
            installTerminalSession(session, paneId: paneId)

        case .sendText(let paneId, let text, let submissionId):
            guard let submissionId else {
                sessions[paneId]?.sendText(text)
                break
            }
            guard let session = sessions[paneId] else {
                send(.inputSubmissionCompleted(id: submissionId, result: .rejected))
                break
            }
            session.sendText(text) { [weak self] result in
                self?.send(.inputSubmissionCompleted(
                    id: submissionId,
                    result: result == .delivered ? .delivered : .rejected
                ))
            }

        case .sendInputText(let paneId, let text, let submissionId):
            guard let submissionId else {
                sessions[paneId]?.sendInputText(text)
                break
            }
            guard let session = sessions[paneId] else {
                send(.inputSubmissionCompleted(id: submissionId, result: .rejected))
                break
            }
            session.sendInputText(text) { [weak self] result in
                self?.send(.inputSubmissionCompleted(
                    id: submissionId,
                    result: result == .delivered ? .delivered : .rejected
                ))
            }

        case .sendInputKey(let paneId, let key, let mods, let submissionId):
            guard let submissionId else {
                sessions[paneId]?.sendInputKey(key, modifiers: mods)
                break
            }
            guard let session = sessions[paneId] else {
                send(.inputSubmissionCompleted(id: submissionId, result: .rejected))
                break
            }
            session.sendInputKey(key, modifiers: mods) { [weak self] result in
                self?.send(.inputSubmissionCompleted(
                    id: submissionId,
                    result: result == .delivered ? .delivered : .rejected
                ))
            }

        case .focusSession(let paneId, let focused):
            sessions[paneId]?.setFocused(focused)

        case .sendNotification(let alertId, let paneId, let title, let subtitle, let body):
            let content = UNMutableNotificationContent()
            content.title = title.text
            if let subtitle { content.subtitle = subtitle.text }
            content.body = body
            // Stack a chatty pane's banners into one Notification Center entry.
            content.threadIdentifier = paneId.rawValue.uuidString
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
            // Only the capture belongs on the main actor: it fences each pane's scrollback at
            // the moment the user asked to export, and reads nothing. The projection, the
            // pretty-printed encode, and the write all ride the export queue, so picking a file
            // stays responsive no matter how many panes are open.
            let capture = CheckpointCapture(
                snapshot: snapshot,
                scrollbackReads: captureScrollbackReads(keeping: .checkpoint),
                retention: .checkpoint
            )
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "danterm-state.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            guard let window = window else { return }
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                Self.exportWriter.write(
                    to: url,
                    async: true,
                    encode: capture.encoder(prettyPrinted: true)
                ) { outcome in
                    guard case .failed(let description) = outcome else { return }
                    // The writer's completion already arrives a main-queue turn after the sheet
                    // dismissed, so this modal cannot open inside the panel's completion.
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = description
                    alert.runModal()
                }
            }

        case .ipcReply(let reqId, let result):
            guard let connection = takeIpcConnection(for: reqId) else { break }
            connection.writeSuccess(reqId: reqId, result: result)

        case .ipcError(let reqId, let code, let message):
            guard let connection = takeIpcConnection(for: reqId) else { break }
            connection.writeError(reqId: reqId, code: code, message: message)

        case .readDoctorPermissions(let reqId):
            Task { [weak self] in
                let permissions = await DoctorPermissionProber().gather()
                guard let self,
                      let connection = self.takeIpcConnection(for: reqId)
                else { return }
                connection.writeSuccess(reqId: reqId, result: permissions.jsonValue)
            }

        case .readFocusInfo(let reqId):
            guard let connection = takeIpcConnection(for: reqId) else { break }
            connection.writeSuccess(
                reqId: reqId,
                result: paneFocusInfoResult(paneFocusClaimant())
            )

        case .readPaneText(let reqId, let paneId, let lineLimit):
            guard let connection = takeIpcConnection(for: reqId) else { break }
            guard let session = sessions[paneId] else {
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

        case .readPaneRowStructure(let reqId, let paneId):
            guard let connection = takeIpcConnection(for: reqId) else { break }
            guard let session = sessions[paneId] else {
                connection.writeError(reqId: reqId, code: -32603, message: "pane no longer available")
                break
            }
            guard let structure = session.readRowStructure() else {
                connection.writeError(reqId: reqId, code: -32603, message: "failed to read pane rows")
                break
            }
            let rows = structure.map { row in
                JSONValue.object([
                    "index": .number(Double(row.index)),
                    "retained": .bool(row.isRetained),
                    "softWrapped": .bool(row.isSoftWrapped),
                    "contentEnd": .number(Double(row.contentEnd)),
                    "width": .number(Double(row.width)),
                    "marginKind": .string(row.marginKind),
                    "staleWrapClaim": .bool(row.staleWrapClaim),
                ])
            }
            connection.writeSuccess(reqId: reqId, result: .object(["rows": .array(rows)]))

        case .dumpPaneTape(let reqId, let paneId):
            guard let connection = takeIpcConnection(for: reqId) else { break }
            guard let session = sessions[paneId] else {
                connection.writeError(reqId: reqId, code: -32603, message: "pane no longer available")
                break
            }
            dumpPaneTape(reqId: reqId, connection: connection, session: session)

        case .followPaneTape(let reqId, let paneId, let fromNow):
            guard let connection = takeIpcConnection(for: reqId) else { break }
            guard let session = sessions[paneId] else {
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

        case .saveDanTermConfig(let config):
            do {
                try configStore.save(config)
            } catch {
                presentConfigError(error)
            }
            // Complete the save path's coherent config application. prefSave already
            // committed `config` to the model but could not know whether its family is
            // installed; the resolution follows here so live panes repaint without a
            // reload or restart. Sent even when the write failed, because the running
            // settings still apply.
            send(.fontFamilyResolved(resolveConfiguredFontFamily(config)))

        case .terminate:
            // Follow teardown is not repeated here: `NSApp.terminate` reaches
            // `applicationWillTerminate`, and `shutdown()` is its single owner.
            cancelCoalescedReconcile()
            schedulingLifecycle.cancel(lightCheckpointTimerToken)
            lightCheckpointTimerToken = nil
            lightCheckpointTimer = nil
            schedulingLifecycle.cancel(enrichedCheckpointTimerToken)
            enrichedCheckpointTimerToken = nil
            enrichedCheckpointTimer = nil
            for paneId in replayFiles.keys {
                cleanupReplayFile(for: paneId)
            }
            (NSApp.delegate as? AppDelegate)?.quitConfirmed = true
            NSApp.terminate(nil)

        case .activateApp:
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)

        // Search commands

        case .sendStartSearch(let paneId):
            sessions[paneId]?.startSearch()

        case .sendSearchNeedle(let paneId, let needle):
            // Debounce: immediate for empty or 3+ chars, 300ms for 1-2 chars
            let delay: TimeInterval = (needle.isEmpty || needle.count >= 3) ? 0 : 0.3
            let sendNeedle = { [weak self] in
                guard let self else { return }
                self.sessions[paneId]?.setSearchNeedle(needle)
            }

            if delay == 0 {
                schedulingLifecycle.cancel(searchDebouncerTokens.removeValue(forKey: paneId))
                sendNeedle()
            } else {
                let debouncer = searchDebouncers[paneId] ?? {
                    let debouncer = Debouncer(queue: .main)
                    searchDebouncers[paneId] = debouncer
                    return debouncer
                }()
                schedulingLifecycle.cancel(searchDebouncerTokens.removeValue(forKey: paneId))
                debouncer.schedule(after: delay) { [weak self] in
                    guard let self,
                          let token = self.searchDebouncerTokens.removeValue(forKey: paneId)
                    else { return }
                    self.schedulingLifecycle.run(token, action: sendNeedle)
                }
                searchDebouncerTokens[paneId] = schedulingLifecycle.arm(.debouncer) {
                    debouncer.cancel()
                }
            }

        case .sendSearchNavigate(let paneId, let direction):
            sessions[paneId]?.navigateSearch(direction)

        case .sendEndSearch(let paneId):
            schedulingLifecycle.cancel(searchDebouncerTokens.removeValue(forKey: paneId))
            searchDebouncers.removeValue(forKey: paneId)
            sessions[paneId]?.endSearch()

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

    /// Tear down all runtime resources for one pane's session. The former command
    /// executor body is now owned by `reconcileSessionExistence` (which
    /// calls it for every pane absent from `model.allPaneIds`). `internal` so the
    /// cross-file reconcile extension can reach it.
    func tearDownSession(_ paneId: PaneId) {
        endPaneTapeFollowers(for: paneId)
        cleanupReplayFile(for: paneId)
        schedulingLifecycle.cancel(searchDebouncerTokens.removeValue(forKey: paneId))
        searchDebouncers.removeValue(forKey: paneId)
        paneHosts.removeValue(forKey: paneId)
        if let session = sessions.removeValue(forKey: paneId) {
            cancelSessionSubscriptions(session)
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

    /// Arm one bounded light-checkpoint window after persisted state diverges. An existing
    /// window stays fixed so continuous message traffic cannot postpone the write.
    private func scheduleLightCheckpointIfNeeded() {
        guard lightCheckpointTimer == nil,
              schedulingLifecycle.isActive,
              currentLightCheckpointProjection() != lightCheckpointBaseline
        else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.checkpointCoalesceInterval,
            leeway: .milliseconds(200)
        )
        guard let token = schedulingLifecycle.arm(.timer, cancel: { timer.cancel() }) else {
            timer.cancel()
            return
        }
        lightCheckpointTimerToken = token
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lightCheckpointTimer?.cancel()
            self.schedulingLifecycle.run(token) {
                self.lightCheckpointTimer = nil
                self.lightCheckpointTimerToken = nil
                self.performLightCheckpoint(async: true)
            }
        }
        timer.resume()
        lightCheckpointTimer = timer
    }

    /// Defer the whole-model reconcile() sweep while cosmetic title/cwd/progress,
    /// background alert-badge, and shell command-event messages arrive at high
    /// frequency. The timer reads the latest model when it fires. This is
    /// fixed-window coalescing; use Debouncer for trailing-edge debounce.
    private func scheduleCoalescedReconcile() {
        guard coalescedReconcileTimer == nil,
              schedulingLifecycle.isActive
        else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.reconcileCoalesceInterval)
        guard let token = schedulingLifecycle.arm(.timer, cancel: { timer.cancel() }) else {
            timer.cancel()
            return
        }
        coalescedReconcileTimerToken = token
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.coalescedReconcileTimer?.cancel()
            self.schedulingLifecycle.run(token) {
                self.coalescedReconcileTimer = nil
                self.coalescedReconcileTimerToken = nil
                self.reconcile()
            }
        }
        timer.resume()
        coalescedReconcileTimer = timer
    }

    /// Cancel any deferred sweep because an inline reconcile will cover the latest model.
    private func cancelCoalescedReconcile() {
        schedulingLifecycle.cancel(coalescedReconcileTimerToken)
        coalescedReconcileTimerToken = nil
        coalescedReconcileTimer = nil
    }

    /// Close the current light-checkpoint window immediately. Called on appResignedActive
    /// so we do not lose the last 2s of state changes when the user switches away.
    func flushPendingCheckpoint() {
        guard schedulingLifecycle.isActive else { return }
        schedulingLifecycle.cancel(lightCheckpointTimerToken)
        lightCheckpointTimerToken = nil
        lightCheckpointTimer = nil
        performLightCheckpoint(async: false)
    }

    /// Fences terminal owners before synchronously capturing the final enriched checkpoint.
    func prepareRecoveryForApplicationExit() {
        guard schedulingLifecycle.isActive else { return }
        schedulingLifecycle.cancel(enrichedCheckpointTimerToken)
        enrichedCheckpointTimerToken = nil
        enrichedCheckpointTimer = nil
        for session in sessions.values {
            session.fenceForApplicationExit()
        }
        _ = recoveryPolicy.terminate()
        performEnrichedCheckpoint(async: false)
    }

    private func notePrimaryHistoryMutation() {
        guard schedulingLifecycle.isActive else { return }
        applyRecoveryAction(recoveryPolicy.mutation(at: DispatchTime.now().uptimeNanoseconds))
    }

    private func applyRecoveryAction(_ action: RecoveryCheckpointAction) {
        guard schedulingLifecycle.isActive else { return }
        switch action {
        case .none:
            break
        case .schedule(let deadline):
            schedulingLifecycle.cancel(enrichedCheckpointTimerToken)
            enrichedCheckpointTimerToken = nil
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
            guard let token = schedulingLifecycle.arm(.timer, cancel: { timer.cancel() }) else {
                timer.cancel()
                return
            }
            enrichedCheckpointTimerToken = token
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.enrichedCheckpointTimer?.cancel()
                self.schedulingLifecycle.run(token) {
                    self.enrichedCheckpointTimer = nil
                    self.enrichedCheckpointTimerToken = nil
                    self.applyRecoveryAction(
                        self.recoveryPolicy.deadlineReached(at: deadline)
                    )
                }
            }
            timer.resume()
            enrichedCheckpointTimer = timer
        case .write(let revision):
            guard let callbackToken = schedulingLifecycle.arm(
                .deferredCallback,
                cancel: {}
            ) else { return }
            performEnrichedCheckpoint(async: true) { [weak self] outcome in
                // The writer delivers this on the main actor, which owns the recovery state, so
                // the policy update runs in the delivery turn itself -- and the finish time it
                // reads is the delivery moment, with no hop in between to age it.
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                guard let self else { return }
                self.schedulingLifecycle.run(callbackToken) {
                    self.applyRecoveryAction(
                        self.recoveryPolicy.writeCompleted(
                            revision: revision,
                            succeeded: outcome.isSucceeded,
                            at: finishedAt
                        )
                    )
                }
            }
        case .cancel:
            schedulingLifecycle.cancel(enrichedCheckpointTimerToken)
            enrichedCheckpointTimerToken = nil
            enrichedCheckpointTimer = nil
        }
    }

    /// Write the current light projection only when it differs from the last projection handed
    /// to the serial writer. Advancing the baseline at handoff preserves writer order while an
    /// earlier write is still in flight.
    private func performLightCheckpoint(async: Bool) {
        let projection = currentLightCheckpointProjection()
        guard let capture = lightCheckpointCapture(
            current: projection,
            baseline: lightCheckpointBaseline
        ) else {
            if !async { Self.checkpointWriter.drain() }
            return
        }
        lightCheckpointBaseline = projection
        Self.checkpointWriter.write(
            to: lightCheckpointURL(),
            async: async,
            encode: capture.encoder()
        )
    }

    /// Take each live pane's bounded scrollback read without performing it, so the projection
    /// lands on the checkpoint queue. A backend that can only read on the main actor has no
    /// deferred reader and is read here instead, leaving the pipeline downstream uniform.
    private func captureScrollbackReads(
        keeping retention: ScrollbackRetention
    ) -> [PaneId: CheckpointScrollbackRead] {
        var reads: [PaneId: CheckpointScrollbackRead] = [:]
        for (paneId, session) in sessions {
            if let deferred = session.primaryHistoryTailReader() {
                reads[paneId] = deferred
            } else if let text = session.readPrimaryHistoryTail(
                maxLines: retention.maxLines,
                maxChars: retention.maxChars
            ) {
                reads[paneId] = { _ in text }
            }
        }
        return reads
    }

    /// Capture the exact value shared by light scheduling and light encoding.
    private func currentLightCheckpointProjection() -> LightCheckpointProjection {
        LightCheckpointProjection(snapshot: toSnapshot(model))
    }

    /// Take everything an enriched checkpoint needs from live state in one main-actor pass.
    /// Everything after this is a pure function of the returned value, which is what lets the
    /// projection, truncation, graft, and encode run on the checkpoint queue instead of here.
    private func captureEnrichedCheckpoint() -> CheckpointCapture {
        let retention = ScrollbackRetention.checkpoint
        return CheckpointCapture(
            snapshot: toSnapshot(model),
            scrollbackReads: captureScrollbackReads(keeping: retention),
            retention: retention
        )
    }

    /// Write an enriched checkpoint: model snapshot + each pane's primary history. Expensive but
    /// gives full restore fidelity, so only the capture happens here — the cost rides the
    /// checkpoint queue. Called by the mutation-driven policy and once at clean termination.
    /// `completion` is `@MainActor` because the writer always delivers it on the main queue, and
    /// `@Sendable` because the closure reaches the checkpoint queue before it is called back.
    func performEnrichedCheckpoint(
        async: Bool,
        completion: (@MainActor @Sendable (CheckpointWriteOutcome) -> Void)? = nil
    ) {
        guard schedulingLifecycle.isActive else { return }
        let capture = captureEnrichedCheckpoint()
        Self.checkpointWriter.write(
            to: enrichedCheckpointURL(),
            async: async,
            encode: capture.encoder(),
            completion: completion
        )
    }

    // MARK: - State Import

    /// Present a file picker, validate the chosen state file, and replace the current session.
    func importStateFromPanel() {
        guard schedulingLifecycle.isActive else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard let window else { return }
        guard let callbackToken = schedulingLifecycle.arm(
            .deferredCallback,
            cancel: { panel.cancel(nil) }
        ) else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.schedulingLifecycle.run(callbackToken) {
                guard response == .OK, let url = panel.url else { return }
                self.importState(from: url)
            }
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
                showImportError(message: "Import failed while creating terminal sessions.")
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

        let targetIds = allPaneIds(tab.paneTree.root).filter { $0 != paneId }

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

    /// Re-parse DanTerm-specific config keys and dispatch through the Elm loop.
    func reloadDanTermConfig() {
        do {
            applyDanTermConfig(try configStore.load())
        } catch {
            applyDanTermConfig(.default)
            presentConfigError(error)
        }
    }

    /// Resolves the config's requested font family against the installed families,
    /// then hands config and verdict to the core together so every config-apply path
    /// produces coherent config, resolution, warning, and pane state. Launch assigns
    /// the same pair by hand for want of a running Elm loop, and the save path sends
    /// the resolution alone because prefSave already committed the config; launch,
    /// reload, and save all go through `resolveConfiguredFontFamily`.
    private func applyDanTermConfig(_ config: DanTermConfig) {
        send(.configLoaded(config, resolvedFontFamily: resolveConfiguredFontFamily(config)))
    }

    // MARK: - Preferences Panel

    /// Show or re-focus the preferences panel. Projects the live JSON config into
    /// the draft, then lets reconcile create/show from the model. The final
    /// makeKeyAndOrderFront call re-raises an already-open normal-level panel.
    func showPreferencesPanel() {
        send(.preferencesOpened(
            // Snapshot on each open: the pure core may not query CoreText or
            // inspect bundled resources, and neither catalog needs a live watcher.
            installedFontFamilies: installedFontFamilyNames(),
            availableThemeNames: ThemeCatalog.shared.names
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
            reconcilePaneFocus()
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
            send(.createTabInSelectedGroup())
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
            print("[init] Snapshot session creation failed, falling back to default startup")
            send(.createTabInSelectedGroup())
        }
    }

    /// Build all runtime objects for a validated restore without touching the live session.
    private func stageValidatedRestore(_ loaded: ValidatedAppRestore) throws -> StagedRestoreSession {
        var stagedSessions: [PaneId: any TerminalSession] = [:]
        var stagedReplayFiles: [PaneId: URL] = [:]
        // A snapshot carries structure, not appearance, so the rebuilt model arrives
        // with its config and resolved font family at the defaults. Carry the live
        // ones on before anything reads them: sessions below are built from this
        // model, and it is the one commitRestoreSession installs.
        let restoredModel = carryingLiveAppearance(
            loaded.model,
            config: model.config,
            resolvedFontFamily: model.resolvedFontFamily
        )

        do {
            for group in restoredModel.groups {
                for tab in group.tabs {
                    for paneId in allPaneIds(tab.paneTree.root) {
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
                            sessionId: restoredModel.pane(paneId)!.session!.id,
                            paneId: paneId,
                            workingDirectory: resolved?.cwd,
                            command: nil,
                            launchCommand: nil,
                            waitAfterCommand: true,
                            envVars: envVars,
                            themeName: restoredModel.pane(paneId).map {
                                effectiveTheme(for: $0, config: restoredModel.config)
                            },
                            fontSize: restoredModel.pane(paneId).map {
                                effectiveFontSize(for: $0, config: restoredModel.config)
                            } ?? restoredModel.config.resolvedFontSize,
                            fontFamily: restoredModel.resolvedFontFamily
                        ) else {
                            throw RestoreBuildError.sessionCreationFailed
                        }
                        stagedSessions[paneId] = session
                    }
                }
            }

            return StagedRestoreSession(
                model: restoredModel,
                sessions: stagedSessions,
                replayFiles: stagedReplayFiles
            )
        } catch {
            discardRestoreSession(StagedRestoreSession(
                model: restoredModel,
                sessions: stagedSessions,
                replayFiles: stagedReplayFiles
            ))
            throw error
        }
    }

    /// Tear down live runtime resources before swapping in a replacement session.
    private func tearDownCurrentSession() {
        cancelPaneDrag()
        dismissTodoPopoverSilently()
        dismissAlertsPopoverSilently()
        model.todoPopover = nil  // session teardown bypasses the reconciler; clear directly
        // Hide/destroy before resetting caches so nil keeps meaning "already hidden"
        // for the first post-restore reconcile. Restored models carry no draft.
        preferencesPanel?.close()
        preferencesPanel = nil
        confirmationPanel?.orderOut(nil)
        confirmationPanel = nil

        for tabId in Array(tabContainers.keys) {
            removeTabContainer(tabId)
        }

        for paneId in Array(sessions.keys) {
            endPaneTapeFollowers(for: paneId)
            cleanupReplayFile(for: paneId)
            paneHosts.removeValue(forKey: paneId)
            if let session = sessions.removeValue(forKey: paneId) {
                cancelSessionSubscriptions(session)
                session.tearDown()
            }
        }
        paneVisibility.removeAll()
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
        sessions = staged.sessions
        paneHosts = Dictionary(uniqueKeysWithValues: staged.sessions.map { paneId, session in
            (paneId, PaneHost(paneId: paneId, session: session, runtime: self))
        })
        replayFiles = staged.replayFiles
        lightCheckpointBaseline = currentLightCheckpointProjection()
        cancelCoalescedReconcile()

        // Restore bypasses update(); reconcile MRU here so the first
        // cmd-shift-i after a restore sees a populated mruOrder.
        reconcileMru(&model)

        // Drive the entire post-restore UI through reconcile() (clean build:
        // tearDownCurrentSession reset the caches). reconcileContainers builds every
        // tab's container eagerly from the nil containerShape cache -- selected visible,
        // the rest mounted+hidden -- and the chrome/sidebar/window passes build from
        // scratch. reconcileSessionExistence is a no-op (staged sessions match allPaneIds).
        reconcile()

    }

    /// Dispose of a staged restore after a failed build so no temp state leaks into the live session.
    private func discardRestoreSession(_ staged: StagedRestoreSession) {
        for session in staged.sessions.values {
            cancelSessionSubscriptions(session)
            session.tearDown()
        }
        for url in staged.replayFiles.values {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Construct one backend session and install its pane-scoped event translation.
    private func makeTerminalSession(
        sessionId: SessionId,
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
            localeFallbackEnabled: model.config.localeFallback,
            themeName: themeName,
            fontSize: fontSize,
            fontFamily: fontFamily
        )
        guard let session = terminalBackend.createSession(request) else { return nil }
        session.onEvent = { [weak self, weak session] event in
            #if DANTERM_TERMINAL_CHARACTERIZATION
            recordTerminalCharacterizationEvent(event)
            #endif
            guard let self, let session else { return }
            withExtendedLifetime(session) {
                for message in terminalMessages(
                    for: event,
                    sessionId: sessionId,
                    paneId: paneId
                ) {
                    self.send(message)
                }
            }
        }
        let initialRecoveryCandidate = session.readPrimaryHistoryText() ?? ""
        session.onPrimaryHistoryMutation = { [weak self] in self?.notePrimaryHistoryMutation() }
        if let token = schedulingLifecycle.arm(.subscription, cancel: {
            session.onEvent = nil
            session.onPrimaryHistoryMutation = nil
        }) {
            sessionSubscriptionTokens[ObjectIdentifier(session)] = token
        }
        session.setRenderingAvailable(renderingAvailable)
        if hasCheckpointableScrollback(initialRecoveryCandidate) {
            notePrimaryHistoryMutation()
        }
        return session
    }

    /// Disconnects the two callbacks that let a terminal session schedule runtime work.
    private func cancelSessionSubscriptions(_ session: any TerminalSession) {
        let key = ObjectIdentifier(session)
        schedulingLifecycle.cancel(sessionSubscriptionTokens.removeValue(forKey: key))
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

    // MARK: - Pane Toolbars

    /// Installs one session and its runtime-owned wrapper host as a single lifetime unit.
    private func installTerminalSession(_ session: any TerminalSession, paneId: PaneId) {
        sessions[paneId] = session
        paneHosts[paneId] = PaneHost(paneId: paneId, session: session, runtime: self)
    }

    /// Returns the persistent pane host, lazily covering test-injected sessions.
    func paneHost(for paneId: PaneId) -> PaneHost? {
        if let host = paneHosts[paneId] { return host }
        guard let session = sessions[paneId] else { return nil }
        let host = PaneHost(paneId: paneId, session: session, runtime: self)
        paneHosts[paneId] = host
        return host
    }

    // Resolve through the runtime-owned host so wrapper identity does not depend on
    // which container currently parents it.
    func findPaneWrapper(for paneId: PaneId) -> PaneWrapperView? {
        paneHost(for: paneId)?.wrapper
    }

    // MARK: - View Building

    /// Build a split container for one tab and insert it below the theme browser overlay.
    /// `internal` so the cross-file reconcileContainers executor can build a container.
    func buildAndInsertContainer(for tab: TabModel) -> SplitContainerView {
        guard let contentArea = contentArea else { fatalError("contentArea unavailable") }
        let container = SplitContainerView(
            rootNode: tab.paneTree.root,
            wrapperLookup: { [weak self] paneId in self?.paneHost(for: paneId)?.wrapper },
            runtime: self,
            frame: contentArea.bounds
        )
        container.autoresizingMask = [.width, .height]
        if let browser = themeBrowserView {
            contentArea.addSubview(container, positioned: .below, relativeTo: browser)
        } else {
            contentArea.addSubview(container)
        }
        container.rebuild()
        container.setZoomedPane(tab.paneTree.isZoomed ? tab.paneTree.focusedPaneId : nil)
        tabContainers[tab.id] = container
        return container
    }

    /// Detach and forget the cached container for a removed tab. `internal` so the
    /// cross-file reconcileContainers executor (and tearDownCurrentSession) can call it.
    func removeTabContainer(_ tabId: TabId) {
        guard let container = tabContainers.removeValue(forKey: tabId) else { return }
        container.removeFromSuperview()
    }

    /// Detaches close reporting before reconciliation closes the alerts popover.
    func dismissAlertsPopoverSilently() {
        alertsPopover?.delegate = nil
        alertsPopover?.performClose(nil)
        alertsPopover = nil
    }
}

/// Reports AppKit-initiated alerts-popover closure back to the model slot.
final class AlertsPopoverDelegateAdapter: NSObject, NSPopoverDelegate {
    weak var runtime: AppRuntime?

    init(runtime: AppRuntime?) {
        self.runtime = runtime
    }

    /// NSPopoverDelegate: click-away clears projected existence through update().
    func popoverDidClose(_ notification: Notification) {
        runtime?.send(.alertsPopoverClosed)
    }
}

/// NSPopoverDelegate adapter shared by pane- and tab-owned TODO popovers.
/// Sends .todoPopoverClosed when the popover closes for any reason (click-away,
/// programmatic, etc.) so model.todoPopover stays in sync.
final class TodoPopoverDelegateAdapter: NSObject, NSPopoverDelegate {
    weak var runtime: AppRuntime?
    let owner: TodoOwner
    init(owner: TodoOwner, runtime: AppRuntime?) {
        self.owner = owner
        self.runtime = runtime
    }
    /// NSPopoverDelegate: cascade-close shortcut help before the parent closes.
    func popoverWillClose(_ notification: Notification) {
        runtime?.closeTodoShortcutHelpPopover()
    }
    /// NSPopoverDelegate: keep model.todoPopover in sync after any close path.
    func popoverDidClose(_ notification: Notification) {
        runtime?.send(.todoPopoverClosed(owner: owner))
    }
}

private enum RestoreBuildError: Error {
    case sessionCreationFailed
}
