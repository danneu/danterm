// The terminal session and presentation surface the pane view is tested against.
//
// `SwiftTerminalSessionView` drives a live terminal through two seams: a session
// controller and the rotation of buffers it presents. The production controller
// forks a PTY child, so this file supplies a recording stand-in for it. The
// production rotation is a final engine type, so the surface here wraps a REAL
// one -- the pixels are rendered by the shipping code, and only the observation
// and the buffer-busy switch belong to the suite.
import Cocoa
import CoreGraphics
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

/// Records what the pane view asked its session to do, and drives the view's own
/// callbacks the way a live terminal would.
@MainActor
final class FakeTerminalPaneSessionController: TerminalPaneSessionControlling {
    var onFrame: ((TerminalPaneFrame) -> Void)?
    var onClipboardWrite: ((String) -> Void)?
    var onSelectionCopy: ((String) -> Void)?
    var onSemanticEvents: (([PaneSemanticEvent]) -> Void)?
    var onProcessStarted: (() -> Void)?
    var onSessionEnded: ((PaneProcessLifecycleResult) -> Void)?
    var onViewportStateChange: ((TerminalPaneViewportState) -> Void)?
    var onOpenLink: ((TerminalHyperlink) -> Void)?
    var onSearchStatus: ((TerminalSearchStatus?) -> Void)?
    var onPrimaryHistoryMutation: (() -> Void)?
    /// Stands in for the real controller's per-fence display-interval read
    /// (research/33 D8); the harness never fences, so it is write-only here.
    var displayRefreshIntervalNanoseconds: () -> UInt64 = { 8_333_333 }
    var currentPlan: RenderFramePlan?
    /// The real controller's fence census, which the frame-rate sampler's call
    /// sites read. The suite never emits a rate sample, so a frozen zero is the
    /// whole contract.
    let fenceMetrics = TerminalPaneFenceMetrics()
    /// Stands in for the real controller's absolute viewport top, which the
    /// delivery-shape sampler's call site reads. Same contract as
    /// `fenceMetrics`: the harness never samples, so a frozen zero suffices.
    let absoluteViewportTopRow = 0
    private(set) var renderTheme = RenderTheme.dark
    private(set) var appliedThemes: [RenderTheme] = []
    var viewportState: TerminalPaneViewportState
    private(set) var scrolledTopRows: [Int] = []
    private(set) var textInputs: [String] = []
    private(set) var inputBytes: [[UInt8]] = []
    /// Every terminal result this controller resolved, in resolution order and with its payload
    /// intact, so a test can name the reason a submission was refused. The view flattens the
    /// reason away at the app boundary, so this is the only place it stays observable.
    private(set) var completedResults: [PaneInputSubmissionResult] = []
    private(set) var deliveredTextInputs: [String] = []
    private(set) var deliveredInputBytes: [[UInt8]] = []
    /// Origin stamps in submission order, so a test can assert which moment the pane view
    /// attributed its input to. The real controller forwards these to the flight recorder.
    private(set) var inputOrigins: [UInt64?] = []
    /// The wait generation stamped on each user-directed submission, in submission order.
    private(set) var submittedWaitGenerations: [PaneInputWaitGeneration?] = []
    private(set) var focusChanges: [Bool] = []
    private(set) var pointerEvents: [TerminalPointerEvent] = []
    private(set) var wheelEvents: [TerminalWheelEvent] = []
    private(set) var searchQueries: [String] = []
    private(set) var searchNextRequests = 0
    private(set) var searchPreviousRequests = 0
    private(set) var clearSearchRequests = 0
    private(set) var synchronizedSelectionReads = 0
    private(set) var linkInteractionCancellations = 0
    /// Stands in for the real controller's cached mouse-tracking answer, which the pane view
    /// reads on every right-button press to decide whether the terminal application claims it.
    var claimsMouseButtons = false
    /// Stands in for lifecycle policy refusing a submission -- a full pending-input buffer, a
    /// failed launch, a closed descriptor. When set, no submission is recorded as delivered and
    /// every completion names this reason, which is what lets a test observe why input was lost.
    var submissionFailure: PaneInputSubmissionFailure?
    var cachedHasSelection = false
    var selectedTextOnFence: String?
    var hoveredLinkForCommandMove: TerminalHyperlink?
    var linkForCommandClick: TerminalHyperlink?
    private var cachedHoveredLink: TerminalHyperlink?
    private var linkClickArmed = false
    private var processIsRunning: Bool
    private var pendingInputDeliveries: [() -> Void] = []
    var inputModes = TerminalInputModes.default

    init(
        viewportState: TerminalPaneViewportState = .init(
            isScrollbarEnabled: true,
            projection: .init(totalRows: 30, topRow: 10, windowRows: 20, isFollowing: false)
        ),
        theme: RenderTheme = .dark,
        currentPlan: RenderFramePlan? = nil,
        processIsRunning: Bool = true
    ) {
        self.viewportState = viewportState
        renderTheme = theme
        self.currentPlan = currentPlan
        self.processIsRunning = processIsRunning
    }

    func sendText(
        _ text: String,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void
    ) {
        textInputs.append(text)
        inputOrigins.append(origin)
        submittedWaitGenerations.append(waitGeneration)
        deliverOrBuffer(onCompletion, waitGeneration: waitGeneration) {
            $0.deliveredTextInputs.append(text)
        }
    }
    func sendKey(
        _ key: TerminalInputKey,
        modifiers: TerminalKeyModifiers,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void
    ) {
        let bytes = encodeTerminalKey(key, modifiers: modifiers, modes: inputModes)
        inputBytes.append(bytes)
        inputOrigins.append(origin)
        submittedWaitGenerations.append(waitGeneration)
        deliverOrBuffer(onCompletion, waitGeneration: waitGeneration) {
            $0.deliveredInputBytes.append(bytes)
        }
    }
    func sendPaste(
        _ text: String,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void
    ) {
        let bytes = encodeTerminalPaste(text, modes: inputModes)
        inputBytes.append(bytes)
        inputOrigins.append(origin)
        submittedWaitGenerations.append(waitGeneration)
        deliverOrBuffer(onCompletion, waitGeneration: waitGeneration) {
            $0.deliveredInputBytes.append(bytes)
        }
    }

    func emitProcessStarted() {
        guard processIsRunning == false else { return }
        processIsRunning = true
        onProcessStarted?()
        let deliveries = pendingInputDeliveries
        pendingInputDeliveries = []
        for delivery in deliveries { delivery() }
    }

    /// Records one submission and resolves it, or holds both until the process starts.
    /// `record` runs only on the delivered path, so a refused submission leaves the
    /// delivered-input logs untouched the way a refused write leaves the descriptor untouched.
    private func deliverOrBuffer(
        _ onCompletion: (@MainActor @Sendable (PaneInputSubmissionResult) -> Void)?,
        waitGeneration: PaneInputWaitGeneration?,
        recording record: @escaping (FakeTerminalPaneSessionController) -> Void
    ) {
        let delivery: () -> Void = { [weak self] in
            guard let self else { return }
            if let submissionFailure {
                complete(onCompletion, with: .rejected(submissionFailure))
            } else {
                record(self)
                // The real owner reports the occurrence only once every byte has crossed
                // the PTY, so the shim reports it only on the delivered branch too.
                onSemanticEvents?([.userInputDelivered(waitGeneration: waitGeneration)])
                complete(onCompletion, with: .delivered)
            }
        }
        if processIsRunning {
            delivery()
        } else {
            pendingInputDeliveries.append(delivery)
        }
    }

    private func complete(
        _ completion: (@MainActor @Sendable (PaneInputSubmissionResult) -> Void)?,
        with result: PaneInputSubmissionResult
    ) {
        completedResults.append(result)
        guard let completion else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { completion(result) }
        }
    }
    func beginSearch(_ query: String) { searchQueries.append(query) }
    func searchNext() { searchNextRequests += 1 }
    func searchPrevious() { searchPreviousRequests += 1 }
    func clearSearch() { clearSearchRequests += 1 }
    func sendFocus(_ focused: Bool, origin: UInt64?) {
        focusChanges.append(focused)
        // The real owner asks its terminal, which retains focus and gates the report on mode
        // 1004; the shim fabricates the same bytes because it owns no terminal.
        guard inputModes.focusReporting else { return }
        inputBytes.append(Array((focused ? "\u{1B}[I" : "\u{1B}[O").utf8))
        inputOrigins.append(origin)
    }
    // `origin` is accepted and dropped: this shim records wheel and pointer input as events
    // rather than as bytes, and only the byte-producing paths above assert on their stamps.
    func sendWheel(
        _ event: TerminalWheelEvent,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void
    ) {
        wheelEvents.append(event)
        submittedWaitGenerations.append(waitGeneration)
        complete(onCompletion, with: submissionFailure.map { .rejected($0) } ?? .delivered)
    }
    func sendPointer(
        _ event: TerminalPointerEvent,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?
    ) {
        submittedWaitGenerations.append(waitGeneration)
        recordPointer(event, origin: origin)
    }
    private func recordPointer(_ event: TerminalPointerEvent, origin: UInt64?) {
        pointerEvents.append(event)
        // Link work follows the real policy: an event the view measured outside the grid arms
        // nothing, hovers nothing, opens nothing, and drops whatever an earlier event armed.
        switch event {
        case let .move(cell, modifiers):
            cachedHoveredLink = cell.isInsideGrid && modifiers.contains(.command)
                ? hoveredLinkForCommandMove
                : nil
            if cell.isInsideGrid == false { linkClickArmed = false }
            emitFrame()
        case let .down(.left, cell, modifiers, _):
            linkClickArmed = cell.isInsideGrid
                && modifiers.contains(.command)
                && linkForCommandClick != nil
        case let .up(.left, cell, modifiers):
            if cell.isInsideGrid, linkClickArmed, modifiers.contains(.command),
               let linkForCommandClick {
                onOpenLink?(linkForCommandClick)
            }
            linkClickArmed = false
        default:
            break
        }
    }
    func cancelLinkInteraction() {
        linkInteractionCancellations += 1
        cachedHoveredLink = nil
        linkClickArmed = false
        emitFrame()
    }
    func readHoveredLink() -> TerminalHyperlink? { cachedHoveredLink }
    private(set) var selectAllRequests = 0
    func selectAll() {
        selectAllRequests += 1
        cachedHasSelection = true
    }
    var hasSelection: Bool { cachedHasSelection }
    func readSelectedTextSynchronizing() -> String? {
        synchronizedSelectionReads += 1
        cachedHasSelection = selectedTextOnFence != nil
        return selectedTextOnFence
    }
    func scroll(toTopRow row: Int) { scrolledTopRows.append(row) }
    func setVisible(_ visible: Bool) {}
    func setRenderingAvailable(_ available: Bool) {}
    func setTheme(_ theme: RenderTheme) {
        renderTheme = theme
        appliedThemes.append(theme)
    }
    func fenceForApplicationExit() {}
    func synchronizeState() {}
    func readViewportText() -> String { "" }
    func readRowStructure() -> [TerminalRowStructure] { [] }
    func readFullHistoryText() -> String { "" }
    func readPrimaryHistoryText() -> String { "" }
    func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String { "" }
    func primaryHistoryTailReader() -> @Sendable (Int, Int) -> String { { _, _ in "" } }
    private(set) var gridDimensions: [TerminalDimensions] = []

    // Mirrors TerminalPaneSession.setGridDimensions(_:pinned:). `pinned` is
    // dropped because no UI test asserts on it yet; record it here the day one
    // does.
    func setGridDimensions(_ dimensions: TerminalDimensions, pinned: Bool) {
        gridDimensions.append(dimensions)
    }
    func tearDown() {
        onOpenLink = nil
        onSearchStatus = nil
        onSemanticEvents = nil
    }

    func emitViewportState(_ state: TerminalPaneViewportState) {
        viewportState = state
        onViewportStateChange?(state)
    }

    func emitClipboardWrite(_ text: String) {
        onClipboardWrite?(text)
    }

    /// Stands in for the engine relaying a completed selection's captured text. A nil
    /// handler is the production gate itself, so calling this while copy-on-select is
    /// off must leave the pasteboard alone rather than trap.
    func emitSelectionCopy(_ text: String) {
        onSelectionCopy?(text)
    }

    /// Takes the terminal's half of the vocabulary, because every test here drives the
    /// pane from the child's side; input occurrences come from the pane's own input path.
    func emitSemanticEvents(_ events: [TerminalSemanticEvent]) {
        onSemanticEvents?(events.map(PaneSemanticEvent.terminal))
    }

    func emitSearchStatus(_ status: TerminalSearchStatus?) {
        onSearchStatus?(status)
    }

    func emitFrameForTest(damage: TerminalDamage = .init(isFull: true)) {
        emitFrame(damage: damage)
    }

    func emitHoveredLinkForTest(_ link: TerminalHyperlink) {
        cachedHoveredLink = link
        emitFrame()
    }

    private func emitFrame(damage: TerminalDamage = .init(isFull: true)) {
        let plan = currentPlan ?? RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        onFrame?(.init(plan: plan, damage: damage))
    }
}
