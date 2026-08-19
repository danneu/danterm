// Performs the phone session's effects, and nothing else.
//
// This is the app-shell half of the session: it holds what cannot be pure -- the runner
// thread, the deadline timers, the network path monitor, the checkpoint file, and the
// terminal surface -- and does one job. It turns a callback into an event, calls
// `MobileSessionModel.handle`, and performs the effects it gets back in array order.
//
// It makes no decision of its own and stores no session fact the model owns: no
// connection state, no pane list, no selection, no draft. That matters because the iOS app
// package is an executable with no test target, so a fact kept here is a fact with no test.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Foundation
import Network
import UIKit

/// Owns the phone session's side effects and the one model they are decided by.
@MainActor
final class MobileSessionController {
    /// The surface the session draws its pane on. The controller owns it because several
    /// effects act on it; the view controller only places it.
    let surfaceView = TerminalSurfaceView()

    /// The terminal's own text-input target, owned here for the same reason the surface
    /// is: the smoke probe is an effect performed on it.
    let inputView = TerminalInputView()

    /// The scroll chrome over the surface, owned beside it because the two are one thing to
    /// the session: the chrome describes this surface's engine, and every effect that moves
    /// that engine's viewport has to reach both.
    let scrollChrome = TerminalScrollChromeView()

    /// Called whenever a redraw effect is performed, with everything the surfaces render.
    var didUpdate: ((MobileSessionProjection) -> Void)?

    private var model = MobileSessionModel()
    /// Events waiting to be handled. A perform can produce an event -- a failed write, a
    /// record the replica refused -- so events are queued and drained by one loop rather
    /// than re-entering `handle` in the middle of an effect array.
    private var pendingEvents: [PendingEvent] = []
    private var isDraining = false

    private let retryTimer = MobileDeadlineTimer()
    private let checkpointTimer = MobileDeadlineTimer()
    private let pathMonitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []

    private var attempt: MobileSessionAttempt?
    /// The handshaken session between the attempt succeeding and its stream starting. The
    /// runner takes ownership once the subscription is sent.
    private var pendingSession: DanTermClientSession?
    private var runner: MobileConnectionRunner?
    private var runnerThread: Thread?
    /// Fences callbacks from a connection that has been torn down.
    private var connectionGeneration = 0

    private let checkpointQueue = DispatchQueue(label: "danterm.mobile.checkpoint")
    private lazy var checkpointStore = PaneReplicaCheckpointStore(
        directory: FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("DanTermMobile", isDirectory: true)
    )

    private enum PendingEvent {
        case session(MobileSessionEvent)
        case geometry(MobileSessionGeometryEvent)
    }

    /// Wires the observed world to events and launches the session.
    func start() {
        surfaceView.didAdvanceReplica = { [weak self] in self?.dispatch(.replicaAdvanced) }
        surfaceView.didChangeReplicaState = { [weak self] state in
            guard let self else { return }
            dispatch(.replicaStateChanged(state))
            surfaceDidLayout()
        }
        surfaceView.didLayout = { [weak self] in self?.surfaceDidLayout() }
        scrollChrome.surface = surfaceView
        scrollChrome.onScrollToTopRow = { [weak self] row in
            self?.dispatch(.scrolledToTopRow(row))
        }
        scrollChrome.onScrollByRows = { [weak self] rows, column, row in
            self?.dispatch(.scrolledByRows(rows, column: column, row: row))
        }
        inputView.onText = { [weak self] text in self?.dispatch(.textEntered(text)) }
        inputView.onDeleteBackward = { [weak self] in self?.dispatch(.deleteBackwardPressed) }
        inputView.onPaste = { [weak self] text in self?.dispatch(.pasted(text)) }
        observeLifecycle()
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        dispatch(.launched(MobileLaunchInputs(
            environmentHost: environment["DANTERM_IOS_HOST"],
            environmentPort: environment["DANTERM_IOS_PORT"],
            storedHost: defaults.string(forKey: "serverHost"),
            storedPort: defaults.string(forKey: "serverPort"),
            smokeInput: environment["DANTERM_IOS_SMOKE_INPUT"]
        )))
    }

    isolated deinit {
        // The model cannot be consulted from here, so the position is written
        // unconditionally: the snapshot is only taken when the replica is exact, and a
        // repeat of the last write costs one file and changes nothing.
        flushCheckpoint(savingReplica: true, synchronously: true)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        retryTimer.cancel()
        checkpointTimer.cancel()
        pathMonitor.cancel()
        attempt?.cancel()
        pendingSession?.cancel()
        runner?.cancel()
    }

    /// Everything the surfaces render right now, for a caller that needs it outside a
    /// redraw -- the first paint before any event has been handled.
    var projection: MobileSessionProjection {
        model.projection(at: MobileMonotonicClock.now)
    }

    func dispatch(_ event: MobileSessionEvent) {
        pendingEvents.append(.session(event))
        drain()
    }

    func dispatch(_ event: MobileSessionGeometryEvent) {
        pendingEvents.append(.geometry(event))
        drain()
    }

    /// Reports the surface's current facts. The extent decides whether a whole cell fits,
    /// which is one of the facts the claim control projects from, so a layout pass is one
    /// of the things the session has to be told about. The report is a geometry event:
    /// while the model holds a standing claim, a rotated grid renews that claim, so this
    /// is one of the inputs allowed to produce a resize.
    ///
    /// The scroll chrome reads the same moment, because the projection it mirrors and the
    /// grid it overlays both move for exactly these reasons.
    private func surfaceDidLayout() {
        scrollChrome.refresh()
        dispatch(.surfaceChanged(MobileSurfaceFacts(
            nativeGrid: surfaceView.nativeGrid,
            pinned: surfaceView.pinned,
            isAlternateScreenActive: surfaceView.isAlternateScreenActive
        )))
    }

    private func drain() {
        guard isDraining == false else { return }
        isDraining = true
        defer { isDraining = false }
        while pendingEvents.isEmpty == false {
            let event = pendingEvents.removeFirst()
            let env = MobileSessionEnv(
                now: MobileMonotonicClock.now,
                newRequestId: { .string(UUID().uuidString) }
            )
            let effects: [MobileSessionGeometryEffect]
            switch event {
            case .session(let event):
                effects = model.handle(event, env: env).map(MobileSessionGeometryEffect.session)
            case .geometry(let event):
                effects = model.handle(event, env: env)
            }
            for effect in effects { perform(effect) }
        }
    }

    private func perform(_ effect: MobileSessionGeometryEffect) {
        switch effect {
        case .session(let effect):
            perform(effect)
        case .resizePane(let requestId, let request):
            send(requestId: requestId, request: request)
        }
    }

    private func perform(_ effect: MobileSessionEffect) {
        switch effect {
        case .connect(let target):
            connect(to: target)
        case .disconnect:
            disconnect()
        case .storeTarget(let host, let port):
            UserDefaults.standard.set(host, forKey: "serverHost")
            UserDefaults.standard.set(port, forKey: "serverPort")
        case .attachPane(let pane, let resumesFromStoredCheckpoint):
            let stored = resumesFromStoredCheckpoint ? checkpointStore.load(for: pane) : nil
            let cursor = surfaceView.reset(checkpoint: stored, for: pane)
            dispatch(.paneAttached(pane: pane, cursor: cursor))
        case .beginStream(let requestId, let request):
            beginStream(requestId: requestId, request: request.request)
        case .send(let requestId, let request):
            send(requestId: requestId, request: request.request)
        case .applyRecord(let record):
            do {
                try surfaceView.apply(record)
                dispatch(.recordApplied(record))
            } catch {
                dispatch(.replicaRejectedRecord)
            }
        case .scrollViewport(let scroll):
            surfaceView.scrollViewport(scroll)
            // The engine's viewport moved without a record arriving, so the chrome is told
            // here. It reflects nothing while the gesture that asked for this is still in
            // progress; the reconciliation happens when the gesture ends.
            scrollChrome.refresh()
        case .flushCheckpoint(let savingReplica, let synchronously):
            flushCheckpoint(savingReplica: savingReplica, synchronously: synchronously)
        case .armRetryTimer(let deadline):
            // The model's moment is handed over as it stands. No arithmetic here: the
            // instrument reads the clock the deadline was computed on.
            retryTimer.schedule(until: deadline) { [weak self] in self?.dispatch(.retryTimerFired) }
        case .cancelRetryTimer:
            retryTimer.cancel()
        case .armCheckpointTimer(let deadline):
            checkpointTimer.schedule(until: deadline) { [weak self] in
                self?.dispatch(.checkpointTimerFired)
            }
        case .driveSmokeInput(let steps):
            inputView.drive(steps)
        case .redraw:
            didUpdate?(projection)
        }
    }

    private func connect(to target: MobileServerTarget) {
        let generation = connectionGeneration
        let attempt = MobileSessionAttempt(host: target.host, port: target.port)
        self.attempt = attempt
        attempt.start { [weak self] result in
            Task { @MainActor in
                guard self?.connectionGeneration == generation else {
                    if case .connected(let bootstrap) = result { bootstrap.session.cancel() }
                    return
                }
                guard let self else { return }
                switch result {
                case .failed(let failure):
                    self.dispatch(.connectionEnded(failure))
                case .connected(let bootstrap):
                    self.pendingSession = bootstrap.session
                    self.dispatch(.attemptSucceeded(
                        roster: bootstrap.roster,
                        serverVersion: bootstrap.serverVersion
                    ))
                }
            }
        }
    }

    private func disconnect() {
        connectionGeneration += 1
        attempt?.cancel()
        attempt = nil
        pendingSession?.cancel()
        pendingSession = nil
        runner?.cancel()
        runner = nil
        runnerThread = nil
    }

    /// Subscribes the chosen pane's tape on the established session and starts its reader.
    private func beginStream(requestId: JSONValue, request: IpcRequest) {
        guard let session = pendingSession else { return }
        pendingSession = nil
        do {
            try session.send(JsonRpcRequest(
                id: requestId,
                method: request.method.rawValue,
                params: .object(request.params)
            ))
        } catch {
            session.cancel()
            dispatch(.connectionEnded(.transport(.writeFailed, phase: .established)))
            return
        }
        let runner = MobileConnectionRunner(session: session) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event {
                case .failed(let failure): self.dispatch(.connectionEnded(failure))
                case .frame(let frame): self.dispatch(.frameReceived(frame))
                }
            }
        }
        self.runner = runner
        let thread = Thread { runner.run() }
        thread.name = "danterm-mobile-stream"
        thread.start()
        runnerThread = thread
    }

    private func send(requestId: JSONValue, request: IpcRequest) {
        do {
            try runner?.send(JsonRpcRequest(
                id: requestId,
                method: request.method.rawValue,
                params: .object(request.params)
            ))
        } catch {
            dispatch(.connectionEnded(.transport(.writeFailed, phase: .established)))
        }
    }

    private func flushCheckpoint(savingReplica: Bool, synchronously: Bool) {
        checkpointTimer.cancel()
        let source = savingReplica ? surfaceView.checkpointSource() : nil
        let store = checkpointStore
        let work: @Sendable () -> Void = {
            guard let source, let checkpoint = source.replica.checkpoint(for: source.paneId)
            else { return }
            try? store.save(checkpoint)
        }
        if synchronously {
            checkpointQueue.sync(execute: work)
        } else if source != nil {
            checkpointQueue.async(execute: work)
        }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dispatch(.appBackgrounded) }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dispatch(.appForegrounded) }
        })
        // The phone's own side of the world is observable, so the session is told about it
        // instead of discovering it by failing an attempt that never had a chance.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            Task { @MainActor in self?.dispatch(.networkPathChanged(usable: usable)) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "danterm.mobile.path"))
    }
}
