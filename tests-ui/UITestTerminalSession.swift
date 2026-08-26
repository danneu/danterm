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
import DanTermProtocol
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
// `@testable` here, not a plain import, for the frame plan and the fence census: both
// are values only the engine mints in production, and their memberwise initializers are
// internal. A test that must hand the view a plan of a chosen shape needs them, and the
// same-package form of this is already proven by client-tests.
@testable import TerminalPaneSession
@testable import TerminalRenderPlanning
@testable import DanTerm

/// One semantic key submission, as the pane view named it rather than as it encodes.
struct RecordedTerminalKey: Equatable {
    let key: TerminalInputKey
    let modifiers: TerminalKeyModifiers
}

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
    /// Every `sendKey` submission with its semantic identity intact. The encoded bytes above
    /// cannot stand in for it: Command is byte-inert in the encoder, so a chord forwarded with
    /// the Command bit still set would encode identically to one that dropped it.
    private(set) var sentKeys: [RecordedTerminalKey] = []
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
    private(set) var deliveredWheelEvents: [TerminalWheelEvent] = []
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
        sentKeys.append(RecordedTerminalKey(key: key, modifiers: modifiers))
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
        let result: PaneInputSubmissionResult
        if let submissionFailure {
            result = .rejected(submissionFailure)
        } else {
            deliveredWheelEvents.append(event)
            result = .delivered
        }
        complete(onCompletion, with: result)
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
    func readViewportCells() -> TerminalViewportCells {
        TerminalViewportCells(columns: 1, rowCount: 1, paneRowsOrigin: 0, rows: [
            TerminalViewportCellRow(index: 0, spans: []),
        ])
    }
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

    func emitFrameForTest(damage: TerminalDamage = .full) {
        emitFrame(damage: damage)
    }

    func emitHoveredLinkForTest(_ link: TerminalHyperlink) {
        cachedHoveredLink = link
        emitFrame()
    }

    private func emitFrame(damage: TerminalDamage = .full) {
        let plan = currentPlan ?? RenderFramePlan(defaultBackground: RenderTheme.dark.defaultBackground)
        onFrame?(.init(plan: plan, damage: damage))
    }
}

// MARK: - Presentation surface

/// Records what the production view asked its buffers to present, so the suite can
/// pin the single render path -- which rows a publish rendered, which publishes
/// coalesced, which retry finished one -- without pixels or a compositor.
///
/// This is a stand-in rotation, NOT a wrapper around a real `TerminalFrameSwapchain`.
/// The shipping rotation keeps three buffers and picks the least-stale detached one,
/// so a second publish lands in a fresh buffer and renders in full; this one keeps a
/// single buffer that composes stale damage, so a second publish renders only what
/// changed. Every rendered-row assertion in this suite was written against the second
/// shape, and swapping in the first would silently redefine what those cases claim.
/// Proving the three-buffer rotation is the engine's own job, in its swapchain tests.
///
/// Acquisition is a switch because the real gate is the render server's in-use
/// report, which no headless suite can steer.
@MainActor
final class RecordingPresentationSurface: TerminalPanePresentationSurface {
    /// False stands in for a render server still reading every detached surface:
    /// no buffer is acquirable, so every publish coalesces.
    static var canAcquire = true
    /// The rows each render covered, in order. A full render records every row; an
    /// incremental render records the damage composed since the buffer was current.
    private(set) static var renderedRowSets: [Set<Int>] = []
    /// Counts rotation construction, so a test can tell a replacement (a
    /// trust-breaking input) from a re-render of the same buffers.
    private(set) static var creationCount = 0

    static func reset() {
        canAcquire = true
        renderedRowSets = []
        creationCount = 0
    }

    /// The factory a test hands to the pane view. Nil geometry is the same refusal
    /// the shipping rotation gives when a store cannot be allocated.
    static let factory: TerminalPanePresentationSurfaceFactory = { columns, rows, metrics, colorSpace in
        RecordingPresentationSurface(
            columns: columns,
            rows: rows,
            metrics: metrics,
            colorSpace: colorSpace
        )
    }

    private let store: TerminalFrameBackingStore
    private let columns: Int
    private let rows: Int
    private let metrics: TerminalRenderMetrics
    private let colorSpace: CGColorSpace?
    private var pendingPlan: RenderFramePlan?
    private var staleDamage = TerminalDamage.none
    private var isCurrent = false

    private(set) var lastRenderedDamage: TerminalDamage?
    var hasPendingPresentation: Bool { pendingPlan != nil }
    /// One buffer, so it is always caught up with itself.
    var allBuffersHaveRenderedLatestWholeFrameDamage: Bool { isCurrent }

    init?(
        columns: Int,
        rows: Int,
        metrics: TerminalRenderMetrics,
        colorSpace: CGColorSpace? = nil
    ) {
        guard let store = TerminalFrameBackingStore(
            columns: columns,
            rows: rows,
            metrics: metrics,
            colorSpace: colorSpace
        ) else { return nil }
        self.store = store
        self.columns = columns
        self.rows = rows
        self.metrics = metrics
        self.colorSpace = colorSpace
        Self.creationCount += 1
    }

    func matches(
        columns: Int,
        rows: Int,
        metrics: TerminalRenderMetrics,
        colorSpace: CGColorSpace?
    ) -> Bool {
        self.columns == columns && self.rows == rows
            && matches(metrics: metrics, colorSpace: colorSpace)
    }

    func matches(metrics: TerminalRenderMetrics, colorSpace: CGColorSpace?) -> Bool {
        self.metrics == metrics && self.colorSpace == colorSpace
    }

    func requireEveryBufferToRenderAgain() {
        isCurrent = false
    }

    func publish(plan: RenderFramePlan, damage: TerminalDamage) -> TerminalFrameBackingStore? {
        staleDamage.formUnion(damage)
        pendingPlan = plan
        return presentPending()
    }

    func retryPendingPresentation() -> TerminalFrameBackingStore? {
        presentPending()
    }

    private func presentPending() -> TerminalFrameBackingStore? {
        guard pendingPlan != nil, Self.canAcquire else { return nil }
        let rendered: TerminalDamage = isCurrent && staleDamage.isFull == false
            ? staleDamage
            : .full
        Self.renderedRowSets.append(
            rendered.isFull ? Set(0..<rows) : Set(rendered.rowIndices)
        )
        lastRenderedDamage = rendered
        isCurrent = true
        staleDamage = .none
        pendingPlan = nil
        return store
    }
}

// MARK: - Frame plans

extension RenderFramePlan {
    /// The suite's viewport row count. Named so a test can enumerate every row
    /// without restating the literal the default `rowCount` already carries.
    static let rowsForTesting = 10

    /// A blank plan of a chosen shape.
    ///
    /// The pane view reads a plan's geometry and its clear color and hands the rest
    /// to the renderer, so an empty row carries everything these cases need. The
    /// grid defaults to the suite's viewport and a test overrides it only to stand
    /// in for a resize -- the one trust-breaking input that reaches the view as a
    /// differently-shaped plan rather than as new metrics.
    init(
        defaultBackground: RenderColor,
        columns: Int = 10,
        rowCount: Int = RenderFramePlan.rowsForTesting
    ) {
        self.init(
            columns: columns,
            defaultBackground: defaultBackground,
            rows: Array(
                repeating: RenderPlanRow(
                    backgroundRuns: [],
                    overlayRuns: [],
                    textRuns: [],
                    decorationRuns: [],
                    inkClass: []
                ),
                count: rowCount
            ),
            cursor: nil
        )
    }
}

extension RenderTheme {
    /// A theme identified only by the color the pane clears to.
    ///
    /// The pane view reads exactly one field of a theme -- the default background,
    /// which it paints the layer and the frame plan with -- and hands the rest to the
    /// renderer. A case that swaps themes is asking whether the view followed the
    /// swap, so naming the one field it can observe states the claim directly.
    init(defaultBackground: RenderColor) {
        self.init(
            ansiColors: RenderANSIColors(exactly: Array(repeating: defaultBackground, count: 16))!,
            defaultForeground: defaultBackground,
            defaultBackground: defaultBackground,
            selectionForeground: defaultBackground,
            selectionBackground: defaultBackground,
            cursor: defaultBackground,
            cursorText: defaultBackground
        )
    }
}

// MARK: - Pane view under test

/// Family names the suite's metrics resolver answers for.
///
/// The engine's real metrics carry a measured font set, so a synthetic cell box
/// cannot be built. These name the two answers a pane must handle -- a face with
/// no usable geometry, and a face whose geometry differs from the default -- and
/// the resolver below produces them from real measurements.
enum UITestFontFamily {
    /// A face that passes an availability probe yet yields no usable cell box, which
    /// is what an installed face missing its nominal `M` glyph does.
    static let unusable = "DanTermTestUnusableFace"
    /// A face whose cells differ from the default family's, so a live family change is
    /// observable in the grid the pane reports rather than only in metrics.
    static let wide = "DanTermTestWideFace"
}

/// The suite's cell geometry: real measurements, with the two named families
/// answered deterministically.
@MainActor
func uiTestMetrics(
    displayScale: CGFloat,
    fontChoice: TerminalFontChoice
) -> TerminalRenderMetrics? {
    switch fontChoice.family {
    case UITestFontFamily.unusable:
        return nil
    case UITestFontFamily.wide:
        return liveTerminalPaneMetrics(
            displayScale: displayScale,
            fontChoice: TerminalFontChoice(family: nil, size: fontChoice.size * 2)
        )
    default:
        // The default family is deliberately dropped: which faces are installed is a
        // property of the machine, and no case here is about font lookup.
        return liveTerminalPaneMetrics(
            displayScale: displayScale,
            fontChoice: TerminalFontChoice(family: nil, size: fontChoice.size)
        )
    }
}

/// The production pane view, with the two collaborators the suite substitutes bound.
///
/// Every case builds its pane here so no case can silently get the shipping rotation
/// or the machine's own font lookup and then assert against numbers derived from
/// neither. A case about how a pane answers one particular metrics result -- a face
/// that refuses one display scale, say -- states its own resolver through
/// `makeMetrics` and still gets the production view.
@MainActor
func makeTestPane(
    controller: any TerminalPaneSessionControlling,
    fontSize: Double = DanTermConfig.default.resolvedFontSize,
    fontFamily: String? = nil,
    optionAsAlt: OptionAsAlt? = nil,
    gridOverride: PaneGridOverride? = nil,
    resolveTheme: @escaping (String) -> RenderTheme? = ThemeCatalog.shared.renderTheme(named:),
    makeMetrics: @escaping TerminalPaneMetricsFactory = uiTestMetrics,
    onSessionEnded: ((PaneProcessLifecycleResult) -> Void)? = nil
) -> SwiftTerminalSessionView {
    SwiftTerminalSessionView(
        controller: controller,
        fontChoice: TerminalFontChoice(family: fontFamily, size: CGFloat(fontSize)),
        optionAsAlt: optionAsAlt,
        gridOverride: gridOverride,
        resolveTheme: resolveTheme,
        makePresentationSurface: RecordingPresentationSurface.factory,
        makeMetrics: makeMetrics,
        onSessionEnded: onSessionEnded
    )
}

/// The grid a pane of `size` reports for `metrics`, by the engine's own floor rule.
///
/// The suite reads its expected geometry from the metrics it injected rather than
/// from a fixed cell box, because the real cell box depends on the machine's system
/// monospace face.
@MainActor
func expectedGrid(
    paneSize: CGSize,
    metrics: TerminalRenderMetrics
) -> TerminalDimensions? {
    terminalGridDimensions(
        size: TerminalPointSize(width: paneSize.width, height: paneSize.height),
        cellSize: TerminalPointSize(
            width: metrics.cellSize.width,
            height: metrics.cellSize.height
        )
    )
}

/// The metrics the suite's resolver gives for one font choice, at the scale a test
/// window runs at.
@MainActor
func uiTestMetrics(fontSize: CGFloat, fontFamily: String? = nil) -> TerminalRenderMetrics {
    uiTestMetrics(
        displayScale: NSScreen.main?.backingScaleFactor ?? 2,
        fontChoice: TerminalFontChoice(family: fontFamily, size: fontSize)
    )!
}

/// The cell box a pane resolved, or the box its font implies before it has laid out.
///
/// Read from the pane rather than fixed, because the engine's metrics come from a
/// real font measurement and a synthetic cell box cannot be built. A case that means
/// "an eighth of the way into column 2" says so through `paneCellPoint` instead of
/// naming a point that only lands there for one particular face.
@MainActor
func paneCellSize(
    _ pane: SwiftTerminalSessionView,
    fontSize: CGFloat = CGFloat(DanTermConfig.default.resolvedFontSize)
) -> CGSize {
    pane.presentationGeometryForTesting?.cellSize ?? uiTestMetrics(fontSize: fontSize).cellSize
}

/// A window-space point a given fraction into one grid cell of `pane`.
///
/// `offsetY` defaults to the middle of the row, because no case is about the
/// sub-cell vertical position; the column offset is the one a selection boundary
/// depends on, so it stays explicit.
@MainActor
func paneCellPoint(
    column: Int,
    offsetX: CGFloat = 0,
    row: Int,
    offsetY: CGFloat = 0.5,
    in pane: SwiftTerminalSessionView
) -> NSPoint {
    let cell = paneCellSize(pane)
    return NSPoint(
        x: (CGFloat(column) + offsetX) * cell.width,
        y: pane.bounds.height - (CGFloat(row) + offsetY) * cell.height
    )
}
