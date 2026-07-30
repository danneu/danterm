// Deterministic reducer for one pane's launch, ordered IO, exit drain, and
// bounded teardown policy. It emits commands but performs no system work.

/// Failures returned by the host while attempting a resolved spawn spec.
public enum SpawnFailure: Equatable, Sendable {
    case workingDirectoryUnavailable
    case systemError(Int32)
}

/// Observable child status captured without platform wait-status encoding.
public enum ChildExitStatus: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
}

/// Product-level launch failure after policy or system attempts are exhausted.
public enum LaunchFailureReason: Equatable, Sendable {
    case noUsableShell
    case invalidDimensions
    case workingDirectoryUnavailable
    case systemError(Int32)
}

/// Exactly-once terminal result reported only after lifecycle ownership converges.
public enum PaneLifecycleResult: Equatable, Sendable {
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
public enum PaneLifecyclePhase: Equatable, Sendable {
    case idle
    case spawning
    case running
    case drainingOutput
    case tearingDown(TeardownStage)
    case finished
}

/// Explicit inputs serialized by the future pane owner before reduction.
public enum PaneLifecycleEvent: Equatable, Sendable {
    case start(LaunchPolicyInput)
    case spawnSucceeded
    case spawnFailed(SpawnFailure)
    case sendInput([UInt8])
    case resize(TerminalDimensions)
    case output([UInt8])
    case outputEOF
    case childExited(ChildExitStatus)
    case requestClose
    case graceElapsed(TeardownStage)
    case sessionDrained
}

/// Ordered effects interpreted by the PTY host on the same serialized owner.
public enum PaneLifecycleCommand: Equatable, Sendable {
    case spawn(PTYLaunchSpec)
    case activateIO
    case writeInput([UInt8])
    case resize(TerminalDimensions)
    case deliverOutput([UInt8])
    case drainOutput
    case closeMaster
    case reapLeader
    case signalSession(TeardownStage)
    case scheduleGrace(TeardownStage)
    case cancelGrace
    case report(PaneLifecycleResult)
    case finishTeardown
}

/// Owns the pure lifecycle state machine so identical event order yields identical commands.
public struct PaneLifecycleReducer: Sendable {
    private var storage: Storage = .idle

    /// Coarse lifecycle state used by the host to gate ownership-sensitive work.
    public var phase: PaneLifecyclePhase {
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
    public mutating func handle(_ event: PaneLifecycleEvent) -> [PaneLifecycleCommand] {
        switch storage {
        case .idle:
            return handleIdle(event)
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
            return []
        }
    }

    private mutating func handleIdle(_ event: PaneLifecycleEvent) -> [PaneLifecycleCommand] {
        switch event {
        case .start(let input):
            switch resolveLaunchPlan(input) {
            case .success(let plan):
                let context = SpawnContext(plan: plan, attemptIndex: 0, pendingDimensions: nil)
                storage = .spawning(context)
                return [.spawn(plan.attempts[0])]
            case .failure(let error):
                storage = .finished
                return [.report(.launchFailed(launchFailure(for: error))), .finishTeardown]
            }
        case .requestClose:
            storage = .finished
            return [.finishTeardown]
        default:
            return []
        }
    }

    private mutating func handleSpawning(
        _ event: PaneLifecycleEvent,
        context: SpawnContext
    ) -> [PaneLifecycleCommand] {
        switch event {
        case .spawnSucceeded:
            storage = .running(outputEOF: false)
            var commands: [PaneLifecycleCommand] = [.activateIO]
            if let dimensions = context.pendingDimensions {
                commands.append(.resize(dimensions))
            }
            if let initialInput = context.plan.initialInput {
                commands.append(.writeInput(initialInput))
            }
            return commands
        case .spawnFailed(.workingDirectoryUnavailable):
            let nextIndex = context.attemptIndex + 1
            guard nextIndex < context.plan.attempts.count else {
                storage = .finished
                return [
                    .report(.launchFailed(.workingDirectoryUnavailable)),
                    .finishTeardown,
                ]
            }
            storage = .spawning(SpawnContext(
                plan: context.plan,
                attemptIndex: nextIndex,
                pendingDimensions: context.pendingDimensions
            ))
            return [.spawn(context.plan.attempts[nextIndex])]
        case .spawnFailed(.systemError(let code)):
            storage = .finished
            return [.report(.launchFailed(.systemError(code))), .finishTeardown]
        case .resize(let dimensions) where dimensions.isValid:
            storage = .spawning(SpawnContext(
                plan: context.plan,
                attemptIndex: context.attemptIndex,
                pendingDimensions: dimensions
            ))
            return []
        case .requestClose:
            storage = .closingWhileSpawning
            return []
        default:
            return []
        }
    }

    private mutating func handleClosingWhileSpawning(
        _ event: PaneLifecycleEvent
    ) -> [PaneLifecycleCommand] {
        switch event {
        case .spawnSucceeded:
            return beginTeardown(result: nil, leaderStatus: nil, reapLeader: false)
        case .spawnFailed:
            storage = .finished
            return [.finishTeardown]
        default:
            return []
        }
    }

    private mutating func handleRunning(
        _ event: PaneLifecycleEvent,
        outputEOF: Bool
    ) -> [PaneLifecycleCommand] {
        switch event {
        case .sendInput(let bytes):
            return [.writeInput(bytes)]
        case .resize(let dimensions) where dimensions.isValid:
            return [.resize(dimensions)]
        case .output(let bytes) where !outputEOF:
            return [.deliverOutput(bytes)]
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
        _ event: PaneLifecycleEvent,
        status: ChildExitStatus
    ) -> [PaneLifecycleCommand] {
        switch event {
        case .output(let bytes):
            return [.deliverOutput(bytes)]
        case .outputEOF:
            return beginTeardown(result: .exited(status), leaderStatus: status, reapLeader: true)
        case .requestClose:
            return beginTeardown(result: .exited(status), leaderStatus: status, reapLeader: true)
        default:
            return []
        }
    }

    private mutating func handleTeardown(
        _ event: PaneLifecycleEvent,
        context: TeardownContext
    ) -> [PaneLifecycleCommand] {
        var next = context
        switch event {
        case .childExited(let status) where next.leaderStatus == nil:
            next.leaderStatus = status
            storage = .tearingDown(next)
            if next.sessionDrained {
                return [.reapLeader] + finishTeardown(next)
            }
            return [.reapLeader]
        case .sessionDrained where !next.sessionDrained:
            next.sessionDrained = true
            storage = .tearingDown(next)
            if next.leaderStatus != nil {
                return finishTeardown(next)
            }
            return []
        case .graceElapsed(let stage) where stage == next.stage:
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
        default:
            return []
        }
    }

    private mutating func beginTeardown(
        result: PaneLifecycleResult?,
        leaderStatus: ChildExitStatus?,
        reapLeader: Bool
    ) -> [PaneLifecycleCommand] {
        storage = .tearingDown(TeardownContext(
            stage: .hangup,
            result: result,
            leaderStatus: leaderStatus,
            sessionDrained: false
        ))
        var commands: [PaneLifecycleCommand] = []
        if reapLeader { commands.append(.reapLeader) }
        commands += [.closeMaster, .signalSession(.hangup), .scheduleGrace(.hangup)]
        return commands
    }

    private mutating func finishTeardown(
        _ context: TeardownContext
    ) -> [PaneLifecycleCommand] {
        storage = .finished
        var commands: [PaneLifecycleCommand] = [.cancelGrace]
        if let result = context.result { commands.append(.report(result)) }
        commands.append(.finishTeardown)
        return commands
    }
}

/// Reducer-only launch retry bookkeeping, never exposed to the system host.
private struct SpawnContext: Sendable {
    let plan: ResolvedLaunchPlan
    let attemptIndex: Int
    let pendingDimensions: TerminalDimensions?
}

/// Reducer-only convergence facts needed to report a result after ownership ends.
private struct TeardownContext: Sendable {
    var stage: TeardownStage
    let result: PaneLifecycleResult?
    var leaderStatus: ChildExitStatus?
    var sessionDrained: Bool
}

/// Internal states keep race bookkeeping private while `phase` exposes stable policy state.
private enum Storage: Sendable {
    case idle
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
    case .noUsableShell: .noUsableShell
    case .invalidDimensions: .invalidDimensions
    }
}
