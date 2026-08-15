// Owns connection lifecycle, pane selection, and normalized phone input for the UIKit shell.
import DanTermClient
import DanTermMobileKit
import DanTermProtocol
import Foundation
import UIKit

/// Keeps every UIKit state transition on the main actor while sessions block elsewhere.
@MainActor
final class MobileRootViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
    UITextViewDelegate
{
    private let hostField = UITextField()
    private let portField = UITextField()
    private let connectButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let paneTable = UITableView(frame: .zero, style: .plain)
    private let terminalView = TerminalSurfaceView()
    private let inputViewField = TerminalInputTextView()
    private let accessoryRow = UIStackView()

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
        if hostField.text?.isEmpty == false { connect(preferredPane: nil) }
    }

    isolated deinit {
        flushArchive()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        attempt?.cancel()
        runner?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let width = view.bounds.width
        let top = safe.top + 8
        hostField.frame = CGRect(x: 12, y: top, width: width - 132, height: 36)
        portField.frame = CGRect(x: width - 112, y: top, width: 48, height: 36)
        connectButton.frame = CGRect(x: width - 60, y: top, width: 52, height: 36)
        statusLabel.frame = CGRect(x: 12, y: top + 40, width: width - 24, height: 22)
        let tableHeight = min(150, max(80, view.bounds.height * 0.2))
        paneTable.frame = CGRect(x: 0, y: top + 66, width: width, height: tableHeight)
        let accessoryHeight: CGFloat = 38
        let inputHeight: CGFloat = 38
        let bottom = view.bounds.height - safe.bottom
        accessoryRow.frame = CGRect(
            x: 4,
            y: bottom - accessoryHeight,
            width: width - 8,
            height: accessoryHeight
        )
        inputViewField.frame = CGRect(
            x: 8,
            y: accessoryRow.frame.minY - inputHeight,
            width: width - 16,
            height: inputHeight
        )
        terminalView.frame = CGRect(
            x: 0,
            y: paneTable.frame.maxY,
            width: width,
            height: max(0, inputViewField.frame.minY - paneTable.frame.maxY)
        )
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "pane")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "pane")
        let pane = panes[indexPath.row]
        cell.textLabel?.text = pane.paneTitle
        cell.detailTextLabel?.text = "\(pane.groupName) / \(pane.tabTitle)"
        cell.accessoryType = pane.paneId == selectedPaneId ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        connect(preferredPane: panes[indexPath.row].paneId)
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if text.isEmpty == false { send(inputMapper.text(text)) }
        return false
    }

    private func configureViews() {
        hostField.borderStyle = .roundedRect
        hostField.placeholder = "Mac tailnet host"
        hostField.autocapitalizationType = .none
        hostField.autocorrectionType = .no
        hostField.spellCheckingType = .no
        portField.borderStyle = .roundedRect
        portField.placeholder = "7420"
        portField.keyboardType = .numberPad
        connectButton.setTitle("Go", for: .normal)
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 1
        paneTable.dataSource = self
        paneTable.delegate = self
        paneTable.rowHeight = 52
        inputViewField.delegate = self
        inputViewField.onPaste = { [weak self] text in
            self?.send(self?.inputMapper.paste(text))
        }
        inputViewField.autocorrectionType = .no
        inputViewField.autocapitalizationType = .none
        inputViewField.smartDashesType = .no
        inputViewField.smartQuotesType = .no
        inputViewField.smartInsertDeleteType = .no
        inputViewField.spellCheckingType = .no
        inputViewField.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        inputViewField.layer.borderColor = UIColor.separator.cgColor
        inputViewField.layer.borderWidth = 1
        inputViewField.layer.cornerRadius = 6
        inputViewField.text = ""
        accessoryRow.axis = .horizontal
        accessoryRow.distribution = .fillEqually
        accessoryRow.spacing = 2
        for entry in accessoryEntries {
            let button = UIButton(type: .system)
            button.setTitle(entry.title, for: .normal)
            button.tag = entry.tag
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            button.addTarget(self, action: #selector(accessoryTapped(_:)), for: .touchUpInside)
            accessoryRow.addArrangedSubview(button)
        }
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
        for subview in [hostField, portField, connectButton, statusLabel, paneTable,
                        terminalView, inputViewField, accessoryRow]
        {
            view.addSubview(subview)
        }
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
        hostField.text = environment["DANTERM_IOS_HOST"] ?? defaults.string(forKey: "serverHost")
        portField.text = environment["DANTERM_IOS_PORT"] ?? defaults.string(forKey: "serverPort") ?? "7420"
    }

    @objc private func connectTapped() {
        connect(preferredPane: selectedPaneId)
    }

    private func connect(preferredPane: PaneId?) {
        guard let host = hostField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              host.isEmpty == false,
              let portText = portField.text,
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

    @objc private func accessoryTapped(_ sender: UIButton) {
        guard let key = MobileAccessoryKey(tag: sender.tag) else { return }
        send(inputMapper.accessory(key))
        if key == .control {
            sender.tintColor = inputMapper.isControlLatched ? .systemOrange : view.tintColor
        }
        inputViewField.becomeFirstResponder()
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
        statusLabel.text = detail ?? state.label
        statusLabel.textColor = state.isFailure ? .systemRed : .secondaryLabel
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

/// Separates an explicit paste gesture from ordinary committed keyboard text.
@MainActor
private final class TerminalInputTextView: UITextView {
    var onPaste: ((String) -> Void)?

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string { onPaste?(text) }
    }
}

private let accessoryEntries: [(title: String, tag: Int)] = [
    ("Esc", 0), ("Ctrl", 1), ("Tab", 2), ("up", 3), ("down", 4),
    ("left", 5), ("right", 6), ("|", 7), ("~", 8), ("/", 9),
]

private extension MobileAccessoryKey {
    init?(tag: Int) {
        switch tag {
        case 0: self = .escape
        case 1: self = .control
        case 2: self = .tab
        case 3: self = .up
        case 4: self = .down
        case 5: self = .left
        case 6: self = .right
        case 7: self = .pipe
        case 8: self = .tilde
        case 9: self = .slash
        default: return nil
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
