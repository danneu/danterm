// DanTerm-owned AppKit boundary for stable per-pane terminal sessions -- the
// contract that pane containers, the reconciler, and UI test doubles all speak.
// Terminal handles, bytes, grids, and rendering stay out.
import Cocoa
import DanTermProtocol

/// One display row's line structure, restated at this boundary so the engine's grid types stay
/// out of the session protocol. Diagnostic only: `danterm pane rows` is its sole consumer.
struct TerminalSessionRowStructure: Equatable {
    let index: Int
    let isRetained: Bool
    let isSoftWrapped: Bool
    let contentEnd: Int
    let width: Int
    /// The engine's margin cell kind spelled as its case name ("padding", "narrow", ...),
    /// restated as a string for the same boundary reason the struct exists.
    let marginKind: String
    let staleWrapClaim: Bool
}

/// Scrollbar position reported by a terminal session in logical terminal rows.
struct TerminalScrollPosition: Equatable {
    let total: UInt64
    let offset: UInt64
    let length: UInt64
}

/// View-local terminal state consumed synchronously by the native scroll chrome.
struct TerminalSessionState: Equatable {
    let scrollbarEnabled: Bool
    let cellHeight: CGFloat
    let scrollPosition: TerminalScrollPosition?
}

/// Retains only the terminal owner needed to disarm one recorder append edge safely.
@MainActor
struct PaneTapeFollowNoticeRegistration {
    private let cancelAction: @MainActor () -> Void

    init(cancel: @escaping @MainActor () -> Void) {
        cancelAction = cancel
    }

    func cancel() {
        cancelAction()
    }
}

/// Receives main-actor session state without routing view-only data through AppModel.
@MainActor
protocol TerminalSessionStateObserver: AnyObject {
    func terminalSessionStateDidChange(_ state: TerminalSessionState)
}

/// Gates both terminal callback channels at the session teardown boundary.
@MainActor
final class TerminalSessionCallbackGate {
    var onEvent: ((TerminalSessionEvent) -> Void)?
    weak var stateObserver: (any TerminalSessionStateObserver)?
    private(set) var isActive = true

    func emit(_ event: TerminalSessionEvent) {
        guard isActive else { return }
        onEvent?(event)
    }

    func emit(_ state: TerminalSessionState) {
        guard isActive else { return }
        stateObserver?.terminalSessionStateDidChange(state)
    }

    func tearDown() {
        isActive = false
        onEvent = nil
        stateObserver = nil
    }
}

/// Inputs needed to create one terminal session without exposing adapter handles.
///
/// The three appearance fields are passed in rather than read from `DanTermConfig` at
/// the creation seam, and that is deliberate on two counts. `themeName` is genuinely
/// per-pane: it resolves the live connection, pane theme, and config default, so the
/// global value is only the last fallback. `fontSize` and `fontFamily` are global, but
/// *which* model they come from is not -- restore builds its sessions against a staged
/// model that has not replaced the live one yet, so a seam that read `self.model` would
/// dress restored panes in the pre-restore config. `fontFamily` additionally is not a
/// config value at all: it is the CoreText-resolved family the core cannot compute.
struct TerminalSessionRequest {
    let workingDirectory: String?
    let command: String?
    let launchCommand: String?
    let waitAfterCommand: Bool
    let environment: [(String, String)]
    let themeName: String?
    let fontSize: Double
    /// The verified-installed family, or nil for the system monospace font; the raw
    /// requested name never reaches rendering.
    let fontFamily: String?
}

/// Stable per-pane terminal owner mounted and reparented by the AppKit reconciler.
@MainActor
protocol TerminalSession: AnyObject {
    var hostView: NSView { get }
    var paneWrapper: PaneWrapperView? { get set }
    var state: TerminalSessionState { get }
    var stateObserver: (any TerminalSessionStateObserver)? { get set }
    var onEvent: ((TerminalSessionEvent) -> Void)? { get set }
    var onPrimaryHistoryMutation: (() -> Void)? { get set }
    var hasSelection: Bool { get }
    #if DANTERM_TERMINAL_BENCHMARK
    /// Exposes only the achieved grid and cell metrics needed for benchmark convergence.
    var benchmarkGeometry: TerminalBenchmarkGeometry? { get }
    #endif

    func sendText(_ text: String)
    func sendInputText(_ text: String)
    func sendInputKey(_ key: KeyName, modifiers: KeyMods)
    func setFocused(_ focused: Bool)
    func setVisible(_ visible: Bool)
    func setRenderingAvailable(_ available: Bool)
    func refreshBackingProperties()
    func applyTheme(_ themeName: String)
    func clearTheme()
    func setFontSize(_ size: Double)
    func setFontFamily(_ family: String?)
    /// Arms or disarms copy-on-select. Enabling installs the completion subscriber the
    /// engine gates text extraction on, so disabling costs the pointer path nothing.
    func setCopyOnSelect(_ enabled: Bool)
    func startSearch()
    func setSearchNeedle(_ needle: String)
    func navigateSearch(_ direction: SearchDirection)
    func endSearch()
    func readViewportText() -> String?
    func readRowStructure() -> [TerminalSessionRowStructure]?
    func readFullHistoryText() -> String?
    /// Reads persistent primary history without changing pane-read active-screen semantics.
    func readPrimaryHistoryText() -> String?
    /// Reads only the primary-history tail a truncation at this budget can keep.
    func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String?
    /// Copies the pane's terminal now and returns that same bounded read, deferred off the main
    /// actor -- the recovery checkpoint's expensive half. nil when this session has no history
    /// to read, which leaves the caller to read eagerly instead.
    func primaryHistoryTailReader() -> CheckpointScrollbackRead?
    /// Copies the pane tape now and returns work that can encode it away from the main actor.
    func flightRecordingEncoder() -> (@Sendable () throws -> Data)?
    /// Fences the chosen stream origin and defers its protocol adaptation off the main actor.
    func paneTapeFollowStart(
        fromNow: Bool
    ) -> (@Sendable () throws -> PaneTapeFollowStart)?
    /// Arms one append edge at the start cursor without moving recorder events across queues.
    func addPaneTapeFollowNotice(
        id: UUID,
        cursor: PaneTapeFollowCursor,
        notify: @escaping @Sendable () -> Void
    ) -> PaneTapeFollowNoticeRegistration?
    /// Fences one retained suffix and defers event adaptation off the main actor.
    func paneTapeFollowBatch(
        subscriptionId: UUID,
        from cursor: PaneTapeFollowCursor
    ) -> (@Sendable () throws -> PaneTapeFollowSnapshot)?
    func scroll(toRow row: Int)
    func copySelection()
    func pasteClipboard()
    func requestClose()
    func setFocusBorder(_ focused: Bool, hasBell: Bool)
    /// Fences accepted terminal mutations before the final recovery capture.
    func fenceForApplicationExit()
    func tearDown()
}

extension TerminalSession {
    /// Only a bundle built with recording enabled has a tape to encode; the default keeps
    /// every other bundle out of the recorder's implementation entirely.
    func flightRecordingEncoder() -> (@Sendable () throws -> Data)? { nil }
    /// A bundle without a recorded tape has no follow origin to fence.
    func paneTapeFollowStart(
        fromNow: Bool
    ) -> (@Sendable () throws -> PaneTapeFollowStart)? { nil }
    /// A backend without a tape cannot install an append edge.
    func addPaneTapeFollowNotice(
        id: UUID,
        cursor: PaneTapeFollowCursor,
        notify: @escaping @Sendable () -> Void
    ) -> PaneTapeFollowNoticeRegistration? { nil }
    /// Without a follow origin there can never be a later cursor batch.
    func paneTapeFollowBatch(
        subscriptionId: UUID,
        from cursor: PaneTapeFollowCursor
    ) -> (@Sendable () throws -> PaneTapeFollowSnapshot)? { nil }
}
