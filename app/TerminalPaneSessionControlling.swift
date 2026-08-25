// The pane view's seam onto its terminal session controller.
//
// `SwiftTerminalSessionView` drives one live terminal session. The production
// controller for that session owns a forked PTY child, so a test that wants to
// drive the view -- what it sends, what it draws when a frame arrives, what it
// does with a hovered link -- cannot build one. This protocol is the whole of
// what the view asks of its controller, so a test supplies a recording stand-in
// and the view under test stays the production view.
//
// Only the pane view names this. Nothing else in the app talks to a controller.
import Foundation
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderPlanning

/// Everything `SwiftTerminalSessionView` asks of the terminal session behind it.
///
/// Class-bound and main-actor-bound because a session controller is a live,
/// single-owner object on the main actor, and the view installs callbacks on it.
@MainActor
protocol TerminalPaneSessionControlling: AnyObject {
    // MARK: Callbacks the view installs

    var onFrame: ((TerminalPaneFrame) -> Void)? { get set }
    var onClipboardWrite: ((String) -> Void)? { get set }
    var onSelectionCopy: ((String) -> Void)? { get set }
    var onSemanticEvents: (([PaneSemanticEvent]) -> Void)? { get set }
    var onSessionEnded: ((PaneProcessLifecycleResult) -> Void)? { get set }
    var onProcessStarted: (() -> Void)? { get set }
    var onViewportStateChange: ((TerminalPaneViewportState) -> Void)? { get set }
    var onPrimaryHistoryMutation: (() -> Void)? { get set }
    var onOpenLink: ((TerminalHyperlink) -> Void)? { get set }
    var onSearchStatus: ((TerminalSearchStatus?) -> Void)? { get set }
    var displayRefreshIntervalNanoseconds: () -> UInt64 { get set }

    // MARK: State the view reads

    var renderTheme: RenderTheme { get }
    var currentPlan: RenderFramePlan? { get }
    var viewportState: TerminalPaneViewportState { get }
    var absoluteViewportTopRow: Int { get }
    var hasSelection: Bool { get }
    var claimsMouseButtons: Bool { get }
    var fenceMetrics: TerminalPaneFenceMetrics { get }
    #if DANTERM_TERMINAL_BENCHMARK
    var lastFenceStallNanoseconds: UInt64 { get }
    var lastPlanDurationNanoseconds: UInt64 { get }
    var lastPlanThreadCPUNanoseconds: UInt64 { get }
    #endif

    // MARK: Input

    func sendText(
        _ text: String,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void
    )
    func sendKey(
        _ key: TerminalInputKey,
        modifiers: TerminalKeyModifiers,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void
    )
    func sendPaste(
        _ text: String,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void
    )
    func sendWheel(
        _ event: TerminalWheelEvent,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void
    )
    func sendPointer(
        _ event: TerminalPointerEvent,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?
    )
    func sendFocus(_ focused: Bool, origin: UInt64?)
    func cancelLinkInteraction()

    // MARK: Presentation and geometry

    func setGridDimensions(_ dimensions: TerminalDimensions, pinned: Bool)
    func setVisible(_ visible: Bool)
    func setRenderingAvailable(_ available: Bool)
    func setTheme(_ theme: RenderTheme)
    func scroll(toTopRow row: Int)

    // MARK: Selection, links, search

    func selectAll()
    func readSelectedTextSynchronizing() -> String?
    func readHoveredLink() -> TerminalHyperlink?
    func beginSearch(_ query: String)
    func searchNext()
    func searchPrevious()
    func clearSearch()

    // MARK: Reads

    func synchronizeState()
    func readViewportText() -> String
    func readViewportCells() -> TerminalViewportCells
    func readRowStructure() -> [TerminalRowStructure]
    func readFullHistoryText() -> String
    func readPrimaryHistoryText() -> String
    func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String
    func primaryHistoryTailReader() -> @Sendable (Int, Int) -> String

    // MARK: Lifetime

    func fenceForApplicationExit()
    func tearDown()
}

/// The call shapes the view uses that a protocol requirement cannot carry,
/// because a requirement has no default arguments.
extension TerminalPaneSessionControlling {
    func sendText(_ text: String, origin: UInt64?, waitGeneration: PaneInputWaitGeneration?) {
        sendText(text, origin: origin, waitGeneration: waitGeneration, onCompletion: { _ in })
    }

    func sendKey(
        _ key: TerminalInputKey,
        modifiers: TerminalKeyModifiers,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?
    ) {
        sendKey(
            key,
            modifiers: modifiers,
            origin: origin,
            waitGeneration: waitGeneration,
            onCompletion: { _ in }
        )
    }

    func sendPaste(_ text: String, origin: UInt64?, waitGeneration: PaneInputWaitGeneration?) {
        sendPaste(text, origin: origin, waitGeneration: waitGeneration, onCompletion: { _ in })
    }

    func sendWheel(
        _ event: TerminalWheelEvent,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?
    ) {
        sendWheel(event, origin: origin, waitGeneration: waitGeneration, onCompletion: { _ in })
    }

    func sendPointer(_ event: TerminalPointerEvent, origin: UInt64?) {
        sendPointer(event, origin: origin, waitGeneration: nil)
    }
}

/// The flight recorder behind a session, for the pane-tape stream the CLI follows.
///
/// Separate from `TerminalPaneSessionControlling` because a recorder fence is a
/// value only a live recorder can mint: a session with no recorder behind it
/// serves no tape, and saying so by not conforming is clearer than a protocol
/// full of members that must return nothing.
@MainActor
protocol TerminalPaneTapeSource: AnyObject {
    func flightRecordingStreamFence(
        request: TerminalFlightRecordingStreamRequest
    ) -> TerminalFlightRecordingStreamFence
    func addFlightRecordingFollowSubscription(
        id: UUID,
        from cursor: TerminalFlightRecordingCursor,
        replicaHistoryIsComplete: Bool,
        decide: @escaping @Sendable (
            TerminalFlightRecordingCursorSnapshot,
            Bool
        ) -> TerminalFlightRecordingFollowDecision,
        deliver: @escaping @Sendable (TerminalFlightRecordingFollowBatch) -> Void
    ) -> Bool
    func markFlightRecordingFollowSubscriptionReady(
        id: UUID,
        replicaHistoryIsComplete: Bool
    )
    func removeFlightRecordingFollowSubscription(id: UUID)
}

// The production controller already has every member the view asks for, so the
// conformances add nothing; they only state that the real session satisfies the seams.
extension TerminalPaneSessionController: TerminalPaneSessionControlling {}
extension TerminalPaneSessionController: TerminalPaneTapeSource {}
