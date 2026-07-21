// Real-PTY session tests for planning, visibility, capture, exit, and teardown.
import Foundation
import PaneLifecycle
import TerminalCore
import TerminalCoreRecording
import TerminalRenderPlanning
import Testing
@testable import TerminalPTYHost
@testable import TerminalPaneSession

/// Exercises the headless pane controller through one real native PTY per scenario.
@MainActor
@Suite(.serialized)
struct TerminalPaneSessionControllerTests {
    @Test("controller forwards one link open and exposes synchronized hover", .timeLimit(.minutes(1)))
    func controllerLinkPlumbing() async throws {
        // Intent: prove the main-actor adapter exposes hover and forwards one approved open.
        // Why it exists: callback hops must respect teardown while cached snapshots stay current.
        // Scenario: a visible pane hovers, activates, exits the surface, and tears down.
        let host = try makeHost()
        let command = "printf '\\033]8;;https://a.co\\007https://a.co\\033]8;;\\007'; exec \(try probeExecutable()) hold \"$0\""
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: command)
        )
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        controller.synchronizeState()
        let screen = controller.terminalSnapshot().screenText
            .split(separator: "\n", omittingEmptySubsequences: false)
        let row = try #require(screen.lastIndex(where: { $0.contains("https://a.co") }))
        let target = try #require(screen[row].range(of: "https://a.co"))
        let column = screen[row].distance(from: screen[row].startIndex, to: target.lowerBound)
        let snapshot = controller.terminalSnapshot()
        _ = try #require(snapshot.activatableLink(at: .init(
            row: snapshot.scrollProjection.topRow + row,
            column: column + 2
        )))
        let opened = AsyncStream<TerminalHyperlink>.makeStream()
        var iterator = opened.stream.makeAsyncIterator()
        controller.onOpenLink = { opened.continuation.yield($0) }

        controller.sendPointer(.move(column: column + 2, row: row, modifiers: [.command]))
        controller.synchronizeState()
        #expect(try #require(controller.readHoveredLink()).uri == "https://a.co")
        controller.sendPointer(.down(
            .left, column: column + 2, row: row, modifiers: [.command]
        ))
        controller.sendPointer(.up(
            .left, column: column + 3, row: row, modifiers: [.command]
        ))
        #expect(await iterator.next()?.uri == "https://a.co")

        controller.cancelLinkInteraction()
        controller.synchronizeState()
        #expect(controller.readHoveredLink() == nil)
        controller.tearDown()
        #expect(controller.onOpenLink == nil)
        await host.close()
    }
    @Test("visible creation retains one full frame and repeat synchronization is idle")
    func visibleCreationRetainsInitialFrame() async throws {
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec sleep 30")
        )
        var frames: [TerminalPaneFrame] = []
        controller.onFrame = { frames.append($0) }

        #expect(controller.currentPlan != nil)
        #expect(controller.currentDamage == .full)
        controller.synchronizeState()
        controller.synchronizeState()
        #expect(frames.isEmpty)

        controller.tearDown()
        await host.close()
    }

    @Test("hidden creation defers one full frame until first reveal")
    func hiddenCreationDefersInitialFrame() async throws {
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec sleep 30"),
            isVisible: false
        )
        var frames: [TerminalPaneFrame] = []
        controller.onFrame = { frames.append($0) }

        #expect(controller.currentPlan == nil)
        controller.setVisible(true)
        controller.setVisible(true)

        #expect(frames.count == 1)
        #expect(frames.first?.damage == .full)
        controller.tearDown()
        await host.close()
    }

    @Test("clipboard delivery bypasses hidden rendering and precedes frame publication", .timeLimit(.minutes(1)))
    func clipboardDeliveryIsUngated() async throws {
        // Intent: every drained write reaches the session callback before any frame from that consume.
        // Why it exists: visibility and damage gates must not suppress grid-silent semantic effects.
        // Scenario: a hidden pane receives a remote OSC 52 write and synchronously fences it.
        let host = try makeHost()
        let command = "printf '__READY__'; read ignored; printf '\\033]52;c;aGVsbG8=\\007'; exec sleep 30"
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: command),
            isVisible: false
        )
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        var events: [String] = []
        controller.onClipboardWrite = { events.append("clipboard:\($0)") }
        controller.onFrame = { _ in events.append("frame") }

        controller.sendText("continue\n")
        #expect(await host.waitForOutput(containing: Array("\u{1B}]52;c;aGVsbG8=\u{7}".utf8)))
        controller.synchronizeState()
        var yields = 0
        while events.isEmpty, yields < 10_000 {
            yields += 1
            await Task.yield()
        }

        #expect(events == ["clipboard:hello"])
        controller.synchronizeState()
        #expect(events == ["clipboard:hello"])
        controller.tearDown()
        await host.close()
    }

    @Test("clipboard delivery bypasses synchronized-output frame suppression", .timeLimit(.minutes(1)))
    func clipboardDeliveryBypassesSynchronizedOutput() async throws {
        // Intent: DEC 2026 delays rendering without delaying a completed clipboard write.
        // Why it exists: both channels share one consume, but only presentation is gateable.
        // Scenario: a visible TUI writes OSC 52 inside a synchronized update, then commits it.
        let host = try makeHost()
        let command = "stty -echo; printf '\\137\\137READY\\137\\137'; read first; printf '\\033[?2026hSYNC\\033]52;c;aGVsbG8=\\007'; read second; printf '\\033[?2026l'; exec sleep 30"
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: command)
        )
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        controller.synchronizeState()
        var events: [String] = []
        controller.onClipboardWrite = { events.append("clipboard:\($0)") }
        controller.onFrame = { _ in events.append("frame") }

        controller.sendText("first\n")
        #expect(await host.waitForOutput(containing: Array("\u{1B}]52;c;aGVsbG8=\u{7}".utf8)))
        controller.synchronizeState()
        var yields = 0
        while events.isEmpty, yields < 10_000 {
            yields += 1
            await Task.yield()
        }
        #expect(events == ["clipboard:hello"])

        controller.sendText("second\n")
        #expect(await host.waitForOutput(containing: Array("\u{1B}[?2026l".utf8)))
        controller.synchronizeState()
        yields = 0
        while events.count < 2, yields < 10_000 {
            yields += 1
            await Task.yield()
        }
        #expect(events == ["clipboard:hello", "frame"])
        controller.tearDown()
        await host.close()
    }

    @Test("synchronized output unions suppressed damage into its published frame", .timeLimit(.minutes(1)))
    func synchronizedOutputAccumulatesDamage() async throws {
        // Intent: damage from every DEC 2026-suppressed state reaches the first
        //   frame published after synchronization ends.
        // Why it exists: draining on each owner read can otherwise discard damage
        //   before the pane session is permitted to publish a frame.
        // Scenario: a TUI renders two synchronized updates and then commits the batch.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) sync \"$0\"")
        )
        var frames: [TerminalPaneFrame] = []
        controller.onFrame = { frames.append($0) }
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        controller.synchronizeState()

        controller.sendText("first\n")
        #expect(await host.waitForOutput(containing: Array("__SYNC_A__".utf8)))
        controller.synchronizeState()
        controller.sendText("second\n")
        #expect(await host.waitForOutput(containing: Array("__SYNC_B__".utf8)))
        controller.synchronizeState()
        let countDuringSynchronization = frames.count

        controller.sendText("commit\n")
        #expect(await host.waitForOutput(containing: Array("__SYNC_DONE__".utf8)))
        controller.synchronizeState()

        #expect(frames.count == countDuringSynchronization + 1)
        #expect(frames.last?.damage != TerminalDamage.none)
        controller.tearDown()
        await host.close()
    }

    @Test("cursor visibility and synchronized updates gate complete frame planning", .timeLimit(.minutes(1)))
    func presentationProjectionAndSynchronizedGating() async throws {
        // Intent: the controller projects cursor visibility, suppresses intermediate
        //   synchronized frames, and plans the complete state once synchronization ends.
        // Why it exists: hardcoded cursor visibility and planning every 2026 update
        //   violate both terminal presentation semantics and the idle-work contract.
        // Scenario: a visible TUI hides its cursor, batches two updates, then commits them.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(
                command: "exec \(try probeExecutable()) sync \"$0\""
            )
        )
        var plans: [RenderFramePlan] = []
        controller.onFrame = { plans.append($0.plan) }
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        controller.synchronizeState()
        let baselinePlanCount = plans.count

        controller.sendText("first\n")
        #expect(await host.waitForOutput(containing: Array("__SYNC_A__".utf8)))
        controller.synchronizeState()
        #expect(host.fencedSnapshot().presentation.isSynchronizedOutputActive)
        let countDuringSynchronization = plans.count
        #expect(countDuringSynchronization == baselinePlanCount)
        #expect(controller.readViewportText().contains("__SYNC_A__"))
        #expect(controller.readFullHistoryText().contains("__SYNC_A__"))

        controller.sendText("second\n")
        #expect(await host.waitForOutput(containing: Array("__SYNC_B__".utf8)))
        controller.synchronizeState()
        #expect(host.fencedSnapshot().presentation.isSynchronizedOutputActive)
        #expect(plans.count == countDuringSynchronization)

        controller.sendText("commit\n")
        #expect(await host.waitForOutput(containing: Array("__SYNC_DONE__".utf8)))
        controller.synchronizeState()
        #expect(plans.count == countDuringSynchronization + 1)
        let finalTerminal = host.fencedSnapshot()
        let expectedPlan = planFrame(
            for: finalTerminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: finalTerminal.presentation.isCursorVisible,
                cursorShape: finalTerminal.presentation.cursorShape
            )
        )
        #expect(try #require(plans.last) == expectedPlan)

        controller.tearDown()
        await host.close()
    }

    @Test("child exit permanently releases synchronized planning for visible and hidden panes", .timeLimit(.minutes(1)))
    func childExitReleasesSynchronizedGating() async throws {
        // Intent: child exit exposes the terminal's final state even when the child
        //   leaves synchronized updates active, immediately or after a hidden reveal.
        // Why it exists: otherwise a crashed TUI can strand its last output forever.
        // Scenario: visible and background commands set 2026, print their last marker,
        //   and exit without resetting the mode.
        let visibleHost = try makeHost()
        let visible = TerminalPaneSessionController(
            host: visibleHost,
            launchInput: makeLaunchInput(
                command: "exec \(try probeExecutable()) sync-exit \"$0\""
            )
        )
        var visiblePlans: [RenderFramePlan] = []
        let visibleResults = AsyncStream<PaneLifecycleResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var visibleResultIterator = visibleResults.stream.makeAsyncIterator()
        visible.onFrame = { visiblePlans.append($0.plan) }
        visible.onSessionEnded = { visibleResults.continuation.yield($0) }
        #expect(await visibleHost.waitForResult() == .exited(.exited(0)))
        #expect(await visibleResultIterator.next() == .exited(.exited(0)))
        visible.synchronizeState()
        #expect(try #require(visiblePlans.last).projectedText.contains("__SYNC_FINAL__"))

        let hiddenHost = try makeHost()
        let hidden = TerminalPaneSessionController(
            host: hiddenHost,
            launchInput: makeLaunchInput(
                command: "exec \(try probeExecutable()) sync-exit \"$0\""
            ),
            isVisible: false
        )
        var hiddenPlans: [RenderFramePlan] = []
        let hiddenResults = AsyncStream<PaneLifecycleResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var hiddenResultIterator = hiddenResults.stream.makeAsyncIterator()
        hidden.onFrame = { hiddenPlans.append($0.plan) }
        hidden.onSessionEnded = { hiddenResults.continuation.yield($0) }
        #expect(await hiddenHost.waitForResult() == .exited(.exited(0)))
        #expect(await hiddenResultIterator.next() == .exited(.exited(0)))
        hidden.synchronizeState()
        #expect(hiddenPlans.isEmpty)
        #expect(hidden.readViewportText().contains("__SYNC_FINAL__"))

        hidden.setVisible(true)
        #expect(hiddenPlans.count == 1)
        #expect(try #require(hiddenPlans.first).projectedText.contains("__SYNC_FINAL__"))

        visible.tearDown()
        hidden.tearDown()
        await visibleHost.close()
        await hiddenHost.close()
    }

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
        controller.onFrame = { plans.append($0.plan) }
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
        controller.onFrame = { _ in planCount += 1 }
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
        // Intent: hidden panes keep inspection reads current without planning,
        //   reveal once, and preserve primary recovery text behind an alternate frame.
        // Why it exists: suspended consumption loses recovery text, hidden planning
        //   wastes power, and conflating full with primary history persists TUI output.
        // Scenario: a background tab receives output, is selected, then opens a
        //   full-screen terminal application.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "printf '__READY__\\n'"),
            isVisible: false
        )
        var plans: [RenderFramePlan] = []
        controller.onFrame = { plans.append($0.plan) }
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        controller.sendText("printf '__HIDDEN_OUTPUT__\\n'\n")
        #expect(await host.waitForOutput(containing: Array("__HIDDEN_OUTPUT__".utf8)))
        controller.synchronizeState()

        #expect(plans.isEmpty)
        let fullHistory = controller.readFullHistoryText()
        #expect(fullHistory.contains("__HIDDEN_OUTPUT__"))
        #expect(controller.readPrimaryHistoryText() == fullHistory)
        controller.setVisible(true)
        #expect(plans.count == 1)
        #expect(plans[0].projectedText.contains("__HIDDEN_OUTPUT__"))
        controller.setVisible(true)
        #expect(plans.count == 1)

        controller.sendText("printf '\\033[?1047h__ALT_%s__' FRAME\n")
        #expect(await host.waitForOutput(containing: Array("__ALT_FRAME__".utf8)))
        controller.synchronizeState()
        #expect(controller.readFullHistoryText().contains("__ALT_FRAME__"))
        #expect(controller.readPrimaryHistoryText().contains("__HIDDEN_OUTPUT__"))
        #expect(controller.readPrimaryHistoryText().contains("__ALT_FRAME__") == false)

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
        controller.onFrame = { plans.continuation.yield($0.plan) }
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

    @Test("viewport state emits on change only and pane reads use logical window text", .timeLimit(.minutes(1)))
    func viewportStateEmissionAndRead() async throws {
        // Intent: expose one deduplicated, AppKit-free viewport state alongside logical pane text.
        // Why it exists: commit-time scrollbar chrome must not poll or serialize padded grid rows.
        // Scenario: a pane scrolls through retained output, repeats the same target, then enters alt.
        let host = try makeHost()
        let command = "i=0; while [ $i -lt 40 ]; do printf 'line-%s\\n' \"$i\"; i=$((i+1)); done; printf '__OUTPUT_DONE__\\n'"
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: command)
        )
        while controller.readFullHistoryText().contains("line-39") == false {
            await Task.yield()
            controller.synchronizeState()
        }
        var states: [TerminalPaneViewportState] = []
        var plans: [RenderFramePlan] = []
        controller.onViewportStateChange = { states.append($0) }
        controller.onFrame = { plans.append($0.plan) }

        controller.scroll(byRows: -3)
        controller.synchronizeState()
        let scrolled = controller.viewportState
        let emissionCount = states.count
        let planCount = plans.count
        controller.scroll(toTopRow: scrolled.projection.topRow)
        controller.synchronizeState()

        #expect(scrolled.isScrollbarEnabled)
        #expect(scrolled.projection.isFollowing == false)
        #expect(emissionCount == 1)
        #expect(states.count == emissionCount)
        #expect(planCount == 1)
        #expect(plans.count == planCount)
        #expect(controller.readViewportText() == host.fencedSnapshot().viewportText)
        #expect(controller.readViewportText() != host.fencedSnapshot().screenText)

        controller.sendText("printf '\\033[?1049h__ALT_STATE__'\n")
        while host.fencedSnapshot().isAlternateScreenActive == false {
            await Task.yield()
        }
        controller.synchronizeState()
        #expect(controller.viewportState.isScrollbarEnabled == false)
        #expect(states.last?.isScrollbarEnabled == false)

        controller.tearDown()
        await host.close()
    }

    @Test("text key and encoded input each snap browsing to live output", .timeLimit(.minutes(1)))
    func everyUserInputPathSnapsViewport() async throws {
        let host = try makeHost(captureTransitions: false)
        let command = "i=0; while [ $i -lt 40 ]; do printf 'line-%s\\n' \"$i\"; i=$((i+1)); done; stty -echo; exec \(try probeExecutable()) hold \"$0\""
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: command)
        )
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        controller.scroll(byRows: -2)
        controller.synchronizeState()
        controller.sendText("text")
        #expect(host.fencedSnapshot().scrollProjection.isFollowing)

        controller.scroll(byRows: -2)
        controller.synchronizeState()
        controller.sendKey(.up, modifiers: [])
        #expect(host.fencedSnapshot().scrollProjection.isFollowing)

        controller.scroll(byRows: -2)
        controller.synchronizeState()
        controller.send([0x78])
        #expect(host.fencedSnapshot().scrollProjection.isFollowing)

        controller.tearDown()
        await host.close()
    }

    @Test("session wheel forwards semantic rows for alternate fallback", .timeLimit(.minutes(1)))
    func sessionWheelForwardsSemanticRows() async throws {
        let host = try makeHost()
        let command = "printf '\\033[?1049h'; exec \(try probeExecutable()) hold \"$0\""
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: command)
        )
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let baseline = await host.inputWrites().count

        controller.sendWheel(.init(rowDelta: -2, column: 0, row: 0))
        _ = host.fencedSnapshot()

        let up = [UInt8]([0x1B, 0x5B, 0x41])
        #expect(Array((await host.inputWrites()).dropFirst(baseline)) == [up + up])

        controller.tearDown()
        await host.close()
    }

    @Test("fenced selection reads observe earlier controller pointer input", .timeLimit(.minutes(1)))
    func fencedSelectionReadObservesPointerInput() async throws {
        let host = try makeHost()
        let command = "printf 'alpha beta'; exec \(try probeExecutable()) hold \"$0\""
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: command)
        )
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        controller.synchronizeState()
        let lines = controller.readViewportText()
            .split(separator: "\n", omittingEmptySubsequences: false)
        let row = try #require(lines.firstIndex(where: { $0.contains("alpha beta") }))
        let beta = try #require(lines[row].range(of: "beta"))
        let column = lines[row].distance(from: lines[row].startIndex, to: beta.lowerBound)

        controller.sendPointer(.down(.left, column: column, row: row, clickCount: 2))
        controller.sendPointer(.up(.left, column: column, row: row))

        #expect(controller.readSelectedTextSynchronizing() == "beta")
        #expect(controller.hasSelection)
        #expect(controller.readSelectedText() == "beta")

        controller.clearSelection()
        controller.synchronizeState()
        #expect(controller.hasSelection == false)
        controller.tearDown()
        await host.close()
    }

    @Test("captured controller navigation and semantic input replay exactly", .timeLimit(.minutes(1)))
    func controllerNavigationCaptureEquality() async throws {
        // Intent: preserve owner-ordered viewport and normalized input events through capture.
        // Why it exists: input snaps and semantic events cannot be reconstructed from child output.
        // Scenario: a pane scrolls away, receives key/paste/focus input, then exits normally.
        let command = "i=0; while [ $i -lt 40 ]; do printf 'line-%s\\n' \"$i\"; i=$((i+1)); done; printf '\\033[?1000;1006h'; read ignored; exit"
        let controller = try TerminalPaneSessionController(
            configuration: .init(
                initialDimensions: .init(columns: 80, rows: 24),
                launchInput: makeLaunchInput(command: command)
            ),
            bootstrapExecutable: bootstrapExecutable(),
            captureTransitions: true
        )
        let results = AsyncStream<PaneLifecycleResult>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var iterator = results.stream.makeAsyncIterator()
        controller.onSessionEnded = { results.continuation.yield($0) }
        controller.synchronizeState()
        while controller.readFullHistoryText().contains("line-39") == false {
            await Task.yield()
            controller.synchronizeState()
        }
        let lines = controller.readViewportText()
            .split(separator: "\n", omittingEmptySubsequences: false)
        let selectionRow = try #require(lines.firstIndex(where: { $0.contains("line-39") }))

        controller.scroll(byRows: -5)
        controller.synchronizeState()
        controller.sendPointer(.down(
            .left,
            column: 0,
            row: selectionRow,
            modifiers: [.shift]
        ))
        controller.sendPointer(.move(column: 3, row: selectionRow, modifiers: [.shift]))
        controller.sendPointer(.up(.left, column: 3, row: selectionRow, modifiers: [.shift]))
        controller.sendPointer(.down(
            .left,
            column: 1,
            row: selectionRow,
            modifiers: [.shift],
            clickCount: 2
        ))
        controller.sendPointer(.up(.left, column: 1, row: selectionRow, modifiers: [.shift]))
        controller.sendPointer(.down(
            .left,
            column: 1,
            row: selectionRow,
            modifiers: [.shift],
            clickCount: 3
        ))
        controller.sendPointer(.up(.left, column: 1, row: selectionRow, modifiers: [.shift]))
        controller.sendKey(.f5, modifiers: [.shift])
        controller.sendPaste("paste")
        controller.sendFocus(true)
        controller.sendText("continue\n")
        #expect(await iterator.next() == .exited(.exited(0)))
        controller.synchronizeState()

        let recording = try #require(controller.capturedRecording(test: "viewport-controller"))
        #expect(recording.events.contains(.viewport(.byRows(-5))))
        #expect(recording.events.contains(.viewport(.toBottom)))
        #expect(recording.events.contains(.input(key: .f5, modifiers: [.shift])))
        #expect(recording.events.contains(.paste("paste")))
        #expect(recording.events.contains(.focus(true)))
        let mouseEvents = recording.events.compactMap { event -> NeutralTerminalMouseEvent? in
            guard case .mouse(let mouse) = event else { return nil }
            return mouse
        }
        let shiftDownClickCounts = mouseEvents.filter {
            $0.action == .down && $0.modifiers == [.shift]
        }.map(\.clickCount)
        #expect(shiftDownClickCounts.contains(1))
        #expect(shiftDownClickCounts.contains(2))
        #expect(shiftDownClickCounts.contains(3))
        var replayed = try recording.replay()
        _ = replayed.drainDamage()
        var consumed = controller.terminalSnapshot()
        _ = consumed.drainDamage()
        #expect(replayed == consumed)

        controller.tearDown()
        await controller.terminationHandle.terminateForApplicationExit()
    }

    @Test("wheel-rate navigation and sustained output converge without retaining owners", .timeLimit(.minutes(1)))
    func navigationOutputStressConverges() async throws {
        // Intent: interleave owner submissions, snapshot copies, and replanning at wheel-like rates.
        // Why it exists: this path previously exposed a copy-time crash and teardown retention.
        // Scenario: a streaming command runs while the user rapidly moves through its viewport.
        weak var releasedController: TerminalPaneSessionController?
        weak var releasedHost: TerminalPTYHost?
        do {
            let host = try makeHost(captureTransitions: false)
            releasedHost = host
            let controller = TerminalPaneSessionController(
                host: host,
                launchInput: makeLaunchInput(command: "printf '__READY__\\n'")
            )
            releasedController = controller
            #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

            controller.sendText("i=0; while [ $i -lt 200 ]; do printf 'stress-%s\\n' \"$i\"; i=$((i+1)); done; printf '__STRESS_DONE__\\n'; exit\n")
            for index in 0..<300 {
                controller.scroll(byRows: index.isMultiple(of: 2) ? -1 : 1)
            }
            #expect(await host.waitForResult() == .exited(.exited(0)))
            controller.synchronizeState()
            #expect(try #require(controller.currentPlan).projectedText.contains("__STRESS_DONE__"))

            controller.tearDown()
            await host.close()
            #expect((await host.resourceSnapshot()).isReleased)
        }
        #expect(releasedController == nil)
        #expect(releasedHost == nil)
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
