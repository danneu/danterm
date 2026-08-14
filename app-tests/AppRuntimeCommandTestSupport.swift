// Recording ports and terminal session fixtures for AppRuntime command-dispatch tests.
import Cocoa
import Darwin
import DanTermProtocol
import Foundation
import UserNotifications
@testable import DanTerm

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

    init(session: RecordingTerminalSession = RecordingTerminalSession()) {
        self.session = session
    }

    var value: AppRuntimePorts {
        AppRuntimePorts(
            createTerminalSession: { [self] request in
                sessionRequests.append(request)
                return session
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
        cellHeight: 0,
        scrollPosition: nil,
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
    var paneTapeOpenings: [(PaneTapeCaptureMode, PaneTapeStartPosition, PaneTapeStreamMode)] = []
    var sentText: [String] = []
    var sentInputText: [String] = []
    var sentInputKeys: [(key: KeyName, modifiers: KeyMods)] = []
    var focusedValues: [Bool] = []
    var renderingAvailableValues: [Bool] = []
    var startSearchCount = 0
    var searchNeedles: [String] = []
    var searchDirections: [SearchDirection] = []
    var endSearchCount = 0

    func sendText(_ text: String) { sentText.append(text) }
    func sendInputText(_ text: String) { sentInputText.append(text) }
    func sendInputKey(_ key: KeyName, modifiers: KeyMods) {
        sentInputKeys.append((key, modifiers))
    }
    func setFocused(_ focused: Bool) { focusedValues.append(focused) }
    func setVisible(_ visible: Bool) {}
    func setRenderingAvailable(_ available: Bool) {
        renderingAvailableValues.append(available)
    }
    func refreshBackingProperties() {}
    func applyTheme(_ themeName: String) {}
    func clearTheme() {}
    func setFontSize(_ size: Double) {}
    func setFontFamily(_ family: String?) {}
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
        mode: PaneTapeStreamMode
    ) -> (@Sendable () throws -> PaneTapeOpening)? {
        paneTapeOpenings.append((capture, start, mode))
        return nil
    }
    func scroll(toRow row: Int) {}
    func copySelection() {}
    func pasteClipboard() {}
    func requestClose() {}
    func fenceForApplicationExit() {}
    func tearDown() {}
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

    func readByte() -> Int {
        guard waitUntilCommandReadable(peer) else { return -1 }
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
        let result = Darwin.poll(&readiness, 1, 2_000)
        if result < 0, errno == EINTR { continue }
        return result > 0
    }
}

func makeCommandSnapshot(paneId: PaneId, scrollback: String? = nil) -> AppModelSnapshot {
    let groupId = GroupId(rawValue: UUID())
    let tabId = TabId(rawValue: UUID())
    let pane = PaneSnapshot(
        id: paneId.rawValue.uuidString,
        title: "Terminal",
        cwd: "/tmp/project",
        command: nil,
        scrollback: scrollback,
        theme: nil
    )
    return AppModelSnapshot(
        groups: [GroupSnapshot(
            id: groupId.rawValue.uuidString,
            name: "General",
            isCollapsed: false,
            tabs: [TabSnapshot(
                id: tabId.rawValue.uuidString,
                customTitle: nil,
                focusedPaneId: paneId.rawValue.uuidString,
                rootNode: .leaf(pane),
                color: nil
            )]
        )],
        selectedTabId: tabId.rawValue.uuidString
    )
}
