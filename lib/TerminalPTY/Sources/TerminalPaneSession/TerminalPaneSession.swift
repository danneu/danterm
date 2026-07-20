// Main-actor pane policy that turns one PTY host's conflated updates into cached
// inspection text, complete render plans, and one child-ended notification.
import PaneLifecycle
import TerminalCore
import TerminalPTYHost
import TerminalRenderPlanning

/// Owns one headless terminal pane while keeping host bytes and actor state behind the adapter.
@MainActor
public final class TerminalPaneSessionController {
    private let host: TerminalPTYHost
    private var consumeTask: Task<Void, Never>?
    private var cachedTerminal: Terminal
    private var lastPlannedTerminal: Terminal?
    private var lastSubmittedDimensions: TerminalDimensions
    private var isVisible: Bool
    private var isTornDown = false
    private var didEmitSessionEnded = false

    /// Receives complete immutable frames on the main actor while the pane is visible.
    public var onPlan: ((RenderFramePlan) -> Void)?

    /// Receives the first child-originated lifecycle result on the main actor.
    public var onSessionEnded: ((PaneLifecycleResult) -> Void)?

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

    init(
        host: TerminalPTYHost,
        launchInput: LaunchPolicyInput,
        isVisible: Bool = true
    ) {
        self.host = host
        cachedTerminal = host.fencedSnapshot()
        lastPlannedTerminal = cachedTerminal
        lastSubmittedDimensions = launchInput.initialDimensions
        self.isVisible = isVisible

        host.submitStart(launchInput)
        consumeTask = Task { [weak self, host] in
            for await _ in host.updates {
                guard Task.isCancelled == false else { break }
                let snapshot = await host.snapshot()
                let result = await host.result()
                guard let self, self.isTornDown == false else { break }
                self.consume(snapshot: snapshot, result: result)
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

    /// Encodes and sends one key from the package-neutral input vocabulary when mapped.
    public func sendKey(_ key: TerminalInputKey, modifiers: TerminalKeyModifiers) {
        guard let bytes = encodeTerminalKey(key, modifiers: modifiers) else { return }
        send(bytes)
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
        consume(snapshot: host.fencedSnapshot(), result: nil)
    }

    /// Returns the latest cached viewport without crossing the host actor boundary.
    public func readViewportText() -> String {
        cachedTerminal.screenText
    }

    /// Returns the latest cached history without crossing the host actor boundary.
    public func readFullHistoryText() -> String {
        cachedTerminal.fullHistoryText
    }

    /// Ends callbacks immediately and lets a host-only detached task finish bounded teardown.
    public func tearDown() {
        guard isTornDown == false else { return }
        cachedTerminal = host.beginCloseAndSnapshot()
        isTornDown = true
        onPlan = nil
        onSessionEnded = nil
        consumeTask?.cancel()
        consumeTask = nil

        let host = host
        Task.detached {
            await host.close()
        }
    }

    private func consume(snapshot: Terminal, result: PaneLifecycleResult?) {
        cachedTerminal = snapshot
        if isVisible { planIfNeeded(snapshot) }
        if let result, didEmitSessionEnded == false {
            didEmitSessionEnded = true
            onSessionEnded?(result)
        }
    }

    private func planIfNeeded(_ terminal: Terminal) {
        guard terminal != lastPlannedTerminal else { return }
        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(theme: .dark, isCursorVisible: true)
        )
        lastPlannedTerminal = terminal
        currentPlan = plan
        onPlan?(plan)
    }
}
