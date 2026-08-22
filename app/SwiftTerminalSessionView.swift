// AppKit host for one Swift terminal session: geometry, drawing, text input,
// and the stable DanTerm TerminalSession boundary live here and nowhere else.
import Cocoa
import DanTermProtocol
// A leaf module with no engine dependency, so both the app build and the UI harness
// resolve it and the view can name one lifecycle vocabulary in either build.
import PaneProcessLifecycle
import TerminalCore
import TerminalCoreRecording
import TerminalPaneSession
// The pane tape's recorder value types -- cursors, spans, fenced captures -- are named here.
// This view is the adapter that lowers them into the portable stream vocabulary, and naming
// both sides is that adapter's job.
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning

/// The event payload every pane-tape value at the `TerminalSession` boundary carries.
///
/// An alias rather than an associated type: the session protocol is used existentially all
/// over the app. It lives in this file because this is the adapter that may name engine
/// types.
typealias PaneTapeSessionEvent = NeutralTerminalRecordingEvent

/// Restates the engine's live-capture provenance in the protocol's JSON vocabulary.
func paneTapeProvenanceJSON() throws -> JSONValue {
    let data = try JSONEncoder().encode(NeutralTerminalProvenance.liveCapture())
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

/// Lowers engine geometry into the support layer's stream dimensions, pinnedness included,
/// so the stream states the pane's geometry as the one fact the recorder holds.
func paneTapeDimensions(_ geometry: NeutralTerminalGeometry) -> PaneTapeDimensions {
    .init(columns: geometry.columns, rows: geometry.rows, pinned: geometry.pinned)
}

/// Lowers a recorder cursor into the support layer's stream cursor.
func paneTapeCursor(_ cursor: TerminalFlightRecordingCursor) -> PaneTapeCursor {
    .init(
        recorderLifetimeId: cursor.recorderLifetimeId,
        nextSequence: cursor.nextSequence,
        feedBytesBeforeNextSequence: cursor.feedBytesBeforeNextSequence,
        writeBytesBeforeNextSequence: cursor.writeBytesBeforeNextSequence
    )
}

/// Raises a stream cursor a client resumed from back into the recorder's own cursor.
func recorderCursor(_ cursor: PaneTapeCursor) -> TerminalFlightRecordingCursor {
    .init(
        recorderLifetimeId: cursor.recorderLifetimeId,
        nextSequence: cursor.nextSequence,
        feedBytesBeforeNextSequence: cursor.feedBytesBeforeNextSequence,
        writeBytesBeforeNextSequence: cursor.writeBytesBeforeNextSequence
    )
}

/// Names the recorded events a replica cannot replay without the source's whole history.
///
/// A primary-screen resize reflows retained history and the live rows as one stream, so a
/// replica missing the oldest rows would compute a different grid from the same event. Which
/// events read history is engine knowledge, so it is stated here, beside the engine vocabulary,
/// rather than rediscovered from the event's JSON downstream.
func paneTapeEventNeedsCompleteHistory(_ event: NeutralTerminalRecordingEvent) -> Bool {
    if case .resize = event { return true }
    return false
}

/// Lowers one fenced recorder suffix into the support layer's stream snapshot. Finite dumps
/// and follow batches both come through here, so neither can adapt an event differently.
func paneTapeSnapshot(
    _ snapshot: TerminalFlightRecordingCursorSnapshot
) -> PaneTapeSnapshot<PaneTapeSessionEvent> {
    PaneTapeSnapshot(
        events: snapshot.events.map { recorded in
            PaneTapeEvent(
                sequence: recorded.sequence,
                elapsedNanoseconds: recorded.elapsedNanoseconds,
                originElapsedNanoseconds: recorded.originElapsedNanoseconds,
                payload: recorded.payload.map {
                    .init(byteOffset: $0.byteOffset, byteLength: $0.byteLength)
                },
                event: recorded.event,
                needsCompleteHistory: paneTapeEventNeedsCompleteHistory(recorded.event)
            )
        },
        droppedEventCount: snapshot.droppedEventCount,
        droppedFeedBytes: snapshot.droppedFeedBytes,
        droppedWriteBytes: snapshot.droppedWriteBytes,
        nextCursor: paneTapeCursor(snapshot.nextCursor)
    )
}

/// Lowers one atomically fenced geometry-and-cursor pair into stream-policy values.
func paneTapeOrigin(_ origin: TerminalFlightRecordingOrigin) -> PaneTapeOrigin {
    .init(
        initial: paneTapeDimensions(origin.initial),
        cursor: paneTapeCursor(origin.cursor)
    )
}

/// Lowers the cheap half of one owner-fenced stream-policy input, without making the support
/// layer import engines. The fenced terminal stays behind in `fence.state`: only a decision
/// that selects a synchronization ever serializes it.
func paneTapeStreamFence(
    _ fence: TerminalFlightRecordingStreamFence
) -> PaneTapeStreamFence<PaneTapeSessionEvent> {
    let requested: PaneTapeCursorPlacement<PaneTapeSessionEvent>
    switch fence.requested {
    case .placed(let snapshot):
        requested = .placed(paneTapeSnapshot(snapshot))
    case .unplaceable:
        requested = .unplaceable
    }
    return PaneTapeStreamFence(
        origin: paneTapeOrigin(fence.origin),
        live: paneTapeOrigin(fence.live),
        retained: paneTapeSnapshot(fence.retained),
        requested: requested
    )
}

/// Serializes one fenced terminal for the requirement a stream decision raised, and lowers the
/// result into stream-policy values. This is the one place the app crosses from a decision into
/// terminal bytes, and it runs off the main actor and off the pane-owner queue.
func paneTapeStateSynchronization(
    _ state: TerminalFlightRecordingStatePairing,
    for requirement: PaneTapeSynchronizationRequirement
) -> PaneTapeStateSynchronization {
    let synchronization = state.resolve(
        historyBudgetBytes: requirement.historyBudgetBytes
    )
    return .init(
        // The one whole-payload copy on this path: the engine is Foundation-free and yields
        // `[UInt8]`, and from here down the payload lives in this single buffer.
        bytes: Data(synchronization.state.bytes),
        dimensions: paneTapeDimensions(synchronization.geometry),
        droppedHistoryRows: synchronization.state.droppedHistoryRows,
        focused: synchronization.focused,
        cursor: paneTapeCursor(synchronization.cursor)
    )
}

/// Lowers stored terminal facts from the engine vocabulary into the
/// session-owned reducer vocabulary; occurrence and view-only events stay outside it.
func sessionReport(for event: TerminalSemanticEvent) -> SessionReport? {
    switch event {
    case .title(let title):
        return .title(title)
    case .workingDirectory(let cwd):
        return .cwd(cwd)
    case .progress(let progress):
        return .progress(progress.map { state in
            switch state {
            case .set(let percent): .set(percent: percent)
            case .indeterminate: .indeterminate
            case .error(let percent): .error(percent: percent)
            case .pause(let percent): .pause(percent: percent)
            }
        })
    case .integrationReady:
        return .integrationReady
    case .commandStarted(let command):
        return .commandStarted(command)
    case .commandEnded(let exitStatus):
        return .commandEnded(exitStatus: exitStatus)
    case .connectionDeclared(let connection):
        switch connection {
        case .local:
            return .connectionDeclared(.local)
        case .remote(identity: nil):
            return .connectionDeclared(.remote(identity: nil))
        case .remote(identity: let identity?):
            return .connectionDeclared(.remote(identity: RemoteSession(
                user: identity.user,
                host: identity.host
            )))
        }
    case .bell, .desktopNotification:
        return nil
    }
}

/// Adapts one headless Swift terminal controller into DanTerm's AppKit pane contract.
final class SwiftTerminalSessionView: NSView, @MainActor NSTextInputClient, NSMenuItemValidation, TerminalSession {
    private let controller: any TerminalPaneSessionControlling
    /// The recorder behind this session, when there is one. A session with no
    /// recorder serves no pane tape, and every tape entry point answers nothing.
    private var tapeSource: (any TerminalPaneTapeSource)? { controller as? any TerminalPaneTapeSource }
    private let resolveTheme: (String) -> RenderTheme?
    private let callbackGate = TerminalSessionCallbackGate()
    private let wheelNormalizer = TerminalWheelNormalizer()
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var currentMetrics: TerminalRenderMetrics?
    /// The cell box in the pane's own coordinates: equal to the rendered cell box
    /// whenever the grid fits, smaller by the fit factor when a claimed grid is
    /// drawn down to its slot. Pointer mapping and positioned chrome read this,
    /// never `currentMetrics.cellSize`, which describes the pixels rendered.
    private var displayedCellSize: CGSize?
    private var currentDimensions: TerminalDimensions?
    /// The pinnedness last submitted with `currentDimensions`. Kept beside the grid rather
    /// than re-derived, so clearing an override back to the grid the pane already ran at
    /// still reads as a change and still reaches the applied boundary.
    private var currentGridPinned: Bool?
    /// Which `TerminalMouseButton` each physical button's outstanding press was reported
    /// as, entered only once that press actually reached the controller. A release is sent
    /// only for a press in here and names the button that press carried, so a press the
    /// view dropped -- the menu path never forwarded it, or no geometry was resolved yet --
    /// is never answered by a release the engine cannot pair, and letting go of Control
    /// mid-click cannot turn a `.right` press into a `.left` release.
    ///
    /// Keyed per physical button because AppKit can deliver a left press and a right press
    /// before either release, and one slot would let the second press overwrite the first.
    private var forwardedPressButtons: [PhysicalPointerButton: TerminalMouseButton] = [:]
    private var mouseTrackingArea: NSTrackingArea?
    private var lastPointerLocationInWindow: NSPoint?
    private var isPointerInside = false
    private var hoveredLink: TerminalHyperlink?
    private var linkPreview: LinkPreviewView?
    private var publishedFrame: (plan: RenderFramePlan, metrics: TerminalRenderMetrics)?
    /// The pane's display surface (research/33 T25): a rotation of
    /// IOSurface-backed frame stores the layer shows directly, so displaying a
    /// frame costs no full-frame copy. Nil until the first publish that has
    /// geometry, and replaced whole -- never reshaped -- whenever a
    /// presentation input moves.
    private var swapchain: (any TerminalPanePresentationSurface)?
    /// Builds each replacement rotation. Given rather than found, so a test can
    /// watch what the view presented without a second render path in production.
    private let makePresentationSurface: TerminalPanePresentationSurfaceFactory
    /// Resolves cell geometry for a font. Given rather than found, because the real
    /// answer depends on which faces are installed on the machine, and a pane's
    /// fallback behavior has to be provable without depending on that.
    private let makeMetrics: TerminalPaneMetricsFactory
    /// Retains the store the layer is showing, so replacing the swapchain
    /// cannot free the frame currently on screen before its successor renders.
    private var displayedStore: TerminalFrameBackingStore?
    /// True exactly while a pending-presentation retry is armed, so a publish
    /// and a retry cannot stack two timers for one pending plan.
    private var isPresentationRetryArmed = false
    private var lastEmittedState: TerminalSessionState?
    /// The two inputs reported terminal focus is derived from, retained separately so
    /// neither can overwrite the other: a terminal view keeps pane focus while DanTerm is
    /// inactive, and a pane created in a background tab never gains pane focus at all.
    private var paneFocused = false
    private var applicationActive: Bool
    private var lastForwardedFocus = false
    private var isTornDown = false
    /// Non-nil only when `DANTERM_FRAME_RATE_LOG` asked for live publish/draw rates.
    private let frameRateSampler = TerminalFrameRateSampler.make()
    /// Non-nil only when `DANTERM_DELIVERY_SHAPE_LOG` asked for lines-per-publish.
    private let deliveryShapeSampler = TerminalDeliveryShapeSampler.make()
    private var fontSize: CGFloat
    /// The verified-installed family to render, or nil for the system monospace
    /// font. Never a raw name from config -- only a resolved family reaches here.
    private var fontFamily: String?
    /// The grid a client claimed for this pane, or nil to derive the grid from the
    /// view's own bounds. Present, it is the pane's grid outright: no bound, scale,
    /// or font input can move it, so a claim survives every Mac layout event.
    private var gridOverride: PaneGridOverride?
    /// The claimed grid in the engine's own dimension type, so the presentation
    /// pass compares and submits one kind of value.
    private var overriddenDimensions: TerminalDimensions? {
        gridOverride.map { TerminalDimensions(columns: $0.columns, rows: $0.rows) }
    }

    /// The pane's clipboard in both directions -- explicit selection copies out and Edit > Paste
    /// in. Defaults to the system pasteboard while keeping UI tests isolated, so a test that
    /// assigns a scratch board neither reads nor destroys the developer's real clipboard.
    var selectionPasteboard = NSPasteboard.general
    /// Supplies the pane context menu without coupling this view to how its owner builds one.
    /// `PaneWrapperView` installs the shared builder; a harness installs its own.
    var paneMenuProvider: (() -> NSMenu?)?
    /// Defaults approved web links to the workspace while keeping UI tests free of external effects.
    var linkOpener: ((URL) -> Bool)? = { NSWorkspace.shared.open($0) }

    var hostView: NSView { self }
    var onEvent: ((TerminalSessionEvent) -> Void)? {
        get { callbackGate.onEvent }
        set { callbackGate.onEvent = newValue }
    }
    var currentAgentWaitGeneration: (() -> AgentWaitGeneration?)? {
        get { callbackGate.currentAgentWaitGeneration }
        set { callbackGate.currentAgentWaitGeneration = newValue }
    }
    var onPrimaryHistoryMutation: (() -> Void)? {
        get { controller.onPrimaryHistoryMutation }
        set { controller.onPrimaryHistoryMutation = newValue }
    }
    weak var stateObserver: (any TerminalSessionStateObserver)? {
        get { callbackGate.stateObserver }
        set { callbackGate.stateObserver = newValue }
    }
    var state: TerminalSessionState {
        let viewport = controller.viewportState
        let projection = viewport.projection
        return TerminalSessionState(
            scrollbarEnabled: viewport.isScrollbarEnabled,
            cellHeight: displayedCellSize?.height,
            scrollPosition: TerminalScrollPosition(
                total: UInt64(clamping: projection.totalRows),
                offset: UInt64(clamping: projection.topRow),
                length: UInt64(clamping: projection.windowRows)
            ),
            background: Self.cgColor(controller.renderTheme.defaultBackground)
        )
    }
    var hasSelection: Bool { controller.hasSelection }
    var publishedBackgroundForTesting: RenderColor? {
        publishedFrame?.plan.defaultBackground
    }
    /// PO5's three independent counters, read by the UI suite rather than by a
    /// live sampler: renders must never exceed publications, and an
    /// AppKit-initiated layer display must cause none at all.
    private(set) var publishCountForTesting = 0
    private(set) var renderCountForTesting = 0
    private(set) var layerDisplayCountForTesting = 0
    var hasPendingPresentationForTesting: Bool {
        swapchain?.hasPendingPresentation == true
    }

    /// The presentation geometry one grid resolved to: the scale its pixels are
    /// rendered at, the cell box those pixels occupy in the pane's own
    /// coordinates, and the pixel extent of the surface the whole grid renders
    /// into. Read by the harness to pin both rendering cases -- a grid that fits
    /// at the pane's own scale, and a claimed grid drawn down into its slot.
    var presentationGeometryForTesting: (
        renderScale: CGFloat,
        cellSize: CGSize,
        surfacePixelSize: CGSize
    )? {
        guard let metrics = currentMetrics,
              let cellSize = displayedCellSize,
              let dimensions = currentDimensions
        else { return nil }
        return (
            renderScale: metrics.displayScale,
            cellSize: cellSize,
            surfacePixelSize: CGSize(
                width: metrics.cellSize.width * metrics.displayScale
                    * CGFloat(dimensions.columns),
                height: metrics.cellSize.height * metrics.displayScale
                    * CGFloat(dimensions.rows)
            )
        )
    }

    func resetSurfaceCountersForTesting() {
        publishCountForTesting = 0
        renderCountForTesting = 0
        layerDisplayCountForTesting = 0
    }
    #if DANTERM_TERMINAL_BENCHMARK
    var benchmarkGeometry: TerminalBenchmarkGeometry? {
        guard let dimensions = currentDimensions, let metrics = currentMetrics else { return nil }
        return TerminalBenchmarkGeometry(
            columns: dimensions.columns,
            rows: dimensions.rows,
            cellWidth: metrics.cellSize.width,
            cellHeight: metrics.cellSize.height
        )
    }
    #endif
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// Installs the controller's sole end callback while preserving backend evidence
    /// work ahead of the app's close request and any resulting pane teardown.
    init(
        controller: any TerminalPaneSessionControlling,
        fontSize: Double = DanTermConfig.default.resolvedFontSize,
        fontFamily: String? = nil,
        gridOverride: PaneGridOverride? = nil,
        applicationActive: Bool = true,
        resolveTheme: @escaping (String) -> RenderTheme? = ThemeCatalog.shared.renderTheme(named:),
        makePresentationSurface: @escaping TerminalPanePresentationSurfaceFactory
            = liveTerminalPanePresentationSurface,
        makeMetrics: @escaping TerminalPaneMetricsFactory = liveTerminalPaneMetrics,
        onSessionEnded: ((PaneProcessLifecycleResult) -> Void)? = nil
    ) {
        self.controller = controller
        self.makePresentationSurface = makePresentationSurface
        self.makeMetrics = makeMetrics
        self.fontSize = CGFloat(fontSize)
        self.fontFamily = fontFamily
        self.applicationActive = applicationActive
        // Supplied at construction, not pushed after mount: the pane's first
        // presentation pass already submits a grid, and for a restored claimed
        // pane that grid has to be the claim itself.
        self.gridOverride = gridOverride
        self.resolveTheme = resolveTheme
        super.init(frame: .zero)
        wantsLayer = true
        // The grid surface is placed unscaled at the top-left corner, so the
        // letterbox strip a non-multiple pane size leaves shows the layer's own
        // background -- the theme default -- rather than a stretched frame.
        layerContentsPlacement = .topLeft
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // No implicit animation on a contents swap. An animation would keep the
        // replaced surface referenced by a presentation layer past the swap, and
        // the swapchain acquires a buffer on the premise that a detached surface
        // reported free stays free. This is the exact mechanism the real-AppKit
        // pin proves (`tests-ui/IOSurfaceLayerContentsTests.swift`).
        layer?.actions = ["contents": NSNull()]
        layer?.backgroundColor = Self.cgColor(controller.renderTheme.defaultBackground)
        registerForDraggedTypes([.fileURL, .URL, .string])
        #if DANTERM_TERMINAL_BENCHMARK
        TerminalBenchmarkObserver.shared?.attachFenceMetricsController(controller)
        #endif

        controller.displayRefreshIntervalNanoseconds = { [weak self] in
            self?.displayRefreshIntervalNanoseconds() ?? Self.assumedRefreshIntervalNanoseconds
        }
        controller.onFrame = { [weak self] frame in
            self?.publish(frame)
        }
        controller.onClipboardWrite = { [weak self] text in
            self?.writeClipboard(text)
        }
        controller.onSemanticEvents = { [weak self] events in
            self?.publish(events)
        }
        controller.onViewportStateChange = { [weak self] _ in
            self?.emitStateIfNeeded()
        }
        controller.onOpenLink = { [weak self] link in
            self?.openLink(link)
        }
        controller.onSearchStatus = { [weak self] status in
            self?.publish(status)
        }
        controller.onProcessStarted = { [weak self] in
            self?.callbackGate.emit(.processStarted)
        }
        controller.onSessionEnded = { [weak self] result in
            onSessionEnded?(result)
            switch result {
            case .exited:
                self?.callbackGate.emit(.processExited)
            case .launchFailed:
                self?.callbackGate.emit(.processLaunchFailed)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    isolated deinit {
        tearDown()
    }

    // MARK: - The owned pane surface

    /// Stands in until the view has a window to read a real display from.
    private static let assumedRefreshIntervalNanoseconds: UInt64 = 8_333_333

    /// Read live rather than cached: the publish deadline must track the pane's
    /// actual display (33/D8), and a window can move to a 60 Hz monitor without
    /// any backing-property change firing. It also paces the pending-presentation
    /// retry, which is why it is a method and not the controller's closure.
    private func displayRefreshIntervalNanoseconds() -> UInt64 {
        guard let framesPerSecond = window?.screen?.maximumFramesPerSecond,
              framesPerSecond > 0
        else { return Self.assumedRefreshIntervalNanoseconds }
        return 1_000_000_000 / UInt64(framesPerSecond)
    }

    /// Keeps AppKit from allocating a backing store or calling `draw(_:)` at
    /// all: the pane owns its pixels, and there is no second render path for a
    /// redisplay to fall back to.
    override var wantsUpdateLayer: Bool { true }

    /// The whole of what an AppKit-initiated redisplay may do (T25 I4): nothing.
    /// The buffer on screen is the last presented frame, and no invalidation
    /// AppKit can raise -- occlusion return, a fresh window, a sibling's
    /// relayout -- makes those pixels stale. Counted so a regression that
    /// reintroduced rendering here is visible as a number.
    override func updateLayer() {
        frameRateSampler?.recordLayerDisplay(
            deliveryCount: controller.fenceMetrics.delivery.count
        )
        layerDisplayCountForTesting += 1
    }

    /// Shows `store`'s surface directly, with no full-frame copy anywhere in
    /// the path (T25 I2). The layer's `actions` dictionary already refuses a
    /// contents animation; the transaction here covers `contentsScale`, which
    /// is animatable too and must land in the same commit as the surface it
    /// describes.
    private func attach(_ store: TerminalFrameBackingStore) {
        displayedStore = store
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The pane's own backing scale, not the store's. The two are the same for
        // every grid that fits its slot. A claimed grid that does not fit renders
        // at a smaller scale, and presenting those pixels at the pane's scale is
        // exactly what shows the whole grid, uniformly shrunk, inside the slot.
        layer?.contentsScale = window?.backingScaleFactor ?? store.metrics.displayScale
        layer?.contents = store.ioSurface
        CATransaction.commit()
    }

    /// The swapchain for these presentation inputs, replacing the live one
    /// whenever any of them moved. The outgoing buffers are not detached here:
    /// `displayedStore` keeps the frame on screen valid until its successor
    /// renders, exactly as the AppKit backing store used to.
    private func surfaceSwapchain(
        columns: Int,
        rows: Int,
        metrics: TerminalRenderMetrics
    ) -> (any TerminalPanePresentationSurface)? {
        let colorSpace = surfaceColorSpace
        // The live swapchain answers for its own inputs (research/33 T25 I3):
        // any inequality means the buffers on screen cannot be trusted, and the
        // answer to that is always a fresh swapchain, never a distrust bit.
        if let swapchain,
           swapchain.matches(
               columns: columns,
               rows: rows,
               metrics: metrics,
               colorSpace: colorSpace
           ) {
            return swapchain
        }
        swapchain = makePresentationSurface(columns, rows, metrics, colorSpace)
        return swapchain
    }

    /// The color space the pane's pixels are rendered in, which is the window's
    /// as `CGColorSpace` -- the domain that actually decides them. Comparing at
    /// this level rather than on `NSColorSpace` keeps two distinct objects over
    /// one CG space from forcing a pointless rebuild.
    private var surfaceColorSpace: CGColorSpace? {
        window?.colorSpace?.cgColorSpace
    }

    /// Drops the swapchain so the next presentation builds fresh buffers, for
    /// the trust-breaking input no value comparison can see: a theme change
    /// repaints every row, including rows this frame's damage does not name.
    private func discardSwapchain() {
        swapchain = nil
    }

    /// Presents one published frame. This is the single render path (T25 I4):
    /// paced shift, `.full` flood, first frame, resize and occlusion return all
    /// arrive here and nowhere else.
    private func present(
        plan: RenderFramePlan,
        damage: TerminalDamage,
        metrics: TerminalRenderMetrics
    ) {
        guard let swapchain = surfaceSwapchain(
            columns: plan.columns,
            rows: plan.rowCount,
            metrics: metrics
        ) else { return }
        presentAttempt(plan: plan, metrics: metrics, using: swapchain) {
            $0.publish(plan: plan, damage: damage)
        }
    }

    /// Re-renders the current plan in full, for the inputs that change a pane's
    /// pixels without a single terminal byte arriving: a backing-scale or
    /// color-space move, a font change, a theme swap, the benchmark observer's
    /// requested redraw.
    private func rerenderCurrentPlan() {
        guard let metrics = currentMetrics, let plan = controller.currentPlan else { return }
        publishedFrame = (plan, metrics)
        present(plan: plan, damage: .full, metrics: metrics)
    }

    /// One presentation attempt: render if the swapchain can acquire a buffer,
    /// show it, and arm the retry if the plan is still waiting. Publish and
    /// retry share it so the two cannot drift apart.
    private func presentAttempt(
        plan: RenderFramePlan,
        metrics: TerminalRenderMetrics,
        using swapchain: any TerminalPanePresentationSurface,
        attempt: (any TerminalPanePresentationSurface) -> TerminalFrameBackingStore?
    ) {
        #if DANTERM_TERMINAL_BENCHMARK
        let renderStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
        #endif
        if let store = attempt(swapchain) {
            frameRateSampler?.recordRender(
                deliveryCount: controller.fenceMetrics.delivery.count
            )
            renderCountForTesting += 1
            attach(store)
            #if DANTERM_TERMINAL_BENCHMARK
            let beginSurfaceConvergence = observeCompletedBenchmarkRender(
                plan: plan,
                metrics: metrics,
                startedAtNanoseconds: renderStartedNanoseconds,
                damage: swapchain.lastRenderedDamage ?? .full,
                allSurfaceBuffersCurrent:
                    swapchain.allBuffersHaveRenderedLatestWholeFrameDamage
            )
            if beginSurfaceConvergence {
                swapchain.requireEveryBufferToRenderAgain()
            }
            #endif
        }
        armPresentationRetryIfPending()
    }

    /// Arms the pending presentation's only driver: one retry per display
    /// refresh, without a display link and without waiting on further terminal
    /// output, so the last published plan reaches the screen even when the
    /// stream stops on it. Bounded by that pending plan (T25 I6) -- a pane with
    /// nothing pending arms nothing.
    private func armPresentationRetryIfPending() {
        guard isTornDown == false,
              isPresentationRetryArmed == false,
              swapchain?.hasPendingPresentation == true
        else { return }
        isPresentationRetryArmed = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(displayRefreshIntervalNanoseconds()))
        ) { [weak self] in
            self?.retryPendingPresentation()
        }
    }

    private func retryPendingPresentation() {
        isPresentationRetryArmed = false
        guard isTornDown == false,
              let swapchain,
              let frame = publishedFrame
        else { return }
        presentAttempt(plan: frame.plan, metrics: frame.metrics, using: swapchain) {
            $0.retryPendingPresentation()
        }
    }

    #if DANTERM_TERMINAL_BENCHMARK
    /// Reports one completed surface render. This is the bracket that used to
    /// sit inside `draw(_:)`, moved with the work it measures: it now contains
    /// the glyph rasterization CoreAnimation used to replay on its own queue
    /// after the draw returned, so the serialized-draw workloads' deciding
    /// metric changed meaning (`agent-docs/terminal-performance.md`).
    /// Returns true exactly once per block when the observer asks the owning
    /// view to make every swapchain buffer render past the block's start frame.
    private func observeCompletedBenchmarkRender(
        plan: RenderFramePlan,
        metrics: TerminalRenderMetrics,
        startedAtNanoseconds: UInt64,
        damage: TerminalDamage,
        allSurfaceBuffersCurrent: Bool
    ) -> Bool {
        let renderDurationNanoseconds =
            DispatchTime.now().uptimeNanoseconds - startedAtNanoseconds
        let renderedRect = NSRect(
            x: 0,
            y: 0,
            width: CGFloat(plan.columns) * metrics.cellSize.width,
            height: CGFloat(plan.rowCount) * metrics.cellSize.height
        )
        TerminalBenchmarkObserver.shared?.observeCompletedDraw(
            plan,
            dirtyRect: renderedRowBounds(damage, within: renderedRect, metrics: metrics),
            metrics: metrics,
            drawDurationNanoseconds: renderDurationNanoseconds,
            damage: damage,
            allSurfaceBuffersCurrent: allSurfaceBuffersCurrent
        )
        if TerminalBenchmarkObserver.shared?.needsPublishedRedraw == true {
            DispatchQueue.main.async { [weak self] in
                self?.rerenderCurrentPlan()
            }
        }
        return TerminalBenchmarkObserver.shared?.consumeSurfaceConvergenceRequest() == true
    }

    /// The rect the observer reads a dirty-row count from: the frame for a full
    /// render, otherwise the band spanning the rendered damage's first through
    /// last row. The observer selects full-redraw draws on that count, so it
    /// must describe the render, not the pane.
    private func renderedRowBounds(
        _ damage: TerminalDamage,
        within frameRect: NSRect,
        metrics: TerminalRenderMetrics
    ) -> NSRect {
        guard damage.isFull == false else { return frameRect }
        let spans = damage.maximalContiguousSpans()
        guard let first = spans.first, let last = spans.last else { return .zero }
        return NSRect(
            x: 0,
            y: CGFloat(first.lowerBound) * metrics.cellSize.height,
            width: frameRect.width,
            height: CGFloat(last.upperBound - first.lowerBound) * metrics.cellSize.height
        )
    }
    #endif

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // No invalidation to raise: the pane owns its pixels, so a resize can
        // neither discard them nor leave a clipped-away row showing bare layer
        // background. A grid resize republishes through the engine, and a
        // sub-cell resize only moves where the letterbox strip falls.
        synchronizePresentation()
    }

    override func layout() {
        super.layout()
        linkPreview?.layoutPill(in: bounds)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: hoveredLink == nil ? .arrow : .pointingHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizePresentation()
    }

    // Backing scale and window color space both arrive here, and a color-space
    // move at unchanged scale changes no metric at all.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        synchronizePresentation()
    }

    override func updateTrackingAreas() {
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        super.updateTrackingAreas()
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        mouseTrackingArea = trackingArea
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        // Presentation only. A responder gain is not a model fact: the pane-focus
        // pass moves the responder here itself, so a report would be a Msg out of a
        // reconcile sweep. The click that asks for focus reports it in `mouseDown`.
        if result { setPaneFocused(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setPaneFocused(false) }
        return result
    }

    override func scrollWheel(with event: NSEvent) {
        guard isTornDown == false, let cell = normalizedCell(for: event) else { return }
        let rows = wheelNormalizer.rows(
            delta: Self.verticalScrollDelta(for: event),
            isPrecise: event.hasPreciseScrollingDeltas,
            cellHeight: Double(displayedCellSize?.height ?? 0)
        )
        controller.sendWheel(
            .init(
                rowDelta: rows,
                column: cell.column,
                row: cell.row,
                modifiers: Self.terminalModifiers(event.modifierFlags),
                phase: Self.wheelPhase(for: event)
            ),
            origin: PaneInputOrigin.systemEvent(event),
            waitGeneration: originatedWaitGeneration
        )
    }

    override func mouseDown(with event: NSEvent) {
        // A control-click only arrives here when the terminal claimed it: an unclaimed one
        // is answered by `menu(for:)`, and AppKit then delivers no mouse lifecycle at all.
        forwardPointerDown(
            event,
            physical: .left,
            reportedAs: event.modifierFlags.contains(.control) ? .right : .left
        )
        // The focus report rides this entry point because AppKit's window moves the
        // responder here and nowhere else: a control-click still arrives as a left
        // press and still takes focus, while a genuine right or middle press moves
        // no responder and reports nothing. It goes last because the report re-enters
        // the model and its reconcile sweep synchronously; the press has already
        // reached the engine by then, so the sweep cannot land between this down and
        // the up that pairs with it. It is not gated on the forward, which drops a
        // press whose cell it cannot resolve -- a click still names its pane.
        callbackGate.emit(.clickedToFocus)
    }

    override func mouseUp(with event: NSEvent) {
        forwardPointerUp(event, physical: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Only a claimed right-click reaches the engine. An unclaimed one goes to super,
        // whose default implementation is what asks `menu(for:)` and pops the menu inside
        // this press; overriding it away would suppress the menu entirely.
        guard terminalClaimsRightButton(modifiers: event.modifierFlags) else {
            super.rightMouseDown(with: event)
            return
        }
        forwardPointerDown(event, physical: .right, reportedAs: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardPointerUp(event, physical: .right)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        forwardPointerDown(event, physical: .middle, reportedAs: .middle)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        forwardPointerUp(event, physical: .middle)
    }

    override func mouseMoved(with event: NSEvent) {
        forwardPointerMove(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        forwardPointerMove(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        lastPointerLocationInWindow = nil
        isPointerInside = false
        controller.cancelLinkInteraction()
        updateHoveredLinkChrome(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardPointerMove(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        forwardPointerMove(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        forwardPointerMove(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard event.keyCode == 0x37 || event.keyCode == 0x36,
              isPointerInside,
              let location = lastPointerLocationInWindow
        else {
            return
        }
        forwardPointerMove(
            at: location,
            modifiers: event.modifierFlags,
            origin: PaneInputOrigin.systemEvent(event)
        )
    }

    // NSView: AppKit calls this from the press -- inside the default `rightMouseDown` for a
    // right-click, and before any mouse lifecycle for a control-click -- and pops up whatever
    // is returned. Returning the menu here is what makes the pane menu open on press, at the
    // pointer, without the gesture ever leaving the main thread.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isTornDown == false else { return nil }
        switch event.type {
        case .rightMouseDown:
            guard terminalClaimsRightButton(modifiers: event.modifierFlags) == false else {
                return nil
            }
        case .leftMouseDown:
            guard event.modifierFlags.contains(.control),
                  terminalClaimsRightButton(modifiers: event.modifierFlags) == false
            else {
                return nil
            }
            // A control-click takes key focus but never reaches `mouseDown`, because AppKit
            // stops delivering the gesture once a menu is returned. Reporting focus here is
            // the only remaining chance to name the pane the user pointed at.
            callbackGate.emit(.clickedToFocus)
        default:
            return nil
        }
        return paneMenuProvider?()
    }

    /// Answers whether the terminal application, not the pane, owns this right-button press.
    /// Shift always overrides the claim, matching the local arm the engine's own pointer
    /// policy uses for every other button.
    private func terminalClaimsRightButton(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.shift) == false && controller.claimsMouseButtons
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) == false else { return }
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Every submission below reports the event's own occurrence time, not the clock now:
        // whatever delayed this handler is the app's, and stamping it here would hide that.
        let origin = PaneInputOrigin.systemEvent(event)
        // Read once for the whole event: every submission below is the same keystroke,
        // so they all answer the wait that was current when the key arrived.
        let waitGeneration = originatedWaitGeneration
        let markedTextBefore = hasMarkedText()
        interpretKeyEvents([event])
        if markedTextBefore == false, hasMarkedText() == false,
           Self.isKeypadKeyCode(event.keyCode), let key = Self.terminalKey(for: event) {
            controller.sendKey(
                key,
                modifiers: Self.terminalModifiers(event.modifierFlags),
                origin: origin,
                waitGeneration: waitGeneration
            )
            return
        }
        if let texts = keyTextAccumulator, texts.isEmpty == false,
           texts.allSatisfy(Self.isCommittedTerminalText) {
            for text in texts {
                controller.sendText(text, origin: origin, waitGeneration: waitGeneration)
            }
            return
        }
        guard markedTextBefore == false, hasMarkedText() == false else { return }
        guard let key = Self.terminalKey(for: event) else { return }
        controller.sendKey(
            key,
            modifiers: Self.terminalModifiers(event.modifierFlags),
            origin: origin,
            waitGeneration: waitGeneration
        )
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: value)
        case let value as String:
            markedText = NSMutableAttributedString(string: value)
        default:
            return
        }
    }

    func unmarkText() {
        markedText.mutableString.setString("")
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let viewRect = NSRect(x: 0, y: 0, width: 0, height: displayedCellSize?.height ?? 0)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let value as NSAttributedString: text = value.string
        case let value as String: text = value
        default: return
        }
        unmarkText()
        guard Self.isCommittedTerminalText(text) else { return }
        if var accumulator = keyTextAccumulator {
            accumulator.append(text)
            keyTextAccumulator = accumulator
        } else {
            // Reached outside a `keyDown`, so there is no system event whose time this text
            // is the product of; the app-entry stamp is the earliest moment it can claim.
            controller.sendText(
                text,
                origin: PaneInputOrigin.appEntry(),
                waitGeneration: originatedWaitGeneration
            )
        }
    }

    override func doCommand(by selector: Selector) {
        // Fixed terminal keys are encoded after interpretKeyEvents returns.
    }

    // TerminalSession: the one runtime input seam keeps paste safety distinct from raw text,
    // then routes each meaning through the matching engine operation.
    func submitInput(
        _ input: PaneInputItem,
        waitGeneration: AgentWaitGeneration?,
        onCompletion: @escaping @MainActor @Sendable (TerminalInputSubmissionResult) -> Void
    ) {
        let origin = PaneInputOrigin.appEntry()
        let waitGeneration = Self.paneWaitGeneration(waitGeneration)
        let completion: @MainActor @Sendable (PaneInputSubmissionResult) -> Void = {
            onCompletion(Self.inputResult($0))
        }
        switch input {
        case .paste(let text):
            controller.sendPaste(
                text,
                origin: origin,
                waitGeneration: waitGeneration,
                onCompletion: completion
            )
        case .text(let text):
            controller.sendText(
                text,
                origin: origin,
                waitGeneration: waitGeneration,
                onCompletion: completion
            )
        case .key(let key, let modifiers):
            controller.sendKey(
                Self.terminalKey(for: key),
                modifiers: Self.terminalModifiers(modifiers),
                origin: origin,
                waitGeneration: waitGeneration,
                onCompletion: completion
            )
        case .wheel(let direction, let column, let row):
            controller.sendWheel(
                Self.terminalWheelEvent(direction, column: column, row: row),
                origin: origin,
                waitGeneration: waitGeneration,
                onCompletion: completion
            )
        }
    }

    private static func terminalWheelEvent(
        _ direction: InputWheelDirection,
        column: Int,
        row: Int
    ) -> TerminalWheelEvent {
        let rowDelta: Double = switch direction {
        case .up: -1
        case .down: 1
        }
        return TerminalWheelEvent(
            rowDelta: rowDelta,
            column: column,
            row: row
        )
    }

    /// The wait to stamp on input this view originates itself. Read at the submission,
    /// never cached: a wait admitted a moment ago must be the one the next keystroke ends.
    private var originatedWaitGeneration: PaneInputWaitGeneration? {
        Self.paneWaitGeneration(callbackGate.agentWaitGeneration())
    }

    /// Restates a model wait generation in the input owner's opaque form, and the owner's
    /// form back again. The two types stay distinct because neither layer may read the
    /// other's meaning; this view is the seam that carries the value across.
    private static func paneWaitGeneration(
        _ generation: AgentWaitGeneration?
    ) -> PaneInputWaitGeneration? {
        generation.map { PaneInputWaitGeneration(rawValue: $0.rawValue) }
    }

    private static func agentWaitGeneration(
        _ generation: PaneInputWaitGeneration?
    ) -> AgentWaitGeneration? {
        generation.map { AgentWaitGeneration(rawValue: $0.rawValue) }
    }

    private static func inputResult(
        _ result: PaneInputSubmissionResult
    ) -> TerminalInputSubmissionResult {
        switch result {
        case .delivered: .delivered
        case .rejected(.bufferLimitExceeded): .rejected(.bufferLimitExceeded)
        case .rejected(.canonicalModeTimeout): .rejected(.canonicalModeTimeout)
        case .rejected(.launchFailed): .rejected(.launchFailed)
        case .rejected(.processEnded): .rejected(.processEnded)
        case .rejected(.writeFailed(let code)): .rejected(.writeFailed(code))
        }
    }

    func setFocused(_ focused: Bool) {
        setPaneFocused(focused)
    }

    func setApplicationActive(_ active: Bool) {
        applicationActive = active
        forwardEffectiveFocus()
    }

    func setVisible(_ visible: Bool) {
        controller.setVisible(visible)
    }

    func setRenderingAvailable(_ available: Bool) {
        controller.setRenderingAvailable(available)
    }

    func refreshPresentation() {
        synchronizePresentation()
    }

    func applyTheme(_ themeName: String) {
        applyResolvedTheme(resolveTheme(themeName) ?? .dark)
    }

    func clearTheme() {
        applyResolvedTheme(.dark)
    }

    func setFontSize(_ size: Double) {
        guard size.isFinite, size > 0, CGFloat(size) != fontSize else { return }
        fontSize = CGFloat(size)
        synchronizePresentation()
    }

    func setFontFamily(_ family: String?) {
        guard family != fontFamily else { return }
        fontFamily = family
        synchronizePresentation()
    }

    /// Claims the pane's grid, or hands it back to the pane's rectangle with nil.
    /// The model is the only writer, so both directions arrive here through the
    /// per-pane config reconcile and nothing else.
    func setGridOverride(_ grid: PaneGridOverride?) {
        guard grid != gridOverride else { return }
        gridOverride = grid
        synchronizePresentation()
    }

    /// Installing the handler is the whole gate: with it absent the engine never extracts
    /// a completed selection's text, so the option being off costs the pointer path nothing.
    /// The text arrives already captured at the gesture's completion and is written as
    /// handed -- re-reading the selection here would race output that landed since.
    func setCopyOnSelect(_ enabled: Bool) {
        controller.onSelectionCopy = enabled
            ? { [weak self] text in self?.writeClipboard(text) }
            : nil
    }

    func setSearchNeedle(_ needle: String) {
        // An empty needle is "no search", not a search for nothing -- clearing also
        // drops the active-match highlight.
        if needle.isEmpty {
            controller.clearSearch()
        } else {
            controller.beginSearch(needle)
        }
    }

    func navigateSearch(_ direction: SearchDirection) {
        switch direction {
        case .next: controller.searchNext()
        case .previous: controller.searchPrevious()
        }
    }

    func endSearch() {
        controller.clearSearch()
    }

    func readViewportText() -> String? {
        controller.synchronizeState()
        return controller.readViewportText()
    }

    func readRowStructure() -> [TerminalSessionRowStructure]? {
        controller.synchronizeState()
        return controller.readRowStructure().map { row in
            let marginKind: String
            switch row.marginCellKind {
            case .padding: marginKind = "padding"
            case .narrow: marginKind = "narrow"
            case .wideHead: marginKind = "wideHead"
            case .wideTail: marginKind = "wideTail"
            case .spacerHead: marginKind = "spacerHead"
            }
            return TerminalSessionRowStructure(
                index: row.index,
                isRetained: row.isRetained,
                isSoftWrapped: row.isSoftWrapped,
                contentEnd: row.contentEnd,
                width: row.width,
                marginKind: marginKind,
                staleWrapClaim: row.staleWrapClaim
            )
        }
    }

    func readFullHistoryText() -> String? {
        controller.synchronizeState()
        return controller.readFullHistoryText()
    }

    func readPrimaryHistoryText() -> String? {
        controller.synchronizeState()
        return controller.readPrimaryHistoryText()
    }

    func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String? {
        controller.synchronizeState()
        return controller.readPrimaryHistoryTail(maxLines: maxLines, maxChars: maxChars)
    }

    func primaryHistoryTailReader() -> CheckpointScrollbackRead? {
        // Synchronizing has to happen here, on the main actor, so the copy the reader closes
        // over includes everything the session has accepted; projecting it does not.
        controller.synchronizeState()
        let read = controller.primaryHistoryTailReader()
        return { retention in read(retention.maxLines, retention.maxChars) }
    }

    func paneTapeOpening(
        capture: PaneTapeCaptureMode,
        start: PaneTapeStartPosition,
        policy: PaneTapeSyncPolicy
    ) -> (@Sendable () throws -> PaneTapeOpening<PaneTapeSessionEvent>)? {
        guard let tapeSource else { return nil }
        let requestedCursor: PaneTapeCursor
        switch start {
        case .cursor(let cursor): requestedCursor = cursor
        case .beginning, .now: requestedCursor = .beginning
        }
        let fence = tapeSource.flightRecordingStreamFence(from: recorderCursor(requestedCursor))
        return {
            let decision = decidePaneTapeOpening(
                request: PaneTapeStreamRequest(capture: capture, policy: policy, position: start),
                fence: paneTapeStreamFence(fence)
            )
            let provenance = try paneTapeProvenanceJSON()
            switch decision.payload {
            case .events(let events):
                return makePaneTapeOpening(decision, events: events, provenance: provenance)
            case .synchronize(let requirement):
                return makePaneTapeOpening(
                    decision,
                    requirement: requirement,
                    synchronization: paneTapeStateSynchronization(fence.state, for: requirement),
                    provenance: provenance
                )
            }
        }
    }

    func paneTapeFollowBatch(
        subscriptionId: UUID,
        from cursor: PaneTapeCursor,
        policy: PaneTapeSyncPolicy,
        replicaHistoryIsComplete: Bool
    ) -> (@Sendable () -> PaneTapeContinuation<PaneTapeSessionEvent>)? {
        guard let tapeSource, let fence = tapeSource.flightRecordingFollowStreamFence(
            subscriptionId: subscriptionId,
            from: recorderCursor(cursor)
        ) else {
            return nil
        }
        return {
            let decision = decidePaneTapeContinuation(
                policy: policy,
                replicaHistoryIsComplete: replicaHistoryIsComplete,
                snapshot: paneTapeSnapshot(fence.snapshot)
            )
            switch decision {
            case .events(let events):
                return makePaneTapeContinuation(events: events)
            case .synchronize(let requirement):
                return makePaneTapeContinuation(
                    requirement: requirement,
                    synchronization: paneTapeStateSynchronization(fence.state, for: requirement)
                )
            }
        }
    }

    func addPaneTapeFollowNotice(
        id: UUID,
        cursor: PaneTapeCursor,
        notify: @escaping @Sendable () -> Void
    ) -> PaneTapeFollowNoticeRegistration? {
        guard let tapeSource else { return nil }
        tapeSource.addFlightRecordingFollowNotice(
            id: id,
            from: recorderCursor(cursor),
            notify: notify
        )
        return PaneTapeFollowNoticeRegistration {
            tapeSource.removeFlightRecordingFollowNotice(id: id)
        }
    }

    func scroll(toRow row: Int) {
        controller.scroll(toTopRow: row)
    }
    func copySelection() {
        guard let text = controller.readSelectedTextSynchronizing() else { return }
        writeClipboard(text)
    }

    private func writeClipboard(_ text: String) {
        selectionPasteboard.clearContents()
        selectionPasteboard.setString(text, forType: .string)
    }

    /// NSResponder: routes the standard Edit > Copy action, which is what gives the pane Cmd-C.
    /// `keyDown` deliberately drops Command-modified keys, so this responder-chain method is the
    /// only owner of the shortcut in the Swift engine.
    @objc func copy(_ sender: Any?) {
        copySelection()
    }

    /// NSResponder: routes the standard Edit > Select All action, which is what gives the pane
    /// Cmd-A. `keyDown` drops Command-modified keys, so this override is the sole owner of the
    /// shortcut; the enqueued whole-stream selection lets the existing Copy path copy scrollback.
    override func selectAll(_ sender: Any?) {
        controller.selectAll()
    }

    /// NSMenuItemValidation: greys out Edit > Copy when nothing is selected. Reads the cache-only
    /// `hasSelection` rather than fencing, because menu tracking must not block on the render
    /// owner; every other action is left enabled so unrelated items keep their own validation.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copy(_:)) else { return true }
        return hasSelection
    }

    /// NSResponder: routes the standard Edit > Paste action through terminal paste policy.
    @objc func paste(_ sender: Any?) {
        pasteClipboard()
    }

    func pasteClipboard() {
        guard let text = selectionPasteboard.string(forType: .string) else { return }
        controller.sendPaste(
            text,
            origin: PaneInputOrigin.appEntry(),
            waitGeneration: originatedWaitGeneration
        )
    }

    func requestClose() {
        callbackGate.emit(.closeRequested)
    }

    func fenceForApplicationExit() {
        controller.fenceForApplicationExit()
        #if DANTERM_TERMINAL_BENCHMARK
        TerminalBenchmarkObserver.shared?.observeApplicationExitFence(for: controller)
        #endif
    }

    func tearDown() {
        guard isTornDown == false else { return }
        isTornDown = true
        paneMenuProvider = nil
        linkOpener = nil
        isPointerInside = false
        updateHoveredLinkChrome(nil)
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
            self.mouseTrackingArea = nil
        }
        callbackGate.tearDown()
        frameRateSampler?.flush(deliveryCount: controller.fenceMetrics.delivery.count)
        deliveryShapeSampler?.flush(deliveryCount: controller.fenceMetrics.delivery.count)
        #if DANTERM_TERMINAL_BENCHMARK
        TerminalBenchmarkObserver.shared?.detachFenceMetricsController(controller)
        #endif
        controller.tearDown()
    }

    private func publish(_ events: [PaneSemanticEvent]) {
        for event in events {
            switch event {
            case .terminal(let terminalEvent):
                publish(terminalEvent)
            case .userInputDelivered(let generation):
                callbackGate.emit(.report(.userInputDelivered(
                    waitGeneration: Self.agentWaitGeneration(generation)
                )))
            }
        }
    }

    private func publish(_ event: TerminalSemanticEvent) {
        #if DANTERM_TERMINAL_BENCHMARK
        if case .title(let title) = event {
            TerminalBenchmarkObserver.shared?.observeTitle(title)
        }
        #endif
        if let report = sessionReport(for: event) {
            callbackGate.emit(.report(report))
            return
        }
        switch event {
        case .title, .workingDirectory, .progress, .integrationReady, .commandStarted,
             .commandEnded, .connectionDeclared:
            return
        case .bell:
            callbackGate.emit(.bell)
        case let .desktopNotification(title, body):
            callbackGate.emit(.desktopNotification(title: title, body: body))
        }
    }

    /// Maps the engine's total search status onto the overlay's two independently
    /// nullable counter fields: no search reads `--/--`, a needle that matches
    /// nothing reads `-/0`, and a live match reads `selected + 1`/`total`.
    private func publish(_ status: TerminalSearchStatus?) {
        switch status {
        case nil:
            callbackGate.emit(.searchTotal(nil))
            callbackGate.emit(.searchSelected(nil))
        case .empty:
            callbackGate.emit(.searchTotal(0))
            callbackGate.emit(.searchSelected(nil))
        case let .matched(selected, total):
            callbackGate.emit(.searchTotal(total))
            callbackGate.emit(.searchSelected(selected))
        }
    }

    /// The view's only presentation-input detector, and the only place that decides
    /// whether the buffers on screen can still be trusted (research/33 T25 I3).
    /// Every entry point that can move an input arrives here -- resize, window
    /// mount, backing properties, font size, font family, the claimed grid
    /// override, and the runtime's screen-change refresh -- so none of them can
    /// re-render on a narrower test than the one the swapchain answers.
    ///
    /// A claimed override is the grid outright, so the bounds conversion below is
    /// never even evaluated while one is present. That is what makes every
    /// rectangle input inert for a claimed pane: the grid it computes to is the
    /// one already submitted, so nothing reaches the controller or the PTY.
    ///
    /// The bail below is the display-scaling invariant, not a defensive check
    /// (docs/design/2026-03-05-display-scaling.md): a zero-area surface, an absent
    /// window, unusable metrics, or refused grid dimensions leave no geometry to
    /// derive, so the pane keeps the frame and grid it already has.
    private func synchronizePresentation() {
        guard isTornDown == false,
              bounds.width > 0, bounds.height > 0,
              let scale = window?.backingScaleFactor,
              let nativeMetrics = resolvedMetrics(displayScale: scale),
              let dimensions = overriddenDimensions ?? terminalGridDimensions(
                  size: .init(width: Double(bounds.width), height: Double(bounds.height)),
                  cellSize: .init(
                      width: Double(nativeMetrics.cellSize.width),
                      height: Double(nativeMetrics.cellSize.height)
                  )
              ),
              let metrics = fittedMetrics(
                  for: dimensions,
                  native: nativeMetrics,
                  displayScale: scale
              )
        else {
            return
        }

        let pinned = gridOverride != nil
        let metricsChanged = metrics != currentMetrics
        let geometryChanged = dimensions != currentDimensions || pinned != currentGridPinned
        currentMetrics = metrics
        currentDimensions = dimensions
        currentGridPinned = pinned
        // What one cell occupies on screen, which is the rendered cell box carried
        // back to the pane's own scale. Every pointer mapping and every piece of
        // chrome the view positions reads this rather than the render metrics, so
        // a shrunk grid is hit-tested at the size the user sees.
        displayedCellSize = CGSize(
            width: metrics.cellSize.width * metrics.displayScale / scale,
            height: metrics.cellSize.height * metrics.displayScale / scale
        )
        if geometryChanged {
            controller.setGridDimensions(dimensions, pinned: pinned)
        }
        // Cell height is the only state-channel field this method moves -- the
        // viewport projection arrives on the controller's own state callback. An
        // unconditional emit would read the viewport once per frame of a divider
        // drag, since `setFrameSize` fires throughout one, for no observable gain.
        if metricsChanged {
            emitStateIfNeeded()
        }

        // No publish need follow a moved input: a scale, cell-geometry, or
        // color-space change leaves the terminal's content untouched, so the view
        // re-renders the current plan itself. The layer's contents scale rides the
        // surface it shows, set in `attach`, so nothing is set here.
        //
        // The geometry-free `matches` is deliberate rather than an omission: a
        // grid resize republishes through `controller.setGridDimensions`, so
        // presenting the *old* plan under the *new* shape would render a stale
        // frame and build buffers the next publish immediately replaces. The
        // swapchain keys its identity on its geometry; this test does not.
        //
        // With no live swapchain the current plan has never reached the screen, so
        // it always renders. A swapchain that keeps failing to allocate therefore
        // retries on every entry, which is the right response to that state.
        guard let swapchain else {
            rerenderCurrentPlan()
            return
        }
        guard swapchain.matches(metrics: metrics, colorSpace: surfaceColorSpace) == false else {
            return
        }
        rerenderCurrentPlan()
    }

    /// The metrics one grid renders at inside the pane's current rectangle.
    ///
    /// A grid that fits resolves to the pane's own backing scale, so an unclaimed
    /// pane -- whose grid is derived from that rectangle and therefore always fits
    /// -- is untouched by this. A claimed grid too large for its slot resolves to
    /// a smaller scale, and the surface it renders into is smaller in the same
    /// proportion: the shrink happens while drawing, so nothing is ever allocated
    /// at the claimed grid's own pixel extent.
    ///
    /// The scale itself comes from `fittedRenderScale`, which is the one definition
    /// of this arithmetic: the phone bounds its own frame stores with the same rule,
    /// and a second copy of it would let the two ends drift apart.
    private func fittedMetrics(
        for dimensions: TerminalDimensions,
        native: TerminalRenderMetrics,
        displayScale: CGFloat
    ) -> TerminalRenderMetrics? {
        // A grid so large that a cell cannot have one whole pixel on some axis has
        // no presentable geometry at all, and the pane keeps the frame it has --
        // the same answer this method's callers give every other unusable input.
        guard let scale = fittedRenderScale(
            columns: dimensions.columns,
            rows: dimensions.rows,
            widthPixels: Int((bounds.width * displayScale).rounded(.down)),
            heightPixels: Int((bounds.height * displayScale).rounded(.down)),
            nativeCellSize: native.cellSize,
            nativeDisplayScale: displayScale
        ) else { return nil }
        guard scale < displayScale else { return native }
        return resolvedMetrics(displayScale: scale)
    }

    /// Metrics for the configured family, falling back to the system monospace font
    /// so an unusable face never leaves a terminal blank or frozen.
    ///
    /// Passing the availability probe does not guarantee usable grid geometry -- a
    /// face can be installed and still lack the nominal `M` glyph the cell box is
    /// derived from. Without this retry `synchronizePresentation` would bail, leaving a
    /// new pane with no geometry and an existing pane frozen on its old grid.
    private func resolvedMetrics(displayScale: CGFloat) -> TerminalRenderMetrics? {
        if let fontFamily,
           let metrics = makeMetrics(displayScale, fontSize, fontFamily)
        {
            return metrics
        }
        return makeMetrics(displayScale, fontSize, nil)
    }

    /// A theme change repaints every row, including rows no damage will name,
    /// so the buffers rendered under the old theme cannot be trusted and the
    /// swapchain goes with it. Discarding before the controller sees the theme
    /// matters: `setTheme` republishes synchronously on a visible pane, and
    /// that publish should land in the fresh buffers rather than in buffers
    /// this method is about to throw away. A swapchain still absent afterwards
    /// means no publish followed, so the view renders the frame itself.
    private func applyResolvedTheme(_ theme: RenderTheme) {
        layer?.backgroundColor = Self.cgColor(theme.defaultBackground)
        discardSwapchain()
        controller.setTheme(theme)
        if swapchain == nil { rerenderCurrentPlan() }
        // The pane's focus-ring gutter takes its color off the state channel, so
        // a theme swap has to publish even though it moves no scrollbar value.
        emitStateIfNeeded()
    }

    private func emitStateIfNeeded() {
        guard isTornDown == false else { return }
        let state = state
        guard state != lastEmittedState else { return }
        lastEmittedState = state
        callbackGate.emit(state)
    }

    private func publish(_ frame: TerminalPaneFrame) {
        guard isTornDown == false else { return }
        // Insideness is re-derived here rather than reused from the last pointer event: the
        // grid can shrink out from under a parked pointer, and a stored bit would keep
        // showing hover chrome for a cell that is no longer on the grid.
        let hoveredLink = isPointerInside ? lastPointerLocationInWindow.flatMap { location in
            normalizedCell(at: location)?.isInsideGrid == true ? controller.readHoveredLink() : nil
        } : nil
        updateHoveredLinkChrome(hoveredLink)
        guard let metrics = currentMetrics else { return }
        #if DANTERM_TERMINAL_CHARACTERIZATION
        recordTerminalCharacterizationPlanDelivery()
        #endif
        #if DANTERM_TERMINAL_BENCHMARK
        TerminalBenchmarkObserver.shared?.observePublishedFrame(
            frame.plan,
            damage: frame.damage,
            planDurationNanoseconds: controller.lastPlanDurationNanoseconds,
            planThreadCPUNanoseconds: controller.lastPlanThreadCPUNanoseconds,
            fenceStallNanoseconds: controller.lastFenceStallNanoseconds
        )
        #endif
        frameRateSampler?.recordPublish(deliveryCount: controller.fenceMetrics.delivery.count)
        deliveryShapeSampler?.recordPublish(
            absoluteViewportTopRow: controller.absoluteViewportTopRow,
            isFullDamage: frame.damage.isFull,
            damagedRowCount: frame.damage.damagedRowCount,
            deliveryCount: controller.fenceMetrics.delivery.count,
            gridRows: frame.plan.rowCount
        )
        publishCountForTesting += 1
        publishedFrame = (frame.plan, metrics)
        // No invalidation and no damage bookkeeping: the publish either renders
        // into a buffer and shows it, or coalesces into the pending
        // presentation. There is no second consumer of this damage.
        present(plan: frame.plan, damage: frame.damage, metrics: metrics)
    }

    private func setPaneFocused(_ focused: Bool) {
        paneFocused = focused
        forwardEffectiveFocus()
    }

    /// Sends the conjunction of the two retained inputs, and only when it moves. The
    /// terminal retains what it is told whether or not the child asked for reports, so a
    /// value it already holds must not be sent again.
    private func forwardEffectiveFocus() {
        let focused = paneFocused && applicationActive
        guard isTornDown == false, focused != lastForwardedFocus else { return }
        lastForwardedFocus = focused
        // Responder changes reach here from several AppKit callbacks with no event in hand, so
        // the pane entry is the earliest moment a focus report can honestly claim.
        controller.sendFocus(focused, origin: PaneInputOrigin.appEntry())
    }

    private func normalizedCell(for event: NSEvent) -> TerminalViewportCell? {
        normalizedCell(at: event.locationInWindow)
    }

    private func normalizedCell(at locationInWindow: NSPoint) -> TerminalViewportCell? {
        guard let cellSize = displayedCellSize, let dimensions = currentDimensions else { return nil }
        let point = convert(locationInWindow, from: nil)
        return terminalCell(
            at: .init(x: Double(point.x), y: Double(point.y)),
            cellSize: .init(
                width: Double(cellSize.width),
                height: Double(cellSize.height)
            ),
            columns: dimensions.columns,
            rows: dimensions.rows
        )
    }

    /// The button the user physically pressed, which is not what the press is reported as:
    /// a control-click enters through `.left` and is reported to the engine as `.right`.
    /// Pairing a release with its press needs the physical identity, because that is what
    /// AppKit's entry points distinguish.
    private enum PhysicalPointerButton {
        case left
        case right
        case middle
    }

    private func forwardPointerDown(
        _ event: NSEvent,
        physical: PhysicalPointerButton,
        reportedAs button: TerminalMouseButton
    ) {
        guard isTornDown == false, let cell = normalizedCell(for: event) else { return }
        lastPointerLocationInWindow = event.locationInWindow
        isPointerInside = cell.isInsideGrid
        forwardedPressButtons[physical] = button
        controller.sendPointer(
            .down(
                button,
                cell: cell,
                modifiers: Self.terminalModifiers(event.modifierFlags),
                clickCount: event.clickCount
            ),
            origin: PaneInputOrigin.systemEvent(event),
            waitGeneration: originatedWaitGeneration
        )
    }

    private func forwardPointerUp(_ event: NSEvent, physical: PhysicalPointerButton) {
        guard let button = forwardedPressButtons.removeValue(forKey: physical) else { return }
        guard isTornDown == false, let cell = normalizedCell(for: event) else { return }
        lastPointerLocationInWindow = event.locationInWindow
        if cell.isInsideGrid == false {
            isPointerInside = false
        }
        controller.sendPointer(
            .up(
                button,
                cell: cell,
                modifiers: Self.terminalModifiers(event.modifierFlags)
            ),
            origin: PaneInputOrigin.systemEvent(event),
            waitGeneration: originatedWaitGeneration
        )
    }

    private func forwardPointerMove(_ event: NSEvent) {
        lastPointerLocationInWindow = event.locationInWindow
        let cell = normalizedCell(for: event)
        // A pointer over unusable geometry names no cell, and the pane cannot claim it is
        // inside a grid it cannot measure.
        isPointerInside = cell?.isInsideGrid ?? false
        guard isTornDown == false, let cell else { return }
        deliverPointerMove(
            cell,
            modifiers: event.modifierFlags,
            origin: PaneInputOrigin.systemEvent(event)
        )
    }

    /// Replays the parked pointer for a caller that has no event of its own -- `flagsChanged`
    /// -- which deliberately leaves `isPointerInside` where the last real event put it.
    private func forwardPointerMove(
        at locationInWindow: NSPoint,
        modifiers: NSEvent.ModifierFlags,
        origin: UInt64
    ) {
        guard isTornDown == false, let cell = normalizedCell(at: locationInWindow) else { return }
        deliverPointerMove(cell, modifiers: modifiers, origin: origin)
    }

    private func deliverPointerMove(
        _ cell: TerminalViewportCell,
        modifiers: NSEvent.ModifierFlags,
        origin: UInt64
    ) {
        controller.sendPointer(
            .move(cell: cell, modifiers: Self.terminalModifiers(modifiers)),
            origin: origin,
            waitGeneration: originatedWaitGeneration
        )
    }

    private func openLink(_ link: TerminalHyperlink) {
        guard isTornDown == false,
              let url = openableWebURL(link.uri)
        else {
            return
        }
        _ = linkOpener?(url)
    }

    private func updateHoveredLinkChrome(_ link: TerminalHyperlink?) {
        if link == hoveredLink {
            if link != nil, let location = lastPointerLocationInWindow {
                linkPreview?.pointerMoved(to: convert(location, from: nil), in: bounds)
            }
            return
        }
        hoveredLink = link
        window?.invalidateCursorRects(for: self)
        guard let link else {
            linkPreview?.hide()
            NSCursor.arrow.set()
            return
        }

        let preview = ensureLinkPreview()
        preview.show(url: link.uri)
        preview.layoutPill(in: bounds)
        if let location = lastPointerLocationInWindow {
            preview.pointerMoved(to: convert(location, from: nil), in: bounds)
        }
        NSCursor.pointingHand.set()
    }

    private func ensureLinkPreview() -> LinkPreviewView {
        if let linkPreview { return linkPreview }
        let preview = LinkPreviewView()
        addSubview(preview)
        linkPreview = preview
        return preview
    }

    private static func wheelPhase(for event: NSEvent) -> TerminalWheelPhase {
        if event.momentumPhase.contains(.began) { return .momentumBegan }
        if event.momentumPhase.contains(.changed) { return .momentumChanged }
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            return .momentumEnded
        }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.changed) { return .changed }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .ended }
        return .standalone
    }

    private static func verticalScrollDelta(for event: NSEvent) -> Double {
        let vertical = Double(event.scrollingDeltaY)
        // AppKit projects Shift-wheel line ticks onto the horizontal axis before dispatch.
        if event.modifierFlags.contains(.shift), vertical == 0 {
            return Double(event.scrollingDeltaX)
        }
        return vertical
    }

    private static func cgColor(_ color: RenderColor) -> CGColor {
        CGColor(
            red: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }

    private static func isCommittedTerminalText(_ text: String) -> Bool {
        guard text.isEmpty == false else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    private static func terminalKey(for event: NSEvent) -> TerminalInputKey? {
        switch event.keyCode {
        case 36: return .returnKey
        case 48: return .tab
        case 51: return .backspace
        case 53: return .escape
        case 126: return .up
        case 125: return .down
        case 124: return .right
        case 123: return .left
        case 115: return .home
        case 119: return .end
        case 114: return .insert
        case 116: return .pageUp
        case 121: return .pageDown
        case 117: return .deleteForward
        case 122: return .f1
        case 120: return .f2
        case 99: return .f3
        case 118: return .f4
        case 96: return .f5
        case 97: return .f6
        case 98: return .f7
        case 100: return .f8
        case 101: return .f9
        case 109: return .f10
        case 103: return .f11
        case 111: return .f12
        case 82: return .keypad0
        case 83: return .keypad1
        case 84: return .keypad2
        case 85: return .keypad3
        case 86: return .keypad4
        case 87: return .keypad5
        case 88: return .keypad6
        case 89: return .keypad7
        case 91: return .keypad8
        case 92: return .keypad9
        case 65: return .keypadDecimal
        case 75: return .keypadDivide
        case 67: return .keypadMultiply
        case 78: return .keypadSubtract
        case 69: return .keypadAdd
        case 76: return .keypadEnter
        case 81: return .keypadEqual
        default:
            guard event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option),
                  let text = event.characters(
                      byApplyingModifiers: event.modifierFlags.intersection(.shift)
                  )?.lowercased(),
                  text.unicodeScalars.count == 1,
                  let scalar = text.unicodeScalars.first,
                  scalar.isASCII
            else {
                return nil
            }
            return .character(scalar)
        }
    }

    private static func isKeypadKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 65, 67, 69, 75, 76, 78, 81...89, 91, 92:
            true
        default:
            false
        }
    }

    private static func terminalKey(for key: KeyName) -> TerminalInputKey {
        switch key {
        case .character(let character):
            return .character(character.unicodeScalars[character.unicodeScalars.startIndex])
        case .named(let name):
            switch name {
            case .enter: return .returnKey
            case .tab: return .tab
            case .bspace: return .backspace
            case .escape: return .escape
            case .up: return .up
            case .down: return .down
            case .left: return .left
            case .right: return .right
            case .home: return .home
            case .end: return .end
            case .pgUp: return .pageUp
            case .pgDn: return .pageDown
            case .insert: return .insert
            case .delete: return .deleteForward
            case .f1: return .f1
            case .f2: return .f2
            case .f3: return .f3
            case .f4: return .f4
            case .f5: return .f5
            case .f6: return .f6
            case .f7: return .f7
            case .f8: return .f8
            case .f9: return .f9
            case .f10: return .f10
            case .f11: return .f11
            case .f12: return .f12
            }
        }
    }

    private static func terminalModifiers(_ flags: NSEvent.ModifierFlags) -> TerminalKeyModifiers {
        var modifiers: TerminalKeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.alt) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    private static func terminalModifiers(_ modifiers: KeyMods) -> TerminalKeyModifiers {
        var result: TerminalKeyModifiers = []
        if modifiers.contains(.ctrl) { result.insert(.control) }
        if modifiers.contains(.alt) { result.insert(.alt) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
}

// MARK: - Drag and Drop

extension SwiftTerminalSessionView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }
        let accepted: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, .string]
        return Set(types).isDisjoint(with: accepted) ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let content = dragDropContent(from: sender.draggingPasteboard) else { return false }
        controller.sendPaste(
            content,
            origin: PaneInputOrigin.appEntry(),
            waitGeneration: originatedWaitGeneration
        )
        return true
    }
}
