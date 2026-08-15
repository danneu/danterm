// Owns connection lifecycle, pane selection, and normalized phone input for the UIKit shell.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Foundation
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
    private var attempt: MobileSessionAttempt?
    private var runner: MobileConnectionRunner?
    private var runnerThread: Thread?
    private var tapeRequestId: JSONValue?
    private var inputMapper = MobileInputMapper()
    private var observers: [NSObjectProtocol] = []
    private var connectionGeneration = 0
    private var didSendSmokeInput = false
    private var pendingArchive: PaneReplicaArchive?
    private var archiveSaveTimer: Timer?
    private var isWaitingForGapRepair = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureViews()
        configureLifecycle()
        loadTarget()
        if connectionHeader.hostText?.isEmpty == false { connect(preferredPane: nil) }
    }

    isolated deinit {
        flushArchive()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
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
        connect(preferredPane: panes[indexPath.row].paneId)
    }

    private func configureViews() {
        connectionHeader.onConnect = { [weak self] in
            self?.connect(preferredPane: self?.selectedPaneId)
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
        terminalView.didUpdateArchive = { [weak self] archive in self?.scheduleStore(archive: archive) }
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
                self?.flushArchive()
                self?.disconnect()
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.connect(preferredPane: self?.selectedPaneId) }
        })
    }

    private func loadTarget() {
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        connectionHeader.hostText = environment["DANTERM_IOS_HOST"]
            ?? defaults.string(forKey: "serverHost")
        connectionHeader.portText = environment["DANTERM_IOS_PORT"]
            ?? defaults.string(forKey: "serverPort") ?? "7420"
    }

    private func connect(preferredPane: PaneId?) {
        guard let host = connectionHeader.hostText?.trimmingCharacters(in: .whitespacesAndNewlines),
              host.isEmpty == false,
              let portText = connectionHeader.portText,
              let port = UInt16(portText)
        else {
            show(state: .deviceSetupFailure, detail: "Enter a host and port")
            return
        }
        UserDefaults.standard.set(host, forKey: "serverHost")
        UserDefaults.standard.set(portText, forKey: "serverPort")
        flushArchive()
        disconnect()
        let generation = connectionGeneration
        show(state: .connecting, detail: "Connecting to \(host):\(port)")
        let attempt = MobileSessionAttempt(host: host, port: port)
        self.attempt = attempt
        attempt.start { [weak self] result in
            Task { @MainActor in
                guard self?.connectionGeneration == generation else {
                    if case .connected(let bootstrap) = result { bootstrap.session.cancel() }
                    return
                }
                self?.finish(result, preferredPane: preferredPane)
            }
        }
    }

    private func finish(_ result: MobileSessionBootstrapResult, preferredPane: PaneId?) {
        attempt = nil
        switch result {
        case .failed(let state):
            show(state: state)
        case .connected(let bootstrap):
            panes = bootstrap.panes
            paneTable.reloadData()
            guard let pane = preferredPane.flatMap({ wanted in panes.first { $0.paneId == wanted } })
                ?? panes.first(where: { $0.isSelectedTab && $0.isFocused })
                ?? panes.first
            else {
                bootstrap.session.cancel()
                show(state: .requestRefused(reason: "The Mac has no panes"))
                return
            }
            selectedPaneId = pane.paneId
            isWaitingForGapRepair = false
            paneTable.reloadData()
            let archive = storedArchive(for: pane.paneId)
            let cursor = terminalView.reset(archive: archive)
            startStream(bootstrap.session, pane: pane.paneId, cursor: cursor)
            show(state: .ready, detail: "Connected to DanTerm \(bootstrap.serverVersion)")
        }
    }

    private func startStream(
        _ session: DanTermClientSession,
        pane: PaneId,
        cursor: PaneTapeCursor?
    ) {
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
            show(state: .connectionLost)
            return
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
    }

    private func receive(_ event: MobileConnectionRunnerEvent) {
        switch event {
        case .ended:
            show(state: .connectionLost)
        case .failure(let state):
            show(state: state)
        case .frame(let frame):
            receive(frame)
        }
    }

    private func receive(_ frame: DanTermClientFrame) {
        switch frame {
        case .response(let response):
            if let error = response.error {
                show(state: .requestRefused(reason: error.message))
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
                show(state: .streamEnded(reason: reason?.rawValue))
            }
        } catch {
            show(state: .deviceSetupFailure, detail: "Replica rejected the stream")
        }
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
                show(state: .connectionLost)
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
        connectionHeader.showStatus(
            detail ?? state.label,
            color: state.isFailure ? .systemRed : .secondaryLabel
        )
    }

    private func scheduleStore(archive: PaneReplicaArchive) {
        pendingArchive = archive
        guard archiveSaveTimer == nil else { return }
        archiveSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.flushArchive() }
        }
    }

    private func flushArchive() {
        archiveSaveTimer?.invalidate()
        archiveSaveTimer = nil
        guard let archive = pendingArchive,
              let pane = selectedPaneId,
              let data = try? JSONEncoder().encode(archive)
        else { return }
        pendingArchive = nil
        UserDefaults.standard.set(data, forKey: "replica.\(pane.rawValue.uuidString)")
    }

    private func storedArchive(for pane: PaneId) -> PaneReplicaArchive? {
        guard let data = UserDefaults.standard.data(forKey: "replica.\(pane.rawValue.uuidString)")
        else { return nil }
        return try? JSONDecoder().decode(PaneReplicaArchive.self, from: data)
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
