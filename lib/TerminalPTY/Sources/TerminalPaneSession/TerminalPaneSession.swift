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

/// Owns one headless terminal pane while keeping host bytes and actor state behind the adapter.
@MainActor
public final class TerminalPaneSessionController {
    private let host: TerminalPTYHost
    private var consumeTask: Task<Void, Never>?
    private var cachedTerminal: Terminal
    private let initialDimensions: TerminalDimensions
    private var lastPlannedTerminal: Terminal?
    private var lastSubmittedDimensions: TerminalDimensions
    private var isVisible: Bool
    private var isTornDown = false
    private var didChildExit = false
    private var didEmitSessionEnded = false
    private var completedRecordingEvents: [NeutralTerminalRecordingEvent]?
    private var lastEmittedViewportState: TerminalPaneViewportState?

    /// Process-lifetime access retained by the backend until this host finishes teardown.
    public let terminationHandle: TerminalPaneTerminationHandle

    /// Receives complete immutable frames on the main actor while the pane is visible.
    public var onPlan: ((RenderFramePlan) -> Void)?

    /// Receives the first child-originated lifecycle result on the main actor.
    public var onSessionEnded: ((PaneLifecycleResult) -> Void)?

    /// Receives scrollbar-relevant state only when its projection or screen availability changes.
    public var onViewportStateChange: ((TerminalPaneViewportState) -> Void)?

    /// Releases the backend registry entry only after this host's native teardown completes.
    public var onTeardownCompleted: (@MainActor @Sendable () -> Void)?

    /// The latest complete plan delivered for the visible pane, retained for scale-only redraws.
    public private(set) var currentPlan: RenderFramePlan?

    /// Creates and starts the sole PTY host owned by this pane controller.
    public convenience init(
        configuration: TerminalPaneLaunchConfiguration,
        bootstrapExecutable: String,
        isVisible: Bool = true
    ) throws {
        let host = try TerminalPTYHost(
            initialDimensions: configuration.initialDimensions,
            bootstrapExecutable: bootstrapExecutable
        )
        self.init(host: host, launchInput: configuration.launchInput, isVisible: isVisible)
    }

    /// Enables transition capture only for package tests or characterization app builds.
    #if DANTERM_TERMINAL_CHARACTERIZATION
    public convenience init(
        configuration: TerminalPaneLaunchConfiguration,
        bootstrapExecutable: String,
        isVisible: Bool = true,
        captureTransitions: Bool
    ) throws {
        let host = try TerminalPTYHost(
            initialDimensions: configuration.initialDimensions,
            bootstrapExecutable: bootstrapExecutable,
            captureTransitions: captureTransitions
        )
        self.init(host: host, launchInput: configuration.launchInput, isVisible: isVisible)
    }
    #else
    package convenience init(
        configuration: TerminalPaneLaunchConfiguration,
        bootstrapExecutable: String,
        isVisible: Bool = true,
        captureTransitions: Bool
    ) throws {
        let host = try TerminalPTYHost(
            initialDimensions: configuration.initialDimensions,
            bootstrapExecutable: bootstrapExecutable,
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
        cachedTerminal = host.fencedSnapshot()
        initialDimensions = launchInput.initialDimensions
        lastPlannedTerminal = cachedTerminal
        lastSubmittedDimensions = launchInput.initialDimensions
        self.isVisible = isVisible
        lastEmittedViewportState = viewportState

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
                let snapshot = await host.snapshot()
                guard let self, self.isTornDown == false else { break }
                self.consume(snapshot: snapshot, result: result, transitions: transitions)
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

    /// Carries semantic wheel rows for owner-side screen routing and cursor-mode encoding.
    public func sendWheel(rows: Int) {
        guard isTornDown == false, rows != 0 else { return }
        host.sendWheel(.init(rowDelta: rows))
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
        consume(snapshot: host.fencedSnapshot(), result: nil, transitions: nil)
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
        return NeutralTerminalRecording(
            provenance: .danTerm(test: test),
            initial: .init(
                columns: initialDimensions.columns,
                rows: initialDimensions.rows
            ),
            events: completedRecordingEvents
        )
    }

    /// Ends callbacks immediately and lets a host-only detached task finish bounded teardown.
    public func tearDown() {
        guard isTornDown == false else { return }
        cachedTerminal = host.beginCloseAndSnapshot()
        isTornDown = true
        onPlan = nil
        onSessionEnded = nil
        onViewportStateChange = nil
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
        snapshot: Terminal,
        result: PaneLifecycleResult?,
        transitions: [TerminalPTYAppliedTransition]?
    ) {
        cachedTerminal = snapshot
        emitViewportStateIfNeeded()
        if case .some(.exited) = result {
            didChildExit = true
        }
        if isVisible { planIfNeeded(snapshot) }
        if let result, didEmitSessionEnded == false {
            didEmitSessionEnded = true
            if let transitions {
                completedRecordingEvents = transitions.map { transition in
                    switch transition {
                    case .feed(let bytes):
                        .feed(bytes)
                    case .input(let key, let modifiers):
                        .input(key: key, modifiers: modifiers)
                    case .paste(let text):
                        .paste(text)
                    case .focus(let focused):
                        .focus(focused)
                    case .resize(let dimensions):
                        .resize(columns: dimensions.columns, rows: dimensions.rows)
                    case .scrollByRows(let rows):
                        .viewport(.byRows(rows))
                    case .scrollToTopRow(let row):
                        .viewport(.toTopRow(row))
                    case .scrollToBottom:
                        .viewport(.toBottom)
                    }
                }
            }
            takeTeardownCompletion()?()
            onSessionEnded?(result)
        }
    }

    private func emitViewportStateIfNeeded() {
        let state = viewportState
        guard state != lastEmittedViewportState else { return }
        lastEmittedViewportState = state
        onViewportStateChange?(state)
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
        guard terminal != lastPlannedTerminal else { return }
        let presentation = terminal.presentation
        guard presentation.isSynchronizedOutputActive == false || didChildExit else { return }
        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: presentation.isCursorVisible
            )
        )
        lastPlannedTerminal = terminal
        currentPlan = plan
        onPlan?(plan)
    }
}
