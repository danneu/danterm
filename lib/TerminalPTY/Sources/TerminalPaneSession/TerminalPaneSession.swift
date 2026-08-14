// Main-actor pane policy that turns one PTY host's conflated updates into cached
// inspection text, complete render plans, child-ended evidence, and one exit notification.
import Dispatch
import Foundation
import PaneProcessLifecycle
import Synchronization
import TerminalCore
import TerminalCoreRecording
import TerminalPTYHost
import TerminalRenderPlanning

/// Owns the controller's sole main-queue crossing so teardown can stop every delivery at once.
private final class TerminalPaneDeliveryBoundary: Sendable {
    private struct State {
        var isUpdateScheduled = false
        var isStopped = false
        /// Signals merged while a main hop is already scheduled, so coalescing
        /// the hop never drops an urgent payload.
        var pendingSignal: TerminalPTYUpdateSignal?
    }

    private let state = Mutex(State())

    func scheduleUpdate(
        _ signal: TerminalPTYUpdateSignal,
        _ delivery: @escaping @MainActor @Sendable (TerminalPTYUpdateSignal) -> Void
    ) {
        let shouldSchedule = state.withLock { state in
            guard state.isStopped == false else { return false }
            state.pendingSignal = state.pendingSignal.map { $0.merging(newer: signal) } ?? signal
            guard state.isUpdateScheduled == false else { return false }
            state.isUpdateScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pending: TerminalPTYUpdateSignal? = self.state.withLock { state in
                state.isUpdateScheduled = false
                guard state.isStopped == false else { return nil }
                let signal = state.pendingSignal
                state.pendingSignal = nil
                return signal
            }
            // Nil means a synchronous fence already flushed this hop's payload.
            guard let pending else { return }
            MainActor.assumeIsolated {
                delivery(pending)
            }
        }
    }

    /// Hands a not-yet-delivered payload to a synchronous fence, so a checkpoint
    /// consume cannot overtake urgent work already signaled toward the main hop.
    func takePendingSignal() -> TerminalPTYUpdateSignal? {
        state.withLock { state in
            let signal = state.pendingSignal
            state.pendingSignal = nil
            return signal
        }
    }

    func enqueue(_ delivery: @escaping @MainActor @Sendable () -> Void) {
        let shouldEnqueue = state.withLock { $0.isStopped == false }
        guard shouldEnqueue else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shouldDeliver = self.state.withLock { $0.isStopped == false }
            guard shouldDeliver else { return }
            MainActor.assumeIsolated {
                delivery()
            }
        }
    }

    func stop() {
        state.withLock { state in
            state.isStopped = true
        }
    }
}

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

/// Pairs one cumulative fence wait with the number of entries that produced it.
public struct TerminalPaneFenceMeasurement: Equatable, Sendable {
    /// Cumulative caller-side wait measured on the monotonic uptime clock.
    public private(set) var waitNanoseconds: UInt64
    /// Number of fence entries included in `waitNanoseconds`.
    public private(set) var count: UInt64

    /// Creates one cumulative wait/count pair for sampling or delta calculation.
    public init(waitNanoseconds: UInt64 = 0, count: UInt64 = 0) {
        self.waitNanoseconds = waitNanoseconds
        self.count = count
    }

    mutating func record(waitNanoseconds: UInt64) {
        self.waitNanoseconds += waitNanoseconds
        count += 1
    }

    fileprivate func subtracting(_ baseline: Self) -> Self? {
        guard waitNanoseconds >= baseline.waitNanoseconds,
              count >= baseline.count
        else { return nil }
        return Self(
            waitNanoseconds: waitNanoseconds - baseline.waitNanoseconds,
            count: count - baseline.count
        )
    }
}

/// Keeps attributed controller totals beside the host's independent raw entry census.
public struct TerminalPaneFenceMetrics: Equatable, Sendable {
    /// Frame-delivery and consume fences.
    public private(set) var delivery = TerminalPaneFenceMeasurement()
    /// Synchronous state and selection-read fences.
    public private(set) var checkpoint = TerminalPaneFenceMeasurement()
    /// Application-exit and pane teardown fences.
    public private(set) var teardown = TerminalPaneFenceMeasurement()
    /// Initial frame-state and update-handler installation fences.
    public private(set) var initialization = TerminalPaneFenceMeasurement()
    /// Failure-evidence capture fences.
    public private(set) var diagnostic = TerminalPaneFenceMeasurement()
    /// Host-side raw production entries observed after the latest controller fence.
    public private(set) var hostEntryCount: UInt64 = 0

    init(
        delivery: TerminalPaneFenceMeasurement = .init(),
        checkpoint: TerminalPaneFenceMeasurement = .init(),
        teardown: TerminalPaneFenceMeasurement = .init(),
        initialization: TerminalPaneFenceMeasurement = .init(),
        diagnostic: TerminalPaneFenceMeasurement = .init(),
        hostEntryCount: UInt64 = 0
    ) {
        self.delivery = delivery
        self.checkpoint = checkpoint
        self.teardown = teardown
        self.initialization = initialization
        self.diagnostic = diagnostic
        self.hostEntryCount = hostEntryCount
    }

    /// Combines every attributed kind without losing the count paired with its wait.
    public var total: TerminalPaneFenceMeasurement {
        TerminalPaneFenceMeasurement(
            waitNanoseconds: delivery.waitNanoseconds
                + checkpoint.waitNanoseconds
                + teardown.waitNanoseconds
                + initialization.waitNanoseconds
                + diagnostic.waitNanoseconds,
            count: delivery.count
                + checkpoint.count
                + teardown.count
                + initialization.count
                + diagnostic.count
        )
    }

    fileprivate mutating func record(
        kind: TerminalPaneFenceKind,
        waitNanoseconds: UInt64,
        hostEntryCount: UInt64
    ) {
        switch kind {
        case .delivery:
            delivery.record(waitNanoseconds: waitNanoseconds)
        case .checkpoint:
            checkpoint.record(waitNanoseconds: waitNanoseconds)
        case .teardown:
            teardown.record(waitNanoseconds: waitNanoseconds)
        case .initialization:
            initialization.record(waitNanoseconds: waitNanoseconds)
        case .diagnostic:
            diagnostic.record(waitNanoseconds: waitNanoseconds)
        }
        self.hostEntryCount = hostEntryCount
    }

    func subtracting(_ baseline: Self) -> Self? {
        guard let delivery = delivery.subtracting(baseline.delivery),
              let checkpoint = checkpoint.subtracting(baseline.checkpoint),
              let teardown = teardown.subtracting(baseline.teardown),
              let initialization = initialization.subtracting(baseline.initialization),
              let diagnostic = diagnostic.subtracting(baseline.diagnostic),
              hostEntryCount >= baseline.hostEntryCount
        else { return nil }
        return Self(
            delivery: delivery,
            checkpoint: checkpoint,
            teardown: teardown,
            initialization: initialization,
            diagnostic: diagnostic,
            hostEntryCount: hostEntryCount - baseline.hostEntryCount
        )
    }
}

/// Gives each main-actor owner-queue fence exactly one accounting category.
private enum TerminalPaneFenceKind {
    case delivery
    case checkpoint
    case teardown
    case initialization
    case diagnostic
}

/// Owns one headless terminal pane while keeping host bytes and actor state behind the adapter.
@MainActor
public final class TerminalPaneSessionController {
    private let host: TerminalPTYHost
    private let deliveryBoundary = TerminalPaneDeliveryBoundary()
    private var cachedTerminal: Terminal
    private let initialDimensions: TerminalDimensions
    /// This pane's own frame stream, so undamaged rows are copied from the frame
    /// this controller planned last rather than re-inspected. One planner per
    /// controller is what keeps the retained rows and `pendingDamage` in lineage.
    private var framePlanner = PaneFramePlanner()
    private var pendingDamage = TerminalDamage.none
    private var lastSubmittedDimensions: TerminalDimensions
    private var isVisible: Bool
    private var isRenderingAvailable = true
    private var isTornDown = false
    private var didChildExit = false
    private var didEmitSessionEnded = false
    private var didEmitProcessStarted = false
    package var didReportProcessStartedForTesting: Bool { didEmitProcessStarted }
    private var completedRecordingEvents: [NeutralTerminalRecordingEvent]?
    private var lastEmittedViewportState: TerminalPaneViewportState?
    private var lastEmittedSearchStatus: TerminalSearchStatus?
    private var lastPrimaryHistoryGeneration: UInt64
    private let fenceClock: () -> UInt64
    /// Arms the deferred-fence one-shot and returns its cancellation. Injected
    /// so the deadline is deterministic under test; production uses a cancellable
    /// main-queue work item.
    private let deadlineTimer: @MainActor (
        UInt64,
        @escaping @MainActor @Sendable () -> Void
    ) -> () -> Void
    /// The consumer's publish deadline (research 33/D8): no delivery fence runs
    /// before this uptime instant, so a flooding producer is bounded by display
    /// demand while a paced one never waits. Zero means fence immediately.
    private var earliestNextFenceNanoseconds: UInt64 = 0
    /// True between a deferred update signal and the fence that drains it; the
    /// one-shot timer exists exactly while this is set.
    private var isAwaitingDeferredFence = false
    private var cancelDeferredFence: (() -> Void)?

    /// Supplies the owning display's refresh interval for the publish deadline.
    /// The interval must come from the pane's actual display, not an assumed
    /// 120 Hz, or an external 60 Hz monitor pays double the fences (33/D8); the
    /// default stands in only until the view installs the real provider.
    public var displayRefreshIntervalNanoseconds: () -> UInt64 = { 8_333_333 }

    /// Theme retained independently of terminal bytes so configuration can repaint immediately.
    public private(set) var renderTheme: RenderTheme

    /// Process-lifetime access retained by the backend until this host finishes teardown.
    public let terminationHandle: TerminalPaneTerminationHandle

    /// Receives complete retained frames with coalesced logical damage on the main actor.
    public var onFrame: ((TerminalPaneFrame) -> Void)?

    /// Delivers completed clipboard writes before any visibility or render-planning gate.
    public var onClipboardWrite: ((String) -> Void)?

    /// Delivers ordered terminal semantics before visibility, rendering, or exit callbacks.
    public var onSemanticEvents: (([TerminalSemanticEvent]) -> Void)?

    /// Receives the first child-originated lifecycle result on the main actor.
    public var onSessionEnded: ((PaneProcessLifecycleResult) -> Void)?

    /// Reports the one transition from spawning to a running child process.
    public var onProcessStarted: (() -> Void)?

    /// Receives scrollbar-relevant state only when its projection or screen availability changes.
    public var onViewportStateChange: ((TerminalPaneViewportState) -> Void)?

    /// Signals primary-history changes without materializing text until recovery reads it.
    public var onPrimaryHistoryMutation: (() -> Void)?

    /// Receives an uncaptured pane-menu request only after its pointer gesture completes.
    public var onPaneMenu: ((TerminalViewportCell) -> Void)?

    /// Receives a click-time-revalidated HTTP(S) target on the main actor.
    public var onOpenLink: ((TerminalHyperlink) -> Void)?

    /// Receives the non-empty text a completed selection gesture held at its release.
    ///
    /// Presence is the copy-on-select gate: with no handler installed the owner is never
    /// asked to extract selection text, so the option being off costs nothing on the pointer
    /// path. The string arrives already captured, so the handler must write it as given
    /// rather than read the selection again.
    public var onSelectionCopy: ((String) -> Void)?

    /// Receives search status when a consumed terminal update changes it, including output.
    public var onSearchStatus: ((TerminalSearchStatus?) -> Void)?

    /// The latest complete plan delivered for the visible pane, retained for scale-only redraws.
    public private(set) var currentPlan: RenderFramePlan?

    /// Damage paired with `currentPlan` at its most recent publication.
    public private(set) var currentDamage: TerminalDamage?

    /// Cumulative owner-queue fence waits attributed by purpose and cross-checked by the host.
    public private(set) var fenceMetrics = TerminalPaneFenceMetrics()

    /// Per-delivery fence wait flushed into the most recently published frame.
    public private(set) var lastFenceStallNanoseconds: UInt64 = 0

    /// Delivery wait not yet charged because no frame has been accepted for publication.
    private(set) var unflushedDeliveryFenceWaitNanoseconds: UInt64 = 0

    #if DANTERM_TERMINAL_BENCHMARK
    /// Cost of the `planFrame` call that produced `currentPlan`, for the benchmark
    /// observer to read when the resulting frame is published.
    ///
    /// Planning runs here on the PTY-output path, not inside `draw(_:)`, so the
    /// harness's draw timer cannot see it. Exposing the measurement at its source
    /// is what lets a planner change be attributed at all. Benchmark builds only.
    public private(set) var lastPlanDurationNanoseconds: UInt64 = 0

    /// Thread CPU time spent inside the same `planFrame` bracket, for separating "the planner
    /// did more work" from "the planner was slowed down". Wall time inflates when planning runs
    /// concurrently with a drain on another core; thread CPU time does not, so a wall rise with
    /// flat thread CPU is contention, not work (`research/33/F16`'s open churn question).
    public private(set) var lastPlanThreadCPUNanoseconds: UInt64 = 0

    #endif

    /// The one host-construction recipe behind every convenience initializer, so a new host
    /// parameter is threaded once rather than through three near-identical bodies.
    private static func makeHost(
        configuration: TerminalPaneLaunchConfiguration,
        bootstrapExecutable: String,
        machineHostname: String?,
        theme: RenderTheme,
        captureTransitions: Bool
    ) throws -> TerminalPTYHost {
        try TerminalPTYHost(
            initialDimensions: configuration.initialDimensions,
            bootstrapExecutable: bootstrapExecutable,
            machineHostname: machineHostname,
            programVersion: configuration.terminalProgramVersion,
            defaultColors: theme.defaultColors,
            captureTransitions: captureTransitions
        )
    }

    /// Creates and starts the sole PTY host owned by this pane controller.
    public convenience init(
        configuration: TerminalPaneLaunchConfiguration,
        bootstrapExecutable: String,
        isVisible: Bool = true,
        machineHostname: String? = MachineHostname.posix,
        theme: RenderTheme = .dark
    ) throws {
        self.init(
            host: try Self.makeHost(
                configuration: configuration,
                bootstrapExecutable: bootstrapExecutable,
                machineHostname: machineHostname,
                theme: theme,
                captureTransitions: false
            ),
            launchInput: configuration.launchInput,
            isVisible: isVisible,
            theme: theme
        )
    }

    /// Enables transition capture only for package tests or characterization app builds.
    #if DANTERM_TERMINAL_CHARACTERIZATION
    public convenience init(
        configuration: TerminalPaneLaunchConfiguration,
        bootstrapExecutable: String,
        isVisible: Bool = true,
        machineHostname: String? = MachineHostname.posix,
        theme: RenderTheme = .dark,
        captureTransitions: Bool
    ) throws {
        self.init(
            host: try Self.makeHost(
                configuration: configuration,
                bootstrapExecutable: bootstrapExecutable,
                machineHostname: machineHostname,
                theme: theme,
                captureTransitions: captureTransitions
            ),
            launchInput: configuration.launchInput,
            isVisible: isVisible,
            theme: theme
        )
    }
    #else
    package convenience init(
        configuration: TerminalPaneLaunchConfiguration,
        bootstrapExecutable: String,
        isVisible: Bool = true,
        machineHostname: String? = MachineHostname.posix,
        theme: RenderTheme = .dark,
        captureTransitions: Bool
    ) throws {
        self.init(
            host: try Self.makeHost(
                configuration: configuration,
                bootstrapExecutable: bootstrapExecutable,
                machineHostname: machineHostname,
                theme: theme,
                captureTransitions: captureTransitions
            ),
            launchInput: configuration.launchInput,
            isVisible: isVisible,
            theme: theme
        )
    }
    #endif

    init(
        host: TerminalPTYHost,
        launchInput: LaunchPolicyInput,
        isVisible: Bool = true,
        theme: RenderTheme = .dark,
        fenceClock: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        deadlineTimer: @escaping @MainActor (
            UInt64,
            @escaping @MainActor @Sendable () -> Void
        ) -> () -> Void = { delayNanoseconds, fire in
            let work = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .nanoseconds(Int(delayNanoseconds)),
                execute: work
            )
            return { work.cancel() }
        }
    ) {
        var initialMetrics = TerminalPaneFenceMetrics()
        let initialFence = Self.performAccountedFence(
            host: host,
            kind: .initialization,
            operation: .frameState,
            clock: fenceClock,
            metrics: &initialMetrics
        )
        guard case .frameState(let initialFrameState) = initialFence.output else {
            preconditionFailure("frame-state fence returned the wrong payload")
        }

        self.host = host
        self.fenceClock = fenceClock
        self.deadlineTimer = deadlineTimer
        renderTheme = theme
        fenceMetrics = initialMetrics
        terminationHandle = TerminalPaneTerminationHandle(host: host)
        cachedTerminal = initialFrameState.terminal
        cachedTerminal.setDefaultColors(theme.defaultColors)
        host.setDefaultColors(theme.defaultColors)
        lastPrimaryHistoryGeneration = initialFrameState.terminal.primaryHistoryGeneration
        initialDimensions = launchInput.initialDimensions
        pendingDamage = initialFrameState.damage
        lastSubmittedDimensions = launchInput.initialDimensions
        self.isVisible = isVisible
        lastEmittedViewportState = viewportState
        lastEmittedSearchStatus = cachedTerminal.searchStatus

        if isVisible { planIfNeeded(cachedTerminal) }

        let deliveryBoundary = deliveryBoundary
        _ = performAccountedFence(
            kind: .initialization,
            operation: .installUpdateHandler { signal in
                deliveryBoundary.scheduleUpdate(signal) { [weak self] merged in
                    guard let self else { return }
                    self.receiveUpdateSignal(merged)
                }
            }
        )
        host.submitStart(launchInput)
    }

    /// The main-actor end of the host's update signal: delivers the urgent
    /// payload immediately, then fences now or at the publish deadline. This is
    /// where 33/D8's bound lives -- the drain and parse never throttle, only
    /// this fence is deferred, and damage keeps accumulating in the engine's
    /// own damage value until the deadline drains it.
    private func receiveUpdateSignal(_ signal: TerminalPTYUpdateSignal) {
        guard isTornDown == false else { return }
        deliverUrgent(signal)
        // A child exit is consumed immediately: the result, the final frame,
        // and the session-ended callback must never wait on a flood's timer.
        if signal.result != nil {
            consumeHostUpdate(host)
            return
        }
        let now = fenceClock()
        if now >= earliestNextFenceNanoseconds {
            consumeHostUpdate(host)
            return
        }
        guard isAwaitingDeferredFence == false else { return }
        isAwaitingDeferredFence = true
        armDeferredFence(now: now)
    }

    private func deliverUrgent(_ signal: TerminalPTYUpdateSignal) {
        if signal.processStarted, didEmitProcessStarted == false {
            didEmitProcessStarted = true
            onProcessStarted?()
        }
        if let clipboardWrite = signal.clipboardWrite {
            onClipboardWrite?(clipboardWrite)
        }
        if signal.semanticEvents.isEmpty == false {
            onSemanticEvents?(signal.semanticEvents)
        }
        if signal.primaryHistoryGeneration > lastPrimaryHistoryGeneration {
            lastPrimaryHistoryGeneration = signal.primaryHistoryGeneration
            onPrimaryHistoryMutation?()
        }
    }

    private func armDeferredFence(now: UInt64) {
        cancelDeferredFence = deadlineTimer(earliestNextFenceNanoseconds - now) { [weak self] in
            self?.deferredFenceElapsed()
        }
    }

    private func deferredFenceElapsed() {
        cancelDeferredFence = nil
        guard isTornDown == false, isAwaitingDeferredFence else { return }
        let now = fenceClock()
        // A checkpoint fence advanced the deadline underneath the armed timer;
        // re-arm for the remainder rather than fencing early or dropping the
        // pending work.
        if now < earliestNextFenceNanoseconds {
            armDeferredFence(now: now)
            return
        }
        consumeHostUpdate(host)
    }

    private func cancelDeferredFenceIfArmed() {
        isAwaitingDeferredFence = false
        cancelDeferredFence?()
        cancelDeferredFence = nil
    }

    private func consumeHostUpdate(_ host: TerminalPTYHost) {
        guard isTornDown == false else { return }
        // Drained synchronously: damage handoff and `consume` stay in one
        // main-actor step, so a checkpoint fence cannot strand moved rows.
        let fence = performAccountedFence(kind: .delivery, operation: .consumptionState)
        guard case .consumptionState(
            let frameState,
            let result,
            let transitions
        ) = fence else {
            preconditionFailure("consumption fence returned the wrong payload")
        }
        consume(
            frameState: frameState,
            result: result,
            transitions: transitions
        )
    }

    /// Test seam for consuming a synchronously injected host update without yielding main.
    package func consumePendingHostUpdateForTesting() {
        consumeHostUpdate(host)
    }

    /// Sends committed UTF-8 text through the host's shared ordered submission queue.
    ///
    /// Every submission here carries an `origin`: when the event that produced these bytes
    /// occurred, on `DispatchTime`'s scale. Nil means the bytes originated at the pane itself
    /// and have no earlier moment to report.
    ///
    /// The parameter takes no default on purpose. Nil is a claim about the bytes, not an
    /// absence of information, so a call site that forgot to thread its event time would
    /// otherwise assert that claim silently -- and a tape would under-report the app-owned
    /// span between the event and the completed write, which is the one thing it exists to
    /// measure. Stating `origin: nil` is how a caller says it genuinely has no earlier moment.
    public func sendText(
        _ text: String,
        origin: UInt64?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        send(Array(text.utf8), origin: origin, onCompletion: onCompletion)
    }

    /// Sends already encoded terminal bytes without introducing an ordering-opaque Task.
    public func send(
        _ bytes: [UInt8],
        origin: UInt64?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        guard isTornDown == false else {
            Self.deliverInputCompletion(onCompletion, .rejected(.processEnded))
            return
        }
        host.send(bytes, origin: origin) { result in
            Self.deliverInputCompletion(onCompletion, result)
        }
    }

    /// Forwards one normalized key for atomic owner-side mode lookup and encoding.
    public func sendKey(
        _ key: TerminalInputKey,
        modifiers: TerminalKeyModifiers,
        origin: UInt64?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        guard isTornDown == false else {
            Self.deliverInputCompletion(onCompletion, .rejected(.processEnded))
            return
        }
        host.sendKey(key, modifiers: modifiers, origin: origin) { result in
            Self.deliverInputCompletion(onCompletion, result)
        }
    }

    /// Forwards paste text so sanitizing and bracket-mode lookup occur on the owner queue.
    public func sendPaste(
        _ text: String,
        origin: UInt64?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        guard isTornDown == false else {
            Self.deliverInputCompletion(onCompletion, .rejected(.processEnded))
            return
        }
        host.sendPaste(text, origin: origin) { result in
            Self.deliverInputCompletion(onCompletion, result)
        }
    }

    nonisolated private static func deliverInputCompletion(
        _ completion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void,
        _ result: PaneInputSubmissionResult
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { completion(result) }
        }
    }

    /// Forwards focus state so the owner gates its report against authoritative mode 1004.
    public func sendFocus(_ focused: Bool, origin: UInt64?) {
        guard isTornDown == false else { return }
        host.sendFocus(focused, origin: origin)
    }

    /// Forwards normalized pointer input without mirroring child modes on the main actor.
    public func sendPointer(_ event: TerminalPointerEvent, origin: UInt64?) {
        guard isTornDown == false else { return }
        let deliveryBoundary = deliveryBoundary
        // Resolved at submission rather than at delivery, so the owner is handed no
        // extraction work at all while copy-on-select is off.
        var onSelectionCompleted: (@Sendable (String) -> Void)?
        if onSelectionCopy != nil {
            onSelectionCompleted = { text in
                deliveryBoundary.enqueue { [weak self] in
                    guard let self, self.isTornDown == false else { return }
                    self.onSelectionCopy?(text)
                }
            }
        }
        host.sendPointer(
            event,
            origin: origin,
            onPaneMenu: { [weak self] cell in
                deliveryBoundary.enqueue { [weak self] in
                    guard let self, self.isTornDown == false else { return }
                    self.onPaneMenu?(cell)
                }
            },
            onOpenLink: { [weak self] link in
                deliveryBoundary.enqueue { [weak self] in
                    guard let self, self.isTornDown == false else { return }
                    self.onOpenLink?(link)
                }
            },
            onSelectionCompleted: onSelectionCompleted
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
    public func sendWheel(
        _ event: TerminalWheelEvent,
        origin: UInt64?,
        onCompletion: @escaping @MainActor @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        guard isTornDown == false else {
            Self.deliverInputCompletion(onCompletion, .rejected(.processEnded))
            return
        }
        host.sendWheel(event, origin: origin) { result in
            Self.deliverInputCompletion(onCompletion, result)
        }
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
        if visible, isRenderingAvailable { planIfNeeded(cachedTerminal) }
    }

    /// Suspends presentation without stopping PTY, terminal, semantic, or recovery updates.
    public func setRenderingAvailable(_ available: Bool) {
        guard isTornDown == false, available != isRenderingAvailable else { return }
        isRenderingAvailable = available
        guard available else { return }
        pendingDamage.formUnion(.full)
        let fence = performAccountedFence(kind: .checkpoint, operation: .frameState)
        guard case .frameState(let frameState) = fence else {
            preconditionFailure("frame-state fence returned the wrong payload")
        }
        consume(frameState: frameState, result: nil, transitions: nil)
    }

    /// Applies one complete theme, deferring its full repaint through existing visibility gates.
    public func setTheme(_ theme: RenderTheme) {
        guard isTornDown == false, theme != renderTheme else { return }
        renderTheme = theme
        cachedTerminal.setDefaultColors(theme.defaultColors)
        host.setDefaultColors(theme.defaultColors)
        pendingDamage.formUnion(.full)
        if isVisible, isRenderingAvailable { planIfNeeded(cachedTerminal) }
    }

    /// Fences host work and applies the newest state before a synchronous checkpoint read.
    public func synchronizeState() {
        guard isTornDown == false else { return }
        let fence = performAccountedFence(kind: .checkpoint, operation: .frameState)
        guard case .frameState(let frameState) = fence else {
            preconditionFailure("frame-state fence returned the wrong payload")
        }
        consume(frameState: frameState, result: nil, transitions: nil)
    }

    /// Fences accepted owner work and freezes the recovery projection before app exit capture.
    public func fenceForApplicationExit() {
        guard stopDeliveryAndCacheFinalTerminal() else { return }
        emitPrimaryHistoryMutationIfNeeded()
        isTornDown = true
    }

    /// The order-sensitive prefix both pane-ending entry points share: stop delivery, take the
    /// one close fence, cache the terminal it hands back. Returns false when the pane has
    /// already ended so the caller's distinct tail is skipped with it.
    ///
    /// `isTornDown` deliberately stays with the callers rather than moving in here.
    /// `fenceForApplicationExit` has to emit its primary-history mutation before setting the
    /// flag, because that callback re-enters the controller through a path gated on it.
    private func stopDeliveryAndCacheFinalTerminal() -> Bool {
        guard isTornDown == false else { return false }
        cancelDeferredFenceIfArmed()
        deliveryBoundary.stop()
        let fence = performAccountedFence(kind: .teardown, operation: .beginCloseAndSnapshot)
        guard case .closeSnapshot(let terminal) = fence else {
            preconditionFailure("close fence returned the wrong payload")
        }
        cachedTerminal = terminal
        return true
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

    /// The cached snapshot's absolute (eviction-corrected) viewport top row, so the
    /// delivery-shape sampler can read scrolled lines per publish as a delta.
    public var absoluteViewportTopRow: Int {
        cachedTerminal.absoluteViewportTopRow
    }

    /// Returns the latest cached line structure without crossing the host actor boundary.
    public func readRowStructure() -> [TerminalRowStructure] {
        cachedTerminal.rowStructure
    }

    /// Returns the latest cached history without crossing the host actor boundary.
    public func readFullHistoryText() -> String {
        cachedTerminal.fullHistoryText
    }

    /// Reflects whether the latest consumed terminal snapshot has a selection.
    public var hasSelection: Bool {
        cachedTerminal.selectionRange != nil
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
        let fence = performAccountedFence(kind: .checkpoint, operation: .frameState)
        guard case .frameState(let frameState) = fence else {
            preconditionFailure("frame-state fence returned the wrong payload")
        }
        consume(frameState: frameState, result: nil, transitions: nil)
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

    /// Enqueues a new search needle on the sole terminal owner.
    public func beginSearch(_ query: String) {
        guard isTornDown == false else { return }
        host.beginSearch(query)
    }

    /// Enqueues a step to the next-older match on the sole terminal owner.
    public func searchNext() {
        guard isTornDown == false else { return }
        host.searchNext()
    }

    /// Enqueues a step to the next-newer match on the sole terminal owner.
    public func searchPrevious() {
        guard isTornDown == false else { return }
        host.searchPrevious()
    }

    /// Enqueues dropping the search, which also removes the active-match highlight.
    public func clearSearch() {
        guard isTornDown == false else { return }
        host.clearSearch()
    }

    /// Returns primary-screen history for persistence consumers that exclude transient screens.
    public func readPrimaryHistoryText() -> String {
        cachedTerminal.primaryHistoryText
    }

    /// Returns only as much of that history's tail as a truncation at this budget can keep, for
    /// the recovery checkpoint -- which reads every pane on a timer and discards the rest.
    public func readPrimaryHistoryTail(maxLines: Int, maxChars: Int) -> String {
        cachedTerminal.primaryHistoryTailText(maxLines: maxLines, maxChars: maxChars)
    }

    /// Copies the terminal now and returns the same bounded read, runnable off the main actor.
    /// The copy is the point: `Terminal` is a value, so the checkpoint can project on its own
    /// queue while this session keeps accepting output. Budgets stay plain `Int`s -- retention
    /// is the app's policy, and this layer must not learn it.
    public func primaryHistoryTailReader() -> @Sendable (Int, Int) -> String {
        let terminal = cachedTerminal
        return { maxLines, maxChars in
            terminal.primaryHistoryTailText(maxLines: maxLines, maxChars: maxChars)
        }
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

    /// Fences the whole retained tape with its origin, for one finite dump.
    public func flightRecordingCapture() -> TerminalFlightRecordingCapture {
        host.fencedFlightRecordingCapture()
    }

    /// Fences exact pane state with the recorder position that continues after it.
    public func flightRecordingStateSynchronization()
        -> TerminalFlightRecordingStateSynchronization
    {
        let fence = performAccountedFence(kind: .checkpoint, operation: .stateSynchronization)
        guard case .stateSynchronization(let terminal, let cursor) = fence else {
            preconditionFailure("state synchronization fence returned the wrong payload")
        }
        return TerminalFlightRecordingStateSynchronization(
            state: terminal.stateSynchronization,
            cursor: cursor
        )
    }

    /// Fences every value needed to choose raw events or exact reconstructible state.
    public func flightRecordingStreamFence(
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingStreamFence {
        host.fencedFlightRecordingStream(from: cursor)
    }

    /// Arms one append edge without carrying recorder events across the owner boundary.
    public func addFlightRecordingFollowNotice(
        id: UUID,
        from cursor: TerminalFlightRecordingCursor,
        notify: @escaping @Sendable () -> Void
    ) {
        host.addFlightRecordingFollowNotice(id: id, from: cursor, notify: notify)
    }

    /// Removes one append edge before the app releases its subscription state.
    public func removeFlightRecordingFollowNotice(id: UUID) {
        host.removeFlightRecordingFollowNotice(id: id)
    }

    /// Fences one followed suffix and rearms that subscriber's next append edge atomically.
    public func flightRecordingFollowSnapshot(
        subscriptionId: UUID,
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingCursorSnapshot? {
        host.fencedFlightRecordingFollowSnapshot(
            subscriptionId: subscriptionId,
            from: cursor
        )
    }

    /// Rearms one followed suffix with exact state available for reconstructible loss repair.
    public func flightRecordingFollowStreamFence(
        subscriptionId: UUID,
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingFollowFence? {
        host.fencedFlightRecordingFollowStream(
            subscriptionId: subscriptionId,
            from: cursor
        )
    }

    /// Fences current geometry with the first cursor for a tail-only follow stream.
    public func flightRecordingOriginFromNow() -> TerminalFlightRecordingOrigin {
        host.fencedFlightRecordingOriginFromNow()
    }

    /// Fences recorder birth geometry with the cursor that requests retained backlog.
    public func flightRecordingBacklogOrigin() -> TerminalFlightRecordingOrigin {
        host.fencedFlightRecordingBacklogOrigin()
    }

    /// Test harness seam that fences live evidence without changing completion eligibility.
    package func diagnosticCapture(test: String) -> TerminalPaneDiagnosticCapture {
        let fence = performAccountedFence(kind: .diagnostic, operation: .diagnosticState)
        guard case .diagnosticState(let frameState, let transitions) = fence else {
            preconditionFailure("diagnostic fence returned the wrong payload")
        }
        cachedTerminal = frameState.terminal
        // The fence drains the host's damage, so this is the only route by which the
        // terminal can advance without `consume` recording which rows moved. Folding it
        // in keeps the planner's retained rows in lineage with `cachedTerminal`.
        pendingDamage.formUnion(frameState.damage)
        return TerminalPaneDiagnosticCapture(
            terminal: frameState.terminal,
            recording: makeRecording(test: test, events: neutralEvents(transitions)),
            semanticEvents: frameState.semanticEvents
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

    /// Ends callbacks immediately and lets the host queue finish bounded teardown.
    public func tearDown() {
        guard stopDeliveryAndCacheFinalTerminal() else { return }
        isTornDown = true
        onFrame = nil
        onClipboardWrite = nil
        onSemanticEvents = nil
        onSessionEnded = nil
        onProcessStarted = nil
        onViewportStateChange = nil
        onPrimaryHistoryMutation = nil
        onPaneMenu = nil
        onOpenLink = nil
        onSelectionCopy = nil
        onSearchStatus = nil
    }

    private func performAccountedFence(
        kind: TerminalPaneFenceKind,
        operation: TerminalPTYProductionFenceOperation
    ) -> TerminalPTYProductionFenceOutput {
        let measured = Self.performAccountedFence(
            host: host,
            kind: kind,
            operation: operation,
            clock: fenceClock,
            metrics: &fenceMetrics
        )
        if kind == .delivery {
            unflushedDeliveryFenceWaitNanoseconds += measured.waitNanoseconds
        }
        return measured.output
    }

    private static func performAccountedFence(
        host: TerminalPTYHost,
        kind: TerminalPaneFenceKind,
        operation: TerminalPTYProductionFenceOperation,
        clock: () -> UInt64,
        metrics: inout TerminalPaneFenceMetrics
    ) -> (output: TerminalPTYProductionFenceOutput, waitNanoseconds: UInt64) {
        let started = clock()
        let result = host.performProductionFence(operation)
        let waitNanoseconds = clock() - started
        metrics.record(
            kind: kind,
            waitNanoseconds: waitNanoseconds,
            hostEntryCount: result.entryCount
        )
        return (result.output, waitNanoseconds)
    }

    private func consume(
        frameState: TerminalPTYFrameState,
        result: PaneProcessLifecycleResult?,
        transitions: [TerminalPTYAppliedTransition]?
    ) {
        // First, so a synchronous checkpoint fence cannot overtake urgent work
        // already signaled toward the main hop: semantics stay ordered before
        // the frame and the exit callback that follow them.
        let flushedSignal = deliveryBoundary.takePendingSignal()
        if let flushedSignal { deliverUrgent(flushedSignal) }
        // Any fence drains all pending host work, so it satisfies the deadline:
        // the armed one-shot dies here and the next signal starts a new cycle.
        cancelDeferredFenceIfArmed()
        earliestNextFenceNanoseconds = fenceClock() + displayRefreshIntervalNanoseconds()
        // A flushed result must not be lost with its hop: this fence adopts it.
        let result = result ?? flushedSignal?.result
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
        emitSearchStatusIfNeeded()
        if case .some(.exited) = result {
            didChildExit = true
        }
        if isVisible, isRenderingAvailable { planIfNeeded(frameState.terminal) }
        if let result, didEmitSessionEnded == false {
            didEmitSessionEnded = true
            if let transitions {
                completedRecordingEvents = neutralEvents(transitions)
            }
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

    private func emitSearchStatusIfNeeded() {
        let status = cachedTerminal.searchStatus
        guard status != lastEmittedSearchStatus else { return }
        lastEmittedSearchStatus = status
        onSearchStatus?(status)
    }

    private func neutralMouseEvent(for event: TerminalPointerEvent) -> NeutralTerminalMouseEvent {
        switch event {
        case let .down(button, column, row, offsetX, modifiers, clickCount):
            NeutralTerminalMouseEvent(
                action: .down,
                button: button.rawValue + 1,
                column: column,
                row: row,
                offsetX: offsetX,
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
        case let .move(column, row, offsetX, modifiers):
            NeutralTerminalMouseEvent(
                action: .move,
                column: column,
                row: row,
                offsetX: offsetX,
                modifiers: modifiers
            )
        }
    }

    /// Test support for whole-value recording equality after a synchronization fence.
    package func terminalSnapshot() -> Terminal {
        cachedTerminal
    }

    private func planIfNeeded(_ terminal: Terminal) {
        guard isVisible, isRenderingAvailable else { return }
        guard pendingDamage != .none else { return }
        let presentation = terminal.presentation
        guard presentation.isSynchronizedOutputActive == false || didChildExit else { return }
        #if DANTERM_TERMINAL_BENCHMARK
        let planStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
        let planStartedThreadCPUNanoseconds = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        #endif
        let plan = framePlanner.planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: renderTheme,
                isCursorVisible: presentation.isCursorVisible,
                cursorShape: presentation.cursorShape
            ),
            damage: pendingDamage
        )
        #if DANTERM_TERMINAL_BENCHMARK
        lastPlanDurationNanoseconds =
            DispatchTime.now().uptimeNanoseconds - planStartedNanoseconds
        lastPlanThreadCPUNanoseconds =
            clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - planStartedThreadCPUNanoseconds
        #endif
        // Below every early return above, so a suppressed publish carries its stall
        // forward to the next one instead of losing it.
        lastFenceStallNanoseconds = unflushedDeliveryFenceWaitNanoseconds
        unflushedDeliveryFenceWaitNanoseconds = 0
        currentPlan = plan
        currentDamage = pendingDamage
        let frame = TerminalPaneFrame(plan: plan, damage: pendingDamage)
        pendingDamage = .none
        onFrame?(frame)
    }
}
