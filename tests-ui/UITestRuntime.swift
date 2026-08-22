// The runtime and terminal session the UI suite drives the production views with.
//
// The runtime here is the real `AppRuntime`, built headlessly: no application
// services, no config file, and every identity-keyed path under a disposable
// root. Only its message entry point is substituted, so a test can read what a
// view reported without the reducer, the reconcile sweep, and the command
// interpreter all running behind each click.
import Cocoa
import DanTermProtocol
import Foundation
@testable import DanTerm

/// Observes what the views under test reported, by substituting the runtime's one
/// message entry point.
///
/// Overriding `send` deliberately stops the message there: these are view tests,
/// and running the reducer plus a reconcile sweep on every click would make each
/// of them a test of the whole app.
@MainActor
final class RecordingAppRuntime: AppRuntime {
    var sentMessages: [Msg] = []
    var onSend: ((Msg) -> Void)?
    var focusedPaneSessions: [PaneId] = []

    /// The model this runtime answers with, held here rather than in the store the
    /// reducer drives. These are view tests: `send` stops at the recorder above, so
    /// nothing would ever advance the real store, and a test states the model it
    /// wants the views reconciled against by assigning it.
    private var substitutedModel: AppModel
    override var model: AppModel {
        get { substitutedModel }
        set { substitutedModel = newValue }
    }

    init(
        substituting model: AppModel,
        ports: AppRuntimePorts,
        dialogSurfaces: DialogSurfaces,
        instancePaths: DanTermInstancePaths,
        configStore: DanTermConfigStore
    ) {
        substitutedModel = model
        super.init(
            ports: ports,
            dialogSurfaces: dialogSurfaces,
            instancePaths: instancePaths,
            configStore: configStore,
            initialModel: model,
            startsApplicationServices: false,
            applicationActive: true
        )
    }

    override func send(_ msg: Msg) {
        sentMessages.append(msg)
        onSend?(msg)
    }

    override func focusPaneSession(_ paneId: PaneId) {
        focusedPaneSessions.append(paneId)
    }

    // PreferencesPanel's "Config file" row. Both reach the user's filesystem in
    // production, so the suite keeps them inert.
    override func openDanTermConfig() {}
    override func reloadDanTermConfig() {}
}

/// Builds a headless recording runtime rooted in a disposable directory.
///
/// The model is given, never loaded: with an explicit initial model the runtime
/// never reads the user's config file.
@MainActor
func makeUITestRuntime(model: AppModel = AppModel(groups: [])) -> RecordingAppRuntime {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("dt-ui-\(UUID().uuidString)", isDirectory: true)
    let paths = DanTermInstancePaths(
        identity: DanTermInstanceIdentity(bundleIdentifier: "dt.uitest"),
        applicationSupportRoot: root.appendingPathComponent("as", isDirectory: true),
        cachesRoot: root.appendingPathComponent("ca", isDirectory: true),
        temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true)
    )
    return RecordingAppRuntime(
        substituting: model,
        ports: .live(terminalBackend: SwiftTerminalBackend()),
        dialogSurfaces: inertDialogSurfaces(),
        instancePaths: paths,
        configStore: DanTermConfigStore(url: root.appendingPathComponent("absent.json"))
    )
}

/// A dialog surface that presents nothing, so a runtime the suite builds cannot
/// put a panel on the developer's screen.
@MainActor
private final class InertDialogSurface<Projection: Equatable>: DialogSurface {
    func bind(runtime: AppRuntime) {}
    func apply(_ projection: Projection) {}
    func raise() {}
    func hide() {}
    func discard() {}
}

@MainActor
private func inertDialogSurfaces() -> DialogSurfaces {
    DialogSurfaces(
        switcher: InertDialogSurface<SwitcherProjection>(),
        confirmation: InertDialogSurface<ConfirmationProjection>(),
        notice: InertDialogSurface<NoticeProjection>(),
        preferences: InertDialogSurface<PreferencesPanelProjection>()
    )
}

/// The stable session boundary the pane chrome is tested against: a recording
/// stand-in for a live terminal, with no engine and no PTY behind it.
@MainActor
class FakeTerminalSession: NSView, TerminalSession {
    var paneMenuProvider: (() -> NSMenu?)?
    var hasSelection = false
    var performedActions: [String] = []
    var hostView: NSView { self }
    var state = TerminalSessionState(
        scrollbarEnabled: true, cellHeight: nil,
        scrollPosition: .init(total: 24, offset: 0, length: 24),
        background: NSColor.black.cgColor)
    weak var stateObserver: (any TerminalSessionStateObserver)?
    var onEvent: ((TerminalSessionEvent) -> Void)?
    var currentAgentWaitGeneration: (() -> AgentWaitGeneration?)?
    var onPrimaryHistoryMutation: (() -> Void)?
    var renderingAvailability: [Bool] = []
    var visibility: [Bool] = []
    var revealCount = 0

    /// Drives the session-state channel the way a real theme swap does, so view
    /// chrome that reads state can be tested without the terminal engine.
    func emitState(_ newState: TerminalSessionState) {
        state = newState
        stateObserver?.terminalSessionStateDidChange(newState)
    }

    func copySelection() {
        performedActions.append("copySelection")
    }

    func pasteClipboard() {
        performedActions.append("pasteClipboard")
    }

    func submitInput(
        _ input: PaneInputItem,
        waitGeneration: AgentWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (TerminalInputSubmissionResult) -> Void
    ) { onCompletion(.delivered) }
    func setFocused(_ focused: Bool) {}
    func setApplicationActive(_ active: Bool) {}
    func setVisible(_ visible: Bool) {
        if visible, visibility.last == false {
            revealCount += 1
        }
        visibility.append(visible)
    }
    func setRenderingAvailable(_ available: Bool) {
        renderingAvailability.append(available)
    }
    func refreshPresentation() {}
    func applyTheme(_ themeName: String) {}
    func clearTheme() {}
    func setFontSize(_ size: Double) {}
    func setFontFamily(_ family: String?) {}
    func setGridOverride(_ grid: PaneGridOverride?) {}
    func setCopyOnSelect(_ enabled: Bool) {}
    func setSearchNeedle(_ needle: String) {}
    func navigateSearch(_ direction: SearchDirection) {}
    func endSearch() {}
    func readViewportText() -> String? { nil }
    func readRowStructure() -> [TerminalSessionRowStructure]? { nil }
    func readFullHistoryText() -> String? { nil }
    func readPrimaryHistoryText() -> String? { nil }
    func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String? { nil }
    func primaryHistoryTailReader() -> CheckpointScrollbackRead? { nil }
    func scroll(toRow row: Int) {}
    func requestClose() {}
    func fenceForApplicationExit() {}
    func tearDown() {}
}
