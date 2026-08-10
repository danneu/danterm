// Real-PTY session tests for planning, visibility, capture, exit, and teardown.
import Foundation
import PaneLifecycle
@testable import TerminalCore
import TerminalCoreRecording
import TerminalRenderPlanning
import Testing
@testable import TerminalPTYHost
import TerminalPTYTestSupport
@testable import TerminalPaneSession

/// Exercises the headless pane controller through one real native PTY per scenario.
@MainActor
@Suite(.serialized)
struct TerminalPaneSessionControllerTests {
    @Test("every controller fence is timed, attributed, and matched by the host")
    func everyControllerFenceIsAccounted() async throws {
        // Intent: initialization, delivery, checkpoint, diagnostic, and teardown
        //   fences each advance their attributed controller counter and the same
        //   host production-entry counter.
        // Why it exists: a new or bypassing fence otherwise silently escapes the
        //   benchmark bracket while the existing delivery-only metric stays plausible.
        // Scenario: one pane starts, consumes output, checkpoints, captures diagnostics,
        //   and tears down; its accounting remains internally complete afterward.
        var now: UInt64 = 0
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec sleep 30"),
            fenceClock: {
                defer { now += 10 }
                return now
            }
        )

        host.deliverOutputForTesting(Array("delivery".utf8))
        controller.consumePendingHostUpdateForTesting()
        controller.synchronizeState()
        _ = controller.diagnosticCapture(test: "fence-accounting")
        controller.tearDown()

        let metrics = controller.fenceMetrics
        #expect(metrics.initialization == .init(waitNanoseconds: 20, count: 2))
        #expect(metrics.delivery == .init(waitNanoseconds: 10, count: 1))
        #expect(metrics.checkpoint == .init(waitNanoseconds: 10, count: 1))
        #expect(metrics.diagnostic == .init(waitNanoseconds: 10, count: 1))
        #expect(metrics.teardown == .init(waitNanoseconds: 10, count: 1))
        #expect(metrics.total == .init(waitNanoseconds: 60, count: 6))
        #expect(metrics.hostEntryCount == metrics.total.count)
        await host.close()
    }

    @Test("package-test fences do not advance the host production count")
    func packageTestFencesDoNotPolluteProductionCount() throws {
        let host = try makeHost()

        _ = host.fencedSnapshot()
        _ = host.fencedFrameState()
        _ = host.fencedConsumptionState()
        _ = host.fencedDiagnosticState()
        _ = host.setTestUpdateHandler { _ in }
        _ = host.observeTestOutput { _ in false }
        host.deliverOutputForTesting(Array("test".utf8))

        #expect(host.productionFenceEntryCountForTesting() == 0)
    }

    @Test("suppressed delivery stalls flush once at the next accepted publish")
    func suppressedDeliveryFenceStallsCarryForward() async throws {
        // Intent: delivery stalls accumulated while DEC 2026 suppresses planning
        //   are charged exactly once when the synchronized update is accepted.
        // Why it exists: drain-time latching dropped suppressed stalls, while retaining
        //   the last latch allowed a later non-draining publish to charge one twice.
        // Scenario: a TUI starts a synchronized frame, updates it, then commits it.
        var now: UInt64 = 0
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec sleep 30"),
            fenceClock: {
                defer { now += 10 }
                return now
            }
        )

        host.deliverOutputForTesting(Array("\u{1B}[?2026hfirst".utf8))
        controller.consumePendingHostUpdateForTesting()
        #expect(controller.lastFenceStallNanoseconds == 0)
        #expect(controller.unflushedDeliveryFenceWaitNanoseconds == 10)

        host.deliverOutputForTesting(Array("second\u{1B}[?2026l".utf8))
        controller.consumePendingHostUpdateForTesting()
        #expect(controller.lastFenceStallNanoseconds == 20)
        #expect(controller.unflushedDeliveryFenceWaitNanoseconds == 0)

        controller.setVisible(false)
        host.deliverOutputForTesting(Array("checkpoint".utf8))
        controller.synchronizeState()
        controller.setVisible(true)
        #expect(controller.lastFenceStallNanoseconds == 0)

        controller.tearDown()
        await host.close()
    }

    @Test("delivery totals equal flushed stalls plus the pending remainder")
    func deliveryTotalsReconcileWithFlushPipeline() async throws {
        // Intent: cumulative delivery accounting equals every accepted frame's
        //   flushed stall plus the still-suppressed remainder.
        // Why it exists: the cumulative and frame-flush paths share one clock pair,
        //   and this equality catches either path charging or dropping a fence alone.
        // Scenario: a TUI suppresses two deliveries, commits them, publishes another
        //   frame, then begins a second synchronized frame that remains pending.
        var now: UInt64 = 0
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec sleep 30"),
            fenceClock: {
                defer { now += 10 }
                return now
            }
        )
        var flushedWaitNanoseconds: UInt64 = 0

        host.deliverOutputForTesting(Array("\u{1B}[?2026hfirst".utf8))
        controller.consumePendingHostUpdateForTesting()
        host.deliverOutputForTesting(Array("second\u{1B}[?2026l".utf8))
        controller.consumePendingHostUpdateForTesting()
        flushedWaitNanoseconds += controller.lastFenceStallNanoseconds
        host.deliverOutputForTesting(Array("accepted".utf8))
        controller.consumePendingHostUpdateForTesting()
        flushedWaitNanoseconds += controller.lastFenceStallNanoseconds
        host.deliverOutputForTesting(Array("\u{1B}[?2026hpending".utf8))
        controller.consumePendingHostUpdateForTesting()

        #expect(flushedWaitNanoseconds == 30)
        #expect(controller.unflushedDeliveryFenceWaitNanoseconds == 10)
        #expect(
            controller.fenceMetrics.delivery.waitNanoseconds
                == flushedWaitNanoseconds
                    + controller.unflushedDeliveryFenceWaitNanoseconds
        )

        controller.tearDown()
        await host.close()
    }

    @Test(
        "zsh, bash, and fish integrations deliver typed events through a real PTY",
        .timeLimit(.minutes(1))
    )
    func shellIntegrationsDeliverTypedEvents() async throws {
        let integrationDirectory = shellIntegrationDirectory()
        let command = "printf 'hola 世界; $HOME'"
        let shells = try ["zsh", "bash", "fish"].map { try findExecutable(named: $0) }

        for shell in shells {
            let asset = integrationDirectory.appending(
                path: "danterm.\(URL(fileURLWithPath: shell).lastPathComponent)"
            ).path
            let invocation: String
            if shell.hasSuffix("/fish") {
                invocation = "DANTERM=1 "
                    + "\(shellQuote(shell)) --no-config -c "
                    + shellQuote("source \(asset); "
                        + "danterm_emit_command_start \(shellQuote(command)); "
                        + "danterm_emit_command_end; exit")
            } else {
                invocation = "DANTERM=1 "
                    + "\(shellQuote(shell)) -f -c "
                    + shellQuote("source \(shellQuote(asset)); "
                        + "danterm_emit_command_start \(shellQuote(command)); "
                        + "danterm_emit_command_end; exit")
            }
            let host = try makeHost()
            let controller = TerminalPaneSessionController(
                host: host,
                launchInput: makeLaunchInput(command: invocation + "; exit")
            )
            var received: [TerminalSemanticEvent] = []
            controller.onSemanticEvents = { events in
                received.append(contentsOf: events)
            }

            #expect(await host.waitForResult() == .exited(.exited(0)))
            controller.synchronizeState()
            #expect(received.contains(.commandStarted(command)))
            #expect(received.contains(.commandEnded))

            controller.tearDown()
            await host.close()
        }
    }

    @Test("semantic events bypass hidden and synchronized rendering gates", .timeLimit(.minutes(1)))
    func semanticEventsBypassRenderingGates() async throws {
        // Intent: deliver every semantic kind while both rendering gates suppress frames.
        // Why it exists: terminal metadata must not wait for pane visibility or synchronized output.
        // Scenario: a hidden child starts a synchronized update, then reports title, cwd, shell, and BEL.
        let host = try makeHost()
        let command = "printf '\\033[?2026h\\033]2;hidden-title\\007"
            + "\\033]7;file://localhost/tmp/pane\\007"
            + "\\033]1337;DanTermShell=1;command-end\\007\\007'; exec sleep 30"
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: command),
            isVisible: false
        )
        let batches = AsyncStream<[TerminalSemanticEvent]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var iterator = batches.stream.makeAsyncIterator()
        controller.onSemanticEvents = { batches.continuation.yield($0) }

        #expect(await iterator.next() == [
            .title("hidden-title"),
            .workingDirectory("/tmp/pane"),
            .commandEnded,
            .bell,
        ])
        #expect(controller.currentPlan == nil)

        controller.tearDown()
        await host.close()
    }

    @Test("a default-constructed pane accepts an OSC 7 report naming this machine", .timeLimit(.minutes(1)))
    func defaultPaneAcceptsThisMachinesCwdReport() async throws {
        // Intent: with nobody passing a hostname -- exactly how the app constructs a pane --
        //   a cwd report carrying this machine's real name is accepted.
        // Why it exists: the app used to supply its own ambient hostname, and the harness
        //   injected a hand-matched one, so no test ever exercised the default. Every
        //   production pane's cwd came back nil.
        // Scenario: the shell emits `OSC 7;file://<hostname>/tmp/pane`, as fish/zsh/bash do
        //   on every directory change.
        let hostname = try #require(MachineHostname.posix)
        let host = try makeHost()
        let command = "printf '\\033]7;file://\(hostname)/tmp/pane\\007'; exec sleep 30"
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: command)
        )
        let batches = AsyncStream<[TerminalSemanticEvent]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var iterator = batches.stream.makeAsyncIterator()
        controller.onSemanticEvents = { batches.continuation.yield($0) }

        #expect(await iterator.next() == [.workingDirectory("/tmp/pane")])

        controller.tearDown()
        await host.close()
    }

    @Test("natural exit delivers semantic events before session end", .timeLimit(.minutes(1)))
    func naturalExitOrdersSemanticEventsBeforeEnd() async throws {
        // Intent: publish output semantics before the same drain reports the child exit.
        // Why it exists: closing the pane first would discard the child's final metadata callback.
        // Scenario: a short-lived child writes its final title and exits immediately.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "printf '\\033]2;final-title\\007'; exit")
        )
        let callbacks = AsyncStream<String>.makeStream()
        var iterator = callbacks.stream.makeAsyncIterator()
        controller.onSemanticEvents = { events in
            if events == [.title("final-title")] { callbacks.continuation.yield("semantic") }
        }
        controller.onSessionEnded = { _ in callbacks.continuation.yield("ended") }

        #expect(await iterator.next() == "semantic")
        #expect(await iterator.next() == "ended")

        controller.tearDown()
        await host.close()
    }

    @Test("explicit teardown discards pending semantic callbacks", .timeLimit(.minutes(1)))
    func teardownDiscardsSemanticCallbacks() async throws {
        // Intent: make explicit teardown synchronously close the semantic callback boundary.
        // Why it exists: queued owner work must not message a removed pane or shorter-lived view.
        // Scenario: the user closes a live pane before stale terminal input reaches its owner.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec sleep 30")
        )
        var events: [TerminalSemanticEvent] = []
        controller.onSemanticEvents = { events.append(contentsOf: $0) }

        controller.tearDown()
        host.send(Array("printf '\\033]2;too-late\\007'\n".utf8))
        await host.close()

        #expect(events.isEmpty)
        #expect(controller.onSemanticEvents == nil)
    }

    @Test("semantic callbacks remain isolated between pane controllers", .timeLimit(.minutes(1)))
    func semanticCallbacksRemainPaneIsolated() async throws {
        // Intent: each controller delivers only the semantics parsed by its own PTY owner.
        // Why it exists: pane identity belongs to the adapter and cannot come from child output.
        // Scenario: two panes concurrently publish distinct notifications and progress.
        let firstHost = try makeHost()
        let secondHost = try makeHost()
        let first = TerminalPaneSessionController(
            host: firstHost,
            launchInput: makeLaunchInput(
                command: "printf '\\033]777;notify;First;done\\007\\033]9;4;1;25\\007'; exec sleep 30"
            )
        )
        let second = TerminalPaneSessionController(
            host: secondHost,
            launchInput: makeLaunchInput(
                command: "printf '\\033]9;second\\007\\033]9;4;4;75\\007'; exec sleep 30"
            )
        )
        let firstEvents = AsyncStream<[TerminalSemanticEvent]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let secondEvents = AsyncStream<[TerminalSemanticEvent]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var firstIterator = firstEvents.stream.makeAsyncIterator()
        var secondIterator = secondEvents.stream.makeAsyncIterator()
        first.onSemanticEvents = { firstEvents.continuation.yield($0) }
        second.onSemanticEvents = { secondEvents.continuation.yield($0) }

        #expect(await firstIterator.next() == [
            .desktopNotification(title: "First", body: "done"),
            .progress(.set(percent: 25)),
        ])
        #expect(await secondIterator.next() == [
            .desktopNotification(title: "", body: "second"),
            .progress(.pause(percent: 75)),
        ])

        first.tearDown()
        second.tearDown()
        await firstHost.close()
        await secondHost.close()
    }

    @Test("recovery mutation signal follows primary content after alternate screen", .timeLimit(.minutes(1)))
    func recoveryMutationClassification() async throws {
        // Intent: signal primary mutations without treating transient alternate content as history.
        // Why it exists: recovery reads primary history only after this payload-free signal fires.
        // Scenario: a child changes cursor/presentation, visits alternate, then prints primary text.
        let host = try makeHost()
        // `A%sT` and `printMarker` keep every awaited marker out of the command text. The line
        // is echoed to the tty before the `stty -echo` in it can run, so a literal `ALT` here
        // satisfies the wait below at startup -- before the child has visited the alternate
        // screen at all. That left the alternate-then-primary ordering this test is about up to
        // scheduling, and let the `__PRIMARY__` assertion pass off the echo rather than off the
        // child's output.
        let command = "stty -echo; \(printMarker("READY", newline: false)); read ignored; "
            + "printf '\\033[2;2H\\033[?25l\\033[?1049hA%sT\\033[?1049l' L; "
            + "read ignored; \(printMarker("PRIMARY", newline: false)); exec sleep 30"
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: command)
        )
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        controller.synchronizeState()
        let baselineAltMentions = controller.readPrimaryHistoryText()
            .components(separatedBy: "ALT")
            .count
        var mutationCount = 0
        controller.onPrimaryHistoryMutation = { mutationCount += 1 }

        controller.sendText("continue\n")
        #expect(await host.waitForOutput(containing: Array("ALT".utf8)))
        controller.synchronizeState()
        let countAfterAlternate = mutationCount
        #expect(
            controller.readPrimaryHistoryText().components(separatedBy: "ALT").count
                == baselineAltMentions
        )

        controller.sendText("continue\n")
        #expect(await host.waitForOutput(containing: Array("__PRIMARY__".utf8)))
        controller.synchronizeState()
        #expect(mutationCount > countAfterAlternate)
        #expect(controller.readPrimaryHistoryText().contains("__PRIMARY__"))

        controller.tearDown()
        await host.close()
    }

    @Test("application-exit fence drains accepted output before final recovery read", .timeLimit(.minutes(1)))
    func applicationExitFenceDrainsAcceptedOutput() async throws {
        // Intent: make the final cached recovery projection the owner-fenced terminal state.
        // Why it exists: a quit racing already-accepted PTY output must not checkpoint stale text.
        // Scenario: output reaches the native owner immediately before orderly app termination.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "stty -echo; \(printMarker("READY"))")
        )
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        controller.sendText("printf '__QUIT_RACE__'\n")
        #expect(await host.waitForOutput(containing: Array("__QUIT_RACE__".utf8)))
        controller.fenceForApplicationExit()
        let finalHistory = controller.readPrimaryHistoryText()

        #expect(finalHistory.contains("__QUIT_RACE__"))
        controller.sendText("printf '__TOO_LATE__'\n")
        controller.synchronizeState()
        #expect(controller.readPrimaryHistoryText() == finalHistory)
        await host.close()
    }

    @Test("application-exit fence suppresses every queued main delivery")
    func applicationExitFenceSuppressesQueuedDeliveries() async throws {
        // Intent: one synchronous fence makes queued frame, pane-menu, link, and search
        //   callbacks inert before host shutdown begins.
        // Why it exists: separately owned Task relays can resume after the recovery
        //   snapshot and touch AppKit state while application termination blocks main.
        // Scenario: output, two pointer gestures, and a search all reach the host while
        //   main is busy handling Cmd-Q; none may cross the ensuing exit fence.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\"")
        )
        var frameCount = 0
        var paneMenuCount = 0
        var linkCount = 0
        var searchCount = 0
        var selectionCopyCount = 0
        controller.onFrame = { _ in frameCount += 1 }
        controller.onPaneMenu = { _ in paneMenuCount += 1 }
        controller.onOpenLink = { _ in linkCount += 1 }
        controller.onSearchStatus = { _ in searchCount += 1 }
        controller.onSelectionCopy = { _ in selectionCopyCount += 1 }
        #expect(host.waitForOutputSynchronously(
            containing: Array("__READY__".utf8),
            timeout: .seconds(10)
        ))

        host.deliverOutputForTesting(
            Array("\u{1B}]8;;https://a.co\u{7}link\u{1B}]8;;\u{7}".utf8)
        )
        let snapshot = host.fencedSnapshot()
        let lines = snapshot.viewportText.split(separator: "\n", omittingEmptySubsequences: false)
        let viewportRow = try #require(lines.firstIndex(where: { $0.contains("link") }))
        let linkRange = try #require(lines[viewportRow].range(of: "link"))
        let column = lines[viewportRow].distance(
            from: lines[viewportRow].startIndex,
            to: linkRange.lowerBound
        )
        controller.sendPointer(.down(.right, column: 0, row: 0))
        controller.sendPointer(.up(.right, column: 0, row: 0))
        controller.sendPointer(.down(
            .left, column: column, row: viewportRow, modifiers: [.command]
        ))
        controller.sendPointer(.up(
            .left, column: column, row: viewportRow, modifiers: [.command]
        ))
        controller.sendPointer(.down(.left, column: column, row: viewportRow, clickCount: 2))
        controller.sendPointer(.up(.left, column: column, row: viewportRow))
        controller.beginSearch("link")
        _ = host.fencedSnapshot()

        controller.fenceForApplicationExit()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(frameCount == 0)
        #expect(paneMenuCount == 0)
        #expect(linkCount == 0)
        #expect(searchCount == 0)
        #expect(selectionCopyCount == 0)
        await host.close()
    }

    @Test("a completed selection relays the text captured with its release", .timeLimit(.minutes(1)))
    func selectionCompletionRelaysTextCapturedAtRelease() async throws {
        // Intent: the subscriber receives the selection's text exactly as it stood when the
        //   release was applied on the owner, exactly once, no matter what the child writes
        //   before or after that moment.
        // Why it exists: reading the selection on the main actor after the hop would race
        //   output. Capturing on the owner in the same step as the selection mutation is
        //   what makes the delivered string independent of every later write.
        // Scenario: a word is double-clicked while the pane repaints that same row twice --
        //   once before the release is applied, and again before main drains the delivery.
        //   Select All follows, which selects but is not a pointer gesture.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\"")
        )
        #expect(host.waitForOutputSynchronously(
            containing: Array("__READY__".utf8),
            timeout: .seconds(10)
        ))
        var copied: [String] = []
        controller.onSelectionCopy = { copied.append($0) }

        host.deliverOutputForTesting(Array("\u{1B}[2J\u{1B}[Halpha beta".utf8))
        let lines = host.fencedSnapshot().viewportText
            .split(separator: "\n", omittingEmptySubsequences: false)
        let row = try #require(lines.firstIndex(where: { $0.contains("alpha beta") }))
        let beta = try #require(lines[row].range(of: "beta"))
        let column = lines[row].distance(from: lines[row].startIndex, to: beta.lowerBound)

        controller.sendPointer(.down(.left, column: column, row: row, clickCount: 2))
        // Overwrites the selected columns before the release is applied, so the text the
        // owner captures is "gamm" -- what the highlight covers at completion, not "beta".
        host.deliverOutputForTesting(Array("\u{1B}[Halpha gamma".utf8))
        controller.sendPointer(.up(.left, column: column, row: row))
        // Applied after the release, so it can only corrupt a main-actor re-read.
        host.deliverOutputForTesting(Array("\u{1B}[Halpha delta".utf8))
        await drainMainQueue()

        #expect(copied == ["gamm"])

        controller.sendPointer(.down(
            .left,
            column: column + 1,
            row: row,
            modifiers: [.shift]
        ))
        controller.sendPointer(.move(column: 0, row: row, modifiers: [.shift]))
        controller.sendPointer(.up(.left, column: 0, row: row, modifiers: [.shift]))
        controller.synchronizeState()
        await drainMainQueue()
        #expect(copied == ["gamm"], "an inside-selection gesture does not complete")

        controller.sendPointer(.down(
            .left,
            column: 2,
            row: row,
            offsetX: 0.75,
            modifiers: [.shift],
            clickCount: 3
        ))
        controller.sendPointer(.up(.left, column: 2, row: row, modifiers: [.shift]))
        controller.synchronizeState()
        await drainMainQueue()
        #expect(copied == ["gamm", "alpha delt"])

        controller.selectAll()
        controller.synchronizeState()
        await drainMainQueue()
        #expect(controller.readSelectedText()?.isEmpty == false, "Select All did select")
        #expect(
            copied == ["gamm", "alpha delt"],
            "Select All is not a pointer gesture and never copies"
        )

        controller.tearDown()
        await host.close()
    }

    @Test("a selection-owned release delivers nothing without a subscriber", .timeLimit(.minutes(1)))
    func selectionCompletionRequiresASubscriber() async throws {
        // Intent: with no subscriber installed, a selection-owned release produces no
        //   completion at all -- installing one afterwards receives nothing.
        // Why it exists: subscriber presence is the copy-on-select gate, and it has to sit
        //   upstream of extraction: capturing the text walks the retained projection on the
        //   PTY host queue, which the option being off must not pay for.
        // Scenario: a word is double-clicked with copy-on-select off, then a subscriber
        //   arrives and the pane is fenced.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\"")
        )
        #expect(host.waitForOutputSynchronously(
            containing: Array("__READY__".utf8),
            timeout: .seconds(10)
        ))

        host.deliverOutputForTesting(Array("\u{1B}[2J\u{1B}[Halpha beta".utf8))
        let lines = host.fencedSnapshot().viewportText
            .split(separator: "\n", omittingEmptySubsequences: false)
        let row = try #require(lines.firstIndex(where: { $0.contains("alpha beta") }))
        let beta = try #require(lines[row].range(of: "beta"))
        let column = lines[row].distance(from: lines[row].startIndex, to: beta.lowerBound)

        controller.sendPointer(.down(.left, column: column, row: row, clickCount: 2))
        controller.sendPointer(.up(.left, column: column, row: row))

        var copied: [String] = []
        controller.onSelectionCopy = { copied.append($0) }
        controller.synchronizeState()
        await drainMainQueue()

        #expect(controller.readSelectedText() == "beta", "the selection itself still exists")
        #expect(copied.isEmpty)
        controller.tearDown()
        await host.close()
    }

    @Test("an absent or empty selection relays nothing", .timeLimit(.minutes(1)))
    func selectionCompletionSkipsEmptyText() async throws {
        // Intent: a release that leaves no selection, and one whose selection covers only
        //   blank cells, both relay nothing.
        // Why it exists: the subscriber writes the clipboard, and a bare click on empty
        //   space must not wipe what the user copied earlier. Emptiness is judged where the
        //   text is captured because it is a property of the extracted string: a present
        //   selection over padding is non-nil and empty.
        // Scenario: a bare click on text, then a double-click on the blank area past it.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\"")
        )
        #expect(host.waitForOutputSynchronously(
            containing: Array("__READY__".utf8),
            timeout: .seconds(10)
        ))
        var copied: [String] = []
        controller.onSelectionCopy = { copied.append($0) }

        host.deliverOutputForTesting(Array("\u{1B}[2J\u{1B}[Halpha beta".utf8))
        let lines = host.fencedSnapshot().viewportText
            .split(separator: "\n", omittingEmptySubsequences: false)
        let row = try #require(lines.firstIndex(where: { $0.contains("alpha beta") }))

        controller.sendPointer(.down(.left, column: 0, row: row))
        controller.sendPointer(.up(.left, column: 0, row: row))
        controller.synchronizeState()
        #expect(controller.readSelectedText() == nil, "a bare click leaves no selection")

        let blankRow = row + 1
        controller.sendPointer(.down(.left, column: 0, row: blankRow, clickCount: 3))
        controller.sendPointer(.up(.left, column: 0, row: blankRow))
        controller.synchronizeState()
        #expect(controller.readSelectedText() == "", "a padding selection is present and empty")

        await drainMainQueue()
        #expect(copied.isEmpty)
        controller.tearDown()
        await host.close()
    }

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
        // Intent: a visible pane holds a full-damage plan from construction, and fencing
        //   again once the pane's output is consumed publishes nothing further.
        // Why it exists: the construction-time frame is what lets a pane draw before its
        //   child writes anything, and the idle half is what stops every recovery
        //   checkpoint from costing a redraw.
        // Scenario: a pane launches a silent long-running command and the app fences twice.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec sleep 30")
        )
        var frames: [TerminalPaneFrame] = []
        controller.onFrame = { frames.append($0) }

        #expect(controller.currentPlan != nil)
        #expect(controller.currentDamage == .full)

        // `sleep 30` writes nothing, but the tty echoes the launch command line back, so the
        // pane is never output-free and "no frame at all" just races that echo -- including
        // the echoed newline, which can arrive as its own chunk after the text.
        //
        // So the idle claim is tested against its own premise rather than against a guess
        // about when the echo lands: a fence that finds the terminal unchanged must publish
        // nothing. Pairs where output did arrive prove nothing either way and are skipped,
        // and the count below is what stops every pair from being skipped silently.
        var idlePairs = 0
        for _ in 0..<200 where idlePairs < 3 {
            controller.synchronizeState()
            let published = frames.count
            let before = controller.terminalSnapshot()
            controller.synchronizeState()
            if controller.terminalSnapshot() == before {
                idlePairs += 1
                #expect(frames.count == published, "an idle fence published a frame")
            }
            await Task.yield()
        }
        #expect(idlePairs == 3, "the pane never went idle, so idleness was never tested")

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

    @Test("theme changes publish one full frame and preserve deferred presentation")
    func themeChangesPublishAndDefer() async throws {
        // Intent: theme changes repaint exactly once while existing visibility and sync gates hold.
        // Why it exists: a theme-only change has no terminal damage and can be lost by byte-state dedupe.
        // Scenario: a visible pane changes twice, changes while hidden, then changes inside DEC 2026.
        let host = try makeHost()
        let themed = makeRenderTheme(seed: 20)
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec sleep 30")
        )
        var frames: [TerminalPaneFrame] = []
        controller.onFrame = { frames.append($0) }

        controller.setTheme(themed)
        controller.setTheme(themed)
        #expect(frames.count == 1)
        #expect(frames.first?.damage == .full)
        #expect(frames.first?.plan.defaultBackground == themed.defaultBackground)

        controller.setVisible(false)
        controller.setTheme(.dark)
        #expect(frames.count == 1)
        controller.setVisible(true)
        #expect(frames.count == 2)
        #expect(frames.last?.damage == .full)
        #expect(frames.last?.plan.defaultBackground == RenderTheme.dark.defaultBackground)

        host.deliverOutputForTesting(Array("\u{1B}[?2026h".utf8))
        controller.consumePendingHostUpdateForTesting()
        let synchronizedBaseline = frames.count
        controller.setTheme(themed)
        #expect(frames.count == synchronizedBaseline)
        host.deliverOutputForTesting(Array("\u{1B}[?2026l".utf8))
        controller.consumePendingHostUpdateForTesting()
        #expect(frames.count == synchronizedBaseline + 1)
        #expect(frames.last?.damage == .full)
        #expect(frames.last?.plan.defaultBackground == themed.defaultBackground)

        controller.tearDown()
        await host.close()
    }

    @Test("live theme defaults preserve ordering for OSC 10 and 11")
    func liveThemeDefaultsPreserveQueryOrdering() async throws {
        // Intent: query replies use the defaults ordered between theme switches on the owner queue.
        // Why it exists: renderer-local theme state would make OSC 10/11 stale or race child output.
        // Scenario: a child queries before a theme, after applying it, and after clearing it.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec sleep 30")
        )
        let query = Array("\u{1B}]10;?\u{07}\u{1B}]11;?\u{1B}\\".utf8)

        host.deliverOutputForTesting(query)
        controller.setTheme(makeRenderTheme(seed: 20))
        host.deliverOutputForTesting(query)
        controller.setTheme(.dark)
        host.deliverOutputForTesting(query)

        let replies = await host.replyWrites().flatMap { $0 }
        #expect(replies == Array(
            ("\u{1B}]10;rgb:e5e5/e5e5/e5e5\u{1B}\\"
                + "\u{1B}]11;rgb:0000/0000/0000\u{1B}\\"
                + "\u{1B}]10;rgb:1414/0404/0505\u{1B}\\"
                + "\u{1B}]11;rgb:1414/0606/0707\u{1B}\\"
                + "\u{1B}]10;rgb:e5e5/e5e5/e5e5\u{1B}\\"
                + "\u{1B}]11;rgb:0000/0000/0000\u{1B}\\").utf8
        ))

        controller.tearDown()
        await host.close()
    }

    @Test("initial theme is present in the controller's first retained plan")
    func initialThemePlansFirstFrame() async throws {
        // Intent: construction plans with the selected theme before any child output arrives.
        // Why it exists: applying only through reconcile permits a restored pane's first dark frame.
        // Scenario: a restored or inherited themed pane is created and inspected immediately.
        let host = try makeHost()
        let themed = makeRenderTheme(seed: 40)
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec sleep 30"),
            theme: themed
        )

        #expect(controller.renderTheme == themed)
        #expect(controller.currentPlan?.defaultBackground == themed.defaultBackground)

        controller.tearDown()
        await host.close()
    }

    @Test("clipboard delivery bypasses hidden rendering and precedes frame publication", .timeLimit(.minutes(1)))
    func clipboardDeliveryIsUngated() async throws {
        // Intent: every drained write reaches the session callback before any frame from that consume.
        // Why it exists: visibility and damage gates must not suppress grid-silent semantic effects.
        // Scenario: a hidden pane receives a remote OSC 52 write and synchronously fences it.
        let host = try makeHost()
        let command = "\(printMarker("READY", newline: false)); read ignored; printf '\\033]52;c;aGVsbG8=\\007'; exec sleep 30"
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

    @Test(
        "synchronized updates gate cursor projection, planning, and accumulated damage",
        .timeLimit(.minutes(1))
    )
    func presentationProjectionAndSynchronizedGating() async throws {
        // Intent: the controller projects cursor visibility, suppresses intermediate
        //   synchronized frames, and publishes the complete state -- plan and damage --
        //   once synchronization ends.
        // Why it exists: hardcoded cursor visibility and planning every 2026 update
        //   violate both terminal presentation semantics and the idle-work contract.
        //   The damage half guards a separate risk: draining on each owner read can
        //   discard damage accumulated while the pane session was not permitted to
        //   publish, so the committed frame would carry the right plan and nothing
        //   telling a consumer to repaint it.
        // Scenario: a visible TUI hides its cursor, batches two updates, then commits them.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(
                command: "exec \(try probeExecutable()) sync \"$0\""
            )
        )
        var plans: [RenderFramePlan] = []
        var damages: [TerminalDamage] = []
        controller.onFrame = { frame in
            plans.append(frame.plan)
            damages.append(frame.damage)
        }
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
        #expect(damages.last != TerminalDamage.none)

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
            launchInput: makeLaunchInput(command: printMarker("READY"))
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

    @Test("keyboard input reaches a child before sustained output completes", .timeLimit(.minutes(1)))
    func keyboardInputDuringSustainedOutputConverges() async throws {
        // Intent: keyboard input reaches the PTY child while its output producer is
        //   still active, then the pane publishes the producer's final state.
        // Why it exists: output convergence alone does not prove that visible flood
        //   processing leaves the child-input route live.
        // Scenario: the controlled probe floods output until it receives one key,
        //   records that the producer was still alive, then emits a final marker.
        let host = try makeHost(captureTransitions: false)
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(
                command: "exec \(try probeExecutable()) responsive-output \"$0\""
            )
        )
        var plans: [RenderFramePlan] = []
        controller.onFrame = { plans.append($0.plan) }

        #expect(await host.waitForOutput(containing: Array("__RESPONSIVE_READY__".utf8)))
        controller.sendText("k")
        #expect(await host.waitForResult() == .exited(.exited(0)))
        controller.synchronizeState()

        let finalPlan = try #require(plans.last)
        #expect(finalPlan.projectedText.contains("__INPUT_BEFORE_PRODUCER_DONE__=k"))
        #expect(finalPlan.projectedText.contains("__RESPONSIVE_DONE__"))
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
            launchInput: makeLaunchInput(command: printMarker("READY")),
            isVisible: false
        )
        var plans: [RenderFramePlan] = []
        controller.onFrame = { plans.append($0.plan) }
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        controller.sendText("printf '__HIDDEN_%s__\\n' OUTPUT\n")
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

    @Test("system sleep preserves pane state and visible wake publishes one complete frame")
    func systemSleepAndVisibleWake() async throws {
        // Intent: lifecycle suspension gates only presentation while terminal and
        //   semantic state continue, then visible wake publishes one complete frame.
        // Why it exists: system sleep must not lose PTY state or queue one frame per
        //   sleeping update, and a quiet wake still needs a current presentation.
        // Scenario: a visible pane sleeps, receives text and a title, wakes twice,
        //   then repeats a quiet sleep/wake cycle before teardown.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(
                command: "exec \(try probeExecutable()) hold \"$0\""
            )
        )
        var frames: [TerminalPaneFrame] = []
        var semantics: [TerminalSemanticEvent] = []
        var recoveryMutationCount = 0
        controller.onFrame = { frames.append($0) }
        controller.onSemanticEvents = { semantics.append(contentsOf: $0) }
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        controller.synchronizeState()
        frames.removeAll()
        semantics.removeAll()
        controller.onPrimaryHistoryMutation = { recoveryMutationCount += 1 }

        controller.setRenderingAvailable(false)
        controller.setRenderingAvailable(false)
        host.deliverOutputForTesting(Array("sleeping\u{1B}]2;sleep-title\u{7}".utf8))
        controller.consumePendingHostUpdateForTesting()

        #expect(frames.isEmpty)
        #expect(controller.readViewportText().contains("sleeping"))
        #expect(semantics == [.title("sleep-title")])
        #expect(recoveryMutationCount == 1)

        host.deliverOutputForTesting(Array("wake-edge".utf8))
        controller.setRenderingAvailable(true)
        #expect(frames.count == 1)
        #expect(frames[0].damage == .full)
        #expect(frames[0].plan.projectedText.contains("sleeping"))
        #expect(frames[0].plan.projectedText.contains("wake-edge"))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(frames.count == 1)
        controller.setRenderingAvailable(true)
        #expect(frames.count == 1)

        controller.setRenderingAvailable(false)
        controller.setRenderingAvailable(true)
        #expect(frames.count == 2)
        #expect(frames[1].damage == .full)

        controller.tearDown()
        controller.setRenderingAvailable(false)
        controller.setRenderingAvailable(true)
        #expect(frames.count == 2)
        await host.close()
    }

    @Test("hidden wake defers one complete frame until reveal")
    func hiddenWakeDefersUntilReveal() async throws {
        // Intent: lifecycle availability and pane visibility remain independent
        //   gates whose requests converge on one complete current reveal frame.
        // Why it exists: waking an occluded window must not render early or forget
        //   that its next visible presentation needs complete current state.
        // Scenario: a hidden pane sleeps, changes, wakes, and is revealed twice.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec sleep 30"),
            isVisible: false
        )
        var frames: [TerminalPaneFrame] = []
        controller.onFrame = { frames.append($0) }

        controller.setRenderingAvailable(false)
        host.deliverOutputForTesting(Array("hidden-asleep".utf8))
        controller.consumePendingHostUpdateForTesting()
        controller.setRenderingAvailable(true)

        #expect(frames.isEmpty)
        #expect(controller.readViewportText().contains("hidden-asleep"))
        controller.setVisible(true)
        #expect(frames.count == 1)
        #expect(frames[0].damage == .full)
        #expect(frames[0].plan.projectedText.contains("hidden-asleep"))
        controller.setVisible(true)
        #expect(frames.count == 1)

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
            launchInput: makeLaunchInput(command: printMarker("READY"))
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
                launchInput: launchInput,
                terminalProgramVersion: "dev"
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
        let replayed = try recording.replay(machineHostname: MachineHostname.posix)
        #expect(recording.provenance == .danTerm(test: "viability-pane"))
        #expect(replayed.geometry.columns == 96)
        #expect(replayed.geometry.rows.count == 28)
        #expect(replayed.fullHistoryText == controller.readFullHistoryText())

        controller.tearDown()
        await waitForQuiescence(controller.terminationHandle)
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

    @Test("diagnostic capture fences a live session without completing its recording", .timeLimit(.minutes(1)))
    func diagnosticCaptureFencesLiveSession() async throws {
        // Intent: failure diagnostics serialize all owner-accepted transitions and the
        //   matching terminal snapshot before teardown without claiming session completion.
        // Why it exists: live-workflow failures must retain reproducible evidence while the
        //   app-facing recording contract remains child-exit-only.
        // Scenario: a shell prints a marker, stays alive, and the harness captures it before cleanup.
        let launchInput = makeLaunchInput(command: "printf '__DIAGNOSTIC__\\n'; cat")
        let controller = try TerminalPaneSessionController(
            configuration: .init(
                launchInput: launchInput,
                terminalProgramVersion: "dev"
            ),
            bootstrapExecutable: bootstrapExecutable(),
            captureTransitions: true
        )
        defer { controller.tearDown() }

        while controller.readFullHistoryText().contains("__DIAGNOSTIC__") == false {
            controller.synchronizeState()
            await Task.yield()
        }

        let capture = controller.diagnosticCapture(test: "live-failure")
        #expect(capture.recording.events.isEmpty == false)
        #expect(capture.terminal.fullHistoryText.contains("__DIAGNOSTIC__"))
        #expect(controller.capturedRecording(test: "ordinary") == nil)
    }

    @Test("a diagnostic capture between frames never strands its damage", .timeLimit(.minutes(1)))
    func diagnosticCaptureFoldsDamageIntoTheNextPlan() async throws {
        // Intent: output that only a diagnostic capture observed still reaches the next
        //   published plan, which must equal a from-scratch plan of the same terminal.
        // Why it exists: the capture fence drains the host's damage, so a capture taken
        //   between frames is the one path that can advance the terminal without telling
        //   the planner which rows moved. Row reuse turned that from harmless into a
        //   stale-row bug: undamaged-looking rows get copied from a frame that predates
        //   the captured output.
        // Scenario: a harness captures diagnostics from a live pane mid-run, and the pane
        //   keeps printing afterwards -- the rows written before the capture must not stay
        //   frozen at their pre-capture content.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            // `stty -echo` is what makes the two waits below mean what they read as: with echo
            // left on, a marker sent as input arrives twice -- once from the tty, once from
            // `cat` -- and `waitForOutput` returns on the first, mid-scenario. `printMarker`
            // covers the other direction for the readiness wait.
            launchInput: makeLaunchInput(command: "stty -echo; \(printMarker("READY")); cat")
        )
        var plans: [RenderFramePlan] = []
        controller.onFrame = { plans.append($0.plan) }
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        controller.synchronizeState()

        controller.sendText("__CAPTURED__\n")
        #expect(await host.waitForOutput(containing: Array("__CAPTURED__".utf8)))
        _ = controller.diagnosticCapture(test: "damage-fold")

        controller.sendText("__AFTER__\n")
        #expect(await host.waitForOutput(containing: Array("__AFTER__".utf8)))
        controller.synchronizeState()

        // The controller's own fenced terminal, not a second `host.fencedSnapshot()`: a
        // separate later fence can see output that arrived after the plan was published,
        // which fails the comparison for a reason this test is not about.
        let finalTerminal = controller.terminalSnapshot()
        let expected = planFrame(
            for: finalTerminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: finalTerminal.presentation.isCursorVisible,
                cursorShape: finalTerminal.presentation.cursorShape
            )
        )
        #expect(finalTerminal.fullHistoryText.contains("__AFTER__"))
        #expect(try #require(plans.last) == expected)

        controller.tearDown()
        await host.close()
    }

    @Test("every synchronization fence leaves the plan stream current", .timeLimit(.minutes(1)))
    func synchronizeStateNeverPublishesAStaleRow() async throws {
        // Intent: after any `synchronizeState()`, the newest published plan equals a
        //   from-scratch plan of the terminal that fence returned.
        // Why it exists: damage is drained on the host's queue but consumed on the main
        //   actor, so a synchronous fence can land between an asynchronous drain and its
        //   delivery -- advancing the cached terminal while the rows that moved are still
        //   in flight. Row reuse then copies rows from a frame that predates them, which
        //   surfaces as a cursor left unpainted or a row frozen at old content. The
        //   assertion is deliberately main-actor-local: both operands come from the
        //   controller, so nothing here depends on when the child writes.
        // Scenario: a pane rewrites viewport rows in place while the app fences repeatedly
        //   for recovery checkpoints -- the ordinary steady state of a live pane.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            // `-echo` so each write below comes back exactly once, from `cat`, and `-icanon`
            // so it comes back at all: the writes carry no newline, and a canonical-mode tty
            // holds input from its reader until one arrives.
            launchInput: makeLaunchInput(
                command: "stty -echo -icanon; \(printMarker("READY")); cat"
            )
        )
        var plans: [RenderFramePlan] = []
        controller.onFrame = { plans.append($0.plan) }
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        // The pane's output is driven from here, one small write per fence, rather than by a
        // child looping on its own. A child flooding the pty saturates the host's queue, and
        // every `synchronizeState` then blocks behind a read turn -- around 115ms per fence,
        // which is slow enough that the fence count needed to cover the race runs into the
        // test's own time limit. Pacing the writes keeps each fence cheap while still leaving
        // output in flight across it, which is the only condition the race needs.
        var checks = 0
        var mismatches = 0
        var firstMismatch = ""
        for fence in 0..<120 {
            // Absolute row addressing inside the first 20 rows, never past column 80: any
            // scroll reports full damage, which replans every row and would hide the stale
            // reuse this test exists to catch.
            controller.sendText("\u{1B}[\(fence % 20 + 1);1Hmark \(fence) ")
            controller.synchronizeState()
            let snapshot = controller.terminalSnapshot()
            guard let published = plans.last else {
                await Task.yield()
                continue
            }
            checks += 1
            let fresh = planFrame(
                for: snapshot,
                presentation: RenderPresentation(
                    theme: .dark,
                    isCursorVisible: snapshot.presentation.isCursorVisible,
                    cursorShape: snapshot.presentation.cursorShape
                )
            )
            // Counted rather than asserted per iteration: a whole `RenderFramePlan` in the
            // failure message buries the one field that differs under every field that does not.
            if published != fresh {
                mismatches += 1
                if firstMismatch.isEmpty {
                    firstMismatch = """
                        fence \(fence): background \(published.backgroundRuns == fresh.backgroundRuns) \
                        text \(published.textRuns == fresh.textRuns) \
                        decoration \(published.decorationRuns == fresh.decorationRuns) \
                        cursor \(published.cursor == fresh.cursor) \
                        overlay \(published.overlayRuns == fresh.overlayRuns)
                        """
                }
            }
            await Task.yield()
        }
        #expect(mismatches == 0, "\(mismatches) of \(checks) fences disagreed -- \(firstMismatch)")
        // A run whose pane produced almost nothing never opened the window, so a green result
        // would say nothing about the race.
        #expect(checks > 90, "only \(checks) of 120 fences saw a published plan")
        #expect(plans.count > 20, "the pane published only \(plans.count) frames")

        controller.tearDown()
        await host.close()
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
            launchInput: makeLaunchInput(command: printMarker("READY")),
            isVisible: false
        )
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        controller.sendText("printf '__FINAL_%s__\\n' CHECKPOINT\n")
        #expect(await host.waitForOutput(containing: Array("__FINAL_CHECKPOINT__".utf8)))

        controller.tearDown()

        #expect(controller.readFullHistoryText().contains("__FINAL_CHECKPOINT__"))
        await host.close()
    }

    @Test("application termination drains the retained registry while main is blocked", .timeLimit(.minutes(1)))
    func applicationTerminationDrainsRegistryWithoutMainProgress() async throws {
        // Intent: the backend registry retains every host through native cleanup,
        //   removes it from host-queue quiescence, and returns only after all
        //   shutdown observers have run.
        // Why it exists: main-delivery cleanup could strand a mid-close host when
        //   applicationWillTerminate synchronously blocked the main actor.
        // Scenario: the user quits with one continuously writing pane and one
        //   pane already closing; the synchronous exit hook blocks main until
        //   both are quiescent.
        let liveHost = try makeHost()
        let closingHost = try makeHost()
        let liveController = TerminalPaneSessionController(
            host: liveHost,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) chatty \"$0\"")
        )
        let closingController = TerminalPaneSessionController(
            host: closingHost,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\"")
        )
        let registry = TerminalPaneTerminationRegistry()
        registry.retain(liveController.terminationHandle)
        registry.retain(closingController.terminationHandle)
        let observers = PaneExitCompletionRecorder()
        liveController.terminationHandle.whenQuiescent { observers.signal() }
        closingController.terminationHandle.whenQuiescent { observers.signal() }
        // The live pane is waited on by its flood, not by `__READY__`: the chatty child
        // writes 4 KiB forever the instant it prints that marker, so by the time this wait
        // is armed the host has discarded it and the question is unanswerable. The flood
        // byte is evidence no discard can lose, and "already writing" is what this test
        // needs anyway.
        #expect(await liveHost.waitForOutput(
            containing: [UInt8](repeating: UInt8(ascii: "c"), count: 4096)
        ))
        #expect(await closingHost.waitForOutput(containing: Array("__READY__".utf8)))

        closingController.tearDown()
        let clock = ContinuousClock()
        let start = clock.now
        registry.requestShutdownAndWait()
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(3))
        #expect(observers.signalCount == 2)
        #expect(registry.retainedCount == 0)
        #expect((await liveHost.resourceSnapshot()).isReleased)
        #expect((await closingHost.resourceSnapshot()).isReleased)
        liveController.tearDown()
    }

    @Test("ordinary teardown and app exit release identical registry ownership", .timeLimit(.minutes(1)))
    func ordinaryTeardownAndAppExitReleaseRegistryOwnership() async throws {
        // Intent: ordinary pane teardown and process exit both remove exactly one
        //   retained handle only after the same native resource outcome.
        // Why it exists: controller-driven registry removal gave ordinary close a
        //   different lifetime edge from application termination.
        // Scenario: one pane closes through reconciliation while another remains
        //   live until Cmd-Q; neither handle survives its host's quiescence.
        let ordinaryHost = try makeHost()
        let exitHost = try makeHost()
        let ordinaryController = TerminalPaneSessionController(
            host: ordinaryHost,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\"")
        )
        let exitController = TerminalPaneSessionController(
            host: exitHost,
            launchInput: makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\"")
        )
        let registry = TerminalPaneTerminationRegistry()
        registry.retain(ordinaryController.terminationHandle)
        registry.retain(exitController.terminationHandle)
        #expect(await ordinaryHost.waitForOutput(containing: Array("__READY__".utf8)))
        #expect(await exitHost.waitForOutput(containing: Array("__READY__".utf8)))

        ordinaryController.tearDown()
        ordinaryController.tearDown()
        await waitForQuiescence(ordinaryController.terminationHandle)
        #expect(registry.retainedCount == 1)
        #expect((await ordinaryHost.resourceSnapshot()).isReleased)

        registry.requestShutdownAndWait()
        #expect(registry.retainedCount == 0)
        #expect((await exitHost.resourceSnapshot()).isReleased)
        exitController.tearDown()
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

    @Test("empty Select All enables Copy without projecting history", .timeLimit(.minutes(1)))
    func emptySelectAllHasSelectionIsConstantCost() async throws {
        // Intent: session menu validation reads selection presence, including an intentionally
        //   empty selection, without serializing retained text.
        // Why it exists: menu validation shares the main-thread fence path with pointer input;
        //   a whole-history walk here can freeze the pane even though only a boolean is needed.
        // Scenario: a blank sleeping pane receives Select All and asks whether Copy is enabled.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "exec sleep 30")
        )

        controller.selectAll()
        controller.synchronizeState()
        let materializations = WholeProjectionCounter.measure {
            #expect(controller.hasSelection)
        }

        #expect(controller.readSelectedText() == "")
        #expect(materializations == 0)
        controller.tearDown()
        await host.close()
    }

    @Test("controller search enqueues report status on the main actor", .timeLimit(.minutes(1)))
    func controllerSearchReportsStatus() async throws {
        // Intent: the controller's search wrappers reach the owner and hop the owner's
        //   status report back onto the main actor for the find overlay.
        // Why it exists: the status callback fires on the host queue; delivering it
        //   without the hop would touch main-actor view state off the main actor.
        let host = try makeHost()
        // Octal-escaped so the needle never appears in the echoed command line itself.
        let command = "printf '\\150it\\n'; exec \(try probeExecutable()) hold \"$0\""
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: command)
        )
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let statuses = AsyncStream<TerminalSearchStatus?>.makeStream()
        var iterator = statuses.stream.makeAsyncIterator()
        controller.onSearchStatus = { statuses.continuation.yield($0) }

        controller.beginSearch("hit")
        #expect(try #require(await iterator.next()) == .matched(selected: 0, total: 1))

        controller.clearSearch()
        #expect(await iterator.next() == .some(nil))

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
                launchInput: makeLaunchInput(command: command),
                terminalProgramVersion: "dev"
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
        var replayed = try recording.replay(machineHostname: MachineHostname.posix)
        _ = replayed.drainDamage()
        var consumed = controller.terminalSnapshot()
        _ = consumed.drainDamage()
        #expect(replayed == consumed)

        controller.tearDown()
        await waitForQuiescence(controller.terminationHandle)
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
                launchInput: makeLaunchInput(command: printMarker("READY"))
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
        // Actor deallocation can lag the last await under scheduler load in
        // parallel runs; a retain cycle persists, scheduling noise settles.
        for _ in 0..<40 where releasedController != nil || releasedHost != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(releasedController == nil)
        #expect(releasedHost == nil)
    }
}

/// Returns once every main-queue block enqueued before the call has run, so a test can
/// assert on what the controller's delivery boundary did or did not hand to the main actor.
private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}

private func makeHost(
    captureTransitions: Bool = true
) throws -> TerminalPTYHost {
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
        initialDimensions: .init(columns: 80, rows: 24)
    )
}

private func makeRenderTheme(seed: UInt8) -> RenderTheme {
    let palette = (0..<16).map { offset in
        RenderColor(red: seed &+ UInt8(offset), green: 2, blue: 3)
    }
    return RenderTheme(
        ansiColors: RenderANSIColors(exactly: palette)!,
        defaultForeground: .init(red: seed, green: 4, blue: 5),
        defaultBackground: .init(red: seed, green: 6, blue: 7),
        selectionForeground: .init(red: seed, green: 8, blue: 9),
        selectionBackground: .init(red: seed, green: 10, blue: 11),
        cursor: .init(red: seed, green: 12, blue: 13),
        cursorText: .init(red: seed, green: 14, blue: 15)
    )
}

private func shellIntegrationDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "integrations/shell-integration", directoryHint: .isDirectory)
}

private func findExecutable(named name: String) throws -> String {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    return try #require(path.split(separator: ":").lazy
        .map { URL(fileURLWithPath: String($0)).appending(path: name).path }
        .first(where: FileManager.default.isExecutableFile(atPath:)))
}

private func waitForQuiescence(_ handle: TerminalPaneTerminationHandle) async {
    await withCheckedContinuation { continuation in
        handle.whenQuiescent { continuation.resume() }
    }
}

/// Records dispatch completions while the main actor is intentionally blocked.
private final class PaneExitCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func signal() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var signalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private extension RenderFramePlan {
    var projectedText: String {
        textRuns.flatMap(\.cells).flatMap(\.scalars).reduce(into: "") {
            $0.unicodeScalars.append($1)
        }
    }
}
