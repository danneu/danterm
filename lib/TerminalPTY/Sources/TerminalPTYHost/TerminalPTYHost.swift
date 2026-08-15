// One serialized owner for PTY lifecycle policy, nonblocking process IO, and
// headless Terminal mutation. Dispatch sources run on the actor's own executor.
import Darwin
import DequeModule
import Dispatch
import Foundation
import PaneProcessLifecycle
import TerminalCore
import TerminalCoreRecording

/// Construction failures caught before any PTY or process ownership exists.
public enum TerminalPTYHostError: Error, Equatable, Sendable {
    case invalidDimensions
}

/// Carries one immutable terminal value with the damage drained for its frame consumer.
public struct TerminalPTYFrameState: Equatable, Sendable {
    /// The newest owner state after its accumulator has been drained.
    public let terminal: Terminal
    /// All redraw work accumulated since the previous frame-state read.
    public let damage: TerminalDamage
    /// The newest completed OSC 52 write drained in the same owner transaction.
    public let clipboardWrite: String?
    /// Ordered semantic output drained independently of render damage.
    public let semanticEvents: [TerminalSemanticEvent]

    /// Keeps the drained accumulator separate so terminal equality remains presentation-based.
    public init(
        terminal: Terminal,
        damage: TerminalDamage,
        clipboardWrite: String?,
        semanticEvents: [TerminalSemanticEvent]
    ) {
        self.terminal = terminal
        self.damage = damage
        self.clipboardWrite = clipboardWrite
        self.semanticEvents = semanticEvents
    }
}

/// Rides every host update signal so the urgent classes -- completed clipboard
/// writes, ordered semantic events, primary-history mutation, and the child's
/// lifecycle result -- reach the consumer without waiting on a delivery fence
/// (research 33/D8). Deliberately carries no terminal and no damage: a payload
/// that carried a frame would reopen the flood the consumer's deadline bounds.
package struct TerminalPTYUpdateSignal: Sendable {
    /// True only on the update turn that transitions the child into running.
    package let processStarted: Bool
    /// The newest completed OSC 52 write drained in the signaling owner turn.
    package let clipboardWrite: String?
    /// Ordered semantic output drained in the signaling owner turn.
    package let semanticEvents: [TerminalSemanticEvent]
    /// Monotonic primary-history generation at signal time, for payload-free
    /// mutation classification at the consumer.
    package let primaryHistoryGeneration: UInt64
    /// The reported child lifecycle result, so an exit is consumed immediately
    /// rather than at the deadline.
    package let result: PaneProcessLifecycleResult?

    package init(
        processStarted: Bool,
        clipboardWrite: String?,
        semanticEvents: [TerminalSemanticEvent],
        primaryHistoryGeneration: UInt64,
        result: PaneProcessLifecycleResult?
    ) {
        self.processStarted = processStarted
        self.clipboardWrite = clipboardWrite
        self.semanticEvents = semanticEvents
        self.primaryHistoryGeneration = primaryHistoryGeneration
        self.result = result
    }

    /// Coalesces this signal with one emitted later, preserving semantic order,
    /// the newest clipboard write, and the newest generation and result.
    package func merging(newer: TerminalPTYUpdateSignal) -> TerminalPTYUpdateSignal {
        TerminalPTYUpdateSignal(
            processStarted: processStarted || newer.processStarted,
            clipboardWrite: newer.clipboardWrite ?? clipboardWrite,
            semanticEvents: semanticEvents + newer.semanticEvents,
            primaryHistoryGeneration: max(
                primaryHistoryGeneration,
                newer.primaryHistoryGeneration
            ),
            result: newer.result ?? result
        )
    }
}

/// Test-support view of owner-ordered terminal, input, and viewport transitions.
package enum TerminalPTYAppliedTransition: Equatable, Sendable {
    case feed([UInt8])
    case input(key: TerminalInputKey, modifiers: TerminalKeyModifiers)
    case paste(String)
    case focus(Bool)
    case mouse(TerminalPointerEvent)
    case resize(TerminalDimensions)
    case scrollByRows(Int)
    case scrollToTopRow(Int)
    case scrollToBottom
}

/// Names the controller-owned synchronous operations that count as production fences.
package enum TerminalPTYProductionFenceOperation: Sendable {
    case frameState
    case consumptionState
    case diagnosticState
    case stateSynchronization
    case beginCloseAndSnapshot
    case installUpdateHandler(@Sendable (TerminalPTYUpdateSignal) -> Void)
}

/// Carries one production fence's payload together with the host's raw entry census.
package enum TerminalPTYProductionFenceOutput: Sendable {
    case frameState(TerminalPTYFrameState)
    case consumptionState(
        frameState: TerminalPTYFrameState,
        result: PaneProcessLifecycleResult?,
        transitions: [TerminalPTYAppliedTransition]?
    )
    case diagnosticState(
        frameState: TerminalPTYFrameState,
        transitions: [TerminalPTYAppliedTransition]
    )
    case stateSynchronization(
        terminal: Terminal,
        cursor: TerminalFlightRecordingCursor
    )
    case closeSnapshot(Terminal)
    case updateHandlerInstalled
}

/// Lets the controller cross-check its attributed count against the host's raw count.
package struct TerminalPTYProductionFenceResult: Sendable {
    package let output: TerminalPTYProductionFenceOutput
    package let entryCount: UInt64
}

/// Test-support view of input and resize effects applied on the shared owner queue.
enum TerminalPTYSubmittedTransition: Equatable, Sendable {
    case input([UInt8])
    case resize(TerminalDimensions)
}

/// Groups passive lifecycle observations so the resource snapshot separates
/// teardown ownership from counters that record how the host reached it.
struct TerminalPTYLifecycleCensus: Equatable, Sendable {
    let callbacksAfterTeardown: Int
    /// How many times the teardown ladder failed to converge inside the host's own
    /// bound and quiescence had to be forced. Zero on every ordinary teardown.
    let forcedQuiescenceCount: Int
    let emittedUpdateSignalCount: Int
    let updateSignalsAfterTermination: Int
}

/// Test-support census of resources that must be absent once teardown returns.
struct TerminalPTYResourceSnapshot: Equatable, Sendable {
    let hasOpenMaster: Bool
    let activeSourceCount: Int
    let descriptorSourceCount: Int
    /// A launch whose outcome this host would still adopt. Deliberately not "a
    /// launch still running": the blocking spawn cannot be interrupted, so what
    /// teardown can guarantee is that a late outcome is discarded, not that the
    /// syscall has returned.
    let hasPendingSpawnAdoption: Bool
    let hasLeader: Bool
    let hasSession: Bool
    let pendingInputByteCount: Int
    let census: TerminalPTYLifecycleCensus

    var isReleased: Bool {
        hasOpenMaster == false
            && activeSourceCount == 0
            && hasPendingSpawnAdoption == false
            && hasLeader == false
            && hasSession == false
            && pendingInputByteCount == 0
            && census.callbacksAfterTeardown == 0
            && census.updateSignalsAfterTermination == 0
    }
}

/// Owns one pane's mutable terminal, lifecycle reducer, PTY, child, and event sources.
public actor TerminalPTYHost {
    /// One submission's bytes inside the shared pending-input buffer, paired with where they
    /// came from. `endOffset` is one past its last byte, so consecutive spans tile the buffer.
    private struct PendingInputSpan {
        let endOffset: Int
        let origin: UInt64?
        let submissionId: PaneInputSubmissionId?
    }

    // Swift cannot import FIONREAD because its C macro encodes sizeof(int).
    // Rebuild the SDK's _IOR('f', 127, int) value from sys/ioccom.h.
    private static let bytesAvailableRequest = UInt(
        0x4000_0000 | (MemoryLayout<Int32>.size << 16) | (102 << 8) | 127
    )

    /// Runs the blocking launch off the owner queue. Concurrent so one pane's
    /// spawn cannot delay another's, and shared because each host would
    /// otherwise carry a whole queue for the one call it makes on it.
    private static let spawnQueue = DispatchQueue(
        label: "com.danneu.danterm.terminal-pty-spawn",
        attributes: .concurrent
    )

    /// How long a host will let its own teardown ladder run before forcing
    /// quiescence. The bound lives here, not in the exit path, because only the
    /// owner of the PTY, the child session, and the dispatch sources can both
    /// stop waiting and guarantee that nothing it owns runs afterward.
    static let defaultApplicationExitBound: DispatchTimeInterval = .seconds(2)

    private static let forcedCensusRetryInterval: UInt32 = 1000

    private let queue: DispatchSerialQueue
    /// Read on the owner queue, written from whatever thread submits, so it is not
    /// actor state: every `nonisolated` submission below either enters a resize into
    /// the open run or closes it.
    private let resizeCoalescer = ResizeCoalescer()
    private var reducer = PaneProcessLifecycleReducer()
    private var terminal: Terminal
    private let initialDimensions: TerminalDimensions
    package nonisolated let captureTransitions: Bool
    private let bootstrapExecutable: String
    private let childExitProbe: any TerminalPTYChildExitProbing
    private let resourceLifecycle: any TerminalPTYResourceLifecycling
    private let spawner: any TerminalPTYSpawning

    private var masterFD: Int32 = -1
    private var leaderPID: pid_t?
    private var sessionID: pid_t?
    private var leaderReaped = false
    private var readSource: (any DispatchSourceRead)?
    private var readSourceActivated = false
    private var writeSource: (any DispatchSourceWrite)?
    private var processSource: (any DispatchSourceProcess)?
    private var processSourceActivated = false
    private var childExitPollSource: (any DispatchSourceTimer)?
    private var graceSource: (any DispatchSourceTimer)?
    private var sessionPollSource: (any DispatchSourceTimer)?
    private var sessionPollStage: TeardownStage?
    private var sessionPollStageSignaled = false
    private var retainedSources: [Int: any DispatchSourceProtocol] = [:]
    private var descriptorSourceIDs: Set<Int> = []
    private var nextSourceID = 0
    private var descriptorOwnershipSealed = false
    private var masterCloseRequested = false
    private var reducerAwaitsMasterClose = false
    private var forcedCleanupAfterMasterClose = false
    private var teardownFinalizationRequested = false
    /// Bumped by every new launch and by teardown. A returning spawn compares the
    /// generation it was issued under, so supersession and abandonment are one
    /// mechanism and a stale outcome is discarded rather than adopted.
    private var spawnGeneration = 0
    private var pendingSpawnAdoption = false
    /// The launch this host would still adopt, kept only so forced quiescence can
    /// stop it. Cleared as soon as its outcome lands.
    private var inFlightLaunch: InFlightLaunch?

    private var pendingInput: [UInt8] = []
    private var pendingInputOffset = 0
    /// One entry per submission still short of the PTY, oldest first, each ending where the
    /// next begins. This is what keeps a submission's origin attached to its own bytes while
    /// backpressure holds them, so the write that finally transmits them can be attributed.
    private var pendingInputSpans: Deque<PendingInputSpan> = []
    private var nextInputSubmissionRawValue: UInt64 = 1
    private var inputCompletions: [
        PaneInputSubmissionId: @Sendable (PaneInputSubmissionResult) -> Void
    ] = [:]
    private var injectedInputWriteErrno: Int32?
    private var pendingEvents: [PaneProcessLifecycleEvent] = []
    private var isReducing = false

    #if DEBUG
    /// Bounded lookback so a test-support wait armed after the fact can still be
    /// answered from output the child already produced. Capped at
    /// `testOutputWindowLimit`; every byte pushed out is counted, never forgotten.
    private var testOutputWindow: [UInt8] = []
    /// How much output has fallen out of `testOutputWindow`. This is the number that
    /// separates "these bytes never arrived" from "this host can no longer know",
    /// which is the difference between a failing wait and a hanging one.
    private var testOutputDiscardedByteCount = 0
    /// Chunk observers, each dropped as soon as it reports it is done, so a satisfied
    /// wait costs nothing afterwards. Bounded by the number of live waits on this host.
    private var testOutputObservers: [@Sendable ([UInt8]) -> Bool] = []
    private static let testOutputWindowLimit = 64 * 1024
    #endif
    private var interactionState = TerminalInteractionState()
    private var capturedOutput: [UInt8] = []
    private var appliedTransitions: [TerminalPTYAppliedTransition] = []
    /// Every pane records from birth: there is no seam that creates or destroys this after
    /// construction, so "a pane that kept no evidence of itself" is unreachable.
    private let flightTape: TerminalFlightRecorder
    private var capturedSubmittedTransitions: [TerminalPTYSubmittedTransition] = []
    private var capturedInputWrites: [[UInt8]] = []
    private var capturedReplyWrites: [[UInt8]] = []
    private var reportedResult: PaneProcessLifecycleResult?
    private var pendingProcessStarted = false
    private var teardownFinished = false
    private let applicationExitBound: DispatchTimeInterval
    private var shutdownRequested = false
    private var quiescenceObservers: [@Sendable () -> Void] = []
    private var exitBoundSource: (any DispatchSourceTimer)?
    private var forcedQuiescenceCount = 0
    private var callbacksAfterTeardown = 0
    private var updatePending = false
    private var shouldFinishUpdates = false
    private var updateSignalFinished = false
    private var emittedUpdateSignalCount = 0
    private var updateSignalsAfterTermination = 0
    private var consumerWorkWasSignaled = false
    private var updateHandler: (@Sendable (TerminalPTYUpdateSignal) -> Void)?
    private var testUpdateHandler:
        (@Sendable (PaneProcessLifecycleResult?) -> Void)?
    private var productionFenceEntryCount: UInt64 = 0

    /// Binds Swift actor jobs to the FIFO queue that also delivers every system callback.
    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Creates an owner before launch so every later mutation shares one executor.
    public init(
        initialDimensions: TerminalDimensions,
        bootstrapExecutable: String,
        machineHostname: String? = MachineHostname.posix,
        programVersion: String = "dev",
        defaultColors: TerminalDefaultColors = .baked
    ) throws {
        try self.init(
            initialDimensions: initialDimensions,
            bootstrapExecutable: bootstrapExecutable,
            machineHostname: machineHostname,
            programVersion: programVersion,
            defaultColors: defaultColors,
            captureTransitions: false
        )
    }

    /// `applicationExitBound` is injected only so a test can drive the forced
    /// quiescence path deterministically instead of waiting out the real bound.
    package init(
        initialDimensions: TerminalDimensions,
        bootstrapExecutable: String,
        machineHostname: String? = MachineHostname.posix,
        programVersion: String = "dev",
        defaultColors: TerminalDefaultColors = .baked,
        captureTransitions: Bool,
        flightTapeConfiguration: TerminalFlightRecorderConfiguration = .production,
        flightTapeClock: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        applicationExitBound: DispatchTimeInterval = TerminalPTYHost.defaultApplicationExitBound,
        childExitProbe: any TerminalPTYChildExitProbing = SystemTerminalPTYChildExitProbe(),
        resourceLifecycle: any TerminalPTYResourceLifecycling = SystemTerminalPTYResourceLifecycle(),
        spawner: any TerminalPTYSpawning = SystemTerminalPTYSpawner()
    ) throws {
        guard let terminal = Terminal(
            columns: initialDimensions.columns,
            rows: initialDimensions.rows,
            machineHostname: machineHostname,
            programVersion: programVersion,
            defaultColors: defaultColors
        ) else {
            throw TerminalPTYHostError.invalidDimensions
        }
        queue = DispatchSerialQueue(label: "com.danneu.danterm.terminal-pty-host")
        self.terminal = terminal
        self.initialDimensions = initialDimensions
        self.bootstrapExecutable = bootstrapExecutable
        self.captureTransitions = captureTransitions
        self.applicationExitBound = applicationExitBound
        self.childExitProbe = childExitProbe
        self.resourceLifecycle = resourceLifecycle
        self.spawner = spawner
        flightTape = TerminalFlightRecorder(
            initialDimensions: initialDimensions,
            configuration: flightTapeConfiguration,
            now: flightTapeClock
        )
    }

    /// Starts the pure launch plan and returns after scheduling its system spawn.
    public func start(_ input: LaunchPolicyInput) {
        guard input.initialDimensions == initialDimensions else {
            var invalidInput = input
            invalidInput.initialDimensions = .init(columns: 0, rows: 0)
            process(.start(invalidInput))
            return
        }
        process(.start(input))
    }

    /// Enqueues launch before synchronous pane submissions without requiring a Task hop.
    nonisolated public func submitStart(_ input: LaunchPolicyInput) {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in owner.start(input) }
        }
    }

    /// Enqueues user bytes directly on the owner queue without an ordering-opaque Task.
    nonisolated public func send(
        _ bytes: [UInt8],
        origin: UInt64? = nil,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        queueClosingResizeRun().async { [weak self] in
            guard let self else {
                onCompletion(.rejected(.processEnded))
                return
            }
            self.assumeIsolated { owner in
                guard bytes.isEmpty == false else {
                    onCompletion(.delivered)
                    return
                }
                owner.applyViewportNavigation(.scrollToBottom, publishUpdate: false)
                owner.submitInput(bytes, origin: origin, onCompletion: onCompletion)
            }
        }
    }

    /// Orders default-color changes with child output and later terminal queries.
    nonisolated public func setDefaultColors(_ colors: TerminalDefaultColors) {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in
                owner.terminal.setDefaultColors(colors)
            }
        }
    }

    /// Enqueues a normalized key so mode read, encoding, viewport snap, and write stay atomic.
    nonisolated public func sendKey(
        _ key: TerminalInputKey,
        modifiers: TerminalKeyModifiers,
        origin: UInt64? = nil,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        queueClosingResizeRun().async { [weak self] in
            guard let self else {
                onCompletion(.rejected(.processEnded))
                return
            }
            self.assumeIsolated { owner in
                owner.applyKey(
                    key,
                    modifiers: modifiers,
                    origin: origin,
                    onCompletion: onCompletion
                )
            }
        }
    }

    /// Enqueues unsanitized text for owner-side safe-paste policy and atomic marker generation.
    nonisolated public func sendPaste(
        _ text: String,
        origin: UInt64? = nil,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        queueClosingResizeRun().async { [weak self] in
            guard let self else {
                onCompletion(.rejected(.processEnded))
                return
            }
            self.assumeIsolated { owner in
                owner.applyPaste(text, origin: origin, onCompletion: onCompletion)
            }
        }
    }

    /// Enqueues semantic pane focus for authoritative mode gating without viewport movement.
    nonisolated public func sendFocus(_ focused: Bool, origin: UInt64? = nil) {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in owner.applyFocus(focused, origin: origin) }
        }
    }

    /// Enqueues geometry on the same FIFO as input so caller order is preserved jointly,
    /// and drops the whole winsize/reflow pair for a grid a later submission already
    /// superseded -- a drag then applies as many reflows as the owner can afford rather
    /// than one per column crossed, and the child is told proportionally fewer sizes.
    nonisolated public func resize(_ dimensions: TerminalDimensions) {
        let submission = resizeCoalescer.submitResize()
        queue.async { [weak self] in
            self?.assumeIsolated { owner in
                guard owner.resizeCoalescer.isSuperseded(submission) == false else { return }
                owner.process(.resize(dimensions))
            }
        }
    }

    /// Returns the owner queue for a non-resize submission, first closing the open
    /// coalescing run so nothing already submitted is superseded across it: the action
    /// being enqueued here reads the geometry of the resize before it, so that resize
    /// has to apply. Every `nonisolated` submission other than `resize` goes through
    /// this rather than touching `queue` directly.
    nonisolated private func queueClosingResizeRun() -> DispatchSerialQueue {
        resizeCoalescer.closeRun()
        return queue
    }

    /// Enqueues relative local navigation on the same FIFO as child output and resize.
    nonisolated public func scroll(byRows rowDelta: Int) {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applyViewportNavigation(.scrollByRows(rowDelta), publishUpdate: true)
            }
        }
    }

    /// Enqueues absolute scrollbar navigation in current-stream row coordinates.
    nonisolated public func scroll(toTopRow row: Int) {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applyViewportNavigation(.scrollToTopRow(row), publishUpdate: true)
            }
        }
    }

    /// Enqueues an explicit return to live-bottom follow.
    nonisolated public func scrollToBottom() {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applyViewportNavigation(.scrollToBottom, publishUpdate: true)
            }
        }
    }

    /// Enqueues selection clearing on the same FIFO as pointer mutations and output.
    nonisolated public func clearSelection() {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in owner.applyClearSelection() }
        }
    }

    /// Enqueues whole-stream selection on the same FIFO as pointer mutations and output.
    nonisolated public func selectAll() {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in owner.applySelectAll() }
        }
    }

    /// Enqueues a new search needle and reports the status the owner ends up in.
    nonisolated public func beginSearch(
        _ query: String,
        onStatus: @escaping @Sendable (TerminalSearchStatus?) -> Void = { _ in }
    ) {
        enqueueSearch(.begin(query), onStatus: onStatus)
    }

    /// Enqueues a step to the next-older match on the same FIFO as output.
    nonisolated public func searchNext(
        onStatus: @escaping @Sendable (TerminalSearchStatus?) -> Void = { _ in }
    ) {
        enqueueSearch(.next, onStatus: onStatus)
    }

    /// Enqueues a step to the next-newer match on the same FIFO as output.
    nonisolated public func searchPrevious(
        onStatus: @escaping @Sendable (TerminalSearchStatus?) -> Void = { _ in }
    ) {
        enqueueSearch(.previous, onStatus: onStatus)
    }

    /// Enqueues dropping the search, which also removes the active-match highlight.
    nonisolated public func clearSearch(
        onStatus: @escaping @Sendable (TerminalSearchStatus?) -> Void = { _ in }
    ) {
        enqueueSearch(.clear, onStatus: onStatus)
    }

    nonisolated private func enqueueSearch(
        _ mutation: SearchMutation,
        onStatus: @escaping @Sendable (TerminalSearchStatus?) -> Void
    ) {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applySearch(mutation, onStatus: onStatus)
            }
        }
    }

    /// Enqueues normalized fractional wheel input for atomic route and mode selection.
    nonisolated public func sendWheel(
        _ event: TerminalWheelEvent,
        origin: UInt64? = nil,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        queueClosingResizeRun().async { [weak self] in
            guard let self else {
                onCompletion(.rejected(.processEnded))
                return
            }
            self.assumeIsolated { owner in
                owner.applyWheel(event, origin: origin, onCompletion: onCompletion)
            }
        }
    }

    /// Enqueues pointer input and returns only owner-approved local actions.
    ///
    /// `onSelectionCompleted` is the whole copy-on-select gate: passing nil means the owner
    /// never extracts the selection's text, so a caller that does not want the behavior does
    /// not pay for the projection walk that materializing it costs.
    nonisolated public func sendPointer(
        _ event: TerminalPointerEvent,
        origin: UInt64? = nil,
        onPaneMenu: @escaping @Sendable (TerminalViewportCell) -> Void = { _ in },
        onOpenLink: @escaping @Sendable (TerminalHyperlink) -> Void = { _ in },
        onSelectionCompleted: (@Sendable (String) -> Void)? = nil
    ) {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applyPointer(
                    event,
                    origin: origin,
                    onPaneMenu: onPaneMenu,
                    onOpenLink: onOpenLink,
                    onSelectionCompleted: onSelectionCompleted
                )
            }
        }
    }

    /// Cancels link arming and hover on the same FIFO as pointer transitions.
    nonisolated public func cancelLinkInteraction() {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in owner.applyLinkCancellation() }
        }
    }

    /// Observes natural or requested completion without changing host lifecycle.
    ///
    /// The observer always runs on this host's queue, including when registered
    /// after quiescence, so process-lifetime ownership never depends on main.
    nonisolated public func whenQuiescent(
        _ observer: @escaping @Sendable () -> Void
    ) {
        queueClosingResizeRun().async { [self] in
            assumeIsolated { owner in owner.observeQuiescence(observer) }
        }
    }

    /// Idempotently starts the one host shutdown transaction from any thread.
    ///
    /// An optional completion is registered before shutdown begins and means
    /// irreversible quiescence, not acknowledgement of the request.
    nonisolated public func requestShutdown(
        completion: (@Sendable () -> Void)? = nil
    ) {
        queueClosingResizeRun().async { [self] in
            assumeIsolated { owner in owner.beginShutdown(completion: completion) }
        }
    }

    private func observeQuiescence(_ observer: @escaping @Sendable () -> Void) {
        guard teardownFinished == false else {
            observer()
            return
        }
        quiescenceObservers.append(observer)
    }

    private func beginShutdown(completion: (@Sendable () -> Void)?) {
        if let completion {
            observeQuiescence(completion)
        }
        guard teardownFinished == false, shutdownRequested == false else { return }
        shutdownRequested = true
        descriptorOwnershipSealed = true
        armExitBound()
        process(.requestClose)
    }

    private func armExitBound() {
        cancelExitBound()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + applicationExitBound)
        timer.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.exitBoundElapsed() }
        }
        retainUntilCancellation(timer, descriptorBacked: false)
        exitBoundSource = timer
        timer.activate()
    }

    private func cancelExitBound() {
        exitBoundSource?.cancel()
        exitBoundSource = nil
    }

    /// Retains one source through its cancellation callback and enrolls
    /// descriptor-backed sources in the PTY close barrier.
    private func retainUntilCancellation<Source: DispatchSourceProtocol>(
        _ source: Source,
        descriptorBacked: Bool
    ) {
        let id = nextSourceID
        nextSourceID += 1
        source.setCancelHandler { [weak self] in
            self?.assumeIsolated { owner in
                owner.sourceCancellationHandlerRan(id)
            }
        }
        retainedSources[id] = source
        if descriptorBacked {
            descriptorSourceIDs.insert(id)
        }
    }

    private func sourceCancellationHandlerRan(_ id: Int) {
        guard retainedSources[id] != nil else { return }
        let resume: @Sendable () -> Void = { [weak self] in
            self?.enqueueSourceCancellationAcknowledgement(id)
        }
        switch resourceLifecycle.gateSourceCancellationAcknowledgement(resume: resume) {
        case .proceed:
            acknowledgeSourceCancellation(id)
        case .deferred:
            break
        }
    }

    /// Re-enters the owner after a test witness releases one parked acknowledgement.
    private nonisolated func enqueueSourceCancellationAcknowledgement(_ id: Int) {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in
                owner.acknowledgeSourceCancellation(id)
            }
        }
    }

    private func acknowledgeSourceCancellation(_ id: Int) {
        guard retainedSources.removeValue(forKey: id) != nil else { return }
        descriptorSourceIDs.remove(id)
        completeMasterCloseIfPossible()
        completeTeardownIfPossible()
    }

    /// The teardown ladder did not converge inside this host's bound, so ownership
    /// of the child session is resolved here rather than abandoned: every surviving
    /// member is killed before teardown finishes. Returning while those processes
    /// could still be running would satisfy the bound by breaking `I2`.
    private func exitBoundElapsed() {
        guard teardownFinished == false else { return }
        forcedQuiescenceCount += 1
        forcedCleanupAfterMasterClose = true
        reducerAwaitsMasterClose = false
        cancelExitBound()
        cancelGrace()
        cancelSessionPoll()
        cancelProcessSource()
        cancelChildExitPoll()
        closeMaster()
    }

    /// Continues forced cleanup only after descriptor source cancellation has
    /// closed the master, so a blocking reap cannot deadlock a draining leader.
    private func performForcedCleanupAfterMasterClose() {
        guard forcedCleanupAfterMasterClose else { return }
        forcedCleanupAfterMasterClose = false
        killOwnedSession()
        reapLeaderAfterKill()
        // Last: a launch that has not come back yet owns a child this host cannot
        // see, and finishing without stopping it would report quiescence over a
        // process that is still starting up.
        inFlightLaunch?.abandon()
        inFlightLaunch = nil
        finishTeardown()
        publishPendingUpdate()
    }

    /// Kills every member of the owned session, across all of its process groups.
    ///
    /// The census is retried rather than treated as optional: it is the only way to
    /// see background and stopped jobs, which routinely sit in process groups of
    /// their own. Signalling just the leader's group would leave those running while
    /// this host reported the session resolved.
    private func killOwnedSession() {
        guard let sessionID else { return }
        while true {
            if let members = sessionMembers(sessionID: sessionID) {
                for pid in members where getsid(pid) == sessionID {
                    _ = kill(pid, SIGKILL)
                }
                return
            }
            // Keep making progress against the portion addressable without a
            // census, but do not report quiescence until every process group in
            // the session has actually been enumerable and signalled.
            _ = kill(-sessionID, SIGKILL)
            if let leaderPID { _ = kill(leaderPID, SIGKILL) }
            usleep(Self.forcedCensusRetryInterval)
        }
    }

    /// Blocks only after the PTY master is closed and SIGKILL guarantees the
    /// leader is exiting, so the owner can prove reap before publishing quiescence.
    /// Giving up on a bounded poll would clear `leaderPID` and signal completion
    /// over a zombie this process still owns -- abandonment wearing quiescence's
    /// clothes -- and a completion is only worth anything if it is never that.
    private func reapLeaderAfterKill() {
        guard leaderReaped == false, let leaderPID else { return }
        _ = kill(leaderPID, SIGKILL)
        var status: Int32 = 0
        // Retry on EINTR like every other blocking syscall here: an interrupted wait is not a
        // reap decision, and treating it as one would clear `leaderPID` and publish quiescence
        // over a child this process has not collected. ECHILD still falls through, so no spin.
        var reaped = waitpid(leaderPID, &status, 0)
        while reaped < 0 && errno == EINTR {
            reaped = waitpid(leaderPID, &status, 0)
        }
        if reaped == leaderPID {
            leaderReaped = true
        }
    }

    /// Returns a Sendable value copy that cannot mutate owner state.
    public func snapshot() -> Terminal {
        terminal
    }

    // Deliberately no `async` counterpart to `fencedFrameState()`. Draining hands each row's
    // damage to exactly one caller, so the drain and the bookkeeping that records it have to
    // be one indivisible step. An awaited drain resolves here and delivers on the consumer's
    // actor, and a synchronous fence taken in that gap reads a terminal newer than the damage
    // still in flight -- it then reuses rows that did move, and the pane holds stale content
    // until later damage happens to cover it. Every drain therefore goes through the fence.
    //
    // If a second interleaving bug ever appears in this hand-over contract, stop patching
    // it: make damage reads non-destructive (the owner accumulates damage, the consumer
    // acknowledges a watermark), so a lost or duplicated delivery degrades to a redundant
    // repaint instead of stale rows.

    /// Performs every controller-owned fence through the host's one counted sync path.
    package nonisolated func performProductionFence(
        _ operation: TerminalPTYProductionFenceOperation
    ) -> TerminalPTYProductionFenceResult {
        let fenced = fence(countsAsProduction: true) {
            owner -> TerminalPTYProductionFenceOutput in
            switch operation {
            case .frameState:
                return .frameState(owner.drainedFrameState())
            case .consumptionState:
                let consumption = owner.drainedConsumptionState()
                return .consumptionState(
                    frameState: consumption.frameState,
                    result: consumption.result,
                    transitions: consumption.transitions
                )
            case .diagnosticState:
                return .diagnosticState(
                    frameState: owner.drainedFrameState(),
                    transitions: owner.appliedTransitions
                )
            case .stateSynchronization:
                return .stateSynchronization(
                    terminal: owner.terminal,
                    cursor: owner.flightTape.liveCursor()
                )
            case .beginCloseAndSnapshot:
                owner.updateHandler = nil
                owner.beginShutdown(completion: nil)
                return .closeSnapshot(owner.terminal)
            case .installUpdateHandler(let handler):
                if owner.teardownFinished == false {
                    owner.updateHandler = handler
                }
                return .updateHandlerInstalled
            }
        }
        return TerminalPTYProductionFenceResult(
            output: fenced.value,
            entryCount: fenced.productionEntryCount
        )
    }

    /// Fences earlier owner-queue work for test-only synchronous reads.
    nonisolated public func fencedSnapshot() -> Terminal {
        fence(countsAsProduction: false) { owner in owner.terminal }.value
    }

    /// Copies the whole retained tape and its origin in one owner fence, so a finite dump
    /// states one atomic moment and its record building stays off-actor.
    package nonisolated func fencedFlightRecordingCapture() -> TerminalFlightRecordingCapture {
        fence(countsAsProduction: false) { owner in owner.flightTape.capture() }.value
    }

    /// Copies terminal state and the recorder continuation cursor in one owner-queue turn.
    package nonisolated func fencedStateSynchronization()
        -> TerminalFlightRecordingStateSynchronization
    {
        let fenced = fence(countsAsProduction: false) { owner in
            (owner.terminal, owner.flightTape.liveCursor())
        }.value
        return TerminalFlightRecordingStateSynchronization(
            state: fenced.0.stateSynchronization,
            cursor: fenced.1
        )
    }

    /// Fences retained tape, remote cursor placement, and exact pane state for stream policy.
    package nonisolated func fencedFlightRecordingStream(
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingStreamFence {
        let fenced = fence(countsAsProduction: false) { owner in
            let terminal = owner.terminal
            let liveCursor = owner.flightTape.liveCursor()
            return (
                terminal,
                liveCursor,
                owner.flightTape.backlogOrigin(),
                owner.flightTape.cursorSnapshot(from: .beginning),
                owner.flightTape.cursorPlacement(from: cursor)
            )
        }.value
        return TerminalFlightRecordingStreamFence(
            origin: fenced.2,
            retained: fenced.3,
            requested: fenced.4,
            synchronization: TerminalFlightRecordingStateSynchronization(
                state: fenced.0.stateSynchronization,
                cursor: fenced.1
            )
        )
    }

    /// Copies the retained suffix and exact cursor gap in one owner-queue fence.
    package nonisolated func fencedFlightRecording(
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingCursorSnapshot {
        fence(countsAsProduction: false) { owner in
            owner.flightTape.cursorSnapshot(from: cursor)
        }.value
    }

    /// Rearms one follow notice while pairing its suffix with exact state at the same cursor.
    package nonisolated func fencedFlightRecordingFollowStream(
        subscriptionId: UUID,
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingFollowFence? {
        let fenced: (Terminal, TerminalFlightRecordingCursorSnapshot)? = fence(
            countsAsProduction: false
        ) { owner in
            guard let snapshot = owner.flightTape.followCursorSnapshot(
                subscriptionId: subscriptionId,
                from: cursor
            ) else { return nil }
            return (owner.terminal, snapshot)
        }.value
        guard let fenced else { return nil }
        return TerminalFlightRecordingFollowFence(
            snapshot: fenced.1,
            synchronization: TerminalFlightRecordingStateSynchronization(
                state: fenced.0.stateSynchronization,
                cursor: fenced.1.nextCursor
            )
        )
    }

    /// Registers one edge-triggered recorder notice at an already-fenced stream cursor.
    package nonisolated func addFlightRecordingFollowNotice(
        id: UUID,
        from cursor: TerminalFlightRecordingCursor,
        notify: @escaping @Sendable () -> Void
    ) {
        _ = fence(countsAsProduction: false) { owner in
            owner.flightTape.addFollowNotice(id: id, from: cursor, notify: notify)
        }
    }

    /// Removes one recorder notice on the same owner queue that may invoke it.
    package nonisolated func removeFlightRecordingFollowNotice(id: UUID) {
        _ = fence(countsAsProduction: false) { owner in
            owner.flightTape.removeFollowNotice(id: id)
        }
    }

    /// Copies one followed suffix and rearms its append edge in the same owner transaction.
    /// nil only when this subscription is no longer registered.
    package nonisolated func fencedFlightRecordingFollowSnapshot(
        subscriptionId: UUID,
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingCursorSnapshot? {
        fence(countsAsProduction: false) { owner in
            owner.flightTape.followCursorSnapshot(
                subscriptionId: subscriptionId,
                from: cursor
            )
        }.value
    }

    /// Reads live geometry and the tail cursor together so resize cannot interleave them.
    package nonisolated func fencedFlightRecordingOriginFromNow()
        -> TerminalFlightRecordingOrigin
    {
        fence(countsAsProduction: false) { owner in owner.flightTape.fromNowOrigin() }.value
    }

    /// Reads birth geometry with the lifetime beginning cursor for a backlog stream.
    package nonisolated func fencedFlightRecordingBacklogOrigin()
        -> TerminalFlightRecordingOrigin
    {
        fence(countsAsProduction: false) { owner in owner.flightTape.backlogOrigin() }.value
    }

    /// Fences test work and drains exactly the damage accumulated through that fence.
    nonisolated public func fencedFrameState() -> TerminalPTYFrameState {
        fence(countsAsProduction: false) { owner in owner.drainedFrameState() }.value
    }

    /// Drains test frame effects and lifecycle evidence as one owner transaction.
    package nonisolated func fencedConsumptionState() -> (
        frameState: TerminalPTYFrameState,
        result: PaneProcessLifecycleResult?,
        transitions: [TerminalPTYAppliedTransition]?
    ) {
        fence(countsAsProduction: false) { owner in owner.drainedConsumptionState() }.value
    }

    /// The one owner-isolated build of the consumption payload, shared by the production fence
    /// and its test counterpart so `countsAsProduction:` stays the only difference between the
    /// two paths. Transitions are selected before the drain, which is the ordering the
    /// hand-over contract above depends on; keeping one copy is what stops the two from
    /// drifting apart.
    private func drainedConsumptionState() -> (
        frameState: TerminalPTYFrameState,
        result: PaneProcessLifecycleResult?,
        transitions: [TerminalPTYAppliedTransition]?
    ) {
        let transitions: [TerminalPTYAppliedTransition]?
        if case .some(.exited) = reportedResult, captureTransitions {
            transitions = appliedTransitions
        } else {
            transitions = nil
        }
        return (drainedFrameState(), reportedResult, transitions)
    }

    /// Captures a test-only diagnostic boundary before failure cleanup can discard evidence.
    package nonisolated func fencedDiagnosticState() -> (
        frameState: TerminalPTYFrameState,
        transitions: [TerminalPTYAppliedTransition]
    ) {
        fence(countsAsProduction: false) { owner in
            (owner.drainedFrameState(), owner.appliedTransitions)
        }.value
    }

    /// Returns the production census without counting the test's own inspection fence.
    package nonisolated func productionFenceEntryCountForTesting() -> UInt64 {
        fence(countsAsProduction: false) { owner in
            owner.productionFenceEntryCount
        }.value
    }

    /// Owns the sole synchronous entry onto the actor's serial executor.
    nonisolated private func fence<Value: Sendable>(
        countsAsProduction: Bool,
        _ operation: @Sendable (isolated TerminalPTYHost) -> Value
    ) -> (value: Value, productionEntryCount: UInt64) {
        queue.sync {
            assumeIsolated { owner in
                if countsAsProduction {
                    owner.productionFenceEntryCount += 1
                }
                return (operation(owner), owner.productionFenceEntryCount)
            }
        }
    }

    private func drainedFrameState() -> TerminalPTYFrameState {
        let damage = terminal.drainDamage()
        let clipboardWrite = terminal.drainPendingClipboardWrite()
        let semanticEvents = terminal.drainSemanticEvents()
        consumerWorkWasSignaled = false
        return TerminalPTYFrameState(
            terminal: terminal,
            damage: damage,
            clipboardWrite: clipboardWrite,
            semanticEvents: semanticEvents
        )
    }

    /// Installs the test-support wakeup separately so adapters do not displace the pane consumer.
    package nonisolated func setTestUpdateHandler(
        _ handler: @escaping @Sendable (PaneProcessLifecycleResult?) -> Void
    ) -> (
        result: PaneProcessLifecycleResult?,
        hasEmittedUpdate: Bool
    ) {
        fence(countsAsProduction: false) { owner in
            if owner.teardownFinished == false {
                owner.testUpdateHandler = handler
            }
            return (
                result: owner.reportedResult,
                hasEmittedUpdate: owner.emittedUpdateSignalCount > 0
            )
        }.value
    }

    #if DEBUG
    /// Subscribes a test-support observer to child output, in one owner transaction that
    /// first replays everything still retained.
    ///
    /// The observer sees the retained lookback as its first chunk and every later chunk in
    /// stream order, with no gap in between -- that ordering is the point of doing this
    /// under the fence, and it is what lets a caller match incrementally instead of
    /// rescanning a window that can drop bytes underneath it. Returning `false` unsubscribes.
    ///
    /// The returned count is how much output this host has already discarded. A caller that
    /// has not matched by the time this returns and sees a non-zero count has asked a
    /// question this host cannot answer, and must say so rather than wait for an answer that
    /// can never arrive.
    package nonisolated func observeTestOutput(
        _ observer: @escaping @Sendable ([UInt8]) -> Bool
    ) -> Int {
        fence(countsAsProduction: false) { owner in
            let wantsMore = observer(owner.testOutputWindow)
            if wantsMore, owner.teardownFinished == false {
                owner.testOutputObservers.append(observer)
            }
            return owner.testOutputDiscardedByteCount
        }.value
    }
    #endif

    /// Applies output synchronously so delivery-fence tests can queue callbacks without yielding main.
    package nonisolated func deliverOutputForTesting(_ bytes: [UInt8]) {
        guard bytes.isEmpty == false else { return }
        _ = fence(countsAsProduction: false) { owner in
            owner.applyOutput(bytes)
            owner.publishPendingUpdate()
        }
    }

    package enum InteractionForTesting: Sendable {
        case pointer(TerminalPointerEvent)
        case cancelLinkInteraction
        case clearSelection
        case beginSearch(String)
        case selectAll
        case scrollByRows(Int)
        case resize(TerminalDimensions)
    }

    package nonisolated func applyInteractionForTesting(_ interaction: InteractionForTesting) {
        _ = fence(countsAsProduction: false) { owner in
            switch interaction {
            case .pointer(let event):
                owner.applyPointer(
                    event,
                    origin: nil,
                    onPaneMenu: { _ in },
                    onOpenLink: { _ in },
                    onSelectionCompleted: nil
                )
            case .cancelLinkInteraction:
                owner.applyLinkCancellation()
            case .clearSelection:
                owner.applyClearSelection()
            case .beginSearch(let query):
                owner.applySearch(.begin(query), onStatus: { _ in })
            case .selectAll:
                owner.applySelectAll()
            case .scrollByRows(let rows):
                owner.applyViewportNavigation(.scrollByRows(rows), publishUpdate: true)
            case .resize(let dimensions):
                owner.process(.resize(dimensions))
            }
        }
    }

    /// Returns the reported child result without waiting for future lifecycle work.
    public func result() -> PaneProcessLifecycleResult? {
        reportedResult
    }

    /// Returns raw bytes only when explicit test-support capture was enabled.
    func outputBytes() -> [UInt8] {
        capturedOutput
    }

    /// Returns the exact TerminalCore mutation order for neutral recording tests.
    package func transitions() -> [TerminalPTYAppliedTransition] {
        appliedTransitions
    }

    /// Returns the reducer-emitted writes before nonblocking partial IO splits them.
    func inputWrites() -> [[UInt8]] {
        capturedInputWrites
    }

    /// Returns core-generated writes separately from user-originated input evidence.
    func replyWrites() -> [[UInt8]] {
        capturedReplyWrites
    }

    /// Returns the shared-queue order of applied input and resize effects.
    func submittedTransitions() -> [TerminalPTYSubmittedTransition] {
        capturedSubmittedTransitions
    }

    /// Exposes an ownership census without leaking mutable descriptors or sources.
    func resourceSnapshot() -> TerminalPTYResourceSnapshot {
        TerminalPTYResourceSnapshot(
            hasOpenMaster: masterFD >= 0,
            activeSourceCount: retainedSources.count,
            descriptorSourceCount: descriptorSourceIDs.count,
            hasPendingSpawnAdoption: pendingSpawnAdoption,
            hasLeader: leaderPID != nil,
            hasSession: sessionID != nil,
            pendingInputByteCount: max(pendingInput.count - pendingInputOffset, 0),
            census: TerminalPTYLifecycleCensus(
                callbacksAfterTeardown: callbacksAfterTeardown,
                forcedQuiescenceCount: forcedQuiescenceCount,
                emittedUpdateSignalCount: emittedUpdateSignalCount,
                updateSignalsAfterTermination: updateSignalsAfterTermination
            )
        )
    }

    private func process(_ event: PaneProcessLifecycleEvent) {
        pendingEvents.append(event)
        guard isReducing == false else { return }
        isReducing = true
        defer {
            publishPendingUpdate()
            isReducing = false
        }

        while pendingEvents.isEmpty == false {
            let next = pendingEvents.removeFirst()
            let commands = reducer.handle(next)
            execute(commands)
        }
    }

    private func applyWheel(
        _ event: TerminalWheelEvent,
        origin: UInt64?,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void
    ) {
        guard teardownFinished == false else {
            onCompletion(.rejected(.processEnded))
            return
        }
        let decision = decideTerminalWheel(event, terminal: terminal, state: &interactionState)
        if decision.inputBytes.isEmpty == false {
            submitInput(decision.inputBytes, origin: origin, onCompletion: onCompletion)
            return
        }
        if decision.localRowDelta != 0 {
            applyViewportNavigation(
                .scrollByRows(decision.localRowDelta),
                publishUpdate: true
            )
        }
        onCompletion(.delivered)
    }

    private func applyPointer(
        _ event: TerminalPointerEvent,
        origin: UInt64?,
        onPaneMenu: @Sendable (TerminalViewportCell) -> Void,
        onOpenLink: @Sendable (TerminalHyperlink) -> Void,
        onSelectionCompleted: (@Sendable (String) -> Void)?
    ) {
        guard teardownFinished == false else { return }
        if captureTransitions { appliedTransitions.append(.mouse(event)) }
        let decision = decideTerminalPointer(event, terminal: terminal, state: &interactionState)
        if decision.inputBytes.isEmpty == false {
            submitInput(decision.inputBytes, origin: origin)
        }
        switch decision.selectionMutation {
        case .clear:
            terminal.clearSelection()
        case .set(let range):
            terminal.setSelection(
                range,
                granularity: decision.selectionGranularity ?? .character
            )
        case nil:
            break
        }
        // Captured here, in the same owner step that applied the mutation, so output arriving
        // after the gesture completed cannot change what the subscriber is handed. Emptiness is
        // judged on the extracted string: a selection over blank cells is present and empty,
        // and relaying it would clear a clipboard the user filled earlier.
        if decision.completedSelectionGesture,
           let onSelectionCompleted,
           let text = terminal.selectedText,
           text.isEmpty == false
        {
            onSelectionCompleted(text)
        }
        applyHoverMutation(decision.hoverMutation)
        applyArmMutation(decision.armMutation)
        markFrameUpdatePendingIfNeeded()
        publishPendingUpdate()
        if let cell = decision.paneMenuCell {
            onPaneMenu(cell)
        }
        if let link = decision.openLink {
            onOpenLink(link)
        }
    }

    private func applyLinkCancellation() {
        guard teardownFinished == false else { return }
        let cancellation = cancelTerminalLinkInteraction(state: &interactionState)
        applyHoverMutation(cancellation.hoverMutation)
        applyArmMutation(cancellation.armMutation)
        markFrameUpdatePendingIfNeeded()
        publishPendingUpdate()
    }

    private func applyHoverMutation(_ mutation: TerminalHoverMutation?) {
        switch mutation {
        case .clear:
            terminal.clearHoveredLink()
        case .set(let link):
            terminal.setHoveredLink(link)
        case nil:
            break
        }
    }

    private func applyArmMutation(_ mutation: TerminalLinkArmMutation?) {
        switch mutation {
        case .clear:
            terminal.clearArmedLink()
        case .set(let link):
            _ = terminal.setArmedLink(link)
        case nil:
            break
        }
    }

    private func applyClearSelection() {
        guard teardownFinished == false else { return }
        terminal.clearSelection()
        markFrameUpdatePendingIfNeeded()
        publishPendingUpdate()
    }

    /// The four search mutations, as one Sendable value so the enqueue can cross the queue.
    private enum SearchMutation: Sendable {
        case begin(String)
        case next
        case previous
        case clear
    }

    private func applySearch(
        _ mutation: SearchMutation,
        onStatus: @Sendable (TerminalSearchStatus?) -> Void
    ) {
        guard teardownFinished == false else { return }
        switch mutation {
        case .begin(let query): _ = terminal.beginSearch(query)
        case .next: _ = terminal.searchNext()
        case .previous: _ = terminal.searchPrevious()
        case .clear: terminal.clearSearch()
        }
        // Always report: a repeated failed needle and a navigate with only one match record
        // no frame work, and those are exactly the moments the overlay still needs status.
        onStatus(terminal.searchStatus)
        markFrameUpdatePendingIfNeeded()
        publishPendingUpdate()
    }

    private func applySelectAll() {
        guard teardownFinished == false else { return }
        terminal.selectAll()
        markFrameUpdatePendingIfNeeded()
        publishPendingUpdate()
    }

    private func applyKey(
        _ key: TerminalInputKey,
        modifiers: TerminalKeyModifiers,
        origin: UInt64?,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void
    ) {
        guard teardownFinished == false else {
            onCompletion(.rejected(.processEnded))
            return
        }
        if captureTransitions { appliedTransitions.append(.input(key: key, modifiers: modifiers)) }
        let bytes = encodeTerminalKey(key, modifiers: modifiers, modes: terminal.inputModes)
        guard bytes.isEmpty == false else {
            onCompletion(.delivered)
            return
        }
        applyViewportNavigation(.scrollToBottom, publishUpdate: false)
        submitInput(bytes, origin: origin, onCompletion: onCompletion)
    }

    private func applyPaste(
        _ text: String,
        origin: UInt64?,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void
    ) {
        guard teardownFinished == false else {
            onCompletion(.rejected(.processEnded))
            return
        }
        if captureTransitions { appliedTransitions.append(.paste(text)) }
        let bytes = encodeTerminalPaste(text, modes: terminal.inputModes)
        guard bytes.isEmpty == false else {
            onCompletion(.delivered)
            return
        }
        applyViewportNavigation(.scrollToBottom, publishUpdate: false)
        submitInput(bytes, origin: origin, onCompletion: onCompletion)
    }

    private func applyFocus(_ focused: Bool, origin: UInt64?) {
        guard teardownFinished == false else { return }
        if captureTransitions { appliedTransitions.append(.focus(focused)) }
        let bytes = encodeTerminalFocus(focused: focused, modes: terminal.inputModes)
        guard bytes.isEmpty == false else { return }
        submitInput(bytes, origin: origin)
    }

    private func applyViewportNavigation(
        _ navigation: TerminalPTYAppliedTransition,
        publishUpdate: Bool
    ) {
        guard teardownFinished == false else { return }
        let previousViewport = terminal.scrollProjection
        switch navigation {
        case .scrollByRows(let rows): terminal.scroll(byRows: rows)
        case .scrollToTopRow(let row): terminal.scroll(toTopRow: row)
        case .scrollToBottom: terminal.scrollToBottom()
        case .feed, .input, .paste, .focus, .mouse, .resize:
            preconditionFailure(
                "applyViewportNavigation takes only .scrollByRows, .scrollToTopRow, .scrollToBottom"
            )
        }
        if terminal.scrollProjection != previousViewport {
            if captureTransitions { appliedTransitions.append(navigation) }
        }
        markFrameUpdatePendingIfNeeded()
        if publishUpdate { publishPendingUpdate() }
    }

    private func execute(_ commands: [PaneProcessLifecycleCommand]) {
        for command in commands { execute(command) }
    }

    private func execute(_ command: PaneProcessLifecycleCommand) {
        switch command {
        case .spawn(let spec):
            spawn(spec)
        case .activateIO:
            activateIO()
            pendingProcessStarted = true
            markUpdatePending()
        case .writeInput(let bytes, let origin, let submissionId):
            if captureTransitions {
                capturedInputWrites.append(bytes)
                capturedSubmittedTransitions.append(.input(bytes))
            }
            enqueueInput(bytes, origin: origin, submissionId: submissionId)
        case .completeInput(let submissionId, let result):
            completeInput(submissionId, with: result)
        case .resize(let dimensions):
            applyResize(dimensions)
        case .deliverOutput(let bytes):
            applyOutput(bytes)
        case .drainOutput:
            drainCommittedOutput()
        case .closeMaster:
            reducerAwaitsMasterClose = true
            closeMaster()
        case .reapLeader:
            reapLeader()
        case .signalSession(let stage):
            signalSession(stage)
        case .scheduleGrace(let stage):
            scheduleGrace(stage)
        case .cancelGrace:
            cancelGrace()
        case .report(let result):
            report(result)
        case .finishTeardown:
            finishTeardown()
        }
    }

    private func spawn(_ spec: PTYLaunchSpec) {
        spawnGeneration += 1
        pendingSpawnAdoption = true
        let generation = spawnGeneration
        let bootstrapExecutable = self.bootstrapExecutable
        let spawner = self.spawner
        let launch = InFlightLaunch()
        inFlightLaunch = launch
        let queue = self.queue
        Self.spawnQueue.async { [weak self] in
            let outcome = spawner.spawn(spec, bootstrapExecutable: bootstrapExecutable) {
                spawned in
                return launch.reportLaunched(spawned)
            }
            // Abandoned launches stop here only after `resolve` has released any
            // child. A deliverable outcome remains in `launch` until the owner
            // callback takes it, so exit can claim it during that handoff too.
            guard launch.resolve(outcome) else { return }
            spawner.waitForDeliveryPermission()
            queue.async { [weak self] in
                guard let deliverable = launch.takeOutcome() else { return }
                guard let self else {
                    if case .success(let spawned) = deliverable {
                        Self.discardOffOwner(spawned)
                    }
                    return
                }
                self.assumeIsolated { owner in
                    owner.receiveSpawn(deliverable, generation: generation)
                }
            }
        }
    }

    /// Test-support: makes the next pending-input flush take the hard write-failure edge.
    package func injectInputWriteFailure(_ code: Int32) {
        injectedInputWriteErrno = code
    }

    /// Test-support: drives the host-bound phase without relying on an elapsed
    /// timer while source acknowledgements are controlled separately.
    package func forceExitBoundForTesting() {
        exitBoundElapsed()
    }

    /// Releases a child this host will never adopt. Off the owner queue because
    /// the kill-and-reap blocks, and the owner must stay free to keep tearing down.
    private nonisolated static func discardOffOwner(_ spawned: SpawnedPTY) {
        spawnQueue.async { PTYSpawner.discard(spawned) }
    }

    private func receiveSpawn(_ outcome: PTYSpawnOutcome, generation: Int) {
        // A superseded or abandoned launch (`PO6`: the blocking spawn returned a
        // live child after exit was requested). Adopting it would install sources
        // and a leader on a host that has already been declared quiescent.
        guard generation == spawnGeneration else {
            if case .success(let spawned) = outcome {
                Self.discardOffOwner(spawned)
            }
            return
        }
        pendingSpawnAdoption = false
        inFlightLaunch = nil
        switch outcome {
        case .abandoned:
            // Unreachable in practice -- `resolve` withholds an abandoned outcome
            // rather than delivering it -- but the reducer must never be told a
            // launch succeeded when its child has already been released.
            process(.spawnFailed(.systemError(ECANCELED)))
        case .success(let spawned):
            masterFD = spawned.master
            leaderPID = spawned.leader
            sessionID = spawned.session
            leaderReaped = false
            if descriptorOwnershipSealed == false {
                installSources(for: spawned)
            }
            let resume: @Sendable () -> Void = { [weak self] in
                self?.enqueueSpawnActivation()
            }
            switch resourceLifecycle.gateSpawnActivation(resume: resume) {
            case .proceed:
                process(.spawnSucceeded)
            case .deferred:
                break
            }
        case .failure(let failure):
            process(.spawnFailed(failure))
        }
    }

    /// Re-enters the owner after a test witness releases parked source activation.
    private nonisolated func enqueueSpawnActivation() {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in
                owner.process(.spawnSucceeded)
            }
        }
    }

    private func installSources(for spawned: SpawnedPTY) {
        let read = DispatchSource.makeReadSource(fileDescriptor: spawned.master, queue: queue)
        read.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.readSourceFired() }
        }
        retainUntilCancellation(read, descriptorBacked: true)
        readSource = read
        readSourceActivated = false

        let process = DispatchSource.makeProcessSource(
            identifier: spawned.leader,
            eventMask: .exit,
            queue: queue
        )
        process.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.processSourceFired() }
        }
        retainUntilCancellation(process, descriptorBacked: false)
        processSource = process
        processSourceActivated = false
    }

    private func activateIO() {
        guard descriptorOwnershipSealed == false else {
            closeMaster()
            return
        }
        activateReadSourceIfNeeded()
        activateProcessSourceIfNeeded()
    }

    private func activateReadSourceIfNeeded() {
        guard let readSource, readSourceActivated == false else { return }
        readSourceActivated = true
        readSource.activate()
    }

    private func activateProcessSourceIfNeeded() {
        guard let processSource, processSourceActivated == false else { return }
        processSourceActivated = true
        processSource.activate()
    }

    private func submitInput(
        _ bytes: [UInt8],
        origin: UInt64?,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        let submissionId = PaneInputSubmissionId(rawValue: nextInputSubmissionRawValue)
        nextInputSubmissionRawValue &+= 1
        precondition(inputCompletions[submissionId] == nil, "input submission identity wrapped")
        inputCompletions[submissionId] = onCompletion
        process(.sendInput(bytes, origin: origin, submissionId: submissionId))
    }

    private func enqueueInput(
        _ bytes: [UInt8],
        origin: UInt64?,
        submissionId: PaneInputSubmissionId?
    ) {
        guard descriptorOwnershipSealed == false,
              bytes.isEmpty == false,
              masterFD >= 0
        else {
            if let submissionId {
                completeInput(submissionId, with: .rejected(.processEnded))
            }
            return
        }
        compactPendingInputIfNeeded()
        let pendingByteCount = pendingInput.count - pendingInputOffset
        guard bytes.count <= PaneProcessLifecycleReducer.pendingInputByteLimit - pendingByteCount else {
            if let submissionId {
                completeInput(submissionId, with: .rejected(.bufferLimitExceeded))
            }
            return
        }
        pendingInput.append(contentsOf: bytes)
        pendingInputSpans.append(.init(
            endOffset: pendingInput.count,
            origin: origin,
            submissionId: submissionId
        ))
        flushInput()
    }

    private func flushInput() {
        guard descriptorOwnershipSealed == false, masterFD >= 0 else {
            rejectPendingInput(because: .processEnded)
            cancelWriteSource()
            return
        }
        if let code = injectedInputWriteErrno {
            injectedInputWriteErrno = nil
            rejectPendingInput(because: .writeFailed(code))
            cancelWriteSource()
            return
        }
        let turnLimit = 64 * 1024
        var writtenThisTurn = 0
        while pendingInputOffset < pendingInput.count, writtenThisTurn < turnLimit {
            let result = pendingInput.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                let remaining = min(
                    pendingInput.count - pendingInputOffset,
                    turnLimit - writtenThisTurn
                )
                return Darwin.write(masterFD, base.advanced(by: pendingInputOffset), remaining)
            }
            if result > 0 {
                recordWrittenInput(count: result)
                pendingInputOffset += result
                writtenThisTurn += result
                continue
            }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
            let code = errno
            rejectPendingInput(because: .writeFailed(code))
            return
        }
        if pendingInputOffset == pendingInput.count {
            clearPendingInput()
            cancelWriteSource()
        } else {
            installWriteSourceIfNeeded()
        }
    }

    /// Records the bytes one successful write transmitted, split at the boundaries of the
    /// submissions they came from so each event reports the origin of its own bytes.
    private func recordWrittenInput(count: Int) {
        var start = pendingInputOffset
        let end = pendingInputOffset + count
        while start < end, let span = pendingInputSpans.first {
            let spanEnd = min(span.endOffset, end)
            guard spanEnd > start else {
                assertionFailure("pending input span ends before the bytes it covers")
                return
            }
            flightTape.record(.write(Array(pendingInput[start..<spanEnd])), origin: span.origin)
            if spanEnd == span.endOffset {
                pendingInputSpans.removeFirst()
                if let submissionId = span.submissionId {
                    completeInput(submissionId, with: .delivered)
                }
            }
            start = spanEnd
        }
        assert(start == end, "written pending input outran its origin spans")
    }

    /// Releases pending input without recording it: these bytes never crossed the boundary,
    /// so the tape must not claim they did.
    private func clearPendingInput() {
        pendingInput.removeAll(keepingCapacity: false)
        pendingInputOffset = 0
        pendingInputSpans.removeAll(keepingCapacity: false)
    }

    private func rejectPendingInput(because failure: PaneInputSubmissionFailure) {
        let submissionIds = pendingInputSpans.compactMap(\.submissionId)
        clearPendingInput()
        for submissionId in submissionIds {
            completeInput(submissionId, with: .rejected(failure))
        }
    }

    private func compactPendingInputIfNeeded() {
        guard pendingInputOffset > 0 else { return }
        let consumed = pendingInputOffset
        pendingInput = Array(pendingInput.dropFirst(consumed))
        pendingInputOffset = 0
        pendingInputSpans = Deque(pendingInputSpans.map {
            PendingInputSpan(
                endOffset: $0.endOffset - consumed,
                origin: $0.origin,
                submissionId: $0.submissionId
            )
        })
    }

    private func completeInput(
        _ submissionId: PaneInputSubmissionId,
        with result: PaneInputSubmissionResult
    ) {
        guard let completion = inputCompletions.removeValue(forKey: submissionId) else { return }
        completion(result)
    }

    private func installWriteSourceIfNeeded() {
        guard descriptorOwnershipSealed == false,
              writeSource == nil,
              masterFD >= 0
        else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.writeSourceFired() }
        }
        retainUntilCancellation(source, descriptorBacked: true)
        writeSource = source
        source.activate()
    }

    private func cancelWriteSource() {
        writeSource?.cancel()
        writeSource = nil
    }

    private func readSourceFired() {
        guard recordSystemCallback(), descriptorOwnershipSealed == false else { return }
        readReady()
    }

    private func writeSourceFired() {
        guard recordSystemCallback(), descriptorOwnershipSealed == false else { return }
        flushInput()
    }

    private func processSourceFired() {
        guard recordSystemCallback() else { return }
        childExited()
    }

    /// Reads at most `turnLimit` bytes, then returns and lets the level-triggered read
    /// source re-fire for the remainder.
    ///
    /// The cap sizes the longest contiguous slice anything else can wait behind on this
    /// queue, because a turn does not yield: the main actor's `queue.sync` drain fence,
    /// every actor call, and the teardown acknowledgements all queue behind whatever turn
    /// is running. Measured on `scrollback-stream`, worst-case fence wait tracks the
    /// constant linearly across an 8x range -- 6.66ms at 64 KiB, 1.78ms at 16 KiB, 0.92ms
    /// at 8 KiB -- because the parse rate is a stable ~10 MB/s and a fence reliably lands
    /// at the start of a fresh turn.
    ///
    /// 16 KiB is where that stops being free. Shrinking a turn multiplies turns, and 8 KiB
    /// took the flood workload's draw metric to a `slower` verdict (+5.1%, three of three
    /// runs) for 0.86ms of further latency; 16 KiB holds `inconclusive` (+3.69% against the
    /// uncapped tree). Lowering it further also stops working on the constant alone -- the
    /// chunk buffer below is 16 KiB, so a turn is already a single `read`.
    ///
    /// Turn size and delivery rate are separate levers, and the cost above is the second
    /// one: fences arriving more often, each paying a fixed ~0.15ms floor, not the shorter
    /// turn itself. If 120Hz margin is ever needed, throttle the consumer's drain cadence
    /// (fence at most once per display frame) instead of revisiting 8 KiB -- that buys the
    /// smaller cap's worst block at the old delivery count.
    private func readReady() {
        guard masterFD >= 0 else { return }
        var bytesReadThisTurn = 0
        let turnLimit = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while bytesReadThisTurn < turnLimit {
            let result = buffer.withUnsafeMutableBytes {
                Darwin.read(masterFD, $0.baseAddress, min($0.count, turnLimit - bytesReadThisTurn))
            }
            if result > 0 {
                bytesReadThisTurn += result
                process(.output(Array(buffer.prefix(result))))
                continue
            }
            if result == 0 || (result < 0 && errno == EIO) {
                cancelReadSource()
                process(.outputEOF)
                return
            }
            if result < 0, errno == EINTR { continue }
            return
        }
    }

    private func childExited() {
        guard let leaderPID else { return }
        switch childExitProbe.probe(leaderPID) {
        case .notYetWaitable:
            // macOS can publish NOTE_EXIT before the wait status is readable
            // (waitid succeeds with si_pid == 0). The process source is a
            // one-shot notification for an event that already happened, so
            // dropping this fire would lose the exit forever: poll the dead
            // child until it becomes waitable. Hard waitid errors stay final.
            installChildExitPollIfNeeded()
            return
        case .failed:
            return
        case .exited(let status):
            cancelChildExitPoll()
            cancelProcessSource()
            process(.childExited(status))
        }
    }

    private func installChildExitPollIfNeeded() {
        guard childExitPollSource == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(5),
            repeating: .milliseconds(5),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.childExitPollFired() }
        }
        retainUntilCancellation(timer, descriptorBacked: false)
        childExitPollSource = timer
        timer.activate()
    }

    private func childExitPollFired() {
        guard recordSystemCallback() else { return }
        childExited()
    }

    private func cancelChildExitPoll() {
        childExitPollSource?.cancel()
        childExitPollSource = nil
    }

    private func drainCommittedOutput() {
        guard masterFD >= 0 else {
            process(.outputEOF)
            return
        }
        var committed: Int32 = 0
        guard ioctl(masterFD, Self.bytesAvailableRequest, &committed) == 0, committed > 0 else {
            process(.outputEOF)
            return
        }
        var remaining = Int(committed)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while remaining > 0 {
            let result = buffer.withUnsafeMutableBytes {
                Darwin.read(masterFD, $0.baseAddress, min($0.count, remaining))
            }
            if result > 0 {
                remaining -= result
                process(.output(Array(buffer.prefix(result))))
            } else if result < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        process(.outputEOF)
    }

    #if DEBUG
    /// Feeds child output to the test-support lookback and to every live observer.
    ///
    /// Debug-only on purpose: this is the only retention the host does for tests, and a
    /// shipping build must not pay an append and a window trim on every PTY read.
    private func recordTestOutput(_ bytes: [UInt8]) {
        let limit = Self.testOutputWindowLimit
        testOutputWindow.append(contentsOf: bytes)
        if testOutputWindow.count > limit {
            let overflow = testOutputWindow.count - limit
            testOutputWindow.removeFirst(overflow)
            testOutputDiscardedByteCount += overflow
        }
        guard testOutputObservers.isEmpty == false else { return }
        // Emptied before the calls, refilled after, so an observer subscribed from within
        // one -- or one that unsubscribes itself by returning false -- is not lost.
        let observers = testOutputObservers
        testOutputObservers.removeAll(keepingCapacity: true)
        for observer in observers where observer(bytes) {
            testOutputObservers.append(observer)
        }
    }
    #endif

    private func applyOutput(_ bytes: [UInt8]) {
        let previousConsumerWorkGeneration = terminal.pendingConsumerWorkGeneration
        flightTape.record(.feed(bytes))
        terminal.feed(bytes)
        let replies = terminal.drainReplyBytes()
        if replies.isEmpty == false {
            if captureTransitions {
                capturedReplyWrites.append(replies)
            }
            enqueueInput(replies, origin: nil, submissionId: nil)
        }
        if terminal.hasPendingConsumerWork,
           consumerWorkWasSignaled == false
            || terminal.pendingConsumerWorkGeneration != previousConsumerWorkGeneration
        {
            markUpdatePending()
        }
        #if DEBUG
        recordTestOutput(bytes)
        #endif
        if captureTransitions {
            capturedOutput.append(contentsOf: bytes)
            appliedTransitions.append(.feed(bytes))
        }
    }

    private func applyResize(_ dimensions: TerminalDimensions) {
        guard descriptorOwnershipSealed == false, masterFD >= 0 else { return }
        var size = winsize(
            ws_row: UInt16(clamping: dimensions.rows),
            ws_col: UInt16(clamping: dimensions.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard ioctl(masterFD, TIOCSWINSZ, &size) == 0 else { return }
        flightTape.record(.resize(columns: dimensions.columns, rows: dimensions.rows))
        terminal.resize(columns: dimensions.columns, rows: dimensions.rows)
        markFrameUpdatePendingIfNeeded()
        if captureTransitions {
            appliedTransitions.append(.resize(dimensions))
            capturedSubmittedTransitions.append(.resize(dimensions))
        }
    }

    private func reapLeader() {
        guard leaderReaped == false, let leaderPID else { return }
        var status: Int32 = 0
        let result = waitpid(leaderPID, &status, WNOHANG)
        if result == leaderPID {
            leaderReaped = true
        } else if result == 0 {
            // The session census can transiently stop seeing a newly launched
            // leader before its wait status is ready. The reducer is about to
            // finish, so force and synchronously confirm the reap rather than
            // clear ownership over a live process or zombie.
            reapLeaderAfterKill()
        }
    }

    private func closeMaster() {
        descriptorOwnershipSealed = true
        masterCloseRequested = true
        // A close can race source installation before the reducer activates IO.
        // Resume before cancellation so libdispatch never releases a suspended
        // source. A spawn adopted after this seal installs no sources at all.
        activateProcessSourceIfNeeded()
        cancelReadSource()
        cancelWriteSource()
        rejectPendingInput(because: .processEnded)
        completeMasterCloseIfPossible()
    }

    private func completeMasterCloseIfPossible() {
        guard masterCloseRequested, descriptorSourceIDs.isEmpty else { return }
        masterCloseRequested = false
        if masterFD >= 0 {
            resourceLifecycle.closeMasterDescriptor(masterFD)
            masterFD = -1
        }
        if forcedCleanupAfterMasterClose {
            performForcedCleanupAfterMasterClose()
            return
        }
        guard reducerAwaitsMasterClose else { return }
        reducerAwaitsMasterClose = false
        process(.masterClosed)
    }

    private func cancelReadSource() {
        guard let readSource else { return }
        if readSourceActivated == false {
            readSourceActivated = true
            readSource.activate()
        }
        readSource.cancel()
        self.readSource = nil
        readSourceActivated = false
    }

    private func cancelProcessSource() {
        guard let processSource else { return }
        if processSourceActivated == false {
            processSourceActivated = true
            processSource.activate()
        }
        processSource.cancel()
        self.processSource = nil
        processSourceActivated = false
    }

    private func signalSession(_ stage: TeardownStage) {
        guard let sessionID else {
            pendingEvents.append(.sessionDrained)
            return
        }
        sessionPollStage = stage
        sessionPollStageSignaled = false
        installSessionPollSourceIfNeeded()
        guard let members = sessionMembers(sessionID: sessionID) else {
            return
        }
        if applySessionCensus(members, sessionID: sessionID) {
            pendingEvents.append(.sessionDrained)
        }
    }

    private func applySessionCensus(_ members: [pid_t], sessionID: pid_t) -> Bool {
        guard members.isEmpty == false else {
            cancelSessionPoll()
            return true
        }
        guard sessionPollStageSignaled == false, let stage = sessionPollStage else { return false }
        let signal: Int32
        switch stage {
        case .hangup: signal = SIGHUP
        case .terminate: signal = SIGTERM
        case .kill: signal = SIGKILL
        }
        for pid in members where getsid(pid) == sessionID {
            _ = kill(pid, signal)
            if stage != .kill { _ = kill(pid, SIGCONT) }
        }
        sessionPollStageSignaled = true
        return false
    }

    private func sessionMembers(sessionID: pid_t) -> [pid_t]? {
        var capacity = max(Int(proc_listallpids(nil, 0)), 256) + 64
        for _ in 0..<3 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count))
            }
            guard count >= 0 else { return nil }
            if count < capacity {
                return pids.prefix(Int(count)).filter { pid in
                    pid > 0 && getsid(pid) == sessionID
                }
            }
            capacity *= 2
        }
        return nil
    }

    private func scheduleGrace(_ stage: TeardownStage) {
        cancelGrace()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(stage == .hangup ? 100 : 200))
        timer.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.graceTimerFired(stage) }
        }
        retainUntilCancellation(timer, descriptorBacked: false)
        graceSource = timer
        timer.activate()
    }

    private func cancelGrace() {
        graceSource?.cancel()
        graceSource = nil
    }

    private func graceTimerFired(_ stage: TeardownStage) {
        guard recordSystemCallback() else { return }
        process(.graceElapsed(stage))
    }

    private func installSessionPollSourceIfNeeded() {
        guard sessionPollSource == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(10),
            repeating: .milliseconds(10),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.sessionPollFired() }
        }
        retainUntilCancellation(timer, descriptorBacked: false)
        sessionPollSource = timer
        timer.activate()
    }

    private func sessionPollFired() {
        guard recordSystemCallback(), let sessionID else { return }
        guard let members = sessionMembers(sessionID: sessionID) else { return }
        if applySessionCensus(members, sessionID: sessionID) {
            process(.sessionDrained)
        }
    }

    private func cancelSessionPoll() {
        sessionPollSource?.cancel()
        sessionPollSource = nil
        sessionPollStage = nil
        sessionPollStageSignaled = false
    }

    private func recordSystemCallback() -> Bool {
        guard teardownFinished == false else {
            callbacksAfterTeardown += 1
            return false
        }
        return true
    }

    private func report(_ result: PaneProcessLifecycleResult) {
        guard reportedResult == nil else { return }
        reportedResult = result
        markUpdatePending()
    }

    private func finishTeardown() {
        guard teardownFinished == false, teardownFinalizationRequested == false else { return }
        // Abandons a launch still blocked in its syscall: it cannot be interrupted,
        // so the generation bump is what guarantees its child is discarded instead
        // of adopted into a host that is about to be quiescent.
        spawnGeneration += 1
        pendingSpawnAdoption = false
        cancelExitBound()
        closeMaster()
        cancelGrace()
        cancelSessionPoll()
        cancelProcessSource()
        cancelChildExitPoll()
        leaderPID = nil
        sessionID = nil
        teardownFinalizationRequested = true
        completeTeardownIfPossible()
    }

    private func completeTeardownIfPossible() {
        guard teardownFinalizationRequested,
              teardownFinished == false,
              masterFD < 0,
              retainedSources.isEmpty,
              inFlightLaunch == nil
        else { return }
        teardownFinished = true
        shouldFinishUpdates = true
        publishPendingUpdate()
    }

    private func markUpdatePending() {
        guard updateSignalFinished == false else {
            updateSignalsAfterTermination += 1
            return
        }
        updatePending = true
        if terminal.hasPendingConsumerWork {
            consumerWorkWasSignaled = true
        }
    }

    /// Wakes one future frame drain for recorded work not covered by an earlier wake.
    private func markFrameUpdatePendingIfNeeded() {
        guard terminal.hasPendingConsumerWork, consumerWorkWasSignaled == false else { return }
        markUpdatePending()
    }

    private func publishPendingUpdate() {
        if updatePending {
            updatePending = false
            // The urgent drains happen only when a production consumer exists:
            // with no handler installed the accumulators stay put, so checkpoint
            // and test fences still hand them over exactly once. With a handler,
            // every producing turn ends here before any fence can run, so a
            // frame-state drain observes them already empty.
            if let updateHandler {
                updateHandler(TerminalPTYUpdateSignal(
                    processStarted: pendingProcessStarted,
                    clipboardWrite: terminal.drainPendingClipboardWrite(),
                    semanticEvents: terminal.drainSemanticEvents(),
                    primaryHistoryGeneration: terminal.primaryHistoryGeneration,
                    result: reportedResult
                ))
                pendingProcessStarted = false
            }
            testUpdateHandler?(reportedResult)
            emittedUpdateSignalCount += 1
        }
        guard shouldFinishUpdates else { return }
        shouldFinishUpdates = false
        updateHandler = nil
        testUpdateHandler = nil
        #if DEBUG
        // The lookback survives teardown -- a wait armed afterwards can still be answered
        // from it -- but nothing stays subscribed to a host that will never deliver again.
        testOutputObservers.removeAll()
        #endif
        updateSignalFinished = true
        // Last, and on this queue: quiescence is only irreversible once every
        // callback is detached, and the exit path treats completion as exactly that.
        let observers = quiescenceObservers
        quiescenceObservers.removeAll()
        for observer in observers { observer() }
    }
}
