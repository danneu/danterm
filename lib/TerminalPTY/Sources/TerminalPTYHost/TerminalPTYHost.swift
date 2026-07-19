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

/// Test-support view of the exact output/resize order applied to TerminalCore.
enum TerminalPTYAppliedTransition: Equatable, Sendable {
    case feed([UInt8])
    case resize(TerminalDimensions)
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
    private let captureTransitions: Bool
    private let bootstrapExecutable: String

    private var masterFD: Int32 = -1
    private var leaderPID: pid_t?
    private var sessionID: pid_t?
    private var leaderReaped = false
    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?
    private var processSource: (any DispatchSourceProcess)?
    private var graceSource: (any DispatchSourceTimer)?
    private var spawnTask: Task<Void, Never>?

    private var pendingInput: [UInt8] = []
    private var pendingInputOffset = 0
    private var pendingEvents: [PaneLifecycleEvent] = []
    private var isReducing = false

    private var recentOutput: [UInt8] = []
    private var capturedOutput: [UInt8] = []
    private var appliedTransitions: [TerminalPTYAppliedTransition] = []
    private var outputWaiters: [OutputWaiter] = []
    private var reportedResult: PaneLifecycleResult?
    private var resultWaiters: [CheckedContinuation<PaneLifecycleResult, Never>] = []

    /// Binds Swift actor jobs to the FIFO queue that also delivers every system callback.
    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Creates an owner before launch so every later mutation shares one executor.
    public init(
        initialDimensions: TerminalDimensions,
        bootstrapExecutable: String
    ) throws {
        try self.init(
            initialDimensions: initialDimensions,
            bootstrapExecutable: bootstrapExecutable,
            captureTransitions: false
        )
    }

    init(
        initialDimensions: TerminalDimensions,
        bootstrapExecutable: String,
        captureTransitions: Bool
    ) throws {
        guard let terminal = Terminal(
            columns: initialDimensions.columns,
            rows: initialDimensions.rows
        ) else {
            throw TerminalPTYHostError.invalidDimensions
        }
        queue = DispatchSerialQueue(label: "com.danneu.danterm.terminal-pty-host")
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

    /// Serializes user bytes behind every previously observed owner event.
    public func send(_ bytes: [UInt8]) {
        process(.sendInput(bytes))
    }

    /// Applies child and TerminalCore geometry as one owner-ordered transition.
    public func resize(_ dimensions: TerminalDimensions) {
        process(.resize(dimensions))
    }

    /// Returns a Sendable value copy that cannot mutate owner state.
    public func snapshot() -> Terminal {
        terminal
    }

    /// Suspends until reducer cleanup reports the child's product-level result.
    public func waitForResult() async -> PaneLifecycleResult {
        if let reportedResult { return reportedResult }
        return await withCheckedContinuation { continuation in
            resultWaiters.append(continuation)
        }
    }

    /// Test synchronization waits on observed bytes rather than elapsed time.
    func waitForOutput(containing bytes: [UInt8]) async -> Bool {
        guard bytes.isEmpty == false else { return true }
        if recentOutput.containsSubsequence(bytes) { return true }
        return await withCheckedContinuation { continuation in
            outputWaiters.append(OutputWaiter(needle: bytes, continuation: continuation))
        }
    }

    /// Returns raw bytes only when explicit test-support capture was enabled.
    func outputBytes() -> [UInt8] {
        capturedOutput
    }

    /// Returns the exact TerminalCore mutation order for neutral recording tests.
    func transitions() -> [TerminalPTYAppliedTransition] {
        appliedTransitions
    }

    private func process(_ event: PaneLifecycleEvent) {
        pendingEvents.append(event)
        guard isReducing == false else { return }
        isReducing = true
        defer { isReducing = false }

        while pendingEvents.isEmpty == false {
            let next = pendingEvents.removeFirst()
            let commands = reducer.handle(next)
            for command in commands {
                execute(command)
            }
        }
    }

    private func execute(_ command: PaneLifecycleCommand) {
        switch command {
        case .spawn(let spec):
            spawn(spec)
        case .activateIO:
            activateIO()
        case .writeInput(let bytes):
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
            self?.assumeIsolated { owner in owner.readReady() }
        }
        readSource = read

        let process = DispatchSource.makeProcessSource(
            identifier: spawned.leader,
            eventMask: .exit,
            queue: queue
        )
        process.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.childExited() }
        }
        processSource = process
    }

    private func activateIO() {
        readSource?.activate()
        processSource?.activate()
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
            self?.assumeIsolated { owner in owner.flushInput() }
        }
        writeSource = source
        source.activate()
    }

    private func cancelWriteSource() {
        writeSource?.cancel()
        writeSource = nil
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
                readSource?.cancel()
                readSource = nil
                process(.outputEOF)
                return
            }
            if result < 0, errno == EINTR { continue }
            return
        }
    }

    private func childExited() {
        guard let leaderPID else { return }
        var info = siginfo_t()
        guard waitid(P_PID, id_t(leaderPID), &info, WEXITED | WNOHANG | WNOWAIT) == 0,
              info.si_pid == leaderPID
        else {
            return
        }
        let status: ChildExitStatus
        switch info.si_code {
        case CLD_EXITED:
            status = .exited(info.si_status)
        default:
            status = .signaled(info.si_status)
        }
        processSource?.cancel()
        processSource = nil
        process(.childExited(status))
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
        terminal.feed(bytes)
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
        terminal.resize(columns: dimensions.columns, rows: dimensions.rows)
        if captureTransitions { appliedTransitions.append(.resize(dimensions)) }
    }

    private func reapLeader() {
        guard leaderReaped == false, let leaderPID else { return }
        var status: Int32 = 0
        if waitpid(leaderPID, &status, WNOHANG) == leaderPID {
            leaderReaped = true
        }
    }

    private func closeMaster() {
        readSource?.cancel()
        readSource = nil
        cancelWriteSource()
        pendingInput.removeAll(keepingCapacity: false)
        pendingInputOffset = 0
        if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }
    }

    private func signalSession(_ stage: TeardownStage) {
        guard let sessionID else {
            pendingEvents.append(.sessionDrained)
            return
        }
        let members = sessionMembers(sessionID: sessionID)
        guard members.isEmpty == false else {
            pendingEvents.append(.sessionDrained)
            return
        }
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
    }

    private func sessionMembers(sessionID: pid_t) -> [pid_t] {
        let estimatedCount = max(Int(proc_listallpids(nil, 0)), 256)
        var pids = [pid_t](repeating: 0, count: estimatedCount + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { pid in
            pid > 0 && getsid(pid) == sessionID
        }
    }

    private func scheduleGrace(_ stage: TeardownStage) {
        cancelGrace()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(stage == .hangup ? 100 : 200))
        timer.setEventHandler { [weak self] in
            self?.assumeIsolated { owner in owner.process(.graceElapsed(stage)) }
        }
        graceSource = timer
        timer.activate()
    }

    private func cancelGrace() {
        graceSource?.cancel()
        graceSource = nil
    }

    private func report(_ result: PaneLifecycleResult) {
        guard reportedResult == nil else { return }
        reportedResult = result
        let waiters = resultWaiters
        resultWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
    }

    private func finishTeardown() {
        spawnTask?.cancel()
        spawnTask = nil
        closeMaster()
        cancelGrace()
        processSource?.cancel()
        processSource = nil
        leaderPID = nil
        sessionID = nil
        let waiters = outputWaiters
        outputWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(returning: false) }
    }

    private func resumeOutputWaiters() {
        var remaining: [OutputWaiter] = []
        for waiter in outputWaiters {
            if recentOutput.containsSubsequence(waiter.needle) {
                waiter.continuation.resume(returning: true)
            } else {
                remaining.append(waiter)
            }
        }
        outputWaiters = remaining
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
