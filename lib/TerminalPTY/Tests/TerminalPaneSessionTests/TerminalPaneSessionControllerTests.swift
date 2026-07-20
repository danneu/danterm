// Real-PTY session tests for planning, visibility, capture, exit, and teardown.
import Foundation
import PaneLifecycle
import TerminalCoreRecording
import TerminalRenderPlanning
import Testing
@testable import TerminalPTYHost
@testable import TerminalPaneSession

/// Exercises the headless pane controller through one real native PTY per scenario.
@MainActor
@Suite(.serialized)
struct TerminalPaneSessionControllerTests {
    @Test("a stalled consumer conflates a burst and plans the final state", .timeLimit(.minutes(1)))
    func burstConflatesToFinalPlan() async throws {
        // Intent: a main-actor consumer stalled during a write burst eventually
        //   plans the final terminal while producing fewer frames than writes.
        // Why it exists: queuing snapshots instead of conflated wakeups can grow
        //   without bound, while a broken conflation flag can lose the last state.
        // Scenario: a shell prints forty lines and a final marker while the pane
        //   controller cannot process its update task.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "printf '__READY__\\n'")
        )
        var plans: [RenderFramePlan] = []
        controller.onPlan = { plans.append($0) }
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        controller.synchronizeState()
        let baseline = plans.count

        for index in 0..<40 {
            controller.sendText("printf 'burst-\(index)\\n'\n")
        }
        controller.sendText("printf '__FINAL_BURST__\\n'\nexit\n")

        #expect(await host.waitForResult() == .exited(.exited(0)))
        controller.synchronizeState()

        #expect(plans.count - baseline < 41)
        #expect(try #require(plans.last).projectedText.contains("__FINAL_BURST__"))
        controller.tearDown()
        await host.close()
    }

    @Test("result-only and equal snapshots emit no render plan", .timeLimit(.minutes(1)))
    func resultOnlyEqualSnapshotSkipsPlanning() async throws {
        // Intent: lifecycle-only updates notify session exit without planning an
        //   unchanged terminal, and repeat pulls do not repeat either callback.
        // Why it exists: treating every update token as visual damage wastes idle
        //   work and can turn one launch failure into multiple pane-close events.
        // Scenario: launch fails before a child or terminal mutation exists.
        let host = try makeHost()
        var invalidInput = makeLaunchInput(command: nil)
        invalidInput.initialDimensions = .init(columns: 0, rows: 0)
        let controller = TerminalPaneSessionController(host: host, launchInput: invalidInput)
        var planCount = 0
        var results: [PaneLifecycleResult] = []
        let resultChannel = AsyncStream<PaneLifecycleResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var resultIterator = resultChannel.stream.makeAsyncIterator()
        controller.onPlan = { _ in planCount += 1 }
        controller.onSessionEnded = {
            results.append($0)
            resultChannel.continuation.yield($0)
        }

        #expect(await host.waitForResult() == .launchFailed(.invalidDimensions))
        #expect(await resultIterator.next() == .launchFailed(.invalidDimensions))
        controller.synchronizeState()
        controller.synchronizeState()

        #expect(planCount == 0)
        #expect(results == [.launchFailed(.invalidDimensions)])
        #expect(controller.capturedRecording(test: "launch-failure") == nil)
        controller.tearDown()
        await host.close()
    }

    @Test("hidden output refreshes reads and reveal plans once", .timeLimit(.minutes(1)))
    func hiddenOutputAndReveal() async throws {
        // Intent: hidden panes keep their inspection cache current without
        //   planning, then reveal one complete frame for all accumulated output.
        // Why it exists: suspending consumption while hidden loses recovery text;
        //   planning while hidden violates the event-driven power contract.
        // Scenario: a background tab receives shell output and is selected later.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "printf '__READY__\\n'"),
            isVisible: false
        )
        var plans: [RenderFramePlan] = []
        controller.onPlan = { plans.append($0) }
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        controller.sendText("printf '__HIDDEN_OUTPUT__\\n'\n")
        #expect(await host.waitForOutput(containing: Array("__HIDDEN_OUTPUT__".utf8)))
        controller.synchronizeState()

        #expect(plans.isEmpty)
        #expect(controller.readFullHistoryText().contains("__HIDDEN_OUTPUT__"))
        controller.setVisible(true)
        #expect(plans.count == 1)
        #expect(plans[0].projectedText.contains("__HIDDEN_OUTPUT__"))
        controller.setVisible(true)
        #expect(plans.count == 1)

        controller.tearDown()
        await host.close()
    }

    @Test("grid submissions dedupe and remain disabled after teardown", .timeLimit(.minutes(1)))
    func gridDedupeAndPostTeardownNoOps() async throws {
        // Intent: repeated layout reports submit one resize, and teardown closes
        //   both resize and input entry points synchronously.
        // Why it exists: AppKit repeats geometry callbacks, while queued work after
        //   pane destruction can target a closing PTY or deallocated view.
        // Scenario: one layout size arrives twice before a pane closes and stale
        //   input and geometry callbacks arrive afterward.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\"")
        )

        controller.setGridDimensions(.init(columns: 90, rows: 30))
        controller.setGridDimensions(.init(columns: 90, rows: 30))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let resizeCount = await host.submittedTransitions().filter {
            if case .resize = $0 { true } else { false }
        }.count
        let inputCount = await host.submittedTransitions().filter {
            if case .input = $0 { true } else { false }
        }.count
        #expect(resizeCount == 1)

        controller.tearDown()
        controller.sendText("ignored")
        controller.setGridDimensions(.init(columns: 100, rows: 40))
        host.send(Array("direct-after-teardown".utf8))
        host.resize(.init(columns: 110, rows: 45))
        controller.tearDown()
        await host.close()

        #expect(await host.submittedTransitions().filter {
            if case .input = $0 { true } else { false }
        }.count == inputCount)
        #expect(await host.submittedTransitions().filter {
            if case .resize = $0 { true } else { false }
        }.count == 1)
        #expect((await host.resourceSnapshot()).isReleased)
    }

    @Test("teardown suppresses exit callbacks and releases controller and host", .timeLimit(.minutes(1)))
    func teardownSuppressesCallbacksAndReleasesOwners() async throws {
        // Intent: repeated pane teardown suppresses child-ended callbacks and
        //   releases both main-actor controllers and their native owners.
        // Why it exists: an update task that captures its controller or a result
        //   waiter that never resumes leaks every rapidly closed pane.
        // Scenario: a user rapidly creates and closes live shell panes.
        var endedCount = 0
        for _ in 0..<8 {
            weak var releasedController: TerminalPaneSessionController?
            weak var releasedHost: TerminalPTYHost?
            do {
                let host = try makeHost()
                releasedHost = host
                let controller = TerminalPaneSessionController(
                    host: host,
                    launchInput: makeLaunchInput(
                        command: "exec \(try probeExecutable()) hold \"$0\""
                    )
                )
                releasedController = controller
                controller.onSessionEnded = { _ in endedCount += 1 }
                #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

                controller.tearDown()
                controller.tearDown()
                await host.close()

                #expect(endedCount == 0)
                #expect((await host.resourceSnapshot()).isReleased)
            }
            #expect(releasedController == nil)
            #expect(releasedHost == nil)
        }
    }

    @Test("live PTY input, resize, render, and exit cross the controller boundary", .timeLimit(.minutes(1)))
    func livePTYEndToEnd() async throws {
        // Intent: one real session carries ordered grid and input changes into a
        //   complete final frame and emits its child exit exactly once.
        // Why it exists: unit seams cannot prove the bootstrap, PTY owner, terminal
        //   reducer, render planner, and controller compose without dropped state.
        // Scenario: a live shell resizes, prints a marker, and exits normally.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "printf '__READY__\\n'")
        )
        var ended: [PaneLifecycleResult] = []
        let resultChannel = AsyncStream<PaneLifecycleResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var resultIterator = resultChannel.stream.makeAsyncIterator()
        controller.onSessionEnded = {
            ended.append($0)
            resultChannel.continuation.yield($0)
        }
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        controller.setGridDimensions(.init(columns: 42, rows: 7))
        controller.sendText("printf '__CONTROLLER_LIVE__\\n'\nexit\n")
        #expect(await host.waitForResult() == .exited(.exited(0)))
        #expect(await resultIterator.next() == .exited(.exited(0)))
        controller.synchronizeState()

        let plan = try #require(controller.currentPlan)
        #expect(plan.columns == 42)
        #expect(plan.rows == 7)
        #expect(plan.projectedText.contains("__CONTROLLER_LIVE__"))
        #expect(ended == [.exited(.exited(0))])

        controller.tearDown()
        await host.close()
    }

    @Test("child session end exposes one replayable DanTerm recording", .timeLimit(.minutes(1)))
    func childSessionEndExposesRecording() async throws {
        // Intent: an enabled controller captures the exact owner-ordered output
        //   and resize transitions that produced its final synchronous read.
        // Why it exists: the viability harness needs a recording at child end,
        //   including for the last pane that remains modeled until app quit.
        // Scenario: a shell prints before and after a resize, then exits normally;
        //   the harness extracts and replays that completed pane session.
        let launchInput = makeLaunchInput(
            command: "printf '__CAPTURE_READY__\\n'; read ignored"
        )
        let controller = try TerminalPaneSessionController(
            configuration: .init(
                initialDimensions: launchInput.initialDimensions,
                launchInput: launchInput
            ),
            bootstrapExecutable: bootstrapExecutable(),
            captureTransitions: true
        )
        let plans = AsyncStream<RenderFramePlan>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var planIterator = plans.stream.makeAsyncIterator()
        let results = AsyncStream<PaneLifecycleResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var resultIterator = results.stream.makeAsyncIterator()
        controller.onPlan = { plans.continuation.yield($0) }
        controller.onSessionEnded = { results.continuation.yield($0) }
        controller.synchronizeState()
        var readyPlan = controller.currentPlan
        while readyPlan?.projectedText.contains("__CAPTURE_READY__") != true {
            readyPlan = await planIterator.next()
        }

        controller.setGridDimensions(.init(columns: 96, rows: 28))
        controller.sendText("continue\nprintf '__CAPTURE_FINAL__\\n'\nexit\n")
        #expect(await resultIterator.next() == .exited(.exited(0)))
        controller.synchronizeState()

        let recording = try #require(controller.capturedRecording(test: "viability-pane"))
        let replayed = try recording.replay()
        #expect(recording.provenance == .danTerm(test: "viability-pane"))
        #expect(replayed.geometry.columns == 96)
        #expect(replayed.geometry.rows.count == 28)
        #expect(replayed.fullHistoryText == controller.readFullHistoryText())

        controller.tearDown()
        await controller.terminationHandle.terminateForApplicationExit()
    }

    @Test("tearing down a live child never exposes a recording", .timeLimit(.minutes(1)))
    func liveChildTeardownDoesNotExposeRecording() async throws {
        // Intent: recording eligibility follows child-originated session end,
        //   not controller teardown or the host's bounded close completion.
        // Why it exists: capture-on-teardown would mislabel killed partial sessions
        //   and still miss the last pane, which is retained through quit confirmation.
        // Scenario: the user closes a pane while its interactive shell is still live.
        let host = try makeHost(captureTransitions: true)
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\"")
        )
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        controller.tearDown()
        await host.close()

        #expect(controller.capturedRecording(test: "torn-down-pane") == nil)
    }

    @Test("capture disabled remains behaviorally inert", .timeLimit(.minutes(1)))
    func captureDisabledExposesNoRecording() async throws {
        // Intent: the default controller path completes a normal session without
        //   retaining or exposing recording transitions.
        // Why it exists: capture is characterization-only product surface and must
        //   not change the default engine's lifetime or output behavior.
        // Scenario: a normal non-characterization pane prints a marker and exits.
        let host = try makeHost(captureTransitions: false)
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "printf '__CAPTURE_OFF__\\n'; exit")
        )
        let results = AsyncStream<PaneLifecycleResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var resultIterator = results.stream.makeAsyncIterator()
        controller.onSessionEnded = { results.continuation.yield($0) }

        #expect(await resultIterator.next() == .exited(.exited(0)))
        controller.synchronizeState()
        #expect(controller.readFullHistoryText().contains("__CAPTURE_OFF__"))
        #expect(controller.capturedRecording(test: "capture-disabled") == nil)

        controller.tearDown()
        await host.close()
    }

    @Test("teardown fences the cached terminal before ending consumption", .timeLimit(.minutes(1)))
    func teardownFencesCachedTerminal() async throws {
        // Intent: synchronous teardown preserves every terminal mutation already
        //   applied by the host even if the main-actor consume task is behind.
        // Why it exists: canceling the consumer before its final pull permanently
        //   drops dirty recovery text from the clean-exit checkpoint.
        // Scenario: a hidden pane prints its final checkpoint marker immediately
        //   before the user closes it.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "printf '__READY__\\n'"),
            isVisible: false
        )
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        controller.sendText("printf '__FINAL_CHECKPOINT__\\n'\n")
        #expect(await host.waitForOutput(containing: Array("__FINAL_CHECKPOINT__".utf8)))

        controller.tearDown()

        #expect(controller.readFullHistoryText().contains("__FINAL_CHECKPOINT__"))
        await host.close()
    }

    @Test("application termination reaches live and already-closing pane hosts", .timeLimit(.minutes(1)))
    func applicationTerminationHandlesLiveAndMidCloseHosts() async throws {
        // Intent: backend-owned termination handles cover every native host until
        //   teardown completes, including one whose ordinary close is in flight.
        // Why it exists: dropping a host from the backend registry at tearDown()
        //   would let app termination leave that pane's process ladder unfinished.
        // Scenario: the app quits while one shell is live and another pane has
        //   just begun closing; both must release their complete process sessions.
        let liveHost = try makeHost()
        let closingHost = try makeHost()
        let liveController = TerminalPaneSessionController(
            host: liveHost,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\"")
        )
        let closingController = TerminalPaneSessionController(
            host: closingHost,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\"")
        )
        let handles = [liveController.terminationHandle, closingController.terminationHandle]
        #expect(await liveHost.waitForOutput(containing: Array("__READY__".utf8)))
        #expect(await closingHost.waitForOutput(containing: Array("__READY__".utf8)))

        closingController.tearDown()
        await withTaskGroup(of: Void.self) { group in
            for handle in handles {
                group.addTask { await handle.terminateForApplicationExit() }
            }
        }

        #expect((await liveHost.resourceSnapshot()).isReleased)
        #expect((await closingHost.resourceSnapshot()).isReleased)
        liveController.tearDown()
    }

    @Test("teardown completion fires backend registry cleanup exactly once", .timeLimit(.minutes(1)))
    func teardownCompletionFiresOnce() async throws {
        // Intent: a pane teardown publishes one completion after native resources
        //   are released, even when tearDown() is called repeatedly.
        // Why it exists: early registry removal loses mid-close hosts, while repeat
        //   removal callbacks make backend ownership state race-prone.
        // Scenario: repeated reconciler cleanup calls close one live shell pane.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\"")
        )
        let completions = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var iterator = completions.stream.makeAsyncIterator()
        var completionCount = 0
        controller.onTeardownCompleted = {
            completionCount += 1
            completions.continuation.yield()
        }
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        controller.tearDown()
        controller.tearDown()
        _ = await iterator.next()

        #expect(completionCount == 1)
        #expect((await host.resourceSnapshot()).isReleased)
    }
}

private func makeHost(captureTransitions: Bool = true) throws -> TerminalPTYHost {
    try TerminalPTYHost(
        initialDimensions: .init(columns: 80, rows: 24),
        bootstrapExecutable: bootstrapExecutable(),
        captureTransitions: captureTransitions
    )
}

private func makeLaunchInput(command: String?) -> LaunchPolicyInput {
    LaunchPolicyInput(
        accountShell: "/bin/sh",
        executablePaths: ["/bin/sh"],
        requestedWorkingDirectory: "/",
        homeDirectory: "/",
        accessibleDirectories: ["/"],
        inheritedEnvironment: [.init(name: "PATH", value: "/usr/bin:/bin")],
        advertisedEnvironment: [.init(name: "TERM", value: "xterm-256color")],
        paneEnvironment: [],
        command: nil,
        launchCommand: command,
        restoreCommandBehavior: .execute,
        initialDimensions: .init(columns: 80, rows: 24)
    )
}

private func builtExecutable(named name: String) throws -> String {
    let packageDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let buildDirectory = packageDirectory.appending(path: ".build", directoryHint: .isDirectory)
    let candidates = try FileManager.default.subpathsOfDirectory(atPath: buildDirectory.path)
        .filter { $0.hasSuffix("/debug/\(name)") }
        .map { buildDirectory.appending(path: $0).path }
        .filter(FileManager.default.isExecutableFile(atPath:))
        .sorted()
    return try #require(candidates.first)
}

private func bootstrapExecutable() throws -> String {
    try builtExecutable(named: "PTYSessionBootstrap")
}

private func probeExecutable() throws -> String {
    try builtExecutable(named: "PTYProbe")
}

private extension RenderFramePlan {
    var projectedText: String {
        textRuns.flatMap(\.cells).flatMap(\.scalars).reduce(into: "") {
            $0.unicodeScalars.append($1)
        }
    }
}
