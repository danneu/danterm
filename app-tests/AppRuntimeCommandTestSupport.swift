// Recording ports and terminal session fixtures for AppRuntime command-dispatch tests.
import Cocoa
import DanTermProtocol
import UserNotifications
@testable import DanTerm

@MainActor
final class RecordingAppRuntimePorts {
    let session: RecordingTerminalSession
    var sessionRequests: [TerminalSessionRequest] = []
    var notifications: [UNNotificationRequest] = []
    var exportDestination: URL?
    var alerts: [(title: String, message: String)] = []
    var terminateCount = 0
    var activationCount = 0

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
            },
            selectExportDestination: { [self] _, completion in
                completion(exportDestination)
            },
            presentAlert: { [self] title, message in
                alerts.append((title, message))
            },
            readDoctorPermissions: { .unavailable },
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
    func readViewportText() -> String? { nil }
    func readRowStructure() -> [TerminalSessionRowStructure]? { nil }
    func readFullHistoryText() -> String? { nil }
    func readPrimaryHistoryText() -> String? { primaryHistoryText }
    func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String? {
        primaryHistoryTail
    }
    func primaryHistoryTailReader() -> CheckpointScrollbackRead? { nil }
    func scroll(toRow row: Int) {}
    func copySelection() {}
    func pasteClipboard() {}
    func requestClose() {}
    func fenceForApplicationExit() {}
    func tearDown() {}
}

@MainActor
func makeCommandTestRuntime(_ fixture: RecordingAppRuntimePorts) -> AppRuntime {
    let absentConfig = FileManager.default.temporaryDirectory
        .appendingPathComponent("danterm-no-config-\(UUID().uuidString)")
    return AppRuntime(
        ports: fixture.value,
        configStore: DanTermConfigStore(url: absentConfig),
        startsApplicationServices: false
    )
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
