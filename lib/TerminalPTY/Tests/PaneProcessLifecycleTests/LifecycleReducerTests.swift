// Golden lifecycle traces proving exact ordered commands at the pure PTY boundary.
import Testing
@testable import PaneProcessLifecycle

@Suite struct LifecycleReducerTests {
    @Test("launch becomes ready and preserves ordered input, resize, and output")
    func launchReadinessAndIO() throws {
        var reducer = PaneProcessLifecycleReducer()
        var input = lifecycleInput()
        input.launchCommand = "printf ready"
        let firstSpec = try resolveLaunchPlan(input).get().spec(shell: 0, workingDirectory: 0)

        #expect(reducer.handle(.start(input)) == [.spawn(firstSpec)])
        #expect(reducer.handle(.spawnSucceeded) == [
            .activateIO,
            .writeInput(Array("printf ready\n".utf8), origin: nil, submissionId: nil),
        ])
        #expect(reducer.handle(.spawnSucceeded).isEmpty)
        #expect(
            reducer.handle(.sendInput(
                [0x61, 0x62],
                origin: 7,
                submissionId: PaneInputSubmissionId(rawValue: 1)
            )) == [.writeInput(
                [0x61, 0x62],
                origin: 7,
                submissionId: PaneInputSubmissionId(rawValue: 1)
            )]
        )
        #expect(reducer.handle(.resize(PaneGridSubmission(dimensions: .init(columns: 120, rows: 50), pinned: false))) == [
            .resize(PaneGridSubmission(dimensions: .init(columns: 120, rows: 50), pinned: false)),
        ])
        #expect(reducer.phase == .running)
    }

    @Test("input submitted while spawning follows launch input after spawn")
    func spawningInputIsBufferedInArrivalOrder() throws {
        var reducer = PaneProcessLifecycleReducer()
        var input = lifecycleInput()
        input.launchCommand = "printf launch"
        let first = PaneInputSubmissionId(rawValue: 1)
        let second = PaneInputSubmissionId(rawValue: 2)

        _ = reducer.handle(.start(input))
        #expect(reducer.handle(.sendInput([0x61], origin: 7, submissionId: first)).isEmpty)
        #expect(reducer.handle(.sendInput([0x62], origin: 8, submissionId: second)).isEmpty)
        #expect(reducer.handle(.spawnSucceeded) == [
            .activateIO,
            .writeInput(Array("printf launch\n".utf8), origin: nil, submissionId: nil),
            .writeInput([0x61], origin: 7, submissionId: first),
            .writeInput([0x62], origin: 8, submissionId: second),
        ])
    }

    @Test("launch input is carried as a tracked submission")
    func launchInputIsTracked() throws {
        var reducer = PaneProcessLifecycleReducer()
        var input = lifecycleInput()
        input.launchCommand = "printf launch"
        let launch = PaneInputSubmissionId(rawValue: 41)
        let firstSpec = try resolveLaunchPlan(input).get().spec(shell: 0, workingDirectory: 0)

        #expect(reducer.handle(.trackInitialInput(launch)).isEmpty)
        #expect(reducer.handle(.start(input)) == [.spawn(firstSpec)])
        #expect(reducer.handle(.spawnSucceeded) == [
            .activateIO,
            .writeInput(Array("printf launch\n".utf8), origin: nil, submissionId: launch),
        ])
    }

    @Test("input submitted before start is delivered behind launch input")
    func idleInputIsBufferedUntilStartAndSpawn() throws {
        var reducer = PaneProcessLifecycleReducer()
        var input = lifecycleInput()
        input.launchCommand = "printf launch"
        let submission = PaneInputSubmissionId(rawValue: 1)
        let plan = try resolveLaunchPlan(input).get()

        #expect(reducer.handle(.sendInput(
            [0x61],
            origin: 7,
            submissionId: submission
        )).isEmpty)
        #expect(reducer.handle(.start(input)) == [.spawn(plan.spec(shell: 0, workingDirectory: 0))])
        #expect(reducer.handle(.spawnSucceeded) == [
            .activateIO,
            .writeInput(Array("printf launch\n".utf8), origin: nil, submissionId: nil),
            .writeInput([0x61], origin: 7, submissionId: submission),
        ])
    }

    @Test("buffered input survives working-directory retry")
    func spawningInputSurvivesWorkingDirectoryRetry() throws {
        var reducer = PaneProcessLifecycleReducer()
        let submission = PaneInputSubmissionId(rawValue: 1)
        let plan = try resolveLaunchPlan(lifecycleInput()).get()

        _ = reducer.handle(.start(lifecycleInput()))
        #expect(reducer.handle(.sendInput([0x61], origin: nil, submissionId: submission)).isEmpty)
        #expect(reducer.handle(.spawnFailed(.workingDirectoryUnavailable)) == [.spawn(plan.spec(shell: 0, workingDirectory: 1))])
        #expect(reducer.handle(.spawnSucceeded) == [
            .activateIO,
            .writeInput([0x61], origin: nil, submissionId: submission),
        ])
    }

    @Test("spawning retains only the latest complete geometry")
    func spawningResizeRetainsLatestGeometry() {
        // Intent: geometry reports received during spawn produce one resize with
        //   the latest dimensions and pinnedness after the child starts.
        // Why it exists: applied-geometry deduplication relies on the lifecycle
        //   reducer preserving the newest full fact rather than each transition.
        // Scenario: dimensions and pinnedness both change before spawn succeeds.
        var reducer = PaneProcessLifecycleReducer()
        let first = PaneGridSubmission(
            dimensions: .init(columns: 90, rows: 30),
            pinned: true
        )
        let latest = PaneGridSubmission(
            dimensions: .init(columns: 120, rows: 50),
            pinned: false
        )

        _ = reducer.handle(.start(lifecycleInput()))
        #expect(reducer.handle(.resize(first)).isEmpty)
        #expect(reducer.handle(.resize(latest)).isEmpty)
        #expect(reducer.handle(.spawnSucceeded) == [
            .activateIO,
            .resize(latest),
        ])
    }

    @Test("spawn failure rejects every buffered input submission")
    func spawnFailureRejectsBufferedInput() {
        var reducer = PaneProcessLifecycleReducer()
        let first = PaneInputSubmissionId(rawValue: 1)
        let second = PaneInputSubmissionId(rawValue: 2)

        _ = reducer.handle(.start(lifecycleInput()))
        _ = reducer.handle(.sendInput([0x61], origin: nil, submissionId: first))
        _ = reducer.handle(.sendInput([0x62], origin: nil, submissionId: second))

        #expect(reducer.handle(.spawnFailed(.systemError(13))) == [
            .completeInput(first, .rejected(.launchFailed(.systemError(13)))),
            .completeInput(second, .rejected(.launchFailed(.systemError(13)))),
            .report(.launchFailed(.systemError(13))),
            .finishTeardown,
        ])
    }

    @Test("close while spawning rejects every buffered input submission")
    func closeWhileSpawningRejectsBufferedInput() {
        var reducer = PaneProcessLifecycleReducer()
        let submission = PaneInputSubmissionId(rawValue: 1)

        _ = reducer.handle(.start(lifecycleInput()))
        _ = reducer.handle(.sendInput([0x61], origin: nil, submissionId: submission))

        #expect(reducer.handle(.requestClose) == [
            .armExitBound,
            .completeInput(submission, .rejected(.processEnded)),
        ])
    }

    @Test("pre-spawn input rejects the whole submission at the byte bound")
    func spawningInputIsBounded() {
        var reducer = PaneProcessLifecycleReducer()
        let accepted = PaneInputSubmissionId(rawValue: 1)
        let rejected = PaneInputSubmissionId(rawValue: 2)

        _ = reducer.handle(.start(lifecycleInput()))
        let full = [UInt8](repeating: 0x61, count: PaneProcessLifecycleReducer.pendingInputByteLimit)
        #expect(reducer.handle(.sendInput(full, origin: nil, submissionId: accepted)).isEmpty)
        #expect(reducer.handle(.sendInput([0x62], origin: nil, submissionId: rejected)) == [
            .completeInput(rejected, .rejected(.bufferLimitExceeded)),
        ])
    }

    @Test("cwd spawn failures walk the cwd ladder and then report it spent")
    func cwdSpawnFallback() throws {
        var reducer = PaneProcessLifecycleReducer()
        let plan = try resolveLaunchPlan(lifecycleInput()).get()

        #expect(reducer.handle(.start(lifecycleInput())) == [.spawn(plan.spec(shell: 0, workingDirectory: 0))])
        #expect(reducer.handle(.spawnFailed(.workingDirectoryUnavailable)) == [.spawn(plan.spec(shell: 0, workingDirectory: 1))])
        #expect(reducer.handle(.spawnFailed(.workingDirectoryUnavailable)) == [.spawn(plan.spec(shell: 0, workingDirectory: 2))])
        #expect(reducer.handle(.spawnFailed(.workingDirectoryUnavailable)) == [
            .report(.launchFailed(.workingDirectoryUnavailable)),
            .finishTeardown,
        ])
        #expect(reducer.phase == .finished)
    }

    @Test("exec spawn failures walk the shell ladder and then report it spent")
    func execSpawnFallback() throws {
        // Intent: an exec-stage failure offers the next shell in the same cwd, and
        //   the report that ends the walk carries the last attempt's errno.
        // Why it exists: the shell fallback is the whole reason the ladder exists.
        //   Nothing predicts a usable shell any more, so only the retry can find
        //   one, and only the final errno can say why none was found.
        // Scenario: spec-first -- every shell candidate is refused by execve.
        var reducer = PaneProcessLifecycleReducer()
        let plan = try resolveLaunchPlan(lifecycleInput()).get()

        #expect(reducer.handle(.start(lifecycleInput())) == [.spawn(plan.spec(shell: 0, workingDirectory: 0))])
        #expect(reducer.handle(.spawnFailed(.executableUnavailable(2)))
            == [.spawn(plan.spec(shell: 1, workingDirectory: 0))])
        #expect(reducer.handle(.spawnFailed(.executableUnavailable(13))) == [
            .report(.launchFailed(.noUsableShell(13))),
            .finishTeardown,
        ])
        #expect(reducer.phase == .finished)
    }

    @Test("each ladder advances only on its own failure stage")
    func ladderIndexesAdvanceIndependently() throws {
        // Intent: a cwd failure keeps the shell, an exec failure keeps the cwd
        //   that already passed chdir, and the surviving pair runs.
        // Why it exists: one shared index, or a product of the two ladders, would
        //   retry a candidate the kernel already rejected and could skip the pair
        //   that actually works.
        // Scenario: spec-first -- the first cwd is unreachable and the first shell
        //   is unrunnable, so the second shell must run in the second cwd.
        var reducer = PaneProcessLifecycleReducer()
        let plan = try resolveLaunchPlan(lifecycleInput()).get()

        _ = reducer.handle(.start(lifecycleInput()))
        #expect(reducer.handle(.spawnFailed(.workingDirectoryUnavailable))
            == [.spawn(plan.spec(shell: 0, workingDirectory: 1))])
        #expect(reducer.handle(.spawnFailed(.executableUnavailable(2)))
            == [.spawn(plan.spec(shell: 1, workingDirectory: 1))])
        #expect(reducer.handle(.spawnSucceeded) == [.activateIO])
    }

    @Test("buffered input survives an exec retry")
    func spawningInputSurvivesExecRetry() throws {
        // Intent: input buffered while spawning is delivered after a shell retry,
        //   not only after a cwd retry.
        // Why it exists: the exec retry is a second path through the spawning
        //   state, and pending input and grid must cross it the same way.
        // Scenario: spec-first -- a keystroke and a resize arrive, then the first
        //   shell is refused by execve.
        var reducer = PaneProcessLifecycleReducer()
        let submission = PaneInputSubmissionId(rawValue: 1)
        let grid = PaneGridSubmission(dimensions: .init(columns: 120, rows: 50), pinned: false)
        let plan = try resolveLaunchPlan(lifecycleInput()).get()

        _ = reducer.handle(.start(lifecycleInput()))
        #expect(reducer.handle(.sendInput([0x61], origin: nil, submissionId: submission)).isEmpty)
        #expect(reducer.handle(.resize(grid)).isEmpty)
        #expect(reducer.handle(.spawnFailed(.executableUnavailable(2)))
            == [.spawn(plan.spec(shell: 1, workingDirectory: 0))])
        #expect(reducer.handle(.spawnSucceeded) == [
            .activateIO,
            .resize(grid),
            .writeInput([0x61], origin: nil, submissionId: submission),
        ])
    }

    @Test("a non-retryable bootstrap stage ends the launch on its first report")
    func systemErrorEndsLaunchWithoutRetry() {
        var reducer = PaneProcessLifecycleReducer()

        _ = reducer.handle(.start(lifecycleInput()))
        #expect(reducer.handle(.spawnFailed(.systemError(13))) == [
            .report(.launchFailed(.systemError(13))),
            .finishTeardown,
        ])
        #expect(reducer.phase == .finished)
    }

    @Test("EOF before exit reaps and cleans the session before reporting")
    func eofBeforeExit() {
        var reducer = runningReducer()
        let status = ChildExitStatus.exited(7)

        #expect(reducer.handle(.outputEOF).isEmpty)
        #expect(reducer.handle(.childExited(status)) == beginSelfExitCommands)
        #expect(reducer.handle(.masterClosed) == masterClosedCommands)
        #expect(reducer.handle(.sessionDrained) == finishCommands(for: .exited(status)))
        #expect(reducer.phase == .finished)
    }

    @Test("exit before EOF drains committed output before cleanup and reporting")
    func exitBeforeEOF() {
        var reducer = runningReducer()
        let status = ChildExitStatus.exited(9)

        #expect(reducer.handle(.childExited(status)) == [.drainOutput])
        #expect(reducer.handle(.outputEOF) == beginSelfExitCommands)
        #expect(reducer.handle(.masterClosed) == masterClosedCommands)
        #expect(reducer.handle(.sessionDrained) == finishCommands(for: .exited(status)))
    }

    @Test("user close completes through the bounded ladder")
    func userClose() {
        var reducer = runningReducer()

        #expect(reducer.handle(.requestClose) == beginCloseCommands)
        #expect(reducer.handle(.masterClosed) == masterClosedCommands)
        #expect(reducer.handle(.graceElapsed(.hangup)) == [
            .signalSession(.terminate),
            .scheduleGrace(.terminate),
        ])
        #expect(reducer.handle(.graceElapsed(.terminate)) == [.signalSession(.kill)])
        #expect(reducer.handle(.childExited(.signaled(9))) == [.reapLeader])
        #expect(reducer.handle(.sessionDrained) == finishCancelledCommands)
    }

    @Test("master close completion starts the teardown ladder exactly once")
    func masterCloseCompletionStartsTeardownLadder() {
        var reducer = runningReducer()

        #expect(reducer.handle(.requestClose) == [.armExitBound, .closeMaster])
        #expect(reducer.handle(.masterClosed) == [
            .signalSession(.hangup),
            .scheduleGrace(.hangup),
        ])
        #expect(reducer.handle(.masterClosed).isEmpty)
    }

    @Test("teardown progress waits for master close completion")
    func teardownProgressWaitsForMasterClose() {
        var reducer = runningReducer()

        _ = reducer.handle(.requestClose)
        #expect(reducer.handle(.graceElapsed(.hangup)).isEmpty)
        #expect(reducer.handle(.sessionDrained).isEmpty)
        #expect(reducer.handle(.masterClosed) == [
            .signalSession(.hangup),
            .scheduleGrace(.hangup),
        ])
        #expect(reducer.handle(.graceElapsed(.hangup)) == [
            .signalSession(.terminate),
            .scheduleGrace(.terminate),
        ])
        #expect(reducer.handle(.graceElapsed(.terminate)) == [.signalSession(.kill)])
    }

    @Test("master close completion is inert outside active teardown")
    func masterCloseCompletionIsPhaseBound() {
        var idle = PaneProcessLifecycleReducer()
        #expect(idle.handle(.masterClosed).isEmpty)
        #expect(idle.phase == .idle)

        var spawning = PaneProcessLifecycleReducer()
        _ = spawning.handle(.start(lifecycleInput()))
        #expect(spawning.handle(.masterClosed).isEmpty)
        #expect(spawning.phase == .spawning)

        var closingWhileSpawning = PaneProcessLifecycleReducer()
        _ = closingWhileSpawning.handle(.start(lifecycleInput()))
        _ = closingWhileSpawning.handle(.requestClose)
        #expect(closingWhileSpawning.handle(.masterClosed).isEmpty)
        #expect(closingWhileSpawning.phase == .spawning)

        var running = runningReducer()
        #expect(running.handle(.masterClosed).isEmpty)
        #expect(running.phase == .running)

        var draining = runningReducer()
        _ = draining.handle(.childExited(.exited(1)))
        #expect(draining.handle(.masterClosed).isEmpty)
        #expect(draining.phase == .drainingOutput)

        var finished = PaneProcessLifecycleReducer()
        _ = finished.handle(.requestClose)
        #expect(finished.handle(.masterClosed).isEmpty)
        #expect(finished.phase == .finished)
    }

    @Test("a drained session reaps and finishes without child-exit observation")
    func sessionDrainConvergesWithoutChildExit() {
        // Intent: session-drain evidence reaps the leader and completes teardown
        //   without requiring a separate child-exit event.
        // Why it exists: close-while-spawning never arms the best-effort exit
        //   observer, so making that event mandatory stalls until the host bound.
        // Scenario: a running pane closes and its host-owned census observes the
        //   empty session before any best-effort process callback is delivered.
        var reducer = runningReducer()

        _ = reducer.handle(.requestClose)
        _ = reducer.handle(.masterClosed)
        #expect(reducer.handle(.sessionDrained) == [
            .reapLeader,
            .cancelGrace,
            .finishTeardown,
        ])
        #expect(reducer.phase == .finished)
    }

    @Test("teardown reaps exactly once before finishing under either witness order")
    func teardownReapsOnceBeforeFinish() throws {
        // Intent: whichever convergence witness arrives first, teardown requests
        //   one leader reap and orders it before final ownership release.
        // Why it exists: letting both exit observation and session drain request
        //   a reap can double-wait, while finishing first can abandon a zombie.
        // Scenario: the exit observer and session census race after a pane closes.
        let orderings: [[PaneProcessLifecycleEvent]] = [
            [.childExited(.signaled(1)), .sessionDrained],
            [.sessionDrained, .childExited(.signaled(1))],
        ]

        for events in orderings {
            var reducer = runningReducer()
            var commands = reducer.handle(.requestClose)
            commands += reducer.handle(.masterClosed)
            for event in events {
                commands += reducer.handle(event)
            }

            let reapIndices = commands.indices.filter { commands[$0] == .reapLeader }
            let finishIndices = commands.indices.filter { commands[$0] == .finishTeardown }
            #expect(reapIndices.count == 1)
            #expect(finishIndices.count == 1)
            let reapIndex = try #require(reapIndices.first)
            let finishIndex = try #require(finishIndices.first)
            #expect(reapIndex < finishIndex)
            #expect(reducer.phase == .finished)
        }
    }

    @Test("close while spawning converges without retrying or orphaning a child")
    func closeWhileSpawning() {
        var reducer = PaneProcessLifecycleReducer()
        var input = lifecycleInput()
        input.launchCommand = "must not run"

        _ = reducer.handle(.start(input))
        #expect(reducer.handle(.requestClose) == [.armExitBound])
        #expect(reducer.handle(.spawnSucceeded) == [.closeMaster])
        #expect(reducer.handle(.masterClosed) == masterClosedCommands)
        #expect(reducer.handle(.sessionDrained) == [
            .reapLeader,
            .cancelGrace,
            .finishTeardown,
        ])
        #expect(reducer.phase == .finished)
    }

    @Test("close while a spawn failure is pending finishes without reporting failure")
    func closeWhileSpawnFails() {
        var reducer = PaneProcessLifecycleReducer()

        _ = reducer.handle(.start(lifecycleInput()))
        #expect(reducer.handle(.requestClose) == [.armExitBound])
        #expect(reducer.handle(.spawnFailed(.workingDirectoryUnavailable)) == [.finishTeardown])
    }

    @Test("finished lifecycle rejects input and ignores every other later event")
    func finishedStateIsTerminal() {
        var reducer = PaneProcessLifecycleReducer()
        #expect(reducer.handle(.requestClose) == [.finishTeardown])

        let submission = PaneInputSubmissionId(rawValue: 1)
        #expect(reducer.handle(.sendInput([1], origin: nil, submissionId: submission)) == [
            .completeInput(submission, .rejected(.processEnded)),
        ])
        let events: [PaneProcessLifecycleEvent] = [
            .start(lifecycleInput()), .spawnSucceeded,
            .spawnFailed(.systemError(1)),
            .resize(PaneGridSubmission(dimensions: .init(columns: 1, rows: 1), pinned: false)),
            .outputEOF, .childExited(.exited(0)), .requestClose,
            .masterClosed, .graceElapsed(.hangup), .sessionDrained,
        ]
        for event in events {
            #expect(reducer.handle(event).isEmpty)
        }
    }

    @Test("a second launch request never creates a second process owner")
    func duplicateStartIsInertOnceLaunched() throws {
        // Intent: once a pane has started, another `.start` emits no command and
        //   changes no state, so a pane can never own two child processes.
        // Why it exists: `.start` is matched only in the idle state, and every
        //   live state drops it through a `default: return []` catch-all. That
        //   makes single ownership true today but silent -- adding a `case
        //   .start` to a live state (a plausible way to build "restart this
        //   pane") would spawn a second child, orphaning the first with its PTY
        //   still open, and no existing test would object. The interleaving
        //   suite covers close/exit races, not repeated launches.
        // Scenario: a duplicate launch request arrives at a pane that is still
        //   spawning, then again once it is running, then again while it drains
        //   after the child exits.
        var reducer = PaneProcessLifecycleReducer()
        let plan = try resolveLaunchPlan(lifecycleInput()).get()
        #expect(reducer.handle(.start(lifecycleInput())) == [.spawn(plan.spec(shell: 0, workingDirectory: 0))])

        #expect(reducer.handle(.start(lifecycleInput())).isEmpty)
        #expect(reducer.phase == .spawning)

        #expect(reducer.handle(.spawnSucceeded) == [.activateIO])
        #expect(reducer.handle(.start(lifecycleInput())).isEmpty)
        #expect(reducer.phase == .running)

        #expect(reducer.handle(.childExited(.exited(0))) == [.drainOutput])
        #expect(reducer.handle(.start(lifecycleInput())).isEmpty)
        #expect(reducer.phase == .drainingOutput)
    }
}

let beginCloseCommands: [PaneProcessLifecycleCommand] = [
    .armExitBound,
    .closeMaster,
]

let beginSelfExitCommands: [PaneProcessLifecycleCommand] = [
    .armExitBound,
    .reapLeader,
    .closeMaster,
]

let masterClosedCommands: [PaneProcessLifecycleCommand] = [
    .signalSession(.hangup),
    .scheduleGrace(.hangup),
]

func finishCommands(for result: PaneProcessLifecycleResult) -> [PaneProcessLifecycleCommand] {
    [.cancelGrace, .report(result), .finishTeardown]
}

let finishCancelledCommands: [PaneProcessLifecycleCommand] = [.cancelGrace, .finishTeardown]

func lifecycleInput() -> LaunchPolicyInput {
    LaunchPolicyInput(
        accountShell: "/bin/zsh",
        requestedWorkingDirectory: "/work",
        homeDirectory: "/Users/tester",
        inheritedEnvironment: [],
        advertisedEnvironment: [EnvironmentEntry(name: "TERM", value: "xterm-256color")],
        paneEnvironment: [],
        command: nil,
        launchCommand: nil,
        initialDimensions: TerminalDimensions(columns: 80, rows: 24)
    )
}

func runningReducer() -> PaneProcessLifecycleReducer {
    var reducer = PaneProcessLifecycleReducer()
    _ = reducer.handle(.start(lifecycleInput()))
    _ = reducer.handle(.spawnSucceeded)
    return reducer
}
