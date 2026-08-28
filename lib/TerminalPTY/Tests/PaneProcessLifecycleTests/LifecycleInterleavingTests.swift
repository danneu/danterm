// Exhaustive two-event race permutations proving lifecycle invariants by behavior.
import Testing
@testable import PaneProcessLifecycle

@Suite struct LifecycleInterleavingTests {
    @Test("named lifecycle races converge from host-owned census evidence")
    func namedRacePermutations() {
        // Intent: every named close/exit permutation reaches a terminal state
        //   when the convergence helper supplies only session-drain evidence.
        // Why it exists: the old helper always injected a best-effort child-exit
        //   event, masking teardown states that the real host could not resolve.
        // Scenario: close, spawn, EOF, and grace events race while the
        //   host-owned session poll remains the only guaranteed final witness.
        checkSpawnRace(with: .spawnSucceeded)
        checkSpawnRace(with: .spawnFailed(.workingDirectoryUnavailable))
        checkSpawnRace(with: .spawnFailed(.executableUnavailable(2)))

        for event in [
            PaneProcessLifecycleEvent.outputEOF,
            .childExited(.exited(4)),
            .resize(PaneGridSubmission(dimensions: .init(columns: 90, rows: 30), pinned: false)),
        ] {
            checkRunningRace(with: event)
        }

        checkGraceExitRace()
        checkEOFExitRace()
    }

    @Test("closing an idle reducer does not arm the exit bound")
    func idleCloseNeedsNoExitBound() {
        var reducer = PaneProcessLifecycleReducer()

        let commands = reducer.handle(.requestClose)

        #expect(commands.contains(.armExitBound) == false)
        #expect(reducer.phase == .finished)
    }

    private func checkSpawnRace(with outcome: PaneProcessLifecycleEvent) {
        for events in permutations(.requestClose, outcome) {
            var reducer = PaneProcessLifecycleReducer()
            var masterClosedSeen = false
            var commands = reduce(
                .start(lifecycleInput()),
                with: &reducer,
                masterClosedSeen: &masterClosedSeen
            )
            var closeSeen = false

            for event in events {
                closeSeen = closeSeen || event == .requestClose
                let emitted = reduce(
                    event,
                    with: &reducer,
                    masterClosedSeen: &masterClosedSeen
                )
                if closeSeen {
                    #expect(!emitted.contains { if case .spawn = $0 { true } else { false } })
                }
                commands += emitted
            }
            commands += converge(&reducer, masterClosedSeen: &masterClosedSeen)
            assertInvariants(commands, reducer: reducer)
        }
    }

    private func checkRunningRace(with racingEvent: PaneProcessLifecycleEvent) {
        for events in permutations(.requestClose, racingEvent) {
            var reducer = runningReducer()
            var commands: [PaneProcessLifecycleCommand] = []
            var masterClosedSeen = false

            for event in events {
                commands += reduce(
                    event,
                    with: &reducer,
                    masterClosedSeen: &masterClosedSeen
                )
            }
            commands += converge(&reducer, masterClosedSeen: &masterClosedSeen)
            assertInvariants(commands, reducer: reducer)
        }
    }

    private func checkGraceExitRace() {
        for events in permutations(.graceElapsed(.hangup), .childExited(.exited(12))) {
            var reducer = runningReducer()
            var masterClosedSeen = false
            var commands = reduce(
                .requestClose,
                with: &reducer,
                masterClosedSeen: &masterClosedSeen
            )
            for event in events {
                commands += reduce(
                    event,
                    with: &reducer,
                    masterClosedSeen: &masterClosedSeen
                )
            }
            commands += converge(&reducer, masterClosedSeen: &masterClosedSeen)
            assertInvariants(commands, reducer: reducer)
        }
    }

    private func checkEOFExitRace() {
        for events in permutations(.outputEOF, .childExited(.exited(3))) {
            var reducer = runningReducer()
            var commands: [PaneProcessLifecycleCommand] = []
            var masterClosedSeen = false
            for event in events {
                commands += reduce(
                    event,
                    with: &reducer,
                    masterClosedSeen: &masterClosedSeen
                )
            }
            commands += converge(&reducer, masterClosedSeen: &masterClosedSeen)
            assertInvariants(commands, reducer: reducer)
            #expect(commands.filter { if case .report = $0 { true } else { false } }.count == 1)
        }
    }

    private func converge(
        _ reducer: inout PaneProcessLifecycleReducer,
        masterClosedSeen: inout Bool
    ) -> [PaneProcessLifecycleCommand] {
        var commands: [PaneProcessLifecycleCommand] = []
        switch reducer.phase {
        case .spawning:
            commands += reduce(
                .spawnFailed(.systemError(99)),
                with: &reducer,
                masterClosedSeen: &masterClosedSeen
            )
        case .running:
            commands += reduce(
                .requestClose,
                with: &reducer,
                masterClosedSeen: &masterClosedSeen
            )
        case .drainingOutput:
            commands += reduce(
                .outputEOF,
                with: &reducer,
                masterClosedSeen: &masterClosedSeen
            )
        case .idle, .tearingDown, .finished:
            break
        }
        commands += reduce(
            .sessionDrained,
            with: &reducer,
            masterClosedSeen: &masterClosedSeen
        )
        return commands
    }

    private func reduce(
        _ event: PaneProcessLifecycleEvent,
        with reducer: inout PaneProcessLifecycleReducer,
        masterClosedSeen: inout Bool
    ) -> [PaneProcessLifecycleCommand] {
        let commands = reducer.handle(event)
        let emittedSignal = commands.contains {
            if case .signalSession = $0 { true } else { false }
        }
        #expect(emittedSignal == false || masterClosedSeen)
        guard commands.contains(.closeMaster) else { return commands }
        #expect(commands.last == .closeMaster)

        masterClosedSeen = true
        return commands + reducer.handle(.masterClosed)
    }

    private func assertInvariants(_ commands: [PaneProcessLifecycleCommand], reducer: PaneProcessLifecycleReducer) {
        var reducer = reducer
        #expect(reducer.phase == .finished)
        #expect(commands.filter { $0 == .armExitBound }.count == 1)
        #expect(commands.filter { if case .report = $0 { true } else { false } }.count <= 1)

        let stages = commands.compactMap { command -> TeardownStage? in
            if case .signalSession(let stage) = command { return stage }
            return nil
        }
        #expect(zip(stages, stages.dropFirst()).allSatisfy { $0.rawValue <= $1.rawValue })

        for event in [PaneProcessLifecycleEvent.requestClose, .childExited(.exited(0)), .sessionDrained] {
            #expect(reducer.handle(event).isEmpty)
        }
    }
}

private func permutations(_ first: PaneProcessLifecycleEvent, _ second: PaneProcessLifecycleEvent) -> [[PaneProcessLifecycleEvent]] {
    [[first, second], [second, first]]
}
