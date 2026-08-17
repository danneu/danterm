// Owns connection lifecycle, pane selection, and normalized phone input for the UIKit shell.
//
// Reconnect timing is not decided here. `MobileReconnectPolicy` answers when an attempt may
// run; this file only supplies the things a pure state machine cannot observe -- the clock,
// the network path, the app's lifecycle, the user's gestures, and the typed cause each
// connection ended with -- and performs the one decision it gets back.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Foundation
import Network
import UIKit

/// Keeps every UIKit state transition on the main actor while sessions block elsewhere.
@MainActor
final class MobileRootViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let connectionHeader = ConnectionHeaderView()
    private let paneTable = UITableView(frame: .zero, style: .plain)
    private let terminalView = TerminalSurfaceView()
    private let composer = TerminalComposerView()

    private var panes: [MobilePaneListItem] = []
    private var selectedPaneId: PaneId?
    /// The target and pane the current episode is about. Every attempt in an episode --
    /// the gesture's and the policy's alike -- reuses them, so an automatic retry cannot
    /// silently follow a half-typed host field.
    private var target: MobileServerTarget?
    private var preferredPaneId: PaneId?
    private var reconnectPolicy = MobileReconnectPolicy()
    private var retryTimer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var presentedState = MobileConnectionState.disconnected
    private var presentedDetail: String?
    private var attempt: MobileSessionAttempt?
    private var runner: MobileConnectionRunner?
    private var runnerThread: Thread?
    private var tapeRequestId: JSONValue?
    private var inputMapper = MobileInputMapper()
    private var observers: [NSObjectProtocol] = []
    private var connectionGeneration = 0
    private var didSendSmokeInput = false
    private var checkpointSaveTimer: Timer?
    private var checkpointIsDirty = false
    private var isWaitingForGapRepair = false
    private let checkpointQueue = DispatchQueue(label: "danterm.mobile.checkpoint")
    private lazy var checkpointStore = PaneReplicaCheckpointStore(
        directory: FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("DanTermMobile", isDirectory: true)
    )

    private static let checkpointInterval: TimeInterval = 30

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureViews()
        configureLifecycle()
        loadTarget()
        if connectionHeader.hostText?.isEmpty == false { requestConnect(preferredPane: nil) }
    }

    isolated deinit {
        flushCheckpoint(synchronously: true)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        retryTimer?.invalidate()
        pathMonitor.cancel()
        attempt?.cancel()
        runner?.cancel()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            let modifiers = key.modifierFlags.mobileModifiers
            if let named = key.keyCode.mobileNamedKey {
                send(inputMapper.hardwareKey(named, modifiers: modifiers))
                handled = true
            } else if modifiers.isEmpty == false,
                      let character = key.charactersIgnoringModifiers.lowercased().first
            {
                send(inputMapper.hardwareCharacter(character, modifiers: modifiers))
                handled = true
            }
        }
        if handled == false { super.pressesBegan(presses, with: event) }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        panes.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "pane", for: indexPath)
        let pane = panes[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = pane.paneTitle
        content.secondaryText = "\(pane.groupName) / \(pane.tabTitle)"
        cell.contentConfiguration = content
        cell.accessoryType = pane.paneId == selectedPaneId ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        requestConnect(preferredPane: panes[indexPath.row].paneId)
    }

    private func configureViews() {
        connectionHeader.onConnect = { [weak self] in
            self?.requestConnect(preferredPane: self?.selectedPaneId)
        }
        paneTable.dataSource = self
        paneTable.delegate = self
        paneTable.rowHeight = UITableView.automaticDimension
        paneTable.estimatedRowHeight = 52
        paneTable.register(UITableViewCell.self, forCellReuseIdentifier: "pane")
        composer.onText = { [weak self] text in
            self?.send(self?.inputMapper.text(text))
        }
        composer.onPaste = { [weak self] text in
            self?.send(self?.inputMapper.paste(text))
        }
        composer.onAccessoryKey = { [weak self] key in
            guard let self else { return false }
            send(inputMapper.accessory(key))
            return inputMapper.isControlLatched
        }
        composer.onDismissKeyboard = { [weak self] in self?.view.endEditing(true) }
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        terminalView.addGestureRecognizer(scroll)
        terminalView.didAdvanceReplica = { [weak self] in self?.scheduleCheckpoint() }
        terminalView.didChangeReplicaState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .gap:
                isWaitingForGapRepair = true
                show(state: .connectionLost, detail: "Stream gap; waiting for exact state")
            case .exact where isWaitingForGapRepair:
                isWaitingForGapRepair = false
                show(state: .ready, detail: "Stream repaired with exact state")
            case .awaitingSynchronization, .exact:
                break
            }
        }
        for subview in [connectionHeader, paneTable, terminalView, composer]
        {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        configureConstraints()
    }

    private func configureConstraints() {
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        let preferredTableHeight = paneTable.heightAnchor.constraint(
            equalTo: view.heightAnchor,
            multiplier: 0.2
        )
        preferredTableHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            connectionHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            connectionHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            connectionHeader.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),

            paneTable.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paneTable.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paneTable.topAnchor.constraint(equalTo: connectionHeader.bottomAnchor, constant: 4),
            paneTable.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            paneTable.heightAnchor.constraint(lessThanOrEqualToConstant: 150),
            preferredTableHeight,

            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: paneTable.bottomAnchor),
            terminalView.bottomAnchor.constraint(equalTo: composer.topAnchor),

            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    private func configureLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushCheckpoint(synchronously: true)
                self.disconnect()
                // After the teardown, so the policy learns that this connection is one the
                // app dropped itself and still owes on return.
                self.dispatch(.appBackgrounded)
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dispatch(.appForegrounded) }
        })
        // The phone's own side of the world is observable, so the policy is told about it
        // instead of discovering it by failing an attempt that never had a chance.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            Task { @MainActor in self?.dispatch(.networkPathChanged(usable: usable)) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "danterm.mobile.path"))
    }

    private func loadTarget() {
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        connectionHeader.hostText = environment["DANTERM_IOS_HOST"]
            ?? defaults.string(forKey: "serverHost")
        connectionHeader.portText = environment["DANTERM_IOS_PORT"]
            ?? defaults.string(forKey: "serverPort") ?? "7420"
    }

    /// Starts an episode from the user's own gesture: the Go button, a pane row, or launch.
    ///
    /// The gesture is the manual remedy itself, so it goes to the policy rather than
    /// straight to a socket -- that is what lets it restore the budget from any rest.
    private func requestConnect(preferredPane: PaneId?) {
        guard let host = connectionHeader.hostText?.trimmingCharacters(in: .whitespacesAndNewlines),
              host.isEmpty == false,
              let portText = connectionHeader.portText,
              let port = UInt16(portText)
        else {
            // No target means no episode to start. The policy is left alone deliberately:
            // a typo in the field must not cancel a retry already owed to a good target.
            show(state: .deviceSetupFailure, detail: "Enter a host and port")
            return
        }
        UserDefaults.standard.set(host, forKey: "serverHost")
        UserDefaults.standard.set(portText, forKey: "serverPort")
        target = MobileServerTarget(host: host, port: port)
        preferredPaneId = preferredPane
        dispatch(.userRequestedConnect)
    }

    /// Feeds the policy one event and performs the single decision it returns.
    private func dispatch(_ event: MobileReconnectEvent) {
        let moment = ProcessInfo.processInfo.systemUptime
        switch reconnectPolicy.handle(event, at: moment) {
        case .attemptNow:
            cancelRetryTimer()
            startAttempt()
        case .wait(let until):
            cancelRetryTimer()
            retryTimer = Timer.scheduledTimer(
                withTimeInterval: max(0, until - moment),
                repeats: false
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dispatch(.clockFired) }
            }
        case .rest:
            cancelRetryTimer()
        }
        refreshStatus()
    }

    private func startAttempt() {
        // The policy only says `attemptNow` inside an episode a gesture started, and a
        // gesture always validates the target first.
        guard let target else { return }
        flushCheckpoint(synchronously: true)
        disconnect()
        let generation = connectionGeneration
        show(state: .connecting, detail: "Connecting to \(target.host):\(target.port)")
        let attempt = MobileSessionAttempt(host: target.host, port: target.port)
        self.attempt = attempt
        attempt.start { [weak self] result in
            Task { @MainActor in
                guard self?.connectionGeneration == generation else {
                    if case .connected(let bootstrap) = result { bootstrap.session.cancel() }
                    return
                }
                self?.finish(result)
            }
        }
    }

    private func finish(_ result: MobileSessionBootstrapResult) {
        attempt = nil
        switch result {
        case .failed(let failure):
            fail(failure)
        case .connected(let bootstrap):
            panes = bootstrap.panes
            paneTable.reloadData()
            guard let pane = preferredPaneId
                .flatMap({ wanted in panes.first { $0.paneId == wanted } })
                ?? panes.first(where: { $0.isSelectedTab && $0.isFocused })
                ?? panes.first
            else {
                bootstrap.session.cancel()
                fail(.requestRefused(reason: "The Mac has no panes"))
                return
            }
            selectedPaneId = pane.paneId
            isWaitingForGapRepair = false
            paneTable.reloadData()
            let checkpoint = storedCheckpoint(for: pane.paneId)
            let cursor = terminalView.reset(checkpoint: checkpoint, for: pane.paneId)
            guard startStream(bootstrap.session, pane: pane.paneId, cursor: cursor) else { return }
            show(state: .ready, detail: "Connected to DanTerm \(bootstrap.serverVersion)")
            dispatch(.attemptConnected)
        }
    }

    /// Subscribes the chosen pane's tape and starts its reader. Returns false when the
    /// subscription itself failed, so the caller does not report a connection that is
    /// already over.
    private func startStream(
        _ session: DanTermClientSession,
        pane: PaneId,
        cursor: PaneTapeCursor?
    ) -> Bool {
        let requestId = JSONValue.string(UUID().uuidString)
        let request = IpcRequest.paneTape(
            pane: pane,
            follow: true,
            start: cursor.map(PaneTapeStartPosition.cursor) ?? .now,
            mode: .reconstructible
        )
        do {
            try session.send(JsonRpcRequest(
                id: requestId,
                method: request.method.rawValue,
                params: .object(request.params)
            ))
        } catch {
            session.cancel()
            fail(.transport(.writeFailed, phase: .established))
            return false
        }
        tapeRequestId = requestId
        let runner = MobileConnectionRunner(session: session) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
        }
        self.runner = runner
        let thread = Thread { runner.run() }
        thread.name = "danterm-mobile-stream"
        thread.start()
        runnerThread = thread
        if didSendSmokeInput == false,
           let smokeInput = ProcessInfo.processInfo.environment["DANTERM_IOS_SMOKE_INPUT"],
           smokeInput.isEmpty == false
        {
            didSendSmokeInput = true
            send(inputMapper.text(smokeInput))
        }
        return true
    }

    private func receive(_ event: MobileConnectionRunnerEvent) {
        switch event {
        case .failed(let failure):
            fail(failure)
        case .frame(let frame):
            receive(frame)
        }
    }

    private func receive(_ frame: DanTermClientFrame) {
        switch frame {
        case .response(let response):
            if let error = response.error {
                // Only the tape subscription's refusal ends the connection, because the
                // subscription is what the connection is for. A refused input request
                // leaves a stream that is still serving.
                if response.id == tapeRequestId {
                    fail(.requestRefused(reason: error.message))
                } else {
                    show(state: .requestRefused(reason: error.message))
                }
                return
            }
            guard response.id == tapeRequestId,
                  let value = response.result,
                  let record = decodePaneTapeRecord(value)
            else { return }
            apply(record)
        case .notification(let method, let params):
            guard let notification = PaneTapeStreamNotification(method: method, params: params),
                  let record = decodePaneTapeRecord(notification.record)
            else { return }
            apply(record)
        }
    }

    private func apply(_ record: PaneTapeRecord) {
        do {
            try terminalView.apply(record)
            if case .end(let reason) = record {
                fail(.streamEnded(reason: reason?.rawValue))
            }
        } catch {
            fail(.deviceSetup, detail: "Replica rejected the stream")
        }
    }

    /// Ends the current connection on one typed cause and lets the policy decide what
    /// follows it.
    ///
    /// The teardown comes first and is what makes the cause unique: it fences the runner,
    /// so a stream that ended and then reported its read error cannot hand the policy a
    /// second, differently classified cause for the same connection.
    private func fail(_ failure: MobileConnectionFailure, detail: String? = nil) {
        disconnect()
        show(state: failure.state, detail: detail)
        dispatch(.attemptFailed(failure))
    }

    private func disconnect() {
        connectionGeneration += 1
        attempt?.cancel()
        attempt = nil
        runner?.cancel()
        runner = nil
        runnerThread = nil
        tapeRequestId = nil
    }

    private func send(_ action: MobileInputAction?) {
        guard let action, let pane = selectedPaneId else { return }
        switch action {
        case .scrollViewport(let rows):
            terminalView.scrollViewport(byRows: rows)
        case .send(let input):
            let request = IpcRequest.paneInput(pane: pane, input: input)
            do {
                try runner?.send(JsonRpcRequest(
                    id: .string(UUID().uuidString),
                    method: request.method.rawValue,
                    params: .object(request.params)
                ))
            } catch {
                fail(.transport(.writeFailed, phase: .established))
            }
        }
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let direction: InputWheelDirection = recognizer.translation(in: terminalView).y > 0 ? .up : .down
        send(inputMapper.scroll(
            direction,
            column: 0,
            row: 0,
            alternateScreen: terminalView.isAlternateScreenActive
        ))
    }

    private func show(state: MobileConnectionState, detail: String? = nil) {
        presentedState = state
        presentedDetail = detail
        refreshStatus()
    }

    /// Presents the causal state with the pending recovery beside it, never instead of it:
    /// the user needs both what happened and what the app is doing about it, and rest after
    /// give-up is the plain state with its own manual remedy.
    private func refreshStatus() {
        let moment = ProcessInfo.processInfo.systemUptime
        let causal = presentedDetail ?? presentedState.label
        let recovery = reconnectPolicy.recoveryPhase(at: moment).label(at: moment)
        connectionHeader.showStatus(
            recovery.map { "\(causal) - \($0)" } ?? causal,
            color: presentedState.isFailure ? .systemRed : .secondaryLabel
        )
    }

    private func cancelRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func scheduleCheckpoint() {
        checkpointIsDirty = true
        guard checkpointSaveTimer == nil else { return }
        checkpointSaveTimer = Timer.scheduledTimer(
            withTimeInterval: Self.checkpointInterval,
            repeats: false
        ) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.flushCheckpoint(synchronously: false) }
        }
    }

    private func flushCheckpoint(synchronously: Bool) {
        checkpointSaveTimer?.invalidate()
        checkpointSaveTimer = nil
        let source = checkpointIsDirty ? terminalView.checkpointSource() : nil
        checkpointIsDirty = false
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

    private func storedCheckpoint(for pane: PaneId) -> PaneReplicaCheckpoint? {
        checkpointStore.load(for: pane)
    }
}

/// One validated server address, so an automatic attempt reuses what the gesture checked
/// rather than re-reading text fields the user may be halfway through editing.
private struct MobileServerTarget {
    let host: String
    let port: UInt16
}

private extension MobileRecoveryPhase {
    /// Words the pending recovery, or nothing when there is none to report.
    func label(at now: TimeInterval) -> String? {
        switch self {
        case .none: nil
        case .attempting: "reconnecting"
        case .waiting(let until): "retrying in \(Int(max(0, until - now).rounded(.up)))s"
        case .waitingForNetwork: "waiting for network"
        }
    }
}

private extension UIKeyModifierFlags {
    var mobileModifiers: KeyMods {
        var result: KeyMods = []
        if contains(.control) { result.insert(.ctrl) }
        if contains(.alternate) { result.insert(.alt) }
        if contains(.shift) { result.insert(.shift) }
        return result
    }
}

private extension UIKeyboardHIDUsage {
    var mobileNamedKey: NamedKey? {
        switch self {
        case .keyboardReturnOrEnter: .enter
        case .keyboardTab: .tab
        case .keyboardDeleteOrBackspace: .bspace
        case .keyboardEscape: .escape
        case .keyboardUpArrow: .up
        case .keyboardDownArrow: .down
        case .keyboardLeftArrow: .left
        case .keyboardRightArrow: .right
        case .keyboardHome: .home
        case .keyboardEnd: .end
        case .keyboardPageUp: .pgUp
        case .keyboardPageDown: .pgDn
        case .keyboardInsert: .insert
        case .keyboardDeleteForward: .delete
        default: nil
        }
    }
}

private extension MobileConnectionState {
    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .listingPanes: "Loading panes"
        case .ready: "Connected"
        case .hostNotFound: "Host not found"
        case .serverUnreachable: "Server unreachable"
        case .refusedByMac(let reason): "Refused by the Mac: \(reason.label)"
        case .versionMismatch(let version): "Version mismatch: protocol \(version)"
        case .connectionLost: "Connection lost"
        case .deviceSetupFailure: "Device setup failure"
        case .streamEnded(let reason): "Stream ended\(reason.map { ": \($0)" } ?? "")"
        case .requestRefused(let reason): "Request refused: \(reason)"
        }
    }

    var isFailure: Bool {
        switch self {
        case .disconnected, .connecting, .listingPanes, .ready: false
        default: true
        }
    }
}

private extension MobileMacRefusal {
    var label: String {
        switch self {
        case .notAdmitted: "node not admitted"
        case .identityUnresolved: "identity unresolved"
        case .connectionLimit: "connection limit"
        case .auditUnavailable: "audit unavailable"
        }
    }
}
