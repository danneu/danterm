// Runtime bridge that performs update commands and synchronizes the AppKit view tree.
import Cocoa
import DanTermProtocol
import PrivateFile
import UniformTypeIdentifiers
@preconcurrency import UserNotifications

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
    do {
        let descriptor = try PrivateFile.openForAppending(at: URL(fileURLWithPath: path))
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    } catch {
        print("[characterization] Failed to record terminal event: \(error)")
    }
}
#endif

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
    var lastEnqueuedRoster: PaneRoster
}

/// Owns the application model so every mutation after initialization passes through update().
@MainActor
private final class AppModelStore {
    private var storedModel: AppModel
    private let coreEnv: CoreEnv

    init(_ model: AppModel, coreEnv: CoreEnv) {
        storedModel = model
        self.coreEnv = coreEnv
    }

    var value: AppModel { storedModel }

    func dispatch(_ msg: Msg) -> [Command] {
        return update(&storedModel, msg, env: coreEnv)
    }
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

    private let modelStore: AppModelStore
    var model: AppModel { modelStore.value }
    let coreEnv: CoreEnv
    private let configStore: DanTermConfigStore
    private let ports: AppRuntimePorts
    // Every identity-keyed path this runtime reads or writes -- the control socket,
    // both checkpoint tiers, the audit log, the replay directory. Given rather than
    // derived, so a runtime cannot reach a directory its owner did not name.
    let instancePaths: DanTermInstancePaths
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
    weak var configurableMenuBindingSurface: ConfigurableMenuBindingSurface?
    var alertsPopover: NSPopover?
    /// Reports click-away closure for the cross-file alerts-popover existence pass.
    lazy var alertsPopoverDelegate = AlertsPopoverDelegateAdapter(runtime: self)
    var todoPopover: NSPopover?
    /// Retains the reporting delegate while the projected TODO popover is open.
    var todoPopoverDelegate: TodoPopoverDelegateAdapter?
    // internal (not private): the cross-file reconcileThemeBrowser extension reads it.
    var themeBrowserView: ThemeBrowserView?
    // The runtime's only route to a dialog window. internal (not private): the
    // cross-file reconcile extension drives them. Given rather than found, so a
    // runtime handed surfaces that present nothing cannot reach the screen.
    let dialogSurfaces: DialogSurfaces
    // One owned local NSEvent monitor. `Any` is the type AppKit hands back for a monitor.
    private lazy var switcherEventMonitor = AppRuntimeScheduledOwner<Any>(
        lifecycle: schedulingLifecycle,
        category: .eventMonitor,
        retire: { NSEvent.removeMonitor($0) }
    )
    private var dragCoordinator: PaneDragCoordinator?
    // Session persistence uses two tiers of checkpoints:
    //   Light  -- model-owned recovery state (no scrollback), written in a fixed
    //            2s coalescing window after the persisted projection changes.
    //   Enriched -- model + primary history, driven by primary-history mutations,
    //               plus one final synchronous clean-exit write.
    private lazy var lightCheckpointTimer = AppRuntimeScheduledOwner<DispatchSourceTimer>(
        timerIn: schedulingLifecycle
    )
    private var lightCheckpointBaseline: LightCheckpointProjection?
    // One owned enriched-checkpoint timer.
    private lazy var enrichedCheckpointTimer = AppRuntimeScheduledOwner<DispatchSourceTimer>(
        timerIn: schedulingLifecycle
    )
    private var recoveryPolicy = RecoveryCheckpointPolicy(
        window: UInt64(600 * NSEC_PER_SEC)
    )
    // Rate-limited whole-model sweep.
    private lazy var coalescedReconcileTimer = AppRuntimeScheduledOwner<DispatchSourceTimer>(
        timerIn: schedulingLifecycle
    )
    private let alertAgeRefreshScheduler: (@escaping () -> Void) -> (() -> Void)
    private lazy var alertAgeRefresh = AppRuntimeScheduledOwner<() -> Void>(
        lifecycle: schedulingLifecycle,
        category: .timer,
        retire: { cancel in cancel() }
    )
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
    // Keyed by connection id: one subscription per connection, and a repeat subscribe
    // replaces the entry rather than adding a second push target.
    private var rosterSubscribers: [UUID: RosterSubscriber] = [:]
    // One owned IPC server; retiring it closes the control socket.
    private lazy var ipcServer = AppRuntimeScheduledOwner<IpcServer>(
        lifecycle: schedulingLifecycle,
        category: .ipcServer,
        retire: { $0.stop() }
    )
    // A token with no handle of its own: it gates the single deferred start callback, and
    // the server that callback starts belongs to the owner above.
    private var ipcServerStartToken: AppRuntimeSchedulingToken?
    // Recovery data stays inert until the projected launch notice resolves to Restore.
    private var pendingLaunchRestore: ValidatedAppRestore?
    // Staging authors this table before the reducer asks the command interpreter
    // to swap it into the live session. The command stays payload-free, so no
    // AppKit-owned value crosses into the pure core.
    private var stagedRestoreHosts: [PaneId: PaneHost]?
    let schedulingLifecycle = AppRuntimeSchedulingLifecycle()
    private lazy var paneTapeBroker = PaneTapeBroker(
        schedulingLifecycle: schedulingLifecycle
    )
    private static let checkpointCoalesceInterval: TimeInterval = 2.0
    // Coalescing window for the reconcile pass, sized for its noisiest driver: a
    // shell that rewrites its OSC 0/2 title on every prompt. 75ms still reads as
    // instant to a human, and it collapses a burst of title writes into one chrome
    // update instead of a visible flicker.
    private static let reconcileCoalesceInterval: TimeInterval = 0.075
    private static let alertAgeRefreshInterval: TimeInterval = 60

    private static func scheduleLiveAlertAgeRefresh(
        _ handler: @escaping () -> Void
    ) -> () -> Void {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + alertAgeRefreshInterval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return { timer.cancel() }
    }

    /// Neither `dialogSurfaces` nor `instancePaths` has a default, for the same
    /// reason: presenting on screen and writing to this instance's directories are
    /// both capabilities a caller grants, so a runtime built without naming them
    /// does not exist. `startsApplicationServices` is now only about the switcher
    /// event monitor and the IPC server -- presenting is the surfaces' business.
    init(
        ports: AppRuntimePorts,
        dialogSurfaces: DialogSurfaces,
        instancePaths: DanTermInstancePaths,
        configStore: DanTermConfigStore = DanTermConfigStore(),
        coreEnv: CoreEnv = .live,
        alertAgeRefreshScheduler: ((@escaping () -> Void) -> (() -> Void))? = nil,
        initialModel: AppModel? = nil,
        startsApplicationServices: Bool = true,
        tailnetOptIn: Bool = false,
        applicationActive: Bool
    ) {
        self.ports = ports
        self.dialogSurfaces = dialogSurfaces
        self.instancePaths = instancePaths
        self.configStore = configStore
        self.coreEnv = coreEnv
        self.alertAgeRefreshScheduler = alertAgeRefreshScheduler ?? Self.scheduleLiveAlertAgeRefresh
        var startingModel: AppModel
        if let initialModel {
            startingModel = initialModel
        } else {
            // Empty launch: one group, no tabs/leaves yet (panes live in leaves).
            var launchModel = AppModel(
                groups: [GroupModel(id: GroupId(rawValue: coreEnv.newId()), name: "General")]
            )
            // Load DanTerm config before any tabs are created. The store does not exist
            // yet, so assemble the launch value before giving it its sole mutation owner.
            let launchConfig: DanTermConfig
            do {
                launchConfig = try configStore.load()
            } catch {
                launchConfig = .default
                self.pendingConfigError = error
            }
            launchModel.config = launchConfig
            launchModel.resolvedFontFamily = resolveConfiguredFontFamily(launchConfig)
            startingModel = launchModel
        }
        // Given, never defaulted: a detached or background launch reaches
        // `applicationDidFinishLaunching` with no activation callback ahead of it, and
        // `AppModel.isAppActive` defaults to true. Every pane created before the first
        // real callback derives its reported terminal focus from this value.
        startingModel.isAppActive = applicationActive
        self.modelStore = AppModelStore(startingModel, coreEnv: coreEnv)
        self.lightCheckpointBaseline = LightCheckpointProjection(snapshot: toSnapshot(model))
        paneTapeBroker.setSessionLookup { [weak self] paneId in
            self?.paneSession(for: paneId)
        }

        // Weak on purpose: the runtime owns the outbox, and a drain scheduled on
        // the main queue must be inert once the runtime is gone. Routed through
        // `send`, not straight to `dispatch`, so a reported fact and a direct send
        // enter the runtime at the same point; the two are the same call here, and
        // the UI suite substitutes that point to observe what a view reported.
        outbox.setDispatcher { [weak self] msg in self?.send(msg) }

        // Here, inside init, so no message can reach a dialog pass before its
        // surface can build a window. A pass that applied to an unbound surface
        // would advance its cache and leave the model claiming a dialog nobody
        // can see.
        for surface in dialogSurfaces.all {
            surface.bind(runtime: self)
        }

        // Install the local NSEvent monitor that drives ephemeral keyboard modes.
        // It reads model flags to know whether a mode is active, but never mutates
        // the model directly; mutations go through send().
        if startsApplicationServices {
            installSwitcherEventMonitor()
        }

        if startsApplicationServices {
            do {
                let server = try IpcServer(
                    socketPath: instancePaths.controlSocket,
                    tailnetConfig: model.config.tailnet,
                    identity: instancePaths.identity,
                    tailnetOptIn: tailnetOptIn,
                    auditWriter: IpcAuditLogWriter(directory: instancePaths.ipcAuditDirectory),
                    runtimeDispatch: makeIpcDispatch()
                )
                self.ipcServer.arm { _ in server }
                _ = self.modelStore.dispatch(.tailnetStatusChanged(server.initialTailnetStatus))
                self.ipcServerStartToken = schedulingLifecycle.arm(.deferredCallback, cancel: {})
            } catch {
                print("Failed to start DanTerm IPC server: \(error)")
            }
        }
    }

    // MARK: - Ephemeral Mode Event Monitor

    private func installSwitcherEventMonitor() {
        guard schedulingLifecycle.isActive else { return }
        let eventHandler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self = self else { return event }

            if self.model.jumpMode != nil {
                switch event.type {
                case .keyDown:
                    let character = event.charactersIgnoringModifiers?.lowercased().first
                    let action = classifyJumpInput(
                        kind: event.keyCode == 0x35 ? .escape : .keyDown(character: character),
                        jumpActive: true
                    )
                    switch action {
                    case .passthrough:
                        return event
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
                        jumpActive: true
                    )
                    return event

                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    let action = classifyJumpInput(
                        kind: .mouseDown,
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

            guard self.model.mruCycle != nil else { return event }
            guard event.type == .keyDown || event.type == .flagsChanged else { return event }

            guard let bindings = self.effectiveHeldMRUBindings() else { return event }
            let modifiers = self.normalizedKeyModifiers(from: event)
            let kind: SwitcherInputKind
            if event.type == .flagsChanged {
                kind = .flagsChanged(modifiers: modifiers)
            } else if event.keyCode == 0x35 {
                kind = .escape
            } else {
                let chord = [bindings.older, bindings.newer].first {
                    self.event(event, matches: $0, modifiers: modifiers)
                }
                kind = .keyDown(chord: chord)
            }

            let action = classifySwitcherInput(
                kind: kind,
                requiredModifiers: bindings.older.modifiers,
                olderChord: bindings.older,
                newerChord: bindings.newer,
                cycleActive: true
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
        switcherEventMonitor.arm { _ in monitor }
    }

    private func normalizedKeyModifiers(from event: NSEvent) -> DanTermProtocol.KeyModifiers {
        var mods: DanTermProtocol.KeyModifiers = []
        let raw = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if raw.contains(.command) { mods.insert(.command) }
        if raw.contains(.shift)   { mods.insert(.shift) }
        if raw.contains(.option)  { mods.insert(.option) }
        if raw.contains(.control) { mods.insert(.control) }
        return mods
    }

    private func effectiveHeldMRUBindings() -> (older: KeyChord, newer: KeyChord)? {
        guard let bindings = effectiveBindings(overrides: model.config.keybindingOverrides).value,
              let older = bindings["tab.recent-older"]?.first,
              let newer = bindings["tab.recent-newer"]?.first
        else { return nil }
        return (older, newer)
    }

    private func event(
        _ event: NSEvent,
        matches chord: KeyChord,
        modifiers: DanTermProtocol.KeyModifiers
    ) -> Bool {
        guard modifiers == chord.modifiers else { return false }
        return event.charactersIgnoringModifiers?.lowercased()
            == CommandMenuItemFactory.keyEquivalent(chord).lowercased()
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

    /// The runtime's one message entry point: a direct send and a fact drained from
    /// the outbox both arrive here. Overridable on purpose -- the UI suite subclasses
    /// the runtime and substitutes this method to observe what a view reported, so a
    /// second route into `dispatch` would make a whole class of reports invisible.
    func send(_ msg: Msg) {
        dispatch(msg)
    }

    /// One send frame: translate, perform, sweep, then deliver what the frame
    /// collected. Any send that arrives while a frame is open joins its outbox,
    /// including one AppKit launders through a view callback mid-sweep. Waiting for
    /// the outermost frame to close keeps update() from re-entering against an
    /// in-flight projection cache.
    private func dispatch(_ msg: Msg) {
        guard schedulingLifecycle.isActive else { return }
        if outbox.isFrameOpen {
            outbox.report([msg])
            return
        }
        outbox.withFrame { dispatchInFrame(msg) }
    }

    /// The body of one send frame. Split out so the frame bracket reads as one
    /// line; it has no other caller.
    private func dispatchInFrame(_ msg: Msg) {
        let commands = modelStore.dispatch(msg)
        for command in commands {
            perform(command)
        }
        switch reconcileDecision(
            for: msg,
            coalescedSweepPending: coalescedReconcileTimer.isArmed
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

    /// Sends each subscriber a roster that differs from the last one its FIFO accepted.
    private func pushRosterIfChanged() {
        guard schedulingLifecycle.isActive else { return }
        guard rosterSubscribers.isEmpty == false else { return }
        let roster = paneRoster(in: model)
        let params = roster.jsonValue
        for connectionId in rosterSubscribers.keys {
            guard var subscriber = rosterSubscribers[connectionId],
                  subscriber.lastEnqueuedRoster != roster
            else { continue }
            subscriber.connection.writeNotification(
                method: Methods.rosterEvent,
                params: params
            )
            subscriber.lastEnqueuedRoster = roster
            rosterSubscribers[connectionId] = subscriber
        }
    }

    /// Answers a roster subscribe on its own connection and keeps that connection as a
    /// push target until it closes.
    ///
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
            shutdownToken: token,
            lastEnqueuedRoster: roster
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
        _ action: @escaping @MainActor @Sendable (AppRuntime) -> Void
    ) -> (@MainActor @Sendable () -> Void)? {
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
        ipcServer.handle?.socketPath
    }

    /// Starts request acceptance when the selected launch branch is ready to serve it.
    func startIpcServer() {
        guard let server = ipcServer.handle, let startToken = ipcServerStartToken else { return }
        ipcServerStartToken = nil
        Task { [weak self, weak server] in
            guard let self, let server else { return }
            guard self.schedulingLifecycle.run(startToken, action: {}) else { return }
            await server.start()
        }
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
                switch message {
                case .request(let caller, let request):
                    self.send(.ipcRequest(reqId: reqId, caller: caller, request: request))
                case .decodeFailed(let error):
                    self.send(.ipcRequestDecodeFailed(reqId: reqId, error: error))
                }
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
        paneTapeBroker.connectionClosed(connectionId)
        // Retired with `run`, not `cancel`: the socket this token would close is the one
        // that just went away, and cancelling a sibling's is what this key prevents.
        if let subscriber = rosterSubscribers.removeValue(forKey: connectionId) {
            schedulingLifecycle.run(subscriber.shutdownToken, action: {})
        }
    }

    /// Stops accepting IPC work while leaving the runtime available for explicit teardown.
    func stopIpcServer() {
        schedulingLifecycle.cancel(ipcServerStartToken)
        ipcServerStartToken = nil
        ipcServer.cancel()
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

        for command in modelStore.dispatch(.runtimeWillShutdown) {
            perform(command)
        }

        // Nothing survives the runtime on screen: the surfaces reach the runtime
        // weakly, so a dialog left up would answer into nothing.
        for surface in dialogSurfaces.all {
            surface.hide()
        }

        paneTapeBroker.shutdown()
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

        // Every armed owner is registered in the census -- the runtime's timers, its event
        // monitor and its IPC server, and each pane record's session subscription and armed
        // search debounce -- so this one walk retires all of them.
        schedulingLifecycle.shutdown()
    }

    // MARK: - Command Performer

    func perform(_ command: Command) {
        switch command {
        case .installStagedRestoreSession:
            guard let hosts = stagedRestoreHosts else {
                assertionFailure("restore command requires a staged pane-host table")
                break
            }
            stagedRestoreHosts = nil
            tearDownCurrentSession()
            // Teardown emptied the table, so the finished staged records become live whole.
            paneHosts = hosts

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
                optionAsAlt: model.config.optionAsAlt,
                gridOverride: model.pane(paneId)?.gridOverride
            ) else {
                send(.sessionCreationFailed(sessionId: sessionId))
                break
            }
            installPane(host, paneId: paneId)

        case .submitPaneInput(let paneId, let input, let submissionId, let waitGeneration):
            guard let session = paneSession(for: paneId) else {
                send(.inputSubmissionCompleted(
                    id: submissionId,
                    result: .rejected(.processEnded)
                ))
                break
            }
            session.submitInput(input, waitGeneration: waitGeneration) { [weak self] result in
                self?.send(.inputSubmissionCompleted(
                    id: submissionId,
                    result: Self.inputSubmissionResult(result)
                ))
            }

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
            let retention = ScrollbackRetention.checkpoint
            let capture = CheckpointCapture(
                snapshot: snapshot,
                scrollbackReads: captureScrollbackReads(
                    limits: retention.primaryHistoryLimits
                )
            )
            let exportWriter = exportWriter
            ports.selectExportDestination(window) { [weak self] url in
                guard let self, let url else { return }
                exportWriter.write(
                    to: url,
                    async: true,
                    encode: capture.encoder(prettyPrinted: true)
                ) { [weak self] outcome in
                    guard let self, case .failed(let description) = outcome else { return }
                    self.send(.noticeReported(.message(
                        title: "Export Failed",
                        message: description
                    )))
                }
            }

        case .resolveLaunchRestore(let shouldRestore):
            guard let callback = captureDeferredCallback({ runtime in
                let retained = runtime.pendingLaunchRestore
                runtime.pendingLaunchRestore = nil
                if shouldRestore, let retained {
                    runtime.bootstrapFromValidatedRestore(retained)
                } else {
                    runtime.send(.createTabInSelectedGroup())
                }
            }) else { break }
            // Leave both the answering send frame and the panel button-action stack.
            DispatchQueue.main.async(execute: callback)

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

        case .resolveAutosplit(let reqId, let caller, let tabId, let launch, let background):
            let resolution = tabContainers[tabId]
                .flatMap { autosplitResolution(in: $0.currentArrangedPaneLayout()) }
            send(.autosplitResolved(
                reqId: reqId,
                caller: caller,
                tabId: tabId,
                resolution: resolution,
                launch: launch,
                background: background
            ))

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

        case .readPaneCells(let reqId, let paneId):
            guard let connection = takeIpcConnection(for: reqId) else { break }
            guard let session = paneSession(for: paneId) else {
                connection.writeError(reqId: reqId, code: -32603, message: "pane no longer available")
                break
            }
            guard let readout = session.readViewportCells() else {
                connection.writeError(reqId: reqId, code: -32603, message: "failed to read pane cells")
                break
            }
            connection.writeSuccess(reqId: reqId, result: viewportCellsJSON(readout))

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
            paneTapeBroker.streamPaneTape(
                reqId: reqId,
                paneId: paneId,
                capture: capture,
                start: start,
                policy: policy,
                connection: connection
            )

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
            lightCheckpointTimer.cancel()
            enrichedCheckpointTimer.cancel()
            for host in paneHosts.values {
                host.removeReplayFile()
            }
            ports.terminateApp()

        case .activateApp:
            ports.activateApp()
            window?.makeKeyAndOrderFront(nil)

        // Search commands

        case .sendSearchNeedle(let paneId, let needle):
            guard let host = paneHost(for: paneId) else { break }
            // Capture the session now rather than resolving the pane when the delayed
            // delivery fires: restore reuses pane ids, so a pane looked up at fire time
            // can be a different pane than the one this needle was typed into.
            let session = host.session
            // Debounce: immediate for empty or 3+ chars, 300ms for 1-2 chars
            let delay: TimeInterval = (needle.isEmpty || needle.count >= 3) ? 0 : 0.3

            if delay == 0 {
                host.searchDebounce.cancel()
                session.setSearchNeedle(needle)
            } else {
                // Arming retires the pending needle first, so a burst of short needles
                // holds one timer and only the last one is delivered.
                host.searchDebounce.armTimer(deadline: .now() + delay) {
                    session.setSearchNeedle(needle)
                }
            }

        case .sendSearchNavigate(let paneId, let direction):
            paneSession(for: paneId)?.navigateSearch(direction)

        case .sendEndSearch(let paneId):
            guard let host = paneHost(for: paneId) else { break }
            host.searchDebounce.cancel()
            host.session.endSearch()

        }
    }

    // MARK: - Scrollback Replay Files

    /// Write scrollback text to a temp file for shell replay. Returns the file URL.
    private func writeReplayFile(scrollback: String) -> URL? {
        guard let data = scrollback.data(using: .utf8) else { return nil }
        let dir = instancePaths.scrollbackReplayDirectory
        try? PrivateFile.createDirectory(at: dir)
        let fileURL = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        guard (try? PrivateFile.writeAtomically(data, to: fileURL)) != nil else { return nil }
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
        paneTapeBroker.paneClosed(paneId)
        guard let host = paneHosts.removeValue(forKey: paneId) else { return }
        host.tearDown(scheduling: schedulingLifecycle)
    }

    /// Delete this identity's replay files from prior sessions.
    func cleanupStaleReplayDirectory() {
        instancePaths.removeStaleScrollbackReplayDirectory()
    }

    // MARK: - Session Checkpointing

    /// Arm one bounded light-checkpoint window after persisted state diverges. An existing
    /// window stays fixed so continuous message traffic cannot postpone the write.
    private func scheduleLightCheckpointIfNeeded() {
        guard lightCheckpointTimer.isArmed == false,
              schedulingLifecycle.isActive,
              currentLightCheckpointProjection() != lightCheckpointBaseline
        else { return }
        lightCheckpointTimer.armTimer(
            deadline: .now() + Self.checkpointCoalesceInterval,
            leeway: .milliseconds(200)
        ) { [weak self] in
            self?.performLightCheckpoint(async: true)
        }
    }

    /// Defer the whole-model reconcile() sweep while cosmetic title/cwd/progress,
    /// background alert-badge, and shell command-event messages arrive at high
    /// frequency. The timer reads the latest model when it fires. This is
    /// fixed-window coalescing: an armed window stays fixed, so message traffic
    /// cannot postpone the sweep. Re-arming an owner instead gives a trailing edge,
    /// which is what the search needle wants.
    private func scheduleCoalescedReconcile() {
        guard coalescedReconcileTimer.isArmed == false,
              schedulingLifecycle.isActive
        else { return }
        coalescedReconcileTimer.armTimer(
            deadline: .now() + Self.reconcileCoalesceInterval
        ) { [weak self] in
            self?.sweepAndDispatchFollowUps()
        }
    }

    /// Keep one fixed-window age refresh armed exactly while the alerts popover is open.
    func reconcileAlertAgeRefresh() {
        guard model.alertsPopoverOpen else {
            alertAgeRefresh.cancel()
            return
        }
        guard alertAgeRefresh.isArmed == false, schedulingLifecycle.isActive else { return }
        alertAgeRefresh.arm { fire in
            alertAgeRefreshScheduler { [weak self] in
                fire {
                    self?.send(.alertsAgeRefreshTick)
                }
            }
        }
    }

    /// Cancel any deferred sweep because an inline reconcile will cover the latest model.
    private func cancelCoalescedReconcile() {
        coalescedReconcileTimer.cancel()
    }

    /// Close the current light-checkpoint window immediately. Called on appResignedActive
    /// so we do not lose the last 2s of state changes when the user switches away.
    func flushPendingCheckpoint() {
        guard schedulingLifecycle.isActive else { return }
        lightCheckpointTimer.cancel()
        performLightCheckpoint(async: false)
    }

    /// Fences terminal owners before synchronously capturing the final enriched checkpoint.
    func prepareRecoveryForApplicationExit() {
        guard schedulingLifecycle.isActive else { return }
        enrichedCheckpointTimer.cancel()
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
            enrichedCheckpointTimer.armTimer(
                deadline: DispatchTime(uptimeNanoseconds: deadline)
            ) { [weak self] in
                guard let self else { return }
                self.applyRecoveryAction(
                    self.recoveryPolicy.deadlineReached(at: deadline)
                )
            }
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
            enrichedCheckpointTimer.cancel()
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
            to: instancePaths.lightCheckpointFile,
            async: async,
            encode: capture.encoder()
        )
    }

    /// Take each live pane's bounded scrollback read without performing it, so the projection
    /// lands on the checkpoint queue. A backend that can only read on the main actor has no
    /// deferred reader and is read here instead, leaving the pipeline downstream uniform.
    private func captureScrollbackReads(
        limits: PrimaryHistoryLimits
    ) -> [PaneId: CheckpointScrollbackRead] {
        var reads: [PaneId: CheckpointScrollbackRead] = [:]
        for (paneId, host) in paneHosts {
            let session = host.session
            if let deferred = session.primaryHistoryTailReader(
                maxLines: limits.maxLines,
                maxChars: limits.maxChars
            ) {
                reads[paneId] = deferred
            } else if let text = session.readPrimaryHistoryTail(
                maxLines: limits.maxLines,
                maxChars: limits.maxChars
            ) {
                reads[paneId] = { text }
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
    /// projection, normalization, graft, and encode run on the checkpoint queue instead of here.
    private func captureEnrichedCheckpoint() -> CheckpointCapture {
        let retention = ScrollbackRetention.checkpoint
        let limits = retention.primaryHistoryLimits
        return CheckpointCapture(
            snapshot: toSnapshot(model),
            scrollbackReads: captureScrollbackReads(limits: limits)
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
            to: instancePaths.enrichedCheckpointFile,
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
    /// the draft, then lets reconcile create/show from the model. The final raise
    /// is what re-focuses a panel that was already open: reopening on an
    /// unchanged projection leaves the dialog pass with nothing to do.
    func showPreferencesPanel() {
        send(.preferencesOpened(
            // Snapshot on each open: the pure core may not query CoreText or
            // inspect bundled resources, and neither catalog needs a live watcher.
            installedFontFamilies: installedFontFamilyNames(),
            availableThemeNames: ThemeCatalog.shared.names
        ))
        dialogSurfaces.preferences.raise()
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

    /// Tells the user that this launch could not claim its session lock, so a crash on
    /// this run will not be detected next time. Called once the window exists; the claim
    /// itself happened long before, in `claimSessionLock`.
    func reportSessionLockClaimFailure(_ error: Error) {
        send(.noticeReported(.message(
            title: "Crash Detection Unavailable",
            message: """
                DanTerm could not write its session lock, so an unclean exit on this run \
                will not be detected the next time it starts.

                \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                """
        )))
    }

    private func presentConfigError(_ error: Error) {
        send(.noticeReported(.message(
            title: "DanTerm Config Error",
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )))
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

    /// Retains validated recovery data, reports the launch decision, and starts IPC while
    /// the prompt waits for its answer.
    func requestRestorePrompt(_ loaded: ValidatedAppRestore, message: String) {
        pendingLaunchRestore = loaded
        send(.noticeReported(.restorePrompt(message: message)))
        startIpcServer()
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
                    try forEachPane(in: tab.paneTree.root) { pane in
                        let paneId = pane.id
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
                            optionAsAlt: restoredModel.config.optionAsAlt,
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
        themeBrowserView?.removeFromSuperview()
        themeBrowserView = nil

        for tabId in Array(tabContainers.keys) {
            removeTabContainer(tabId)
        }

        for paneId in Array(paneHosts.keys) {
            tearDownSession(paneId)
        }
        // Discard every dialog before resetting the caches, so nil continues to
        // mean "already hidden" for the first post-restore sweep. Restored models
        // carry no draft and no pending confirmation. A surface whose window
        // outlives a session -- the switcher overlay -- only hides.
        for surface in dialogSurfaces.all {
            surface.discard()
        }
        // Reset reconciler caches by re-init so the first post-restore reconcile is
        // a clean build, not a stale diff (restore/import can reuse pane IDs).
        caches = ReconcilerCaches()
        sidebarReconcileDriver = SidebarReconcileDriver()
    }

    /// Give the staged hosts to the command interpreter and install the model through update().
    private func commitRestoreSession(_ staged: StagedRestoreSession) {
        precondition(stagedRestoreHosts == nil, "only one restore may be staged for commit")
        stagedRestoreHosts = staged.hosts
        send(.restoreSession(staged.model))
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

    private static func inputSubmissionResult(
        _ result: TerminalInputSubmissionResult
    ) -> InputSubmissionResult {
        switch result {
        case .delivered: .delivered
        case .rejected(.bufferLimitExceeded): .rejected(.bufferLimitExceeded)
        case .rejected(.canonicalModeTimeout): .rejected(.canonicalModeTimeout)
        case .rejected(.launchFailed): .rejected(.launchFailed)
        case .rejected(.processEnded): .rejected(.processEnded)
        case .rejected(.writeFailed(let code)): .rejected(.writeFailed(code))
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
        optionAsAlt: OptionAsAlt?,
        gridOverride: PaneGridOverride?,
        replayFile: URL? = nil
    ) -> PaneHost? {
        let onLaunchInputCompletion: (@MainActor @Sendable (
            TerminalInputSubmissionResult
        ) -> Void)?
        if command != nil || launchCommand != nil {
            onLaunchInputCompletion = { [weak self] result in
                self?.send(.launchInputCompleted(
                    sessionId: sessionId,
                    result: Self.inputSubmissionResult(result)
                ))
            }
        } else {
            onLaunchInputCompletion = nil
        }
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
            optionAsAlt: optionAsAlt,
            gridOverride: gridOverride,
            onLaunchInputCompletion: onLaunchInputCompletion
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
        let initialRecoveryLimits = ScrollbackRetention.checkpoint.primaryHistoryLimits
        let initialRecoveryCandidate = session.readPrimaryHistoryTail(
            maxLines: initialRecoveryLimits.maxLines,
            maxChars: initialRecoveryLimits.maxChars
        ) ?? ""
        session.onPrimaryHistoryMutation = { [weak self] in self?.notePrimaryHistoryMutation() }
        let subscriptionToken = schedulingLifecycle.arm(.subscription, cancel: {
            session.onEvent = nil
            session.currentAgentWaitGeneration = nil
            session.onPrimaryHistoryMutation = nil
        })
        session.setRenderingAvailable(renderingAvailable)
        if normalizeCheckpointScrollback(initialRecoveryCandidate) != nil {
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

    private func viewportCellsJSON(_ readout: TerminalSessionViewportCells) -> JSONValue {
        let rows: [JSONValue] = readout.rows.map { row in
            let spans: [JSONValue] = row.spans.map { span in
                var fields: [String: JSONValue] = [
                    "kind": .string(span.kind),
                    "column": .number(Double(span.column)),
                    "cellWidth": .number(Double(span.cellWidth)),
                ]
                if let text = span.text { fields["text"] = .string(text) }
                if let offsets = span.utf8Offsets {
                    fields["utf8Offsets"] = .array(offsets.map { .number(Double($0)) })
                }
                return .object(fields)
            }
            return .object([
                "index": .number(Double(row.index)),
                "spans": .array(spans),
            ])
        }
        return .object([
            "columns": .number(Double(readout.columns)),
            "rowCount": .number(Double(readout.rowCount)),
            "paneRowsOrigin": .number(Double(readout.paneRowsOrigin)),
            "rows": .array(rows),
        ])
    }

    private func showImportError(message: String) {
        send(.noticeReported(.message(title: "Import Failed", message: message)))
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
