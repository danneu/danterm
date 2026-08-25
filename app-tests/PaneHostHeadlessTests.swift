// Headless construction proof for the runtime-owned session and pane-chrome lifetime root.
import Cocoa
import DanTermProtocol
import Testing
@testable import DanTerm

@Suite struct PaneHostHeadlessTests {
    @Test("pane host constructs without a WindowServer-backed window")
    @MainActor
    func constructsHeadlessly() {
        let instance = TemporaryInstancePaths()
        defer { instance.remove() }
        let runtime = AppRuntime(
            ports: .live(terminalBackend: SwiftTerminalBackend()),
            dialogSurfaces: RecordingDialogSurfaces().value,
            instancePaths: instance.paths,
            configStore: DanTermConfigStore(url: instance.absentConfigURL),
            startsApplicationServices: false,
            applicationActive: true
        )
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        let session = HeadlessPaneHostSession()

        let host = PaneHost(paneId: paneId, session: session, runtime: runtime)

        #expect(host.session === session)
        #expect(host.wrapper.terminalSession === session)
    }
}

/// Supplies the stable session boundary while the test exercises only PaneHost's AppKit chrome.
@MainActor
private final class HeadlessPaneHostSession: NSView, TerminalSession {
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

    func submitInput(
        _ input: PaneInputItem,
        waitGeneration: AgentWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (TerminalInputSubmissionResult) -> Void
    ) { onCompletion(.delivered) }
    func setFocused(_ focused: Bool) {}
    func setVisible(_ visible: Bool) {}
    func setRenderingAvailable(_ available: Bool) {}
    func refreshPresentation() {}
    func applyTheme(_ themeName: String) {}
    func clearTheme() {}
    func setFontSize(_ size: Double) {}
    func setFontFamily(_ family: String?) {}
    func setGridOverride(_ grid: PaneGridOverride?) {}
    func setCopyOnSelect(_ enabled: Bool) {}
    func setOptionAsAlt(_ policy: OptionAsAlt?) {}
    func setSearchNeedle(_ needle: String) {}
    func navigateSearch(_ direction: SearchDirection) {}
    func endSearch() {}
    func readViewportText() -> String? { nil }
    func readViewportCells() -> TerminalSessionViewportCells? { nil }
    func readRowStructure() -> [TerminalSessionRowStructure]? { nil }
    func readFullHistoryText() -> String? { nil }
    func readPrimaryHistoryText() -> String? { nil }
    func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String? { nil }
    func primaryHistoryTailReader(maxLines: Int, maxChars: Int) -> CheckpointScrollbackRead? { nil }
    func scroll(toRow row: Int) {}
    func copySelection() {}
    func pasteClipboard() {}
    func requestClose() {}
    func fenceForApplicationExit() {}
    func tearDown() {}
}
