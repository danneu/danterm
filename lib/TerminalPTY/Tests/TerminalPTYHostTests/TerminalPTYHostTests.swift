// Real-system PTY tests for launch ownership, ordered IO, resize, and exit convergence.
import Darwin
import Foundation
import Testing
@testable import TerminalPTYHost
import PaneLifecycle
import TerminalCoreRecording

/// Exercises the native owner only through real PTYs and controlled child behavior.
@Suite(.serialized)
struct TerminalPTYHostTests {
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
            events: transitions.map { transition in
                switch transition {
                case .feed(let bytes): .feed(bytes)
                case .resize(let dimensions):
                    .resize(columns: dimensions.columns, rows: dimensions.rows)
                }
            }
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
            #expect(releasedHost == nil)
        }

        let descriptorsAfter = try openFileDescriptorCount()
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

    @Test("initial input variants reach the interactive login shell exactly once", .timeLimit(.minutes(1)))
    func initialInputSeamPreservesBytesAndRecoveryEnvironment() async throws {
        // Intent: prove the app-facing command variants become one byte-exact
        //   owner write to the ordinary login shell, including newline handling.
        // Why it exists: facade wiring can otherwise drop, duplicate, direct-exec,
        //   or mutate restore input even when the pure launch policy is correct.
        // Scenario: command launch, restore prefill/execute, and recovery replay
        //   each run through a real PTY and controlled shell command.
        let probe = try probeExecutable()
        let restorePath = "/tmp/danterm-recovery-recording.json"
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
                name: "prefill",
                command: "exec \(probe) initial prefill",
                source: .restorePrefill,
                expectedWrite: "exec \(probe) initial prefill"
            ),
            InitialInputCase(
                name: "execute-newline",
                command: "exec \(probe) initial execute-newline\n",
                source: .restoreExecute,
                expectedWrite: "exec \(probe) initial execute-newline\n"
            ),
            InitialInputCase(
                name: "recovery",
                command: "exec \(probe) initial recovery",
                source: .recoveryReplay(restorePath),
                expectedWrite: "exec \(probe) initial recovery\n"
            ),
        ]

        for testCase in cases {
            let host = try makeHost()
            var input = makeLaunchInput(command: "")
            input.launchCommand = nil
            switch testCase.source {
            case .launchCommand:
                input.launchCommand = testCase.command
            case .restorePrefill:
                input.command = testCase.command
                input.restoreCommandBehavior = .prefill
            case .restoreExecute:
                input.command = testCase.command
                input.restoreCommandBehavior = .execute
            case .recoveryReplay(let path):
                input.command = testCase.command
                input.restoreCommandBehavior = .execute
                input.paneEnvironment.append(.init(
                    name: "DANTERM_RESTORE_SCROLLBACK_FILE",
                    value: path
                ))
            }

            await host.start(input)
            if case .restorePrefill = testCase.source {
                #expect(await host.waitForOutput(containing: Array(testCase.command.utf8)))
                #expect(await host.inputWrites() == [Array(testCase.expectedWrite.utf8)])
                host.send(Array("\n".utf8))
            }
            #expect(await host.waitForResult() == .exited(.exited(0)))

            let writes = await host.inputWrites()
            let expectedWrites = [Array(testCase.expectedWrite.utf8)]
                + (testCase.source == .restorePrefill ? [Array("\n".utf8)] : [])
            #expect(writes == expectedWrites)
            let output = String(decoding: await host.outputBytes(), as: UTF8.self)
            #expect(output.components(separatedBy: "__INITIAL_EXECUTED__=").count - 1 == 1)
            #expect(output.contains("__INITIAL_EXECUTED__=\(testCase.name)"))
            if case .recoveryReplay = testCase.source {
                #expect(output.contains("__RESTORE_FILE__=\(restorePath)"))
            }
            #expect((await host.resourceSnapshot()).isReleased)
        }
    }
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
    case restorePrefill
    case restoreExecute
    case recoveryReplay(String)
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
