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
    /// Ordered pane semantics drained independently of render damage.
    public let semanticEvents: [PaneSemanticEvent]

    /// Keeps the drained accumulator separate so terminal equality remains presentation-based.
    public init(
        terminal: Terminal,
        damage: TerminalDamage,
        clipboardWrite: String?,
        semanticEvents: [PaneSemanticEvent]
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
///
/// The semantic payload is held as retention state, not as a plain array, because a
/// consumer whose main hop stalls leaves an unknown number of signals accumulating
/// into one value. The terminal half of that payload obeys the engine's own J6 bound
/// through the shared retention surface, so untrusted child output cannot grow this
/// pane's pending work without limit. The pane's input acknowledgements sit beside it:
/// they are not terminal output, and one per wait generation is all the model can act on.
package struct TerminalPTYUpdateSignal: Sendable {
    /// True only on the update turn that transitions the child into running.
    package private(set) var processStarted: Bool
    /// The newest completed OSC 52 write drained in the signaling owner turn.
    package private(set) var clipboardWrite: String?
    /// Monotonic primary-history generation at signal time, for payload-free
    /// mutation classification at the consumer.
    package private(set) var primaryHistoryGeneration: UInt64
    /// The reported child lifecycle result, so an exit is consumed immediately
    /// rather than at the deadline.
    package private(set) var result: PaneProcessLifecycleResult?

    private var terminalEvents = TerminalSemanticEventRetention()
    /// The newest position each distinct wait generation was acknowledged at.
    private var acknowledgements: [PaneInputWaitGeneration?: UInt64] = [:]
    /// The order the next admitted semantic takes. One counter covers both halves of
    /// the channel, which is what keeps acknowledgements interleaved with terminal
    /// meanings rather than racing them.
    private var nextOrder: UInt64 = 0

    package init(
        processStarted: Bool,
        clipboardWrite: String?,
        semanticEvents: [PaneSemanticEvent],
        primaryHistoryGeneration: UInt64,
        result: PaneProcessLifecycleResult?
    ) {
        self.processStarted = processStarted
        self.clipboardWrite = clipboardWrite
        self.primaryHistoryGeneration = primaryHistoryGeneration
        self.result = result
        for event in semanticEvents { admit(event) }
    }

    /// Ordered pane semantics retained for this signal's consumer.
    package var semanticEvents: [PaneSemanticEvent] {
        var ordered = terminalEvents.retainedInStreamOrder.map {
            (order: $0.order, event: PaneSemanticEvent.terminal($0.event))
        }
        ordered.append(contentsOf: acknowledgements.map {
            (order: $0.value, event: PaneSemanticEvent.userInputDelivered(waitGeneration: $0.key))
        })
        ordered.sort { $0.order < $1.order }
        return ordered.map(\.event)
    }

    /// Accumulates a signal emitted later into this one, keeping the strongest of each
    /// scalar and admitting every semantic under the retention bound.
    ///
    /// In place on purpose: the boundary merges once per host turn while a main hop is
    /// outstanding, and rebuilding the whole value each time made the retained payload
    /// cost grow with the square of how long that hop was stalled.
    package mutating func accumulate(_ newer: TerminalPTYUpdateSignal) {
        processStarted = processStarted || newer.processStarted
        clipboardWrite = newer.clipboardWrite ?? clipboardWrite
        primaryHistoryGeneration = max(primaryHistoryGeneration, newer.primaryHistoryGeneration)
        result = newer.result ?? result
        for event in newer.semanticEvents { admit(event) }
    }

    /// Offers one semantic to whichever half of the channel owns it, and advances stream
    /// order only for a semantic that was actually retained.
    private mutating func admit(_ event: PaneSemanticEvent) {
        switch event {
        case let .terminal(terminalEvent):
            guard terminalEvents.admit(terminalEvent, order: nextOrder) == .admitted else { return }
        case let .userInputDelivered(waitGeneration):
            acknowledgements[waitGeneration] = nextOrder
        }
        nextOrder &+= 1
    }
}

/// One controller-owned synchronous operation, carrying the payload type its fence returns.
///
/// The payload travels with the operation, so `.frameState` can hand back nothing but a frame
/// state and a caller that reads it as another payload does not compile. Only this file can
/// mint a value: the factories below are the whole operation set, so the controller picks a
/// documented owner operation instead of fencing arbitrary owner work.
package struct TerminalPTYProductionFenceOperation<Payload: Sendable>: Sendable {
    fileprivate let build: @Sendable (isolated TerminalPTYHost) -> Payload
}

extension TerminalPTYProductionFenceOperation where Payload == TerminalPTYFrameState {
    /// Drains one frame's damage and effects for an initialization or checkpoint read.
    package static var frameState: Self {
        Self { owner in owner.drainedFrameState() }
    }
}

extension TerminalPTYProductionFenceOperation
where Payload == (
    frameState: TerminalPTYFrameState,
    result: PaneProcessLifecycleResult?
) {
    /// Drains one frame together with the lifecycle evidence a delivery fence consumes.
    package static var consumptionState: Self {
        Self { owner in owner.drainedConsumptionState() }
    }
}

extension TerminalPTYProductionFenceOperation
where Payload == (
    frameState: TerminalPTYFrameState,
    capture: TerminalFlightRecordingCapture
) {
    /// Captures a diagnostic boundary before failure cleanup can discard the evidence.
    package static var diagnosticState: Self {
        Self { owner in owner.drainedDiagnosticState() }
    }
}

extension TerminalPTYProductionFenceOperation where Payload == Terminal {
    /// Detaches delivery, starts shutdown, and hands back the terminal to cache.
    package static var beginCloseAndSnapshot: Self {
        Self { owner in owner.beginCloseAndSnapshot() }
    }
}

extension TerminalPTYProductionFenceOperation where Payload == Void {
    /// Installs the pane consumer's wakeup unless teardown has already finished.
    package static func installUpdateHandler(
        _ handler: @escaping @Sendable (TerminalPTYUpdateSignal) -> Void
    ) -> Self {
        Self { owner in owner.installUpdateHandler(handler) }
    }
}

/// Lets the controller cross-check its attributed count against the host's raw count.
package struct TerminalPTYProductionFenceResult<Payload: Sendable>: Sendable {
    package let payload: Payload
    package let entryCount: UInt64
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

/// Pairs serialized terminal state with the first recorder event outside that state.
///
/// Only `TerminalFlightRecordingStatePairing.resolve()` can mint one, so every value of
/// this type carries state bytes and a cursor read in the same owner turn.
public struct TerminalFlightRecordingStateSynchronization: Equatable, Sendable {
    /// Terminal-protocol bytes and the geometry needed to replay them.
    public let state: TerminalStateSynchronization

    /// The same grid `state` carries, stated with the pinnedness the recorder held at the
    /// pairing's fence. A sync payload replaces a replica outright, so it must restate the
    /// whole geometry fact rather than leave pinnedness to the events around it.
    public let geometry: NeutralTerminalGeometry

    /// The effective terminal focus the paired terminal held at the fence. Focus is retained
    /// terminal state and `state.bytes` restates none of it, so a consumer that rebuilt from
    /// the bytes alone would answer a later `DECSET 1004` with focus the pane never held.
    public let focused: Bool

    /// Recorder position taken in the same owner turn as `state`.
    public let cursor: TerminalFlightRecordingCursor

    fileprivate init(
        state: TerminalStateSynchronization,
        pinned: Bool,
        focused: Bool,
        cursor: TerminalFlightRecordingCursor
    ) {
        self.state = state
        geometry = .init(columns: state.columns, rows: state.rows, pinned: pinned)
        self.focused = focused
        self.cursor = cursor
    }
}

/// Holds a fence-copied terminal beside the recorder cursor paired with it, and defers the
/// serialization of that terminal to `resolve()`.
///
/// The pairing exists so state and cursor cannot come from different owner turns: only the
/// isolated mints below can build one, and they derive both ingredients off the owner
/// themselves rather than taking either from a caller. Serializing is separate because it
/// walks the whole retained history, which must not run on the owner queue -- and because a
/// stream that ships recorder events instead never has to pay for it at all.
public struct TerminalFlightRecordingStatePairing: Sendable {
    private let terminal: Terminal
    private let pinned: Bool
    private let cursor: TerminalFlightRecordingCursor

    fileprivate init(terminal: Terminal, pinned: Bool, cursor: TerminalFlightRecordingCursor) {
        self.terminal = terminal
        self.pinned = pinned
        self.cursor = cursor
    }

    /// Serializes the paired terminal into replay bytes -- the one place in this package
    /// that does so -- spending at most `historyBudgetBytes` on retained history; `nil`
    /// carries all of it.
    ///
    /// Call it only after the fence that minted the pairing has returned, and only once the
    /// stream has selected a synchronization for the wire. Without a budget the cost is
    /// proportional to retained scrollback, so resolving inside a fence closure would stall
    /// the owner queue that also ingests PTY output. The terminal is a fenced copy, so the
    /// bytes state the fence's moment however much the live pane ingested since.
    public func resolve(historyBudgetBytes: Int?) -> TerminalFlightRecordingStateSynchronization {
        TerminalFlightRecordingStateSynchronization(
            state: terminal.stateSynchronization(historyBudgetBytes: historyBudgetBytes),
            pinned: pinned,
            focused: terminal.isFocused,
            cursor: cursor
        )
    }
}

/// Owns one pane's mutable terminal, lifecycle reducer, PTY, child, and event sources.
public actor TerminalPTYHost {
    /// Which typed handle a retained source belongs to.
    ///
    /// Every source names its slot when it registers, so the teardown walk can drop the
    /// handle without a ladder that lists sources by name. A new source cannot skip this:
    /// it has to add a case, and the switch over the slots stops compiling until it does.
    private enum SourceSlot {
        case read
        case write
        case canonicalInputRetry
        case process
        case childExitPoll
        case grace
        case sessionPoll
        case exitBound
    }

    /// One source libdispatch has not released yet, with the slot it came from.
    private struct RetainedSource {
        let source: any DispatchSourceProtocol
        let slot: SourceSlot
    }

    /// One pending submission owns its bytes and the facts needed when a later write crosses.
    private struct PendingInputRecord {
        let bytes: [UInt8]
        let origin: UInt64?
        let submissionId: PaneInputSubmissionId?
        /// Who chose these bytes, decided where they were submitted and carried to the tape,
        /// because a partial write records at transmission and cannot ask again by then.
        let attribution: TerminalFlightRecordingWriteAttribution
    }

    /// Says whether one submission is the user acting on this pane, and if so which
    /// wait the caller held when it submitted.
    ///
    /// The distinction lives here because this is the layer that knows it: the owner
    /// chose the bytes, so it also knows whether they answer a person or settle the
    /// pane's own business with the child. `.pane` covers focus reports and the
    /// terminal's replies, which arrive without anyone touching the pane.
    private enum PaneInputAttribution {
        case user(waitGeneration: PaneInputWaitGeneration?)
        case pane

        /// How this submission's bytes name their chooser once they reach the tape. The wait
        /// generation is a delivery concern and has no place on a recording.
        var recorded: TerminalFlightRecordingWriteAttribution {
            switch self {
            case .user: .user
            case .pane: .pane
            }
        }
    }

    /// One submission still owed a result, holding what to call and what the delivery
    /// means, so a completed write reports its occurrence in the same step it replies.
    private struct PendingInputSubmission {
        let attribution: PaneInputAttribution
        let completion: @Sendable (PaneInputSubmissionResult) -> Void
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

    /// How long an oversized canonical input segment may wait for a lossless raw-mode path.
    static let defaultCanonicalInputWait: DispatchTimeInterval = .seconds(5)

    private static let canonicalInputRetryInterval: DispatchTimeInterval = .milliseconds(10)

    private static let forcedCensusRetryInterval: UInt32 = 1000

    /// The most bytes one read turn takes before it returns to the queue. See `readReady`
    /// for what the constant buys and why 16 KiB is where it sits.
    private static let readTurnLimit = 16 * 1024

    private let queue: DispatchSerialQueue
    /// Read on the owner queue, written from whatever thread submits, so it is not
    /// actor state: every `nonisolated` submission below either enters a resize into
    /// the open run or closes it.
    private let resizeCoalescer = ResizeCoalescer()
    private var reducer = PaneProcessLifecycleReducer()
    private var terminal: Terminal
    private let launchInput: LaunchPolicyInput
    /// Whether this pane's tape keeps the interaction intent behind its boundary events, which
    /// is also what makes the pane eligible to yield a characterization recording. Copied from
    /// the recorder's own configuration at construction, so there is no second switch that can
    /// disagree with what the recorder actually does.
    package nonisolated let recordsInteractionIntent: Bool
    private let bootstrapExecutable: String
    private let childExitProbe: any TerminalPTYChildExitProbing
    private let resourceLifecycle: any TerminalPTYResourceLifecycling
    private let spawner: any TerminalPTYSpawning

    private var masterFD: Int32 = -1
    private var leaderPID: pid_t?
    private var sessionID: pid_t?
    private var leaderReaped = false
    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?
    private var canonicalInputRetrySource: (any DispatchSourceTimer)?
    private var canonicalInputDeadline: DispatchTime?
    private var processSource: (any DispatchSourceProcess)?
    private var childExitPollSource: (any DispatchSourceTimer)?
    private var graceSource: (any DispatchSourceTimer)?
    private var sessionPollSource: (any DispatchSourceTimer)?
    private var sessionPollStage: TeardownStage?
    private var sessionPollStageSignaled = false
    private var retainedSources: [Int: RetainedSource] = [:]
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

    /// One entry per submission still short of the PTY, oldest first. Each record owns its
    /// payload, so advancing or rejecting the head never rebases the submissions behind it.
    private var pendingInputRecords: Deque<PendingInputRecord> = []
    private var pendingInputHeadOffset = 0
    private var pendingInputByteCount = 0
    private var nextInputSubmissionRawValue: UInt64 = 1
    private var inputSubmissions: [PaneInputSubmissionId: PendingInputSubmission] = [:]
    /// Semantics the owner itself produced, waiting for the drain that carries the
    /// terminal's. Held rather than pushed so a consumer that has not attached yet,
    /// or a fence that arrives first, still receives them exactly once.
    private var pendingOwnerSemanticEvents: [PaneSemanticEvent] = []
    private var pendingEvents: [PaneProcessLifecycleEvent] = []
    private var isReducing = false

    /// The one buffer every read turn fills, allocated and zero-filled once per host.
    /// Successive `read()` returns land at successive offsets of it, so a turn costs one
    /// syscall per read and no allocation at all until the turn ends.
    private var turnStorage = [UInt8](repeating: 0, count: TerminalPTYHost.readTurnLimit)

    private var interactionState = TerminalInteractionState()
    /// The pane's one record of what it applied. Every pane records from birth: there is no
    /// seam that creates or destroys this after construction, so "a pane that kept no evidence
    /// of itself" is unreachable, and no second capture surface can disagree with it.
    private let flightTape: TerminalFlightRecorder
    private var reportedResult: PaneProcessLifecycleResult?
    private var pendingProcessStarted = false
    private var teardownFinished = false
    private let applicationExitBound: DispatchTimeInterval
    private let canonicalInputWait: DispatchTimeInterval
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

    /// Creates an owner from the immutable launch request before any lifecycle work starts.
    public init(
        launchInput: LaunchPolicyInput,
        initialGridPinned: Bool = false,
        bootstrapExecutable: String,
        machineHostname: String? = MachineHostname.posix,
        programVersion: String = "dev",
        defaultColors: TerminalDefaultColors = .baked
    ) throws {
        try self.init(
            launchInput: launchInput,
            initialGridPinned: initialGridPinned,
            bootstrapExecutable: bootstrapExecutable,
            machineHostname: machineHostname,
            programVersion: programVersion,
            defaultColors: defaultColors,
            flightTapeConfiguration: .production
        )
    }

    #if DANTERM_TERMINAL_CHARACTERIZATION
    /// Selects complete tape retention for characterization builds without exposing package policy.
    public init(
        launchInput: LaunchPolicyInput,
        initialGridPinned: Bool = false,
        bootstrapExecutable: String,
        machineHostname: String? = MachineHostname.posix,
        programVersion: String = "dev",
        defaultColors: TerminalDefaultColors = .baked,
        recordsCompleteTape: Bool
    ) throws {
        try self.init(
            launchInput: launchInput,
            initialGridPinned: initialGridPinned,
            bootstrapExecutable: bootstrapExecutable,
            machineHostname: machineHostname,
            programVersion: programVersion,
            defaultColors: defaultColors,
            flightTapeConfiguration: recordsCompleteTape ? .complete : .production
        )
    }
    #endif

    /// `applicationExitBound` is injected only so a test can drive the forced
    /// quiescence path deterministically instead of waiting out the real bound.
    package init(
        launchInput: LaunchPolicyInput,
        initialGridPinned: Bool = false,
        bootstrapExecutable: String,
        machineHostname: String? = MachineHostname.posix,
        programVersion: String = "dev",
        defaultColors: TerminalDefaultColors = .baked,
        flightTapeConfiguration: TerminalFlightRecorderConfiguration = .production,
        flightTapeClock: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        applicationExitBound: DispatchTimeInterval = TerminalPTYHost.defaultApplicationExitBound,
        canonicalInputWait: DispatchTimeInterval = TerminalPTYHost.defaultCanonicalInputWait,
        childExitProbe: any TerminalPTYChildExitProbing = SystemTerminalPTYChildExitProbe(),
        resourceLifecycle: any TerminalPTYResourceLifecycling = SystemTerminalPTYResourceLifecycle(),
        spawner: any TerminalPTYSpawning = SystemTerminalPTYSpawner()
    ) throws {
        let initialDimensions = launchInput.initialDimensions
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
        self.launchInput = launchInput
        self.bootstrapExecutable = bootstrapExecutable
        recordsInteractionIntent = flightTapeConfiguration.recordsInteractionIntent
        self.applicationExitBound = applicationExitBound
        self.canonicalInputWait = canonicalInputWait
        self.childExitProbe = childExitProbe
        self.resourceLifecycle = resourceLifecycle
        self.spawner = spawner
        flightTape = TerminalFlightRecorder(
            initialGeometry: .init(
                columns: initialDimensions.columns,
                rows: initialDimensions.rows,
                pinned: initialGridPinned
            ),
            configuration: flightTapeConfiguration,
            now: flightTapeClock
        )
        flightTape.setFollowStatePairingSource { [unowned self] in
            self.assumeIsolated { owner in owner.liveStatePairing() }
        }
    }

    /// Starts the pure launch plan and returns after scheduling its system spawn.
    public func start(
        onInitialInputCompletion: (@Sendable (PaneInputSubmissionResult) -> Void)? = nil
    ) {
        if let onInitialInputCompletion {
            let submissionId = registerInputSubmission(
                attribution: .pane,
                onCompletion: onInitialInputCompletion
            )
            process(.trackInitialInput(submissionId))
        }
        process(.start(launchInput))
    }

    /// Enqueues launch before synchronous pane submissions without requiring a Task hop.
    nonisolated public func submitStart(
        onInitialInputCompletion: (@Sendable (PaneInputSubmissionResult) -> Void)? = nil
    ) {
        queueClosingResizeRun().async { [weak self] in
            guard let self else {
                onInitialInputCompletion?(.rejected(.processEnded))
                return
            }
            self.assumeIsolated { owner in
                owner.start(onInitialInputCompletion: onInitialInputCompletion)
            }
        }
    }

    /// Enqueues user bytes directly on the owner queue without an ordering-opaque Task.
    nonisolated public func send(
        _ bytes: [UInt8],
        origin: UInt64? = nil,
        waitGeneration: PaneInputWaitGeneration? = nil,
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
                owner.applyViewportNavigation(.toBottom, publishUpdate: false)
                owner.submitInput(
                    bytes,
                    origin: origin,
                    attribution: .user(waitGeneration: waitGeneration),
                    onCompletion: onCompletion
                )
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
        waitGeneration: PaneInputWaitGeneration? = nil,
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
                    waitGeneration: waitGeneration,
                    onCompletion: onCompletion
                )
            }
        }
    }

    /// Enqueues unsanitized text for owner-side safe-paste policy and atomic marker generation.
    nonisolated public func sendPaste(
        _ text: String,
        origin: UInt64? = nil,
        waitGeneration: PaneInputWaitGeneration? = nil,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        queueClosingResizeRun().async { [weak self] in
            guard let self else {
                onCompletion(.rejected(.processEnded))
                return
            }
            self.assumeIsolated { owner in
                owner.applyPaste(
                    text,
                    origin: origin,
                    waitGeneration: waitGeneration,
                    onCompletion: onCompletion
                )
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
    nonisolated public func resize(_ grid: PaneGridSubmission) {
        let submission = resizeCoalescer.submitResize()
        queue.async { [weak self] in
            self?.assumeIsolated { owner in
                guard owner.resizeCoalescer.isSuperseded(submission) == false else { return }
                owner.process(.resize(grid))
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
                owner.applyViewportNavigation(.byRows(rowDelta), publishUpdate: true)
            }
        }
    }

    /// Enqueues absolute scrollbar navigation in current-stream row coordinates.
    nonisolated public func scroll(toTopRow row: Int) {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applyViewportNavigation(.toTopRow(row), publishUpdate: true)
            }
        }
    }

    /// Enqueues an explicit return to live-bottom follow.
    nonisolated public func scrollToBottom() {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applyViewportNavigation(.toBottom, publishUpdate: true)
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
        waitGeneration: PaneInputWaitGeneration? = nil,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        queueClosingResizeRun().async { [weak self] in
            guard let self else {
                onCompletion(.rejected(.processEnded))
                return
            }
            self.assumeIsolated { owner in
                owner.applyWheel(
                    event,
                    origin: origin,
                    waitGeneration: waitGeneration,
                    onCompletion: onCompletion
                )
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
        waitGeneration: PaneInputWaitGeneration? = nil,
        onOpenLink: @escaping @Sendable (TerminalHyperlink) -> Void = { _ in },
        onSelectionCompleted: (@Sendable (String) -> Void)? = nil
    ) {
        queueClosingResizeRun().async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applyPointer(
                    event,
                    origin: origin,
                    waitGeneration: waitGeneration,
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
        retainUntilCancellation(timer, slot: .exitBound, descriptorBacked: false)
        exitBoundSource = timer
        timer.activate()
    }

    private func cancelExitBound() {
        exitBoundSource?.cancel()
        forgetSource(.exitBound)
    }

    /// Retains one source through its cancellation callback and enrolls
    /// descriptor-backed sources in the PTY close barrier.
    private func retainUntilCancellation<Source: DispatchSourceProtocol>(
        _ source: Source,
        slot: SourceSlot,
        descriptorBacked: Bool
    ) {
        let id = nextSourceID
        nextSourceID += 1
        source.setCancelHandler { [weak self] in
            self?.assumeIsolated { owner in
                owner.sourceCancellationHandlerRan(id)
            }
        }
        retainedSources[id] = RetainedSource(source: source, slot: slot)
        if descriptorBacked {
            descriptorSourceIDs.insert(id)
        }
    }

    /// Cancels every source the host still owns, so neither teardown ladder can
    /// forget one.
    ///
    /// Both ladders call this instead of enumerating sources by name: a source added
    /// later, by code that edits neither ladder, is torn down anyway. Each entry is
    /// activated first because cancelling a source that was never activated only
    /// records the request -- its cancel handler cannot run, so the entry would stay
    /// in the registry forever and quiescence would never arrive. Activating a source
    /// that is already active does nothing.
    private func cancelAllRetainedSources() {
        for entry in Array(retainedSources.values) {
            entry.source.activate()
            entry.source.cancel()
            forgetSource(entry.slot)
        }
    }

    /// Drops the host's typed handle to a cancelled source, and any tracking state
    /// that only means something while that source is armed.
    ///
    /// Called at cancel time, never when a cancellation is acknowledged: the typed
    /// handle means "the source this host still drives", while the registry means
    /// "sources libdispatch has not released yet". A replace-on-arm source depends on
    /// the difference -- a predecessor awaiting release must not clear the handle its
    /// successor now occupies.
    private func forgetSource(_ slot: SourceSlot) {
        switch slot {
        case .read:
            readSource = nil
        case .write:
            writeSource = nil
        case .canonicalInputRetry:
            clearCanonicalInputHoldTracking()
        case .process:
            processSource = nil
        case .childExitPoll:
            childExitPollSource = nil
        case .grace:
            graceSource = nil
        case .sessionPoll:
            clearSessionPollTracking()
        case .exitBound:
            exitBoundSource = nil
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
    /// could still be running would satisfy the bound by giving up a session that
    /// may still be alive, which is not what the bound promises.
    private func exitBoundElapsed() {
        guard teardownFinished == false else { return }
        forcedQuiescenceCount += 1
        forcedCleanupAfterMasterClose = true
        reducerAwaitsMasterClose = false
        // Every driver of the reducer stops before the master closes, and the walk
        // reaches sources this path never names.
        cancelAllRetainedSources()
        // Last: it owns the descriptor seal and the join barrier that re-enters
        // forced cleanup once the descriptor sources have released.
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
    package nonisolated func performProductionFence<Payload: Sendable>(
        _ operation: TerminalPTYProductionFenceOperation<Payload>
    ) -> TerminalPTYProductionFenceResult<Payload> {
        let fenced = fence(countsAsProduction: true) { owner in operation.build(owner) }
        return TerminalPTYProductionFenceResult(
            payload: fenced.value,
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

    /// Pairs the owner's terminal with the recorder's live cursor, taking neither from the
    /// caller so the two cannot come from different owner turns.
    fileprivate func liveStatePairing() -> TerminalFlightRecordingStatePairing {
        TerminalFlightRecordingStatePairing(
            terminal: terminal,
            pinned: flightTape.currentGeometry.pinned,
            cursor: flightTape.liveCursor()
        )
    }

    /// Fences retained tape, remote cursor placement, live geometry, and the pane's state for
    /// stream policy. Nothing here is serialized: the fence hands back the state unresolved so
    /// only a stream that ships a synchronization pays to encode one.
    package nonisolated func fencedFlightRecordingStream(
        request: TerminalFlightRecordingStreamRequest
    ) -> TerminalFlightRecordingStreamFence {
        fence(countsAsProduction: false) { owner in
            owner.flightTape.streamFence(request: request) { owner.liveStatePairing() }
        }.value
    }

    /// Copies the retained suffix and exact cursor gap in one owner-queue fence.
    package nonisolated func fencedFlightRecording(
        from cursor: TerminalFlightRecordingCursor
    ) -> TerminalFlightRecordingCursorSnapshot {
        fence(countsAsProduction: false) { owner in
            owner.flightTape.cursorSnapshot(from: cursor)
        }.value
    }

    /// Registers one recorder-owned follow state machine at an opening cursor.
    package nonisolated func addFlightRecordingFollowSubscription(
        id: UUID,
        from cursor: TerminalFlightRecordingCursor,
        replicaHistoryIsComplete: Bool,
        decide: @escaping @Sendable (
            TerminalFlightRecordingCursorSnapshot,
            Bool
        ) -> TerminalFlightRecordingFollowDecision,
        deliver: @escaping @Sendable (TerminalFlightRecordingFollowBatch) -> Void
    ) -> Bool {
        fence(countsAsProduction: false) { owner in
            owner.flightTape.addFollowSubscription(
                id: id,
                from: cursor,
                replicaHistoryIsComplete: replicaHistoryIsComplete,
                decide: decide,
                deliver: deliver
            )
        }.value
    }

    /// Rearms one subscription asynchronously after its previous write flushes.
    package nonisolated func markFlightRecordingFollowSubscriptionReady(
        id: UUID,
        replicaHistoryIsComplete: Bool
    ) {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in
                owner.flightTape.markFollowSubscriptionReady(
                    id: id,
                    replicaHistoryIsComplete: replicaHistoryIsComplete
                )
            }
        }
    }

    /// Removes one recorder-owned subscription on its owner queue.
    package nonisolated func removeFlightRecordingFollowSubscription(id: UUID) {
        _ = fence(countsAsProduction: false) { owner in
            owner.flightTape.removeFollowSubscription(id: id)
        }
    }

    /// Fences subscription membership for test-only lifetime assertions.
    package nonisolated func hasFlightRecordingFollowSubscription(id: UUID) -> Bool {
        fence(countsAsProduction: false) { owner in
            owner.flightTape.hasFollowSubscription(id: id)
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
        result: PaneProcessLifecycleResult?
    ) {
        fence(countsAsProduction: false) { owner in owner.drainedConsumptionState() }.value
    }

    /// The one owner-isolated build of the consumption payload, shared by the production fence
    /// and its test counterpart so `countsAsProduction:` stays the only difference between the
    /// two paths. It carries no recording: a reader that wants one pulls the tape when it asks,
    /// so which fence happened to observe the child's exit cannot decide whether it gets one.
    fileprivate func drainedConsumptionState() -> (
        frameState: TerminalPTYFrameState,
        result: PaneProcessLifecycleResult?
    ) {
        (drainedFrameState(), reportedResult)
    }

    /// Captures a test-only diagnostic boundary before failure cleanup can discard evidence.
    package nonisolated func fencedDiagnosticState() -> (
        frameState: TerminalPTYFrameState,
        capture: TerminalFlightRecordingCapture
    ) {
        fence(countsAsProduction: false) { owner in owner.drainedDiagnosticState() }.value
    }

    /// The one owner-isolated build of the diagnostic payload, shared by the production fence
    /// and its test counterpart. The drain precedes the tape read on purpose: a diagnostic
    /// capture wants every transition applied up to the boundary the drain just established.
    fileprivate func drainedDiagnosticState() -> (
        frameState: TerminalPTYFrameState,
        capture: TerminalFlightRecordingCapture
    ) {
        (drainedFrameState(), flightTape.capture())
    }

    /// Detaches the pane consumer and starts bounded shutdown, returning the terminal the
    /// controller caches as its final one. Owner-isolated so the detach, the shutdown, and the
    /// copy are one indivisible step: a signal delivered between them would reach a consumer
    /// that has stopped reading.
    fileprivate func beginCloseAndSnapshot() -> Terminal {
        updateHandler = nil
        beginShutdown(completion: nil)
        return terminal
    }

    /// Installs the pane consumer's wakeup, dropping it once teardown has finished so a
    /// late installation cannot resurrect delivery on a host that has stopped.
    fileprivate func installUpdateHandler(
        _ handler: @escaping @Sendable (TerminalPTYUpdateSignal) -> Void
    ) {
        guard teardownFinished == false else { return }
        updateHandler = handler
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

    fileprivate func drainedFrameState() -> TerminalPTYFrameState {
        let damage = terminal.drainDamage()
        let clipboardWrite = terminal.drainPendingClipboardWrite()
        let semanticEvents = drainSemanticEvents()
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
    /// Stages output on a host that a test is using as a fixture, so a consumer's own
    /// behavior can be asserted against a known screen.
    ///
    /// This is not a way to drive the host: it skips the read path entirely, and the host's
    /// own suite must reach the byte plane through a real PTY master descriptor instead
    /// (`scripts/terminal-pty-host-test-seam-lint.sh` enforces that). It exists for a
    /// consumer test -- pane-session publish deadlines and synchronization fences -- that
    /// needs a screen to assert against and does not care how the bytes arrived. Applying
    /// synchronously lets such a test queue callbacks without yielding main.
    package nonisolated func stageFixtureOutput(_ bytes: [UInt8]) {
        guard bytes.isEmpty == false else { return }
        _ = fence(countsAsProduction: false) { owner in
            owner.applyFixtureTurn(bytes)
            owner.publishPendingUpdate()
        }
    }

    /// One whole read turn applied from bytes the caller already holds, so the seam above
    /// reaches the terminal through the same turn-end bookkeeping the read path uses.
    private func applyFixtureTurn(_ bytes: [UInt8]) {
        let previousConsumerWorkGeneration = terminal.pendingConsumerWorkGeneration
        terminal.feed(bytes)
        finishOutputTurn(
            bytes,
            replies: terminal.drainReplyBytes(),
            previousConsumerWorkGeneration: previousConsumerWorkGeneration
        )
    }
    #endif

    package enum InteractionForTesting: Sendable {
        case pointer(TerminalPointerEvent)
        case cancelLinkInteraction
        case clearSelection
        case beginSearch(String)
        case selectAll
        case scrollByRows(Int)
        case resize(PaneGridSubmission)
    }

    package nonisolated func applyInteractionForTesting(_ interaction: InteractionForTesting) {
        _ = fence(countsAsProduction: false) { owner in
            switch interaction {
            case .pointer(let event):
                owner.applyPointer(
                    event,
                    origin: nil,
                    waitGeneration: nil,
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
                owner.applyViewportNavigation(.byRows(rows), publishUpdate: true)
            case .resize(let grid):
                owner.process(.resize(grid))
            }
        }
    }

    /// Returns the reported child result without waiting for future lifecycle work.
    public func result() -> PaneProcessLifecycleResult? {
        reportedResult
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
            pendingInputByteCount: pendingInputByteCount,
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
        waitGeneration: PaneInputWaitGeneration?,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void
    ) {
        guard teardownFinished == false else {
            onCompletion(.rejected(.processEnded))
            return
        }
        let decision = decideTerminalWheel(event, terminal: terminal, state: &interactionState)
        if decision.inputBytes.isEmpty == false {
            submitInput(
                decision.inputBytes,
                origin: origin,
                attribution: .user(waitGeneration: waitGeneration),
                onCompletion: onCompletion
            )
            return
        }
        if decision.localRowDelta != 0 {
            applyViewportNavigation(
                .byRows(decision.localRowDelta),
                publishUpdate: true
            )
        }
        onCompletion(.delivered)
    }

    private func applyPointer(
        _ event: TerminalPointerEvent,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?,
        onOpenLink: @Sendable (TerminalHyperlink) -> Void,
        onSelectionCompleted: (@Sendable (String) -> Void)?
    ) {
        guard teardownFinished == false else { return }
        flightTape.record(.mouse(.init(event)))
        let decision = decideTerminalPointer(event, terminal: terminal, state: &interactionState)
        if decision.inputBytes.isEmpty == false {
            submitInput(
                decision.inputBytes,
                origin: origin,
                attribution: .user(waitGeneration: waitGeneration)
            )
        }
        applyTerminalPointerDecision(decision, to: &terminal)
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
        markFrameUpdatePendingIfNeeded()
        publishPendingUpdate()
        if let link = decision.openLink {
            onOpenLink(link)
        }
    }

    private func applyLinkCancellation() {
        guard teardownFinished == false else { return }
        let cancellation = cancelTerminalLinkInteraction(state: &interactionState)
        applyTerminalLinkCancellation(cancellation, to: &terminal)
        markFrameUpdatePendingIfNeeded()
        publishPendingUpdate()
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
        onStatus(terminal.searchReadout?.status)
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
        waitGeneration: PaneInputWaitGeneration?,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void
    ) {
        guard teardownFinished == false else {
            onCompletion(.rejected(.processEnded))
            return
        }
        if case .localViewport(let scroll) = decideTerminalKey(
            key, modifiers: modifiers, terminal: terminal
        ) {
            // No input event on the tape: the child was sent nothing, and recording the key
            // would make every replay write `ESC[5~` into the replica. The navigation below
            // records itself, and only when the viewport actually moved.
            applyViewportNavigation(navigation(for: scroll), publishUpdate: true)
            // Completed as delivered like the empty-bytes path below, so the input-wait
            // bookkeeping stays balanced for a submission that produced no write.
            onCompletion(.delivered)
            return
        }
        flightTape.record(.input(key: key, modifiers: modifiers))
        let bytes = encodeTerminalKey(key, modifiers: modifiers, modes: terminal.inputModes)
        guard bytes.isEmpty == false else {
            onCompletion(.delivered)
            return
        }
        applyViewportNavigation(.toBottom, publishUpdate: false)
        submitInput(
            bytes,
            origin: origin,
            attribution: .user(waitGeneration: waitGeneration),
            onCompletion: onCompletion
        )
    }

    private func applyPaste(
        _ text: String,
        origin: UInt64?,
        waitGeneration: PaneInputWaitGeneration?,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void
    ) {
        guard teardownFinished == false else {
            onCompletion(.rejected(.processEnded))
            return
        }
        flightTape.record(.paste(text))
        let bytes = encodeTerminalPaste(text, modes: terminal.inputModes)
        guard bytes.isEmpty == false else {
            onCompletion(.delivered)
            return
        }
        applyViewportNavigation(.toBottom, publishUpdate: false)
        submitInput(
            bytes,
            origin: origin,
            attribution: .user(waitGeneration: waitGeneration),
            onCompletion: onCompletion
        )
    }

    private func applyFocus(_ focused: Bool, origin: UInt64?) {
        guard teardownFinished == false else { return }
        flightTape.record(.focus(focused))
        let bytes = terminal.setFocused(focused)
        guard bytes.isEmpty == false else { return }
        // The pane's own report of a focus change the user never aimed at the child.
        submitInput(bytes, origin: origin, attribution: .pane)
    }

    /// Restates a policy scroll in the tape's navigation vocabulary. The two enums are
    /// separate because `TerminalCore` cannot see `TerminalCoreRecording`, and this is the one
    /// place that has to hold both.
    private func navigation(
        for scroll: TerminalViewportScroll
    ) -> NeutralTerminalViewportNavigation {
        switch scroll {
        case .byRows(let rows): .byRows(rows)
        case .toTopRow(let row): .toTopRow(row)
        case .toBottom: .toBottom
        }
    }

    /// Takes the three-case navigation vocabulary the tape already speaks, so "a navigation
    /// that is not a navigation" has no representation to reject at runtime.
    private func applyViewportNavigation(
        _ navigation: NeutralTerminalViewportNavigation,
        publishUpdate: Bool
    ) {
        guard teardownFinished == false else { return }
        let previousViewport = terminal.scrollProjection
        switch navigation {
        case .byRows(let rows): terminal.scroll(byRows: rows)
        case .toTopRow(let row): terminal.scroll(toTopRow: row)
        case .toBottom: terminal.scrollToBottom()
        }
        // Only an effective move is recorded: a navigation the viewport did not follow is a
        // request, not a transition, and replaying it would move a replica the pane never moved.
        if terminal.scrollProjection != previousViewport {
            flightTape.record(.viewport(navigation))
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
            enqueueInput(
                bytes,
                origin: origin,
                submissionId: submissionId,
                attribution: writeAttribution(of: submissionId)
            )
        case .completeInput(let submissionId, let result):
            completeInput(submissionId, with: result)
        case .resize(let grid):
            applyResize(grid)
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
            // Delivered in the same owner turn that installed the sources, so no spawn
            // source outlives this turn unactivated, and the generation check above is
            // the only path from a spawn outcome to the reducer.
            process(.spawnSucceeded)
        case .failure(let failure):
            process(.spawnFailed(failure))
        }
    }

    private func installSources(for spawned: SpawnedPTY) {
        let read = DispatchSource.makeReadSource(fileDescriptor: spawned.master, queue: queue)
        read.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.readSourceFired() }
        }
        retainUntilCancellation(read, slot: .read, descriptorBacked: true)
        readSource = read

        // A channel with no child behind it has no process to watch. The rest of the
        // process plane already treats an absent leader and session as nothing to do,
        // so this host simply ends on the channel's own end-of-output edge.
        guard let leader = spawned.leader else { return }
        let process = DispatchSource.makeProcessSource(
            identifier: leader,
            eventMask: .exit,
            queue: queue
        )
        process.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.processSourceFired() }
        }
        retainUntilCancellation(process, slot: .process, descriptorBacked: false)
        processSource = process
    }

    private func activateIO() {
        guard descriptorOwnershipSealed == false else {
            closeMaster()
            return
        }
        readSource?.activate()
        processSource?.activate()
    }

    private func submitInput(
        _ bytes: [UInt8],
        origin: UInt64?,
        attribution: PaneInputAttribution,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void = { _ in }
    ) {
        let submissionId = registerInputSubmission(
            attribution: attribution,
            onCompletion: onCompletion
        )
        process(.sendInput(bytes, origin: origin, submissionId: submissionId))
    }

    private func registerInputSubmission(
        attribution: PaneInputAttribution,
        onCompletion: @escaping @Sendable (PaneInputSubmissionResult) -> Void
    ) -> PaneInputSubmissionId {
        let submissionId = PaneInputSubmissionId(rawValue: nextInputSubmissionRawValue)
        nextInputSubmissionRawValue &+= 1
        precondition(inputSubmissions[submissionId] == nil, "input submission identity wrapped")
        inputSubmissions[submissionId] = PendingInputSubmission(
            attribution: attribution,
            completion: onCompletion
        )
        return submissionId
    }

    /// Who chose the bytes of one write the reducer released. Launch input is pane-owned,
    /// while an absent identity covers terminal replies that need no completion result.
    private func writeAttribution(
        of submissionId: PaneInputSubmissionId?
    ) -> TerminalFlightRecordingWriteAttribution {
        guard let submissionId, let submission = inputSubmissions[submissionId] else {
            return .pane
        }
        return submission.attribution.recorded
    }

    private func enqueueInput(
        _ bytes: [UInt8],
        origin: UInt64?,
        submissionId: PaneInputSubmissionId?,
        attribution: TerminalFlightRecordingWriteAttribution
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
        guard bytes.count <= PaneProcessLifecycleReducer.pendingInputByteLimit - pendingInputByteCount else {
            if let submissionId {
                completeInput(submissionId, with: .rejected(.bufferLimitExceeded))
            }
            return
        }
        pendingInputRecords.append(.init(
            bytes: bytes,
            origin: origin,
            submissionId: submissionId,
            attribution: attribution
        ))
        pendingInputByteCount += bytes.count
        flushInput()
    }

    private func flushInput() {
        guard descriptorOwnershipSealed == false, masterFD >= 0 else {
            rejectPendingInput(because: .processEnded)
            cancelWriteSource()
            return
        }
        let turnLimit = 64 * 1024
        var writtenThisTurn = 0
        while let record = pendingInputRecords.first, writtenThisTurn < turnLimit {
            guard prepareCurrentInputRecordForWrite() else { return }
            let result = record.bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                let remaining = min(
                    record.bytes.count - pendingInputHeadOffset,
                    turnLimit - writtenThisTurn
                )
                return Darwin.write(masterFD, base.advanced(by: pendingInputHeadOffset), remaining)
            }
            if result > 0 {
                recordWrittenInput(count: result)
                writtenThisTurn += result
                continue
            }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
            let code = errno
            rejectPendingInput(because: .writeFailed(code))
            return
        }
        if pendingInputRecords.isEmpty {
            clearPendingInput()
            cancelWriteSource()
        } else {
            installWriteSourceIfNeeded()
        }
    }

    /// Re-evaluates the current whole submission before any of its pending bytes cross.
    private func prepareCurrentInputRecordForWrite() -> Bool {
        guard let record = pendingInputRecords.first else { return true }
        var attributes = termios()
        guard tcgetattr(masterFD, &attributes) == 0 else {
            let code = errno
            rejectPendingInput(because: .writeFailed(code))
            return false
        }
        guard attributes.c_lflag & tcflag_t(ICANON) != 0 else {
            cancelCanonicalInputHold()
            return true
        }
        let isOversized = CanonicalInputDeliveryGate.isOversized(
            record.bytes[pendingInputHeadOffset...],
            inputFlags: attributes.c_iflag
        )
        guard isOversized else {
            cancelCanonicalInputHold()
            return true
        }

        cancelWriteSource()
        let now = DispatchTime.now()
        if canonicalInputDeadline == nil {
            canonicalInputDeadline = now + canonicalInputWait
            installCanonicalInputRetryIfNeeded()
        }
        guard let deadline = canonicalInputDeadline, now < deadline else {
            rejectCurrentInputRecord(because: .canonicalModeTimeout)
            if pendingInputRecords.isEmpty == false { flushInput() }
            return false
        }
        return false
    }

    /// Drops only the blocked head submission so later deliverable input can still proceed.
    private func rejectCurrentInputRecord(because failure: PaneInputSubmissionFailure) {
        guard let record = pendingInputRecords.popFirst() else { return }
        pendingInputByteCount -= record.bytes.count - pendingInputHeadOffset
        pendingInputHeadOffset = 0
        cancelCanonicalInputHold()
        if let submissionId = record.submissionId {
            completeInput(submissionId, with: .rejected(failure))
        }
        if pendingInputRecords.isEmpty { clearPendingInput() }
    }

    /// Records one successful write against the head submission and advances its cursor.
    private func recordWrittenInput(count: Int) {
        guard let record = pendingInputRecords.first else { return }
        let end = pendingInputHeadOffset + count
        flightTape.recordWrite(
            Array(record.bytes[pendingInputHeadOffset..<end]),
            origin: record.origin,
            attribution: record.attribution
        )
        pendingInputHeadOffset = end
        pendingInputByteCount -= count
        if pendingInputHeadOffset == record.bytes.count {
            pendingInputRecords.removeFirst()
            pendingInputHeadOffset = 0
            if let submissionId = record.submissionId {
                completeInput(submissionId, with: .delivered)
            }
        }
    }

    /// Releases pending input without recording it: these bytes never crossed the boundary,
    /// so the tape must not claim they did.
    private func clearPendingInput() {
        cancelCanonicalInputHold()
        pendingInputRecords.removeAll(keepingCapacity: false)
        pendingInputHeadOffset = 0
        pendingInputByteCount = 0
    }

    private func rejectPendingInput(because failure: PaneInputSubmissionFailure) {
        let submissionIds = pendingInputRecords.compactMap(\.submissionId)
        clearPendingInput()
        for submissionId in submissionIds {
            completeInput(submissionId, with: .rejected(failure))
        }
    }

    private func completeInput(
        _ submissionId: PaneInputSubmissionId,
        with result: PaneInputSubmissionResult
    ) {
        guard let submission = inputSubmissions.removeValue(forKey: submissionId) else { return }
        // Delivery is the whole claim: the occurrence says these bytes reached the
        // child, so a rejection -- before the write or partway through it -- reports
        // nothing at all.
        if case .delivered = result, case .user(let waitGeneration) = submission.attribution {
            pendingOwnerSemanticEvents.append(
                .userInputDelivered(waitGeneration: waitGeneration)
            )
            markUpdatePending()
        }
        submission.completion(result)
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
        retainUntilCancellation(source, slot: .write, descriptorBacked: true)
        writeSource = source
        source.activate()
    }

    private func cancelWriteSource() {
        writeSource?.cancel()
        forgetSource(.write)
    }

    private func installCanonicalInputRetryIfNeeded() {
        guard canonicalInputRetrySource == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + Self.canonicalInputRetryInterval,
            repeating: Self.canonicalInputRetryInterval,
            leeway: .milliseconds(1)
        )
        source.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.canonicalInputRetryFired() }
        }
        retainUntilCancellation(source, slot: .canonicalInputRetry, descriptorBacked: false)
        canonicalInputRetrySource = source
        source.activate()
    }

    private func canonicalInputRetryFired() {
        guard recordSystemCallback() else { return }
        flushInput()
        if pendingOwnerSemanticEvents.isEmpty == false { publishPendingUpdate() }
    }

    private func cancelCanonicalInputHold() {
        canonicalInputRetrySource?.cancel()
        clearCanonicalInputHoldTracking()
    }

    private func clearCanonicalInputHoldTracking() {
        canonicalInputRetrySource = nil
        canonicalInputDeadline = nil
    }

    private func readSourceFired() {
        guard recordSystemCallback(), descriptorOwnershipSealed == false else { return }
        readReady()
    }

    private func writeSourceFired() {
        guard recordSystemCallback(), descriptorOwnershipSealed == false else { return }
        flushInput()
        // A submission that backpressure held finishes on this path and no other, so
        // without this a quiet pane would sit on the occurrence until its next output.
        if pendingOwnerSemanticEvents.isEmpty == false { publishPendingUpdate() }
    }

    private func processSourceFired() {
        guard recordSystemCallback() else { return }
        childExited()
    }

    /// Reads at most `readTurnLimit` bytes, then returns and lets the level-triggered read
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
    /// uncapped tree).
    ///
    /// A turn is many reads, never one. A read on a pty master returns at most one kernel
    /// clist buffer -- 1024 bytes on xnu -- so the cap is reached only by chaining sixteen
    /// of them, and chaining is not automatic either. Probed on macOS 25.5.0 against a
    /// blocked writer: a loop that does no work between reads never chains at all, because
    /// the next read returns `EAGAIN` in nanoseconds while the writer's kernel wakeup takes
    /// microseconds, and about 5us of work between reads is enough for every turn to reach
    /// the cap. That work is the parse, which is why `takeOutputTurn` feeds the terminal
    /// inside its read loop and defers everything else to the end of the turn.
    ///
    /// Turn size and delivery rate are separate levers, and the cost above is the second
    /// one: fences arriving more often, each paying a fixed ~0.15ms floor, not the shorter
    /// turn itself. If 120Hz margin is ever needed, throttle the consumer's drain cadence
    /// (fence at most once per display frame) instead of revisiting 8 KiB -- that buys the
    /// smaller cap's worst block at the old delivery count.
    private func readReady() {
        guard masterFD >= 0 else { return }
        guard takeOutputTurn(limit: Self.readTurnLimit).reachedEndOfOutput else {
            publishPendingUpdate()
            return
        }
        cancelReadSource()
        // The reduction below publishes, so the turn's last bytes reach the consumer at the
        // EOF edge instead of waiting on a child exit that may be indefinitely later.
        process(.outputEOF)
    }

    /// How a read turn ended, and how much of the descriptor it took.
    private struct OutputTurn {
        let byteCount: Int
        /// The read side reported end of output inside this turn. Whoever asked for the
        /// turn owns the EOF edge, because the two callers close it differently.
        let reachedEndOfOutput: Bool
    }

    /// Reads into the host's one turn buffer until the turn ends, feeding the terminal from
    /// each newly filled slice, then runs the turn's single pass of downstream bookkeeping.
    ///
    /// Feeding stays inside the read loop deliberately: the parse is the only gap between
    /// two reads, and it is what lets a blocked writer refill the kernel's buffer, so a loop
    /// that deferred it would take exactly one 1024-byte read per turn. Everything that is
    /// not the syscall or the parse belongs to `finishOutputTurn` instead.
    ///
    /// The turn ends at `limit`, at `EAGAIN`, at end of output, or at a feed that produced
    /// terminal reply bytes -- a reply must not wait on reads that may never come.
    private func takeOutputTurn(limit: Int) -> OutputTurn {
        let previousConsumerWorkGeneration = terminal.pendingConsumerWorkGeneration
        var replies: [UInt8] = []
        var reachedEndOfOutput = false
        let turnBytes = turnStorage.withUnsafeMutableBufferPointer { storage -> [UInt8] in
            guard let base = storage.baseAddress else { return [] }
            let cap = min(storage.count, limit)
            var filled = 0
            while filled < cap {
                let result = Darwin.read(masterFD, base + filled, cap - filled)
                if result > 0 {
                    // Safe to feed a buffer a later read overwrites: every piece of
                    // unfinished stream state accumulates by value inside the terminal.
                    terminal.feed(UnsafeBufferPointer(start: base + filled, count: result))
                    filled += result
                    replies = terminal.drainReplyBytes()
                    if replies.isEmpty == false { break }
                    continue
                }
                if result == 0 || (result < 0 && errno == EIO) {
                    reachedEndOfOutput = true
                    break
                }
                if result < 0, errno == EINTR { continue }
                break
            }
            return Array(UnsafeBufferPointer(start: base, count: filled))
        }
        finishOutputTurn(
            turnBytes,
            replies: replies,
            previousConsumerWorkGeneration: previousConsumerWorkGeneration
        )
        return OutputTurn(byteCount: turnBytes.count, reachedEndOfOutput: reachedEndOfOutput)
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
        retainUntilCancellation(timer, slot: .childExitPoll, descriptorBacked: false)
        childExitPollSource = timer
        timer.activate()
    }

    private func childExitPollFired() {
        guard recordSystemCallback() else { return }
        childExited()
    }

    private func cancelChildExitPoll() {
        childExitPollSource?.cancel()
        forgetSource(.childExitPoll)
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
        // Turn-by-turn for the same reason the read source is: the drain runs inside a
        // reduction, and the committed byte count is whatever the child left behind.
        var remaining = Int(committed)
        while remaining > 0 {
            let turn = takeOutputTurn(limit: remaining)
            remaining -= turn.byteCount
            if turn.byteCount == 0 || turn.reachedEndOfOutput { break }
        }
        // Nested in the caller's reduction, so its bytes and its tape record are both in
        // place before the outer reduction reports the child's result.
        process(.outputEOF)
    }

    /// The turn's one pass over everything downstream of the parse: the tape event, the
    /// reply flush, and the update-pending check.
    ///
    /// Turn-scoped rather than read-scoped because a read boundary on a pty master is a
    /// kernel buffer artifact and means nothing to any of them. Order is load-bearing: the
    /// `.feed` is recorded before the reply's `.write`, so a tape always carries a query
    /// ahead of the answer it produced.
    private func finishOutputTurn(
        _ bytes: [UInt8],
        replies: [UInt8],
        previousConsumerWorkGeneration: UInt64
    ) {
        guard bytes.isEmpty == false else { return }
        flightTape.record(.feed(bytes))
        if replies.isEmpty == false {
            enqueueInput(replies, origin: nil, submissionId: nil, attribution: .reply)
        }
        if pendingInputRecords.isEmpty == false { flushInput() }
        if terminal.hasPendingConsumerWork,
           consumerWorkWasSignaled == false
            || terminal.pendingConsumerWorkGeneration != previousConsumerWorkGeneration
        {
            markUpdatePending()
        }
    }

    /// The applied-geometry boundary: every distinct geometry fact the authoritative
    /// terminal applies is recorded here as exactly one event, grid and pinnedness together.
    ///
    /// A pinnedness-only change arrives with an unchanged grid. The `TIOCSWINSZ` below then
    /// installs the size the tty already holds, so the kernel raises no `SIGWINCH` and the
    /// child observes nothing, and `terminal.resize` to the current grid leaves cell content
    /// alone -- but the event still has to be recorded, because a replica that never saw it
    /// would stay wrong about the pane's pinnedness for as long as the grid held.
    private func applyResize(_ grid: PaneGridSubmission) {
        let dimensions = grid.dimensions
        guard flightTape.currentGeometry != .init(
            columns: dimensions.columns,
            rows: dimensions.rows,
            pinned: grid.pinned
        ) else { return }
        guard descriptorOwnershipSealed == false, masterFD >= 0 else { return }
        var size = winsize(
            ws_row: UInt16(clamping: dimensions.rows),
            ws_col: UInt16(clamping: dimensions.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard ioctl(masterFD, TIOCSWINSZ, &size) == 0 else { return }
        flightTape.record(
            .resize(columns: dimensions.columns, rows: dimensions.rows, pinned: grid.pinned)
        )
        terminal.resize(columns: dimensions.columns, rows: dimensions.rows)
        markFrameUpdatePendingIfNeeded()
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
        // Activate before cancelling, for the same reason `cancelAllRetainedSources`
        // does: a source cancelled while still suspended never runs its cancellation
        // handler, so it would stay in the retained registry forever. Activating an
        // already-active source does nothing.
        processSource?.activate()
        cancelReadSource()
        cancelWriteSource()
        cancelCanonicalInputHold()
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
        // Activate first: a source cancelled before it was ever activated never runs
        // its cancel handler, so it would never leave the retained registry.
        readSource.activate()
        readSource.cancel()
        forgetSource(.read)
    }

    private func cancelProcessSource() {
        guard let processSource else { return }
        processSource.activate()
        processSource.cancel()
        forgetSource(.process)
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
        retainUntilCancellation(timer, slot: .grace, descriptorBacked: false)
        graceSource = timer
        timer.activate()
    }

    private func cancelGrace() {
        graceSource?.cancel()
        forgetSource(.grace)
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
        retainUntilCancellation(timer, slot: .sessionPoll, descriptorBacked: false)
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
        clearSessionPollTracking()
    }

    private func clearSessionPollTracking() {
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
        cancelAllRetainedSources()
        closeMaster()
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

    /// Takes every pane semantic the owner has accumulated, in one ordered batch.
    ///
    /// The owner's own semantics come first: they were recorded before this drain, and
    /// the terminal's are only now being read out of the accumulator. Order between the
    /// two halves carries no meaning beyond that -- an input occurrence names the wait
    /// it ended, so nothing downstream reasons about which side of it a title landed on.
    private func drainSemanticEvents() -> [PaneSemanticEvent] {
        let ownerEvents = pendingOwnerSemanticEvents
        pendingOwnerSemanticEvents.removeAll(keepingCapacity: false)
        return ownerEvents + terminal.drainSemanticEvents().map(PaneSemanticEvent.terminal)
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
                    semanticEvents: drainSemanticEvents(),
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
        updateSignalFinished = true
        // Last, and on this queue: quiescence is only irreversible once every
        // callback is detached, and the exit path treats completion as exactly that.
        let observers = quiescenceObservers
        quiescenceObservers.removeAll()
        for observer in observers { observer() }
    }
}
