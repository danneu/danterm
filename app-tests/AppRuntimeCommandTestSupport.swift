// Recording ports and terminal session fixtures for AppRuntime command-dispatch tests.
import Cocoa
import Darwin
import DanTermProtocol
import Foundation
import UserNotifications
@testable import DanTerm

/// How long a read through this fixture waits before it declares the runtime hung.
///
/// This is a hang guard, not a threshold: no test using this fixture measures how fast the
/// runtime answers, so the only requirement is that a passing run cannot approach it and
/// that it fires before the suite's time-limit backstop, so the failure names the read.
private let hangGuardMilliseconds: Int32 = 30_000

@MainActor
final class RecordingAppRuntimePorts {
    let session: RecordingTerminalSession
    var sessionRequests: [TerminalSessionRequest] = []
    var notifications: [UNNotificationRequest] = []
    var exportDestination: URL?
    var alerts: [(title: String, message: String)] = []
    var doctorPermissions = DoctorFacts.Permissions.unavailable
    var terminateCount = 0
    var activationCount = 0
    var onNotification: (() -> Void)?
    /// Sessions handed out in order before the fixture falls back to `session`. A test
    /// that reuses a pane id needs to tell the replacement pane's session apart from the
    /// session of the pane it replaced.
    var queuedSessions: [RecordingTerminalSession] = []
    /// How many sessions the fixture hands out in total before it refuses every later
    /// request. `nil` never refuses. A test that needs a restore to fail partway through
    /// building its panes counts the ones it wants built first.
    var sessionsBeforeFailure: Int?

    init(session: RecordingTerminalSession = RecordingTerminalSession()) {
        self.session = session
    }

    var value: AppRuntimePorts {
        AppRuntimePorts(
            createTerminalSession: { [self] request in
                sessionRequests.append(request)
                if let sessionsBeforeFailure, sessionRequests.count > sessionsBeforeFailure {
                    return nil
                }
                return queuedSessions.isEmpty ? session : queuedSessions.removeFirst()
            },
            deliverNotification: { [self] request in
                notifications.append(request)
                onNotification?()
            },
            selectExportDestination: { [self] _, completion in
                completion(exportDestination)
            },
            presentAlert: { [self] title, message in
                alerts.append((title, message))
            },
            readDoctorPermissions: { [self] in doctorPermissions },
            terminateApp: { [self] in terminateCount += 1 },
            activateApp: { [self] in activationCount += 1 }
        )
    }
}

@MainActor
final class RecordingTerminalSession: NSView, TerminalSession {
    weak var paneWrapper: PaneWrapperView?
    var hostView: NSView { self }
    var state = TerminalSessionState(
        scrollbarEnabled: true,
        cellHeight: nil,
        scrollPosition: .init(total: 24, offset: 0, length: 24),
        background: NSColor.black.cgColor
    )
    weak var stateObserver: (any TerminalSessionStateObserver)?
    var onEvent: ((TerminalSessionEvent) -> Void)?
    var onPrimaryHistoryMutation: (() -> Void)?
    var hasSelection = false
    var primaryHistoryText: String?
    var primaryHistoryTail: String?
    var viewportText: String?
    var fullHistoryText: String?
    var rowStructure: [TerminalSessionRowStructure]?
    var paneTapeOpenings: [(PaneTapeCaptureMode, PaneTapeStartPosition, PaneTapeSyncPolicy)] = []
    /// The opening this session hands a tape reader. `nil` reports "no terminal to read",
    /// so a test that wants a live follow stream on this pane assigns one.
    var tapeOpening: PaneTapeOpening?
    /// Counts follow notices the runtime retired, which is how a stream ending shows up on
    /// the session side.
    var cancelledTapeNotices = 0
    var sentText: [String] = []
    var sentInputText: [String] = []
    var sentInputKeys: [(key: KeyName, modifiers: KeyMods)] = []
    var sentInputWheels: [(direction: InputWheelDirection, column: Int, row: Int)] = []
    var focusedValues: [Bool] = []
    var visibleValues: [Bool] = []
    var renderingAvailableValues: [Bool] = []
    var startSearchCount = 0
    var searchNeedles: [String] = []
    var searchDirections: [SearchDirection] = []
    var endSearchCount = 0
    var tearDownCount = 0

    func sendText(_ text: String) { sentText.append(text) }
    func sendInputText(_ text: String) { sentInputText.append(text) }
    func sendInputKey(_ key: KeyName, modifiers: KeyMods) {
        sentInputKeys.append((key, modifiers))
    }
    func sendInputWheel(_ direction: InputWheelDirection, column: Int, row: Int) {
        sentInputWheels.append((direction, column, row))
    }
    func setFocused(_ focused: Bool) { focusedValues.append(focused) }
    func setVisible(_ visible: Bool) { visibleValues.append(visible) }
    func setRenderingAvailable(_ available: Bool) {
        renderingAvailableValues.append(available)
    }
    func refreshPresentation() {}
    func applyTheme(_ themeName: String) {}
    func clearTheme() {}
    func setFontSize(_ size: Double) {}
    func setFontFamily(_ family: String?) {}
    /// Recorded so a test can watch a claim reach the pane and a take-back undo it.
    var gridOverrides: [PaneGridOverride?] = []
    func setGridOverride(_ grid: PaneGridOverride?) { gridOverrides.append(grid) }
    func setCopyOnSelect(_ enabled: Bool) {}
    func startSearch() { startSearchCount += 1 }
    func setSearchNeedle(_ needle: String) { searchNeedles.append(needle) }
    func navigateSearch(_ direction: SearchDirection) { searchDirections.append(direction) }
    func endSearch() { endSearchCount += 1 }
    func readViewportText() -> String? { viewportText }
    func readRowStructure() -> [TerminalSessionRowStructure]? { rowStructure }
    func readFullHistoryText() -> String? { fullHistoryText }
    func readPrimaryHistoryText() -> String? { primaryHistoryText }
    func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String? {
        primaryHistoryTail
    }
    func primaryHistoryTailReader() -> CheckpointScrollbackRead? { nil }
    func paneTapeOpening(
        capture: PaneTapeCaptureMode,
        start: PaneTapeStartPosition,
        policy: PaneTapeSyncPolicy
    ) -> (@Sendable () throws -> PaneTapeOpening)? {
        paneTapeOpenings.append((capture, start, policy))
        guard let tapeOpening else { return nil }
        return { tapeOpening }
    }

    func addPaneTapeFollowNotice(
        id: UUID,
        cursor: PaneTapeCursor,
        notify: @escaping @Sendable () -> Void
    ) -> PaneTapeFollowNoticeRegistration? {
        guard tapeOpening != nil else { return nil }
        return PaneTapeFollowNoticeRegistration(cancel: { [weak self] in
            self?.cancelledTapeNotices += 1
        })
    }
    func scroll(toRow row: Int) {}
    func copySelection() {}
    func pasteClipboard() {}
    func requestClose() {}
    func fenceForApplicationExit() {}
    func tearDown() { tearDownCount += 1 }
}

@MainActor
func makeCommandTestRuntime(
    _ fixture: RecordingAppRuntimePorts,
    configStore: DanTermConfigStore? = nil
) -> AppRuntime {
    let absentConfig = FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-no-config-\(UUID().uuidString)")
    return AppRuntime(
        ports: fixture.value,
        configStore: configStore ?? DanTermConfigStore(url: absentConfig),
        startsApplicationServices: false
    )
}

struct CommandIpcConnectionFixture {
    let connection: IpcConnection
    let peer: Int32

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.ENOTSOCK)
        }
        connection = IpcConnection(fileDescriptor: descriptors[0])
        peer = descriptors[1]
    }

    func remember(reqId: UUID, rpcId: JSONValue) {
        connection.rememberRequest(reqId: reqId, rpcId: rpcId)
    }

    func readResponse() throws -> JsonRpcResponse {
        try readCommandResponse(from: peer)
    }

    func readLine() throws -> Data {
        try readCommandLine(from: peer)
    }

    func readResponseAsync() async throws -> JsonRpcResponse {
        let peer = peer
        let data = try await Task.detached {
            try readCommandLine(from: peer)
        }.value
        return try JSONDecoder().decode(JsonRpcResponse.self, from: data)
    }

    func hasReadableData() -> Bool {
        var readiness = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
        return Darwin.poll(&readiness, 1, 0) > 0
    }

    func readByte() throws -> Int {
        guard waitUntilCommandReadable(peer) else { throw POSIXError(.ETIMEDOUT) }
        var byte: UInt8 = 0
        return Darwin.read(peer, &byte, 1)
    }

    func closePeer() {
        Darwin.close(peer)
    }
}

private func readCommandResponse(from descriptor: Int32) throws -> JsonRpcResponse {
    try JSONDecoder().decode(JsonRpcResponse.self, from: readCommandLine(from: descriptor))
}

private func readCommandLine(from descriptor: Int32) throws -> Data {
    guard waitUntilCommandReadable(descriptor) else { throw POSIXError(.ETIMEDOUT) }
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while true {
        let count = Darwin.read(descriptor, &byte, 1)
        guard count > 0 else { throw POSIXError(.ECONNRESET) }
        if byte == 0x0A { break }
        bytes.append(byte)
    }
    return Data(bytes)
}

private func waitUntilCommandReadable(_ descriptor: Int32) -> Bool {
    var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    while true {
        let result = Darwin.poll(&readiness, 1, hangGuardMilliseconds)
        if result < 0, errno == EINTR { continue }
        return result > 0
    }
}

/// An opening that carries no prefix records, so a test can hold a real follow stream open
/// against a recording session with no terminal engine behind it.
func makeEmptyPaneTapeOpening() -> PaneTapeOpening {
    let cursor = PaneTapeCursor(
        recorderLifetimeId: UUID(),
        nextSequence: 0,
        feedBytesBeforeNextSequence: 0,
        writeBytesBeforeNextSequence: 0
    )
    return PaneTapeOpening(
        start: PaneTapeStart(record: .object(["type": .string("start")]), cursor: cursor),
        records: [],
        nextCursor: cursor,
        replicaHistoryIsComplete: false
    )
}

/// `splitWith` puts a second pane beside the first, so a test can let a restore stage the
/// first pane's record and then fail on the second.
func makeCommandSnapshot(
    paneId: PaneId,
    scrollback: String? = nil,
    splitWith siblingPaneId: PaneId? = nil,
    gridOverride: PaneGridOverrideSnapshot? = nil
) -> AppModelSnapshot {
    let groupId = GroupId(rawValue: UUID())
    let tabId = TabId(rawValue: UUID())
    let pane = PaneSnapshot(
        id: paneId.rawValue.uuidString,
        title: "Terminal",
        cwd: "/tmp/project",
        command: nil,
        scrollback: scrollback,
        theme: nil,
        gridOverride: gridOverride
    )
    var rootNode = SplitNodeSnapshot.leaf(pane)
    if let siblingPaneId {
        rootNode = .split(
            id: UUID().uuidString,
            direction: "horizontal",
            first: .leaf(pane),
            second: .leaf(PaneSnapshot(
                id: siblingPaneId.rawValue.uuidString,
                title: "Terminal",
                cwd: "/tmp/project",
                command: nil,
                scrollback: nil,
                theme: nil
            )),
            ratio: 0.5
        )
    }
    return AppModelSnapshot(
        groups: [GroupSnapshot(
            id: groupId.rawValue.uuidString,
            name: "General",
            isCollapsed: false,
            tabs: [TabSnapshot(
                id: tabId.rawValue.uuidString,
                customTitle: nil,
                focusedPaneId: paneId.rawValue.uuidString,
                rootNode: rootNode,
                color: nil
            )]
        )],
        selectedTabId: tabId.rawValue.uuidString
    )
}
