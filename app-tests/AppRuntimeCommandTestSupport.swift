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
    var doctorPermissions = DoctorFacts.Permissions.unavailable
    var doctorConfigFont = DoctorFacts.ConfigFont.unset
    var doctorConfigFilePaths: [String] = []
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
    /// Specific one-based request numbers the fixture refuses while later requests may succeed.
    var failedSessionRequestNumbers: Set<Int> = []

    init(session: RecordingTerminalSession = RecordingTerminalSession()) {
        self.session = session
    }

    var value: AppRuntimePorts {
        AppRuntimePorts(
            createTerminalSession: { [self] request in
                sessionRequests.append(request)
                if failedSessionRequestNumbers.contains(sessionRequests.count) {
                    return nil
                }
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
            readDoctorAppFacts: { [self] configFilePath in
                doctorConfigFilePaths.append(configFilePath)
                return DoctorFacts.AppFacts(
                    permissions: doctorPermissions,
                    configFilePath: configFilePath,
                    configFont: doctorConfigFont
                )
            },
            terminateApp: { [self] in terminateCount += 1 },
            activateApp: { [self] in activationCount += 1 }
        )
    }
}

/// Holds one follow delivery behind reference identity so fixture traversals never wrap closures.
@MainActor
private final class RecordedPaneTapeFollowSubscription {
    private let deliverAction: @Sendable (
        @escaping @Sendable () -> PaneTapeContinuation<PaneTapeSessionEvent>
    ) -> Void
    private var isCancelled = false

    init(deliver: @escaping @Sendable (
        @escaping @Sendable () -> PaneTapeContinuation<PaneTapeSessionEvent>
    ) -> Void) {
        deliverAction = deliver
    }

    func deliver(_ continuation: PaneTapeContinuation<PaneTapeSessionEvent>) {
        guard isCancelled == false else { return }
        deliverAction { continuation }
    }

    func cancel() {
        isCancelled = true
    }
}

@MainActor
final class RecordingTerminalSession: NSView, TerminalSession {
    var paneMenuProvider: (() -> NSMenu?)?
    var hostView: NSView { self }
    var state = TerminalSessionState(
        scrollbarEnabled: true,
        cellHeight: nil,
        scrollPosition: .init(total: 24, offset: 0, length: 24),
        background: NSColor.black.cgColor
    )
    weak var stateObserver: (any TerminalSessionStateObserver)?
    var onEvent: ((TerminalSessionEvent) -> Void)?
    var currentAgentWaitGeneration: (() -> AgentWaitGeneration?)?
    var onPrimaryHistoryMutation: (() -> Void)?
    var hasSelection = false
    var primaryHistoryText: String?
    var primaryHistoryTail: String?
    var primaryHistoryTailLimits: [PrimaryHistoryLimits] = []
    var usesDeferredPrimaryHistoryTail = false
    var deferredPrimaryHistoryTailLimits: [PrimaryHistoryLimits] = []
    var viewportText: String?
    var viewportCells: TerminalSessionViewportCells?
    var fullHistoryText: String?
    var rowStructure: [TerminalSessionRowStructure]?
    /// The census this session reports. `nil` is the unmeasured answer -- a session
    /// with no presentation of its own -- and is the default, because that is what a
    /// double without buffers honestly holds.
    var surfaceCensus: TerminalSessionSurfaceCensus?
    var paneTapeOpenings: [(PaneTapeCaptureMode, PaneTapeStartPosition, PaneTapeSyncPolicy)] = []
    /// The opening this session hands a tape reader. `nil` reports "no terminal to read",
    /// so a test that wants a live follow stream on this pane assigns one.
    var tapeOpening: PaneTapeOpening<PaneTapeSessionEvent>?
    /// Counts follow notices the runtime retired, which is how a stream ending shows up on
    /// the session side.
    var cancelledTapeNotices = 0
    /// Continuations handed to follow fetches in order. The returned work closure captures
    /// only the removed value because the runtime executes it off the main actor.
    var tapeFollowContinuations: [PaneTapeContinuation<PaneTapeSessionEvent>] = []
    private var tapeFollowSubscriptions: [UUID: RecordedPaneTapeFollowSubscription] = [:]
    var sentText: [String] = []
    var sentInputText: [String] = []
    var sentInputKeys: [(key: KeyName, modifiers: KeyMods)] = []
    var sentInputWheels: [(direction: InputWheelDirection, column: Int, row: Int)] = []
    /// The wait stamped on each input submission, in submission order.
    var submittedWaitGenerations: [AgentWaitGeneration?] = []
    var focusedValues: [Bool] = []
    var visibleValues: [Bool] = []
    var renderingAvailableValues: [Bool] = []
    var optionAsAltValues: [OptionAsAlt?] = []
    var searchNeedles: [String] = []
    var searchDirections: [SearchDirection] = []
    var endSearchCount = 0
    var tearDownCount = 0

    func submitInput(
        _ input: PaneInputItem,
        waitGeneration: AgentWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (TerminalInputSubmissionResult) -> Void
    ) {
        switch input {
        case .paste(let text): sentText.append(text)
        case .text(let text): sentInputText.append(text)
        case .key(let key, let modifiers): sentInputKeys.append((key, modifiers))
        case .wheel(let direction, let column, let row):
            sentInputWheels.append((direction, column, row))
        }
        submittedWaitGenerations.append(waitGeneration)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onCompletion(.delivered) }
        }
    }
    func setFocused(_ focused: Bool) { focusedValues.append(focused) }
    func setVisible(_ visible: Bool) { visibleValues.append(visible) }
    func setRenderingAvailable(_ available: Bool) {
        renderingAvailableValues.append(available)
    }
    func refreshPresentation() {}
    /// Recorded so a test can watch what a pane's config reconcile actually applies,
    /// including the redundant push a pane that mounted with its config must not get.
    var appliedThemes: [String] = []
    var appliedFonts: [PaneFont] = []
    var copyOnSelectValues: [Bool] = []
    func applyTheme(_ themeName: String) { appliedThemes.append(themeName) }
    func clearTheme() {}
    func setFont(_ font: PaneFont) { appliedFonts.append(font) }
    /// Recorded so a test can watch a claim reach the pane and a take-back undo it.
    var gridOverrides: [PaneGridOverride?] = []
    /// Called as the override is applied, so an ordering test can observe what is already
    /// on the wire at that moment.
    var onGridOverride: ((PaneGridOverride?) -> Void)?
    func setGridOverride(_ grid: PaneGridOverride?) {
        gridOverrides.append(grid)
        onGridOverride?(grid)
    }
    func setCopyOnSelect(_ enabled: Bool) { copyOnSelectValues.append(enabled) }
    func setOptionAsAlt(_ policy: OptionAsAlt?) { optionAsAltValues.append(policy) }
    func setSearchNeedle(_ needle: String) { searchNeedles.append(needle) }
    func navigateSearch(_ direction: SearchDirection) { searchDirections.append(direction) }
    func endSearch() { endSearchCount += 1 }
    func readViewportText() -> String? { viewportText }
    func readViewportCells() -> TerminalSessionViewportCells? { viewportCells }
    func readSurfaceCensus() -> TerminalSessionSurfaceCensus? { surfaceCensus }
    func readRowStructure() -> [TerminalSessionRowStructure]? { rowStructure }
    func readFullHistoryText() -> String? { fullHistoryText }
    func readPrimaryHistoryText() -> String? { primaryHistoryText }
    func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String? {
        primaryHistoryTailLimits.append(PrimaryHistoryLimits(maxLines: maxLines, maxChars: maxChars))
        return primaryHistoryTail
    }
    func primaryHistoryTailReader(maxLines: Int, maxChars: Int) -> CheckpointScrollbackRead? {
        guard usesDeferredPrimaryHistoryTail else { return nil }
        deferredPrimaryHistoryTailLimits.append(
            PrimaryHistoryLimits(maxLines: maxLines, maxChars: maxChars)
        )
        let text = primaryHistoryTail
        return { text }
    }
    func paneTapeOpening(
        capture: PaneTapeCaptureMode,
        start: PaneTapeStartPosition,
        policy: PaneTapeSyncPolicy
    ) -> (@Sendable () throws -> PaneTapeOpening<PaneTapeSessionEvent>)? {
        paneTapeOpenings.append((capture, start, policy))
        guard let tapeOpening else { return nil }
        return { tapeOpening }
    }

    func addPaneTapeFollowSubscription(
        id: UUID,
        cursor: PaneTapeCursor,
        policy: PaneTapeSyncPolicy,
        replicaHistoryIsComplete: Bool,
        deliver: @escaping @Sendable (
            @escaping @Sendable () -> PaneTapeContinuation<PaneTapeSessionEvent>
        ) -> Void
    ) -> PaneTapeFollowRegistration? {
        guard tapeOpening != nil else { return nil }
        guard tapeFollowSubscriptions.count < 8 else { return nil }
        let subscription = RecordedPaneTapeFollowSubscription(deliver: deliver)
        tapeFollowSubscriptions[id] = subscription
        return PaneTapeFollowRegistration(cancel: { [weak self] in
            subscription.cancel()
            self?.cancelledTapeNotices += 1
        })
    }

    func markPaneTapeFollowReady(id: UUID, replicaHistoryIsComplete: Bool) {}

    /// Fires every live recorder notice as the terminal owner would after an append.
    func notifyPaneTapeFollowers() {
        guard tapeFollowContinuations.isEmpty == false else { return }
        let continuation = tapeFollowContinuations.removeFirst()
        for subscription in tapeFollowSubscriptions.values {
            subscription.deliver(continuation)
        }
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
    configStore: DanTermConfigStore? = nil,
    dialogSurfaces: RecordingDialogSurfaces = RecordingDialogSurfaces(),
    initialModel: AppModel? = nil,
    applicationActive: Bool = true
) -> AppRuntime {
    let instance = TemporaryInstancePaths()
    return AppRuntime(
        ports: fixture.value,
        dialogSurfaces: dialogSurfaces.value,
        instancePaths: instance.paths,
        configStore: configStore ?? DanTermConfigStore(url: instance.absentConfigURL),
        initialModel: initialModel,
        startsApplicationServices: false,
        applicationActive: applicationActive
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

    /// Reads one wire line off the main actor for ordering tests over asynchronous writes.
    func readLineAsync() async throws -> Data {
        let peer = peer
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    try readCommandLine(from: peer)
                })
            }
        }
    }

    func readResponseAsync() async throws -> JsonRpcResponse {
        let data = try await readLineAsync()
        return try JSONDecoder().decode(JsonRpcResponse.self, from: data)
    }

    /// Reads one server-initiated notification that is already on the wire.
    func readNotification() throws -> JsonRpcRequest {
        try JSONDecoder().decode(JsonRpcRequest.self, from: readLine())
    }

    /// Reads one notification off the main thread, so a test may wait for a frame that a
    /// main-queue timer has not written yet without blocking the timer itself.
    func readNotificationAsync() async throws -> JsonRpcRequest {
        let data = try await readLineAsync()
        return try JSONDecoder().decode(JsonRpcRequest.self, from: data)
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

    /// Waits for EOF off the main actor when transport shutdown completes asynchronously.
    func readByteAsync() async throws -> Int {
        let peer = peer
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    guard waitUntilCommandReadable(peer) else { throw POSIXError(.ETIMEDOUT) }
                    var byte: UInt8 = 0
                    return Darwin.read(peer, &byte, 1)
                })
            }
        }
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
func makeEmptyPaneTapeOpening() -> PaneTapeOpening<PaneTapeSessionEvent> {
    let cursor = PaneTapeCursor(
        recorderLifetimeId: UUID(),
        nextSequence: 0,
        feedBytesBeforeNextSequence: 0,
        writeBytesBeforeNextSequence: 0
    )
    return PaneTapeOpening(
        start: PaneTapeStart(
            record: PaneTapeStartRecord(
                version: paneTapeStreamVersion,
                capture: .follow,
                format: .replay,
                columns: 80,
                rows: 24,
                pinned: false,
                cursor: cursor,
                reconstructible: false
            ),
            cursor: cursor
        ),
        records: [],
        nextCursor: cursor,
        replicaHistoryIsComplete: false
    )
}

/// A dump whose prefix is one retained event, so a test can watch a whole finite capture --
/// start record, event record, terminator -- reach a real socket.
func makeSingleEventPaneTapeDump(
    of event: PaneTapeSessionEvent
) -> PaneTapeOpening<PaneTapeSessionEvent> {
    let empty = makeEmptyPaneTapeOpening()
    return PaneTapeOpening(
        start: PaneTapeStart(
            record: PaneTapeStartRecord(
                version: paneTapeStreamVersion,
                capture: .dump,
                format: .replay,
                columns: 80,
                rows: 24,
                pinned: false,
                cursor: empty.nextCursor,
                reconstructible: false
            ),
            cursor: empty.nextCursor
        ),
        records: [makePaneTapeEventRecord(PaneTapeEvent(
            sequence: 4,
            elapsedNanoseconds: 11,
            originElapsedNanoseconds: nil,
            payload: .init(byteOffset: 0, byteLength: 2),
            event: event,
            needsCompleteHistory: false
        ))],
        nextCursor: empty.nextCursor,
        replicaHistoryIsComplete: false
    )
}

/// `splitWith` puts a second pane beside the first, so a test can let a restore stage the
/// first pane's record and then fail on the second.
func makeCommandSnapshot(
    paneId: PaneId,
    scrollback: String? = nil,
    splitWith siblingPaneId: PaneId? = nil,
    gridOverride: PaneGridOverrideSnapshot? = nil,
    theme: String? = nil,
    agentSession: AgentSessionSnapshot? = nil
) -> AppModelSnapshot {
    let groupId = GroupId(rawValue: UUID())
    let tabId = TabId(rawValue: UUID())
    let pane = PaneSnapshot(
        id: paneId,
        title: "Terminal",
        cwd: "/tmp/project",
        command: nil,
        scrollback: scrollback,
        theme: theme,
        agentSession: agentSession,
        gridOverride: gridOverride
    )
    var rootNode = SplitNodeSnapshot.leaf(pane)
    if let siblingPaneId {
        rootNode = .split(
            id: SplitId(rawValue: UUID()),
            direction: .horizontal,
            first: .leaf(pane),
            second: .leaf(PaneSnapshot(
                id: siblingPaneId,
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
            id: groupId,
            name: "General",
            isCollapsed: false,
            tabs: [TabSnapshot(
                id: tabId,
                customTitle: nil,
                focusedPaneId: paneId,
                rootNode: rootNode,
                color: nil
            )]
        )],
        selectedTabId: tabId
    )
}

/// Builds the validated restore that runtime tests need without restoring the deleted raw-snapshot API.
func makeCommandRestore(_ snapshot: AppModelSnapshot) -> ValidatedAppRestore {
    guard let built = validateAndBuildDetailed(snapshot) else {
        preconditionFailure("command test snapshot must be valid")
    }
    return ValidatedAppRestore(model: built.model, paneSnapshots: built.paneSnapshots)
}

/// A copy of the model with every tab's focus history erased.
///
/// Tab recency is a monotone stamp, so a sequence that creates a tab and destroys it
/// again advances the focus clock even though the model it leaves behind is otherwise
/// the one it started from. A test that compares whole models across such a round trip
/// normalizes the stamps and asserts the recency *order* separately.
func withoutFocusHistory(_ model: AppModel) -> AppModel {
    var copy = model
    copy.focusClock = 0
    for groupIndex in copy.groups.indices {
        for tabIndex in copy.groups[groupIndex].tabs.indices {
            copy.groups[groupIndex].tabs[tabIndex].focusStamp = 0
        }
    }
    return copy
}

extension AppRuntime {
    /// Lets runtime tests start from compact snapshot fixtures while production accepts only validated restores.
    func bootstrapFromTestSnapshot(_ snapshot: AppModelSnapshot) {
        bootstrapFromValidatedRestore(makeCommandRestore(snapshot))
    }
}
