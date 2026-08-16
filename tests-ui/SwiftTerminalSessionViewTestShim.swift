// Test-only terminal-engine values and controller used to compile the real Swift pane view.
import Cocoa
import IOSurface

enum PaneProcessLifecycleResult {
    case exited
    case launchFailed
}

/// Matches the production controller's terminal result for one bounded input submission.
enum PaneInputSubmissionResult {
    case delivered
    case rejected
}

enum TerminalCellKind {
    case padding
    case narrow
    case wideHead
    case wideTail
    case spacerHead
}

struct TerminalRowStructure {
    let index: Int
    let isRetained: Bool
    let isSoftWrapped: Bool
    let contentEnd: Int
    let width: Int
    let marginCellKind: TerminalCellKind
    let staleWrapClaim: Bool
}

enum TerminalSearchStatus {
    case empty
    case matched(selected: Int, total: Int)
}

enum TerminalSemanticEvent {
    case title(String)
    case workingDirectory(String?)
    case bell
    case integrationReady
    case commandStarted(String)
    case commandEnded(exitStatus: UInt8)
    case connectionDeclared(TerminalConnectionState)
    case desktopNotification(title: String, body: String)
    case progress(TerminalProgress?)
}

enum TerminalConnectionState {
    case local
    case remote(identity: TerminalRemoteIdentity?)
}

struct TerminalRemoteIdentity {
    let user: String
    let host: String
}

enum TerminalProgress {
    case set(percent: UInt8)
    case indeterminate
    case error(percent: UInt8?)
    case pause(percent: UInt8?)
}

struct RenderColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

/// Test-only fixed-palette stand-in used by the real app-side bridge.
struct RenderANSIColors {
    init?(exactly colors: [RenderColor]) {
        guard colors.count == 16 else { return nil }
    }
}

struct RenderTheme {
    static let dark = RenderTheme(defaultBackground: .init(red: 0, green: 0, blue: 0))
    let defaultBackground: RenderColor

    init(defaultBackground: RenderColor) {
        self.defaultBackground = defaultBackground
    }

    init(
        ansiColors: RenderANSIColors,
        defaultForeground: RenderColor,
        defaultBackground: RenderColor,
        selectionForeground: RenderColor,
        selectionBackground: RenderColor,
        cursor: RenderColor,
        cursorText: RenderColor
    ) {
        self.defaultBackground = defaultBackground
    }
}

struct RenderFramePlan {
    /// The fake viewport's row count, exposed so a test can enumerate every row without
    /// restating the literal that `rows` and the initializer default already share.
    static let rowsForTesting = 10

    let defaultBackground: RenderColor
    let columns: Int
    let rows: Int

    /// The grid defaults to the fake viewport, and a test overrides it only to
    /// stand in for a resize -- the one trust-breaking input that reaches the
    /// view as a differently-shaped plan rather than as new metrics.
    init(
        defaultBackground: RenderColor,
        columns: Int = 10,
        rows: Int = RenderFramePlan.rowsForTesting
    ) {
        self.defaultBackground = defaultBackground
        self.columns = columns
        self.rows = rows
    }
}

struct TerminalDamageShift: Equatable {
    let region: Range<Int>
    let delta: Int
}

struct TerminalDamage: Equatable {
    static let full = TerminalDamage(isFull: true)
    let isFull: Bool
    let rows: Set<Int>
    let shift: TerminalDamageShift?

    init(isFull: Bool = false, rows: Set<Int> = [], shift: TerminalDamageShift? = nil) {
        self.isFull = isFull
        self.rows = rows
        self.shift = shift
    }

    init(rows: Range<Int>, rowCount: Int) {
        self.init(rows: Set(rows))
    }

    static let none = TerminalDamage()

    var damagedRowCount: Int { rows.count }

    mutating func formUnion(_ other: TerminalDamage) {
        guard isFull == false else { return }
        if other.isFull {
            self = .full
        } else {
            self = TerminalDamage(rows: rows.union(other.rows))
        }
    }
}

/// A frame store the harness can attach as layer contents without rendering
/// anything. Only what the view touches survives here -- the surface it shows
/// and the geometry it shows it at; the pixel contract lives in the engine's
/// own FrameBackingStoreTests.
final class TerminalFrameBackingStore {
    let columns: Int
    let rows: Int
    let metrics: TerminalRenderMetrics
    let ioSurface: IOSurface

    init?(
        columns: Int,
        rows: Int,
        metrics: TerminalRenderMetrics,
        colorSpace: CGColorSpace? = nil
    ) {
        guard columns > 0, rows > 0 else { return nil }
        guard let surface = IOSurface(properties: [
            .width: columns,
            .height: rows,
            .bytesPerElement: 4,
            .pixelFormat: UInt32(0x4247_5241), // 'BGRA'
        ]) else { return nil }
        self.columns = columns
        self.rows = rows
        self.metrics = metrics
        ioSurface = surface
    }
}

/// Records what the production view asked the swapchain to present, so the
/// harness can pin the single render path -- which rows a publish rendered,
/// which publishes coalesced, which retry finished one -- without pixels or a
/// compositor. Acquisition is a switch here because the real gate is the render
/// server's in-use report, which no headless harness can steer.
final class TerminalFrameSwapchain {
    /// False stands in for a render server still reading every detached
    /// surface: no buffer is acquirable, so every publish coalesces.
    static var canAcquireForTesting = true
    /// The rows each render covered, in order. `.full` renders record every
    /// row; an incremental render records the damage composed since the
    /// acquired buffer was last current.
    private(set) static var renderedRowSetsForTesting: [Set<Int>] = []
    /// Counts swapchain construction, so the harness can tell a replacement
    /// (a trust-breaking input) from a re-render of the same buffers.
    private(set) static var creationCountForTesting = 0

    static func resetForTesting() {
        canAcquireForTesting = true
        renderedRowSetsForTesting = []
        creationCountForTesting = 0
    }

    private let store: TerminalFrameBackingStore
    private let rows: Int
    private var pendingPlan: RenderFramePlan?
    private var staleDamage = TerminalDamage.none
    private var isCurrent = false

    private(set) var lastRenderedDamage: TerminalDamage?
    var hasPendingPresentation: Bool { pendingPlan != nil }

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
        self.rows = rows
        Self.creationCountForTesting += 1
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
        guard pendingPlan != nil, Self.canAcquireForTesting else { return nil }
        let rendered: TerminalDamage = isCurrent && staleDamage.isFull == false
            ? staleDamage
            : .full
        Self.renderedRowSetsForTesting.append(
            rendered.isFull ? Set(0..<rows) : rendered.rows
        )
        lastRenderedDamage = rendered
        isCurrent = true
        staleDamage = .none
        pendingPlan = nil
        return store
    }
}

struct TerminalPaneFrame {
    let plan: RenderFramePlan
    let damage: TerminalDamage
}

struct TerminalDimensions: Equatable {
    let columns: Int
    let rows: Int
}

struct TerminalRenderMetrics: Equatable {
    /// A family that would pass an availability probe yet yields no usable cell
    /// geometry -- the real metrics refuse a face with no nominal `M` glyph, or one
    /// whose cell box cannot be pixel-quantized. Naming the case here proves an
    /// unusable face falls back instead of leaving a terminal blank or frozen without
    /// depending on any particular font being installed on the test machine.
    static let unusableFamily = "DanTermTestUnusableFace"

    /// A family with double-width cells, so a live family change is observable in the
    /// grid the view reports rather than only in metrics the harness cannot see.
    static let wideFamily = "DanTermTestWideFace"

    let cellSize: CGSize
    /// The layer's contents scale rides the surface the view attaches, so the
    /// harness has to carry a real value here rather than a placeholder.
    let displayScale: CGFloat

    init?(displayScale: CGFloat, fontSize: CGFloat = 13, fontFamily: String? = nil) {
        guard displayScale > 0, fontSize > 0, fontFamily != Self.unusableFamily else { return nil }
        let widthFactor: CGFloat = fontFamily == Self.wideFamily ? 2 : 1
        cellSize = CGSize(width: 8 * widthFactor * fontSize / 13, height: 16 * fontSize / 13)
        self.displayScale = displayScale
    }
}

func terminalGridDimensions(
    size: TerminalRenderExecutionSize,
    cellSize: TerminalRenderExecutionSize
) -> TerminalDimensions? {
    guard size.width > 0, size.height > 0, cellSize.width > 0, cellSize.height > 0 else {
        return nil
    }
    return TerminalDimensions(
        columns: Int(size.width / cellSize.width),
        rows: Int(size.height / cellSize.height)
    )
}

struct TerminalRenderExecutionSize {
    let width: Double
    let height: Double
}

struct TerminalScrollProjection: Equatable {
    let totalRows: Int
    let topRow: Int
    let windowRows: Int
    let isFollowing: Bool
}

struct TerminalPaneViewportState: Equatable {
    let isScrollbarEnabled: Bool
    let projection: TerminalScrollProjection
}

struct TerminalViewportCell: Equatable {
    let column: Int
    let row: Int
    let offsetX: Double

    init(column: Int, row: Int, offsetX: Double = 0) {
        self.column = column
        self.row = row
        self.offsetX = offsetX
    }
}

struct TerminalHyperlink: Equatable {
    let uri: String
    let explicitId: String?

    init(uri: String, explicitId: String? = nil) {
        self.uri = uri
        self.explicitId = explicitId
    }
}

enum TerminalPointerEvent: Equatable {
    case down(
        TerminalMouseButton,
        column: Int,
        row: Int,
        offsetX: Double = 0,
        modifiers: TerminalKeyModifiers = [],
        clickCount: Int = 1
    )
    case up(
        TerminalMouseButton,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = []
    )
    case move(column: Int, row: Int, offsetX: Double = 0, modifiers: TerminalKeyModifiers = [])
}

enum TerminalWheelPhase: Equatable {
    case began
    case changed
    case ended
    case momentumBegan
    case momentumChanged
    case momentumEnded
    case standalone
}

struct TerminalWheelEvent: Equatable {
    let rowDelta: Double
    let column: Int
    let row: Int
    let modifiers: TerminalKeyModifiers
    let phase: TerminalWheelPhase

    init(
        rowDelta: Double,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = [],
        phase: TerminalWheelPhase = .standalone
    ) {
        self.rowDelta = rowDelta
        self.column = column
        self.row = row
        self.modifiers = modifiers
        self.phase = phase
    }
}

func terminalCell(
    at point: TerminalPoint,
    cellSize: TerminalCellSize,
    columns: Int,
    rows: Int
) -> TerminalViewportCell? {
    guard cellSize.width > 0, cellSize.height > 0, columns > 0, rows > 0 else { return nil }
    let scaledColumn = point.x / cellSize.width
    let column = Int(scaledColumn.rounded(.down))
    let clampedColumn = min(max(column, 0), columns - 1)
    return TerminalViewportCell(
        column: clampedColumn,
        row: min(max(Int((point.y / cellSize.height).rounded(.down)), 0), rows - 1),
        offsetX: column == clampedColumn
            ? min(max(scaledColumn - scaledColumn.rounded(.down), 0), 1)
            : (column < clampedColumn ? 0 : 1)
    )
}

struct TerminalPoint {
    let x: Double
    let y: Double
}

struct TerminalCellSize {
    let width: Double
    let height: Double
}

struct TerminalPaneFenceMetrics {
    struct Measurement {
        var count: UInt64 = 0
    }

    var delivery = Measurement()
}

@MainActor
final class TerminalPaneSessionController {
    var onFrame: ((TerminalPaneFrame) -> Void)?
    var onClipboardWrite: ((String) -> Void)?
    var onSelectionCopy: ((String) -> Void)?
    var onSemanticEvents: (([TerminalSemanticEvent]) -> Void)?
    var onProcessStarted: (() -> Void)?
    var onSessionEnded: ((PaneProcessLifecycleResult) -> Void)?
    var onViewportStateChange: ((TerminalPaneViewportState) -> Void)?
    var onPaneMenu: ((TerminalViewportCell) -> Void)?
    var onOpenLink: ((TerminalHyperlink) -> Void)?
    var onSearchStatus: ((TerminalSearchStatus?) -> Void)?
    var onPrimaryHistoryMutation: (() -> Void)?
    /// Stands in for the real controller's per-fence display-interval read
    /// (research/33 D8); the harness never fences, so it is write-only here.
    var displayRefreshIntervalNanoseconds: (() -> UInt64)?
    var currentPlan: RenderFramePlan?
    /// Stands in for the real controller's fence census, which the frame-rate
    /// sampler's call sites read. The harness never emits a rate sample, so a
    /// frozen zero is the whole contract.
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
    private(set) var deliveredTextInputs: [String] = []
    private(set) var deliveredInputBytes: [[UInt8]] = []
    /// Origin stamps in submission order, so a test can assert which moment the pane view
    /// attributed its input to. The real controller forwards these to the flight recorder.
    private(set) var inputOrigins: [UInt64?] = []
    private(set) var focusChanges: [Bool] = []
    private(set) var pointerEvents: [TerminalPointerEvent] = []
    private(set) var wheelEvents: [TerminalWheelEvent] = []
    private(set) var searchQueries: [String] = []
    private(set) var searchNextRequests = 0
    private(set) var searchPreviousRequests = 0
    private(set) var clearSearchRequests = 0
    private(set) var synchronizedSelectionReads = 0
    private(set) var linkInteractionCancellations = 0
    var allowsPaneMenu = true
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

    func sendText(_ text: String, origin: UInt64?) {
        sendText(text, origin: origin, onCompletion: nil)
    }
    func sendText(
        _ text: String,
        origin: UInt64?,
        onCompletion: (@MainActor @Sendable (PaneInputSubmissionResult) -> Void)?
    ) {
        textInputs.append(text)
        inputOrigins.append(origin)
        deliverOrBuffer { [weak self] in
            self?.deliveredTextInputs.append(text)
            Self.complete(onCompletion, with: .delivered)
        }
    }
    func sendKey(
        _ key: TerminalInputKey,
        modifiers: TerminalKeyModifiers,
        origin: UInt64?,
        onCompletion: (@MainActor @Sendable (PaneInputSubmissionResult) -> Void)? = nil
    ) {
        let bytes = encodeTerminalKey(key, modifiers: modifiers, modes: inputModes)
        inputBytes.append(bytes)
        inputOrigins.append(origin)
        deliverOrBuffer { [weak self] in
            self?.deliveredInputBytes.append(bytes)
            Self.complete(onCompletion, with: .delivered)
        }
    }
    func sendPaste(
        _ text: String,
        origin: UInt64?,
        onCompletion: (@MainActor @Sendable (PaneInputSubmissionResult) -> Void)? = nil
    ) {
        let bytes = encodeTerminalPaste(text, modes: inputModes)
        inputBytes.append(bytes)
        inputOrigins.append(origin)
        deliverOrBuffer { [weak self] in
            self?.deliveredInputBytes.append(bytes)
            Self.complete(onCompletion, with: .delivered)
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

    private func deliverOrBuffer(_ delivery: @escaping () -> Void) {
        if processIsRunning {
            delivery()
        } else {
            pendingInputDeliveries.append(delivery)
        }
    }

    private static func complete(
        _ completion: (@MainActor @Sendable (PaneInputSubmissionResult) -> Void)?,
        with result: PaneInputSubmissionResult
    ) {
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
        let bytes = encodeTerminalFocus(focused: focused, modes: inputModes)
        if bytes.isEmpty == false {
            inputBytes.append(bytes)
            inputOrigins.append(origin)
        }
    }
    // `origin` is accepted and dropped: this shim records wheel and pointer input as events
    // rather than as bytes, and only the byte-producing paths above assert on their stamps.
    func sendWheel(_ event: TerminalWheelEvent, origin: UInt64?) {
        wheelEvents.append(event)
    }
    func sendWheel(
        _ event: TerminalWheelEvent,
        origin: UInt64?,
        onCompletion: (@MainActor @Sendable (PaneInputSubmissionResult) -> Void)?
    ) {
        wheelEvents.append(event)
        Self.complete(onCompletion, with: .delivered)
    }
    func sendPointer(_ event: TerminalPointerEvent, origin: UInt64?) {
        pointerEvents.append(event)
        if allowsPaneMenu, case let .up(.right, column, row, _) = event {
            onPaneMenu?(.init(column: column, row: row))
        }
        switch event {
        case let .move(_, _, _, modifiers):
            cachedHoveredLink = modifiers.contains(.command) ? hoveredLinkForCommandMove : nil
            emitFrame()
        case let .down(.left, _, _, _, modifiers, _):
            linkClickArmed = modifiers.contains(.command) && linkForCommandClick != nil
        case let .up(.left, _, _, modifiers):
            if linkClickArmed, modifiers.contains(.command), let linkForCommandClick {
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
    func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String? { nil }
    func primaryHistoryTailReader() -> @Sendable (Int, Int) -> String? { { _, _ in nil } }
    private(set) var gridDimensions: [TerminalDimensions] = []

    func setGridDimensions(_ dimensions: TerminalDimensions) {
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

    func emitSemanticEvents(_ events: [TerminalSemanticEvent]) {
        onSemanticEvents?(events)
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
