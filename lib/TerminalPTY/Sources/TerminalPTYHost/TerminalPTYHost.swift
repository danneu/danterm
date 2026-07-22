// One serialized owner for PTY lifecycle policy, nonblocking process IO, and
// headless Terminal mutation. Dispatch sources run on the actor's own executor.
import Darwin
import Dispatch
import PaneLifecycle
import TerminalCore

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

/// Test-support view of input and resize effects applied on the shared owner queue.
enum TerminalPTYSubmittedTransition: Equatable, Sendable {
    case input([UInt8])
    case resize(TerminalDimensions)
}

/// Test-support census of resources that must be absent once teardown returns.
struct TerminalPTYResourceSnapshot: Equatable, Sendable {
    let hasOpenMaster: Bool
    let activeSourceCount: Int
    let hasSpawnTask: Bool
    let hasLeader: Bool
    let hasSession: Bool
    let pendingInputByteCount: Int
    let callbacksAfterTeardown: Int
    let emittedUpdateSignalCount: Int
    let updateSignalsAfterTermination: Int

    var isReleased: Bool {
        hasOpenMaster == false
            && activeSourceCount == 0
            && hasSpawnTask == false
            && hasLeader == false
            && hasSession == false
            && pendingInputByteCount == 0
            && callbacksAfterTeardown == 0
            && updateSignalsAfterTermination == 0
    }
}

/// Owns one pane's mutable terminal, lifecycle reducer, PTY, child, and event sources.
public actor TerminalPTYHost {
    // Swift cannot import FIONREAD because its C macro encodes sizeof(int).
    // Rebuild the SDK's _IOR('f', 127, int) value from sys/ioccom.h.
    private static let bytesAvailableRequest = UInt(
        0x4000_0000 | (MemoryLayout<Int32>.size << 16) | (102 << 8) | 127
    )

    private let queue: DispatchSerialQueue
    private var reducer = PaneLifecycleReducer()
    private var terminal: Terminal
    private let initialDimensions: TerminalDimensions
    package nonisolated let captureTransitions: Bool
    private let bootstrapExecutable: String
    private let updateContinuation: AsyncStream<Void>.Continuation

    /// Conflates terminal and lifecycle changes into one pull-driven wakeup channel.
    nonisolated public let updates: AsyncStream<Void>

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
    private var spawnTask: Task<Void, Never>?

    private var pendingInput: [UInt8] = []
    private var pendingInputOffset = 0
    private var pendingEvents: [PaneLifecycleEvent] = []
    private var isReducing = false

    private var recentOutput: [UInt8] = []
    private var interactionState = TerminalInteractionState()
    private var capturedOutput: [UInt8] = []
    private var appliedTransitions: [TerminalPTYAppliedTransition] = []
    private var capturedSubmittedTransitions: [TerminalPTYSubmittedTransition] = []
    private var capturedInputWrites: [[UInt8]] = []
    private var capturedReplyWrites: [[UInt8]] = []
    private var reportedResult: PaneLifecycleResult?
    private var teardownFinished = false
    private var waiterSlots: [Int: WaiterSlot] = [:]
    private var nextWaiterID = 0
    private var transientChildWaitInjections = 0
    private var callbacksAfterTeardown = 0
    private var updatePending = false
    private var shouldFinishUpdates = false
    private var updateSignalFinished = false
    private var emittedUpdateSignalCount = 0
    private var updateSignalsAfterTermination = 0
    private var consumerWorkWasSignaled = false

    /// Binds Swift actor jobs to the FIFO queue that also delivers every system callback.
    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Creates an owner before launch so every later mutation shares one executor.
    public init(
        initialDimensions: TerminalDimensions,
        bootstrapExecutable: String,
        machineHostname: String? = nil,
        programVersion: String = "dev"
    ) throws {
        try self.init(
            initialDimensions: initialDimensions,
            bootstrapExecutable: bootstrapExecutable,
            machineHostname: machineHostname,
            programVersion: programVersion,
            captureTransitions: false
        )
    }

    package init(
        initialDimensions: TerminalDimensions,
        bootstrapExecutable: String,
        machineHostname: String? = nil,
        programVersion: String = "dev",
        captureTransitions: Bool
    ) throws {
        guard let terminal = Terminal(
            columns: initialDimensions.columns,
            rows: initialDimensions.rows,
            machineHostname: machineHostname,
            programVersion: programVersion
        ) else {
            throw TerminalPTYHostError.invalidDimensions
        }
        queue = DispatchSerialQueue(label: "com.danneu.danterm.terminal-pty-host")
        let updateChannel = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        updates = updateChannel.stream
        updateContinuation = updateChannel.continuation
        self.terminal = terminal
        self.initialDimensions = initialDimensions
        self.bootstrapExecutable = bootstrapExecutable
        self.captureTransitions = captureTransitions
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
        queue.async { [weak self] in
            self?.assumeIsolated { owner in owner.start(input) }
        }
    }

    /// Enqueues user bytes directly on the owner queue without an ordering-opaque Task.
    nonisolated public func send(_ bytes: [UInt8]) {
        guard bytes.isEmpty == false else { return }
        queue.async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applyViewportNavigation(.scrollToBottom, publishUpdate: false)
                owner.process(.sendInput(bytes))
            }
        }
    }

    /// Enqueues a normalized key so mode read, encoding, viewport snap, and write stay atomic.
    nonisolated public func sendKey(
        _ key: TerminalInputKey,
        modifiers: TerminalKeyModifiers
    ) {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in owner.applyKey(key, modifiers: modifiers) }
        }
    }

    /// Enqueues unsanitized text for owner-side safe-paste policy and atomic marker generation.
    nonisolated public func sendPaste(_ text: String) {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in owner.applyPaste(text) }
        }
    }

    /// Enqueues semantic pane focus for authoritative mode gating without viewport movement.
    nonisolated public func sendFocus(_ focused: Bool) {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in owner.applyFocus(focused) }
        }
    }

    /// Enqueues geometry on the same FIFO as input so caller order is preserved jointly.
    nonisolated public func resize(_ dimensions: TerminalDimensions) {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in owner.process(.resize(dimensions)) }
        }
    }

    /// Enqueues relative local navigation on the same FIFO as child output and resize.
    nonisolated public func scroll(byRows rowDelta: Int) {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applyViewportNavigation(.scrollByRows(rowDelta), publishUpdate: true)
            }
        }
    }

    /// Enqueues absolute scrollbar navigation in current-stream row coordinates.
    nonisolated public func scroll(toTopRow row: Int) {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applyViewportNavigation(.scrollToTopRow(row), publishUpdate: true)
            }
        }
    }

    /// Enqueues an explicit return to live-bottom follow.
    nonisolated public func scrollToBottom() {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applyViewportNavigation(.scrollToBottom, publishUpdate: true)
            }
        }
    }

    /// Enqueues selection clearing on the same FIFO as pointer mutations and output.
    nonisolated public func clearSelection() {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in owner.applyClearSelection() }
        }
    }

    /// Enqueues normalized fractional wheel input for atomic route and mode selection.
    nonisolated public func sendWheel(_ event: TerminalWheelEvent) {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in owner.applyWheel(event) }
        }
    }

    /// Enqueues pointer input and returns only owner-approved local actions.
    nonisolated public func sendPointer(
        _ event: TerminalPointerEvent,
        onPaneMenu: @escaping @Sendable (TerminalViewportCell) -> Void = { _ in },
        onOpenLink: @escaping @Sendable (TerminalHyperlink) -> Void = { _ in }
    ) {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in
                owner.applyPointer(
                    event,
                    onPaneMenu: onPaneMenu,
                    onOpenLink: onOpenLink
                )
            }
        }
    }

    /// Cancels link arming and hover on the same FIFO as pointer transitions.
    nonisolated public func cancelLinkInteraction() {
        queue.async { [weak self] in
            self?.assumeIsolated { owner in owner.applyLinkCancellation() }
        }
    }

    /// Closes one pane and returns only after its owned process session is gone.
    public func close() async {
        process(.requestClose)
        await waitForTeardown()
    }

    /// Applies the same bounded teardown when the application exits orderly.
    public func terminateForApplicationExit() async {
        process(.appTermination)
        await waitForTeardown()
    }

    /// Returns a Sendable value copy that cannot mutate owner state.
    public func snapshot() -> Terminal {
        terminal
    }

    /// Drains render damage while returning the newest immutable terminal value.
    public func frameState() -> TerminalPTYFrameState {
        drainedFrameState()
    }

    /// Fences earlier owner-queue work for synchronous session recovery reads.
    nonisolated public func fencedSnapshot() -> Terminal {
        queue.sync {
            assumeIsolated { owner in owner.terminal }
        }
    }

    /// Fences earlier owner work and drains exactly the damage accumulated through that fence.
    nonisolated public func fencedFrameState() -> TerminalPTYFrameState {
        queue.sync {
            assumeIsolated { owner in owner.drainedFrameState() }
        }
    }

    /// Captures one owner-ordered diagnostic boundary before failure cleanup can discard evidence.
    package nonisolated func fencedDiagnosticState() -> (
        frameState: TerminalPTYFrameState,
        transitions: [TerminalPTYAppliedTransition]
    ) {
        queue.sync {
            assumeIsolated { owner in
                (owner.drainedFrameState(), owner.appliedTransitions)
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

    /// Starts close and returns its final accepted terminal state in one owner-queue fence.
    nonisolated public func beginCloseAndSnapshot() -> Terminal {
        queue.sync {
            assumeIsolated { owner in
                owner.process(.requestClose)
                return owner.terminal
            }
        }
    }

    /// Returns the reported child result without waiting for future lifecycle work.
    public func result() -> PaneLifecycleResult? {
        reportedResult
    }

    /// Suspends until teardown, returning nil when no child result was produced.
    /// Cancellation resumes the wait with nil without disturbing the pane.
    public func waitForResult() async -> PaneLifecycleResult? {
        if let reportedResult { return reportedResult }
        if teardownFinished { return nil }
        let id = allocateWaiterID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerWaiter(id: id, slot: .result(continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Test synchronization waits on observed bytes rather than elapsed time.
    /// Cancellation resumes the wait with false without disturbing the pane.
    func waitForOutput(containing bytes: [UInt8]) async -> Bool {
        guard bytes.isEmpty == false else { return true }
        if recentOutput.containsSubsequence(bytes) { return true }
        if teardownFinished { return false }
        let id = allocateWaiterID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerWaiter(id: id, slot: .output(
                    OutputWaiter(needle: bytes, continuation: continuation)
                ))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Waiter identity lets cancellation remove exactly its own continuation.
    private func allocateWaiterID() -> Int {
        defer { nextWaiterID += 1 }
        waiterSlots[nextWaiterID] = .pending
        return nextWaiterID
    }

    /// Exactly-once resumption invariant: whichever path removes a waiter's slot
    /// (delivery, teardown, or cancellation) is the one that resumes it; a
    /// missing slot is always a no-op. All paths are actor-serialized.
    private func registerWaiter(id: Int, slot: WaiterSlot) {
        switch waiterSlots[id] {
        case .cancelled:
            waiterSlots[id] = nil
            slot.resumeCancelled()
        case .pending:
            if teardownFinished {
                waiterSlots[id] = nil
                slot.resumeCancelled()
            } else {
                waiterSlots[id] = slot
            }
        default:
            waiterSlots[id] = nil
            slot.resumeCancelled()
        }
    }

    private func cancelWaiter(_ id: Int) {
        switch waiterSlots[id] {
        case .pending:
            waiterSlots[id] = .cancelled
        case .cancelled, nil:
            break
        case .some(let slot):
            waiterSlots[id] = nil
            slot.resumeCancelled()
        }
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
            activeSourceCount: [
                readSource != nil,
                writeSource != nil,
                processSource != nil,
                childExitPollSource != nil,
                graceSource != nil,
                sessionPollSource != nil,
            ].filter { $0 }.count,
            hasSpawnTask: spawnTask != nil,
            hasLeader: leaderPID != nil,
            hasSession: sessionID != nil,
            pendingInputByteCount: max(pendingInput.count - pendingInputOffset, 0),
            callbacksAfterTeardown: callbacksAfterTeardown,
            emittedUpdateSignalCount: emittedUpdateSignalCount,
            updateSignalsAfterTermination: updateSignalsAfterTermination
        )
    }

    private func waitForTeardown() async {
        if teardownFinished { return }
        let id = allocateWaiterID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerWaiter(id: id, slot: .teardown(continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func process(_ event: PaneLifecycleEvent) {
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
            for command in commands {
                execute(command)
            }
        }
    }

    private func applyWheel(_ event: TerminalWheelEvent) {
        guard teardownFinished == false else { return }
        let decision = decideTerminalWheel(event, terminal: terminal, state: &interactionState)
        if decision.inputBytes.isEmpty == false {
            process(.sendInput(decision.inputBytes))
        }
        if decision.localRowDelta != 0 {
            applyViewportNavigation(
                .scrollByRows(decision.localRowDelta),
                publishUpdate: true
            )
        }
    }

    private func applyPointer(
        _ event: TerminalPointerEvent,
        onPaneMenu: @Sendable (TerminalViewportCell) -> Void,
        onOpenLink: @Sendable (TerminalHyperlink) -> Void
    ) {
        guard teardownFinished == false else { return }
        if captureTransitions { appliedTransitions.append(.mouse(event)) }
        let decision = decideTerminalPointer(event, terminal: terminal, state: &interactionState)
        if decision.inputBytes.isEmpty == false {
            process(.sendInput(decision.inputBytes))
        }
        let previousTerminal = terminal
        switch decision.selectionMutation {
        case .clear:
            terminal.clearSelection()
        case .set(let range):
            terminal.setSelection(range)
        case nil:
            break
        }
        applyHoverMutation(decision.hoverMutation)
        applyArmMutation(decision.armMutation)
        if terminal != previousTerminal {
            markUpdatePending()
            publishPendingUpdate()
        }
        if let cell = decision.paneMenuCell {
            onPaneMenu(cell)
        }
        if let link = decision.openLink {
            onOpenLink(link)
        }
    }

    private func applyLinkCancellation() {
        guard teardownFinished == false else { return }
        let previousTerminal = terminal
        let cancellation = cancelTerminalLinkInteraction(state: &interactionState)
        applyHoverMutation(cancellation.hoverMutation)
        applyArmMutation(cancellation.armMutation)
        guard terminal != previousTerminal else { return }
        markUpdatePending()
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
        let previousTerminal = terminal
        terminal.clearSelection()
        guard terminal != previousTerminal else { return }
        markUpdatePending()
        publishPendingUpdate()
    }

    private func applyKey(_ key: TerminalInputKey, modifiers: TerminalKeyModifiers) {
        guard teardownFinished == false else { return }
        if captureTransitions { appliedTransitions.append(.input(key: key, modifiers: modifiers)) }
        let bytes = encodeTerminalKey(key, modifiers: modifiers, modes: terminal.inputModes)
        guard bytes.isEmpty == false else { return }
        applyViewportNavigation(.scrollToBottom, publishUpdate: false)
        process(.sendInput(bytes))
    }

    private func applyPaste(_ text: String) {
        guard teardownFinished == false else { return }
        if captureTransitions { appliedTransitions.append(.paste(text)) }
        let bytes = encodeTerminalPaste(text, modes: terminal.inputModes)
        guard bytes.isEmpty == false else { return }
        applyViewportNavigation(.scrollToBottom, publishUpdate: false)
        process(.sendInput(bytes))
    }

    private func applyFocus(_ focused: Bool) {
        guard teardownFinished == false else { return }
        if captureTransitions { appliedTransitions.append(.focus(focused)) }
        let bytes = encodeTerminalFocus(focused: focused, modes: terminal.inputModes)
        guard bytes.isEmpty == false else { return }
        process(.sendInput(bytes))
    }

    private func applyViewportNavigation(
        _ navigation: TerminalPTYAppliedTransition,
        publishUpdate: Bool
    ) {
        guard teardownFinished == false else { return }
        let previousTerminal = terminal
        switch navigation {
        case .scrollByRows(let rows): terminal.scroll(byRows: rows)
        case .scrollToTopRow(let row): terminal.scroll(toTopRow: row)
        case .scrollToBottom: terminal.scrollToBottom()
        case .feed, .input, .paste, .focus, .mouse, .resize: return
        }
        if terminal != previousTerminal {
            markUpdatePending()
            if captureTransitions { appliedTransitions.append(navigation) }
        }
        if publishUpdate { publishPendingUpdate() }
    }

    private func execute(_ command: PaneLifecycleCommand) {
        switch command {
        case .spawn(let spec):
            spawn(spec)
        case .activateIO:
            activateIO()
        case .writeInput(let bytes):
            if captureTransitions {
                capturedInputWrites.append(bytes)
                capturedSubmittedTransitions.append(.input(bytes))
            }
            enqueueInput(bytes)
        case .resize(let dimensions):
            applyResize(dimensions)
        case .deliverOutput(let bytes):
            applyOutput(bytes)
        case .drainOutput:
            drainCommittedOutput()
        case .closeMaster:
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
        spawnTask?.cancel()
        let bootstrapExecutable = self.bootstrapExecutable
        spawnTask = Task { [weak self] in
            let outcome = await PTYSpawner.spawn(
                spec,
                bootstrapExecutable: bootstrapExecutable
            )
            guard Task.isCancelled == false, let self else {
                if case .success(let spawned) = outcome {
                    await PTYSpawner.discard(spawned)
                }
                return
            }
            await self.receiveSpawn(outcome)
        }
    }

    private func receiveSpawn(_ outcome: PTYSpawnOutcome) {
        spawnTask = nil
        switch outcome {
        case .success(let spawned):
            masterFD = spawned.master
            leaderPID = spawned.leader
            sessionID = spawned.session
            leaderReaped = false
            installSources(for: spawned)
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
        processSource = process
        processSourceActivated = false
    }

    private func activateIO() {
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

    private func enqueueInput(_ bytes: [UInt8]) {
        guard bytes.isEmpty == false, masterFD >= 0 else { return }
        pendingInput.append(contentsOf: bytes)
        flushInput()
    }

    private func flushInput() {
        guard masterFD >= 0 else { return }
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
                pendingInputOffset += result
                writtenThisTurn += result
                continue
            }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
            pendingInput.removeAll(keepingCapacity: false)
            pendingInputOffset = 0
            return
        }
        if pendingInputOffset == pendingInput.count {
            pendingInput.removeAll(keepingCapacity: false)
            pendingInputOffset = 0
            cancelWriteSource()
        } else {
            installWriteSourceIfNeeded()
        }
    }

    private func installWriteSourceIfNeeded() {
        guard writeSource == nil, masterFD >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.writeSourceFired() }
        }
        writeSource = source
        source.activate()
    }

    private func cancelWriteSource() {
        writeSource?.cancel()
        writeSource = nil
    }

    private func readSourceFired() {
        guard recordSystemCallback() else { return }
        readReady()
    }

    private func writeSourceFired() {
        guard recordSystemCallback() else { return }
        flushInput()
    }

    private func processSourceFired() {
        guard recordSystemCallback() else { return }
        childExited()
    }

    private func readReady() {
        guard masterFD >= 0 else { return }
        var bytesReadThisTurn = 0
        let turnLimit = 64 * 1024
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

    /// Test-support fault injection replicating macOS publishing NOTE_EXIT
    /// before the child's wait status is readable: the next `count` exit checks
    /// behave as that transient regardless of the real waitid answer.
    package func injectTransientChildWaits(_ count: Int) {
        transientChildWaitInjections = count
    }

    private func childExited() {
        guard let leaderPID else { return }
        var info = siginfo_t()
        var rc = waitid(P_PID, id_t(leaderPID), &info, WEXITED | WNOHANG | WNOWAIT)
        if transientChildWaitInjections > 0 {
            transientChildWaitInjections -= 1
            rc = 0
            info.si_pid = 0
        }
        guard rc == 0, info.si_pid == leaderPID
        else {
            // macOS can publish NOTE_EXIT before the wait status is readable
            // (waitid succeeds with si_pid == 0). The process source is a
            // one-shot notification for an event that already happened, so
            // dropping this fire would lose the exit forever: poll the dead
            // child until it becomes waitable. Hard waitid errors stay final.
            if rc == 0, info.si_pid == 0 {
                installChildExitPollIfNeeded()
            }
            return
        }
        cancelChildExitPoll()
        let status: ChildExitStatus
        switch info.si_code {
        case CLD_EXITED:
            status = .exited(info.si_status)
        default:
            status = .signaled(info.si_status)
        }
        cancelProcessSource()
        process(.childExited(status))
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

    private func applyOutput(_ bytes: [UInt8]) {
        let previousConsumerWorkGeneration = terminal.pendingConsumerWorkGeneration
        terminal.feed(bytes)
        let replies = terminal.drainReplyBytes()
        if replies.isEmpty == false {
            if captureTransitions {
                capturedReplyWrites.append(replies)
            }
            enqueueInput(replies)
        }
        if terminal.hasPendingConsumerWork,
           consumerWorkWasSignaled == false
            || terminal.pendingConsumerWorkGeneration != previousConsumerWorkGeneration
        {
            markUpdatePending()
        }
        recentOutput.append(contentsOf: bytes)
        if recentOutput.count > 64 * 1024 {
            recentOutput.removeFirst(recentOutput.count - 64 * 1024)
        }
        if captureTransitions {
            capturedOutput.append(contentsOf: bytes)
            appliedTransitions.append(.feed(bytes))
        }
        resumeOutputWaiters()
    }

    private func applyResize(_ dimensions: TerminalDimensions) {
        guard masterFD >= 0 else { return }
        var size = winsize(
            ws_row: UInt16(clamping: dimensions.rows),
            ws_col: UInt16(clamping: dimensions.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard ioctl(masterFD, TIOCSWINSZ, &size) == 0 else { return }
        let previousTerminal = terminal
        terminal.resize(columns: dimensions.columns, rows: dimensions.rows)
        if terminal != previousTerminal { markUpdatePending() }
        if captureTransitions {
            appliedTransitions.append(.resize(dimensions))
            capturedSubmittedTransitions.append(.resize(dimensions))
        }
    }

    private func reapLeader() {
        guard leaderReaped == false, let leaderPID else { return }
        var status: Int32 = 0
        if waitpid(leaderPID, &status, WNOHANG) == leaderPID {
            leaderReaped = true
        }
    }

    private func closeMaster() {
        // A close that raced spawn has sources installed but no activateIO
        // command. Resume before cancellation so libdispatch never releases a
        // suspended source, and keep process observation live for leader reap.
        activateProcessSourceIfNeeded()
        cancelReadSource()
        cancelWriteSource()
        pendingInput.removeAll(keepingCapacity: false)
        pendingInputOffset = 0
        if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }
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

    private func report(_ result: PaneLifecycleResult) {
        guard reportedResult == nil else { return }
        reportedResult = result
        markUpdatePending()
        for id in waiterSlots.keys {
            guard case .result(let continuation) = waiterSlots[id] else { continue }
            waiterSlots[id] = nil
            continuation.resume(returning: result)
        }
    }

    private func finishTeardown() {
        guard teardownFinished == false else { return }
        spawnTask?.cancel()
        spawnTask = nil
        closeMaster()
        cancelGrace()
        cancelSessionPoll()
        cancelProcessSource()
        cancelChildExitPoll()
        leaderPID = nil
        sessionID = nil
        for id in waiterSlots.keys {
            switch waiterSlots[id] {
            case .output(let waiter):
                waiterSlots[id] = nil
                waiter.continuation.resume(returning: false)
            case .result(let continuation):
                waiterSlots[id] = nil
                continuation.resume(returning: nil)
            default:
                break
            }
        }
        teardownFinished = true
        shouldFinishUpdates = true
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

    private func publishPendingUpdate() {
        if updatePending {
            updatePending = false
            updateContinuation.yield()
            emittedUpdateSignalCount += 1
        }
        guard shouldFinishUpdates else { return }
        shouldFinishUpdates = false
        updateContinuation.finish()
        updateSignalFinished = true
        for id in waiterSlots.keys {
            guard case .teardown(let continuation) = waiterSlots[id] else { continue }
            waiterSlots[id] = nil
            continuation.resume()
        }
    }

    private func resumeOutputWaiters() {
        for id in waiterSlots.keys {
            guard case .output(let waiter) = waiterSlots[id],
                  recentOutput.containsSubsequence(waiter.needle)
            else { continue }
            waiterSlots[id] = nil
            waiter.continuation.resume(returning: true)
        }
    }
}

/// One suspended waiter's lifecycle: allocated `.pending`, then either upgraded
/// to a continuation-bearing case or marked `.cancelled` if the owning task was
/// cancelled before registration could store its continuation.
private enum WaiterSlot {
    case pending
    case cancelled
    case result(CheckedContinuation<PaneLifecycleResult?, Never>)
    case output(OutputWaiter)
    case teardown(CheckedContinuation<Void, Never>)

    /// Resumes with the "wait abandoned" value for the slot's wait kind.
    func resumeCancelled() {
        switch self {
        case .pending, .cancelled:
            break
        case .result(let continuation):
            continuation.resume(returning: nil)
        case .output(let waiter):
            waiter.continuation.resume(returning: false)
        case .teardown(let continuation):
            continuation.resume()
        }
    }
}

/// One marker-based test wait kept actor-isolated until matching bytes arrive.
private struct OutputWaiter {
    let needle: [UInt8]
    let continuation: CheckedContinuation<Bool, Never>
}

private extension Array where Element == UInt8 {
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard needle.isEmpty == false, needle.count <= count else { return false }
        return indices.dropLast(needle.count - 1).contains { start in
            self[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}
