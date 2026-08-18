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
    private let claimBar = UIStackView()
    private let claimButton = UIButton(type: .system)
    private let releaseButton = UIButton(type: .system)

    private var panes: [MobilePaneListItem] = []
    private var selectedPaneId: PaneId?
    /// The target and pane the current episode is about. Every attempt in an episode --
    /// the gesture's and the policy's alike -- reuses them, so an automatic retry cannot
    /// silently follow a half-typed host field.
    private var connectTarget = MobileConnectTarget()
    private var preferredPaneId: PaneId?
    private var reconnectPolicy = MobileReconnectPolicy()
    private var resumePolicy = MobileResumePolicy()
    private let retryTimer = MobileDeadlineTimer()
    private let pathMonitor = NWPathMonitor()
    private var status = MobileStatus()
    private var attempt: MobileSessionAttempt?
    private var runner: MobileConnectionRunner?
    private var runnerThread: Thread?
    private var tapeRequestId: JSONValue?
    private var inputMapper = MobileInputMapper()
    private var observers: [NSObjectProtocol] = []
    private var connectionGeneration = 0
    private var didSendSmokeInput = false
    private let checkpointSaveTimer = MobileDeadlineTimer()
    private var checkpointIsDirty = false
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
        loadDraftFields()
        // A first launch with no stored host has nothing to say about the empty field yet.
        if connectionHeader.hostText?.isEmpty == false {
            requestConnectToTypedTarget(preferredPane: nil)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The terminal's extent decides whether a whole cell fits, which is one of the
        // facts the claim control projects from.
        refreshClaimControl()
    }

    isolated deinit {
        flushCheckpoint(synchronously: true)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        retryTimer.cancel()
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
        requestConnectToPane(panes[indexPath.row].paneId)
    }

    private func configureViews() {
        connectionHeader.onConnect = { [weak self] in
            self?.requestConnectToTypedTarget(preferredPane: self?.selectedPaneId)
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
        configureGeometryButton(claimButton, title: "Claim", action: #selector(claimTapped))
        configureGeometryButton(releaseButton, title: "Release", action: #selector(releaseTapped))
        claimBar.axis = .horizontal
        claimBar.alignment = .center
        claimBar.distribution = .fillEqually
        claimBar.spacing = 8
        claimBar.isLayoutMarginsRelativeArrangement = true
        claimBar.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 4,
            leading: 8,
            bottom: 4,
            trailing: 8
        )
        claimBar.addArrangedSubview(claimButton)
        claimBar.addArrangedSubview(releaseButton)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        terminalView.addGestureRecognizer(scroll)
        terminalView.didAdvanceReplica = { [weak self] in self?.scheduleCheckpoint() }
        terminalView.didChangeReplicaState = { [weak self] state in
            guard let self else { return }
            status.noteStream(state)
            switch state {
            // The producer never learns of a gap the replica found for itself, so it sends
            // no repair. Ending the connection is what puts the one recovery mechanism in
            // charge of it, and the next attempt starts away from the disputed position.
            case .gap(.detected):
                fail(.streamDesynchronized)
            case .exact:
                resumePolicy.replicaBecameExact()
                refreshProjections()
            case .gap(.declared), .awaitingSynchronization:
                refreshProjections()
            }
        }
        for subview in [connectionHeader, paneTable, terminalView, claimBar, composer]
        {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        configureConstraints()
        refreshClaimControl()
    }

    /// Gives both geometry buttons the one appearance, so the pair reads as two forms of
    /// the same control rather than two unrelated actions.
    private func configureGeometryButton(_ button: UIButton, title: String, action: Selector) {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.cornerStyle = .capsule
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(self, action: action, for: .touchUpInside)
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
            terminalView.bottomAnchor.constraint(equalTo: claimBar.topAnchor),

            // The bar sits beside the terminal rather than over it, so no cell is ever
            // drawn underneath it, claimed or not.
            claimBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            claimBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            claimBar.bottomAnchor.constraint(equalTo: composer.topAnchor),
            claimBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

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

    private func loadDraftFields() {
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        connectionHeader.hostText = environment["DANTERM_IOS_HOST"]
            ?? defaults.string(forKey: "serverHost")
        connectionHeader.portText = environment["DANTERM_IOS_PORT"]
            ?? defaults.string(forKey: "serverPort") ?? "7420"
    }

    /// The gesture that names a server: the Go button, or the attempt made at launch.
    private func requestConnectToTypedTarget(preferredPane: PaneId?) {
        let draft = MobileTargetDraft(
            host: connectionHeader.hostText,
            port: connectionHeader.portText
        )
        startEpisode(connectTarget.setTarget(from: draft), preferredPane: preferredPane)
    }

    /// The gesture that names a pane inside the episode that produced the list. It never
    /// consults the text fields, so editing them cannot retarget or block it.
    private func requestConnectToPane(_ pane: PaneId) {
        startEpisode(connectTarget.reuseTarget(), preferredPane: pane)
    }

    /// Starts an episode from the user's own gesture, or reports why it cannot.
    ///
    /// The gesture is the manual remedy itself, so it goes to the policy rather than
    /// straight to a socket -- that is what lets it restore the budget from any rest.
    private func startEpisode(_ gesture: MobileConnectGesture, preferredPane: PaneId?) {
        switch gesture {
        case .connect(let target):
            connectionHeader.showDraftProblem(nil)
            UserDefaults.standard.set(target.host, forKey: "serverHost")
            UserDefaults.standard.set(String(target.port), forKey: "serverPort")
            preferredPaneId = preferredPane
            dispatch(.userRequestedConnect)
        case .reportDraft(let problem):
            // A field problem is reported beside its field and nowhere else. The policy is
            // left alone deliberately: a typo must not cancel a retry already owed to a
            // good target.
            connectionHeader.showDraftProblem(problem.label)
        case .ignore:
            break
        }
    }

    /// Feeds the policy one event and performs the single decision it returns.
    private func dispatch(_ event: MobileReconnectEvent) {
        let moment = MobileMonotonicClock.now
        switch reconnectPolicy.handle(event, at: moment) {
        case .attemptNow:
            retryTimer.cancel()
            startAttempt()
        case .wait(let until):
            // The policy's moment is handed over as it stands. No arithmetic here: the
            // instrument reads the clock the policy computed `until` on.
            retryTimer.schedule(until: until) { [weak self] in self?.dispatch(.clockFired) }
        case .rest:
            retryTimer.cancel()
        }
        refreshProjections()
    }

    private func startAttempt() {
        // The policy only says `attemptNow` inside an episode a gesture started, and a
        // gesture only starts one against a target it resolved.
        guard let target = connectTarget.established else { return }
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
            paneTable.reloadData()
            let checkpoint = resumePolicy.resumeCheckpoint(
                stored: storedCheckpoint(for: pane.paneId)
            )
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
                // subscription is what the connection is for. A refused input request is
                // the newest outcome on a stream that is still serving, and the next
                // completed request replaces it.
                if response.id == tapeRequestId {
                    fail(.requestRefused(reason: error.message))
                } else {
                    status.noteRequestOutcome(.refused(reason: error.message))
                    refreshProjections()
                }
                return
            }
            guard response.id == tapeRequestId else {
                status.noteRequestOutcome(.succeeded)
                refreshProjections()
                return
            }
            guard let value = response.result,
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
        resumePolicy.connectionEnded(with: failure)
        dispatch(.attemptFailed(failure))
    }

    private func disconnect() {
        // The stream condition and the last request outcome both describe the connection
        // that is going away, so they go with it rather than being shown beside the next.
        status.noteStream(nil)
        status.noteRequestOutcome(nil)
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
            send(IpcRequest.paneInput(pane: pane, input: input))
        }
    }

    private func send(_ request: IpcRequest) {
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

    /// Claims the selected pane for this phone: one ordinary resize carrying the grid
    /// this surface runs at. No other gesture here sends one, which is what keeps
    /// typing and scrolling from claiming.
    @objc private func claimTapped() {
        guard let request = claimControl.claim else { return }
        send(request)
    }

    /// Gives the pane back to the grid its Mac slot implies. It acts on the override's
    /// presence, not on who set it, so it is the phone's exit from any pinned pane.
    @objc private func releaseTapped() {
        guard let request = claimControl.release else { return }
        send(request)
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
        status.noteConnection(state, detail: detail)
        refreshProjections()
    }

    /// Re-renders everything the shell projects from its stored facts -- the status line
    /// and the claim control -- so both stay projections instead of remembered UI state.
    /// Every path that moves one of those facts ends here.
    ///
    /// Reads the recovery phase, which only the policy knows, and renders whatever the four
    /// facts compose to. No wording or severity is decided here.
    private func refreshProjections() {
        let moment = MobileMonotonicClock.now
        status.noteRecovery(reconnectPolicy.recoveryPhase(at: moment))
        let line = status.line(at: moment)
        connectionHeader.showStatus(line.text, color: line.severity.color)
        refreshClaimControl()
    }

    /// Shows exactly the geometry actions the phone can send right now, and stores none of
    /// them: the projection is recomputed from the facts every time one of them moves.
    private func refreshClaimControl() {
        let control = claimControl
        // Only the buttons hide. The bar keeps its layout space either way, so the
        // terminal's extent -- and with it the grid a claim would name -- does not move
        // when an action appears or goes away.
        //
        // Written only on a change: a layout pass calls this, and the stack view lays out
        // again whenever an arranged subview's hidden flag is set, so an unconditional
        // write would drive a layout loop.
        setOffered(claimButton, control.claim != nil)
        setOffered(releaseButton, control.release != nil)
    }

    private func setOffered(_ button: UIButton, _ offered: Bool) {
        guard button.isHidden == offered else { return }
        button.isHidden = offered == false
    }

    /// The current projection, recomputed at every read so a tap acts on the facts as they
    /// stand rather than on whatever they were when the button was last drawn.
    private var claimControl: MobileClaimControl {
        MobileClaimControl(
            connection: status.connection,
            pane: selectedPaneId,
            pinned: terminalView.pinned,
            nativeGrid: terminalView.nativeGrid
        )
    }

    private func scheduleCheckpoint() {
        checkpointIsDirty = true
        guard checkpointSaveTimer.isPending == false else { return }
        checkpointSaveTimer.schedule(until: MobileMonotonicClock.now + Self.checkpointInterval) {
            [weak self] in
            self?.flushCheckpoint(synchronously: false)
        }
    }

    private func flushCheckpoint(synchronously: Bool) {
        checkpointSaveTimer.cancel()
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

private extension MobileStatusSeverity {
    /// The one UIKit decision the composed status leaves to the shell.
    var color: UIColor {
        switch self {
        case .normal: .secondaryLabel
        case .degraded: .systemOrange
        case .failed: .systemRed
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
