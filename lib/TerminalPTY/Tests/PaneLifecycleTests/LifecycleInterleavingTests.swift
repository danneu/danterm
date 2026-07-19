// Exhaustive two-event race permutations proving lifecycle invariants by behavior.
import Testing
@testable import PaneLifecycle

@Suite struct LifecycleInterleavingTests {
    @Test("named lifecycle races preserve cancellation, delivery, and reporting invariants")
    func namedRacePermutations() {
        checkSpawnRace(with: .spawnSucceeded)
        checkSpawnRace(with: .spawnFailed(.workingDirectoryUnavailable))

        for event in [
            PaneLifecycleEvent.output([0x78]),
            .outputEOF,
            .childExited(.exited(4)),
            .resize(TerminalDimensions(columns: 90, rows: 30)),
        ] {
            checkRunningRace(with: event)
        }

        checkGraceExitRace()
        checkEOFExitRace()
    }

    private func checkSpawnRace(with outcome: PaneLifecycleEvent) {
        for events in permutations(.requestClose, outcome) {
            var reducer = PaneLifecycleReducer()
            var commands = reducer.handle(.start(lifecycleInput()))
            var closeSeen = false

            for event in events {
                closeSeen = closeSeen || event == .requestClose
                let emitted = reducer.handle(event)
                if closeSeen {
                    #expect(!emitted.contains { if case .spawn = $0 { true } else { false } })
                }
                commands += emitted
            }
            commands += converge(&reducer)
            assertInvariants(commands, reducer: reducer)
        }
    }

    private func checkRunningRace(with racingEvent: PaneLifecycleEvent) {
        for events in permutations(.requestClose, racingEvent) {
            var reducer = runningReducer()
            var commands: [PaneLifecycleCommand] = []
            var closeSeen = false

            for event in events {
                let emitted = reducer.handle(event)
                if closeSeen {
                    #expect(!emitted.contains { if case .deliverOutput = $0 { true } else { false } })
                }
                commands += emitted
                closeSeen = closeSeen || event == .requestClose
            }
            commands += converge(&reducer)
            assertInvariants(commands, reducer: reducer)
        }
    }

    private func checkGraceExitRace() {
        for events in permutations(.graceElapsed(.hangup), .childExited(.exited(12))) {
            var reducer = runningReducer()
            var commands = reducer.handle(.requestClose)
            for event in events { commands += reducer.handle(event) }
            commands += converge(&reducer)
            assertInvariants(commands, reducer: reducer)
        }
    }

    private func checkEOFExitRace() {
        for events in permutations(.outputEOF, .childExited(.exited(3))) {
            var reducer = runningReducer()
            var commands: [PaneLifecycleCommand] = []
            for event in events { commands += reducer.handle(event) }
            commands += converge(&reducer)
            assertInvariants(commands, reducer: reducer)
            #expect(commands.filter { if case .report = $0 { true } else { false } }.count == 1)
        }
    }

    private func converge(_ reducer: inout PaneLifecycleReducer) -> [PaneLifecycleCommand] {
        var commands: [PaneLifecycleCommand] = []
        switch reducer.phase {
        case .spawning:
            commands += reducer.handle(.spawnFailed(.systemError(99)))
        case .running:
            commands += reducer.handle(.requestClose)
        case .drainingOutput:
            commands += reducer.handle(.outputEOF)
        case .idle, .tearingDown, .finished:
            break
        }
        commands += reducer.handle(.childExited(.signaled(9)))
        commands += reducer.handle(.sessionDrained)
        return commands
    }

    private func assertInvariants(_ commands: [PaneLifecycleCommand], reducer: PaneLifecycleReducer) {
        var reducer = reducer
        #expect(reducer.phase == .finished)
        #expect(commands.filter { if case .report = $0 { true } else { false } }.count <= 1)

        let stages = commands.compactMap { command -> TeardownStage? in
            if case .signalSession(let stage) = command { return stage }
            return nil
        }
        #expect(zip(stages, stages.dropFirst()).allSatisfy { $0.rawValue <= $1.rawValue })

        for event in [PaneLifecycleEvent.requestClose, .output([1]), .childExited(.exited(0)), .sessionDrained] {
            #expect(reducer.handle(event).isEmpty)
        }
    }
}

private func permutations(_ first: PaneLifecycleEvent, _ second: PaneLifecycleEvent) -> [[PaneLifecycleEvent]] {
    [[first, second], [second, first]]
}
