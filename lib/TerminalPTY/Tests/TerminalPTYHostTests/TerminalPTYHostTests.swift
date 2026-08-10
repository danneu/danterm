// Real-system PTY tests for launch ownership, ordered IO, resize, and exit convergence.
import Darwin
import Foundation
import Testing
@testable import TerminalPTYHost
import TerminalPTYTestSupport
import PaneProcessLifecycle
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

    @Test("consumption fence pairs final frame damage with exit metadata", .timeLimit(.minutes(1)))
    func consumptionFencePairsFrameAndExitMetadata() async throws {
        // Intent: one synchronous consumer read returns terminal damage, lifecycle
        //   result, and captured transitions from the same owner-queue boundary.
        // Why it exists: reading lifecycle metadata and frame state through separate
        //   fences both undercounted benchmark stall time and allowed intervening owner
        //   work to make the values describe different moments.
        // Scenario: a child prints its final frame and exits; the pane consumes the
        //   redraw and exit evidence together before publishing the session end.
        let host = try makeHost(captureTransitions: true)
        _ = host.fencedFrameState()
        await host.start(makeLaunchInput(command: "printf '__FINAL_FRAME__'; exit 7"))
        #expect(await host.waitForResult() == .exited(.exited(7)))

        let consumption = host.fencedConsumptionState()

        #expect(consumption.frameState.damage != .none)
        #expect(consumption.frameState.terminal.screenText.contains("__FINAL_FRAME__"))
        #expect(consumption.result == .exited(.exited(7)))
        #expect(consumption.transitions?.contains {
            if case let .feed(bytes) = $0 {
                return String(decoding: bytes, as: UTF8.self).contains("__FINAL_FRAME__")
            }
            return false
        } == true)
        await host.close()
    }

    @Test("OSC 52 wakes and drains once without sending query data to the child", .timeLimit(.minutes(1)))
    func clipboardWriteFrameStateAndReadDenial() async throws {
        // Intent: owner framing drains completed clipboard writes independently from replies.
        // Why it exists: grid-silent effects need a wakeup, while reads must never expose clipboard data.
        // Scenario: a child writes OSC 52, asks to read it, and remains alive for inspection.
        let host = try makeHost()
        _ = host.fencedFrameState()
        let command = "\(printMarker("READY", newline: false)); sleep 0.1; printf '\\033]52;c;aGVsbG8=\\007\\033]52;c;?\\007'; exec sleep 30"
        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        _ = host.fencedFrameState()

        var clipboardWrite: String?
        for await _ in host.updates {
            let state = host.fencedFrameState()
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

    @Test(
        "a burst behind a held owner applies only the newest grid to terminal and child",
        .timeLimit(.minutes(1))
    )
    func supersededResizesSkipBothWinsizeAndReflow() async throws {
        // Intent: when several grids are submitted with no other action between
        //   them, every one but the newest applies neither its `TIOCSWINSZ` nor
        //   its reflow, and the newest applies both.
        // Why it exists: a drag enqueues one full reflow per column crossed, so
        //   the pane trails the window by seconds and the child is told forty
        //   sizes. The verdict has to be deterministic rather than "fewer than
        //   submitted", which a fix that drops one of forty would also satisfy.
        // Scenario: the owner is held inside a pane-menu callback while a drag's
        //   worth of grids arrives, then released -- the shape of a real drag on
        //   a pane whose reflow is slower than mouse-move arrival.
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) resize \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let baseline = await host.transitions().count

        let owner = OwnerHold()
        owner.hold(host)
        for grid in [(84, 25), (88, 26), (92, 27), (96, 28)] {
            host.resize(.init(columns: grid.0, rows: grid.1))
        }
        host.resize(.init(columns: 100, rows: 31))
        owner.release()

        let applied = (await host.transitions()).dropFirst(baseline).filter {
            if case .resize = $0 { true } else { false }
        }
        #expect(applied == [.resize(.init(columns: 100, rows: 31))])
        #expect(await host.waitForOutput(containing: Array("__WINCH__=31 100".utf8)))
        let snapshot = await host.snapshot()
        #expect(snapshot.geometry.columns == 100)
        #expect(snapshot.geometry.rows.count == 31)

        host.send(Array("done\n".utf8))
        #expect(await host.waitForResult() == .exited(.exited(0)))
    }

    @Test(
        "a pointer between two resizes closes the run and observes the earlier grid",
        .timeLimit(.minutes(1))
    )
    func nonResizeSubmissionClosesTheCoalescingRun() async throws {
        // Intent: coalescing never reaches across a non-resize submission, so
        //   the pointer still sees the grid of the last resize submitted before
        //   it and both surrounding resizes apply.
        // Why it exists: pointer hit-testing reads the grid, so a resize that
        //   the coalescer skipped because a later one was already queued would
        //   silently move where a click lands -- the host's joint FIFO order
        //   promises geometry that a run-wide skip would break.
        // Scenario: a drag interrupted by a click, with the click's viewport
        //   row 0 resolving against the taller grid submitted just before it.
        let host = try makeHost()
        await host.start(makeLaunchInput(command: try scrollbackCommand()))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        host.resize(.init(columns: 80, rows: 30))
        let tallTopLine = topViewportLine(host.fencedSnapshot())
        host.resize(.init(columns: 80, rows: 10))
        let shortTopLine = topViewportLine(host.fencedSnapshot())
        try #require(tallTopLine.isEmpty == false)
        try #require(tallTopLine != shortTopLine)
        let baseline = await host.transitions().count

        let owner = OwnerHold()
        owner.hold(host)
        host.resize(.init(columns: 80, rows: 30))
        host.sendPointer(.down(.left, column: 2, row: 0, clickCount: 3))
        host.resize(.init(columns: 80, rows: 10))
        owner.release()

        let snapshot = host.fencedSnapshot()
        let ordered = (await host.transitions()).dropFirst(baseline).filter { transition in
            switch transition {
            case .resize: true
            case .mouse(.down(.left, _, _, _, _, _)): true
            default: false
            }
        }
        #expect(ordered == [
            .resize(.init(columns: 80, rows: 30)),
            .mouse(.down(.left, column: 2, row: 0, clickCount: 3)),
            .resize(.init(columns: 80, rows: 10)),
        ])
        #expect(
            snapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) == tallTopLine
        )
        #expect(snapshot.geometry.rows.count == 10)
        await host.close()
    }

    @Test("a resize with nothing behind it applies without a settle delay", .timeLimit(.minutes(1)))
    func loneResizeAppliesWithoutWaiting() async throws {
        // Intent: coalescing costs a lone resize nothing -- the grid is applied
        //   by the time the next owner-queue fence returns.
        // Why it exists: the rejected debounce alternative would have made every
        //   settled resize wait out a timer, and nothing else in this suite fails
        //   if a delay is added rather than a submission dropped.
        let host = try makeHost()
        await host.start(makeLaunchInput(command: "exec \(try probeExecutable()) hold \"$0\""))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        host.resize(.init(columns: 100, rows: 31))
        let snapshot = host.fencedSnapshot()

        #expect(snapshot.geometry.columns == 100)
        #expect(snapshot.geometry.rows.count == 31)
        await host.close()
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
        var observedResult: PaneProcessLifecycleResult?
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

    @Test("OSC default-color replies reach a real PTY child", .timeLimit(.minutes(1)))
    func defaultColorRepliesReachChild() async throws {
        // Intent: route both baked default-color replies through the production PTY write path.
        // Why it exists: pure core reply tests cannot prove the serialized host writes OSC replies
        //   back to the child or preserves the two replies as one ordered response stream.
        // Scenario: a child probes foreground and background before choosing its UI colors.
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) color-query \"$0\""
        ))

        let result = await host.waitForResult()
        let output = String(decoding: await host.outputBytes(), as: UTF8.self)
        #expect(result == .exited(.exited(0)), "result: \(String(describing: result))")
        #expect(output.contains("__COLOR_QUERY_OK__"), "output: \(output.debugDescription)")
        let replies = await host.replyWrites()
        #expect(replies.flatMap { $0 } == Array(
            ("\u{1B}]10;rgb:e5e5/e5e5/e5e5\u{1B}\\"
                + "\u{1B}]11;rgb:0000/0000/0000\u{1B}\\").utf8
        ))
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

        #expect(try recording.replay(machineHostname: MachineHostname.posix) == (await host.snapshot()))
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
        // Bounded rather than immediate for the same reason as the teardown ladder: the
        // descendant dies when its write fails, and the reparented corpse is reaped by
        // launchd on its own schedule, so `kill(pid, 0)` keeps succeeding for a moment.
        #expect(await waitForProcessExit(descendant))
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

        #expect(try decoded.replay(machineHostname: MachineHostname.posix) == (await host.snapshot()))
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

    @Test("live flight recording preserves PTY chunk boundaries and resize order", .timeLimit(.minutes(1)))
    func liveFlightRecordingRoundTrip() async throws {
        let host = try TerminalPTYHost(
            initialDimensions: .init(columns: 80, rows: 24),
            bootstrapExecutable: bootstrapExecutable(),
            machineHostname: MachineHostname.posix,
            recordsFlightTape: true
        )
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) recording \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__BEFORE_RESIZE__".utf8)))
        host.resize(.init(columns: 96, rows: 28))
        host.send(Array("continue\n".utf8))
        #expect(await host.waitForResult() == .exited(.exited(0)))

        let snapshot = try #require(host.fencedFlightRecording())
        let fromNow = try #require(host.fencedFlightRecordingOriginFromNow())
        let liveSuffix = try #require(host.fencedFlightRecording(from: fromNow.cursor))
        let recording = try JSONDecoder().decode(
            NeutralTerminalRecording.self,
            from: snapshot.encodedRecording()
        )
        let resizeIndex = try #require(snapshot.events.firstIndex {
            if case .resize = $0.event { true } else { false }
        })

        #expect(try recording.replay(machineHostname: MachineHostname.posix) == (await host.snapshot()))
        #expect(recording.events == snapshot.events.map(\.event))
        #expect(snapshot.events[..<resizeIndex].contains {
            if case .feed = $0.event { true } else { false }
        })
        #expect(snapshot.events[(resizeIndex + 1)...].contains {
            if case .feed = $0.event { true } else { false }
        })
        #expect(zip(snapshot.events, snapshot.events.dropFirst()).allSatisfy {
            $0.elapsedNanoseconds <= $1.elapsedNanoseconds
        })
        #expect(fromNow.initial == .init(columns: 96, rows: 28))
        #expect(fromNow.cursor.nextSequence == snapshot.events.last.map { $0.sequence + 1 })
        #expect(liveSuffix.events.isEmpty)
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
            #expect(
                await waitForProcessExit(pid),
                "Owned process \(pid) survived pane close"
            )
        }
        // Immediate on purpose: the claim is that the sibling was never signalled, and a
        // bounded wait for something that must still be alive would only hide the opposite.
        #expect(processExists(siblingPID))
        #expect((await host.resourceSnapshot()).isReleased)

        await sibling.close()
        #expect(await waitForProcessExit(siblingPID))
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
        let warmupSnapshot = await warmup.resourceSnapshot()
        #expect(warmupSnapshot.isReleased)
        #expect(warmupSnapshot.forcedQuiescenceCount == 0)
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
                let snapshot = await host.resourceSnapshot()
                #expect(snapshot.isReleased)
                #expect(snapshot.forcedQuiescenceCount == 0)
            }
            for _ in 0..<40 where releasedHost != nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(releasedHost == nil)
        }

        // The census is process-wide, so it is only valid with the process to
        // itself: scripts/test-terminal-pty.sh skips this test by name in the
        // parallel lane and reruns it solo (update the script if renaming it).
        // The settle loop stays as cheap insurance against fd-table lag.
        var descriptorsAfter = try openFileDescriptorCount()
        for _ in 0..<40 where descriptorsAfter > descriptorsBefore {
            try await Task.sleep(for: .milliseconds(50))
            descriptorsAfter = try openFileDescriptorCount()
        }
        #expect(descriptorsAfter <= descriptorsBefore)
    }

    @Test("close racing a prompt spawn converges inside the real host bound", .timeLimit(.minutes(1)))
    func closeRacingPromptSpawnUsesTeardownLadder() async throws {
        // Intent: a spawn that lands after close starts still completes through
        //   the teardown ladder, reaps its leader, and never needs forced cleanup.
        // Why it exists: a close-while-spawning host does not arm process exit
        //   observation, so the old reducer waited for the full two-second bound.
        // Scenario: a user opens a pane and immediately closes it while the
        //   launch worker is handing its successful spawn back to the owner.
        let host = try makeHost(captureTransitions: false)
        await host.injectSpawnReportDelay(0.05)
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))

        let clock = ContinuousClock()
        let start = clock.now
        await host.close()
        let elapsed = start.duration(to: clock.now)

        let snapshot = await host.resourceSnapshot()
        #expect(elapsed < .seconds(1))
        #expect(snapshot.isReleased)
        #expect(snapshot.forcedQuiescenceCount == 0)

        let leader = try #require(await host.lastLaunchedLeaderPID())
        var status: Int32 = 0
        errno = 0
        #expect(waitpid(leader, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
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
        // Named, because these three fail for different reasons: a bare `host` in the message
        // cannot say which pane never reported liveness. The flooding one is the slow case --
        // its child saturates its own owner queue, so even answering this call waits behind a
        // read turn (measured 0.03s to 2.6s, against under a millisecond for the quiet two).
        //
        // That pane is also waited on by its flood rather than by `__READY__`, because the
        // marker is not a question this test can ask here: the child writes 4 KiB forever
        // the instant it prints it, and all three panes are started before any of them is
        // waited on, so by the time the wait is armed the host has long since discarded it.
        // A full write's worth of the flood byte is evidence no discard can lose, and it is
        // the stronger claim anyway -- what this test needs from this pane is that it is
        // already flooding.
        let ready = Array("__READY__".utf8)
        let flooding = [UInt8](repeating: UInt8(ascii: "c"), count: 4096)
        for (name, host, liveness) in [
            ("stalled", stalled, ready),
            ("chatty", chatty, flooding),
            ("ordinary", ordinary, ready),
        ] {
            #expect(
                await host.waitForOutput(containing: liveness),
                "the \(name) pane never reported liveness"
            )
        }

        stalled.send([UInt8](repeating: 65, count: 4 * 1024 * 1024))
        #expect((await stalled.resourceSnapshot()).pendingInputByteCount > 0)

        let clock = ContinuousClock()
        let start = clock.now
        await withTaskGroup(of: Void.self) { group in
            for host in [stalled, chatty, ordinary] {
                group.addTask { await host.close() }
            }
        }
        let elapsed = start.duration(to: clock.now)

        #expect(elapsed < .seconds(3))
        for host in [stalled, chatty, ordinary] {
            #expect((await host.resourceSnapshot()).isReleased)
        }
    }

    @Test("dispatch-submitted termination releases every pane and signals from its own queue", .timeLimit(.minutes(1)))
    func applicationExitTerminationSignalsFromOwnerQueues() async throws {
        // Intent: submitting termination to a set of live hosts releases every
        //   child and signals one completion per host from that host's own queue.
        // Why it exists: PO2. The exit path has to reach quiescence without
        //   creating a Swift Concurrency job, so the completion has to arrive on
        //   the queue that owns the work rather than through an async hop.
        // Scenario: the user quits with three live panes open.
        let hosts = try (0..<3).map { _ in try makeHost() }
        for host in hosts {
            await host.start(makeLaunchInput(
                command: "exec \(try probeExecutable()) hold \"$0\""
            ))
        }
        var childPIDs: [Int] = []
        for host in hosts {
            #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
            childPIDs.append(try taggedInt(
                "__PID__",
                in: String(decoding: await host.outputBytes(), as: UTF8.self)
            ))
        }

        let recorder = ExitCompletionRecorder(expecting: hosts.count)
        for host in hosts {
            host.requestShutdown { recorder.signal() }
        }
        #expect(recorder.waitForAll(within: .seconds(20)))

        #expect(recorder.queueLabels.count == hosts.count)
        #expect(recorder.queueLabels.allSatisfy { $0 == hostOwnerQueueLabel })
        for pid in childPIDs {
            #expect(await waitForProcessExit(pid), "pane child \(pid) survived termination")
        }
        for host in hosts {
            let snapshot = await host.resourceSnapshot()
            #expect(snapshot.isReleased)
            #expect(snapshot.forcedQuiescenceCount == 0)
        }
    }

    @Test("a stalled teardown ladder still quiesces inside the host's own bound", .timeLimit(.minutes(1)))
    func applicationExitTerminationForcesQuiescenceWithinBound() async throws {
        // Intent: a host whose ladder cannot converge in time reaches quiescence
        //   anyway, completes, kills the session it owns, and runs nothing after.
        // Why it exists: PO3/I3. A bound that returns while the host's children
        //   are still alive would satisfy the deadline by abandoning ownership,
        //   which is the failure the removed application-level timeout had.
        // Scenario: the pane holds a signal-resistant job tree at quit, and the
        //   ladder's escalation cannot finish before the host's bound expires.
        let host = try makeHost(applicationExitBound: .milliseconds(1))
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) teardown \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let output = String(decoding: await host.outputBytes(), as: UTF8.self)
        let ownedPIDs = try [
            taggedInt("__LEADER__", in: output),
            taggedInt("__FOREGROUND__", in: output),
            taggedInt("__BACKGROUND__", in: output),
            taggedInt("__STOPPED__", in: output),
            taggedInt("__RESISTANT__", in: output),
        ]

        let recorder = ExitCompletionRecorder(expecting: 1)
        host.requestShutdown { recorder.signal() }
        #expect(recorder.waitForAll(within: .seconds(20)))

        for pid in ownedPIDs {
            #expect(await waitForProcessExit(pid), "owned process \(pid) survived the bound")
        }
        // Settles so any source that outlived teardown would have a turn to fire.
        try await Task.sleep(for: .milliseconds(200))
        let snapshot = await host.resourceSnapshot()
        #expect(snapshot.forcedQuiescenceCount == 1)
        #expect(snapshot.isReleased)
    }

    @Test("shutdown completion waits for every source cancellation acknowledgement", .timeLimit(.minutes(1)))
    func shutdownCompletionJoinsDispatchSources() async throws {
        // Intent: shutdown keeps the PTY and child owned until every canceled
        //   Dispatch source has run its cancellation handler.
        // Why it exists: cancel() is only a request; publishing quiescence before
        //   its handler runs lets callbacks and descriptor access outlive teardown.
        // Scenario: application exit pauses source cancellation acknowledgements
        //   while a live pane is closing, then releases the join barrier.
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let pid = try taggedInt(
            "__PID__",
            in: String(decoding: await host.outputBytes(), as: UTF8.self)
        )
        let cancellationReached = ExitCompletionRecorder(expecting: 1)
        await host.holdSourceCancellationAcknowledgements {
            cancellationReached.signal()
        }
        let completion = ExitCompletionRecorder(expecting: 1)

        host.requestShutdown { completion.signal() }
        #expect(cancellationReached.waitForAll(within: .seconds(20)))

        let whileHeld = await host.resourceSnapshot()
        #expect(whileHeld.hasOpenMaster)
        #expect(whileHeld.activeSourceCount > 0)
        #expect(completion.queueLabels.isEmpty)
        #expect(processExists(pid))

        await host.releaseSourceCancellationAcknowledgements()
        #expect(completion.waitForAll(within: .seconds(20)))
        #expect(await waitForProcessExit(pid))
        #expect((await host.resourceSnapshot()).isReleased)
    }

    @Test("forced cleanup starts only after descriptor cancellation joins", .timeLimit(.minutes(1)))
    func forcedShutdownWaitsForDescriptorJoin() async throws {
        // Intent: the forced path leaves the child and master owned until the
        //   descriptor-source barrier opens, then completes the whole cleanup.
        // Why it exists: resuming forced reap from closeMaster() itself can block
        //   before cancellation callbacks run or replay superseded ladder commands.
        // Scenario: application exit forces a live pane while its source
        //   cancellation acknowledgements are deterministically paused.
        let host = try makeHost(
            applicationExitBound: .seconds(30)
        )
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let pid = try taggedInt(
            "__PID__",
            in: String(decoding: await host.outputBytes(), as: UTF8.self)
        )
        let cancellationReached = ExitCompletionRecorder(expecting: 1)
        await host.holdSourceCancellationAcknowledgements {
            cancellationReached.signal()
        }
        let completion = ExitCompletionRecorder(expecting: 1)
        host.requestShutdown { completion.signal() }
        #expect(cancellationReached.waitForAll(within: .seconds(20)))

        await host.forceExitBoundForTesting()
        let beforeJoin = await host.resourceSnapshot()
        #expect(beforeJoin.hasOpenMaster)
        #expect(processExists(pid))
        #expect(completion.queueLabels.isEmpty)

        await host.releaseSourceCancellationAcknowledgements()
        #expect(completion.waitForAll(within: .seconds(20)))
        #expect(await waitForProcessExit(pid))
        let finished = await host.resourceSnapshot()
        #expect(finished.forcedQuiescenceCount == 1)
        #expect(finished.isReleased)
    }

    @Test("input submitted after shutdown sealing cannot rearm descriptor IO", .timeLimit(.minutes(1)))
    func shutdownSealDiscardsQueuedInput() async throws {
        // Intent: a shutdown request permanently prevents later input work from
        //   installing another write source or touching the closing descriptor.
        // Why it exists: queued submissions can otherwise recreate descriptor
        //   ownership after the cancellation census was assumed complete.
        // Scenario: a pane with write backpressure receives another write while
        //   application exit is paused at the source join barrier.
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) stalled \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        host.send([UInt8](repeating: 65, count: 4 * 1024 * 1024))
        let beforeShutdown = await host.resourceSnapshot()
        #expect(beforeShutdown.pendingInputByteCount > 0)
        #expect(beforeShutdown.descriptorSourceCount == 2)

        let cancellationReached = ExitCompletionRecorder(expecting: 1)
        await host.holdSourceCancellationAcknowledgements {
            cancellationReached.signal()
        }
        let completion = ExitCompletionRecorder(expecting: 1)
        host.requestShutdown { completion.signal() }
        host.send(Array("after-shutdown".utf8))
        #expect(cancellationReached.waitForAll(within: .seconds(20)))

        let whileHeld = await host.resourceSnapshot()
        #expect(whileHeld.pendingInputByteCount == 0)
        #expect(whileHeld.descriptorSourceCount == beforeShutdown.descriptorSourceCount)
        #expect(completion.queueLabels.isEmpty)

        await host.releaseSourceCancellationAcknowledgements()
        #expect(completion.waitForAll(within: .seconds(20)))
        #expect((await host.resourceSnapshot()).isReleased)
    }

    @Test("close during spawn activates inactive sources before cancellation", .timeLimit(.minutes(1)))
    func closeDuringSpawnJoinsInactiveSources() async throws {
        // Intent: sources installed before launch adoption can still reach their
        //   cancellation handlers when shutdown wins before activation.
        // Why it exists: canceling a suspended Dispatch source does not make its
        //   cancellation handler runnable until the source is activated.
        // Scenario: a newly opened pane receives Cmd-Q between source installation
        //   and the reducer command that would normally activate PTY IO.
        let host = try makeHost(captureTransitions: false)
        let sourcesInstalled = ExitCompletionRecorder(expecting: 1)
        await host.holdInstalledSourcesBeforeActivation {
            sourcesInstalled.signal()
        }
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(sourcesInstalled.waitForAll(within: .seconds(20)))

        let cancellationReached = ExitCompletionRecorder(expecting: 1)
        await host.holdSourceCancellationAcknowledgements {
            cancellationReached.signal()
        }
        let completion = ExitCompletionRecorder(expecting: 1)
        host.requestShutdown { completion.signal() }
        await host.releaseInstalledSourcesForActivation()
        #expect(cancellationReached.waitForAll(within: .seconds(20)))

        let whileHeld = await host.resourceSnapshot()
        #expect(whileHeld.hasOpenMaster)
        #expect(whileHeld.descriptorSourceCount == 1)
        #expect(completion.queueLabels.isEmpty)

        await host.releaseSourceCancellationAcknowledgements()
        #expect(completion.waitForAll(within: .seconds(20)))
        #expect((await host.resourceSnapshot()).isReleased)
    }

    @Test("joined descriptor sources cannot touch a reused fd number", .timeLimit(.minutes(1)))
    func teardownDoesNotTouchReusedDescriptor() async throws {
        // Intent: after quiescence, reusing the former PTY fd for a pipe leaves
        //   that replacement descriptor open and its bytes untouched.
        // Why it exists: a late source callback or cancellation close keyed only
        //   by fd number can act on an unrelated descriptor after rapid teardown.
        // Scenario: a pane closes and the kernel immediately assigns its master
        //   number to a replacement pipe before any later owner work can run.
        var pipeFDs = [Int32](repeating: -1, count: 2)
        try #require(pipe(&pipeFDs) == 0)
        defer {
            if pipeFDs[0] >= 0 { Darwin.close(pipeFDs[0]) }
            if pipeFDs[1] >= 0 { Darwin.close(pipeFDs[1]) }
        }

        let host = try makeHost(captureTransitions: false)
        await host.installDescriptorReuseProbe(replacementFD: pipeFDs[0])
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        await host.close()

        let reusedFD = try #require(await host.reusedDescriptorForTesting())
        let byte: UInt8 = 0x5A
        #expect(withUnsafeBytes(of: byte) {
            Darwin.write(pipeFDs[1], $0.baseAddress, $0.count)
        } == 1)
        _ = await host.resourceSnapshot()
        var received: UInt8 = 0
        #expect(withUnsafeMutableBytes(of: &received) {
            Darwin.read(reusedFD, $0.baseAddress, $0.count)
        } == 1)
        #expect(received == byte)
        #expect(fcntl(reusedFD, F_GETFD) != -1)

        Darwin.close(reusedFD)
        if reusedFD == pipeFDs[0] {
            pipeFDs[0] = -1
        }
    }

    @Test("terminating an already-quiesced host completes without waiting", .timeLimit(.minutes(1)))
    func applicationExitTerminationOnTornDownHostReturnsImmediately() async throws {
        // Intent: a host that finished teardown before exit reached it completes
        //   at once rather than waiting for a signal that will never come.
        // Why it exists: PO4/I4. The teardown ladder is what produces a
        //   completion, and a host past it will never run one again.
        // Scenario: a pane was closed moments before the user quit.
        // The bound is long on purpose: if this waited on the ladder at all, it
        //   would wait thirty seconds, so the elapsed assertion cannot pass by luck.
        let host = try makeHost(captureTransitions: false, applicationExitBound: .seconds(30))
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        await host.close()
        #expect((await host.resourceSnapshot()).isReleased)

        let recorder = ExitCompletionRecorder(expecting: 1)
        let clock = ContinuousClock()
        let start = clock.now
        host.requestShutdown { recorder.signal() }
        #expect(recorder.waitForAll(within: .seconds(20)))
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect((await host.resourceSnapshot()).forcedQuiescenceCount == 0)
    }

    @Test("quiescence observation neither starts shutdown nor misses later completion", .timeLimit(.minutes(1)))
    func quiescenceObservationDoesNotRequestShutdown() async throws {
        // Intent: whenQuiescent observes host lifetime without changing it, then
        //   fires exactly once after a separate shutdown request.
        // Why it exists: registry ownership must be able to follow natural or
        //   requested teardown without observation itself closing a live pane.
        // Scenario: the backend registers cleanup while a shell is live, and the
        //   pane controller requests close later.
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let pid = try taggedInt(
            "__PID__",
            in: String(decoding: await host.outputBytes(), as: UTF8.self)
        )
        let recorder = ExitCompletionRecorder(expecting: 1)

        host.whenQuiescent { recorder.signal() }
        _ = host.fencedSnapshot()

        #expect(recorder.queueLabels.isEmpty)
        #expect(processExists(pid))

        host.requestShutdown()
        #expect(recorder.waitForAll(within: .seconds(20)))
        #expect(recorder.queueLabels.count == 1)
        #expect(recorder.queueLabels == [hostOwnerQueueLabel])
        #expect(await waitForProcessExit(pid))
    }

    @Test("an observer registered after quiescence runs once on the owner queue", .timeLimit(.minutes(1)))
    func lateQuiescenceObserverRunsImmediately() async throws {
        let host = try makeHost(captureTransitions: false)
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        await host.close()

        let recorder = ExitCompletionRecorder(expecting: 1)
        host.whenQuiescent { recorder.signal() }

        #expect(recorder.waitForAll(within: .seconds(20)))
        #expect(recorder.queueLabels.count == 1)
        #expect(recorder.queueLabels == [hostOwnerQueueLabel])
    }

    @Test("exit during a launch discards the child instead of adopting it", .timeLimit(.minutes(1)))
    func applicationExitTerminationDuringSpawnDiscardsChild() async throws {
        // Intent: when a launch has not reported its child yet at exit, the host
        //   stops that launch and the child is already gone by the time the host
        //   signals completion.
        // Why it exists: PO6/I1/I2. The ladder waits for an in-flight spawn --
        //   until it lands there is no session to signal -- so a slow launch is
        //   exactly what drives a host past its bound. The completion is the
        //   moment the exit path is entitled to let the process die, so anything
        //   still alive then is a child that outlives the app: asserting after the
        //   fact instead would pass on an asynchronous cleanup that a real exit
        //   would never reach.
        // Scenario: the user quits in the moment a freshly opened pane is
        //   launching, and the launch is slow enough to outlast the bound.
        let host = try makeHost(captureTransitions: false, applicationExitBound: .milliseconds(50))
        // Withholds the report that tells the owner queue a child exists, which is
        // the window this test is about. Deliberately many times the host's bound:
        // the host is required to wait it out, because a deadline here could only
        // make quiescence punctual, never true.
        await host.injectSpawnReportDelay(1.0)
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))

        let liveAtCompletion = LockedBox<[pid_t]>([])
        let recorder = ExitCompletionRecorder(expecting: 1)
        host.requestShutdown {
            liveAtCompletion.set(directChildProcessIDs())
            recorder.signal()
        }
        #expect(recorder.waitForAll(within: .seconds(20)))

        // A launch that has still not reported by the time the host says it is
        // quiescent is the failure itself, not an inconclusive run: the child is
        // then born after the exit path was entitled to end the process.
        let launched = try #require(
            await host.lastLaunchedLeaderPID(),
            "the host reported quiescence while its launch was still unresolved"
        )
        // Named rather than counted: sibling suites launch their own children, so a
        // process-wide census cannot tell this pane's child from a neighbor's.
        #expect(
            liveAtCompletion.value.contains(launched) == false,
            "child \(launched) was still alive when the host reported quiescence"
        )
        let atCompletion = await host.resourceSnapshot()
        #expect(atCompletion.isReleased)
        #expect(atCompletion.forcedQuiescenceCount == 1)

        // Nothing arrives afterward either: the launch is not adopted late.
        try await Task.sleep(for: .seconds(1))
        let snapshot = await host.resourceSnapshot()
        #expect(snapshot.isReleased, "the abandoned launch was adopted after teardown")
        #expect(snapshot.callbacksAfterTeardown == 0)
        #expect(directChildProcessIDs().contains(launched) == false)
    }

    @Test("exit claims a resolved spawn before owner delivery", .timeLimit(.minutes(1)))
    func applicationExitTerminationClaimsResolvedSpawn() async throws {
        // Intent: exit cannot complete while a resolved spawn and its live child
        //   are waiting to be delivered to the owner queue.
        // Why it exists: PO6/I2. Resolving the worker before enqueueing its owner
        //   callback creates a second handoff race after the pre-report race.
        // Scenario: a pane finishes launching exactly as the user confirms quit,
        //   but the owner has not adopted the returned PTY yet.
        let host = try makeHost(captureTransitions: false, applicationExitBound: .milliseconds(50))
        await host.injectSpawnDeliveryDelay(1.0)
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))

        for _ in 0..<200 where await host.lastLaunchHasPendingDelivery() == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await host.lastLaunchHasPendingDelivery())

        let liveAtCompletion = LockedBox<[pid_t]>([])
        let recorder = ExitCompletionRecorder(expecting: 1)
        host.requestShutdown {
            liveAtCompletion.set(directChildProcessIDs())
            recorder.signal()
        }
        #expect(recorder.waitForAll(within: .seconds(20)))

        let launched = try #require(await host.lastLaunchedLeaderPID())
        #expect(
            liveAtCompletion.value.contains(launched) == false,
            "resolved child \(launched) was still alive when the host reported quiescence"
        )
        #expect((await host.resourceSnapshot()).isReleased)

        // Let the delayed worker submit its token-gated callback so a failure does
        // not leave this test's child running into the next test. Polled rather than
        // slept: this is a positive wait, and a fixed deadline only has to lose one
        // race against the parallel gate's load to fail a pane that converged.
        #expect(await waitForDirectChildExit(launched))
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

    @Test("Shift extension stays local while captured and replays exactly", .timeLimit(.minutes(1)))
    func capturedShiftSelectionReplays() async throws {
        let host = try makeHost()
        let command = "exec \(try probeExecutable()) hold \"$0\""
        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        host.deliverOutputForTesting(Array("\u{1B}[2J\u{1B}[H\u{1B}[?1000halpha beta".utf8))
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
            modifiers: [.shift],
            clickCount: 2
        ))
        host.sendPointer(.up(.left, column: column, row: row, modifiers: [.shift]))
        // The extending click count maps to line selection on a fresh gesture, but the settled
        // token granularity wins and entering beta includes that token as one unit.
        host.sendPointer(.down(
            .left,
            column: column + 6,
            row: row,
            offsetX: 0.75,
            modifiers: [.shift],
            clickCount: 3
        ))
        host.sendPointer(.up(.left, column: column + 6, row: row, modifiers: [.shift]))
        let snapshot = host.fencedSnapshot()
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "captured-shift-selection"),
            initial: .init(columns: 80, rows: 24),
            events: (await host.transitions()).map(\.recordingEvent)
        )

        #expect(snapshot.selectedText == "alpha beta")
        #expect(snapshot.selectionGranularity == .terminalToken)
        #expect(await host.inputWrites().count == baseline)
        #expect(try recording.replay(machineHostname: MachineHostname.posix) == snapshot)
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
        #expect(try recording.replay(machineHostname: MachineHostname.posix) == snapshot)

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

    @Test("search begin, navigate, and clear publish frames and report status", .timeLimit(.minutes(1)))
    func ownerSearchMutationsPublishAndReportStatus() async throws {
        // Intent: each enqueued search mutation lands on the owner queue, republishes a
        //   frame so the moved highlight redraws, and reports the resulting status.
        // Why it exists: the highlight is planned from the owner's terminal value, so a
        //   mutation that never publishes leaves the previous match painted on screen.
        // Scenario: a pane holding two occurrences of a needle is searched, walked to the
        //   older match, then cleared.
        let host = try makeHost(captureTransitions: false)
        // Octal-escaped so the needle never appears in the echoed command line itself.
        let command = "printf '\\150it\\nmiss\\n\\150it\\n'; exec \(try probeExecutable()) hold \"$0\""
        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let statuses = AsyncStream<TerminalSearchStatus?>.makeStream()
        var iterator = statuses.stream.makeAsyncIterator()
        let report: @Sendable (TerminalSearchStatus?) -> Void = { statuses.continuation.yield($0) }
        let baseline = (await host.resourceSnapshot()).emittedUpdateSignalCount

        host.beginSearch("hit", onStatus: report)
        #expect(try #require(await iterator.next()) == .matched(selected: 0, total: 2))
        let afterBegin = (await host.resourceSnapshot()).emittedUpdateSignalCount
        #expect(afterBegin == baseline + 1)
        #expect(host.fencedSnapshot().activeSearchMatchRange != nil)

        host.searchNext(onStatus: report)
        #expect(try #require(await iterator.next()) == .matched(selected: 1, total: 2))
        let afterNext = (await host.resourceSnapshot()).emittedUpdateSignalCount
        #expect(afterNext == afterBegin + 1)

        host.searchPrevious(onStatus: report)
        #expect(try #require(await iterator.next()) == .matched(selected: 0, total: 2))
        let afterPrevious = (await host.resourceSnapshot()).emittedUpdateSignalCount
        #expect(afterPrevious == afterNext + 1)

        host.clearSearch(onStatus: report)
        #expect(await iterator.next() == .some(nil))
        #expect((await host.resourceSnapshot()).emittedUpdateSignalCount == afterPrevious + 1)
        #expect(host.fencedSnapshot().activeSearchMatchRange == nil)
        await host.close()
    }

    @Test("search mutations that change nothing still report status", .timeLimit(.minutes(1)))
    func ownerUnchangingSearchMutationsStillReportStatus() async throws {
        // Intent: a repeated failed needle and a navigate with only one match report
        //   status even though the terminal value is untouched.
        // Why it exists: the status report sits above the `terminal != previousTerminal`
        //   early return. Below it, the overlay's counter would silently stop updating
        //   exactly when the user needs to be told the search found nothing / cannot move.
        // Scenario: typing a needle with no matches, then re-typing it; and pressing
        //   Cmd-G on the only match.
        let host = try makeHost(captureTransitions: false)
        // Octal-escaped so the needle never appears in the echoed command line itself.
        let command = "printf '\\150it\\n'; exec \(try probeExecutable()) hold \"$0\""
        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let statuses = AsyncStream<TerminalSearchStatus?>.makeStream()
        var iterator = statuses.stream.makeAsyncIterator()
        let report: @Sendable (TerminalSearchStatus?) -> Void = { statuses.continuation.yield($0) }

        host.beginSearch("zzz", onStatus: report)
        #expect(try #require(await iterator.next()) == .empty)
        let afterFirstMiss = (await host.resourceSnapshot()).emittedUpdateSignalCount

        host.beginSearch("zzz", onStatus: report)
        #expect(try #require(await iterator.next()) == .empty)
        #expect((await host.resourceSnapshot()).emittedUpdateSignalCount == afterFirstMiss)

        host.beginSearch("hit", onStatus: report)
        #expect(try #require(await iterator.next()) == .matched(selected: 0, total: 1))
        let afterHit = (await host.resourceSnapshot()).emittedUpdateSignalCount

        host.searchNext(onStatus: report)
        #expect(try #require(await iterator.next()) == .matched(selected: 0, total: 1))
        #expect((await host.resourceSnapshot()).emittedUpdateSignalCount == afterHit)
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
        await host.start(makeLaunchInput(command: "\(printMarker("READY")); exit 7"))

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

    @Test("waiting on output a quiesced host already produced never reports absence", .timeLimit(.minutes(1)))
    func waitForOutputAfterQuiescenceSeesRetainedEvidence() async throws {
        // Intent: `waitForOutput(containing:)` answers from retained evidence when the
        //   bytes arrived before the wait started, even though the host has already
        //   torn down and can never deliver another output callback.
        // Why it exists: the helper registered its quiescence fallback before consulting
        //   the evidence it was handed, so the two raced on the host queue. A child that
        //   prints and immediately exits -- the common shape -- made every such wait a
        //   coin flip, surfacing as an unexplained `#expect` failure at the wait line.
        // Scenario: `just test` runs its steps as a parallel pool; under that load the
        //   host queue won the race often enough to fail the gate roughly one run in five.
        let host = try makeHost()
        await host.start(makeLaunchInput(command: "\(printMarker("SETTLED")); exit 0"))
        #expect(await host.waitForResult() == .exited(.exited(0)))
        await host.close()

        // Re-asking a torn-down host is the whole point: each call reinstalls the
        // handler that teardown refuses, so only the evidence check can answer. One
        // call would pass by luck often enough to hide the race; the loop does not.
        var absences = 0
        for _ in 0..<200 where await host.waitForOutput(containing: Array("__SETTLED__".utf8)) == false {
            absences += 1
        }
        #expect(absences == 0)
    }

    @Test("waiting on output the host already discarded reports why, immediately", .timeLimit(.minutes(1)))
    func waitForDiscardedOutputFailsImmediately() async throws {
        // Intent: a wait whose answer can no longer be inside the host's bounded
        //   evidence resolves at once, as a recorded issue naming the discard, instead
        //   of suspending on a live pane that will never quiesce.
        // Why it exists: `waitForOutput` reads a bounded window but reads like an
        //   unbounded "was this ever printed?" question. When the answer had already
        //   been discarded the wait was not slow, it was unsatisfiable -- and because a
        //   live pane never quiesces it burned the whole test time limit before
        //   reporting anything, pointing at the wait line rather than at the discard.
        // Scenario: the 2026-08-03 gate hang in
        //   `applicationTerminationClosesMultipleLivePanes`, where the chatty probe
        //   printed `__READY__` once and then wrote 4 KiB forever, so sixteen writes
        //   discarded the marker before the wait for it was armed (fix fdb9ec6).
        let host = try makeHost(captureTransitions: false)
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        // The flood, deterministically: enough output through the host's own path that
        // the marker cannot still be retained, on an idle machine as much as a loaded one.
        let flood = [UInt8](repeating: UInt8(ascii: "f"), count: 64 * 1024)
        for _ in 0..<16 { host.deliverOutputForTesting(flood) }

        let clock = ContinuousClock()
        let start = clock.now
        var answer: Bool??
        await withKnownIssue("the wait must say it cannot be answered") {
            answer = await value(
                of: Task { await host.waitForOutput(containing: Array("__READY__".utf8)) },
                withinMilliseconds: 3000
            )
        }
        // `nil` is the pre-fix outcome: the wait never resumed at all.
        #expect(answer == .some(.some(false)))
        #expect(clock.now - start < .seconds(1))
        await host.close()
    }

    @Test("a match armed before a flood still sees a marker printed after it", .timeLimit(.minutes(1)))
    func armedExpectationSurvivesFloodedOutput() async throws {
        // Intent: once armed, a match is decided by the whole stream from that point on --
        //   no volume of intervening output, and no chunk boundary inside the marker,
        //   can lose it.
        // Why it exists: this is the escape hatch the "already discarded" failure points
        //   at, so it has to actually work; and it is the property that makes retaining
        //   output unnecessary in the first place.
        // Scenario: the shape a chatty pane forces -- the interesting marker arrives after
        //   megabytes of noise that no bounded window could have held.
        let host = try makeHost(captureTransitions: false)
        let expectation = host.expectOutput(containing: Array("__LATE__".utf8))

        let flood = [UInt8](repeating: UInt8(ascii: "f"), count: 64 * 1024)
        for _ in 0..<16 { host.deliverOutputForTesting(flood) }
        // Split across chunks, because a PTY read boundary lands wherever it lands.
        host.deliverOutputForTesting(Array("__LA".utf8))
        host.deliverOutputForTesting(Array("TE__".utf8))

        #expect(await expectation.satisfied())
        await host.close()
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
        case let .down(button, column, row, offsetX, modifiers, clickCount):
            .init(
                action: .down,
                button: button.rawValue + 1,
                column: column,
                row: row,
                offsetX: offsetX,
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
        case let .move(column, row, offsetX, modifiers):
            .init(
                action: .move,
                column: column,
                row: row,
                offsetX: offsetX,
                modifiers: modifiers
            )
        }
    }
}

/// Holds the owner queue inside a pane-menu callback so everything submitted after
/// `hold(_:)` returns provably queues behind one job.
///
/// Coalescing is only a deterministic verdict when the test controls *when the owner is
/// free*; measuring how much a burst collapses while the queue drains at its own pace
/// would assert the machine's speed instead. The pane-menu callback is used because it is
/// the one production entry point that runs caller code on the owner queue.
private struct OwnerHold {
    private let reached = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    /// Returns once the owner queue is blocked, so the caller's next submission waits.
    func hold(_ host: TerminalPTYHost) {
        let reached = reached
        let released = released
        host.sendPointer(.down(.right, column: 0, row: 0))
        host.sendPointer(.up(.right, column: 0, row: 0)) { _ in
            reached.signal()
            released.wait()
        }
        reached.wait()
    }

    func release() {
        released.signal()
    }
}

/// Names the stream row a viewport's height puts at its top, which is what a pointer at
/// row 0 resolves against.
private func topViewportLine(_ terminal: Terminal) -> String {
    terminal.viewportText
        .split(separator: "\n", omittingEmptySubsequences: false)
        .first
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
}

private func scrollbackCommand(disableEcho: Bool = false) throws -> String {
    let echoPolicy = disableEcho ? "stty -echo; " : ""
    return "i=0; while [ $i -lt 40 ]; do printf 'line-%s\\n' \"$i\"; i=$((i+1)); done; \(echoPolicy)exec \(try probeExecutable()) hold \"$0\""
}

private func makeHost(
    captureTransitions: Bool = true,
    applicationExitBound: DispatchTimeInterval = TerminalPTYHost.defaultApplicationExitBound
) throws -> TerminalPTYHost {
    try TerminalPTYHost(
        initialDimensions: .init(columns: 80, rows: 24),
        bootstrapExecutable: bootstrapExecutable(),
        captureTransitions: captureTransitions,
        applicationExitBound: applicationExitBound
    )
}

/// Collects host exit completions the way the exit path does -- a dispatch signal
/// with no Swift Concurrency between the host and the waiter -- and records the
/// queue each one ran on, because "the host's own queue signalled it" is half of
/// what a completion is supposed to mean.
private final class ExitCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var labels: [String] = []
    private let group = DispatchGroup()

    init(expecting count: Int) {
        for _ in 0..<count { group.enter() }
    }

    func signal() {
        let label = String(cString: __dispatch_queue_get_label(nil))
        lock.lock()
        labels.append(label)
        lock.unlock()
        group.leave()
    }

    func waitForAll(within timeout: DispatchTimeInterval) -> Bool {
        group.wait(timeout: .now() + timeout) == .success
    }

    var queueLabels: [String] {
        lock.lock()
        defer { lock.unlock() }
        return labels
    }
}

private let hostOwnerQueueLabel = "com.danneu.danterm.terminal-pty-host"

/// Carries one observation out of a host completion, which runs on the host's own
/// queue while the test is suspended elsewhere.
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func directChildProcessIDs() -> [pid_t] {
    var capacity = max(Int(proc_listallpids(nil, 0)), 256) + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = pids.withUnsafeMutableBytes { buffer in
        proc_listallpids(buffer.baseAddress, Int32(buffer.count))
    }
    guard count > 0 else { return [] }
    capacity = min(Int(count), pids.count)
    let selfPID = getpid()
    return Array(pids.prefix(capacity)).filter { pid in
        guard pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size) else { return false }
        return pid_t(info.pbi_ppid) == selfPID
    }
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

/// Waits for `processID` to leave the process table, which teardown does not do synchronously.
///
/// `kill(pid, 0)` still succeeds for a zombie, and a pane's owned jobs are the probe leader's
/// children: once the leader dies they are reparented and reaped by launchd, on its schedule
/// rather than ours. Asserting absence the instant `close()` returns therefore measures the
/// reaper's latency and not the teardown ladder, and it fails under load for a pane that
/// converged correctly. The bound keeps the real claim -- teardown converges -- while still
/// failing for a job actually left running.
private func waitForProcessExit(
    _ processID: Int,
    within limit: Duration = .seconds(10)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while processExists(processID), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    return processExists(processID) == false
}

/// Waits for `processID` to stop being a direct child of this process.
///
/// `waitForProcessExit` cannot answer this one: `kill(pid, 0)` still succeeds for a zombie,
/// while `directChildProcessIDs()` filters on `pbi_ppid` and so reports the reparenting that
/// the discard path actually performs. Same bounded-poll shape, different predicate.
private func waitForDirectChildExit(
    _ processID: pid_t,
    within limit: Duration = .seconds(10)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while directChildProcessIDs().contains(processID), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    return directChildProcessIDs().contains(processID) == false
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
