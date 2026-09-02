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
    /// One past the last column with a visible effect; the paint extent, never below
    /// `contentEnd`, with the margin-reaching fill collapsed into `fill`.
    let visibleEnd: Int
    /// The style painted from `visibleEnd` to the margin, nil when the margin is default.
    let fill: TerminalSessionCellStyle?
    let width: Int
    /// The engine's margin cell kind spelled as its case name ("padding", "narrow", ...),
    /// restated as a string for the same boundary reason the struct exists.
    let marginKind: String
    let staleWrapClaim: Bool
}

/// One cell style restated as strings for the same boundary reason as the row structure.
/// Colors spell as `default`, `indexed:<n>` or `#rrggbb`; `attributes` lists the set flags by
/// name (`bold`, `dim`, `italic`, `underline:<style>`, `reverse`, `hidden`, `strikethrough`).
struct TerminalSessionCellStyle: Equatable {
    let foreground: String
    let background: String
    let underlineColor: String
    let attributes: [String]
}

/// Restates one engine viewport span without exposing terminal grid types to AppKit callers.
struct TerminalSessionViewportCellSpan: Equatable {
    let kind: String
    let column: Int
    let cellWidth: Int
    let text: String?
    let utf8Offsets: [Int]?
}

/// Restates one row of the session's coordinate-preserving viewport readout.
struct TerminalSessionViewportCellRow: Equatable {
    let index: Int
    let spans: [TerminalSessionViewportCellSpan]
}

/// Carries a coherent viewport cell projection across the AppKit session boundary.
struct TerminalSessionViewportCells: Equatable {
    let columns: Int
    let rowCount: Int
    let paneRowsOrigin: Int
    let rows: [TerminalSessionViewportCellRow]
}

/// What one pane's presentation buffers cost the process right now, restated in app
/// terms so the engine's surface types stay out of this protocol.
///
/// Every field is derived when it is read, from the objects that own the surfaces:
/// nothing here is incremented on create or decremented on release, so nothing can
/// drift out of step with what the process holds (research/41 T1).
struct TerminalSessionSurfaceCensus: Equatable {
    /// The live rotation's buffers. Nil when the pane holds no rotation at all --
    /// distinct from a rotation of zero buffers, which cannot exist.
    struct Swapchain: Equatable {
        let storeCount: Int
        let bytes: Int
        let pixelWidth: Int
        let pixelHeight: Int
        /// The buffers by the kernel's own purgeability answer, read when the
        /// census is read (research/41 D2). `bytes` is mapped size and does not
        /// move when a buffer goes volatile, which is why the states have to be
        /// reported beside it: a volatile buffer keeps its mapping and loses its
        /// resident pages, and only `nonVolatileBytes` follows the footprint.
        let nonVolatileStores: Int
        let volatileStores: Int
        let emptyStores: Int
        /// Stores whose purgeability the kernel refused to report. Counted
        /// separately so an unreadable state is never summed as a known one.
        let unknownStores: Int
        let nonVolatileBytes: Int
    }

    let isVisible: Bool
    let swapchain: Swapchain?
    /// The frame still on screen when the live rotation does not hold it -- a
    /// replaced rotation leaves its predecessor's store retained until the
    /// successor presents. Nil when there is no such store, which is the ordinary
    /// case; a walk of rotations alone would under-report exactly here.
    let displayedStoreOutsideSwapchainBytes: Int?
}

/// Scrollbar position reported by a terminal session in logical terminal rows.
struct TerminalScrollPosition: Equatable {
    let total: UInt64
    let offset: UInt64
    let length: UInt64
}

/// View-local terminal state consumed synchronously by the native scroll chrome.
///
/// One field carries the pane's one absence: `cellHeight` is nil until the pane has
/// laid out a grid, and every other field is always meaningful. A session always
/// knows where its viewport sits in its own scrollback, so `scrollPosition` cannot
/// go missing -- what a fresh pane lacks is the cell box that turns rows into pixels.
struct TerminalSessionState: Equatable {
    let scrollbarEnabled: Bool
    let cellHeight: CGFloat?
    let scrollPosition: TerminalScrollPosition
    /// The pane's current terminal default background. It rides this channel because
    /// the focus-ring gutter lives outside the terminal view and so cannot inherit
    /// that view's theme-colored layer background.
    let background: CGColor
}

/// Preserves why an app-submitted input item could not cross the PTY boundary.
enum TerminalInputSubmissionFailure: Equatable {
    case bufferLimitExceeded
    case canonicalModeTimeout
    case launchFailed
    case processEnded
    case writeFailed(Int32)
}

/// Restates one app-submitted input item's terminal PTY result.
enum TerminalInputSubmissionResult: Equatable {
    case delivered
    case rejected(TerminalInputSubmissionFailure)
}

/// Retains only the terminal owner needed to disarm one recorder append edge safely.
@MainActor
struct PaneTapeFollowRegistration {
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
    /// The session's on-demand read of its own agent wait. It is gated with the emit
    /// channels because it closes over the runtime the same way they do, so a torn-down
    /// session must not call it either.
    var currentAgentWaitGeneration: (() -> AgentWaitGeneration?)?
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

    func agentWaitGeneration() -> AgentWaitGeneration? {
        guard isActive else { return nil }
        return currentAgentWaitGeneration?()
    }

    func tearDown() {
        isActive = false
        onEvent = nil
        currentAgentWaitGeneration = nil
        stateObserver = nil
    }
}

/// Inputs needed to create one terminal session without exposing adapter handles.
struct TerminalSessionRequest {
    let workingDirectory: String?
    let command: String?
    let launchCommand: String?
    let waitAfterCommand: Bool
    let environment: [(String, String)]
    /// App-wide policy captured at the runtime's sole session-construction funnel.
    let localeFallbackEnabled: Bool
    /// The pane's whole desired terminal config, from the same `paneConfigKey`
    /// derivation the reconciler diffs. Carried as one value rather than loose
    /// appearance fields so a pane mounts with exactly what the first reconcile pass
    /// would otherwise push, and so a field added to the key becomes a construction
    /// question the compiler asks. Passed in rather than read from the live model at
    /// this seam because restore derives against a staged model that has not replaced
    /// the live one yet.
    let config: PaneConfigKey
    /// Reports the initial interactive command after all of its bytes cross the PTY or fail.
    let onLaunchInputCompletion: (@MainActor @Sendable (TerminalInputSubmissionResult) -> Void)?
}

/// Stable per-pane terminal owner mounted and reparented by the AppKit reconciler.
@MainActor
protocol TerminalSession: AnyObject {
    var hostView: NSView { get }
    /// Supplies the pane context menu the terminal view hands AppKit from a right-button or
    /// control-click press. The owner installs it; the view never builds a menu itself.
    var paneMenuProvider: (() -> NSMenu?)? { get set }
    var state: TerminalSessionState { get }
    var stateObserver: (any TerminalSessionStateObserver)? { get set }
    var onEvent: ((TerminalSessionEvent) -> Void)? { get set }
    /// Reads the agent wait this pane's session holds right now, for input the session
    /// originates itself -- typing, paste, drag-and-drop, the pointer.
    ///
    /// A closure rather than a pushed value because the answer must be read at the
    /// instant of the submission. The view sweep that refreshes pushed pane state is
    /// coalesced, so a copy would still name the previous wait exactly when a wait has
    /// just been admitted -- and the one keystroke that dismisses it would retract
    /// nothing. Input the runtime dispatches as a `Command` carries its own snapshot
    /// instead, taken in the same pure dispatch that read the model.
    var currentAgentWaitGeneration: (() -> AgentWaitGeneration?)? { get set }
    var onPrimaryHistoryMutation: (() -> Void)? { get set }
    var hasSelection: Bool { get }
    #if DANTERM_TERMINAL_BENCHMARK
    /// Exposes only the achieved grid and cell metrics needed for benchmark convergence.
    var benchmarkGeometry: TerminalBenchmarkGeometry? { get }
    #endif

    /// Submits one runtime-originated input and reports the terminal's real delivery result.
    func submitInput(
        _ input: PaneInputItem,
        waitGeneration: AgentWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (TerminalInputSubmissionResult) -> Void
    )
    /// Reports whether this pane's terminal receives the user's keystrokes.
    func setFocused(_ focused: Bool)
    func setVisible(_ visible: Bool)
    func setRenderingAvailable(_ available: Bool)
    /// Re-checks every input that decides the session's pixels -- backing scale, cell
    /// geometry, and the window's color space -- and re-renders if one moved. The
    /// runtime calls it on a screen change, where AppKit can skip its own callback.
    func refreshPresentation()
    /// Applies one appearance decision. Each of these is a piece of a `PaneConfigKey`,
    /// and `apply(_:)` is the only caller that pushes a whole key through them.
    func applyTheme(_ themeName: String)
    func clearTheme()
    /// Applies the pane's whole font request. It arrives as the core's own font value,
    /// the same one the config key carries, so no type on the way here can hold a size
    /// and a family the producer never derived together. It is not the engine's font
    /// type, because this protocol is the seam that keeps engine types out of the app.
    func setFont(_ font: PaneFont)
    /// Fixes the pane's grid at a claimed size, or with nil hands it back to the
    /// pane's rectangle. While a grid is set no rectangle, scale, or font input
    /// may move the grid the child runs at.
    func setGridOverride(_ grid: PaneGridOverride?)
    /// Arms or disarms copy-on-select. Enabling installs the completion subscriber the
    /// engine gates text extraction on, so disabling costs the pointer path nothing.
    func setCopyOnSelect(_ enabled: Bool)
    /// Changes physical Option text routing for the next key event without replacing the session.
    func setOptionAsAlt(_ policy: OptionAsAlt?)
    func setSearchNeedle(_ needle: String)
    func navigateSearch(_ direction: SearchDirection)
    func endSearch()
    /// Reads what this pane's presentation buffers cost the process, or nil when
    /// this session has no presentation of its own to measure. Nil is the
    /// unmeasured answer and is reported as such: a session that owns no surfaces
    /// must never be summed as a zero.
    func readSurfaceCensus() -> TerminalSessionSurfaceCensus?
    func readViewportText() -> String?
    func readViewportCells() -> TerminalSessionViewportCells?
    func readRowStructure() -> [TerminalSessionRowStructure]?
    func readFullHistoryText() -> String?
    /// Reads persistent primary history without changing pane-read active-screen semantics.
    func readPrimaryHistoryText() -> String?
    /// Reads the primary-history tail after applying these positional limits once.
    func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String?
    /// Copies the pane's terminal now and returns that same bounded read, deferred off the main
    /// actor -- the recovery checkpoint's expensive half. nil when this session has no history
    /// to read, which leaves the caller to read eagerly instead.
    func primaryHistoryTailReader(maxLines: Int, maxChars: Int) -> CheckpointScrollbackRead?
    /// Fences every value needed to open one raw or reconstructible tape stream.
    func paneTapeOpening(
        capture: PaneTapeCaptureMode,
        start: PaneTapeStartPosition,
        policy: PaneTapeSyncPolicy
    ) -> (@Sendable () throws -> PaneTapeOpening<PaneTapeSessionEvent>)?
    /// Registers recorder-owned follow state and hands each decided batch to transport.
    func addPaneTapeFollowSubscription(
        id: UUID,
        cursor: PaneTapeCursor,
        policy: PaneTapeSyncPolicy,
        replicaHistoryIsComplete: Bool,
        deliver: @escaping @Sendable (
            @escaping @Sendable () -> PaneTapeContinuation<PaneTapeSessionEvent>
        ) -> Void
    ) -> PaneTapeFollowRegistration?
    /// Rearms one recorder-owned subscription after its previous write flushes.
    func markPaneTapeFollowReady(id: UUID, replicaHistoryIsComplete: Bool)
    func scroll(toRow row: Int)
    func copySelection()
    func pasteClipboard()
    /// Fences accepted terminal mutations before the final recovery capture.
    func fenceForApplicationExit()
    func tearDown()
}

/// The one place a `PaneConfigKey` becomes applied session state. Mount and the reconcile
/// diff both call it, so a pane holds exactly what the next diff would push and neither
/// seam can honor a field the other drops. It lives in an extension rather than as a
/// protocol requirement so no conformer can supply a second version of it: a field added
/// to the key is applied here or nowhere.
extension TerminalSession {
    func apply(_ config: PaneConfigKey) {
        applyTheme(config.theme)
        setFont(config.font)
        setCopyOnSelect(config.copyOnSelect)
        setOptionAsAlt(config.optionAsAlt)
        setGridOverride(config.gridOverride)
    }
}

/// Every terminal pane records, so these defaults exist only for a session with no terminal
/// behind it -- the UI-test shim. A live terminal pane always overrides them with a real tape.
extension TerminalSession {
    func paneTapeOpening(
        capture: PaneTapeCaptureMode,
        start: PaneTapeStartPosition,
        policy: PaneTapeSyncPolicy
    ) -> (@Sendable () throws -> PaneTapeOpening<PaneTapeSessionEvent>)? { nil }
    func addPaneTapeFollowSubscription(
        id: UUID,
        cursor: PaneTapeCursor,
        policy: PaneTapeSyncPolicy,
        replicaHistoryIsComplete: Bool,
        deliver: @escaping @Sendable (
            @escaping @Sendable () -> PaneTapeContinuation<PaneTapeSessionEvent>
        ) -> Void
    ) -> PaneTapeFollowRegistration? { nil }
    func markPaneTapeFollowReady(id: UUID, replicaHistoryIsComplete: Bool) {}
}
