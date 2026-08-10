// Golden lifecycle traces proving exact ordered commands at the pure PTY boundary.
import Testing
@testable import PaneLifecycle

@Suite struct LifecycleReducerTests {
    @Test("launch becomes ready and preserves ordered input, resize, and output")
    func launchReadinessAndIO() throws {
        var reducer = PaneLifecycleReducer()
        var input = lifecycleInput()
        input.launchCommand = "printf ready"
        let firstSpec = try resolveLaunchPlan(input).get().attempts[0]

        #expect(reducer.handle(.start(input)) == [.spawn(firstSpec)])
        #expect(reducer.handle(.spawnSucceeded) == [
            .activateIO,
            .writeInput(Array("printf ready\n".utf8)),
        ])
        #expect(reducer.handle(.spawnSucceeded).isEmpty)
        #expect(reducer.handle(.sendInput([0x61, 0x62])) == [.writeInput([0x61, 0x62])])
        #expect(reducer.handle(.resize(TerminalDimensions(columns: 120, rows: 50))) == [
            .resize(TerminalDimensions(columns: 120, rows: 50)),
        ])
        #expect(reducer.handle(.output([0x63, 0x64])) == [.deliverOutput([0x63, 0x64])])
        #expect(reducer.phase == .running)
    }

    @Test("cwd spawn failures advance through the resolved fallback chain")
    func cwdSpawnFallback() throws {
        var reducer = PaneLifecycleReducer()
        let plan = try resolveLaunchPlan(lifecycleInput()).get()

        #expect(reducer.handle(.start(lifecycleInput())) == [.spawn(plan.attempts[0])])
        #expect(reducer.handle(.spawnFailed(.workingDirectoryUnavailable)) == [.spawn(plan.attempts[1])])
        #expect(reducer.handle(.spawnFailed(.workingDirectoryUnavailable)) == [.spawn(plan.attempts[2])])
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
        #expect(reducer.handle(.sessionDrained) == finishCommands(for: .exited(status)))
        #expect(reducer.phase == .finished)
    }

    @Test("exit before EOF drains committed output before cleanup and reporting")
    func exitBeforeEOF() {
        var reducer = runningReducer()
        let status = ChildExitStatus.exited(9)

        #expect(reducer.handle(.childExited(status)) == [.drainOutput])
        #expect(reducer.handle(.output([0x66, 0x69, 0x6e, 0x61, 0x6c])) == [
            .deliverOutput([0x66, 0x69, 0x6e, 0x61, 0x6c]),
        ])
        #expect(reducer.handle(.outputEOF) == beginSelfExitCommands)
        #expect(reducer.handle(.sessionDrained) == finishCommands(for: .exited(status)))
    }

    @Test("user close drops later output and completes through the bounded ladder")
    func userClose() {
        var reducer = runningReducer()

        #expect(reducer.handle(.requestClose) == beginCloseCommands)
        #expect(reducer.handle(.output([0x6c, 0x61, 0x74, 0x65])).isEmpty)
        #expect(reducer.handle(.graceElapsed(.hangup)) == [
            .signalSession(.terminate),
            .scheduleGrace(.terminate),
        ])
        #expect(reducer.handle(.graceElapsed(.terminate)) == [.signalSession(.kill)])
        #expect(reducer.handle(.childExited(.signaled(9))) == [.reapLeader])
        #expect(reducer.handle(.sessionDrained) == finishCancelledCommands)
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
        let orderings: [[PaneLifecycleEvent]] = [
            [.childExited(.signaled(1)), .sessionDrained],
            [.sessionDrained, .childExited(.signaled(1))],
        ]

        for events in orderings {
            var reducer = runningReducer()
            var commands = reducer.handle(.requestClose)
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
        var reducer = PaneLifecycleReducer()
        var input = lifecycleInput()
        input.launchCommand = "must not run"

        _ = reducer.handle(.start(input))
        #expect(reducer.handle(.requestClose).isEmpty)
        #expect(reducer.handle(.spawnSucceeded) == beginCloseCommands)
        #expect(reducer.handle(.sessionDrained) == [
            .reapLeader,
            .cancelGrace,
            .finishTeardown,
        ])
        #expect(reducer.phase == .finished)
    }

    @Test("close while a spawn failure is pending finishes without reporting failure")
    func closeWhileSpawnFails() {
        var reducer = PaneLifecycleReducer()

        _ = reducer.handle(.start(lifecycleInput()))
        #expect(reducer.handle(.requestClose).isEmpty)
        #expect(reducer.handle(.spawnFailed(.workingDirectoryUnavailable)) == [.finishTeardown])
    }

    @Test("finished lifecycle ignores every later event")
    func finishedStateIsTerminal() {
        var reducer = PaneLifecycleReducer()
        #expect(reducer.handle(.requestClose) == [.finishTeardown])

        let events: [PaneLifecycleEvent] = [
            .start(lifecycleInput()), .spawnSucceeded,
            .spawnFailed(.systemError(1)), .sendInput([1]),
            .resize(TerminalDimensions(columns: 1, rows: 1)), .output([2]),
            .outputEOF, .childExited(.exited(0)), .requestClose,
            .graceElapsed(.hangup), .sessionDrained,
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
        var reducer = PaneLifecycleReducer()
        let plan = try resolveLaunchPlan(lifecycleInput()).get()
        #expect(reducer.handle(.start(lifecycleInput())) == [.spawn(plan.attempts[0])])

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

let beginCloseCommands: [PaneLifecycleCommand] = [
    .closeMaster,
    .signalSession(.hangup),
    .scheduleGrace(.hangup),
]

let beginSelfExitCommands: [PaneLifecycleCommand] = [
    .reapLeader,
    .closeMaster,
    .signalSession(.hangup),
    .scheduleGrace(.hangup),
]

func finishCommands(for result: PaneLifecycleResult) -> [PaneLifecycleCommand] {
    [.cancelGrace, .report(result), .finishTeardown]
}

let finishCancelledCommands: [PaneLifecycleCommand] = [.cancelGrace, .finishTeardown]

func lifecycleInput() -> LaunchPolicyInput {
    LaunchPolicyInput(
        accountShell: "/bin/zsh",
        executablePaths: ["/bin/zsh", "/bin/sh"],
        requestedWorkingDirectory: "/work",
        homeDirectory: "/Users/tester",
        accessibleDirectories: ["/work", "/Users/tester"],
        inheritedEnvironment: [],
        advertisedEnvironment: [EnvironmentEntry(name: "TERM", value: "xterm-256color")],
        paneEnvironment: [],
        command: nil,
        launchCommand: nil,
        initialDimensions: TerminalDimensions(columns: 80, rows: 24)
    )
}

func runningReducer() -> PaneLifecycleReducer {
    var reducer = PaneLifecycleReducer()
    _ = reducer.handle(.start(lifecycleInput()))
    _ = reducer.handle(.spawnSucceeded)
    return reducer
}
