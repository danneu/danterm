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
    case .clickedToFocus:
        description = "session.clickedToFocus"
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
    let policy: PaneTapeSyncPolicy
    /// Registers the stream in the shutdown census. Its cancel closure closes the socket,
    /// which is right for app teardown and wrong for one stream ending, so every teardown
    /// short of shutdown retires this token with `run` instead of `cancel`.
    let shutdownToken: AppRuntimeSchedulingToken?
    var noticeRegistration: PaneTapeFollowNoticeRegistration?
}

/// Holds one roster subscriber's socket and its shutdown census entry.
///
/// Keyed by connection id wherever it is stored, which is what makes a subscription
/// connection-scoped and a repeat subscribe idempotent: there is nowhere to put a
/// second one.
@MainActor
private struct RosterSubscriber {
    let connection: IpcConnection
    /// Registers the subscriber in the shutdown census. Its cancel closure closes the
    /// socket, which is right for app teardown and wrong for a connection that has
    /// already gone, so `ipcConnectionClosed` retires this token with `run` instead.
    let shutdownToken: AppRuntimeSchedulingToken
}

// App runtime owns the mutable app model, performs the commands emitted by the
// pure update function, and bridges model changes into AppKit objects and live sessions.
@MainActor
class AppRuntime {
    /// A restore built whole but not yet live. Its panes are finished records, so committing
    /// is a table swap and discarding is the same per-record teardown a live pane gets.
    private struct StagedRestoreSession {
        let model: AppModel
        let hosts: [PaneId: PaneHost]
    }

    var model: AppModel
    private let configStore: DanTermConfigStore
    private let ports: AppRuntimePorts
    private var pendingConfigError: Error?
    // The one pane-keyed table of live panes. Each record owns everything whose lifetime
    // is the pane's -- session, pane chrome, pushed visibility, replay file, search
    // debounce, session subscription -- so a container only reparents wrappers and
    // nothing else indexes a pane. `private(set)` because installing and removing a pane
    // are the only ways to write it -- see `installPane` and `tearDownSession`, plus the
    // restore commit, which installs a whole staged table into an emptied one.
    private(set) var paneHosts: [PaneId: PaneHost] = [:]
    // Kept separate from pane visibility so an occluded wake remains deferred.
    var renderingAvailable = true
    // Per-pass diff caches for the view reconciler (see Reconcile.swift).
    // Reset on teardown so a post-restore reconcile is a clean build.
    var caches = ReconcilerCaches()
    // The sidebar owns an ordered row-op pipeline and therefore keeps its cache
    // with the pipeline driver rather than in the generic reconciler cache bag.
    var sidebarReconcileDriver = SidebarReconcileDriver()
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
    // The one channel a view reports a discovered fact through. Owned here because
    // the runtime is what opens a send frame and what dispatches a released fact,
    // and because it has to outlive every view that reports into it.
    let outbox = ReconcileOutbox()
    // Serializes checkpoint encode+write work and gives sync flushes one fence for pending I/O.
    private let checkpointWriter = CheckpointWriter()
    // Export gets its own queue rather than sharing the checkpoint one. Nothing orders an export
    // against a checkpoint -- it goes to a path the user just picked -- and sharing would put a
    // multi-megabyte export inside the fence the quit checkpoint drains, so quitting mid-export
    // would wait on it.
    private let exportWriter = CheckpointWriter(label: "danterm.export.io")
    private var ipcConnections: [UUID: IpcRequestTransport] = [:]
    private var ipcConnectionTokens: [UUID: AppRuntimeSchedulingToken] = [:]
    private var paneTapeFollowSubscriptions = PaneTapeFollowSubscriptions()
    // Keyed by subscription id, like the subscriptions themselves. Anything coarser is shared
    // by sibling streams and cannot be retired one stream at a time.
    private var paneTapeFollowTransports: [UUID: PaneTapeFollowTransport] = [:]
    // Keyed by connection id: one subscription per connection, and a repeat subscribe
    // replaces the entry rather than adding a second push target.
    private var rosterSubscribers: [UUID: RosterSubscriber] = [:]
    // The last roster a reconcile projected -- never the last one a subscriber was
    // handed. A bootstrap reply must not advance it, or a change a pending sweep still
    // owes the existing subscribers would be swallowed by a newcomer's reply.
    private var rosterBaseline = PaneRoster(panes: [])
    private var ipcServer: IpcServer?
    private var ipcServerToken: AppRuntimeSchedulingToken?
    let schedulingLifecycle = AppRuntimeSchedulingLifecycle()
    private static let checkpointCoalesceInterval: TimeInterval = 2.0
    // Coalescing window for the reconcile pass, sized for its noisiest driver: a
    // shell that rewrites its OSC 0/2 title on every prompt. 75ms still reads as
    // instant to a human, and it collapses a burst of title writes into one chrome
    // update instead of a visible flicker.
    private static let reconcileCoalesceInterval: TimeInterval = 0.075

    init(
        ports: AppRuntimePorts,
        configStore: DanTermConfigStore = DanTermConfigStore(),
        startsApplicationServices: Bool = true,
        tailnetOptIn: Bool = false
    ) {
        self.ports = ports
        self.configStore = configStore
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
        self.rosterBaseline = paneRoster(in: model)

        // Weak on purpose: the runtime owns the outbox, and a drain scheduled on
        // the main queue must be inert once the runtime is gone.
        outbox.setDispatcher { [weak self] msg in self?.dispatch(msg) }

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
                let server = try IpcServer(
                    socketPath: controlSocketPath(),
                    tailnetConfig: launchConfig.tailnet,
                    tailnetOptIn: tailnetOptIn,
                    runtimeDispatch: makeIpcDispatch()
                )
                self.ipcServer = server
                // Assigned rather than sent, like the config above: the Elm loop is not
                // running yet, and a preferences pane opened before the first transition
                // must not read a default as if it were this instance's verdict.
                self.model.tailnetStatus = server.initialTailnetStatus
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
        dispatch(msg)
    }

    /// One send frame: translate, perform, sweep, then deliver what the frame
    /// collected. Anything reported while the frame is open -- by a pass, or by a
    /// view whose teardown AppKit ran mid-sweep -- waits for the outermost frame to
    /// close, which is what stops it from re-entering a pass against a stale
    /// projection cache.
    private func dispatch(_ msg: Msg) {
        guard schedulingLifecycle.isActive else { return }
        outbox.withFrame { dispatchInFrame(msg) }
    }

    /// The body of one send frame. Split out so the frame bracket reads as one
    /// line; it has no other caller.
    private func dispatchInFrame(_ msg: Msg) {
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
            pushRosterIfChanged()
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

    /// Runs a whole-model sweep outside `send()` -- the coalesced timer and the
    /// post-restore commit -- and delivers what the sweep reported. The sweep runs
    /// outside any send frame on purpose: nothing may drain while it is in flight,
    /// which is why a report never drains on its own stack.
    private func sweepAndDispatchFollowUps() {
        reconcile()
        pushRosterIfChanged()
        outbox.drain()
    }

    /// Sends the roster to every subscriber when it moved since the last reconcile, then
    /// advances the baseline.
    ///
    /// The baseline advances whether or not anyone is subscribed, so the first roster a
    /// later subscriber is pushed describes a change that happened while it was
    /// listening -- it already has everything before that from its subscribe reply.
    private func pushRosterIfChanged() {
        guard schedulingLifecycle.isActive else { return }
        let roster = paneRoster(in: model)
        guard roster != rosterBaseline else { return }
        rosterBaseline = roster
        guard rosterSubscribers.isEmpty == false else { return }
        let params = roster.jsonValue
        for subscriber in rosterSubscribers.values {
            subscriber.connection.writeNotification(
                method: Methods.rosterEvent,
                params: params
            )
        }
    }

    /// Answers a roster subscribe on its own connection and keeps that connection as a
    /// push target until it closes.
    ///
    /// Deliberately does not touch `rosterBaseline`: the reply is this caller's whole
    /// starting picture, and moving the baseline here would tell every other subscriber
    /// that a change they have not seen yet has already been delivered.
    private func subscribeToRoster(reqId: UUID, roster: PaneRoster) {
        guard let transport = takeIpcConnection(for: reqId) else { return }
        guard schedulingLifecycle.isActive else {
            transport.close()
            return
        }
        let connection = transport.connection
        transport.writeSuccess(reqId: reqId, result: roster.jsonValue)
        if let existing = rosterSubscribers.removeValue(forKey: connection.id) {
            schedulingLifecycle.run(existing.shutdownToken, action: {})
        }
        guard let token = schedulingLifecycle.arm(.subscription, cancel: {
            connection.close()
        }) else {
            connection.close()
            return
        }
        rosterSubscribers[connection.id] = RosterSubscriber(
            connection: connection,
            shutdownToken: token
        )
    }

    /// Close a todo popover's shortcut help without dismissing the popover itself.
    /// One controller serves every todo scope, so one cast covers pane and tab alike.
    func closeTodoShortcutHelpPopover() {
        (todoPopover?.contentViewController as? TodoPopoverApplying)?.closeShortcutHelpPopover()
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

    /// Re-checks every live session's presentation inputs after the window changes
    /// screens -- the backing scale and the window's color space alike. Deferred one
    /// main-loop turn because AppKit can skip the automatic backing-properties
    /// callback on a screen change.
    func refreshSessionsForScreenChange() {
        guard let callback = captureDeferredCallback({ runtime in
            for host in runtime.paneHosts.values {
                host.session.refreshPresentation()
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

    /// Builds the IPC server's view of this runtime: main-actor closures over a weak self.
    ///
    /// Handing the server this instead of `self` is what keeps the runtime's last release on
    /// the main actor. The server owns no runtime reference to drop, so no request in flight
    /// can make the server's own executor the one that destroys a main-actor object.
    func makeIpcDispatch() -> AppRuntimeIpcDispatch {
        AppRuntimeIpcDispatch(
            serve: { [weak self] connection, reqId, audit, message in
                guard let self else { return }
                self.registerIpcConnection(connection, for: reqId, audit: audit)
                self.send(message)
            },
            connectionClosed: { [weak self] connectionId in
                self?.ipcConnectionClosed(connectionId)
            },
            tailnetStatusChanged: { [weak self] status in
                self?.send(.tailnetStatusChanged(status))
            }
        )
    }

    func registerIpcConnection(
        _ connection: IpcConnection,
        for reqId: UUID,
        audit: IpcRequestAudit? = nil
    ) {
        guard schedulingLifecycle.isActive else {
            connection.close()
            return
        }
        ipcConnections[reqId] = IpcRequestTransport(connection: connection, audit: audit)
        ipcConnectionTokens[reqId] = schedulingLifecycle.arm(.subscription) {
            connection.close()
        }
    }

    /// Drops all streams owned by a closed socket before another append edge can fetch.
    func ipcConnectionClosed(_ connectionId: UUID) {
        guard schedulingLifecycle.isActive else { return }
        let requestIds = ipcConnections.compactMap { reqId, transport in
            transport.id == connectionId ? reqId : nil
        }
        for reqId in requestIds {
            ipcConnections.removeValue(forKey: reqId)
            schedulingLifecycle.cancel(ipcConnectionTokens.removeValue(forKey: reqId))
        }
        for subscriptionId in paneTapeFollowSubscriptions.connectionClosed(connectionId) {
            retirePaneTapeFollowTransport(subscriptionId)
        }
        // Retired with `run`, not `cancel`: the socket this token would close is the one
        // that just went away, and cancelling a sibling's is what this key prevents.
        if let subscriber = rosterSubscribers.removeValue(forKey: connectionId) {
            schedulingLifecycle.run(subscriber.shutdownToken, action: {})
        }
    }

    /// Streams one finite capture: the start record as the reply, then this dump's own gap,
    /// events, and terminator as notifications on the same socket.
    ///
    /// The fence is taken here, once, before any record is built. Everything after it works
    /// from that one copy, so output arriving mid-delivery, or the pane closing outright,
    /// cannot add to or truncate a dump that already stated its boundary. This capture holds
    /// no subscription: its id only routes its records to the socket that asked for them.
    private func streamFinitePaneTape(
        reqId: UUID,
        connection: IpcRequestTransport,
        session: any TerminalSession,
        capture: PaneTapeCaptureMode,
        start: PaneTapeStartPosition,
        policy: PaneTapeSyncPolicy
    ) {
        guard schedulingLifecycle.isActive else {
            connection.close()
            return
        }
        guard let prepareOpening = session.paneTapeOpening(
            capture: capture,
            start: start,
            policy: policy
        ) else {
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
                let opening = try prepareOpening()
                // Both writes are enqueued from this one utility-queue block, so every record
                // is encoded here rather than on the main actor -- a dump can carry the whole
                // retained tape, and the main actor is drawing panes. Order still holds: each
                // call encodes inline and hands its bytes to the connection's serial write
                // queue, so the start record reaches the socket ahead of everything after it.
                connection.writeSuccess(
                    reqId: reqId,
                    result: PaneTapeOutgoingRecord<JSONValue>.start(opening.start.record)
                )
                let endReason: PaneTapeEndReason = capture == .snapshot
                    ? .snapshotComplete
                    : .dumpComplete
                writePaneTapeRecords(
                    opening.records + [.end(reason: endReason)],
                    connection: connection.connection,
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
        start: PaneTapeStartPosition,
        policy: PaneTapeSyncPolicy,
        connection: IpcRequestTransport,
        session: any TerminalSession
    ) {
        guard schedulingLifecycle.isActive else {
            connection.close()
            return
        }
        guard let prepareOpening = session.paneTapeOpening(
            capture: .follow,
            start: start,
            policy: policy
        ) else {
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
                let opening = try prepareOpening()
                connection.writeSuccess(
                    reqId: reqId,
                    result: PaneTapeOutgoingRecord<JSONValue>.start(opening.start.record)
                ) { [weak self] succeeded in
                    guard let self else { return }
                    self.schedulingLifecycle.run(callbackToken) {
                        self.finishPaneTapeFollowStart(
                            succeeded: succeeded,
                            subscriptionId: subscriptionId,
                            paneId: paneId,
                            connection: connection.connection,
                            opening: opening,
                            policy: policy
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
        opening: PaneTapeOpening<PaneTapeSessionEvent>,
        policy: PaneTapeSyncPolicy
    ) {
        guard schedulingLifecycle.isActive else { return }
        guard succeeded else { return }
        // The pane went away between the start reply and this callback. The client is owed the
        // same terminator a pane close writes; its socket stays open for its other work.
        guard let session = paneSession(for: paneId) else {
            writePaneTapeRecords(
                [PaneTapeOutgoingRecord<PaneTapeSessionEvent>.end(reason: .paneClosed)],
                connection: connection,
                subscriptionId: subscriptionId
            )
            return
        }
        paneTapeFollowSubscriptions.add(
            id: subscriptionId,
            connectionId: connection.id,
            paneId: paneId.rawValue,
            cursor: opening.nextCursor,
            replicaHistoryIsComplete: opening.replicaHistoryIsComplete,
            isDeliveringOpening: opening.records.isEmpty == false
        )
        paneTapeFollowTransports[subscriptionId] = PaneTapeFollowTransport(
            connection: connection,
            policy: policy,
            shutdownToken: schedulingLifecycle.arm(
                .subscription,
                cancel: { connection.close() }
            )
        )
        guard let noticeRegistration = session.addPaneTapeFollowNotice(
            id: subscriptionId,
            cursor: opening.nextCursor,
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
        guard opening.records.isEmpty == false else { return }
        guard let callbackToken = schedulingLifecycle.arm(.deferredCallback, cancel: {}) else {
            dropPaneTapeFollow(subscriptionId)
            return
        }
        writePaneTapeRecords(
            opening.records,
            connection: connection,
            subscriptionId: subscriptionId
        ) { [weak self] succeeded in
            guard let self else { return }
            self.schedulingLifecycle.run(callbackToken) {
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

    private func paneTapeFollowEventsAvailable(_ subscriptionId: UUID) {
        guard schedulingLifecycle.isActive else { return }
        guard let fetch = paneTapeFollowSubscriptions.eventsAvailable(subscriptionId) else {
            return
        }
        fetchPaneTapeFollow(fetch)
    }

    private func fetchPaneTapeFollow(_ fetch: PaneTapeFollowFetch) {
        guard let transport = paneTapeFollowTransports[fetch.subscriptionId] else {
            dropPaneTapeFollow(fetch.subscriptionId)
            return
        }
        let connection = transport.connection
        let paneId = PaneId(rawValue: fetch.paneId)
        guard let session = paneSession(for: paneId) else {
            endPaneTapeFollowers(for: paneId)
            return
        }
        guard let prepareBatch = session.paneTapeFollowBatch(
            subscriptionId: fetch.subscriptionId,
            from: fetch.cursor,
            policy: transport.policy,
            replicaHistoryIsComplete: fetch.replicaHistoryIsComplete
        ) else {
            failPaneTapeFollow(fetch.subscriptionId)
            return
        }
        guard let callbackToken = schedulingLifecycle.arm(
            .deferredCallback,
            cancel: {}
        ) else { return }
        DispatchQueue.global(qos: .utility).async {
            let continuation = prepareBatch()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.schedulingLifecycle.run(callbackToken) {
                    self.deliverPaneTapeFollowBatch(
                        subscriptionId: fetch.subscriptionId,
                        connection: connection,
                        continuation: continuation
                    )
                }
            }
        }
    }

    private func deliverPaneTapeFollowBatch(
        subscriptionId: UUID,
        connection: IpcConnection,
        continuation: PaneTapeContinuation<PaneTapeSessionEvent>
    ) {
        guard schedulingLifecycle.isActive else { return }
        guard let accepted = paneTapeFollowSubscriptions.finishFetch(
            subscriptionId: subscriptionId,
            continuation: continuation
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
            [PaneTapeOutgoingRecord<PaneTapeSessionEvent>.end(reason: end.reason)],
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
    private func takeIpcConnection(for reqId: UUID) -> IpcRequestTransport? {
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
        for subscriber in rosterSubscribers.values {
            schedulingLifecycle.run(subscriber.shutdownToken, action: {})
            subscriber.connection.close()
        }
        rosterSubscribers.removeAll()
        ipcConnections.removeAll()
        ipcConnectionTokens.removeAll()
        for host in paneHosts.values {
            host.session.onEvent = nil
            host.session.onPrimaryHistoryMutation = nil
        }

        // Pane-owned scheduling -- each record's session subscription and its armed search
        // debounce -- is registered in the census, so this one walk retires it.
        schedulingLifecycle.shutdown()

        switcherEventMonitor = nil
        switcherEventMonitorToken = nil
        lightCheckpointTimer = nil
        lightCheckpointTimerToken = nil
        enrichedCheckpointTimer = nil
        enrichedCheckpointTimerToken = nil
        coalescedReconcileTimer = nil
        coalescedReconcileTimerToken = nil
        ipcServer = nil
        ipcServerToken = nil
    }

    // MARK: - Command Performer

    func perform(_ command: Command) {
        switch command {
        case .createSession(let sessionId, let paneId, let cwd, let command, let launchCommand):
            let envVars = terminalLaunchEnvironment(
                ipcSocketPath: ipcSocketPath?.path,
                paneId: paneId
            )
            guard let host = makeTerminalSession(
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
                fontFamily: model.resolvedFontFamily,
                gridOverride: model.pane(paneId)?.gridOverride
            ) else {
                send(.sessionCreationFailed(sessionId: sessionId))
                break
            }
            installPane(host, paneId: paneId)

        case .sendText(let paneId, let text, let submissionId, let waitGeneration):
            guard let submissionId else {
                paneSession(for: paneId)?.sendText(text, waitGeneration: waitGeneration)
                break
            }
            guard let session = paneSession(for: paneId) else {
                send(.inputSubmissionCompleted(id: submissionId, result: .rejected))
                break
            }
            session.sendText(text, waitGeneration: waitGeneration) { [weak self] result in
                self?.send(.inputSubmissionCompleted(
                    id: submissionId,
                    result: result == .delivered ? .delivered : .rejected
                ))
            }

        case .sendInputText(let paneId, let text, let submissionId, let waitGeneration):
            guard let submissionId else {
                paneSession(for: paneId)?.sendInputText(text, waitGeneration: waitGeneration)
                break
            }
            guard let session = paneSession(for: paneId) else {
                send(.inputSubmissionCompleted(id: submissionId, result: .rejected))
                break
            }
            session.sendInputText(text, waitGeneration: waitGeneration) { [weak self] result in
                self?.send(.inputSubmissionCompleted(
                    id: submissionId,
                    result: result == .delivered ? .delivered : .rejected
                ))
            }

        case .sendInputKey(let paneId, let key, let mods, let submissionId, let waitGeneration):
            guard let submissionId else {
                paneSession(for: paneId)?.sendInputKey(
                    key,
                    modifiers: mods,
                    waitGeneration: waitGeneration
                )
                break
            }
            guard let session = paneSession(for: paneId) else {
                send(.inputSubmissionCompleted(id: submissionId, result: .rejected))
                break
            }
            session.sendInputKey(
                key,
                modifiers: mods,
                waitGeneration: waitGeneration
            ) { [weak self] result in
                self?.send(.inputSubmissionCompleted(
                    id: submissionId,
                    result: result == .delivered ? .delivered : .rejected
                ))
            }

        case .sendInputWheel(
            let paneId,
            let direction,
            let column,
            let row,
            let submissionId,
            let waitGeneration
        ):
            guard let submissionId else {
                paneSession(for: paneId)?.sendInputWheel(
                    direction,
                    column: column,
                    row: row,
                    waitGeneration: waitGeneration
                )
                break
            }
            guard let session = paneSession(for: paneId) else {
                send(.inputSubmissionCompleted(id: submissionId, result: .rejected))
                break
            }
            session.sendInputWheel(
                direction,
                column: column,
                row: row,
                waitGeneration: waitGeneration
            ) { [weak self] result in
                self?.send(.inputSubmissionCompleted(
                    id: submissionId,
                    result: result == .delivered ? .delivered : .rejected
                ))
            }

        case .focusSession(let paneId, let focused):
            paneSession(for: paneId)?.setFocused(focused)

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
            ports.deliverNotification(request)

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
            let exportWriter = exportWriter
            let presentAlert = ports.presentAlert
            ports.selectExportDestination(window) { url in
                guard let url else { return }
                exportWriter.write(
                    to: url,
                    async: true,
                    encode: capture.encoder(prettyPrinted: true)
                ) { outcome in
                    guard case .failed(let description) = outcome else { return }
                    // The writer's completion already arrives a main-queue turn after the sheet
                    // dismissed, so this modal cannot open inside the panel's completion.
                    presentAlert("Export Failed", description)
                }
            }

        case .ipcReply(let reqId, let result):
            guard let connection = takeIpcConnection(for: reqId) else { break }
            connection.writeSuccess(reqId: reqId, result: result)

        case .ipcError(let reqId, let code, let message):
            guard let connection = takeIpcConnection(for: reqId) else { break }
            connection.writeError(reqId: reqId, code: code, message: message)

        case .readDoctorPermissions(let reqId):
            let readDoctorPermissions = ports.readDoctorPermissions
            Task { [weak self] in
                let permissions = await readDoctorPermissions()
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
            guard let session = paneSession(for: paneId) else {
                connection.writeError(reqId: reqId, code: -32603, message: "pane no longer available")
                break
            }
            let raw = lineLimit == nil ? session.readViewportText() : session.readFullHistoryText()
            guard let raw else {
                connection.writeError(reqId: reqId, code: -32603, message: "failed to read pane text")
                break
            }
            let text = lineLimit.map { tailLines(raw, n: $0) } ?? raw
            connection.writeSuccess(reqId: reqId, result: JSONValue.object(["text": .string(text)]))

        case .readPaneRowStructure(let reqId, let paneId):
            guard let connection = takeIpcConnection(for: reqId) else { break }
            guard let session = paneSession(for: paneId) else {
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
            connection.writeSuccess(reqId: reqId, result: JSONValue.object(["rows": .array(rows)]))

        case .streamPaneTape(let reqId, let paneId, let capture, let start, let policy):
            guard let connection = takeIpcConnection(for: reqId) else { break }
            guard let session = paneSession(for: paneId) else {
                connection.writeError(reqId: reqId, code: -32603, message: "pane no longer available")
                break
            }
            if capture == .follow {
                beginPaneTapeFollow(
                    reqId: reqId,
                    paneId: paneId,
                    start: start,
                    policy: policy,
                    connection: connection,
                    session: session
                )
            } else {
                streamFinitePaneTape(
                    reqId: reqId,
                    connection: connection,
                    session: session,
                    capture: capture,
                    start: start,
                    policy: policy
                )
            }

        case .subscribeRoster(let reqId, let roster):
            subscribeToRoster(reqId: reqId, roster: roster)

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
            // Follow teardown is not repeated here: application termination reaches
            // `applicationWillTerminate`, and `shutdown()` is its single owner.
            cancelCoalescedReconcile()
            schedulingLifecycle.cancel(lightCheckpointTimerToken)
            lightCheckpointTimerToken = nil
            lightCheckpointTimer = nil
            schedulingLifecycle.cancel(enrichedCheckpointTimerToken)
            enrichedCheckpointTimerToken = nil
            enrichedCheckpointTimer = nil
            for host in paneHosts.values {
                host.removeReplayFile()
            }
            ports.terminateApp()

        case .activateApp:
            ports.activateApp()
            window?.makeKeyAndOrderFront(nil)

        // Search commands

        case .sendStartSearch(let paneId):
            paneSession(for: paneId)?.startSearch()

        case .sendSearchNeedle(let paneId, let needle):
            guard let host = paneHost(for: paneId) else { break }
            // Capture the session now rather than resolving the pane when the delayed
            // delivery fires: restore reuses pane ids, so a pane looked up at fire time
            // can be a different pane than the one this needle was typed into.
            let session = host.session
            // Debounce: immediate for empty or 3+ chars, 300ms for 1-2 chars
            let delay: TimeInterval = (needle.isEmpty || needle.count >= 3) ? 0 : 0.3
            schedulingLifecycle.cancel(host.searchDebounceToken)
            host.searchDebounceToken = nil

            if delay == 0 {
                session.setSearchNeedle(needle)
            } else {
                let debouncer = host.searchDebouncer ?? {
                    let debouncer = Debouncer(queue: .main)
                    host.searchDebouncer = debouncer
                    return debouncer
                }()
                debouncer.schedule(after: delay) { [weak self, weak host] in
                    guard let self, let host, let token = host.searchDebounceToken else { return }
                    host.searchDebounceToken = nil
                    self.schedulingLifecycle.run(token) { session.setSearchNeedle(needle) }
                }
                host.searchDebounceToken = schedulingLifecycle.arm(.debouncer) {
                    debouncer.cancel()
                }
            }

        case .sendSearchNavigate(let paneId, let direction):
            paneSession(for: paneId)?.navigateSearch(direction)

        case .sendEndSearch(let paneId):
            guard let host = paneHost(for: paneId) else { break }
            schedulingLifecycle.cancel(host.searchDebounceToken)
            host.searchDebounceToken = nil
            host.searchDebouncer = nil
            host.session.endSearch()

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

    /// The only way a pane leaves the runtime. `reconcileSessionExistence` calls it for
    /// every pane absent from `model.allPaneIds`, and the whole-session swap calls it for
    /// every live pane, so a step added here applies on both paths. `internal` so the
    /// cross-file reconcile extension can reach it.
    ///
    /// Two layers, and the split is the point: what the record owns it destroys itself,
    /// which is also right for a staged record; what is scoped to the pane *id* is retired
    /// here, because only a live pane may have it.
    func tearDownSession(_ paneId: PaneId) {
        endPaneTapeFollowers(for: paneId)
        guard let host = paneHosts.removeValue(forKey: paneId) else { return }
        host.tearDown(scheduling: schedulingLifecycle)
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
                self.sweepAndDispatchFollowUps()
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
        for host in paneHosts.values {
            host.session.fenceForApplicationExit()
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
            if !async { checkpointWriter.drain() }
            return
        }
        lightCheckpointBaseline = projection
        checkpointWriter.write(
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
        for (paneId, host) in paneHosts {
            let session = host.session
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
        checkpointWriter.write(
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
        guard let container = tabContainers[tab.id] else { return }

        dragCoordinator = PaneDragCoordinator(
            sourcePaneId: paneId,
            contentView: contentArea,
            container: container
        )
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
        ports.presentAlert(
            "DanTerm Config Error",
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
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
    /// Each pane is staged as the finished record it will be installed as, so nothing is
    /// reconstructed at commit and a failed build has one thing per pane to destroy.
    private func stageValidatedRestore(_ loaded: ValidatedAppRestore) throws -> StagedRestoreSession {
        var stagedHosts: [PaneId: PaneHost] = [:]
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
                        var replayFile: URL?
                        if let replayText = recoveryReplayText(scrollback: ps?.scrollback, agentSession: ps?.agentSession) {
                            replayFile = writeReplayFile(scrollback: replayText)
                        }
                        let envVars = restoreLaunchEnvironment(
                            ipcSocketPath: ipcSocketPath?.path,
                            paneId: paneId,
                            scrollbackFilePath: replayFile?.path,
                            command: resolved?.command
                        )
                        guard let host = makeTerminalSession(
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
                            fontFamily: restoredModel.resolvedFontFamily,
                            gridOverride: restoredModel.pane(paneId)?.gridOverride,
                            replayFile: replayFile
                        ) else {
                            throw RestoreBuildError.sessionCreationFailed
                        }
                        stagedHosts[paneId] = host
                    }
                }
            }

            return StagedRestoreSession(model: restoredModel, hosts: stagedHosts)
        } catch {
            discardRestoreSession(StagedRestoreSession(model: restoredModel, hosts: stagedHosts))
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

        for paneId in Array(paneHosts.keys) {
            tearDownSession(paneId)
        }
        // The switcher panel persists across sessions; hide it before resetting
        // caches.switcher so nil continues to mean the panel is already hidden.
        switcherPanel?.orderOut(nil)
        // Reset reconciler caches by re-init so the first post-restore reconcile is
        // a clean build, not a stale diff (restore/import can reuse pane IDs).
        caches = ReconcilerCaches()
        sidebarReconcileDriver = SidebarReconcileDriver()
    }

    /// Swap a fully staged restore into the live runtime and refresh derived UI state.
    private func commitRestoreSession(_ staged: StagedRestoreSession) {
        tearDownCurrentSession()
        model = staged.model
        // tearDownCurrentSession emptied the table, so the staged one becomes the live one
        // whole. The records were finished at staging; nothing is rebuilt here.
        paneHosts = staged.hosts
        lightCheckpointBaseline = currentLightCheckpointProjection()
        cancelCoalescedReconcile()

        // Restore bypasses update(); reconcile tab state here so the first
        // cmd-shift-i after a restore sees a populated mruOrder.
        reconcileTabState(&model)

        // Drive the entire post-restore UI through reconcile() (clean build:
        // tearDownCurrentSession reset the caches). reconcileContainers builds every
        // tab's container eagerly from the nil containerShape cache -- selected visible,
        // the rest mounted+hidden -- and the chrome/sidebar/window passes build from
        // scratch. reconcileSessionExistence is a no-op (staged sessions match allPaneIds).
        sweepAndDispatchFollowUps()
    }

    /// Dispose of a staged restore after a failed build so no temp state leaks into the live
    /// session. This is the record teardown a live pane gets, and only that: a staged record
    /// can carry the same pane id as a live pane, so the id-scoped half of `tearDownSession`
    /// -- which would end that live pane's tape-follow streams -- must not run here.
    private func discardRestoreSession(_ staged: StagedRestoreSession) {
        for host in staged.hosts.values {
            host.tearDown(scheduling: schedulingLifecycle)
        }
    }

    /// Build one pane's whole runtime record: a backend session with its pane-scoped event
    /// translation armed, wrapped in the record that owns both for the pane's lifetime. Both
    /// callers -- the create-session command and restore staging -- get a finished record, so
    /// no pane exists in a state where its session is live but its chrome is not.
    ///
    /// `replayFile` is the one resource written before the record exists. If the backend
    /// refuses the session there is no record to own it, so it is deleted here rather than
    /// left for a caller to remember.
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
        fontFamily: String?,
        gridOverride: PaneGridOverride?,
        replayFile: URL? = nil
    ) -> PaneHost? {
        let request = TerminalSessionRequest(
            workingDirectory: workingDirectory,
            command: command,
            launchCommand: launchCommand,
            waitAfterCommand: waitAfterCommand,
            environment: envVars,
            localeFallbackEnabled: model.config.localeFallback,
            themeName: themeName,
            fontSize: fontSize,
            fontFamily: fontFamily,
            gridOverride: gridOverride
        )
        guard let session = ports.createTerminalSession(request) else {
            if let replayFile { try? FileManager.default.removeItem(at: replayFile) }
            return nil
        }
        session.currentAgentWaitGeneration = { [weak self] in
            self?.model.pane(owning: sessionId)?.session?.agent.currentWaitGeneration
        }
        session.onEvent = { [weak self, weak session] event in
            #if DANTERM_TERMINAL_CHARACTERIZATION
            recordTerminalCharacterizationEvent(event)
            #endif
            guard let self, let session else { return }
            guard self.retractionIsLive(event, sessionId: sessionId) else { return }
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
        let subscriptionToken = schedulingLifecycle.arm(.subscription, cancel: {
            session.onEvent = nil
            session.currentAgentWaitGeneration = nil
            session.onPrimaryHistoryMutation = nil
        })
        session.setRenderingAvailable(renderingAvailable)
        if hasCheckpointableScrollback(initialRecoveryCandidate) {
            notePrimaryHistoryMutation()
        }
        return PaneHost(
            paneId: paneId,
            session: session,
            runtime: self,
            subscriptionToken: subscriptionToken,
            replayFile: replayFile
        )
    }

    /// Drops a delivered-input occurrence that can retract nothing before it reaches
    /// `send()`, which snapshots and compares the whole model for every message. Typing
    /// is the highest-rate producer of session events, and almost none of it answers a
    /// wait.
    ///
    /// A fast path, never a second rule: it asks `AgentLifecycle.retractsWait`, the same
    /// predicate `reduceSession` guards with, so deleting this function changes nothing
    /// observable. Every other event passes untouched.
    private func retractionIsLive(_ event: TerminalSessionEvent, sessionId: SessionId) -> Bool {
        guard case .report(.userInputDelivered(let waitGeneration)) = event else { return true }
        guard let agent = model.pane(owning: sessionId)?.session?.agent else { return false }
        return agent.retractsWait(carrying: waitGeneration)
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
        ports.presentAlert("Import Failed", message)
    }

    // MARK: - Pane Toolbars

    /// The way one pane enters the runtime, given the record session creation produced.
    private func installPane(_ host: PaneHost, paneId: PaneId) {
        paneHosts[paneId] = host
    }

    /// Wraps a bare session in its record and installs it, for a caller that has a session
    /// rather than a restore or a create-session command behind it. `internal` so tests
    /// install panes the way production does instead of writing one in behind this path.
    func installTerminalSession(_ session: any TerminalSession, paneId: PaneId) {
        installPane(PaneHost(paneId: paneId, session: session, runtime: self), paneId: paneId)
    }

    /// Returns the pane's record, or nil when no pane is installed under that id.
    func paneHost(for paneId: PaneId) -> PaneHost? {
        paneHosts[paneId]
    }

    /// Reads the live session out of the pane's record. Every caller that used to
    /// index a separate session table goes through here.
    func paneSession(for paneId: PaneId) -> (any TerminalSession)? {
        paneHosts[paneId]?.session
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
        container.setZoomedPane(tab.paneTree.zoomedPaneId)
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
