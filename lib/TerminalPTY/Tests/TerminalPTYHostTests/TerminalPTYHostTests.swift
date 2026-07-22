// Real-system PTY tests for launch ownership, ordered IO, resize, and exit convergence.
import Darwin
import Foundation
import Testing
@testable import TerminalPTYHost
import PaneLifecycle
import TerminalCore
import TerminalCoreRecording

/// Exercises the native owner only through real PTYs and controlled child behavior.
@Suite(.serialized)
struct TerminalPTYHostTests {
    @Test("Cmd link interaction publishes hover and opens once without PTY input", .timeLimit(.minutes(1)))
    func linkInteractionEffectsStayLocal() async throws {
        // Intent: prove the serialized owner applies hover/open effects without child bytes.
        // Why it exists: link ownership must preempt mouse reporting at the PTY boundary.
        // Scenario: a real child prints OSC 8 text, then receives a Cmd-hover and Cmd-click.
        let host = try makeHost()
        let command = "printf '\\033]8;;https://a.co\\007https://a.co\\033]8;;\\007'; exec \(try probeExecutable()) hold \"$0\""
        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let screen = host.fencedSnapshot().screenText
            .split(separator: "\n", omittingEmptySubsequences: false)
        let row = try #require(screen.lastIndex(where: { $0.contains("https://a.co") }))
        let target = try #require(screen[row].range(of: "https://a.co"))
        let column = screen[row].distance(from: screen[row].startIndex, to: target.lowerBound)
        let snapshot = host.fencedSnapshot()
        _ = try #require(snapshot.activatableLink(at: .init(
            row: snapshot.scrollProjection.topRow + row,
            column: column + 2
        )))
        let baseline = await host.inputWrites().count
        let opened = AsyncStream<TerminalHyperlink>.makeStream()
        var iterator = opened.stream.makeAsyncIterator()

        host.sendPointer(.move(column: column + 2, row: row, modifiers: [.command]))
        _ = try #require(host.fencedSnapshot().hoveredLink)
        host.sendPointer(
            .down(.left, column: column + 2, row: row, modifiers: [.command]),
            onOpenLink: { opened.continuation.yield($0) }
        )
        host.sendPointer(
            .up(.left, column: column + 3, row: row, modifiers: [.command]),
            onOpenLink: { opened.continuation.yield($0) }
        )

        #expect(await iterator.next()?.uri == "https://a.co")
        #expect(await host.inputWrites().count == baseline)
        host.cancelLinkInteraction()
        #expect(host.fencedSnapshot().hoveredLink == nil)
        await host.close()
    }
    @Test("frame-state reads drain damage without changing ordinary snapshots")
    func frameStateReadsDrainDamage() async throws {
        let host = try makeHost()

        let first = host.fencedFrameState()
        let second = host.fencedFrameState()

        #expect(first.damage == .full)
        #expect(second.damage == .none)
        #expect(await host.snapshot() == second.terminal)
        await host.close()
    }

    @Test("OSC 52 wakes and drains once without sending query data to the child", .timeLimit(.minutes(1)))
    func clipboardWriteFrameStateAndReadDenial() async throws {
        // Intent: owner framing drains completed clipboard writes independently from replies.
        // Why it exists: grid-silent effects need a wakeup, while reads must never expose clipboard data.
        // Scenario: a child writes OSC 52, asks to read it, and remains alive for inspection.
        let host = try makeHost()
        _ = host.fencedFrameState()
        let command = "printf '__READY__'; sleep 0.1; printf '\\033]52;c;aGVsbG8=\\007\\033]52;c;?\\007'; exec sleep 30"
        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        _ = host.fencedFrameState()

        var clipboardWrite: String?
        for await _ in host.updates {
            let state = await host.frameState()
            if state.clipboardWrite != nil {
                clipboardWrite = state.clipboardWrite
                break
            }
        }

        #expect(clipboardWrite == "hello")
        #expect(host.fencedFrameState().clipboardWrite == nil)
        #expect(await host.replyWrites() == [])
        await host.close()
    }

    @Test("incomplete OSC 52 stays idle until grid-silent termination", .timeLimit(.minutes(1)))
    func incompleteClipboardWriteStaysIdle() async throws {
        // Intent: retained OSC bytes alone produce neither a host wakeup nor a drained effect.
        // Why it exists: whole-Terminal inequality includes parser state and is too broad for work.
        // Scenario: a child splits one clipboard write across two temporally separate chunks.
        let host = try makeHost(captureTransitions: false)
        _ = host.fencedFrameState()
        let command = "printf '\\137\\137READY\\137\\137'; sleep 0.2; printf '\\033]52;c;aGVs'; sleep 0.2; printf 'bG8=\\007'; exec sleep 30"
        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        _ = host.fencedFrameState()
        let baseline = (await host.resourceSnapshot()).emittedUpdateSignalCount

        #expect(await host.waitForOutput(containing: Array("\u{1B}]52;c;aGVs".utf8)))
        #expect((await host.resourceSnapshot()).emittedUpdateSignalCount == baseline)
        let incomplete = host.fencedFrameState()
        #expect(incomplete.damage == .none)
        #expect(incomplete.clipboardWrite == nil)

        #expect(await host.waitForOutput(containing: Array("bG8=\u{7}".utf8)))
        #expect((await host.resourceSnapshot()).emittedUpdateSignalCount == baseline + 1)
        let complete = host.fencedFrameState()
        #expect(complete.damage == .none)
        #expect(complete.clipboardWrite == "hello")
        #expect(host.fencedFrameState().clipboardWrite == nil)
        await host.close()
    }

    @Test("controlled login shell observes PTY ownership, cwd, environment, IO, and exit", .timeLimit(.minutes(1)))
    func launchRecipeAndDuplexIO() async throws {
        let host = try TerminalPTYHost(
            initialDimensions: .init(columns: 80, rows: 24),
            bootstrapExecutable: try bootstrapExecutable(),
            captureTransitions: true
        )
        let command = "exec \(try probeExecutable()) ownership \"$0\""

        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        host.send(Array("ordered-input\n".utf8))
        let result = await host.waitForResult()
        let output = String(decoding: await host.outputBytes(), as: UTF8.self)

        #expect(result == .exited(.exited(7)))
        #expect(await host.waitForResult() == result)
        #expect(output.contains("__ARGV0__=-sh"))
        let pid = try taggedInt("__PID__", in: output)
        #expect(try taggedInt("__SID__", in: output) == pid)
        #expect(try taggedInt("__PGID__", in: output) == pid)
        #expect(try taggedInt("__TPGID__", in: output) == pid)
        #expect(output.contains("__TTY0__=yes"))
        #expect(output.contains("__TTY1__=yes"))
        #expect(output.contains("__TTY2__=yes"))
        let tty0 = try taggedValue("__TTYNAME0__", in: output)
        #expect(try taggedValue("__TTYNAME1__", in: output) == tty0)
        #expect(try taggedValue("__TTYNAME2__", in: output) == tty0)
        #expect(output.contains("__CWD__=/"))
        #expect(output.contains("__ENV__=pane-wins"))
        #expect(output.contains("__SIZE__=24 80"))
        #expect(output.contains("__INPUT__=ordered-input"))
    }

    @Test("bootstrap cwd failure retries the next pure-policy fallback", .timeLimit(.minutes(1)))
    func realSpawnCwdFallback() async throws {
        let host = try makeHost()
        var input = makeLaunchInput(
            command: "exec \(try probeExecutable()) ownership \"$0\""
        )
        input.requestedWorkingDirectory = "/definitely/missing-after-policy"
        input.accessibleDirectories = ["/definitely/missing-after-policy", "/"]

        await host.start(input)
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        host.send(Array("fallback\n".utf8))
        #expect(await host.waitForResult() == .exited(.exited(7)))

        let output = String(decoding: await host.outputBytes(), as: UTF8.self)
        #expect(output.contains("__CWD__=/"))
        #expect(output.contains("__INPUT__=fallback"))
    }

    @Test("resize is ordered between output and keeps child and terminal geometry equal", .timeLimit(.minutes(1)))
    func orderedResize() async throws {
        let host = try TerminalPTYHost(
            initialDimensions: .init(columns: 80, rows: 24),
            bootstrapExecutable: try bootstrapExecutable(),
            captureTransitions: true
        )
        let command = "exec \(try probeExecutable()) resize \"$0\""

        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        host.resize(.init(columns: 100, rows: 31))
        let snapshot = await host.snapshot()
        host.send(Array("done\n".utf8))
        #expect(await host.waitForResult() == .exited(.exited(0)))
        let output = String(decoding: await host.outputBytes(), as: UTF8.self)

        #expect(snapshot.geometry.columns == 100)
        #expect(snapshot.geometry.rows.count == 31)
        #expect(output.contains("__WINCH__=31 100"))
    }

    @Test("synchronous input and resize submissions preserve their shared FIFO order", .timeLimit(.minutes(1)))
    @MainActor
    func synchronousSubmissionOrder() async throws {
        // Intent: input and resize calls made from one synchronous context enter
        //   the owner in exactly the order the caller submitted them.
        // Why it exists: separate unstructured Tasks can reorder input and grid
        //   changes even though each actor method is individually serialized.
        // Scenario: a pane sends bytes, resizes, then sends the completing line
        //   while a live child waits for that line.
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) recording \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__BEFORE_RESIZE__".utf8)))
        let submissionBaseline = await host.submittedTransitions().count

        host.send(Array("prefix-".utf8))
        host.resize(.init(columns: 96, rows: 28))
        host.send(Array("continue\n".utf8))

        #expect(await host.waitForResult() == .exited(.exited(0)))
        #expect(Array((await host.submittedTransitions()).dropFirst(submissionBaseline)) == [
            .input(Array("prefix-".utf8)),
            .resize(.init(columns: 96, rows: 28)),
            .input(Array("continue\n".utf8)),
        ])

        host.send(Array("after-teardown".utf8))
        host.resize(.init(columns: 120, rows: 40))
        #expect(await host.submittedTransitions().count == submissionBaseline + 3)
    }

    @Test("updates cover output, resize, and a later result without polling", .timeLimit(.minutes(1)))
    func updateSignalResignalsAfterConsumerPull() async throws {
        // Intent: each newly applied state after a consumer pull makes another
        //   update observable, including resize and the final lifecycle result.
        // Why it exists: a naive conflation flag can lose the re-signal race or
        //   finish the stream before its final result token is delivered.
        // Scenario: a pane renders its prompt, resizes, accepts a command, and
        //   then observes child exit through the same event-driven stream.
        let host = try makeHost()
        var updates = host.updates.makeAsyncIterator()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) resize \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        #expect(await updates.next() != nil)

        host.resize(.init(columns: 100, rows: 31))
        var observedResize = false
        while let _ = await updates.next() {
            let snapshot = await host.snapshot()
            if snapshot.geometry.columns == 100, snapshot.geometry.rows.count == 31 {
                observedResize = true
                break
            }
        }
        #expect(observedResize)

        host.send(Array("done\n".utf8))
        var observedResult: PaneLifecycleResult?
        while let _ = await updates.next() {
            observedResult = await host.result()
            if observedResult != nil { break }
        }
        #expect(observedResult == .exited(.exited(0)))
        while await updates.next() != nil {}
        #expect((await host.resourceSnapshot()).updateSignalsAfterTermination == 0)
    }

    @Test("an unchanged terminal emits no update work", .timeLimit(.minutes(1)))
    func unchangedTerminalEmitsNoUpdate() async throws {
        let host = try makeHost(captureTransitions: false)
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let signalsBefore = (await host.resourceSnapshot()).emittedUpdateSignalCount

        host.resize(.init(columns: 80, rows: 24))
        _ = await host.snapshot()

        #expect((await host.resourceSnapshot()).emittedUpdateSignalCount == signalsBefore)
        await host.close()
    }

    @Test("query replies precede later user input without causing render updates", .timeLimit(.minutes(1)))
    func queryReplyOrderingAndCapture() async throws {
        // Intent: route core-generated CPR bytes back through the PTY before later user input.
        // Why it exists: reducer routing can reorder replies, misclassify them as user input,
        //   or wake rendering for a query that does not change terminal presentation state.
        // Scenario: a child waits for CPR, while the user submits bytes only after its query.
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) query \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__QUERY_READY__".utf8)))
        var updates = host.updates.makeAsyncIterator()
        while await updates.next() != nil {
            if (await host.snapshot()).screenText.contains("__QUERY_READY__") { break }
        }
        let signalsBeforeQuery = (await host.resourceSnapshot()).emittedUpdateSignalCount
        let inputBaseline = await host.inputWrites().count

        host.send(Array("query\n".utf8))
        #expect(await host.waitForOutput(containing: Array("\u{1B}[6n".utf8)))
        #expect((await host.resourceSnapshot()).emittedUpdateSignalCount == signalsBeforeQuery)
        host.send(Array("USER".utf8))

        let result = await host.waitForResult()
        let output = String(decoding: await host.outputBytes(), as: UTF8.self)
        let replies = await host.replyWrites()
        let inputs = await host.inputWrites()
        #expect(result == .exited(.exited(0)), "result: \(String(describing: result))")
        #expect(output.contains("__QUERY_OK__"), "output: \(output.debugDescription)")
        #expect(replies == [Array("\u{1B}[1;1R".utf8)], "replies: \(replies)")
        #expect(
            Array(inputs.dropFirst(inputBaseline))
                == [Array("query\n".utf8), Array("USER".utf8)],
            "inputs: \(inputs)"
        )
        #expect((await host.snapshot()).pendingReplyBytes.isEmpty)
    }

    @Test("query-bearing capture replays to the drained live terminal", .timeLimit(.minutes(1)))
    func queryCaptureReplayEquality() async throws {
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) query \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__QUERY_READY__".utf8)))
        host.send(Array("query\n".utf8))
        #expect(await host.waitForOutput(containing: Array("\u{1B}[6n".utf8)))
        host.send(Array("USER".utf8))
        #expect(await host.waitForResult() == .exited(.exited(0)))

        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "pty-query-replay"),
            initial: .init(columns: 80, rows: 24),
            events: (await host.transitions()).map(\.recordingEvent)
        )

        #expect(try recording.replay() == (await host.snapshot()))
    }

    @Test("a late update consumer receives one conflated final state before termination", .timeLimit(.minutes(1)))
    func lateUpdateConsumerReceivesFinalState() async throws {
        // Intent: a stalled consumer receives the newest state once and can then
        //   observe clean stream termination and the in-band child result.
        // Why it exists: finishing an AsyncStream before yielding its final token
        //   drops the only wakeup that can carry the last output into recovery.
        // Scenario: a child writes a fragmented burst and exits before the pane's
        //   update consumer begins reading.
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) fragmented \"$0\""
        ))
        #expect(await host.waitForResult() == .exited(.exited(0)))

        var updates = host.updates.makeAsyncIterator()
        #expect(await updates.next() != nil)
        #expect(await updates.next() == nil)
        #expect(await host.result() == .exited(.exited(0)))
        #expect((await host.snapshot()).fullHistoryText.contains("__FRAGMENTED_DONE__"))
        #expect((await host.resourceSnapshot()).updateSignalsAfterTermination == 0)
    }

    @Test("a result-only drain emits its final update token", .timeLimit(.minutes(1)))
    func resultOnlyDrainEmitsFinalUpdate() async throws {
        let host = try makeHost(captureTransitions: false)
        var input = makeLaunchInput(command: "")
        input.initialDimensions = .init(columns: 0, rows: 0)

        await host.start(input)
        #expect(await host.waitForResult() == .launchFailed(.invalidDimensions))

        var updates = host.updates.makeAsyncIterator()
        #expect(await updates.next() != nil)
        #expect(await updates.next() == nil)
        #expect((await host.resourceSnapshot()).emittedUpdateSignalCount == 1)
    }

    @Test("closing a live pane resolves result waiters with nil", .timeLimit(.minutes(1)))
    func closeWithoutChildResultResumesWaiter() async throws {
        // Intent: teardown completion resumes every result waiter even when no
        //   product-level child result exists.
        // Why it exists: the old set-once result path stranded its continuation
        //   forever and retained a user-closed pane host.
        // Scenario: a user closes a pane while its shell is still running.
        weak var releasedHost: TerminalPTYHost?
        do {
            let host = try makeHost(captureTransitions: false)
            releasedHost = host
            await host.start(makeLaunchInput(
                command: "exec \(try probeExecutable()) hold \"$0\""
            ))
            #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

            async let result = host.waitForResult()
            await host.close()

            #expect(await result == nil)
            #expect(await host.result() == nil)
            #expect((await host.resourceSnapshot()).isReleased)
        }
        #expect(releasedHost == nil)
    }

    @Test("large fragmented output is delivered in byte order before exit", .timeLimit(.minutes(1)))
    func largeFragmentedOutput() async throws {
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) fragmented \"$0\""
        ))

        #expect(await host.waitForResult() == .exited(.exited(0)))
        let output = Data(await host.outputBytes())
        let expected = Data((0..<(256 * 1024)).map { UInt8(65 + ($0 % 26)) })

        #expect(output.range(of: expected) != nil)
        #expect(output.range(of: Data("__FRAGMENTED_DONE__".utf8)) != nil)
    }

    @Test("PTY EOF observed before child exit still reports one final status", .timeLimit(.minutes(1)))
    func eofBeforeExit() async throws {
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) eof-first \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__CLOSING_PTY__".utf8)))
        let pid = try taggedInt(
            "__PID__",
            in: String(decoding: await host.outputBytes(), as: UTF8.self)
        )

        #expect(kill(pid_t(pid), SIGUSR1) == 0)
        #expect(await host.waitForResult() == .exited(.exited(6)))
    }

    @Test("leader exit drains its final marker and terminates a slave-holding descendant", .timeLimit(.minutes(1)))
    func exitBeforeEOFConverges() async throws {
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) exit-first \"$0\""
        ))

        #expect(await host.waitForResult() == .exited(.exited(9)))
        let output = String(decoding: await host.outputBytes(), as: UTF8.self)
        let descendant = try taggedInt("__DESCENDANT__", in: output)

        #expect(output.contains("__FINAL_MARKER__"))
        errno = 0
        #expect(kill(pid_t(descendant), 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("recorded output-resize-output order replays to the live Terminal", .timeLimit(.minutes(1)))
    func recordingRoundTrip() async throws {
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) recording \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__BEFORE_RESIZE__".utf8)))
        host.resize(.init(columns: 96, rows: 28))
        host.send(Array("continue\n".utf8))
        #expect(await host.waitForResult() == .exited(.exited(0)))

        let transitions = await host.transitions()
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "pty-output-resize-output"),
            initial: .init(columns: 80, rows: 24),
            events: transitions.map(\.recordingEvent)
        )
        let recorder = PTYRecordingRecorder(recording: recording)
        let encoded = try recorder.encoded()
        try recorder.writeIfRequested(name: "pty-output-resize-output")
        let decoded = try JSONDecoder().decode(NeutralTerminalRecording.self, from: encoded)

        #expect(try decoded.replay() == (await host.snapshot()))
        let resizeIndex = try #require(transitions.firstIndex {
            if case .resize = $0 { true } else { false }
        })
        #expect(transitions[..<resizeIndex].contains {
            if case .feed = $0 { true } else { false }
        })
        #expect(transitions[(resizeIndex + 1)...].contains {
            if case .feed = $0 { true } else { false }
        })
    }

    @Test("teardown reaches every job in the owned session without touching a sibling", .timeLimit(.minutes(1)))
    func teardownLadderCoversSessionAndPreservesSibling() async throws {
        // Intent: pane close escalates across foreground, background, stopped,
        //   and signal-resistant jobs, then releases the whole owned session.
        // Why it exists: foreground-group-only signaling and a ladder without a
        //   post-SIGKILL census both leave real terminal jobs behind.
        // Scenario: one pane contains all four job shapes while a second pane is
        //   live; closing the first must converge without disturbing the second.
        let host = try makeHost()
        let sibling = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) teardown \"$0\""
        ))
        await sibling.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        #expect(await sibling.waitForOutput(containing: Array("__READY__".utf8)))

        let output = String(decoding: await host.outputBytes(), as: UTF8.self)
        let ownedPIDs = try [
            taggedInt("__LEADER__", in: output),
            taggedInt("__FOREGROUND__", in: output),
            taggedInt("__BACKGROUND__", in: output),
            taggedInt("__STOPPED__", in: output),
            taggedInt("__RESISTANT__", in: output),
        ]
        let siblingPID = try taggedInt(
            "__PID__",
            in: String(decoding: await sibling.outputBytes(), as: UTF8.self)
        )

        await host.close()

        for pid in ownedPIDs {
            #expect(processExists(pid) == false, "Owned process \(pid) survived pane close")
        }
        #expect(processExists(siblingPID))
        #expect((await host.resourceSnapshot()).isReleased)

        await sibling.close()
        #expect(processExists(siblingPID) == false)
        #expect((await sibling.resourceSnapshot()).isReleased)
    }

    @Test("rapid create-close and resize-close races release descriptors and owners", .timeLimit(.minutes(1)))
    func rapidCloseStressLeavesNoResources() async throws {
        // Intent: stress close both during spawn and concurrently with resize,
        //   then compare the process fd census and owner lifetimes.
        // Why it exists: cancellation races can strand a spawn result, dispatch
        //   source, master descriptor, child owner, or callback after teardown.
        // Scenario: panes are opened and immediately discarded as a user rapidly
        //   creates, resizes, and closes terminal splits.
        let warmup = try makeHost(captureTransitions: false)
        await warmup.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        await warmup.close()
        #expect((await warmup.resourceSnapshot()).isReleased)
        let descriptorsBefore = try openFileDescriptorCount()

        for iteration in 0..<16 {
            weak var releasedHost: TerminalPTYHost?
            do {
                let host = try makeHost(captureTransitions: false)
                releasedHost = host
                await host.start(makeLaunchInput(
                    command: "exec \(try probeExecutable()) hold \"$0\""
                ))
                if iteration.isMultiple(of: 2) {
                    await host.close()
                } else {
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            host.resize(.init(columns: 81 + iteration, rows: 25))
                        }
                        group.addTask { await host.close() }
                    }
                }
                #expect((await host.resourceSnapshot()).isReleased)
            }
            for _ in 0..<40 where releasedHost != nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(releasedHost == nil)
        }

        // The census is process-wide, and other suites in this process open
        // PTYs concurrently in parallel runs: a real leak from this loop
        // persists, neighbor descriptors are transient, so settle briefly.
        var descriptorsAfter = try openFileDescriptorCount()
        for _ in 0..<40 where descriptorsAfter > descriptorsBefore {
            try await Task.sleep(for: .milliseconds(50))
            descriptorsAfter = try openFileDescriptorCount()
        }
        #expect(descriptorsAfter <= descriptorsBefore)
    }

    @Test("application termination remains bounded with stalled input and chatty output", .timeLimit(.minutes(1)))
    func applicationTerminationClosesMultipleLivePanes() async throws {
        // Intent: orderly app termination applies pane teardown concurrently and
        //   is not monopolized by either write backpressure or continuous reads.
        // Why it exists: a blocking write or unbounded read turn can starve the
        //   owner's grace timers and make application shutdown unbounded.
        // Scenario: one pane has a multi-megabyte write queued to a child that
        //   never reads, one writes forever, and a third is an ordinary live pane.
        let stalled = try makeHost(captureTransitions: false)
        let chatty = try makeHost(captureTransitions: false)
        let ordinary = try makeHost(captureTransitions: false)
        await stalled.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) stalled \"$0\""
        ))
        await chatty.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) chatty \"$0\""
        ))
        await ordinary.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        for host in [stalled, chatty, ordinary] {
            #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        }

        stalled.send([UInt8](repeating: 65, count: 4 * 1024 * 1024))
        #expect((await stalled.resourceSnapshot()).pendingInputByteCount > 0)

        let clock = ContinuousClock()
        let start = clock.now
        await withTaskGroup(of: Void.self) { group in
            for host in [stalled, chatty, ordinary] {
                group.addTask { await host.terminateForApplicationExit() }
            }
        }
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(3))
        for host in [stalled, chatty, ordinary] {
            #expect((await host.resourceSnapshot()).isReleased)
        }
    }

    @Test("user-authored command input reaches the interactive login shell exactly once", .timeLimit(.minutes(1)))
    func initialInputSeamPreservesBytes() async throws {
        // Intent: prove the app-facing command variants become one byte-exact
        //   owner write to the ordinary login shell, including newline handling.
        // Why it exists: facade wiring can otherwise drop, duplicate, direct-exec,
        //   or mutate restore input even when the pure launch policy is correct.
        // Scenario: both command seams run through a real PTY and controlled shell command.
        let probe = try probeExecutable()
        let cases = [
            InitialInputCase(
                name: "launch",
                command: "exec \(probe) initial launch",
                source: .launchCommand,
                expectedWrite: "exec \(probe) initial launch\n"
            ),
            InitialInputCase(
                name: "launch-newline",
                command: "exec \(probe) initial launch-newline\n",
                source: .launchCommand,
                expectedWrite: "exec \(probe) initial launch-newline\n"
            ),
            InitialInputCase(
                name: "command",
                command: "exec \(probe) initial command",
                source: .command,
                expectedWrite: "exec \(probe) initial command\n"
            ),
        ]

        for testCase in cases {
            let host = try makeHost()
            var input = makeLaunchInput(command: "")
            input.launchCommand = nil
            switch testCase.source {
            case .launchCommand:
                input.launchCommand = testCase.command
            case .command:
                input.command = testCase.command
            }

            await host.start(input)
            #expect(await host.waitForResult() == .exited(.exited(0)))
            #expect(await host.inputWrites() == [Array(testCase.expectedWrite.utf8)])

            let output = String(decoding: await host.outputBytes(), as: UTF8.self)
            #expect(output.components(separatedBy: "__INITIAL_EXECUTED__=").count - 1 == 1)
            #expect(output.contains("__INITIAL_EXECUTED__=\(testCase.name)"))
            #expect((await host.resourceSnapshot()).isReleased)
        }
    }

    @Test("primary wheel intent scrolls locally without writing child bytes", .timeLimit(.minutes(1)))
    func primaryWheelRoutesLocally() async throws {
        // Intent: route a wheel step using the authoritative screen selected on the host queue.
        // Why it exists: deciding from a lagging session snapshot can emit arrows on primary.
        // Scenario: the user wheels upward through retained shell output while the child waits.
        let host = try makeHost()
        await host.start(makeLaunchInput(command: try scrollbackCommand()))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let writeBaseline = await host.inputWrites().count

        host.sendWheel(.init(rowDelta: -3, column: 0, row: 0))
        let snapshot = host.fencedSnapshot()

        #expect(snapshot.scrollProjection.isFollowing == false)
        #expect(snapshot.scrollProjection.topRow == snapshot.scrollbackRowCount - 3)
        #expect(await host.inputWrites().count == writeBaseline)

        await host.close()
        host.scrollToBottom()
        _ = host.fencedSnapshot()
        #expect((await host.resourceSnapshot()).isReleased)
    }

    @Test("alternate wheel intent writes counted arrows without local navigation", .timeLimit(.minutes(1)))
    func alternateWheelRoutesToChild() async throws {
        // Intent: select the alternate-screen arrow arm exactly once on the owner queue.
        // Why it exists: wheel routing outside the owner can swallow input during a 1049 race.
        // Scenario: the user wheels upward three rows while a full-screen application is active.
        let host = try makeHost()
        let command = "printf '\\033[?1h\\033[?1049h'; exec \(try probeExecutable()) hold \"$0\""
        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let writeBaseline = await host.inputWrites().count
        let up = [UInt8]([0x1B, 0x4F, 0x41])

        host.sendWheel(.init(rowDelta: -3, column: 0, row: 0))
        let snapshot = host.fencedSnapshot()
        let writes = await host.inputWrites()

        #expect(snapshot.isAlternateScreenActive)
        #expect(snapshot.scrollProjection.isFollowing)
        #expect(Array(writes.dropFirst(writeBaseline)) == [up + up + up])

        await host.close()
    }

    @Test("owner encodes key paste and focus from modes applied by earlier output", .timeLimit(.minutes(1)))
    func semanticInputUsesAuthoritativeModes() async throws {
        // Intent: read child-controlled modes, encode semantic input, and write it in one owner turn.
        // Why it exists: a controller-side mode mirror can lag immediately after a child mode change.
        // Scenario: a TUI enables DECCKM, bracketed paste, and focus reporting before accepting input.
        let host = try makeHost()
        let command = "stty -echo; printf '\\033[?1h\\033[?2004h\\033[?1004h'; exec \(try probeExecutable()) hold \"$0\""
        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let baseline = await host.inputWrites().count
        let snapshotBeforeFocus = await host.snapshot()

        host.sendKey(.up, modifiers: [])
        host.sendPaste("one\ntwo")
        host.sendFocus(true)
        _ = host.fencedSnapshot()

        #expect(Array((await host.inputWrites()).dropFirst(baseline)) == [
            Array("\u{1B}OA".utf8),
            Array("\u{1B}[200~one\ntwo\u{1B}[201~".utf8),
            Array("\u{1B}[I".utf8),
        ])
        #expect(await host.snapshot() == snapshotBeforeFocus)
        await host.close()
    }

    @Test("empty safe paste and focus preserve a browsing viewport", .timeLimit(.minutes(1)))
    func nonScrollingSemanticInputPreservesViewport() async throws {
        let host = try makeHost()
        await host.start(makeLaunchInput(command: try scrollbackCommand(disableEcho: true)))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        host.scroll(byRows: -3)
        let browsing = host.fencedSnapshot()
        let baseline = await host.inputWrites().count

        host.sendPaste("\u{1B}\u{7F}\u{0080}")
        host.sendFocus(true)
        _ = host.fencedSnapshot()

        #expect(await host.inputWrites().count == baseline)
        #expect((await host.snapshot()).scrollProjection == browsing.scrollProjection)

        host.sendPaste("safe")
        #expect(host.fencedSnapshot().scrollProjection.isFollowing)
        await host.close()
    }

    @Test("semantic input capture records normalized events in owner order", .timeLimit(.minutes(1)))
    func semanticInputCaptureOrder() async throws {
        let host = try makeHost()
        await host.start(makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\""))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        host.sendKey(.f5, modifiers: [.shift])
        host.sendPaste("paste")
        host.sendFocus(false)
        _ = host.fencedSnapshot()

        let events = (await host.transitions()).map(\.recordingEvent)
        #expect(events.contains(.input(key: .f5, modifiers: [.shift])))
        #expect(events.contains(.paste("paste")))
        #expect(events.contains(.focus(false)))
        await host.close()
    }

    @Test("wheel races with 1049 transitions use exactly the screen seen by the owner", .timeLimit(.minutes(1)))
    func wheelTransitionRaceUsesOwnerScreen() async throws {
        // Intent: prove both race directions resolve on the shared FIFO instead of a caller snapshot.
        // Why it exists: a primary-to-alt race can leak arrows, while alt-to-primary can swallow them.
        // Scenario: wheel intent is queued immediately after commands that enter and leave alt screen.
        let host = try makeHost()
        let command = "i=0; while [ $i -lt 40 ]; do printf 'line-%s\\n' \"$i\"; i=$((i+1)); done"
        await host.start(makeLaunchInput(command: command))
        while host.fencedSnapshot().fullHistoryText.contains("line-39") == false {
            await Task.yield()
        }
        let down = [UInt8]([0x1B, 0x5B, 0x42])

        let enter = Array("printf '\\033[?1049h'\n".utf8)
        let enterWriteBaseline = await host.inputWrites().count
        host.send(enter)
        host.sendWheel(.init(rowDelta: -1, column: 0, row: 0))
        _ = host.fencedSnapshot()
        #expect(Array((await host.inputWrites()).dropFirst(enterWriteBaseline)) == [enter])
        #expect((await host.transitions()).contains(.scrollByRows(-1)))
        while host.fencedSnapshot().isAlternateScreenActive == false {
            await Task.yield()
        }

        let exit = Array("printf '\\033[?1049l'\n".utf8)
        let exitWriteBaseline = await host.inputWrites().count
        host.send(exit)
        host.sendWheel(.init(rowDelta: 2, column: 0, row: 0))
        _ = host.fencedSnapshot()
        #expect(Array((await host.inputWrites()).dropFirst(exitWriteBaseline)) == [
            exit,
            down + down,
        ])
        while host.fencedSnapshot().isAlternateScreenActive {
            await Task.yield()
        }

        await host.close()
    }

    @Test("captured SGR pointer reports use modes already applied by child output", .timeLimit(.minutes(1)))
    func capturedPointerUsesAuthoritativeModes() async throws {
        // Intent: decide and encode pointer input from the terminal modes on the owner FIFO.
        // Why it exists: mode lookup outside the owner can race child DECSET output.
        // Scenario: a child enables click tracking and SGR encoding before the user clicks.
        let host = try makeHost()
        let command = "printf '\\033[?1000;1006h'; exec \(try probeExecutable()) hold \"$0\""
        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let baseline = await host.inputWrites().count

        host.sendPointer(.down(.left, column: 4, row: 2))
        host.sendPointer(.up(.left, column: 4, row: 2))
        _ = host.fencedSnapshot()

        #expect(Array((await host.inputWrites()).dropFirst(baseline)) == [
            Array("\u{1B}[<0;5;3M".utf8),
            Array("\u{1B}[<0;5;3m".utf8),
        ])
        await host.close()
    }

    @Test("Shift drag selects locally while captured and replays exactly", .timeLimit(.minutes(1)))
    func capturedShiftSelectionReplays() async throws {
        let host = try makeHost()
        let command = "printf '\\033[?1000;1006halpha beta'; exec \(try probeExecutable()) hold \"$0\""
        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let baseline = await host.inputWrites().count
        let lines = host.fencedSnapshot().viewportText
            .split(separator: "\n", omittingEmptySubsequences: false)
        let row = try #require(lines.firstIndex(where: { $0.contains("alpha beta") }))
        let alpha = try #require(lines[row].range(of: "alpha"))
        let column = lines[row].distance(from: lines[row].startIndex, to: alpha.lowerBound)

        host.sendPointer(.down(
            .left,
            column: column,
            row: row,
            modifiers: [.shift]
        ))
        host.sendPointer(.move(column: column + 4, row: row, modifiers: [.shift]))
        host.sendPointer(.up(.left, column: column + 4, row: row, modifiers: [.shift]))
        let snapshot = host.fencedSnapshot()
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "captured-shift-selection"),
            initial: .init(columns: 80, rows: 24),
            events: (await host.transitions()).map(\.recordingEvent)
        )

        #expect(snapshot.selectedText == "alpha")
        #expect(await host.inputWrites().count == baseline)
        #expect(try recording.replay() == snapshot)
        await host.close()
    }

    @Test("captured and Shift wheel routes preserve a browsing viewport", .timeLimit(.minutes(1)))
    func wheelRoutesPreserveBrowsing() async throws {
        let host = try makeHost()
        let command = "i=0; while [ $i -lt 40 ]; do printf 'line-%s\\n' \"$i\"; i=$((i+1)); done; printf '\\033[?1000;1006h'; exec \(try probeExecutable()) hold \"$0\""
        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        host.scroll(byRows: -3)
        let browsing = host.fencedSnapshot().scrollProjection
        let baseline = await host.inputWrites().count

        host.sendWheel(.init(rowDelta: -1, column: 2, row: 3))
        _ = host.fencedSnapshot()
        #expect(Array((await host.inputWrites()).dropFirst(baseline)) == [
            Array("\u{1B}[<64;3;4M".utf8),
        ])
        #expect(host.fencedSnapshot().scrollProjection == browsing)

        let reportCount = await host.inputWrites().count
        host.sendWheel(.init(rowDelta: -1, column: 2, row: 3, modifiers: [.shift]))
        let shifted = host.fencedSnapshot().scrollProjection
        #expect(await host.inputWrites().count == reportCount)
        #expect(shifted.topRow == browsing.topRow - 1)
        #expect(shifted.isFollowing == false)
        await host.close()
    }

    @Test("uncaptured pane menu is returned only after right-button release", .timeLimit(.minutes(1)))
    func paneMenuWaitsForRelease() async throws {
        let host = try makeHost()
        await host.start(makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\""))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let menus = AsyncStream<TerminalViewportCell>.makeStream()
        var iterator = menus.stream.makeAsyncIterator()

        host.sendPointer(.down(.right, column: 9, row: 4)) { cell in
            _ = menus.continuation.yield(cell)
        }
        _ = host.fencedSnapshot()
        host.sendPointer(.up(.right, column: 9, row: 4)) { cell in
            _ = menus.continuation.yield(cell)
        }

        #expect(await iterator.next() == .init(column: 9, row: 4))
        await host.close()
    }

    @Test("user input snaps browsing to bottom and capture replays the transition", .timeLimit(.minutes(1)))
    func userInputSnapCaptureEquality() async throws {
        // Intent: record the local snap before the user write without classifying replies as input.
        // Why it exists: a non-echoing child cannot reconstruct this viewport mutation from output.
        // Scenario: the user scrolls up, types into a waiting process, and captures the pane.
        let host = try makeHost()
        await host.start(makeLaunchInput(command: try scrollbackCommand(disableEcho: true)))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        host.scroll(byRows: -4)
        #expect(host.fencedSnapshot().scrollProjection.isFollowing == false)

        host.send(Array("typed".utf8))
        let transitions = await host.transitions()
        let snapshot = host.fencedSnapshot()
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "input-snap"),
            initial: .init(columns: 80, rows: 24),
            events: transitions.map(\.recordingEvent)
        )

        #expect(snapshot.scrollProjection.isFollowing)
        #expect(transitions.contains(.scrollToBottom))
        #expect(try recording.replay() == snapshot)

        await host.close()
    }

    @Test("scrollbar commands clamp on the owner queue and emit updates only for changes", .timeLimit(.minutes(1)))
    func ownerScrollbarCommandsClampAndDedupe() async throws {
        let host = try makeHost(captureTransitions: false)
        await host.start(makeLaunchInput(command: try scrollbackCommand()))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let baseline = (await host.resourceSnapshot()).emittedUpdateSignalCount
        let writeBaseline = await host.inputWrites().count

        host.scroll(toTopRow: -100)
        let top = host.fencedSnapshot()
        let afterChange = (await host.resourceSnapshot()).emittedUpdateSignalCount
        host.scroll(toTopRow: -100)
        _ = host.fencedSnapshot()

        #expect(top.scrollProjection.topRow == 0)
        #expect(top.scrollProjection.isFollowing == false)
        #expect(afterChange == baseline + 1)
        #expect((await host.resourceSnapshot()).emittedUpdateSignalCount == afterChange)
        #expect(await host.inputWrites().count == writeBaseline)

        host.scrollToBottom()
        #expect(host.fencedSnapshot().scrollProjection.isFollowing)
        await host.close()
    }

    @Test("cancelled result and output waits resume promptly without teardown", .timeLimit(.minutes(1)))
    func cancelledWaitsResumePromptly() async throws {
        // Intent: cancelling a task suspended in waitForResult/waitForOutput
        //   resumes it promptly (nil/false) while the pane keeps running.
        // Why it exists: these waits used bare checked continuations that ignore
        //   cancellation, so a timed-out Swift Testing test never unwound and the
        //   whole suite sat idle forever holding the PTY.
        // Scenario: the 2026-07-22 stress run where launchRecipeAndDuplexIO hit
        //   its 60s time limit yet the run had to be killed by hand.
        let host = try makeHost(captureTransitions: false)
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        let resultTask = Task { await host.waitForResult() }
        let outputTask = Task { await host.waitForOutput(containing: Array("__NEVER__".utf8)) }
        try await Task.sleep(for: .milliseconds(50))
        resultTask.cancel()
        outputTask.cancel()

        let cancelledResult = await value(of: resultTask, withinMilliseconds: 2000)
        let cancelledOutput = await value(of: outputTask, withinMilliseconds: 2000)
        #expect(cancelledResult == .some(nil))
        #expect(cancelledOutput == false)

        // A wait born already-cancelled must not register a stranded waiter.
        let bornCancelled = Task { await host.waitForResult() }
        bornCancelled.cancel()
        #expect(await value(of: bornCancelled, withinMilliseconds: 2000) == .some(nil))

        await host.close()
        #expect((await host.resourceSnapshot()).isReleased)
    }

    @Test("child exit report survives a transient waitid race", .timeLimit(.minutes(1)))
    func childExitReportSurvivesTransientWaitidRace() async throws {
        // Intent: a NOTE_EXIT delivered before the child's wait status is
        //   readable still converges to a reported result and full teardown.
        // Why it exists: childExited() dropped the one-shot exit notification
        //   whenever waitid transiently returned si_pid == 0, wedging
        //   waitForResult() and close() forever.
        // Scenario: the 2026-07-22 parallel stress-run hang; the lifecycle trace
        //   showed "processSourceFired" then "waitid rc=0 errno=0 si_pid=0" and
        //   no further child events.
        let host = try makeHost(captureTransitions: false)
        await host.injectTransientChildWaits(3)
        await host.start(makeLaunchInput(command: "printf '__READY__\\n'; exit 7"))

        let result = await value(
            of: Task { await host.waitForResult() },
            withinMilliseconds: 5000
        )
        #expect(result == .exited(.exited(7)))

        let closed = await value(
            of: Task { await host.close() },
            withinMilliseconds: 5000
        )
        #expect(closed != nil)
        #expect((await host.resourceSnapshot()).isReleased)
    }
}

/// Awaits the task's value but gives up after the bound, returning nil on
/// timeout WITHOUT requiring the awaited task to finish: pre-fix regressions
/// suspend forever, and the census helper must stay bounded regardless.
private func value<T: Sendable>(
    of task: Task<T, Never>,
    withinMilliseconds bound: Int
) async -> T? {
    let completions = AsyncStream<T> { continuation in
        Task {
            continuation.yield(await task.value)
            continuation.finish()
        }
    }
    return await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await completed in completions { return completed }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(bound))
            return nil
        }
        defer { group.cancelAll() }
        return await group.next() ?? nil
    }
}

private extension TerminalPTYAppliedTransition {
    var recordingEvent: NeutralTerminalRecordingEvent {
        switch self {
        case .feed(let bytes): .feed(bytes)
        case .input(let key, let modifiers): .input(key: key, modifiers: modifiers)
        case .paste(let text): .paste(text)
        case .focus(let focused): .focus(focused)
        case .mouse(let event): .mouse(event.neutralEvent)
        case .resize(let dimensions):
            .resize(columns: dimensions.columns, rows: dimensions.rows)
        case .scrollByRows(let rows): .viewport(.byRows(rows))
        case .scrollToTopRow(let row): .viewport(.toTopRow(row))
        case .scrollToBottom: .viewport(.toBottom)
        }
    }
}

private extension TerminalPointerEvent {
    var neutralEvent: NeutralTerminalMouseEvent {
        switch self {
        case let .down(button, column, row, modifiers, clickCount):
            .init(
                action: .down,
                button: button.rawValue + 1,
                column: column,
                row: row,
                modifiers: modifiers,
                clickCount: clickCount
            )
        case let .up(button, column, row, modifiers):
            .init(
                action: .up,
                button: button.rawValue + 1,
                column: column,
                row: row,
                modifiers: modifiers
            )
        case let .move(column, row, modifiers):
            .init(action: .move, column: column, row: row, modifiers: modifiers)
        }
    }
}

private func scrollbackCommand(disableEcho: Bool = false) throws -> String {
    let echoPolicy = disableEcho ? "stty -echo; " : ""
    return "i=0; while [ $i -lt 40 ]; do printf 'line-%s\\n' \"$i\"; i=$((i+1)); done; \(echoPolicy)exec \(try probeExecutable()) hold \"$0\""
}

private func makeHost(captureTransitions: Bool = true) throws -> TerminalPTYHost {
    try TerminalPTYHost(
        initialDimensions: .init(columns: 80, rows: 24),
        bootstrapExecutable: bootstrapExecutable(),
        captureTransitions: captureTransitions
    )
}

private func makeLaunchInput(command: String) -> LaunchPolicyInput {
    LaunchPolicyInput(
        accountShell: "/definitely/missing",
        executablePaths: ["/bin/sh"],
        requestedWorkingDirectory: "/definitely/missing",
        homeDirectory: "/",
        accessibleDirectories: ["/"],
        inheritedEnvironment: [
            EnvironmentEntry(name: "PATH", value: "/usr/bin:/bin"),
            EnvironmentEntry(name: "DANTERM_PROBE", value: "inherited"),
        ],
        advertisedEnvironment: [
            EnvironmentEntry(name: "TERM", value: "xterm-256color"),
            EnvironmentEntry(name: "DANTERM_PROBE", value: "advertised"),
        ],
        paneEnvironment: [EnvironmentEntry(name: "DANTERM_PROBE", value: "pane-wins")],
        command: nil,
        launchCommand: command,
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

private func taggedInt(_ tag: String, in output: String) throws -> Int {
    let value = output.split(whereSeparator: \.isNewline).lazy.compactMap { line -> Int? in
        guard line.hasPrefix("\(tag)=") else { return nil }
        return Int(line.dropFirst(tag.count + 1))
    }.first
    return try #require(value)
}

private func taggedValue(_ tag: String, in output: String) throws -> Substring {
    let line = try #require(output.split(whereSeparator: \.isNewline).first {
        $0.hasPrefix("\(tag)=")
    })
    return line.dropFirst(tag.count + 1)
}

private enum InitialInputSource: Equatable {
    case launchCommand
    case command
}

private struct InitialInputCase {
    let name: String
    let command: String
    let source: InitialInputSource
    let expectedWrite: String
}

private func processExists(_ processID: Int) -> Bool {
    errno = 0
    return kill(pid_t(processID), 0) == 0 || errno == EPERM
}

private func openFileDescriptorCount() throws -> Int {
    let requiredBytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    guard requiredBytes > 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    var bytes = [UInt8](
        repeating: 0,
        count: Int(requiredBytes) + 16 * MemoryLayout<proc_fdinfo>.stride
    )
    let receivedBytes = bytes.withUnsafeMutableBytes { buffer in
        proc_pidinfo(
            getpid(),
            PROC_PIDLISTFDS,
            0,
            buffer.baseAddress,
            Int32(buffer.count)
        )
    }
    guard receivedBytes >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return Int(receivedBytes) / MemoryLayout<proc_fdinfo>.stride
}
