// Deterministic reducer for one pane's launch, ordered IO, exit drain, and
// bounded teardown policy. It emits commands but performs no system work.

/// Failures returned by the host while attempting a resolved spawn spec.
///
/// The first two name the ladder to advance: the child bootstrap reported that
/// `chdir` or `execve` refused this candidate, and nothing of the child has run.
/// Everything else is terminal on its first occurrence.
public enum SpawnFailure: Equatable, Sendable {
    case workingDirectoryUnavailable
    /// The chosen shell could not be executed, carrying the `execve` errno.
    case executableUnavailable(Int32)
    case systemError(Int32)
}

/// Observable child status captured without platform wait-status encoding.
public enum ChildExitStatus: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
}

/// Product-level launch failure after policy or system attempts are exhausted.
public enum LaunchFailureReason: Equatable, Sendable {
    /// Every shell candidate was refused by `execve`, carrying the last attempt's errno.
    case noUsableShell(Int32)
    case invalidDimensions
    /// Initial shell input cannot fit within the pane's bounded pending-input path.
    case initialInputTooLarge
    case workingDirectoryUnavailable
    case systemError(Int32)
}

/// Stable identity for one input submission until every byte is delivered or rejected.
public struct PaneInputSubmissionId: Hashable, Sendable {
    /// Monotonic owner-local value used only while the submission is incomplete.
    public let rawValue: UInt64

    /// Creates an identity allocated by the serialized PTY owner.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Why a complete input submission could not cross the PTY master descriptor.
public enum PaneInputSubmissionFailure: Equatable, Sendable {
    /// The whole submission did not fit within the pane's shared pending-input bound.
    case bufferLimitExceeded
    /// The tty stayed canonical until the bounded delivery wait expired.
    case canonicalModeTimeout
    /// The process could not start, so no buffered bytes had a destination.
    case launchFailed(LaunchFailureReason)
    /// The process ended or its pane closed before all bytes crossed the descriptor.
    case processEnded
    /// A descriptor write failed with the captured POSIX error number.
    case writeFailed(Int32)
}

/// Exactly one terminal result for one input submission.
public enum PaneInputSubmissionResult: Equatable, Sendable {
    /// Every byte in the submission crossed the PTY master descriptor.
    case delivered
    /// At least one byte in the submission did not cross the PTY master descriptor.
    case rejected(PaneInputSubmissionFailure)
}

/// Exactly-once terminal result reported only after lifecycle ownership converges.
public enum PaneProcessLifecycleResult: Equatable, Sendable {
    case exited(ChildExitStatus)
    case launchFailed(LaunchFailureReason)
}

/// Monotone session-wide signal stages in the bounded teardown ladder.
public enum TeardownStage: Int, Equatable, Sendable {
    case hangup = 1
    case terminate = 2
    case kill = 3
}

/// Coarse state exposed for host assertions without exposing reducer bookkeeping.
public enum PaneProcessLifecyclePhase: Equatable, Sendable {
    case idle
    case spawning
    case running
    case drainingOutput
    case tearingDown(TeardownStage)
    case finished
}

/// Explicit inputs serialized by the future pane owner before reduction.
public enum PaneProcessLifecycleEvent: Equatable, Sendable {
    /// Gives launch input the same exactly-once result identity as later pane input.
    case trackInitialInput(PaneInputSubmissionId)
    case start(LaunchPolicyInput)
    case spawnSucceeded
    case spawnFailed(SpawnFailure)
    /// `origin` is when the event that produced these bytes occurred, on the owner's monotonic
    /// clock, and travels with them so the eventual write can be attributed to it. Nil for
    /// bytes the pane owner produced itself, such as a terminal reply.
    case sendInput([UInt8], origin: UInt64?, submissionId: PaneInputSubmissionId)
    case resize(PaneGridSubmission)
    case outputEOF
    case childExited(ChildExitStatus)
    case requestClose
    case masterClosed
    case graceElapsed(TeardownStage)
    case sessionDrained
}

/// Ordered effects interpreted by the PTY host on the same serialized owner.
public enum PaneProcessLifecycleCommand: Equatable, Sendable {
    case spawn(PTYLaunchSpec)
    case activateIO
    /// Carries the submission metadata unchanged while backpressure holds bytes short of the PTY.
    case writeInput([UInt8], origin: UInt64?, submissionId: PaneInputSubmissionId?)
    /// Resolves a submission rejected by lifecycle policy before it reaches descriptor IO.
    case completeInput(PaneInputSubmissionId, PaneInputSubmissionResult)
    case resize(PaneGridSubmission)
    case drainOutput
    /// Starts the host-owned deadline for a lifecycle that now requires bounded teardown.
    case armExitBound
    case closeMaster
    case reapLeader
    case signalSession(TeardownStage)
    case scheduleGrace(TeardownStage)
    case cancelGrace
    case report(PaneProcessLifecycleResult)
    case finishTeardown
}

/// Owns the pure lifecycle state machine so identical event order yields identical commands.
public struct PaneProcessLifecycleReducer: Sendable {
    /// One bound shared by input waiting before spawn and input waiting on descriptor writes.
    public static let pendingInputByteLimit = 8 * 1024 * 1024

    private var storage: Storage = .idle(.init(
        initialInputSubmissionId: nil,
        pendingInput: [],
        pendingInputByteCount: 0
    ))

    /// Coarse lifecycle state used by the host to gate ownership-sensitive work.
    public var phase: PaneProcessLifecyclePhase {
        switch storage {
        case .idle: .idle
        case .spawning, .closingWhileSpawning: .spawning
        case .running: .running
        case .drainingOutput: .drainingOutput
        case .tearingDown(let context): .tearingDown(context.stage)
        case .finished: .finished
        }
    }

    /// Creates an idle reducer with no child or system resources.
    public init() {}

    /// Applies one serialized event and returns effects in their required execution order.
    public mutating func handle(_ event: PaneProcessLifecycleEvent) -> [PaneProcessLifecycleCommand] {
        switch storage {
        case .idle(let context):
            return handleIdle(event, context: context)
        case .spawning(let context):
            return handleSpawning(event, context: context)
        case .closingWhileSpawning:
            return handleClosingWhileSpawning(event)
        case .running(let outputEOF):
            return handleRunning(event, outputEOF: outputEOF)
        case .drainingOutput(let status):
            return handleDraining(event, status: status)
        case .tearingDown(let context):
            return handleTeardown(event, context: context)
        case .finished:
            if case .sendInput(_, _, let submissionId) = event {
                return [.completeInput(submissionId, .rejected(.processEnded))]
            }
            return []
        }
    }

    private mutating func handleIdle(
        _ event: PaneProcessLifecycleEvent,
        context: PreStartContext
    ) -> [PaneProcessLifecycleCommand] {
        switch event {
        case .trackInitialInput(let submissionId):
            guard context.initialInputSubmissionId == nil else { return [] }
            var next = context
            next.initialInputSubmissionId = submissionId
            storage = .idle(next)
            return []
        case .start(let input):
            switch resolveLaunchPlan(input) {
            case .success(let plan):
                var pendingInput = plan.initialInput.map {
                    [PendingInputSubmission(
                        id: context.initialInputSubmissionId,
                        bytes: $0,
                        origin: nil
                    )]
                } ?? []
                var pendingInputByteCount = plan.initialInput?.count ?? 0
                var commands: [PaneProcessLifecycleCommand] = []
                for submission in context.pendingInput {
                    if submission.bytes.count <= Self.pendingInputByteLimit - pendingInputByteCount {
                        pendingInput.append(submission)
                        pendingInputByteCount += submission.bytes.count
                    } else {
                        guard let submissionId = submission.id else {
                            preconditionFailure("only caller input can exceed the launch remainder")
                        }
                        commands.append(.completeInput(
                            submissionId,
                            .rejected(.bufferLimitExceeded)
                        ))
                    }
                }
                let spawnContext = SpawnContext(
                    plan: plan,
                    shellIndex: 0,
                    workingDirectoryIndex: 0,
                    pendingGrid: nil,
                    pendingInput: pendingInput,
                    pendingInputByteCount: pendingInputByteCount
                )
                storage = .spawning(spawnContext)
                commands.append(.spawn(spawnContext.spec))
                return commands
            case .failure(let error):
                storage = .finished
                let failure = launchFailure(for: error)
                let trackedLaunch = context.initialInputSubmissionId.map {
                    [PaneProcessLifecycleCommand.completeInput(
                        $0,
                        .rejected(.launchFailed(failure))
                    )]
                } ?? []
                return trackedLaunch + context.pendingInput.compactMap {
                    $0.id.map { .completeInput($0, .rejected(.launchFailed(failure))) }
                } + [.report(.launchFailed(failure)), .finishTeardown]
            }
        case .requestClose:
            storage = .finished
            return context.pendingInput.compactMap {
                $0.id.map { .completeInput($0, .rejected(.processEnded)) }
            } + [.finishTeardown]
        case .sendInput(let bytes, let origin, let submissionId):
            guard bytes.isEmpty == false else {
                return [.completeInput(submissionId, .delivered)]
            }
            guard bytes.count <= Self.pendingInputByteLimit - context.pendingInputByteCount else {
                return [.completeInput(submissionId, .rejected(.bufferLimitExceeded))]
            }
            var next = context
            next.pendingInput.append(.init(id: submissionId, bytes: bytes, origin: origin))
            next.pendingInputByteCount += bytes.count
            storage = .idle(next)
            return []
        default:
            return []
        }
    }

    private mutating func handleSpawning(
        _ event: PaneProcessLifecycleEvent,
        context: SpawnContext
    ) -> [PaneProcessLifecycleCommand] {
        switch event {
        case .spawnSucceeded:
            storage = .running(outputEOF: false)
            var commands: [PaneProcessLifecycleCommand] = [.activateIO]
            if let grid = context.pendingGrid {
                commands.append(.resize(grid))
            }
            commands += context.pendingInput.map {
                .writeInput($0.bytes, origin: $0.origin, submissionId: $0.id)
            }
            return commands
        case .spawnFailed(.workingDirectoryUnavailable):
            var next = context
            next.workingDirectoryIndex += 1
            guard next.workingDirectoryIndex < context.plan.workingDirectories.count else {
                return exhaustLadder(context, reporting: .workingDirectoryUnavailable)
            }
            storage = .spawning(next)
            return [.spawn(next.spec)]
        case .spawnFailed(.executableUnavailable(let code)):
            var next = context
            next.shellIndex += 1
            guard next.shellIndex < context.plan.shells.count else {
                return exhaustLadder(context, reporting: .noUsableShell(code))
            }
            storage = .spawning(next)
            return [.spawn(next.spec)]
        case .spawnFailed(.systemError(let code)):
            storage = .finished
            let failure = LaunchFailureReason.systemError(code)
            return rejectPendingInput(context, because: .launchFailed(failure))
                + [.report(.launchFailed(failure)), .finishTeardown]
        case .resize(let grid) where grid.isValid:
            var next = context
            next.pendingGrid = grid
            storage = .spawning(next)
            return []
        case .sendInput(let bytes, let origin, let submissionId):
            guard bytes.isEmpty == false else {
                return [.completeInput(submissionId, .delivered)]
            }
            guard bytes.count <= Self.pendingInputByteLimit - context.pendingInputByteCount else {
                return [.completeInput(submissionId, .rejected(.bufferLimitExceeded))]
            }
            var next = context
            next.pendingInput.append(.init(id: submissionId, bytes: bytes, origin: origin))
            next.pendingInputByteCount += bytes.count
            storage = .spawning(next)
            return []
        case .requestClose:
            storage = .closingWhileSpawning
            return [.armExitBound] + rejectPendingInput(context, because: .processEnded)
        default:
            return []
        }
    }

    private mutating func handleClosingWhileSpawning(
        _ event: PaneProcessLifecycleEvent
    ) -> [PaneProcessLifecycleCommand] {
        switch event {
        case .spawnSucceeded:
            return beginTeardown(
                result: nil,
                leaderStatus: nil,
                reapLeader: false,
                armExitBound: false
            )
        case .spawnFailed:
            storage = .finished
            return [.finishTeardown]
        case .sendInput(_, _, let submissionId):
            return [.completeInput(submissionId, .rejected(.processEnded))]
        default:
            return []
        }
    }

    private mutating func handleRunning(
        _ event: PaneProcessLifecycleEvent,
        outputEOF: Bool
    ) -> [PaneProcessLifecycleCommand] {
        switch event {
        case .sendInput(let bytes, let origin, let submissionId):
            guard bytes.isEmpty == false else {
                return [.completeInput(submissionId, .delivered)]
            }
            return [.writeInput(bytes, origin: origin, submissionId: submissionId)]
        case .resize(let grid) where grid.isValid:
            return [.resize(grid)]
        case .outputEOF:
            storage = .running(outputEOF: true)
            return []
        case .childExited(let status):
            if outputEOF {
                return beginTeardown(result: .exited(status), leaderStatus: status, reapLeader: true)
            }
            storage = .drainingOutput(status)
            return [.drainOutput]
        case .requestClose:
            return beginTeardown(result: nil, leaderStatus: nil, reapLeader: false)
        default:
            return []
        }
    }

    private mutating func handleDraining(
        _ event: PaneProcessLifecycleEvent,
        status: ChildExitStatus
    ) -> [PaneProcessLifecycleCommand] {
        switch event {
        case .outputEOF:
            return beginTeardown(result: .exited(status), leaderStatus: status, reapLeader: true)
        case .requestClose:
            return beginTeardown(result: .exited(status), leaderStatus: status, reapLeader: true)
        case .sendInput(_, _, let submissionId):
            return [.completeInput(submissionId, .rejected(.processEnded))]
        default:
            return []
        }
    }

    private mutating func handleTeardown(
        _ event: PaneProcessLifecycleEvent,
        context: TeardownContext
    ) -> [PaneProcessLifecycleCommand] {
        var next = context
        switch event {
        case .childExited(let status) where next.leaderStatus == nil:
            next.leaderStatus = status
            storage = .tearingDown(next)
            if next.sessionDrained {
                return [.reapLeader] + finishTeardown(next)
            }
            return [.reapLeader]
        case .masterClosed where next.masterClosed == false:
            next.masterClosed = true
            storage = .tearingDown(next)
            return [.signalSession(.hangup), .scheduleGrace(.hangup)]
        case .sessionDrained where next.masterClosed && !next.sessionDrained:
            next.sessionDrained = true
            if next.leaderStatus != nil {
                return finishTeardown(next)
            }
            return [.reapLeader] + finishTeardown(next)
        case .graceElapsed(let stage) where next.masterClosed && stage == next.stage:
            switch stage {
            case .hangup:
                next.stage = .terminate
                storage = .tearingDown(next)
                return [.signalSession(.terminate), .scheduleGrace(.terminate)]
            case .terminate:
                next.stage = .kill
                storage = .tearingDown(next)
                return [.signalSession(.kill)]
            case .kill:
                return []
            }
        case .sendInput(_, _, let submissionId):
            return [.completeInput(submissionId, .rejected(.processEnded))]
        default:
            return []
        }
    }

    /// Ends a launch whose retryable ladder ran out of candidates.
    private mutating func exhaustLadder(
        _ context: SpawnContext,
        reporting failure: LaunchFailureReason
    ) -> [PaneProcessLifecycleCommand] {
        storage = .finished
        return rejectPendingInput(context, because: .launchFailed(failure))
            + [.report(.launchFailed(failure)), .finishTeardown]
    }

    private func rejectPendingInput(
        _ context: SpawnContext,
        because failure: PaneInputSubmissionFailure
    ) -> [PaneProcessLifecycleCommand] {
        context.pendingInput.compactMap {
            $0.id.map { .completeInput($0, .rejected(failure)) }
        }
    }

    private mutating func beginTeardown(
        result: PaneProcessLifecycleResult?,
        leaderStatus: ChildExitStatus?,
        reapLeader: Bool,
        armExitBound: Bool = true
    ) -> [PaneProcessLifecycleCommand] {
        storage = .tearingDown(TeardownContext(
            stage: .hangup,
            result: result,
            leaderStatus: leaderStatus,
            sessionDrained: false,
            masterClosed: false
        ))
        var commands: [PaneProcessLifecycleCommand] = armExitBound ? [.armExitBound] : []
        if reapLeader { commands.append(.reapLeader) }
        commands.append(.closeMaster)
        return commands
    }

    private mutating func finishTeardown(
        _ context: TeardownContext
    ) -> [PaneProcessLifecycleCommand] {
        storage = .finished
        var commands: [PaneProcessLifecycleCommand] = [.cancelGrace]
        if let result = context.result { commands.append(.report(result)) }
        commands.append(.finishTeardown)
        return commands
    }
}

/// Reducer-only launch retry bookkeeping, never exposed to the system host.
///
/// One index per ladder, advanced only by the failure stage that names it, so a
/// cwd that already passed `chdir` survives a shell retry and the reverse.
private struct SpawnContext: Sendable {
    let plan: ResolvedLaunchPlan
    var shellIndex: Int
    var workingDirectoryIndex: Int
    var pendingGrid: PaneGridSubmission?
    var pendingInput: [PendingInputSubmission]
    var pendingInputByteCount: Int

    var spec: PTYLaunchSpec {
        plan.spec(shell: shellIndex, workingDirectory: workingDirectoryIndex)
    }
}

/// Input can reach the serialized owner before its already-enqueued start event is reduced.
private struct PreStartContext: Sendable {
    var initialInputSubmissionId: PaneInputSubmissionId?
    var pendingInput: [PendingInputSubmission]
    var pendingInputByteCount: Int
}

/// One whole user submission retained until a successful spawn can preserve its boundary.
private struct PendingInputSubmission: Sendable {
    let id: PaneInputSubmissionId?
    let bytes: [UInt8]
    let origin: UInt64?
}

/// Reducer-only convergence facts needed to report a result after ownership ends.
private struct TeardownContext: Sendable {
    var stage: TeardownStage
    let result: PaneProcessLifecycleResult?
    var leaderStatus: ChildExitStatus?
    var sessionDrained: Bool
    var masterClosed: Bool
}

/// Internal states keep race bookkeeping private while `phase` exposes stable policy state.
private enum Storage: Sendable {
    case idle(PreStartContext)
    case spawning(SpawnContext)
    case closingWhileSpawning
    case running(outputEOF: Bool)
    case drainingOutput(ChildExitStatus)
    case tearingDown(TeardownContext)
    case finished
}

/// Maps pre-spawn policy errors into the reducer's single product-level failure vocabulary.
private func launchFailure(for error: LaunchPolicyError) -> LaunchFailureReason {
    switch error {
    case .invalidDimensions: .invalidDimensions
    case .initialInputTooLarge: .initialInputTooLarge
    }
}
