// AppKit host for one Swift terminal session: geometry, drawing, text input,
// and the stable DanTerm TerminalSession boundary live here and nowhere else.
import Cocoa
import DanTermProtocol
#if !DANTERM_UI_TEST
import PaneLifecycle
import TerminalCore
import TerminalCoreRecording
import TerminalPaneSession
import TerminalRenderExecution
import TerminalRenderPlanning
#endif

#if !DANTERM_UI_TEST
/// Preserves TerminalCoreRecording's single event dialect when wrapping live tape events for IPC.
func paneTapeFollowEventJSON(_ event: NeutralTerminalRecordingEvent) throws -> JSONValue {
    let data = try JSONEncoder().encode(event)
    return try JSONDecoder().decode(JSONValue.self, from: data)
}
#endif

/// Adapts one headless Swift terminal controller into DanTerm's AppKit pane contract.
final class SwiftTerminalSessionView: NSView, NSTextInputClient, NSMenuItemValidation, TerminalSession {
    private let controller: TerminalPaneSessionController
    private let resolveTheme: (String) -> RenderTheme?
    private let callbackGate = TerminalSessionCallbackGate()
    private let wheelNormalizer = TerminalWheelNormalizer()
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var currentMetrics: TerminalRenderMetrics?
    private var currentDimensions: TerminalDimensions?
    private var controlClickIsActive = false
    private var mouseTrackingArea: NSTrackingArea?
    private var lastPointerLocationInWindow: NSPoint?
    private var isPointerInside = false
    private var hoveredLink: TerminalHyperlink?
    private var linkPreview: LinkPreviewView?
    private var publishedFrame: (plan: RenderFramePlan, metrics: TerminalRenderMetrics)?
    /// Retains source row damage across publishes because AppKit reduces disjoint
    /// invalidations to one union rectangle before `draw(_:)` can inspect them.
    private var pendingDisplayDamage = TerminalDamage.none
    private var lastEmittedState: TerminalSessionState?
    private var lastForwardedFocus = false
    private var isTornDown = false
    private var fontSize: CGFloat
    /// The verified-installed family to render, or nil for the system monospace
    /// font. Never a raw name from config -- only a resolved family reaches here.
    private var fontFamily: String?

    weak var paneWrapper: PaneWrapperView?
    /// Defaults explicit selection copies to the system pasteboard while keeping UI tests isolated.
    var selectionPasteboard = NSPasteboard.general
    /// Lets the UI harness observe owner-approved menu timing without entering AppKit menu tracking.
    var paneMenuHandler: ((TerminalViewportCell) -> Void)?
    /// Defaults approved web links to the workspace while keeping UI tests free of external effects.
    var linkOpener: ((URL) -> Bool)? = { NSWorkspace.shared.open($0) }

    var hostView: NSView { self }
    var onEvent: ((TerminalSessionEvent) -> Void)? {
        get { callbackGate.onEvent }
        set { callbackGate.onEvent = newValue }
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
            cellHeight: currentMetrics?.cellSize.height ?? 0,
            scrollPosition: TerminalScrollPosition(
                total: UInt64(clamping: projection.totalRows),
                offset: UInt64(clamping: projection.topRow),
                length: UInt64(clamping: projection.windowRows)
            )
        )
    }
    var hasSelection: Bool { controller.hasSelection }
    #if DANTERM_UI_TEST
    var publishedBackgroundForTesting: RenderColor? {
        publishedFrame?.plan.defaultBackground
    }
    private(set) var drawnRowSetsForTesting: [Set<Int>] = []

    func resetDrawnRowSetsForTesting() {
        drawnRowSetsForTesting = []
    }
    #endif
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
        controller: TerminalPaneSessionController,
        fontSize: Double = DanTermConfig.default.resolvedFontSize,
        fontFamily: String? = nil,
        resolveTheme: @escaping (String) -> RenderTheme? = ThemeCatalog.shared.renderTheme(named:),
        onSessionEnded: ((PaneLifecycleResult) -> Void)? = nil
    ) {
        self.controller = controller
        self.fontSize = CGFloat(fontSize)
        self.fontFamily = fontFamily
        self.resolveTheme = resolveTheme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.cgColor(controller.renderTheme.defaultBackground)
        registerForDraggedTypes([.fileURL, .URL, .string])
        #if DANTERM_TERMINAL_BENCHMARK
        TerminalBenchmarkObserver.shared?.attachFenceMetricsController(controller)
        #endif

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
        controller.onPaneMenu = { [weak self] cell in
            self?.showPaneMenu(at: cell)
        }
        controller.onOpenLink = { [weak self] link in
            self?.openLink(link)
        }
        controller.onSearchStatus = { [weak self] status in
            self?.publish(status)
        }
        controller.onSessionEnded = { [weak self] result in
            onSessionEnded?(result)
            self?.callbackGate.emit(.closeRequested)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    isolated deinit {
        tearDown()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        #if DANTERM_TERMINAL_BENCHMARK
        let drawStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
        #endif
        let frame = publishedFrame
        let background = frame?.plan.defaultBackground ?? RenderTheme.dark.defaultBackground
        context.setFillColor(Self.cgColor(background))
        if let frame {
            let drawingDamageResolution = drawingDamage(
                fallback: dirtyRect,
                metrics: frame.metrics,
                rowCount: frame.plan.rows
            )
            let drawingDamage = drawingDamageResolution.damage
            let plan = drawingDamage.isFull
                ? frame.plan
                : clipFramePlan(frame.plan, to: drawingDamage)
            context.saveGState()
            if drawingDamage.isFull == false {
                context.beginPath()
                for span in terminalDamageMaximalContiguousSpans(drawingDamage.rows) {
                    context.addRect(NSRect(
                        x: 0,
                        y: CGFloat(span.lowerBound) * frame.metrics.cellSize.height,
                        width: CGFloat(frame.plan.columns) * frame.metrics.cellSize.width,
                        height: CGFloat(span.count) * frame.metrics.cellSize.height
                    ))
                }
                context.clip()
            }
            context.fill(dirtyRect)
            #if DANTERM_UI_TEST
            drawnRowSetsForTesting.append(plan.includedRows)
            #endif
            context.clip(to: dirtyRect)
            drawRenderFrame(plan, metrics: frame.metrics, in: context)
            context.restoreGState()
            #if DANTERM_TERMINAL_BENCHMARK
            let drawDurationNanoseconds =
                DispatchTime.now().uptimeNanoseconds - drawStartedNanoseconds
            TerminalBenchmarkObserver.shared?.observeCompletedDraw(
                frame.plan,
                dirtyRect: dirtyRect,
                metrics: frame.metrics,
                drawDurationNanoseconds: drawDurationNanoseconds,
                damage: drawingDamage,
                usedDirtyRectFallback: drawingDamageResolution.usedDirtyRectFallback
            )
            if TerminalBenchmarkObserver.shared?.needsPublishedRedraw == true {
                let redrawRect = NSRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(frame.plan.columns) * frame.metrics.cellSize.width,
                    height: CGFloat(frame.plan.rows) * frame.metrics.cellSize.height
                )
                DispatchQueue.main.async { [weak self] in
                    self?.invalidateFullDisplay(redrawRect)
                }
            }
            #endif
        } else {
            context.fill(dirtyRect)
        }
    }

    /// Consumes exact engine damage when available and preserves AppKit-driven redraws as fallback.
    private func drawingDamage(
        fallback dirtyRect: NSRect,
        metrics: TerminalRenderMetrics,
        rowCount: Int
    ) -> (damage: TerminalDamage, usedDirtyRectFallback: Bool) {
        if pendingDisplayDamage != .none {
            let damage = pendingDisplayDamage
            pendingDisplayDamage = .none
            return (damage, false)
        }
        let rows = terminalRows(
            intersecting: dirtyRect,
            metrics: metrics,
            rowCount: rowCount
        )
        let damage: TerminalDamage = rows == 0..<rowCount
            ? .full
            : TerminalDamage(rows: Set(rows))
        return (damage, true)
    }

    /// Prevents geometry, theme, and benchmark invalidations from inheriting stale partial damage.
    private func invalidateFullDisplay(_ rect: NSRect? = nil) {
        pendingDisplayDamage = .full
        if let rect {
            setNeedsDisplay(rect)
        } else {
            needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeGeometry()
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
        synchronizeGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        synchronizeGeometry()
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
        if result {
            forwardFocusIfChanged(true)
            callbackGate.emit(.becameFirstResponder)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { forwardFocusIfChanged(false) }
        return result
    }

    override func scrollWheel(with event: NSEvent) {
        guard isTornDown == false, let cell = normalizedCell(for: event) else { return }
        let rows = wheelNormalizer.rows(
            delta: Self.verticalScrollDelta(for: event),
            isPrecise: event.hasPreciseScrollingDeltas,
            cellHeight: Double(state.cellHeight)
        )
        controller.sendWheel(.init(
            rowDelta: rows,
            column: cell.column,
            row: cell.row,
            modifiers: Self.terminalModifiers(event.modifierFlags),
            phase: Self.wheelPhase(for: event)
        ))
    }

    override func mouseDown(with event: NSEvent) {
        controlClickIsActive = event.modifierFlags.contains(.control)
        forwardPointerDown(event, button: controlClickIsActive ? .right : .left)
    }

    override func mouseUp(with event: NSEvent) {
        forwardPointerUp(event, button: controlClickIsActive ? .right : .left)
        controlClickIsActive = false
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardPointerDown(event, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardPointerUp(event, button: .right)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        forwardPointerDown(event, button: .middle)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        forwardPointerUp(event, button: .middle)
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
        forwardPointerMove(at: location, modifiers: event.modifierFlags)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) == false else { return }
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = hasMarkedText()
        interpretKeyEvents([event])
        if markedTextBefore == false, hasMarkedText() == false,
           Self.isKeypadKeyCode(event.keyCode), let key = Self.terminalKey(for: event) {
            controller.sendKey(key, modifiers: Self.terminalModifiers(event.modifierFlags))
            return
        }
        if let texts = keyTextAccumulator, texts.isEmpty == false,
           texts.allSatisfy(Self.isCommittedTerminalText) {
            for text in texts { controller.sendText(text) }
            return
        }
        guard markedTextBefore == false, hasMarkedText() == false else { return }
        guard let key = Self.terminalKey(for: event) else { return }
        controller.sendKey(key, modifiers: Self.terminalModifiers(event.modifierFlags))
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
        let viewRect = NSRect(x: 0, y: 0, width: 0, height: state.cellHeight)
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
            controller.sendText(text)
        }
    }

    override func doCommand(by selector: Selector) {
        // Fixed terminal keys are encoded after interpretKeyEvents returns.
    }

    func sendText(_ text: String) {
        controller.sendText(text)
    }

    func sendInputText(_ text: String) {
        controller.sendText(text)
    }

    func sendInputKey(_ key: KeyName, modifiers: KeyMods) {
        guard let key = Self.terminalKey(for: key) else { return }
        controller.sendKey(key, modifiers: Self.terminalModifiers(modifiers))
    }

    func setFocused(_ focused: Bool) {
        forwardFocusIfChanged(focused)
    }

    func setVisible(_ visible: Bool) {
        controller.setVisible(visible)
    }

    func setDisplayID(_ displayID: UInt32) {}
    func setScrollbarEnabled(_ enabled: Bool) {}

    func refreshBackingProperties() {
        synchronizeGeometry()
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
        synchronizeGeometry()
    }

    func setFontFamily(_ family: String?) {
        guard family != fontFamily else { return }
        fontFamily = family
        synchronizeGeometry()
    }

    func startSearch() {
        // Synchronous on purpose: `.searchStarted` is what creates the pane's
        // searchState and mounts the overlay, so it cannot wait on an engine round-trip.
        callbackGate.emit(.searchStarted(""))
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

    #if !DANTERM_UI_TEST
    func flightRecordingEncoder() -> (@Sendable () throws -> Data)? {
        guard let snapshot = controller.flightRecordingSnapshot() else { return nil }
        return { try snapshot.encodedRecording() }
    }

    func paneTapeFollowStart(
        fromNow: Bool
    ) -> (@Sendable () throws -> PaneTapeFollowStart)? {
        let origin = fromNow
            ? controller.flightRecordingOriginFromNow()
            : controller.flightRecordingBacklogOrigin()
        guard let origin else { return nil }
        return {
            let provenanceData = try JSONEncoder().encode(NeutralTerminalProvenance.liveCapture())
            let provenance = try JSONDecoder().decode(JSONValue.self, from: provenanceData)
            return makePaneTapeFollowStart(
                provenance: provenance,
                initial: .init(columns: origin.initial.columns, rows: origin.initial.rows),
                cursor: .init(
                    nextSequence: origin.cursor.nextSequence,
                    payloadBytesBeforeNextSequence: origin.cursor.payloadBytesBeforeNextSequence
                )
            )
        }
    }

    func paneTapeFollowBatch(
        from cursor: PaneTapeFollowCursor
    ) -> (@Sendable () throws -> PaneTapeFollowSnapshot)? {
        guard let snapshot = controller.flightRecordingSnapshot(
            nextSequence: cursor.nextSequence,
            payloadBytesBeforeNextSequence: cursor.payloadBytesBeforeNextSequence
        ) else {
            return nil
        }
        return {
            let events = try snapshot.events.map { recorded in
                return PaneTapeFollowEvent(
                    sequence: recorded.sequence,
                    elapsedNanoseconds: recorded.elapsedNanoseconds,
                    event: try paneTapeFollowEventJSON(recorded.event)
                )
            }
            return PaneTapeFollowSnapshot(
                events: events,
                droppedEventCount: snapshot.droppedEventCount,
                droppedPayloadBytes: snapshot.droppedPayloadBytes,
                nextCursor: .init(
                    nextSequence: snapshot.nextCursor.nextSequence,
                    payloadBytesBeforeNextSequence:
                        snapshot.nextCursor.payloadBytesBeforeNextSequence
                )
            )
        }
    }
    #endif

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
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        controller.sendPaste(text)
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

    func setFocusBorder(_ focused: Bool, hasBell: Bool) {
        guard let layer else { return }
        if focused {
            layer.borderWidth = 2
            layer.borderColor = NSColor.systemGreen.cgColor
        } else if hasBell {
            layer.borderWidth = 2
            layer.borderColor = NSColor.systemRed.cgColor
        } else {
            layer.borderWidth = 0
            layer.borderColor = nil
        }
    }

    func tearDown() {
        guard isTornDown == false else { return }
        isTornDown = true
        paneMenuHandler = nil
        linkOpener = nil
        isPointerInside = false
        updateHoveredLinkChrome(nil)
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
            self.mouseTrackingArea = nil
        }
        callbackGate.tearDown()
        #if DANTERM_TERMINAL_BENCHMARK
        TerminalBenchmarkObserver.shared?.detachFenceMetricsController(controller)
        #endif
        controller.tearDown()
    }

    private func publish(_ events: [TerminalSemanticEvent]) {
        for event in events {
            switch event {
            case .title(let title):
                #if DANTERM_TERMINAL_BENCHMARK
                TerminalBenchmarkObserver.shared?.observeTitle(title)
                #endif
                callbackGate.emit(.titleChanged(title))
            case .workingDirectory(let cwd):
                callbackGate.emit(.cwdChanged(cwd))
            case .bell:
                callbackGate.emit(.bell)
            case .commandStarted(let command):
                callbackGate.emit(.commandStarted(command))
            case .commandEnded:
                callbackGate.emit(.commandEnded)
            case .remoteStarted:
                callbackGate.emit(.remoteStarted)
            case let .remoteHost(user, host):
                callbackGate.emit(.remoteHost(user: user, host: host))
            case let .desktopNotification(title, body):
                callbackGate.emit(.desktopNotification(title: title, body: body))
            case .progress(let progress):
                callbackGate.emit(.progress(progress.map { state in
                    switch state {
                    case .set(let percent): .set(percent: percent)
                    case .indeterminate: .indeterminate
                    case .error(let percent): .error(percent: percent)
                    case .pause(let percent): .pause(percent: percent)
                    }
                }))
            }
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

    private func synchronizeGeometry() {
        guard isTornDown == false,
              bounds.width > 0, bounds.height > 0,
              let scale = window?.backingScaleFactor,
              let metrics = resolvedMetrics(displayScale: scale),
              let dimensions = terminalGridDimensions(
                  size: .init(width: Double(bounds.width), height: Double(bounds.height)),
                  cellSize: .init(
                      width: Double(metrics.cellSize.width),
                      height: Double(metrics.cellSize.height)
                  )
              )
        else {
            return
        }

        let metricsChanged = metrics != currentMetrics
        currentMetrics = metrics
        currentDimensions = dimensions
        controller.setGridDimensions(dimensions)
        if metricsChanged {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = scale
            CATransaction.commit()
            if let plan = controller.currentPlan {
                publishedFrame = (plan, metrics)
            }
            emitStateIfNeeded()
            invalidateFullDisplay()
        }
    }

    /// Metrics for the configured family, falling back to the system monospace font
    /// when that family yields none (I5).
    ///
    /// Passing the availability probe does not guarantee usable grid geometry -- a
    /// face can be installed and still lack the nominal `M` glyph the cell box is
    /// derived from. Without this retry `synchronizeGeometry` would bail, leaving a
    /// new pane with no geometry and an existing pane frozen on its old grid.
    private func resolvedMetrics(displayScale: CGFloat) -> TerminalRenderMetrics? {
        if let fontFamily,
           let metrics = TerminalRenderMetrics(
               displayScale: displayScale,
               fontSize: fontSize,
               fontFamily: fontFamily
           )
        {
            return metrics
        }
        return TerminalRenderMetrics(displayScale: displayScale, fontSize: fontSize)
    }

    private func applyResolvedTheme(_ theme: RenderTheme) {
        controller.setTheme(theme)
        layer?.backgroundColor = Self.cgColor(theme.defaultBackground)
        invalidateFullDisplay()
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
        let hoveredLink = isPointerInside ? lastPointerLocationInWindow.flatMap { location in
            pointerIsOutsideGrid(location) ? nil : controller.readHoveredLink()
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
            fenceStallNanoseconds: controller.lastFenceStallNanoseconds
        )
        #endif
        publishedFrame = (frame.plan, metrics)
        if frame.damage.isFull {
            invalidateFullDisplay()
        } else {
            let rows = terminalDamageRowsWithGlyphHalo(
                frame.damage.rows,
                rowCount: frame.plan.rows
            )
            pendingDisplayDamage.formUnion(TerminalDamage(rows: rows))
            for row in rows {
                setNeedsDisplay(NSRect(
                    x: 0,
                    y: CGFloat(row) * metrics.cellSize.height,
                    width: CGFloat(frame.plan.columns) * metrics.cellSize.width,
                    height: metrics.cellSize.height
                ))
            }
        }
    }

    private func forwardFocusIfChanged(_ focused: Bool) {
        guard isTornDown == false, focused != lastForwardedFocus else { return }
        lastForwardedFocus = focused
        controller.sendFocus(focused)
    }

    private func normalizedCell(for event: NSEvent) -> TerminalViewportCell? {
        normalizedCell(at: event.locationInWindow)
    }

    private func normalizedCell(at locationInWindow: NSPoint) -> TerminalViewportCell? {
        guard let metrics = currentMetrics, let dimensions = currentDimensions else { return nil }
        let point = convert(locationInWindow, from: nil)
        return terminalCell(
            at: .init(x: Double(point.x), y: Double(point.y)),
            cellSize: .init(
                width: Double(metrics.cellSize.width),
                height: Double(metrics.cellSize.height)
            ),
            columns: dimensions.columns,
            rows: dimensions.rows
        )
    }

    private func forwardPointerDown(_ event: NSEvent, button: TerminalMouseButton) {
        guard isTornDown == false, let cell = normalizedCell(for: event) else { return }
        lastPointerLocationInWindow = event.locationInWindow
        isPointerInside = pointerIsOutsideGrid(event.locationInWindow) == false
        controller.sendPointer(.down(
            button,
            column: cell.column,
            row: cell.row,
            modifiers: Self.terminalModifiers(event.modifierFlags),
            clickCount: event.clickCount
        ))
        if pointerIsOutsideGrid(event.locationInWindow) {
            controller.cancelLinkInteraction()
        }
    }

    private func forwardPointerUp(_ event: NSEvent, button: TerminalMouseButton) {
        guard isTornDown == false, let cell = normalizedCell(for: event) else { return }
        lastPointerLocationInWindow = event.locationInWindow
        if pointerIsOutsideGrid(event.locationInWindow) {
            isPointerInside = false
            controller.cancelLinkInteraction()
        }
        controller.sendPointer(.up(
            button,
            column: cell.column,
            row: cell.row,
            modifiers: Self.terminalModifiers(event.modifierFlags)
        ))
    }

    private func forwardPointerMove(_ event: NSEvent) {
        lastPointerLocationInWindow = event.locationInWindow
        isPointerInside = pointerIsOutsideGrid(event.locationInWindow) == false
        forwardPointerMove(at: event.locationInWindow, modifiers: event.modifierFlags)
    }

    private func forwardPointerMove(
        at locationInWindow: NSPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        guard isTornDown == false, let cell = normalizedCell(at: locationInWindow) else { return }
        controller.sendPointer(.move(
            column: cell.column,
            row: cell.row,
            modifiers: Self.terminalModifiers(modifiers)
        ))
        if pointerIsOutsideGrid(locationInWindow) {
            controller.cancelLinkInteraction()
        }
    }

    private func pointerIsOutsideGrid(_ locationInWindow: NSPoint) -> Bool {
        guard let metrics = currentMetrics, let dimensions = currentDimensions else { return true }
        let point = convert(locationInWindow, from: nil)
        return point.x < 0 || point.y < 0
            || point.x >= CGFloat(dimensions.columns) * metrics.cellSize.width
            || point.y >= CGFloat(dimensions.rows) * metrics.cellSize.height
    }

    private func showPaneMenu(at cell: TerminalViewportCell) {
        guard isTornDown == false else { return }
        if let paneMenuHandler {
            paneMenuHandler(cell)
            return
        }
        guard let paneWrapper, let metrics = currentMetrics else { return }
        let menu = paneWrapper.makePaneMenu(includeClipboard: true)
        let point = NSPoint(
            x: (CGFloat(cell.column) + 0.5) * metrics.cellSize.width,
            y: (CGFloat(cell.row) + 1) * metrics.cellSize.height
        )
        menu.popUp(positioning: nil, at: point, in: self)
    }

    private func openLink(_ link: TerminalHyperlink) {
        guard isTornDown == false,
              let url = Self.safeWebURL(link.uri)
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

    private static func safeWebURL(_ raw: String) -> URL? {
        guard raw.unicodeScalars.allSatisfy({ scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) == false
                && CharacterSet.controlCharacters.contains(scalar) == false
        }),
            let components = URLComponents(string: raw),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            host.isEmpty == false,
            components.port.map({ (1...65_535).contains($0) }) ?? true
        else {
            return nil
        }
        return components.url
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

    private static func terminalKey(for key: KeyName) -> TerminalInputKey? {
        switch key {
        case .letter(let character):
            guard let scalar = character.lowercased().unicodeScalars.first else { return nil }
            return .character(scalar)
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
        controller.sendPaste(content)
        return true
    }
}
