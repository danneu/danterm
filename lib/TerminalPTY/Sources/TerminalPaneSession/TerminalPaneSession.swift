// Main-actor pane policy that turns one PTY host's conflated updates into cached
// inspection text, complete render plans, child-ended evidence, and one exit notification.
import PaneLifecycle
import TerminalCore
import TerminalCoreRecording
import TerminalPTYHost
import TerminalRenderPlanning

/// Gives the AppKit adapter a deduplicated scrollbar projection without exposing Terminal storage.
public struct TerminalPaneViewportState: Equatable, Sendable {
    /// False while an alternate screen owns the live grid and primary history stays hidden.
    public let isScrollbarEnabled: Bool
    /// Current reflowed row extent and selected local window.
    public let projection: TerminalScrollProjection

    /// Creates one complete state emitted atomically with the cached terminal snapshot.
    public init(isScrollbarEnabled: Bool, projection: TerminalScrollProjection) {
        self.isScrollbarEnabled = isScrollbarEnabled
        self.projection = projection
    }
}

/// Publishes a complete retained plan with the bounded damage that triggered its display pass.
public struct TerminalPaneFrame: Equatable, Sendable {
    /// Complete retained rendering state, independent of the damage optimization.
    public let plan: RenderFramePlan
    /// Coalesced redraw work since the previous published frame.
    public let damage: TerminalDamage

    public init(plan: RenderFramePlan, damage: TerminalDamage) {
        self.plan = plan
        self.damage = damage
    }
}

/// Bundles a failure-time terminal snapshot with the exact transitions that produced it.
package struct TerminalPaneDiagnosticCapture: Sendable {
    package let terminal: Terminal
    package let recording: NeutralTerminalRecording
    package let semanticEvents: [TerminalSemanticEvent]
}

/// Owns one headless terminal pane while keeping host bytes and actor state behind the adapter.
@MainActor
public final class TerminalPaneSessionController {
    private let host: TerminalPTYHost
    private var consumeTask: Task<Void, Never>?
    private var cachedTerminal: Terminal
    private let initialDimensions: TerminalDimensions
    private var lastPlannedTerminal: Terminal?
    private var pendingDamage = TerminalDamage.none
    private var lastSubmittedDimensions: TerminalDimensions
    private var isVisible: Bool
    private var isTornDown = false
    private var didChildExit = false
    private var didEmitSessionEnded = false
    private var completedRecordingEvents: [NeutralTerminalRecordingEvent]?
    private var lastEmittedViewportState: TerminalPaneViewportState?
    private var lastPrimaryHistoryGeneration: UInt64

    /// Process-lifetime access retained by the backend until this host finishes teardown.
    public let terminationHandle: TerminalPaneTerminationHandle

    /// Receives complete retained frames with coalesced logical damage on the main actor.
    public var onFrame: ((TerminalPaneFrame) -> Void)?

    /// Delivers completed clipboard writes before any visibility or render-planning gate.
    public var onClipboardWrite: ((String) -> Void)?

    /// Delivers ordered terminal semantics before visibility, rendering, or exit callbacks.
    public var onSemanticEvents: (([TerminalSemanticEvent]) -> Void)?

    /// Receives the first child-originated lifecycle result on the main actor.
    public var onSessionEnded: ((PaneLifecycleResult) -> Void)?

    /// Receives scrollbar-relevant state only when its projection or screen availability changes.
    public var onViewportStateChange: ((TerminalPaneViewportState) -> Void)?

    /// Signals primary-history changes without materializing text until recovery reads it.
    public var onPrimaryHistoryMutation: (() -> Void)?

    /// Receives an uncaptured pane-menu request only after its pointer gesture completes.
    public var onPaneMenu: ((TerminalViewportCell) -> Void)?

    /// Receives a click-time-revalidated HTTP(S) target on the main actor.
    public var onOpenLink: ((TerminalHyperlink) -> Void)?

    /// Releases the backend registry entry only after this host's native teardown completes.
    public var onTeardownCompleted: (@MainActor @Sendable () -> Void)?

    /// The latest complete plan delivered for the visible pane, retained for scale-only redraws.
    public private(set) var currentPlan: RenderFramePlan?

    /// Damage paired with `currentPlan` at its most recent publication.
    public private(set) var currentDamage: TerminalDamage?

    /// Creates and starts the sole PTY host owned by this pane controller.
    public convenience init(
        configuration: TerminalPaneLaunchConfiguration,
        bootstrapExecutable: String,
        isVisible: Bool = true,
        machineHostname: String? = MachineHostname.posix
    ) throws {
        let host = try TerminalPTYHost(
            initialDimensions: configuration.initialDimensions,
            bootstrapExecutable: bootstrapExecutable,
            machineHostname: machineHostname,
            programVersion: configuration.terminalProgramVersion
        )
        self.init(host: host, launchInput: configuration.launchInput, isVisible: isVisible)
    }

    /// Enables transition capture only for package tests or characterization app builds.
    #if DANTERM_TERMINAL_CHARACTERIZATION
    public convenience init(
        configuration: TerminalPaneLaunchConfiguration,
        bootstrapExecutable: String,
        isVisible: Bool = true,
        machineHostname: String? = MachineHostname.posix,
        captureTransitions: Bool
    ) throws {
        let host = try TerminalPTYHost(
            initialDimensions: configuration.initialDimensions,
            bootstrapExecutable: bootstrapExecutable,
            machineHostname: machineHostname,
            programVersion: configuration.terminalProgramVersion,
            captureTransitions: captureTransitions
        )
        self.init(host: host, launchInput: configuration.launchInput, isVisible: isVisible)
    }
    #else
    package convenience init(
        configuration: TerminalPaneLaunchConfiguration,
        bootstrapExecutable: String,
        isVisible: Bool = true,
        machineHostname: String? = MachineHostname.posix,
        captureTransitions: Bool
    ) throws {
        let host = try TerminalPTYHost(
            initialDimensions: configuration.initialDimensions,
            bootstrapExecutable: bootstrapExecutable,
            machineHostname: machineHostname,
            programVersion: configuration.terminalProgramVersion,
            captureTransitions: captureTransitions
        )
        self.init(host: host, launchInput: configuration.launchInput, isVisible: isVisible)
    }
    #endif

    init(
        host: TerminalPTYHost,
        launchInput: LaunchPolicyInput,
        isVisible: Bool = true
    ) {
        self.host = host
        terminationHandle = TerminalPaneTerminationHandle(host: host)
        let initialFrameState = host.fencedFrameState()
        cachedTerminal = initialFrameState.terminal
        lastPrimaryHistoryGeneration = initialFrameState.terminal.primaryHistoryGeneration
        initialDimensions = launchInput.initialDimensions
        pendingDamage = initialFrameState.damage
        lastSubmittedDimensions = launchInput.initialDimensions
        self.isVisible = isVisible
        lastEmittedViewportState = viewportState

        if isVisible { planIfNeeded(cachedTerminal) }

        host.submitStart(launchInput)
        consumeTask = Task { [weak self, host] in
            for await _ in host.updates {
                guard Task.isCancelled == false else { break }
                let result = await host.result()
                let transitions: [TerminalPTYAppliedTransition]?
                // Results publish only after output drain, so these actor reads
                // cannot acquire a transition newer than the final snapshot.
                if case .some(.exited) = result, host.captureTransitions {
                    transitions = await host.transitions()
                } else {
                    transitions = nil
                }
                let frameState = await host.frameState()
                guard let self, self.isTornDown == false else { break }
                self.consume(frameState: frameState, result: result, transitions: transitions)
            }
        }
    }

    /// Sends committed UTF-8 text through the host's shared ordered submission queue.
    public func sendText(_ text: String) {
        send(Array(text.utf8))
    }

    /// Sends already encoded terminal bytes without introducing an ordering-opaque Task.
    public func send(_ bytes: [UInt8]) {
        guard isTornDown == false, bytes.isEmpty == false else { return }
        host.send(bytes)
    }

    /// Forwards one normalized key for atomic owner-side mode lookup and encoding.
    public func sendKey(_ key: TerminalInputKey, modifiers: TerminalKeyModifiers) {
        guard isTornDown == false else { return }
        host.sendKey(key, modifiers: modifiers)
    }

    /// Forwards paste text so sanitizing and bracket-mode lookup occur on the owner queue.
    public func sendPaste(_ text: String) {
        guard isTornDown == false else { return }
        host.sendPaste(text)
    }

    /// Forwards focus state so the owner gates its report against authoritative mode 1004.
    public func sendFocus(_ focused: Bool) {
        guard isTornDown == false else { return }
        host.sendFocus(focused)
    }

    /// Forwards normalized pointer input without mirroring child modes on the main actor.
    public func sendPointer(_ event: TerminalPointerEvent) {
        guard isTornDown == false else { return }
        host.sendPointer(
            event,
            onPaneMenu: { [weak self] cell in
                Task { @MainActor [weak self] in
                    guard let self, self.isTornDown == false else { return }
                    self.onPaneMenu?(cell)
                }
            },
            onOpenLink: { [weak self] link in
                Task { @MainActor [weak self] in
                    guard let self, self.isTornDown == false else { return }
                    self.onOpenLink?(link)
                }
            }
        )
    }

    /// Clears hover and invalidates a pending link click after pointer exit or invalid geometry.
    public func cancelLinkInteraction() {
        guard isTornDown == false else { return }
        host.cancelLinkInteraction()
    }

    /// Submits signed local row navigation through the host's ordered owner queue.
    public func scroll(byRows rowDelta: Int) {
        guard isTornDown == false, rowDelta != 0 else { return }
        host.scroll(byRows: rowDelta)
    }

    /// Submits a scrollbar top row through the same ordering boundary as output and resize.
    public func scroll(toTopRow row: Int) {
        guard isTornDown == false else { return }
        host.scroll(toTopRow: row)
    }

    /// Returns the local viewport to live-bottom follow.
    public func scrollToBottom() {
        guard isTornDown == false else { return }
        host.scrollToBottom()
    }

    /// Forwards fractional wheel input and gesture boundaries for owner-side routing.
    public func sendWheel(_ event: TerminalWheelEvent) {
        guard isTornDown == false else { return }
        host.sendWheel(event)
    }

    /// Submits each distinct valid grid once, preserving its order relative to input.
    public func setGridDimensions(_ dimensions: TerminalDimensions) {
        guard isTornDown == false, dimensions != lastSubmittedDimensions else { return }
        guard dimensions.columns >= 2, dimensions.rows >= 1 else { return }
        lastSubmittedDimensions = dimensions
        host.resize(dimensions)
    }

    /// Gates planning only; revealing accumulated changes emits one complete current frame.
    public func setVisible(_ visible: Bool) {
        guard isTornDown == false, visible != isVisible else { return }
        isVisible = visible
        if visible { planIfNeeded(cachedTerminal) }
    }

    /// Fences host work and applies the newest state before a synchronous checkpoint read.
    public func synchronizeState() {
        guard isTornDown == false else { return }
        consume(frameState: host.fencedFrameState(), result: nil, transitions: nil)
    }

    /// Fences accepted owner work and freezes the recovery projection before app exit capture.
    public func fenceForApplicationExit() {
        guard isTornDown == false else { return }
        cachedTerminal = host.beginCloseAndSnapshot()
        emitPrimaryHistoryMutationIfNeeded()
        isTornDown = true
        consumeTask?.cancel()
        consumeTask = nil
    }

    /// Returns the latest cached viewport without crossing the host actor boundary.
    public func readViewportText() -> String {
        cachedTerminal.viewportText
    }

    /// Exposes the newest cached row extent and alternate-screen scrollbar availability.
    public var viewportState: TerminalPaneViewportState {
        TerminalPaneViewportState(
            isScrollbarEnabled: cachedTerminal.isAlternateScreenActive == false,
            projection: cachedTerminal.scrollProjection
        )
    }

    /// Returns the latest cached history without crossing the host actor boundary.
    public func readFullHistoryText() -> String {
        cachedTerminal.fullHistoryText
    }

    /// Reflects whether the latest consumed terminal snapshot contains selected text.
    public var hasSelection: Bool {
        cachedTerminal.selectedText != nil
    }

    /// Returns selection from the latest asynchronously consumed terminal snapshot.
    public func readSelectedText() -> String? {
        cachedTerminal.selectedText
    }

    /// Returns the currently hovered target from the latest asynchronously consumed snapshot.
    public func readHoveredLink() -> TerminalHyperlink? {
        cachedTerminal.hoveredLink?.hyperlink
    }

    /// Fences pending pointer work, refreshes cached state, and returns finalized selection text.
    public func readSelectedTextSynchronizing() -> String? {
        guard isTornDown == false else { return nil }
        consume(frameState: host.fencedFrameState(), result: nil, transitions: nil)
        return cachedTerminal.selectedText
    }

    /// Enqueues selection clearing on the sole terminal owner.
    public func clearSelection() {
        guard isTornDown == false else { return }
        host.clearSelection()
    }

    /// Enqueues whole-stream selection on the sole terminal owner.
    public func selectAll() {
        guard isTornDown == false else { return }
        host.selectAll()
    }

    /// Returns primary-screen history for persistence consumers that exclude transient screens.
    public func readPrimaryHistoryText() -> String {
        cachedTerminal.primaryHistoryText
    }

    /// Returns completed child-session evidence without making capture a default app surface.
    #if DANTERM_TERMINAL_CHARACTERIZATION
    public func capturedRecording(test: String) -> NeutralTerminalRecording? {
        makeCapturedRecording(test: test)
    }
    #else
    package func capturedRecording(test: String) -> NeutralTerminalRecording? {
        makeCapturedRecording(test: test)
    }
    #endif

    private func makeCapturedRecording(test: String) -> NeutralTerminalRecording? {
        guard let completedRecordingEvents else { return nil }
        return makeRecording(test: test, events: completedRecordingEvents)
    }

    /// Test harness seam that fences live evidence without changing completion eligibility.
    package func diagnosticCapture(test: String) -> TerminalPaneDiagnosticCapture {
        let state = host.fencedDiagnosticState()
        cachedTerminal = state.frameState.terminal
        return TerminalPaneDiagnosticCapture(
            terminal: state.frameState.terminal,
            recording: makeRecording(test: test, events: neutralEvents(state.transitions)),
            semanticEvents: state.frameState.semanticEvents
        )
    }

    private func makeRecording(
        test: String,
        events: [NeutralTerminalRecordingEvent]
    ) -> NeutralTerminalRecording {
        return NeutralTerminalRecording(
            provenance: .danTerm(test: test),
            initial: .init(
                columns: initialDimensions.columns,
                rows: initialDimensions.rows
            ),
            events: events
        )
    }

    private func neutralEvents(
        _ transitions: [TerminalPTYAppliedTransition]
    ) -> [NeutralTerminalRecordingEvent] {
        transitions.map { transition in
            switch transition {
            case .feed(let bytes): .feed(bytes)
            case .input(let key, let modifiers): .input(key: key, modifiers: modifiers)
            case .paste(let text): .paste(text)
            case .focus(let focused): .focus(focused)
            case .mouse(let event): .mouse(neutralMouseEvent(for: event))
            case .resize(let dimensions): .resize(columns: dimensions.columns, rows: dimensions.rows)
            case .scrollByRows(let rows): .viewport(.byRows(rows))
            case .scrollToTopRow(let row): .viewport(.toTopRow(row))
            case .scrollToBottom: .viewport(.toBottom)
            }
        }
    }

    /// Ends callbacks immediately and lets a host-only detached task finish bounded teardown.
    public func tearDown() {
        guard isTornDown == false else { return }
        cachedTerminal = host.beginCloseAndSnapshot()
        isTornDown = true
        onFrame = nil
        onClipboardWrite = nil
        onSemanticEvents = nil
        onSessionEnded = nil
        onViewportStateChange = nil
        onPrimaryHistoryMutation = nil
        onPaneMenu = nil
        onOpenLink = nil
        let onTeardownCompleted = takeTeardownCompletion()
        consumeTask?.cancel()
        consumeTask = nil

        let host = host
        Task.detached {
            await host.close()
            await onTeardownCompleted?()
        }
    }

    private func consume(
        frameState: TerminalPTYFrameState,
        result: PaneLifecycleResult?,
        transitions: [TerminalPTYAppliedTransition]?
    ) {
        cachedTerminal = frameState.terminal
        emitPrimaryHistoryMutationIfNeeded()
        pendingDamage.formUnion(frameState.damage)
        if let clipboardWrite = frameState.clipboardWrite {
            onClipboardWrite?(clipboardWrite)
        }
        if frameState.semanticEvents.isEmpty == false {
            onSemanticEvents?(frameState.semanticEvents)
        }
        emitViewportStateIfNeeded()
        if case .some(.exited) = result {
            didChildExit = true
        }
        if isVisible { planIfNeeded(frameState.terminal) }
        if let result, didEmitSessionEnded == false {
            didEmitSessionEnded = true
            if let transitions {
                completedRecordingEvents = neutralEvents(transitions)
            }
            takeTeardownCompletion()?()
            onSessionEnded?(result)
        }
    }

    private func emitPrimaryHistoryMutationIfNeeded() {
        guard cachedTerminal.primaryHistoryGeneration != lastPrimaryHistoryGeneration else { return }
        lastPrimaryHistoryGeneration = cachedTerminal.primaryHistoryGeneration
        onPrimaryHistoryMutation?()
    }

    private func emitViewportStateIfNeeded() {
        let state = viewportState
        guard state != lastEmittedViewportState else { return }
        lastEmittedViewportState = state
        onViewportStateChange?(state)
    }

    private func neutralMouseEvent(for event: TerminalPointerEvent) -> NeutralTerminalMouseEvent {
        switch event {
        case let .down(button, column, row, modifiers, clickCount):
            NeutralTerminalMouseEvent(
                action: .down,
                button: button.rawValue + 1,
                column: column,
                row: row,
                modifiers: modifiers,
                clickCount: clickCount
            )
        case let .up(button, column, row, modifiers):
            NeutralTerminalMouseEvent(
                action: .up,
                button: button.rawValue + 1,
                column: column,
                row: row,
                modifiers: modifiers
            )
        case let .move(column, row, modifiers):
            NeutralTerminalMouseEvent(
                action: .move,
                column: column,
                row: row,
                modifiers: modifiers
            )
        }
    }

    /// Test support for whole-value recording equality after a synchronization fence.
    package func terminalSnapshot() -> Terminal {
        cachedTerminal
    }

    private func takeTeardownCompletion() -> (@MainActor @Sendable () -> Void)? {
        let completion = onTeardownCompleted
        onTeardownCompleted = nil
        return completion
    }

    private func planIfNeeded(_ terminal: Terminal) {
        guard pendingDamage != .none else { return }
        guard terminal != lastPlannedTerminal else { return }
        let presentation = terminal.presentation
        guard presentation.isSynchronizedOutputActive == false || didChildExit else { return }
        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: presentation.isCursorVisible,
                cursorShape: presentation.cursorShape
            )
        )
        lastPlannedTerminal = terminal
        currentPlan = plan
        currentDamage = pendingDamage
        let frame = TerminalPaneFrame(plan: plan, damage: pendingDamage)
        pendingDamage = .none
        onFrame?(frame)
    }
}
