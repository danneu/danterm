// Real-system PTY tests for launch ownership, ordered IO, resize, and exit convergence.
//
// Two suites, split by what the test needs from the machine: the childless-channel tests own
// nothing outside their own pair of descriptors and run in parallel, while the tests that fork
// a real child are serialized on the process-wide state they share. The helpers below serve
// both, so both suites live in this file.
import Darwin
import Foundation
import Synchronization
import Testing
@testable import TerminalPTYHost
import TerminalPTYTestSupport
import TerminalPTYWaitSupport
import PaneProcessLifecycle
@testable import TerminalCore
import TerminalCoreRecording

/// The ordinary slot-derived grid submission, so a test that says nothing about pinnedness
/// is not silently asserting a claim.
func unpinned(columns: Int, rows: Int) -> PaneGridSubmission {
    PaneGridSubmission(dimensions: .init(columns: columns, rows: rows), pinned: false)
}

/// The same grid submitted as an explicit override, for the geometry-event assertions.
func pinned(columns: Int, rows: Int) -> PaneGridSubmission {
    PaneGridSubmission(dimensions: .init(columns: columns, rows: rows), pinned: true)
}

/// Exercises the owner across a real PTY master with no process at the other end.
///
/// Nothing here forks, signals, or reaps, so nothing here contends for machine state another
/// test can observe. These run in parallel; the serialized suite below states what its own
/// tests share.
struct TerminalPTYHostTests {
    @Test("character and Insert keys encode at the PTY owner", .timeLimit(.minutes(1)))
    func widenedKeysEncodeAtPTYOwner() async throws {
        // Intent: owner-side key encoding covers every new byte-exact D8 key class.
        // Why it exists: encoding these keys in a client would race live terminal modes.
        // Scenario: Ctrl-Space, Ctrl-backslash, and Insert reach one waiting child.
        let pane = try await startChildlessHost()
        let host = pane.host
        let baseline = host.inputWrites().count

        host.sendKey(.character(" "), modifiers: [.control])
        host.sendKey(.character("\\"), modifiers: [.control])
        host.sendKey(.insert, modifiers: [])
        _ = host.fencedSnapshot()
        let writes = Array((host.inputWrites()).dropFirst(baseline))

        #expect(writes == [
            [0x00],
            [0x1C],
            Array("\u{1B}[2~".utf8),
        ])
        await host.close()
    }

    @Test("captured wheel completion follows PTY delivery", .timeLimit(.minutes(1)))
    func capturedWheelCompletionFollowsPTYDelivery() async throws {
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("\u{1B}[?1000;1006h"))
        let completion = InputCompletionRecorder(expecting: 1)

        host.sendWheel(.init(rowDelta: -1, column: 2, row: 3)) {
            completion.signal($0)
        }

        #expect(completion.waitForAll(within: .seconds(20)))
        #expect(completion.results == [.delivered])
        await host.close()
    }

    @Test("encoded key and paste submissions complete after PTY delivery", .timeLimit(.minutes(1)))
    func encodedInputSubmissionsCompleteAfterDelivery() async throws {
        let host = try await startChildlessHost().host
        let completions = InputCompletionRecorder(expecting: 2)

        host.sendKey(.returnKey, modifiers: []) { completions.signal($0) }
        host.sendPaste("hello") { completions.signal($0) }

        #expect(completions.waitForAll(within: .seconds(20)))
        #expect(completions.results == [.delivered, .delivered])
        await host.close()
    }

    @Test("every user-directed operation reports its delivery once", .timeLimit(.minutes(1)))
    func userDirectedOperationsReportDeliveryOnce() async throws {
        // Intent: each user-directed input operation reports one occurrence, carrying the
        //   wait generation its caller submitted, once all of its bytes cross the PTY.
        // Why it exists: only this owner knows what an operation encodes to and whether the
        //   write finished, so it is the one place that can state the fact without guessing.
        // Scenario: a key, raw bytes, and a paste are submitted against three distinct waits.
        let host = try await startChildlessHost().host
        let completions = InputCompletionRecorder(expecting: 3)

        host.sendKey(.returnKey, modifiers: [], waitGeneration: .init(rawValue: 1)) {
            completions.signal($0)
        }
        host.send(Array("typed".utf8), waitGeneration: nil) { completions.signal($0) }
        host.sendPaste("pasted", waitGeneration: .init(rawValue: 2)) { completions.signal($0) }

        #expect(completions.waitForAll(within: .seconds(20)))
        #expect(completions.results == [.delivered, .delivered, .delivered])
        #expect(host.drainedUserInputEvents() == [
            .userInputDelivered(waitGeneration: .init(rawValue: 1)),
            .userInputDelivered(waitGeneration: nil),
            .userInputDelivered(waitGeneration: .init(rawValue: 2)),
        ])
        await host.close()
    }

    @Test("pointer and wheel bytes report delivery under a mouse mode", .timeLimit(.minutes(1)))
    func mouseReportingOperationsReportDelivery() async throws {
        // Intent: pointer and wheel input reports its delivery like any other input, but
        //   only while a mouse mode makes the child the recipient of it.
        // Why it exists: under a mouse mode these operations are the user reaching the
        //   child, and off it they move the local viewport and reach nobody.
        // Scenario: the child turns on SGR mouse tracking, then a press and a wheel turn.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("\u{1B}[?1000;1006h"))
        let completion = InputCompletionRecorder(expecting: 1)

        host.sendPointer(
            .down(.left, cell: .init(column: 2, row: 3)),
            waitGeneration: .init(rawValue: 8)
        )
        host.sendWheel(
            .init(rowDelta: -1, column: 2, row: 3),
            waitGeneration: .init(rawValue: 9)
        ) { completion.signal($0) }

        #expect(completion.waitForAll(within: .seconds(20)))
        #expect(host.drainedUserInputEvents() == [
            .userInputDelivered(waitGeneration: .init(rawValue: 8)),
            .userInputDelivered(waitGeneration: .init(rawValue: 9)),
        ])
        await host.close()
    }

    @Test("an operation that encodes to no bytes reports nothing", .timeLimit(.minutes(1)))
    func emptyOperationsReportNoDelivery() async throws {
        // Intent: an operation whose encoding is empty reports no delivery, even though it
        //   still completes as delivered.
        // Why it exists: the occurrence has to mean the child received the user's bytes. A
        //   completion alone would also fire for a wheel turn the pane scrolled by itself.
        // Scenario: an empty request, an empty paste, and a wheel turn under no mouse mode.
        let host = try await startChildlessHost().host
        let completions = InputCompletionRecorder(expecting: 3)

        host.send([], waitGeneration: .init(rawValue: 1)) { completions.signal($0) }
        host.sendPaste("", waitGeneration: .init(rawValue: 1)) { completions.signal($0) }
        host.sendWheel(
            .init(rowDelta: -1, column: 2, row: 3),
            waitGeneration: .init(rawValue: 1)
        ) { completions.signal($0) }

        #expect(completions.waitForAll(within: .seconds(20)))
        #expect(completions.results == [.delivered, .delivered, .delivered])
        #expect(host.drainedUserInputEvents().isEmpty)
        await host.close()
    }

    @Test("a rejected submission reports no delivery", .timeLimit(.minutes(1)))
    func rejectedSubmissionReportsNoDelivery() async throws {
        // Intent: a submission the lifecycle rejects reports no occurrence at all.
        // Why it exists: an occurrence means the user's bytes reached the child, so bytes
        //   that never crossed must not end a wait the agent is still holding.
        // Scenario: the child end is closed, then one whole payload is submitted.
        let channel = try ChildlessPTYChannel()
        let host = try makeHost(spawner: channel)
        await host.start(makeLaunchInput(command: childlessLaunchCommand))
        channel.writeFromChild(Array("__READY__".utf8))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        channel.closeChildEnd()
        #expect(await host.drainedDescriptorSourceCount() == 0)
        let completion = InputCompletionRecorder(expecting: 1)

        host.send(Array("cannot-write".utf8), waitGeneration: .init(rawValue: 4)) {
            completion.signal($0)
        }

        #expect(completion.waitForAll(within: .seconds(20)))
        #expect(completion.results == [.rejected(.writeFailed(EIO))])
        #expect(host.drainedUserInputEvents().isEmpty)
        await host.close()
    }

    @Test("focus reports and terminal replies report no user input", .timeLimit(.minutes(1)))
    func paneOwnedWritesReportNoUserInput() async throws {
        // Intent: bytes the pane owes the child on its own account report no occurrence,
        //   even though they cross the same PTY as the user's.
        // Why it exists: the pane reports focus and answers queries without anybody typing,
        //   so counting those would end a wait while the question is still on screen.
        // Scenario: focus reporting is enabled and the pane reports focus, then the child
        //   asks for the cursor position and the terminal answers it.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("\u{1B}[?1004h"))
        let writeBaseline = host.inputWrites().count

        host.sendFocus(true)
        #expect(await pane.writeFromChild("\u{1B}[6n"))

        #expect(host.inputWrites().count > writeBaseline)
        #expect(host.replyWrites().isEmpty == false)
        #expect(host.drainedUserInputEvents().isEmpty)
        await host.close()
    }

    @Test("a child enabling focus reporting learns the pane's focus at once",
          .timeLimit(.minutes(1)))
    func focusReportingEnableAnswersRetainedFocus() async throws {
        // Intent: a pane that never received a focus callback answers `CSI ?1004h` with
        //   `CSI O`, and a later focus gain crosses the PTY while the child says nothing.
        // Why it exists: `tab new --cmd` starts its pane in the background, so an
        //   application that enables focus reporting there used to keep its optimistic
        //   "I am focused" assumption for the life of the pane and suppress the
        //   notifications it owed the user.
        // Scenario: a childless pane, never focused, sees the child enable mode 1004 and
        //   then gains focus. The waits are hang guards.
        let pane = try await startChildlessHost()
        let host = pane.host
        let submission = host.fencedFlightRecordingOriginFromNow().cursor

        #expect(await pane.writeFromChild("\u{1B}[?1004h"))
        #expect(await host.settledPendingInputByteCount() == 0)
        host.sendFocus(true)
        #expect(await host.settledPendingInputByteCount() == 0)

        let writes = host.fencedFlightRecording(from: submission).events
            .filter { writtenBytes($0) != nil }
        #expect(writes.compactMap(writtenBytes) == [
            Array("\u{1B}[O".utf8),
            Array("\u{1B}[I".utf8),
        ])
        // The enable is answered like any other query; the change is the pane's own business.
        #expect(writes.map(\.writeAttribution) == [.reply, .pane])
        #expect(host.drainedUserInputEvents().isEmpty)

        let expected = Array("\u{1B}[O\u{1B}[I".utf8)
        #expect(await pollUntil({
            pane.channel.bytesReceivedFromHost().suffix(expected.count) == expected[...]
        }, within: .seconds(20)))
        await host.close()
    }

    @Test("input submitted before spawn completes after crossing the PTY", .timeLimit(.minutes(1)))
    func preSpawnInputCompletesAfterDelivery() async throws {
        // Intent: pre-spawn input stays pending, then completes only after its last byte writes.
        // Why it exists: the old lifecycle dropped input received before spawn without a result.
        // Scenario: the launch report holds a successful spawn while one submission arrives.
        let spawner = ControlledTerminalPTYSpawner(
            wrapping: try ChildlessPTYChannel(),
            holdLaunchReport: true
        )
        let host = try makeHost(spawner: spawner)
        await host.start(makeLaunchInput(command: childlessLaunchCommand))
        let completion = InputCompletionRecorder(expecting: 1)

        host.send(Array("buffered\n".utf8)) {
            completion.signal($0)
        }

        #expect(spawner.waitForLaunchReport(within: .seconds(20)))
        #expect(completion.results.isEmpty)
        spawner.releaseLaunchReport()
        #expect(completion.waitForAll(within: .seconds(20)))
        #expect(completion.results == [.delivered])
        await host.close()
    }

    @Test("close during spawn rejects buffered input", .timeLimit(.minutes(1)))
    func closeDuringSpawnRejectsBufferedInput() async throws {
        // Intent: closing a spawning pane rejects every submission that cannot reach its PTY.
        // Why it exists: buffered input needs a terminal result on every failed readiness edge.
        // Scenario: a close arrives while the launch report holds a successful spawn.
        let spawner = ControlledTerminalPTYSpawner(
            wrapping: try ChildlessPTYChannel(),
            holdLaunchReport: true
        )
        let host = try makeHost(spawner: spawner)
        await host.start(makeLaunchInput(command: childlessLaunchCommand))
        let completion = InputCompletionRecorder(expecting: 1)
        host.send(Array("buffered".utf8)) {
            completion.signal($0)
        }

        #expect(spawner.waitForLaunchReport(within: .seconds(20)))
        let close = Task { await host.close() }
        #expect(completion.waitForAll(within: .seconds(20)))
        #expect(completion.results == [.rejected(.processEnded)])
        spawner.releaseLaunchReport()
        await close.value
    }

    @Test("pre-spawn input overflow rejects the whole later submission", .timeLimit(.minutes(1)))
    func preSpawnInputOverflowIsRejected() async throws {
        // Intent: the shared byte bound admits or rejects each submission as one unit.
        // Why it exists: buffering input before spawn must not introduce unbounded pane state.
        // Scenario: launch input and one submission fill the bound before another byte arrives.
        let spawner = ControlledTerminalPTYSpawner(
            wrapping: try ChildlessPTYChannel(),
            holdLaunchReport: true
        )
        let host = try makeHost(spawner: spawner)
        await host.start(makeLaunchInput(command: childlessLaunchCommand))
        let accepted = InputCompletionRecorder(expecting: 1)
        let rejected = InputCompletionRecorder(expecting: 1)

        let initialInputByteCount = Array("\(childlessLaunchCommand)\n".utf8).count
        host.send([UInt8](
            repeating: 0x61,
            count: PaneProcessLifecycleReducer.pendingInputByteLimit - initialInputByteCount
        )) {
            accepted.signal($0)
        }
        host.send([0x62]) {
            rejected.signal($0)
        }

        #expect(spawner.waitForLaunchReport(within: .seconds(20)))
        #expect(rejected.waitForAll(within: .seconds(20)))
        #expect(rejected.results == [.rejected(.bufferLimitExceeded)])
        let close = Task { await host.close() }
        #expect(accepted.waitForAll(within: .seconds(20)))
        #expect(accepted.results == [.rejected(.processEnded)])
        spawner.releaseLaunchReport()
        await close.value
    }

    @Test("hard descriptor write failure rejects queued input", .timeLimit(.minutes(1)))
    func hardWriteFailureRejectsInput() async throws {
        // Intent: a hard descriptor error rejects bytes that never crossed the PTY master.
        // Why it exists: enqueue success is not delivery when the later write can fail.
        // Scenario: the test closes the child end, then submits one whole payload.
        let channel = try ChildlessPTYChannel()
        let host = try makeHost(spawner: channel)
        await host.start(makeLaunchInput(command: childlessLaunchCommand))
        channel.writeFromChild(Array("__READY__".utf8))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        // Closing the child end is the real end-of-output edge: the host's read
        // reports end of file, so the host drops its descriptor-backed read source.
        // Waiting for that orders the submission strictly after the close.
        channel.closeChildEnd()
        #expect(await host.drainedDescriptorSourceCount() == 0)
        let completion = InputCompletionRecorder(expecting: 1)

        host.send(Array("cannot-write".utf8)) {
            completion.signal($0)
        }

        #expect(completion.waitForAll(within: .seconds(20)))
        #expect(completion.results == [.rejected(.writeFailed(EIO))])
        await host.close()
    }

    @Test("descriptor close rejects a partially written submission", .timeLimit(.minutes(1)))
    func descriptorCloseRejectsPartiallyWrittenInput() async throws {
        // Intent: one submission stays incomplete until every byte crosses the descriptor,
        //   and a descriptor that dies mid-submission rejects the whole of it as a write
        //   failure rather than as a process that ended.
        // Why it exists: a successful prefix must not turn later discarded bytes into
        //   success, and the two failure reasons tell a caller different things.
        // Scenario: nobody reads the child end, so a large submission stalls under real
        //   backpressure with its prefix already across the master; then the end closes.
        let channel = try ChildlessPTYChannel()
        let host = try makeHost(spawner: channel)
        await host.start(makeLaunchInput(command: childlessLaunchCommand))
        channel.writeFromChild(Array("__READY__".utf8))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let completion = InputCompletionRecorder(expecting: 1)
        host.send([UInt8](repeating: 0x61, count: 4 * 1024 * 1024)) {
            completion.signal($0)
        }

        #expect(await host.settledPendingInputByteCount() > 0)
        #expect(completion.results.isEmpty)
        channel.closeChildEnd()

        #expect(completion.waitForAll(within: .seconds(20)))
        #expect(completion.results == [.rejected(.writeFailed(EIO))])
        await host.close()
    }

    @Test("backpressured submissions keep their own bytes and attribution", .timeLimit(.minutes(1)))
    func backpressuredSubmissionsStayDistinct() async throws {
        // Intent: later input can queue behind a stalled submission, then both cross in order
        //   with their own bytes, origin, completion, and pending-byte accounting intact.
        // Why it exists: the pending-input representation must not merge submission ownership
        //   when a partial head write leaves later submissions waiting behind it.
        // Scenario: nobody reads a childless channel while two distinct payloads queue, then
        //   the test drains the child end until both submissions complete.
        let pane = try await startChildlessHost()
        let host = pane.host
        let recordingStart = host.fencedFlightRecordingOriginFromNow().cursor
        let first = [UInt8](repeating: UInt8(ascii: "A"), count: 2 * 1024 * 1024)
        let second = [UInt8](repeating: UInt8(ascii: "B"), count: 512 * 1024)
        let firstOrigin = DispatchTime.now().uptimeNanoseconds
        let secondOrigin = firstOrigin + 1
        let completions = InputCompletionRecorder(expecting: 2)

        host.send(first, origin: firstOrigin) { completions.signal($0) }
        #expect(await host.settledPendingInputByteCount() > 0)
        host.send(second, origin: secondOrigin) { completions.signal($0) }

        let stalledPending = await host.settledPendingInputByteCount()
        let stalledEvents = host.fencedFlightRecording(from: recordingStart).events
            .filter { writtenBytes($0) != nil }
        let stalledWrittenCount = stalledEvents.compactMap(writtenBytes).reduce(0) { $0 + $1.count }
        #expect(stalledPending == first.count + second.count - stalledWrittenCount)
        #expect(completions.results.isEmpty)

        #expect(pane.channel.discardBytesReceivedFromHost(count: first.count + second.count))
        #expect(completions.waitForAll(within: .seconds(30)))
        #expect(completions.results == [.delivered, .delivered])
        #expect(await host.resourceSnapshot().pendingInputByteCount == 0)

        let events = host.fencedFlightRecording(from: recordingStart).events
            .filter { writtenBytes($0) != nil }
        let bytes = events.compactMap(writtenBytes).flatMap { $0 }
        expectBytes(bytes, equal: first + second, "queued submission bytes")
        let firstOrigins = Set(events.compactMap { event in
            writtenBytes(event)?.first == UInt8(ascii: "A") ? event.originElapsedNanoseconds : nil
        })
        let secondOrigins = Set(events.compactMap { event in
            writtenBytes(event)?.first == UInt8(ascii: "B") ? event.originElapsedNanoseconds : nil
        })
        #expect(firstOrigins.count == 1)
        #expect(secondOrigins.count == 1)
        #expect(firstOrigins != secondOrigins)

        await host.close()
    }

    @Test("running input limit follows unwritten bytes", .timeLimit(.minutes(1)))
    func runningInputLimitTracksUnwrittenBytes() async throws {
        // Intent: bytes that cross a running host immediately release queue capacity, while
        //   every byte still pending counts against the same whole-submission admission limit.
        // Why it exists: the host's running byte total is separate from pre-spawn buffering
        //   and must stay exact across partial writes, rejection, draining, and reuse.
        // Scenario: a stalled first submission crosses only a prefix; a second fills the
        //   remaining capacity, one extra byte is rejected, then draining restores capacity.
        let pane = try await startChildlessHost()
        let host = pane.host
        let first = [UInt8](
            repeating: UInt8(ascii: "A"),
            count: PaneProcessLifecycleReducer.pendingInputByteLimit
        )
        let admitted = InputCompletionRecorder(expecting: 2)
        let rejected = InputCompletionRecorder(expecting: 1)

        host.send(first) { admitted.signal($0) }
        let firstPending = await host.settledPendingInputByteCount()
        #expect(firstPending > 0)
        #expect(firstPending < PaneProcessLifecycleReducer.pendingInputByteLimit)
        let releasedCapacity = PaneProcessLifecycleReducer.pendingInputByteLimit - firstPending
        host.send([UInt8](repeating: UInt8(ascii: "B"), count: releasedCapacity)) {
            admitted.signal($0)
        }
        host.send([UInt8(ascii: "C")]) { rejected.signal($0) }

        #expect(rejected.waitForAll(within: .seconds(20)))
        #expect(rejected.results == [.rejected(.bufferLimitExceeded)])
        #expect(await host.settledPendingInputByteCount()
            == PaneProcessLifecycleReducer.pendingInputByteLimit)

        #expect(pane.channel.discardBytesReceivedFromHost(
            count: first.count + releasedCapacity
        ))
        #expect(admitted.waitForAll(within: .seconds(30)))
        #expect(admitted.results == [.delivered, .delivered])
        #expect(await host.resourceSnapshot().pendingInputByteCount == 0)

        let fresh = InputCompletionRecorder(expecting: 1)
        host.send(Array("fresh".utf8)) { fresh.signal($0) }
        #expect(pane.channel.discardBytesReceivedFromHost(count: Array("fresh".utf8).count))
        #expect(fresh.waitForAll(within: .seconds(20)))
        #expect(fresh.results == [.delivered])

        await host.close()
    }

    @Test("Cmd link interaction publishes hover and opens once without PTY input", .timeLimit(.minutes(1)))
    func linkInteractionEffectsStayLocal() async throws {
        // Intent: prove the serialized owner applies hover/open effects without child bytes.
        // Why it exists: link ownership must preempt mouse reporting at the PTY boundary.
        // Scenario: the child prints OSC 8 text, then receives a Cmd-hover and Cmd-click.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("\u{1B}]8;;https://a.co\u{7}https://a.co\u{1B}]8;;\u{7}"))
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
        let baseline = host.inputWrites().count
        let opened = AsyncStream<TerminalHyperlink>.makeStream()
        var iterator = opened.stream.makeAsyncIterator()

        host.sendPointer(.move(cell: .init(column: column + 2, row: row), modifiers: [.command]))
        _ = try #require(host.fencedSnapshot().hoveredLink)
        host.sendPointer(
            .down(.left, cell: .init(column: column + 2, row: row), modifiers: [.command]),
            onOpenLink: { opened.continuation.yield($0) }
        )
        host.sendPointer(
            .up(.left, cell: .init(column: column + 3, row: row), modifiers: [.command]),
            onOpenLink: { opened.continuation.yield($0) }
        )

        #expect(await iterator.next()?.uri == "https://a.co")
        #expect(host.inputWrites().count == baseline)
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

    @Test("frame-only mutations coalesce behind one undrained signal")
    func frameOnlyMutationsCoalesceBehindUndrainedSignal() async throws {
        // Intent: one outstanding frame wake covers later interaction work until the frame drains.
        // Why it exists: signaling every mutation lets pointer backlogs wake the same future drain
        //   repeatedly even though that drain reads the terminal's final state.
        // Scenario: full damage is signaled, then Select All lands before the consumer drains it.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("alpha"))
        let afterOutput = (await host.resourceSnapshot()).census.emittedUpdateSignalCount

        host.selectAll()
        _ = host.fencedSnapshot()

        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == afterOutput)
        let frame = host.fencedFrameState()
        #expect(frame.damage == .full)
        #expect(frame.terminal.selectedText == "alpha")
        await host.close()
    }

    @Test("partial frame damage coalesces disjoint interaction rows")
    func partialFrameDamageCoalescesDisjointRows() async throws {
        // Intent: one undrained wake covers later damage outside the first mutation's row set.
        // Why it exists: signal coalescing is safe only if the eventual drain carries all damage,
        //   rather than only the rows present when the wake was emitted.
        // Scenario: two line selections land on different rows before one frame drain.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("alpha\r\nbeta\r\ngamma"))
        _ = host.fencedFrameState()
        let baseline = (await host.resourceSnapshot()).census.emittedUpdateSignalCount

        host.sendPointer(.down(.left, cell: .init(column: 1, row: 0), clickCount: 3))
        _ = host.fencedSnapshot()
        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == baseline + 1)
        host.sendPointer(.up(.left, cell: .init(column: 1, row: 0)))
        _ = host.fencedSnapshot()

        host.sendPointer(.down(.left, cell: .init(column: 1, row: 2), clickCount: 3))
        _ = host.fencedSnapshot()
        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == baseline + 1)

        let frame = host.fencedFrameState()
        #expect(frame.damage.contains(row: 0))
        #expect(frame.damage.contains(row: 2))
        #expect(frame.terminal.selectedText == "gamma")
        await host.close()
    }

    @Test("arming an already-hovered link emits no frame signal")
    func armOnlyLinkTransitionEmitsNoSignal() async throws {
        // Intent: click reservation stays owner-internal and creates no consumer wakeup.
        // Why it exists: whole-Terminal inequality treated invisible armed-link state as a frame.
        // Scenario: Cmd-hover drains, then Cmd-down arms the same URL without changing hover.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("https://a.co"))
        _ = host.fencedFrameState()

        host.sendPointer(.move(cell: .init(column: 3, row: 0), modifiers: [.command]))
        _ = host.fencedFrameState()
        let baseline = (await host.resourceSnapshot()).census.emittedUpdateSignalCount

        host.sendPointer(.down(.left, cell: .init(column: 3, row: 0), modifiers: [.command]))
        _ = host.fencedSnapshot()

        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == baseline)
        #expect(host.fencedFrameState().damage == .none)
        await host.close()
    }

    @Test("owner interactions never compare retained terminal history", .timeLimit(.minutes(1)))
    func ownerInteractionsNeverCompareRetainedHistory() async throws {
        // Intent: every interaction publication site remains independent of retained depth.
        // Why it exists: the 2026-08-15 pointer freeze came from whole-Terminal equality on the
        //   owner queue, and removing only that one call would leave the same failure elsewhere.
        // Scenario: each interaction class mutates a live host after it has built deep history.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild(scrollbackLines))
        _ = host.fencedFrameState()

        let comparisons = Instrument.wholeStoreEquality.measure {
            host.applyInteractionForTesting(.pointer(.move(cell: .init(column: 0, row: 0))))
            host.applyInteractionForTesting(.cancelLinkInteraction)
            host.applyInteractionForTesting(.clearSelection)
            host.applyInteractionForTesting(.beginSearch("line"))
            host.applyInteractionForTesting(.selectAll)
            host.applyInteractionForTesting(.scrollByRows(-1))
            host.applyInteractionForTesting(.resize(unpinned(columns: 79, rows: 23)))
        }

        #expect(comparisons == 0)
        await host.close()
    }

    @Test("conservative frame recordings still publish after each drain")
    func conservativeFrameRecordingsStillPublish() async throws {
        // Intent: publication follows recorded damage even when the visible value is unchanged.
        // Why it exists: an inequality-based shortcut would strand deliberate repaint records.
        // Scenario: the same URL is hovered twice and the same successful search is begun twice.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("https://a.co hit"))
        _ = host.fencedFrameState()

        host.sendPointer(.move(cell: .init(column: 3, row: 0), modifiers: [.command]))
        _ = host.fencedFrameState()
        let afterFirstHover = (await host.resourceSnapshot()).census.emittedUpdateSignalCount
        host.sendPointer(.move(cell: .init(column: 3, row: 0), modifiers: [.command]))
        _ = host.fencedSnapshot()
        #expect(
            (await host.resourceSnapshot()).census.emittedUpdateSignalCount
                == afterFirstHover + 1
        )
        _ = host.fencedFrameState()

        host.beginSearch("hit")
        _ = host.fencedFrameState()
        let afterFirstSearch = (await host.resourceSnapshot()).census.emittedUpdateSignalCount
        host.beginSearch("hit")
        _ = host.fencedSnapshot()
        #expect(
            (await host.resourceSnapshot()).census.emittedUpdateSignalCount
                == afterFirstSearch + 1
        )
        await host.close()
    }

    @Test("viewport capture records movement under already-pending full damage")
    func viewportCaptureRecordsMovementUnderPendingFullDamage() async throws {
        // Intent: transition capture classifies viewport movement from viewport state itself.
        // Why it exists: pending full damage cannot say whether a later navigation actually moved.
        // Scenario: output schedules full damage, then a scroll lands before that frame drains.
        let pane = try await startChildlessHost(flightTapeConfiguration: .complete)
        let host = pane.host
        #expect(await pane.writeFromChild(scrollbackLines))
        _ = host.fencedFrameState()
        let baseline = host.tapeEvents().count

        #expect(await pane.writeFromChild("\u{1B}[2J"))
        host.scroll(byRows: -1)
        _ = host.fencedSnapshot()

        #expect(Array(host.tapeEvents().dropFirst(baseline)).contains(.viewport(.byRows(-1))))
        await host.close()
    }

    @Test("OSC 52 wakes and drains once without sending query data to the child", .timeLimit(.minutes(1)))
    func clipboardWriteFrameStateAndReadDenial() async throws {
        // Intent: owner framing drains completed clipboard writes independently from replies.
        // Why it exists: grid-silent effects need a wakeup, while reads must never expose clipboard data.
        // Scenario: the child writes OSC 52, asks to read it, and the pane stays live.
        let pane = try await startChildlessHost()
        let host = pane.host
        _ = host.fencedFrameState()
        #expect(await pane.writeFromChild("\u{1B}]52;c;aGVsbG8=\u{7}\u{1B}]52;c;?\u{7}"))

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
        #expect(host.replyWrites() == [])
        await host.close()
    }

    @Test("incomplete OSC 52 stays idle until grid-silent termination", .timeLimit(.minutes(1)))
    func incompleteClipboardWriteStaysIdle() async throws {
        // Intent: retained OSC bytes alone produce neither a host wakeup nor a drained effect.
        // Why it exists: whole-Terminal inequality includes parser state and is too broad for work.
        // Scenario: the child splits one clipboard write across two separate writes.
        let pane = try await startChildlessHost()
        let host = pane.host
        _ = host.fencedFrameState()
        let baseline = (await host.resourceSnapshot()).census.emittedUpdateSignalCount

        #expect(await pane.writeFromChild("\u{1B}]52;c;aGVs"))
        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == baseline)
        let incomplete = host.fencedFrameState()
        #expect(incomplete.damage == .none)
        #expect(incomplete.clipboardWrite == nil)

        #expect(await pane.writeFromChild("bG8=\u{7}"))
        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == baseline + 1)
        let complete = host.fencedFrameState()
        #expect(complete.damage == .none)
        #expect(complete.clipboardWrite == "hello")
        #expect(host.fencedFrameState().clipboardWrite == nil)
        await host.close()
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
        let pane = try await startChildlessHost(flightTapeConfiguration: .complete)
        let host = pane.host
        #expect(await pane.writeFromChild(scrollbackLines))

        host.resize(unpinned(columns: 80, rows: 30))
        let tallTopLine = topViewportLine(host.fencedSnapshot())
        host.resize(unpinned(columns: 80, rows: 10))
        let shortTopLine = topViewportLine(host.fencedSnapshot())
        try #require(tallTopLine.isEmpty == false)
        try #require(tallTopLine != shortTopLine)
        let baseline = host.tapeEvents().count

        let owner = OwnerHold()
        try owner.hold(host)
        host.resize(unpinned(columns: 80, rows: 30))
        host.sendPointer(.down(.left, cell: .init(column: 2, row: 0), clickCount: 3))
        host.resize(unpinned(columns: 80, rows: 10))
        owner.release()

        let snapshot = host.fencedSnapshot()
        let ordered = host.tapeEvents().dropFirst(baseline).filter { event in
            switch event {
            case .resize: true
            case .mouse(let mouse): mouse.action == .down
            default: false
            }
        }
        #expect(ordered == [
            .resize(columns: 80, rows: 30, pinned: false),
            .mouse(.init(action: .down, button: 1, column: 2, row: 0, clickCount: 3)),
            .resize(columns: 80, rows: 10, pinned: false),
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
        let host = try await startChildlessHost().host

        host.resize(unpinned(columns: 100, rows: 31))
        let snapshot = host.fencedSnapshot()

        #expect(snapshot.geometry.columns == 100)
        #expect(snapshot.geometry.rows.count == 31)
        await host.close()
    }

    @Test("an unchanged terminal emits no update work", .timeLimit(.minutes(1)))
    func unchangedTerminalEmitsNoUpdate() async throws {
        let host = try await startChildlessHost().host
        let signalsBefore = (await host.resourceSnapshot()).census.emittedUpdateSignalCount

        host.resize(unpinned(columns: 80, rows: 24))
        _ = await host.snapshot()

        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == signalsBefore)
        await host.close()
    }

    // Intent: the history budget a stream states reaches the serialization it asks the fenced
    //   state for, from an opening fence and from a follow fence alike; without one, the whole
    //   retained history is carried.
    // Why it exists: the budget is the only thing standing between a join and a payload
    //   proportional to the whole scrollback. It crosses four layers to get here, and a hop
    //   that dropped it would still produce a correct sync -- just an enormous one, which no
    //   correctness assertion anywhere else would notice.
    // Scenario: a pane whose child printed far more history than the budget allows.
    @Test("resolving a fenced state observes the budget it was given", .timeLimit(.minutes(1)))
    func streamFenceHonorsHistoryBudget() async throws {
        let pane = try await startChildlessHost()
        let host = pane.host
        for line in 0..<400 {
            #expect(await pane.writeFromChild("history line \(line)\r\n"))
        }

        let budget = 2048
        let bounded = host.fencedFlightRecordingStream(from: .beginning)
            .state.resolve(historyBudgetBytes: budget).state
        let whole = host.fencedFlightRecordingStream(from: .beginning)
            .state.resolve(historyBudgetBytes: nil).state

        #expect(bounded.droppedHistoryRows > 0)
        #expect(whole.droppedHistoryRows == 0)
        #expect(bounded.bytes.count < whole.bytes.count)

        let subscriptionId = UUID()
        let origin = host.fencedFlightRecordingOriginFromNow()
        host.addFlightRecordingFollowNotice(id: subscriptionId, from: origin.cursor, notify: {})
        let followed = try #require(host.fencedFlightRecordingFollowStream(
            subscriptionId: subscriptionId,
            from: origin.cursor
        ))
        #expect(followed.state.resolve(historyBudgetBytes: budget).state.droppedHistoryRows > 0)
        host.removeFlightRecordingFollowNotice(id: subscriptionId)
        await host.close()
    }

    @Test("terminal synchronization and recorder cursor share one owner fence", .timeLimit(.minutes(1)))
    func stateSynchronizationSharesRecorderFence() async throws {
        // Intent: pair serialized terminal state with the first event not reflected in that state.
        // Why it exists: separate terminal and recorder reads can drop or double-apply output between them.
        // Scenario: the child prints history, a stream fence pairs state with a cursor, and
        //   later output replays from that cursor onto the replayed state.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("one\r\n"))

        let fenced = host.fencedFlightRecordingStream(from: .beginning)
            .state.resolve(historyBudgetBytes: nil)
        var resumed = try #require(Terminal(
            columns: fenced.state.columns,
            rows: fenced.state.rows
        ))
        resumed.feed(fenced.state.bytes)
        host.send(Array("\n".utf8))
        #expect(await pane.writeFromChild("two\r\n"))
        let suffix = host.fencedFlightRecording(from: fenced.cursor)
        for recorded in suffix.events {
            switch recorded.event {
            case .feed(let bytes):
                resumed.feed(bytes)
            case .resize(let columns, let rows, _):
                resumed.resize(columns: columns, rows: rows)
            default:
                break
            }
        }
        let source = host.fencedSnapshot()

        #expect(resumed.screenText == source.screenText)
        #expect(resumed.scrollbackRowCount == source.scrollbackRowCount)
        #expect(suffix.events.contains { if case .feed = $0.event { true } else { false } })
        await host.close()
    }

    @Test(
        "stream fence validates a supplied cursor beside retained tape and exact state",
        .timeLimit(.minutes(1))
    )
    func streamFenceCarriesPlacementAndState() async throws {
        // Intent: one owner turn returns remote cursor placement, retained events, and state.
        // Why it exists: separate fences can splice a cursor onto state from another moment.
        // Scenario: a live pane rejects a foreign cursor while its exact state stays replayable.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("pane-state"))
        let foreign = TerminalFlightRecordingCursor(
            recorderLifetimeId: UUID(),
            nextSequence: 0,
            feedBytesBeforeNextSequence: 0,
            writeBytesBeforeNextSequence: 0
        )

        let fenced = host.fencedFlightRecordingStream(from: foreign)
        let synchronization = fenced.state.resolve(historyBudgetBytes: nil)
        var resumed = try #require(Terminal(
            columns: synchronization.state.columns,
            rows: synchronization.state.rows
        ))
        resumed.feed(synchronization.state.bytes)

        #expect(fenced.requested.isUnplaceable)
        #expect(fenced.retained.events.isEmpty == false)
        #expect(synchronization.cursor == fenced.retained.nextCursor)
        #expect(fenced.live.cursor == fenced.retained.nextCursor)
        #expect(resumed.screenText == host.fencedSnapshot().screenText)
        await host.close()
    }

    @Test(
        "follow fence rearms its notice beside a suffix and exact replacement state",
        .timeLimit(.minutes(1))
    )
    func followFenceCarriesSuffixAndState() async throws {
        // Intent: a followed suffix and its replacement state end at the same recorder cursor.
        // Why it exists: eviction during delivery must repair state without losing later output.
        // Scenario: the child waits between two writes while a follower arms at the first one.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("one"))
        let origin = host.fencedFlightRecordingOriginFromNow()
        let subscriptionId = UUID()
        host.addFlightRecordingFollowNotice(
            id: subscriptionId,
            from: origin.cursor,
            notify: {}
        )
        host.send(Array("\n".utf8))
        #expect(await pane.writeFromChild("two"))

        let fenced = try #require(host.fencedFlightRecordingFollowStream(
            subscriptionId: subscriptionId,
            from: origin.cursor
        ))
        let synchronization = fenced.state.resolve(historyBudgetBytes: nil)
        var resumed = try #require(Terminal(
            columns: synchronization.state.columns,
            rows: synchronization.state.rows
        ))
        resumed.feed(synchronization.state.bytes)

        #expect(fenced.snapshot.events.isEmpty == false)
        #expect(synchronization.cursor == fenced.snapshot.nextCursor)
        #expect(resumed.screenText == host.fencedSnapshot().screenText)
        host.removeFlightRecordingFollowNotice(id: subscriptionId)
        await host.close()
    }

    // Intent: state serialized after a fence returns describes the terminal as the fence saw
    //   it, however much the pane ingested in between -- for an opening fence and a follow
    //   fence alike.
    // Why it exists: the serialization is now deferred until a stream selects a sync, so it
    //   runs strictly after the fence rather than inside it. If it read the live terminal, a
    //   sync would state a moment its paired cursor does not, and the replica would apply the
    //   suffix after it twice.
    // Scenario: a pane fences a stream, the child keeps printing, and only then does the
    //   stream ask for bytes.
    @Test("a fenced state serialized later still states the fence's moment", .timeLimit(.minutes(1)))
    func deferredSerializationStatesTheFencedMoment() async throws {
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("fenced\r\n"))

        let opening = host.fencedFlightRecordingStream(from: .beginning)
        let subscriptionId = UUID()
        host.addFlightRecordingFollowNotice(
            id: subscriptionId,
            from: opening.live.cursor,
            notify: {}
        )
        let fencedText = host.fencedSnapshot().screenText
        #expect(await pane.writeFromChild("after the fence\r\n"))
        let follow = try #require(host.fencedFlightRecordingFollowStream(
            subscriptionId: subscriptionId,
            from: opening.live.cursor
        ))
        let followFencedText = host.fencedSnapshot().screenText
        #expect(await pane.writeFromChild("after the follow fence\r\n"))
        // Both halves only have teeth while the live terminal has moved past the moment each
        // fence took, so state the two moves rather than trust the writes above.
        #expect(followFencedText != fencedText)
        #expect(host.fencedSnapshot().screenText != followFencedText)

        for (synchronization, expected) in [
            (opening.state.resolve(historyBudgetBytes: nil), fencedText),
            (follow.state.resolve(historyBudgetBytes: nil), followFencedText),
        ] {
            var resumed = try #require(Terminal(
                columns: synchronization.state.columns,
                rows: synchronization.state.rows
            ))
            resumed.feed(synchronization.state.bytes)
            #expect(resumed.screenText == expected)
        }

        host.removeFlightRecordingFollowNotice(id: subscriptionId)
        await host.close()
    }

    @Test("input the child has not accepted stays out of the tape", .timeLimit(.minutes(1)))
    func backpressuredInputIsRecordedOnlyOnceItCrosses() async throws {
        // Intent: the tape holds the bytes the PTY accepted and no others, so input still
        //   waiting in the owner's own buffer leaves no event behind.
        // Why it exists: an event written when bytes are queued charges the app's own
        //   backpressure to the child, which is the attribution this facility exists to make.
        // Scenario: megabytes are submitted to a channel whose child end nobody reads.
        let host = try await startChildlessHost().host

        let submission = host.fencedFlightRecordingOriginFromNow().cursor
        let payload = [UInt8](repeating: UInt8(ascii: "A"), count: 4 * 1024 * 1024)
        host.send(payload, origin: 1)
        let pending = await host.settledPendingInputByteCount()

        let recorded = host.fencedFlightRecording(from: submission)
            .events
            .compactMap(writtenBytes)
        #expect(pending > 0)
        #expect(recorded.reduce(0) { $0 + $1.count } == payload.count - pending)
        #expect(recorded.allSatisfy { $0.allSatisfy { $0 == UInt8(ascii: "A") } })

        await host.close()
    }

    @Test("a mismatched megabyte is reported, not diffed", .timeLimit(.minutes(1)))
    func mismatchedPayloadIsReportedWithoutDiffing() {
        // Intent: comparing megabyte payloads costs one pass whether they match or not.
        // Why it exists: the incident. `#expect(recorded == payload)` on a 1 MiB array
        //   failed under load, and Swift Testing rendered that failure by computing
        //   `BidirectionalCollection.difference(from:)` -- about quadratic, four seconds
        //   at 32 KiB, and never finishing at a megabyte. The lane died on its deadline
        //   and left the test binary spinning at full CPU with no parent, which is how
        //   this was found. A `.timeLimit` cannot catch it, because the diff is
        //   synchronous and does not yield, so the guard has to be the comparison itself.
        // Scenario: the shape of a partial drain -- a payload against its own prefix.
        let payload = (0..<(1024 * 1024)).map { UInt8($0 % 251) }
        let truncated = Array(payload.prefix(payload.count - 1024))

        let started = ContinuousClock().now
        withKnownIssue("the payloads are deliberately unequal") {
            expectBytes(truncated, equal: payload, "deliberate mismatch")
        }
        let elapsed = ContinuousClock().now - started

        // Generous on purpose: the failure mode is hours, not milliseconds, so this
        // separates the two without pinning the comparison to a machine's speed.
        #expect(elapsed < .seconds(5), "reporting the mismatch took \(elapsed)")
    }

    @Test("owner-originated bytes cross without an origin stamp", .timeLimit(.minutes(1)))
    func ownerOriginatedBytesCarryNoOrigin() async throws {
        // Intent: a terminal reply has no origin earlier than its own transfer, so its event
        //   carries one stamp, while input submitted with an origin beside it carries two.
        // Why it exists: I3. An origin defaulted to the transfer time, or to zero, would read
        //   as a measurement rather than as the absence of one.
        // Scenario: the child asks for the cursor position and the user types straight after.
        let pane = try await startChildlessHost()
        let host = pane.host

        let submission = host.fencedFlightRecordingOriginFromNow().cursor
        #expect(await pane.writeFromChild("\u{1B}[6n"))
        let typedOrigin = DispatchTime.now().uptimeNanoseconds
        host.send(Array("hi".utf8), origin: typedOrigin)
        #expect(await host.settledPendingInputByteCount() == 0)

        let events = host.fencedFlightRecording(from: submission)
            .events
            .filter { writtenBytes($0) != nil }
        // Row 1 column 1: nothing has been printed to this pane, because the only
        // thing that could print to it is this test. The coordinates stay exact
        // because they are what notices output nobody asked for -- and the screen
        // rides along with a failure, so the next such surprise explains itself
        // instead of arriving as a byte array.
        #expect(events.compactMap(writtenBytes) == [
            Array("\u{1B}[1;1R".utf8),
            Array("hi".utf8),
        ], "screen when the cursor was reported:\n\(occupiedScreenText(host))")
        #expect(events.first?.originElapsedNanoseconds == nil)
        #expect(events.last?.originElapsedNanoseconds != nil)

        await host.close()
    }

    @Test("primary wheel intent scrolls locally without writing child bytes", .timeLimit(.minutes(1)))
    func primaryWheelRoutesLocally() async throws {
        // Intent: route a wheel step using the authoritative screen selected on the host queue.
        // Why it exists: deciding from a lagging session snapshot can emit arrows on primary.
        // Scenario: the user wheels upward through retained output while the child waits.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild(scrollbackLines))
        let writeBaseline = host.inputWrites().count

        host.sendWheel(.init(rowDelta: -3, column: 0, row: 0))
        let snapshot = host.fencedSnapshot()

        #expect(snapshot.scrollProjection.isFollowing == false)
        #expect(snapshot.scrollProjection.topRow == snapshot.scrollbackRowCount - 3)
        #expect(host.inputWrites().count == writeBaseline)

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
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("\u{1B}[?1h\u{1B}[?1049h"))
        let writeBaseline = host.inputWrites().count
        let up = [UInt8]([0x1B, 0x4F, 0x41])

        host.sendWheel(.init(rowDelta: -3, column: 0, row: 0))
        let snapshot = host.fencedSnapshot()
        let writes = host.inputWrites()

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
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("\u{1B}[?1h\u{1B}[?2004h\u{1B}[?1004h"))
        let baseline = host.inputWrites().count
        #expect(await host.snapshot().isFocused == false)

        host.sendKey(.up, modifiers: [])
        host.sendPaste("one\ntwo")
        host.sendFocus(true)
        _ = host.fencedSnapshot()

        #expect(Array((host.inputWrites()).dropFirst(baseline)) == [
            Array("\u{1B}OA".utf8),
            Array("\u{1B}[200~one\ntwo\u{1B}[201~".utf8),
            Array("\u{1B}[I".utf8),
        ])
        // Focus is the one semantic input the terminal retains, and the owner's terminal is
        // where it lands -- the mode mirror this test guards against would lose it.
        #expect(await host.snapshot().isFocused)
        await host.close()
    }

    @Test("empty safe paste and focus preserve a browsing viewport", .timeLimit(.minutes(1)))
    func nonScrollingSemanticInputPreservesViewport() async throws {
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild(scrollbackLines))
        host.scroll(byRows: -3)
        let browsing = host.fencedSnapshot()
        let baseline = host.inputWrites().count

        host.sendPaste("\u{1B}\u{7F}\u{0080}")
        host.sendFocus(true)
        _ = host.fencedSnapshot()

        #expect(host.inputWrites().count == baseline)
        #expect((await host.snapshot()).scrollProjection == browsing.scrollProjection)

        host.sendPaste("safe")
        #expect(host.fencedSnapshot().scrollProjection.isFollowing)
        await host.close()
    }

    @Test("semantic input capture records normalized events in owner order", .timeLimit(.minutes(1)))
    func semanticInputCaptureOrder() async throws {
        let host = try await startChildlessHost(flightTapeConfiguration: .complete).host

        host.sendKey(.f5, modifiers: [.shift])
        host.sendPaste("paste")
        host.sendFocus(false)
        _ = host.fencedSnapshot()

        let events = host.tapeEvents()
        #expect(events.contains(.input(key: .f5, modifiers: [.shift])))
        #expect(events.contains(.paste("paste")))
        #expect(events.contains(.focus(false)))
        await host.close()
    }

    @Test("wheel races with 1049 transitions use exactly the screen seen by the owner", .timeLimit(.minutes(1)))
    func wheelTransitionRaceUsesOwnerScreen() async throws {
        // Intent: prove both race directions resolve on the shared FIFO instead of a caller snapshot.
        // Why it exists: a primary-to-alt race can leak arrows, while alt-to-primary can swallow them.
        // Scenario: wheel intent is queued immediately after the commands that make the
        //   child enter and leave alt screen, and before the child's answer arrives.
        let pane = try await startChildlessHost(flightTapeConfiguration: .complete)
        let host = pane.host
        #expect(await pane.writeFromChild(scrollbackLines))
        let down = [UInt8]([0x1B, 0x5B, 0x42])

        let enter = Array("enter-alt-screen\n".utf8)
        let enterWriteBaseline = host.inputWrites().count
        host.send(enter)
        host.sendWheel(.init(rowDelta: -1, column: 0, row: 0))
        _ = host.fencedSnapshot()
        #expect(Array((host.inputWrites()).dropFirst(enterWriteBaseline)) == [enter])
        #expect(host.tapeEvents().contains(.viewport(.byRows(-1))))
        #expect(await pane.writeFromChild("\u{1B}[?1049h"))
        #expect(host.fencedSnapshot().isAlternateScreenActive)

        let exit = Array("leave-alt-screen\n".utf8)
        let exitWriteBaseline = host.inputWrites().count
        host.send(exit)
        host.sendWheel(.init(rowDelta: 2, column: 0, row: 0))
        _ = host.fencedSnapshot()
        #expect(Array((host.inputWrites()).dropFirst(exitWriteBaseline)) == [
            exit,
            down + down,
        ])
        #expect(await pane.writeFromChild("\u{1B}[?1049l"))
        #expect(host.fencedSnapshot().isAlternateScreenActive == false)

        await host.close()
    }

    @Test("captured SGR pointer reports use modes already applied by child output", .timeLimit(.minutes(1)))
    func capturedPointerUsesAuthoritativeModes() async throws {
        // Intent: decide and encode pointer input from the terminal modes on the owner FIFO.
        // Why it exists: mode lookup outside the owner can race child DECSET output.
        // Scenario: the child enables click tracking and SGR encoding before the user clicks.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("\u{1B}[?1000;1006h"))
        let baseline = host.inputWrites().count

        host.sendPointer(.down(.left, cell: .init(column: 4, row: 2)))
        host.sendPointer(.up(.left, cell: .init(column: 4, row: 2)))
        _ = host.fencedSnapshot()

        #expect(Array((host.inputWrites()).dropFirst(baseline)) == [
            Array("\u{1B}[<0;5;3M".utf8),
            Array("\u{1B}[<0;5;3m".utf8),
        ])
        await host.close()
    }

    @Test("Shift extension stays local while captured and replays exactly", .timeLimit(.minutes(1)))
    func capturedShiftSelectionReplays() async throws {
        let pane = try await startChildlessHost(flightTapeConfiguration: .complete)
        let host = pane.host
        #expect(await pane.writeFromChild("\u{1B}[2J\u{1B}[H\u{1B}[?1000halpha beta"))
        let baseline = host.inputWrites().count
        let lines = host.fencedSnapshot().viewportText
            .split(separator: "\n", omittingEmptySubsequences: false)
        let row = try #require(lines.firstIndex(where: { $0.contains("alpha beta") }))
        let alpha = try #require(lines[row].range(of: "alpha"))
        let column = lines[row].distance(from: lines[row].startIndex, to: alpha.lowerBound)

        host.sendPointer(.down(.left, cell: .init(column: column, row: row),
            modifiers: [.shift],
            clickCount: 2))
        host.sendPointer(.up(.left, cell: .init(column: column, row: row), modifiers: [.shift]))
        // The extending click count maps to line selection on a fresh gesture, but the settled
        // token granularity wins and entering beta includes that token as one unit.
        host.sendPointer(.down(.left, cell: .init(column: column + 6, row: row, offsetX: 0.75),
            modifiers: [.shift],
            clickCount: 3))
        host.sendPointer(.up(.left, cell: .init(column: column + 6, row: row), modifiers: [.shift]))
        let snapshot = host.fencedSnapshot()
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "captured-shift-selection"),
            initial: .init(columns: 80, rows: 24),
            events: host.tapeEvents()
        )

        #expect(snapshot.selectedText == "alpha beta")
        #expect(snapshot.selectionGranularity == .terminalToken)
        #expect(host.inputWrites().count == baseline)
        #expect(try recording.replay(machineHostname: MachineHostname.posix) == snapshot)
        await host.close()
    }

    @Test("captured and Shift wheel routes preserve a browsing viewport", .timeLimit(.minutes(1)))
    func wheelRoutesPreserveBrowsing() async throws {
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild(scrollbackLines + "\u{1B}[?1000;1006h"))
        host.scroll(byRows: -3)
        let browsing = host.fencedSnapshot().scrollProjection
        let baseline = host.inputWrites().count

        host.sendWheel(.init(rowDelta: -1, column: 2, row: 3))
        _ = host.fencedSnapshot()
        #expect(Array((host.inputWrites()).dropFirst(baseline)) == [
            Array("\u{1B}[<64;3;4M".utf8),
        ])
        #expect(host.fencedSnapshot().scrollProjection == browsing)

        let reportCount = host.inputWrites().count
        host.sendWheel(.init(rowDelta: -1, column: 2, row: 3, modifiers: [.shift]))
        let shifted = host.fencedSnapshot().scrollProjection
        #expect(host.inputWrites().count == reportCount)
        #expect(shifted.topRow == browsing.topRow - 1)
        #expect(shifted.isFollowing == false)
        await host.close()
    }

    @Test("an uncaptured right-button gesture writes nothing to the child", .timeLimit(.minutes(1)))
    func uncapturedRightButtonIsInert() async throws {
        // Intent: with mouse reporting off, neither half of a right-button gesture reaches
        //   the child.
        // Why it exists: AppKit now owns the pane context menu, so the engine's only
        //   remaining duty for an unclaimed right-click is to stay out of the way. A stray
        //   report here would land as input in whatever program is running.
        // Scenario: spec-first -- the user right-clicks a pane running a plain shell.
        let host = try await startChildlessHost().host
        let before = host.inputWrites().count

        host.sendPointer(.down(.right, cell: .init(column: 9, row: 4)))
        _ = host.fencedSnapshot()
        host.sendPointer(.up(.right, cell: .init(column: 9, row: 4)))
        _ = host.fencedSnapshot()

        #expect(host.inputWrites().count == before)
        await host.close()
    }

    @Test("user input snaps browsing to bottom and capture replays the transition", .timeLimit(.minutes(1)))
    func userInputSnapCaptureEquality() async throws {
        // Intent: record the local snap before the user write without classifying replies as input.
        // Why it exists: a non-echoing child cannot reconstruct this viewport mutation from output.
        // Scenario: the user scrolls up, types into a waiting process, and captures the pane.
        let pane = try await startChildlessHost(flightTapeConfiguration: .complete)
        let host = pane.host
        #expect(await pane.writeFromChild(scrollbackLines))
        host.scroll(byRows: -4)
        #expect(host.fencedSnapshot().scrollProjection.isFollowing == false)

        host.send(Array("typed".utf8))
        let events = host.tapeEvents()
        let snapshot = host.fencedSnapshot()
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "input-snap"),
            initial: .init(columns: 80, rows: 24),
            events: events
        )

        #expect(snapshot.scrollProjection.isFollowing)
        #expect(events.contains(.viewport(.toBottom)))
        #expect(try recording.replay(machineHostname: MachineHostname.posix) == snapshot)

        await host.close()
    }

    @Test("scrollbar commands clamp on the owner queue and emit updates only for changes", .timeLimit(.minutes(1)))
    func ownerScrollbarCommandsClampAndDedupe() async throws {
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild(scrollbackLines))
        _ = host.fencedFrameState()
        let baseline = (await host.resourceSnapshot()).census.emittedUpdateSignalCount
        let writeBaseline = host.inputWrites().count

        host.scroll(toTopRow: -100)
        let top = host.fencedSnapshot()
        let afterChange = (await host.resourceSnapshot()).census.emittedUpdateSignalCount
        host.scroll(toTopRow: -100)
        _ = host.fencedSnapshot()

        #expect(top.scrollProjection.topRow == 0)
        #expect(top.scrollProjection.isFollowing == false)
        #expect(afterChange == baseline + 1)
        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == afterChange)
        #expect(host.inputWrites().count == writeBaseline)

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
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("hit\r\nmiss\r\nhit\r\n"))
        _ = host.fencedFrameState()
        let statuses = AsyncStream<TerminalSearchStatus?>.makeStream()
        var iterator = statuses.stream.makeAsyncIterator()
        let report: @Sendable (TerminalSearchStatus?) -> Void = { statuses.continuation.yield($0) }
        let baseline = (await host.resourceSnapshot()).census.emittedUpdateSignalCount

        host.beginSearch("hit", onStatus: report)
        #expect(try #require(await iterator.next()) == .matched(selected: 0, total: 2))
        let afterBegin = (await host.resourceSnapshot()).census.emittedUpdateSignalCount
        #expect(afterBegin == baseline + 1)
        #expect(host.fencedFrameState().terminal.activeSearchMatchRange != nil)

        host.searchNext(onStatus: report)
        #expect(try #require(await iterator.next()) == .matched(selected: 1, total: 2))
        let afterNext = (await host.resourceSnapshot()).census.emittedUpdateSignalCount
        #expect(afterNext == afterBegin + 1)
        _ = host.fencedFrameState()

        host.searchPrevious(onStatus: report)
        #expect(try #require(await iterator.next()) == .matched(selected: 0, total: 2))
        let afterPrevious = (await host.resourceSnapshot()).census.emittedUpdateSignalCount
        #expect(afterPrevious == afterNext + 1)
        _ = host.fencedFrameState()

        host.clearSearch(onStatus: report)
        #expect(await iterator.next() == .some(nil))
        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == afterPrevious + 1)
        #expect(host.fencedFrameState().terminal.activeSearchMatchRange == nil)
        await host.close()
    }

    @Test("search mutations that change nothing still report status", .timeLimit(.minutes(1)))
    func ownerUnchangingSearchMutationsStillReportStatus() async throws {
        // Intent: a repeated failed needle and a navigate with only one match report
        //   status even though the mutation records no frame work.
        // Why it exists: frame publication can skip these no-ops, but the overlay still needs
        //   to be told that the search found nothing or cannot move.
        // Scenario: typing a needle with no matches, then re-typing it; and pressing
        //   Cmd-G on the only match.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("hit\r\n"))
        let statuses = AsyncStream<TerminalSearchStatus?>.makeStream()
        var iterator = statuses.stream.makeAsyncIterator()
        let report: @Sendable (TerminalSearchStatus?) -> Void = { statuses.continuation.yield($0) }

        host.beginSearch("zzz", onStatus: report)
        #expect(try #require(await iterator.next()) == .empty)
        let afterFirstMiss = (await host.resourceSnapshot()).census.emittedUpdateSignalCount

        host.beginSearch("zzz", onStatus: report)
        #expect(try #require(await iterator.next()) == .empty)
        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == afterFirstMiss)

        host.beginSearch("hit", onStatus: report)
        #expect(try #require(await iterator.next()) == .matched(selected: 0, total: 1))
        let afterHit = (await host.resourceSnapshot()).census.emittedUpdateSignalCount

        host.searchNext(onStatus: report)
        #expect(try #require(await iterator.next()) == .matched(selected: 0, total: 1))
        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == afterHit)
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
        let host = try await startChildlessHost().host

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

    @Test("waiting on output a quiesced host already produced never reports absence", .timeLimit(.minutes(1)))
    func waitForOutputAfterQuiescenceSeesRetainedEvidence() async throws {
        // Intent: `waitForOutput(containing:)` answers from retained evidence when the
        //   bytes arrived before the wait started, even though the host has already
        //   torn down and can never deliver another output callback.
        // Why it exists: the helper registered its quiescence fallback before consulting
        //   the evidence it was handed, so the two raced on the host queue. A pane that
        //   prints and is immediately torn down -- the common shape -- made every such
        //   wait a coin flip, surfacing as an unexplained `#expect` failure at the wait
        //   line.
        // Scenario: `just test` runs its steps as a parallel pool; under that load the
        //   host queue won the race often enough to fail the gate roughly one run in five.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("__SETTLED__"))
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

    @Test("waiting on output the tape no longer holds reports why, immediately", .timeLimit(.minutes(1)))
    func waitForEvictedOutputFailsImmediately() async throws {
        // Intent: a wait whose answer can no longer be inside the pane's flight tape resolves
        //   at once, as a recorded issue naming the loss, instead of suspending on a live pane
        //   that will never quiesce.
        // Why it exists: `waitForOutput` reads bounded evidence but reads like an unbounded
        //   "was this ever printed?" question. When the answer has already been evicted the
        //   wait is not slow, it is unsatisfiable -- and because a live pane never quiesces it
        //   burned the whole test time limit before reporting anything, pointing at the wait
        //   line rather than at the loss.
        // Scenario: the 2026-08-03 gate hang in
        //   `applicationTerminationClosesMultipleLivePanes`, where the chatty probe printed
        //   `__READY__` once and then wrote 4 KiB forever, so the marker was long gone before
        //   the wait for it was armed (fix fdb9ec6).
        //
        // The tape retains nothing at all, so the loss is a property of the host this test
        // built rather than of how fast a flood raced the machine it runs on.
        let pane = try await startChildlessHost(
            flightTapeConfiguration: .retainingNothing
        )
        let host = pane.host
        #expect(pane.channel.writeFromChild(Array("__READY__".utf8)))
        // Parsed screen state, not the tape: it is the one evidence a zero-retention tape
        // cannot lose, and it proves the host applied the marker before the wait below.
        #expect(await host.waitForSnapshot { $0.fencedSnapshot().screenText.contains("__READY__") })

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

    @Test("an armed wait outrun by the pane reports the loss instead of waiting on", .timeLimit(.minutes(1)))
    func armedWaitBeyondRetentionReportsLoss() async throws {
        // Intent: a wait armed before output that exceeds the tape's retention resolves as a
        //   loss report rather than as an absence, so the bound on an armed match is loud.
        // Why it exists: an armed match is bounded by the tape rather than absolute, and the
        //   whole reason that bound is acceptable is that overrunning it is reported. A silent
        //   armed wait would be the hang this suite already paid for once, with no clue in it.
        // Scenario: the wait is armed in time and still cannot answer, which is the failure a
        //   test author has no other way to tell apart from "the child never printed it".
        let pane = try await startChildlessHost(
            flightTapeConfiguration: .retainingNothing
        )
        let host = pane.host
        let marker = host.expectOutput(containing: Array("__MARKER__".utf8))

        var answer: Bool?
        await withKnownIssue("the wait must say the pane outran it") {
            #expect(pane.channel.writeFromChild(Array("__MARKER__".utf8)))
            answer = await value(of: Task { await marker.satisfied() }, withinMilliseconds: 3000)
        }
        #expect(answer == .some(false))
        await host.close()
    }

    @Test("a needle straddling a reported loss does not satisfy a wait", .timeLimit(.minutes(1)))
    func needleStraddlingLossDoesNotMatch() async throws {
        // Intent: a wait reports loss rather than joining output from before a gap to output
        //   after it, even when the child did print the whole needle contiguously and the tape
        //   still holds its tail.
        // Why it exists: a match is decided within one uninterrupted run of output. A matcher
        //   that carried progress across a gap would answer `true` for a needle the child never
        //   emitted contiguously, which is worse than any missed match: it would make a wait
        //   agree with a claim about ordering that the evidence cannot support.
        // Scenario: the tape holds one event, so the head of the needle is evicted by the tail
        //   of the needle.
        let pane = try await startChildlessHost(
            flightTapeConfiguration: .retainingOneEvent
        )
        let host = pane.host
        #expect(pane.channel.writeFromChild(Array("__HEAD__".utf8)))
        // Waiting on the screen between the two writes is what makes them two applied chunks,
        // so the tail's own event is what evicts the head's.
        #expect(await host.waitForSnapshot { $0.fencedSnapshot().screenText.contains("__HEAD__") })
        #expect(pane.channel.writeFromChild(Array("__TAIL__".utf8)))
        #expect(await host.waitForSnapshot {
            $0.fencedSnapshot().screenText.contains("__HEAD____TAIL__")
        })

        var answer: Bool?
        await withKnownIssue("the wait must report the gap rather than match across it") {
            answer = await value(
                of: Task { await host.waitForOutput(containing: Array("__HEAD____TAIL__".utf8)) },
                withinMilliseconds: 3000
            )
        }
        #expect(answer == .some(false))
        await host.close()
    }

    @Test("input the host transmits never satisfies a wait on output", .timeLimit(.minutes(1)))
    func transmittedInputDoesNotSatisfyOutputWait() async throws {
        // Intent: bytes the host writes toward the child do not answer a wait for the same
        //   bytes as child output.
        // Why it exists: the tape carries both directions on one stream, so a wait that read
        //   every event would be satisfied by the pane's own keystrokes. A test asserting that
        //   a program echoed something would then pass without the program running at all.
        // Scenario: the child end is raw, so nothing the host writes comes back as output --
        //   the only way this wait can be satisfied is by a real write from the child.
        let pane = try await startChildlessHost()
        let host = pane.host
        let echoed = host.expectOutput(containing: Array("__PING__".utf8))

        host.sendPaste("__PING__")
        #expect(await pollUntil(
            { String(decoding: pane.channel.bytesReceivedFromHost(), as: UTF8.self)
                .contains("__PING__") },
            within: .seconds(20)
        ))
        // Still unsatisfied after the bytes have crossed the descriptor toward the child.
        #expect(await value(of: Task { await echoed.satisfied() }, withinMilliseconds: 500) == nil)

        // The positive control: the same bytes, this time printed by the child.
        #expect(pane.channel.writeFromChild(Array("__PING__".utf8)))
        #expect(await echoed.satisfied())
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
        //   noise that no bounded window could have held.
        let pane = try await startChildlessHost()
        let host = pane.host
        let expectation = host.expectOutput(containing: Array("__LATE__".utf8))
        // Armed here for the same reason as the match under test: after the flood,
        // nothing may ask about output any more. It is what splits the marker across two
        // applied chunks, which is what a PTY read boundary landing inside it looks like.
        let firstHalfApplied = host.expectOutput(containing: Array("__LA".utf8))

        let flood = [UInt8](repeating: UInt8(ascii: "f"), count: 64 * 1024)
        for _ in 0..<2 { #expect(pane.channel.writeFromChild(flood)) }
        #expect(pane.channel.writeFromChild(Array("__LA".utf8)))
        #expect(await firstHalfApplied.satisfied())
        #expect(pane.channel.writeFromChild(Array("TE__".utf8)))

        #expect(await expectation.satisfied())
        await host.close()
    }

    @Test("a host with a wait armed for the whole stream takes a megabyte of output", .timeLimit(.minutes(1)))
    func hostWithArmedWaitTakesLargeOutput() async throws {
        // Intent: how much output a wait observes does not bound how much output the host can
        //   take -- applying thousands of chunks with a wait reading every one of them costs no
        //   more stack, and no more retained output in the wait, than applying one.
        // Why it exists: the failure this guards is process death, not a failed expectation.
        //   A wait that accumulated the stream it matched against, or that grew a closure per
        //   chunk, killed the whole test process a few hundred kilobytes in, reported as
        //   `exited with unexpected signal code 10` and naming no test at all -- so nothing
        //   below asserts on stack depth, and the byte count is the whole point of the test.
        // Scenario: a wait for a marker that never comes stays armed across the entire flood,
        //   which is what every `expectOutput` before a chatty child looks like.
        let pane = try await startChildlessHost()
        let host = pane.host
        // Never satisfied, so every chunk of the flood is read and matched against it.
        let never = host.expectOutput(containing: Array("__NEVER__".utf8))
        let tail = host.expectOutput(containing: Array("__TAIL__".utf8))

        let flood = [UInt8](repeating: UInt8(ascii: "x"), count: 64 * 1024)
        for _ in 0..<16 { #expect(pane.channel.writeFromChild(flood)) }
        #expect(pane.channel.writeFromChild(Array("\r\n__TAIL__".utf8)))

        #expect(await tail.satisfied())
        // A satisfied wait implies the terminal has already applied the matched bytes: the tape
        // records before the terminal feeds, so only the fence the wait reads through puts the
        // two in this order.
        #expect(host.fencedSnapshot().screenText.contains("__TAIL__"))
        #expect(host.holdsOutputWaitSubscription(never))
        await host.close()
    }

    @Test("a wait joins retained output to the stream after it as one run of bytes", .timeLimit(.minutes(1)))
    func waitJoinsRetainedOutputToLaterStream() async throws {
        // Intent: a wait armed after output has already been applied matches the retained
        //   output and every later chunk as one ordered stream, with no gap across the join.
        // Why it exists: a wait matches incrementally and never rescans, so a byte dropped at
        //   the join between the retained read and the notice-driven reads after it is
        //   invisible until some later wait fails for the wrong reason. A needle that spans the
        //   join is the only assertion that cannot pass while such a byte is missing.
        // Scenario: the child printed before anything asked about it, then keeps printing --
        //   the shape a pane that is already running when a test arrives always has.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("ALPHA"))

        // Spans the join twice over: its first five bytes are only in the retained read, and
        // its last five only arrive after two more read turns.
        let joined = host.expectOutput(containing: Array("ALPHABETAGAMMA".utf8))
        #expect(await pane.writeFromChild("BETA"))
        #expect(await pane.writeFromChild("GAMMA"))

        #expect(await joined.satisfied())
        await host.close()
    }

    @Test("a wait gives up its subscription at every terminal outcome", .timeLimit(.minutes(1)))
    func waitGivesUpSubscriptionAtEveryOutcome() async throws {
        // Intent: quiescence, cancellation, and a synchronous timeout each end a wait's
        //   subscription to the pane's tape, and a host reaches quiescence with a wait
        //   outstanding.
        // Why it exists: the subscription is the host's only reference to a wait, so it is what
        //   keeps the wait's matcher -- and every fixture the test that armed it captured --
        //   alive. Nothing on the host clears recorder notices, so a wait that did not detach
        //   itself would hold a whole test's fixtures past the test. The notice also fires on
        //   the host queue, where fencing the host to detach would deadlock the very teardown
        //   the wait is watching for.
        let pane = try await startChildlessHost()
        let host = pane.host

        let cancelled = host.expectOutput(containing: Array("__CANCELLED__".utf8))
        let task = Task { await cancelled.satisfied() }
        #expect(await value(of: task, withinMilliseconds: 200) == nil)
        task.cancel()
        #expect(await pollUntil(
            { host.holdsOutputWaitSubscription(cancelled) == false },
            within: .seconds(20)
        ))

        let timedOut = host.expectOutput(containing: Array("__TIMED_OUT__".utf8))
        #expect(timedOut.satisfied(within: .milliseconds(50)) == false)
        #expect(await pollUntil(
            { host.holdsOutputWaitSubscription(timedOut) == false },
            within: .seconds(20)
        ))

        // Outstanding across the whole teardown ladder, which is what proves detaching on
        // quiescence cannot be what lets the host quiesce.
        let outstanding = host.expectOutput(containing: Array("__OUTSTANDING__".utf8))
        #expect(host.holdsOutputWaitSubscription(outstanding))
        await host.close()
        #expect(await pollUntil(
            { host.holdsOutputWaitSubscription(outstanding) == false },
            within: .seconds(20)
        ))
        #expect((await host.resourceSnapshot()).isReleased)
    }

    @Test("a host on a childless channel lives and quiesces with nothing to reap", .timeLimit(.minutes(1)))
    func childlessChannelHostReachesQuiescence() async throws {
        // Intent: a host whose PTY has no child behind it starts, takes output,
        //   transmits input, resizes, and reaches quiescence owning no process.
        // Why it exists: source installation was the one process-plane step that
        //   assumed a child existed, so a channel without one could not converge.
        // Scenario: the test owns the child end of a real PTY and plays the child.
        let channel = try ChildlessPTYChannel()
        let host = try makeHost(spawner: channel)
        await host.start(makeLaunchInput(command: childlessLaunchCommand))
        channel.writeFromChild(Array("__READY__".utf8))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))

        let running = await host.resourceSnapshot()
        #expect(running.hasOpenMaster)
        #expect(running.hasLeader == false)
        #expect(running.hasSession == false)

        host.send(Array("typed".utf8))
        host.resize(unpinned(columns: 100, rows: 31))
        #expect(await host.drainedPendingInputByteCount() == 0)
        await host.close()

        let released = await host.resourceSnapshot()
        #expect(released.isReleased)
        #expect(released.census.forcedQuiescenceCount == 0)
    }

    @Test("bytes cross a childless channel in both directions", .timeLimit(.minutes(1)))
    func childlessChannelCarriesBytesBothWays() async throws {
        // Intent: output written at the child end reaches a fenced snapshot through
        //   the host's own read path, and input reaches the child end byte for byte.
        // Why it exists: input capture records what the reducer submitted, not what
        //   crossed the master, so transmission itself had no coverage.
        // Scenario: the test writes as the child, then reads back what the host sent.
        let channel = try ChildlessPTYChannel()
        let host = try makeHost(spawner: channel)
        await host.start(makeLaunchInput(command: childlessLaunchCommand))

        channel.writeFromChild(Array("alpha".utf8))
        #expect(await host.waitForSnapshot {
            $0.fencedSnapshot().screenText.contains("alpha")
        })

        host.send(Array("typed\r".utf8))
        // The whole transmission, not a suffix of it: the launch command line the
        // policy hands the host is itself written to the PTY, and a childless channel
        // receives it exactly as a shell would.
        let transmitted = Array("\(childlessLaunchCommand)\n".utf8) + Array("typed\r".utf8)
        #expect(await pollUntil({
            channel.bytesReceivedFromHost() == transmitted
        }, within: .seconds(20)))
        await host.close()
    }

    @Test("a resize on a childless channel reaches the descriptor", .timeLimit(.minutes(1)))
    func childlessChannelResizeReachesDescriptor() async throws {
        // Intent: the host's TIOCSWINSZ lands on the adopted descriptor, and the
        //   terminal geometry moves with it.
        // Why it exists: a fixture that only carried bytes could be a socket pair.
        //   A window size read back at the child end is what proves a real PTY.
        // Scenario: the test reads TIOCGWINSZ at the child end after a resize.
        let channel = try ChildlessPTYChannel()
        let host = try makeHost(spawner: channel)
        await host.start(makeLaunchInput(command: childlessLaunchCommand))
        channel.writeFromChild(Array("__READY__".utf8))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        #expect(channel.childWindowSize()?.ws_col == 80)

        host.resize(unpinned(columns: 100, rows: 31))
        let snapshot = await host.snapshot()

        #expect(snapshot.geometry.columns == 100)
        #expect(snapshot.geometry.rows.count == 31)
        let resized = try #require(channel.childWindowSize())
        #expect(resized.ws_col == 100)
        #expect(resized.ws_row == 31)
        await host.close()
    }

    @Test("output cut by read boundaries replays from the tape to the live screen", .timeLimit(.minutes(1)))
    func boundaryStraddlingOutputReplaysFromTheTape() async throws {
        // Intent: the byte stream the terminal parses, and the one the tape records, are
        //   the stream the kernel delivered -- whatever offsets the reads landed on.
        // Why it exists: a read turn now feeds the terminal from successive offsets of one
        //   reused buffer and records a single tape event for the whole turn, so a sequence
        //   cut by a read boundary is the case that would lose or duplicate bytes.
        // Scenario: a saturating writer floods sequences whose lengths sweep every offset
        //   relative to the 1024-byte kernel buffer, so some copy of each one is cut.
        let pane = try await startChildlessHost()
        let host = pane.host

        let applied = host.expectOutput(containing: straddleCompletionMarker)
        #expect(pane.channel.writeFromChild(boundaryStraddlingPayload(), pace: .saturating))
        #expect(await applied.satisfied())

        let capture = host.fencedFlightRecordingCapture()
        let recording = NeutralTerminalRecording(
            provenance: .liveCapture(),
            initial: .init(
                columns: capture.origin.initial.columns,
                rows: capture.origin.initial.rows
            ),
            events: capture.snapshot.events.map(\.event)
        )

        #expect(try recording.replay(machineHostname: MachineHostname.posix) == (await host.snapshot()))
        await host.close()
    }

    @Test("no recorded feed event exceeds one read turn", .timeLimit(.minutes(1)))
    func recordedFeedEventsStayWithinTheTurnCap() async throws {
        // Intent: a `.feed` boundary on the tape is a turn boundary, and a turn is capped.
        // Why it exists: the cap is what bounds the longest contiguous slice the owner queue
        //   runs without yielding, and the tape is where a turn that outgrew it would show.
        // Scenario: the same saturated flood, read back as recorded feed sizes.
        let pane = try await startChildlessHost()
        let host = pane.host

        let applied = host.expectOutput(containing: straddleCompletionMarker)
        #expect(pane.channel.writeFromChild(boundaryStraddlingPayload(), pace: .saturating))
        #expect(await applied.satisfied())

        let feeds = host.fencedFlightRecordingCapture().snapshot.events.compactMap(fedBytes)

        #expect(feeds.isEmpty == false)
        #expect(feeds.allSatisfy { $0.count <= readTurnLimit }, "largest feed: \(feeds.map(\.count).max() ?? 0)")
        await host.close()
    }

    @Test("a query is on the tape before the reply it produced", .timeLimit(.minutes(1)))
    func queryIsRecordedBeforeItsReply() async throws {
        // Intent: the feed carrying a query is recorded ahead of the write carrying its
        //   answer, and the answer still crosses the descriptor.
        // Why it exists: a turn records one feed at its end, so a reply flushed before that
        //   record would put the answer on the tape ahead of the question, and a replay of
        //   the tape would then read as a terminal answering something nobody asked.
        // Scenario: the child prints text ending in a cursor-position report request.
        let pane = try await startChildlessHost()
        let host = pane.host
        let query = Array("\u{1B}[6n".utf8)

        let submission = host.fencedFlightRecordingOriginFromNow().cursor
        #expect(await pane.writeFromChild(Array("hello".utf8) + query))
        #expect(await host.settledPendingInputByteCount() == 0)

        let events = host.fencedFlightRecording(from: submission).events
        let queryIndex = try #require(events.firstIndex {
            fedBytes($0).map { $0.suffix(query.count) == query[...] } == true
        })
        let replyIndex = try #require(events.firstIndex {
            guard let bytes = writtenBytes($0) else { return false }
            return bytes.starts(with: [0x1B, UInt8(ascii: "[")]) && bytes.last == UInt8(ascii: "R")
        })
        let reply = try #require(writtenBytes(events[replyIndex]))

        #expect(queryIndex < replyIndex)
        #expect(await pollUntil({
            pane.channel.bytesReceivedFromHost().suffix(reply.count) == reply[...]
        }, within: .seconds(20)))
        await host.close()
    }

    @Test("every recorded write states who chose its bytes", .timeLimit(.minutes(1)))
    func recordedWritesStateTheirChooser() async throws {
        // Intent: the tape separates the three choosers of bytes going to the child -- the
        //   user, the pane's own business, and the terminal's answer to a query -- and the
        //   pane's launch line is the pane's own.
        // Why it exists: a reply and a plain user send are byte-identical and both cross with
        //   no origin stamp, so a reader that could not ask the tape would have to guess, and
        //   a wait for the user's input would end on an answer nobody typed.
        // Scenario: focus reporting is on, the user presses a key, focus arrives, and then
        //   the child asks for the cursor position.
        let pane = try await startChildlessHost()
        let host = pane.host
        #expect(await pane.writeFromChild("\u{1B}[?1004h"))
        let submission = host.fencedFlightRecordingOriginFromNow().cursor

        host.sendKey(.up, modifiers: [])
        #expect(await host.settledPendingInputByteCount() == 0)
        host.sendFocus(true)
        #expect(await host.settledPendingInputByteCount() == 0)
        #expect(await pane.writeFromChild("\u{1B}[6n"))
        #expect(await host.settledPendingInputByteCount() == 0)

        let writes = host.fencedFlightRecording(from: submission).events
            .filter { writtenBytes($0) != nil }
        #expect(writes.compactMap(writtenBytes) == [
            Array("\u{1B}[A".utf8),
            Array("\u{1B}[I".utf8),
            Array("\u{1B}[1;1R".utf8),
        ])
        #expect(writes.map(\.writeAttribution) == [.user, .pane, .reply])

        let lifetime = host.fencedFlightRecordingCapture().snapshot.events
            .filter { writtenBytes($0) != nil }
        #expect(
            lifetime.first?.writeAttribution == .pane,
            "the launch line is the pane's own business, not the user's"
        )
        await host.close()
    }
}

/// Exercises the owner against a real child process: launch ownership, signals, and exit.
///
/// Serialized on three resources that belong to the test process as a whole and cannot be
/// split between concurrent cases: the child-process table these tests fork into and reap
/// from, the process groups and sessions they signal, and the descriptor table the census
/// counts. Two of these running at once would each see the other there.
@Suite(.serialized)
struct TerminalPTYHostChildProcessTests {
    @Test("long launch input waits for a synthetic child to enter raw mode", .timeLimit(.minutes(1)))
    func longLaunchInputWaitsForSyntheticRawMode() async throws {
        // Intent: initial input held while the child is canonical crosses byte-exact after the
        //   child opens a lossless raw-mode path.
        // Why it exists: launch input used to cross immediately and xnu silently discarded the
        //   tail and newline of any command longer than its canonical input queue.
        // Scenario: a synthetic child stays canonical briefly, switches to raw, and verifies
        //   every byte of a 4096-byte launch submission. The waits are hang guards.
        let byteCount = 4096
        let probe = try probeExecutable()
        let spawner = ProgramReplacingTerminalPTYSpawner(
            program: probe,
            arguments: ["PTYProbe", "signaled-raw-launch", String(byteCount)]
        )
        let host = try makeHost(spawner: spawner)
        let completion = InputCompletionRecorder(expecting: 1)
        let canonicalReady = host.expectOutput(containing: Array("__CANONICAL_LAUNCH_READY__".utf8))

        await host.start(
            makeLaunchInput(command: String(repeating: "Z", count: byteCount - 1)),
            onInitialInputCompletion: { completion.signal($0) }
        )

        guard canonicalReady.satisfied(within: .seconds(30)) else {
            throw POSIXError(.ETIMEDOUT)
        }
        #expect(completion.results.isEmpty)
        try spawner.requestRawMode()
        #expect(completion.waitForAll(within: .seconds(30)))
        #expect(completion.results == [.delivered])
        #expect(await host.waitForResult() == .exited(.exited(0)))
        #expect(String(decoding: host.outputBytes(), as: UTF8.self).contains(
            "__RAW_LAUNCH_COUNT__=\(byteCount)"
        ))
    }

    @Test("zsh, bash, and fish execute long launch input byte-exact", .timeLimit(.minutes(1)))
    func supportedShellsExecuteLongLaunchInputByteExact() async throws {
        // Intent: every supported interactive shell reaches raw mode, receives the full launch
        //   line, and executes it.
        // Why it exists: the gate relies on each supported shell's real line editor to open the
        //   lossless path that makes commands beyond the canonical capacity deliverable.
        // Scenario: zsh, Bash, and fish each print a 4096-byte payload behind a marker that the
        //   echoed command cannot contain. The 30 second waits are hang guards.
        let payload = String(repeating: "Z", count: 4096)
        let marker = "__LONG_LAUNCH_BYTE_EXACT__="
        let shells = try ["zsh", "bash", "fish"].map { try findExecutable(named: $0) }

        for shell in shells {
            let command: String
            if shell.hasSuffix("/fish") {
                command = "set p \(shellQuote(payload)); set m LONG_LAUNCH_BYTE_EXACT; "
                    + "printf '__%s__=%s\\n' $m $p; exit"
            } else {
                command = "p=\(shellQuote(payload)); m=LONG_LAUNCH_BYTE_EXACT; "
                    + "printf '__%s__=%s\\n' \"$m\" \"$p\"; exit"
            }
            var input = makeLaunchInput(command: command)
            input.accountShell = shell
            input.executablePaths = [shell]
            let host = try makeHost()
            let exactOutput = host.expectOutput(containing: Array((marker + payload).utf8))

            await host.start(input)

            guard exactOutput.satisfied(within: .seconds(30)) else {
                throw POSIXError(.ETIMEDOUT)
            }
            #expect(await host.waitForResult() == .exited(.exited(0)))
            let output = String(decoding: host.outputBytes(), as: UTF8.self)
            #expect(output.contains(marker + payload), "\(shell) did not deliver launch input byte-exact")
        }
    }

    @Test("canonical input clearing leaves later short lines deliverable", .timeLimit(.minutes(1)))
    func canonicalInputClearingLeavesLaterShortLinesDeliverable() async throws {
        // Intent: the delivery gate keeps no stale occupancy state after the line discipline
        //   clears bytes that already crossed the master.
        // Why it exists: a gate that copied kernel occupancy would miss editing and flush events
        //   and could keep withholding input after the tty was ready for a short line.
        // Scenario: one child handles VKILL and another handles an out-of-band tcflush; each
        //   then reads a short probe line. The 30 second waits are hang guards.
        let probe = try probeExecutable()

        let killSpawner = ProgramReplacingTerminalPTYSpawner(
            program: probe,
            arguments: ["PTYProbe", "canonical-hold", "probe"]
        )
        let killHost = try makeHost(spawner: killSpawner)
        let killReady = killHost.expectOutput(containing: Array("__CANONICAL_READY__".utf8))
        var noLaunchInput = makeLaunchInput(command: "")
        noLaunchInput.launchCommand = nil
        await killHost.start(noLaunchInput)
        guard killReady.satisfied(within: .seconds(30)) else { throw POSIXError(.ETIMEDOUT) }

        try submitAndAwait(Array("stale".utf8), to: killHost)
        try submitAndAwait([0x15], to: killHost)
        try submitAndAwait(Array("probe\n".utf8), to: killHost)
        #expect(await killHost.waitForResult() == .exited(.exited(0)))
        #expect(String(decoding: killHost.outputBytes(), as: UTF8.self).contains(
            "__CANONICAL_INPUT__=probe"
        ))

        let flushSpawner = ProgramReplacingTerminalPTYSpawner(
            program: probe,
            arguments: ["PTYProbe", "canonical-flush", "probe"]
        )
        let flushHost = try makeHost(spawner: flushSpawner)
        let flushReady = flushHost.expectOutput(containing: Array("__CANONICAL_READY__".utf8))
        let flushed = flushHost.expectOutput(containing: Array("__CANONICAL_FLUSHED__".utf8))
        await flushHost.start(noLaunchInput)
        guard flushReady.satisfied(within: .seconds(30)) else { throw POSIXError(.ETIMEDOUT) }

        try submitAndAwait(Array("stale".utf8), to: flushHost)
        try flushSpawner.sendSignal(SIGUSR2)
        guard flushed.satisfied(within: .seconds(30)) else { throw POSIXError(.ETIMEDOUT) }
        try submitAndAwait(Array("probe\n".utf8), to: flushHost)
        #expect(await flushHost.waitForResult() == .exited(.exited(0)))
        #expect(String(decoding: flushHost.outputBytes(), as: UTF8.self).contains(
            "__CANONICAL_INPUT__=probe"
        ))
    }

    @Test("oversized canonical input times out without wedging later input", .timeLimit(.minutes(1)))
    func oversizedCanonicalInputTimesOutWithoutWedge() async throws {
        // Intent: a line the canonical queue cannot hold never reaches the master, and its
        //   rejection leaves the queue able to accept the next short line.
        // Why it exists: xnu otherwise accepts the write while silently discarding its tail
        //   and every later byte offered to the full input queue.
        // Scenario: a child stays canonical, an oversized run expires, then a probe line exits.
        // The injected 50 ms wait is meant to expire; the 20 second waits below are hang guards.
        let host = try makeHost(canonicalInputWait: .milliseconds(50))
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) canonical-hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__CANONICAL_READY__".utf8)))
        let writeBaseline = host.inputWrites().count
        let oversized = InputCompletionRecorder(expecting: 1)
        let probe = InputCompletionRecorder(expecting: 1)

        host.send([UInt8](repeating: 0x61, count: CanonicalInputDeliveryGate.capacity)) {
            oversized.signal($0)
        }

        #expect(oversized.waitForAll(within: .seconds(20)))
        #expect(oversized.results == [.rejected(.canonicalModeTimeout)])
        #expect(host.inputWrites().count == writeBaseline)
        host.send(Array("probe\n".utf8)) { probe.signal($0) }
        #expect(probe.waitForAll(within: .seconds(20)))
        #expect(probe.results == [.delivered])
        #expect(await host.waitForResult() == .exited(.exited(0)))
        #expect(String(decoding: host.outputBytes(), as: UTF8.self).contains("__CANONICAL_INPUT__=probe"))
    }

    @Test("canonical timeout preserves an already queued short line", .timeLimit(.minutes(1)))
    func canonicalTimeoutPreservesQueuedShortLine() async throws {
        // Intent: rejecting an oversized head submission releases only its unwritten bytes
        //   and leaves a later short line queued for ordinary delivery.
        // Why it exists: head rejection must not rebase, discard, or misattribute the records
        //   behind the canonical hold.
        // Scenario: both submissions enter before the intended 50 ms timeout; the oversized
        //   one is rejected, then the queued probe reaches the canonical child and exits.
        let oversizedBytes = [UInt8](
            repeating: UInt8(ascii: "a"),
            count: CanonicalInputDeliveryGate.capacity
        )
        let probeBytes = Array("probe\n".utf8)
        let host = try makeHost(canonicalInputWait: .milliseconds(50))
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) canonical-hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__CANONICAL_READY__".utf8)))
        let writeBaseline = host.inputWrites().count
        let oversized = InputCompletionRecorder(expecting: 1)
        let probe = InputCompletionRecorder(expecting: 1)

        host.send(oversizedBytes) { oversized.signal($0) }
        host.send(probeBytes) { probe.signal($0) }
        #expect(await waitForSnapshot(of: host) {
            $0.pendingInputByteCount == oversizedBytes.count + probeBytes.count
        })

        #expect(oversized.waitForAll(within: .seconds(20)))
        #expect(oversized.results == [.rejected(.canonicalModeTimeout)])
        #expect(probe.waitForAll(within: .seconds(20)))
        #expect(probe.results == [.delivered])
        #expect(host.inputWrites().count == writeBaseline + 1)
        #expect(await host.resourceSnapshot().pendingInputByteCount == 0)
        #expect(await host.waitForResult() == .exited(.exited(0)))
        #expect(String(decoding: host.outputBytes(), as: UTF8.self).contains(
            "__CANONICAL_INPUT__=probe"
        ))
    }

    @Test("canonical input translation cannot disguise an oversized run", .timeLimit(.minutes(1)))
    func canonicalInputTranslationCannotDisguiseOversizedRun() async throws {
        let cases: [(String, [UInt8])] = [
            (
                "inlcr",
                [UInt8](repeating: 0x61, count: CanonicalInputDeliveryGate.capacity - 1)
                    + [0x0A, 0x62]
            ),
            (
                "igncr",
                [UInt8](repeating: 0x61, count: CanonicalInputDeliveryGate.capacity - 1)
                    + [0x0D, 0x62]
            ),
        ]

        for (mode, bytes) in cases {
            let host = try makeHost(canonicalInputWait: .milliseconds(50))
            await host.start(makeLaunchInput(
                command: "exec \(try probeExecutable()) canonical-\(mode) \"$0\""
            ))
            #expect(await host.waitForOutput(containing: Array("__CANONICAL_READY__".utf8)))
            let writeBaseline = host.inputWrites().count
            let completion = InputCompletionRecorder(expecting: 1)

            host.send(bytes) { completion.signal($0) }

            #expect(completion.waitForAll(within: .seconds(20)))
            #expect(completion.results == [.rejected(.canonicalModeTimeout)])
            #expect(host.inputWrites().count == writeBaseline)
            await host.close()
        }
    }

    @Test("sub-capacity canonical input and large raw input keep their delivery behavior", .timeLimit(.minutes(1)))
    func deliverableCanonicalAndRawInputAreUnchanged() async throws {
        let canonical = try makeHost(canonicalInputWait: .milliseconds(50))
        await canonical.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) canonical-hold \"$0\""
        ))
        #expect(await canonical.waitForOutput(containing: Array("__CANONICAL_READY__".utf8)))
        let canonicalCompletion = InputCompletionRecorder(expecting: 1)
        canonical.send(Array("short\n".utf8)) { canonicalCompletion.signal($0) }
        #expect(canonicalCompletion.waitForAll(within: .seconds(20)))
        #expect(canonicalCompletion.results == [.delivered])
        #expect(await canonical.waitForResult() == .exited(.exited(0)))

        let raw = try makeHost()
        let byteCount = 2 * 1024 * 1024
        await raw.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) raw-count \(byteCount)"
        ))
        #expect(await raw.waitForOutput(containing: Array("__RAW_READY__".utf8)))
        let rawCompletion = InputCompletionRecorder(expecting: 1)
        raw.send([UInt8](repeating: 0x5A, count: byteCount)) { rawCompletion.signal($0) }
        #expect(rawCompletion.waitForAll(within: .seconds(30)))
        #expect(rawCompletion.results == [.delivered])
        #expect(await raw.waitForResult() == .exited(.exited(0)))
        #expect(String(decoding: raw.outputBytes(), as: UTF8.self).contains("__RAW_COUNT__=\(byteCount)"))
    }

    @Test("consumption fence pairs final frame damage with exit metadata", .timeLimit(.minutes(1)))
    func consumptionFencePairsFrameAndExitMetadata() async throws {
        // Intent: one synchronous consumer read returns terminal damage and the lifecycle
        //   result from the same owner-queue boundary, while the pane's tape independently
        //   carries the output that produced that frame.
        // Why it exists: reading lifecycle metadata and frame state through separate
        //   fences both undercounted benchmark stall time and allowed intervening owner
        //   work to make the values describe different moments.
        // Scenario: a child prints its final frame and exits; the pane consumes the
        //   redraw and exit evidence together before publishing the session end.
        let host = try makeHost(flightTapeConfiguration: .complete)
        _ = host.fencedFrameState()
        await host.start(makeLaunchInput(command: "printf '__FINAL_FRAME__'; exit 7"))
        #expect(await host.waitForResult() == .exited(.exited(7)))

        let consumption = host.fencedConsumptionState()

        #expect(consumption.frameState.damage != .none)
        #expect(consumption.frameState.terminal.screenText.contains("__FINAL_FRAME__"))
        #expect(consumption.result == .exited(.exited(7)))
        #expect(host.tapeEvents().contains {
            if case let .feed(bytes) = $0 {
                return String(decoding: bytes, as: UTF8.self).contains("__FINAL_FRAME__")
            }
            return false
        })
        await host.close()
    }

    @Test("controlled login shell observes PTY ownership, cwd, environment, IO, and exit", .timeLimit(.minutes(1)))
    func launchRecipeAndDuplexIO() async throws {
        let host = try TerminalPTYHost(
            initialDimensions: .init(columns: 80, rows: 24),
            bootstrapExecutable: try bootstrapExecutable(),
            flightTapeConfiguration: .complete
        )
        let command = "exec \(try probeExecutable()) ownership \"$0\""

        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        host.send(Array("ordered-input\n".utf8))
        let result = await host.waitForResult()
        let output = String(decoding: host.outputBytes(), as: UTF8.self)

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

        let output = String(decoding: host.outputBytes(), as: UTF8.self)
        #expect(output.contains("__CWD__=/"))
        #expect(output.contains("__INPUT__=fallback"))
    }

    @Test("resize is ordered between output and keeps child and terminal geometry equal", .timeLimit(.minutes(1)))
    func orderedResize() async throws {
        let host = try TerminalPTYHost(
            initialDimensions: .init(columns: 80, rows: 24),
            bootstrapExecutable: try bootstrapExecutable(),
            flightTapeConfiguration: .complete
        )
        let command = "exec \(try probeExecutable()) resize \"$0\""

        await host.start(makeLaunchInput(command: command))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        host.resize(unpinned(columns: 100, rows: 31))
        let snapshot = await host.snapshot()
        host.send(Array("done\n".utf8))
        #expect(await host.waitForResult() == .exited(.exited(0)))
        let output = String(decoding: host.outputBytes(), as: UTF8.self)

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
        let submissionBaseline = host.tapeSubmissions().count

        host.send(Array("prefix-".utf8))
        host.resize(unpinned(columns: 96, rows: 28))
        host.send(Array("continue\n".utf8))

        #expect(await host.waitForResult() == .exited(.exited(0)))
        #expect(Array(host.tapeSubmissions().dropFirst(submissionBaseline)) == [
            .write(Array("prefix-".utf8)),
            .resize(columns: 96, rows: 28, pinned: false),
            .write(Array("continue\n".utf8)),
        ])

        host.send(Array("after-teardown".utf8))
        host.resize(unpinned(columns: 120, rows: 40))
        #expect(host.tapeSubmissions().count == submissionBaseline + 3)
    }

    @Test(
        "every applied geometry fact records one event stating its pinnedness",
        .timeLimit(.minutes(1))
    )
    func appliedGeometryRecordsPinnednessOnce() async throws {
        // Intent: each of the four geometry transitions -- pin at a new grid, pin at the
        //   grid already running, release to that same grid, release to a different one --
        //   records exactly one tape event, and each one states the pinnedness that applied.
        // Why it exists: pinnedness is the only thing a phone can key a Release control off.
        //   A transition that records nothing because the grid did not move would leave every
        //   replica reporting the pane as claimed for as long as that grid held.
        // Scenario: a claim, a re-claim at the same size, a take-back, and a later resize.
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let baseline = host.fencedFlightRecordingCapture().snapshot.events.count

        // A zero-row scroll between submissions closes the coalescing run, so nothing here
        // is superseded and every fact below reaches the applied boundary in order.
        host.resize(pinned(columns: 60, rows: 20))
        host.scroll(byRows: 0)
        host.resize(pinned(columns: 60, rows: 20))
        host.scroll(byRows: 0)
        host.resize(unpinned(columns: 60, rows: 20))
        host.scroll(byRows: 0)
        host.resize(unpinned(columns: 100, rows: 31))
        host.scroll(byRows: 0)

        // The fence runs on the same owner queue as every submission above, so it cannot
        // return before all of them have applied.
        let recorded = host.fencedFlightRecordingCapture().snapshot.events
            .dropFirst(baseline)
            .compactMap { event -> (Int, Int, Bool)? in
                guard case .resize(let columns, let rows, let pinned) = event.event else {
                    return nil
                }
                return (columns, rows, pinned)
            }

        #expect(recorded.map(\.0) == [60, 60, 60, 100])
        #expect(recorded.map(\.1) == [20, 20, 20, 31])
        #expect(recorded.map(\.2) == [true, true, false, false])

        await host.close()
    }

    @Test(
        "a pinnedness-only transition reaches neither the child nor the cells",
        .timeLimit(.minutes(1))
    )
    func pinnednessOnlyTransitionIsInvisibleToTheChild() async throws {
        // Intent: pinning and releasing a pane at the grid it already runs at raises no
        //   SIGWINCH and changes no cell content, even though each one records an event.
        // Why it exists: pinnedness is a presentation fact about who chose the grid. A
        //   claim at the current size that made a full-screen application redraw, or that
        //   reflowed the screen, would be a visible cost for no visible change.
        // Scenario: a phone claims a pane already showing its size, then hands it back,
        //   and only afterwards asks for a different grid.
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) resize \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let before = await host.snapshot().viewportText

        // A zero-row scroll closes the coalescing run without touching a cell or the child,
        // so both transitions actually apply rather than the first being superseded.
        host.resize(pinned(columns: 80, rows: 24))
        host.scroll(byRows: 0)
        host.resize(unpinned(columns: 80, rows: 24))
        host.scroll(byRows: 0)
        #expect(await host.snapshot().viewportText == before)

        // The probe reports the first SIGWINCH it receives and no other. If either
        // transition above had signalled, this would name the unchanged 80x24 grid.
        host.resize(unpinned(columns: 100, rows: 31))
        #expect(await host.waitForOutput(containing: Array("__WINCH__=31 100".utf8)))

        host.send(Array("done\n".utf8))
        #expect(await host.waitForResult() == .exited(.exited(0)))
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
        // Scenario: the owner is held inside a wheel completion while a drag's
        //   worth of grids arrives, then released -- the shape of a real drag on
        //   a pane whose reflow is slower than mouse-move arrival.
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) resize \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let baseline = host.tapeEvents().count

        let owner = OwnerHold()
        try owner.hold(host)
        for grid in [(84, 25), (88, 26), (92, 27), (96, 28)] {
            host.resize(unpinned(columns: grid.0, rows: grid.1))
        }
        host.resize(unpinned(columns: 100, rows: 31))
        owner.release()

        let applied = host.tapeEvents().dropFirst(baseline).filter {
            if case .resize = $0 { true } else { false }
        }
        #expect(applied == [.resize(columns: 100, rows: 31, pinned: false)])
        #expect(await host.waitForOutput(containing: Array("__WINCH__=31 100".utf8)))
        let snapshot = await host.snapshot()
        #expect(snapshot.geometry.columns == 100)
        #expect(snapshot.geometry.rows.count == 31)

        host.send(Array("done\n".utf8))
        #expect(await host.waitForResult() == .exited(.exited(0)))
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
        _ = host.fencedFrameState()

        host.resize(unpinned(columns: 100, rows: 31))
        var observedResize = false
        while let _ = await updates.next() {
            let frame = host.fencedFrameState()
            if frame.terminal.geometry.columns == 100,
               frame.terminal.geometry.rows.count == 31
            {
                observedResize = true
                break
            }
        }
        #expect(observedResize)

        host.send(Array("done\n".utf8))
        var observedResult: PaneProcessLifecycleResult?
        while let _ = await updates.next() {
            observedResult = host.fencedConsumptionState().result
            if observedResult != nil { break }
        }
        #expect(observedResult == .exited(.exited(0)))
        while await updates.next() != nil {}
        #expect((await host.resourceSnapshot()).census.updateSignalsAfterTermination == 0)
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
        let inputBaseline = host.inputWrites().count
        let delivered = InputCompletionRecorder(expecting: 1)

        host.send(Array("query\n".utf8)) { delivered.signal($0) }
        // Baselined after the user's own input has landed, because delivering it reports an
        // occurrence of its own. What this test rules out is a wake caused by the query.
        #expect(delivered.waitForAll(within: .seconds(20)))
        let signalsBeforeQuery = (await host.resourceSnapshot()).census.emittedUpdateSignalCount
        #expect(await host.waitForOutput(containing: Array("\u{1B}[6n".utf8)))
        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == signalsBeforeQuery)
        host.send(Array("USER".utf8))

        let result = await host.waitForResult()
        let output = String(decoding: host.outputBytes(), as: UTF8.self)
        let replies = host.replyWrites()
        let inputs = host.inputWrites()
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
        let output = String(decoding: host.outputBytes(), as: UTF8.self)
        #expect(result == .exited(.exited(0)), "result: \(String(describing: result))")
        #expect(output.contains("__COLOR_QUERY_OK__"), "output: \(output.debugDescription)")
        let replies = host.replyWrites()
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
            events: host.tapeEvents()
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
        #expect((await host.resourceSnapshot()).census.updateSignalsAfterTermination == 0)
    }

    @Test("a result-only drain emits its final update token", .timeLimit(.minutes(1)))
    func resultOnlyDrainEmitsFinalUpdate() async throws {
        let host = try makeHost()
        var input = makeLaunchInput(command: "")
        input.initialDimensions = .init(columns: 0, rows: 0)

        await host.start(input)
        #expect(await host.waitForResult() == .launchFailed(.invalidDimensions))

        var updates = host.updates.makeAsyncIterator()
        #expect(await updates.next() != nil)
        #expect(await updates.next() == nil)
        #expect((await host.resourceSnapshot()).census.emittedUpdateSignalCount == 1)
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
            let host = try makeHost()
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
        let output = Data(host.outputBytes())
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
            in: String(decoding: host.outputBytes(), as: UTF8.self)
        )

        #expect(kill(pid_t(pid), SIGUSR1) == 0)
        #expect(await host.waitForResult() == .exited(.exited(6)))
    }

    @Test("final output before EOF wakes the consumer without waiting for the exit", .timeLimit(.minutes(1)))
    func eofBeforeExitPublishesBeforeTheResult() async throws {
        // Intent: the last bytes a child prints reach the consumer at the EOF edge, while
        //   the child is still alive and its result still unreported.
        // Why it exists: publishing is now once per read turn instead of once per read, so
        //   the question of when the last turn publishes became load-bearing. `eofBeforeExit`
        //   below waits on the flight tape, which records before publishing and so cannot
        //   tell a published screen from a merely applied one.
        // Scenario: the child prints its markers, closes the PTY, and then waits for a
        //   signal the test only sends after it has seen the consumer woken.
        let host = try makeHost()
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) eof-first \"$0\""
        ))

        // Draining the frame is what a real consumer does on every signal, and the host only
        // re-signals redraw work once the last frame has been taken.
        let published = await host.waitForUpdate {
            $0.fencedFrameState().terminal.screenText.contains("__CLOSING_PTY__")
        }
        guard published else { throw POSIXError(.ETIMEDOUT) }
        #expect(await host.result() == nil)

        let pid = try taggedInt(
            "__PID__",
            in: String(decoding: host.outputBytes(), as: UTF8.self)
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
        let output = String(decoding: host.outputBytes(), as: UTF8.self)
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
        host.resize(unpinned(columns: 96, rows: 28))
        host.send(Array("continue\n".utf8))
        #expect(await host.waitForResult() == .exited(.exited(0)))

        let events = host.tapeEvents()
        let recording = NeutralTerminalRecording(
            provenance: .danTerm(test: "pty-output-resize-output"),
            initial: .init(columns: 80, rows: 24),
            events: events
        )
        let recorder = PTYRecordingRecorder(recording: recording)
        let encoded = try recorder.encoded()
        try recorder.writeIfRequested(name: "pty-output-resize-output")
        let decoded = try JSONDecoder().decode(NeutralTerminalRecording.self, from: encoded)

        #expect(try decoded.replay(machineHostname: MachineHostname.posix) == (await host.snapshot()))
        let resizeIndex = try #require(events.firstIndex {
            if case .resize = $0 { true } else { false }
        })
        #expect(events[..<resizeIndex].contains {
            if case .feed = $0 { true } else { false }
        })
        #expect(events[(resizeIndex + 1)...].contains {
            if case .feed = $0 { true } else { false }
        })
    }

    @Test("live flight recording preserves PTY chunk boundaries and resize order", .timeLimit(.minutes(1)))
    func liveFlightRecordingRoundTrip() async throws {
        let host = try TerminalPTYHost(
            initialDimensions: .init(columns: 80, rows: 24),
            bootstrapExecutable: bootstrapExecutable(),
            machineHostname: MachineHostname.posix
        )
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) recording \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__BEFORE_RESIZE__".utf8)))
        host.resize(unpinned(columns: 96, rows: 28))
        host.send(Array("continue\n".utf8))
        #expect(await host.waitForResult() == .exited(.exited(0)))

        let capture = host.fencedFlightRecordingCapture()
        let snapshot = capture.snapshot
        let fromNow = host.fencedFlightRecordingOriginFromNow()
        let liveSuffix = host.fencedFlightRecording(from: fromNow.cursor)
        // The capture's own halves are the whole replay: birth geometry from the origin, and
        // the ordered events from the snapshot fenced with it.
        let recording = NeutralTerminalRecording(
            provenance: .liveCapture(),
            initial: .init(
                columns: capture.origin.initial.columns,
                rows: capture.origin.initial.rows
            ),
            events: snapshot.events.map(\.event)
        )
        let resizeIndex = try #require(snapshot.events.firstIndex {
            if case .resize = $0.event { true } else { false }
        })

        #expect(capture.origin.initial == .init(columns: 80, rows: 24, pinned: false))
        #expect(try recording.replay(machineHostname: MachineHostname.posix) == (await host.snapshot()))
        // The tape carries the bytes this test typed as well as the child's output, and the
        // replay above is what proves replay ignores them rather than echoing them back in.
        #expect(snapshot.events.contains { writtenBytes($0) != nil })
        #expect(snapshot.events[..<resizeIndex].contains {
            if case .feed = $0.event { true } else { false }
        })
        #expect(snapshot.events[(resizeIndex + 1)...].contains {
            if case .feed = $0.event { true } else { false }
        })
        #expect(zip(snapshot.events, snapshot.events.dropFirst()).allSatisfy {
            $0.elapsedNanoseconds <= $1.elapsedNanoseconds
        })
        #expect(fromNow.initial == .init(columns: 96, rows: 28, pinned: false))
        #expect(fromNow.cursor.nextSequence == snapshot.events.last.map { $0.sequence + 1 })
        #expect(liveSuffix.events.isEmpty)
    }

    @Test("accepted input is recorded as transmitted, under the origin it was submitted with", .timeLimit(.minutes(1)))
    func acceptedInputCarriesItsSubmissionOrigin() async throws {
        // Intent: every byte the child accepted appears in the tape in transmission order,
        //   and each event reports the time its bytes originated as well as the time they
        //   crossed -- including for the bytes a backpressured write deferred to a later turn.
        // Why it exists: PO2. An owner that sampled its own clock at the write would report
        //   an origin equal to the transfer time and hide exactly the delay worth seeing.
        // Scenario: a megabyte is submitted well after its originating event occurred, to a
        //   child that drains it over many owner turns.
        let host = try makeHost()
        await host.start(makeLaunchInput(command: drainingCommand))
        #expect(await host.waitForOutput(containing: drainingMarker))

        let submission = host.fencedFlightRecordingOriginFromNow().cursor
        let origin = DispatchTime.now().uptimeNanoseconds
        let stallNanoseconds: UInt64 = 50_000_000
        try await Task.sleep(for: .nanoseconds(stallNanoseconds))
        let payload = (0..<(1024 * 1024)).map { UInt8($0 % 251) }
        host.send(payload, origin: origin)
        #expect(await host.drainedPendingInputByteCount() == 0)

        let events = host.fencedFlightRecording(from: submission)
            .events
            .filter { writtenBytes($0) != nil }
        expectBytes(events.compactMap(writtenBytes).flatMap { $0 }, equal: payload, "transmitted bytes")
        #expect(events.count > 1)
        #expect(Set(events.map(\.originElapsedNanoseconds)).count == 1)
        #expect(events.allSatisfy { event in
            guard let originElapsed = event.originElapsedNanoseconds else { return false }
            return event.elapsedNanoseconds - originElapsed >= stallNanoseconds
        })

        await host.close()
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

        let output = String(decoding: host.outputBytes(), as: UTF8.self)
        let ownedPIDs = try [
            taggedInt("__LEADER__", in: output),
            taggedInt("__FOREGROUND__", in: output),
            taggedInt("__BACKGROUND__", in: output),
            taggedInt("__STOPPED__", in: output),
            taggedInt("__RESISTANT__", in: output),
        ]
        let siblingPID = try taggedInt(
            "__PID__",
            in: String(decoding: sibling.outputBytes(), as: UTF8.self)
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
        let warmup = try makeHost()
        await warmup.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        await warmup.close()
        let warmupSnapshot = await warmup.resourceSnapshot()
        #expect(warmupSnapshot.isReleased)
        #expect(warmupSnapshot.census.forcedQuiescenceCount == 0)
        let descriptorsBefore = try openFileDescriptorCount()

        for iteration in 0..<16 {
            weak var releasedHost: TerminalPTYHost?
            do {
                let host = try makeHost()
                releasedHost = host
                await host.start(makeLaunchInput(
                    command: "exec \(try probeExecutable()) hold \"$0\""
                ))
                if iteration.isMultiple(of: 2) {
                    await host.close()
                } else {
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            host.resize(unpinned(columns: 81 + iteration, rows: 25))
                        }
                        group.addTask { await host.close() }
                    }
                }
                let snapshot = await host.resourceSnapshot()
                #expect(snapshot.isReleased)
                #expect(snapshot.census.forcedQuiescenceCount == 0)
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
        let spawner = ControlledTerminalPTYSpawner(holdLaunchReport: true)
        let host = try makeHost(spawner: spawner)
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(spawner.waitForLaunchReport(within: .seconds(20)))
        defer { spawner.releaseLaunchReport() }

        let clock = ContinuousClock()
        let start = clock.now
        let recorder = ExitCompletionRecorder(expecting: 1)
        host.requestShutdown { recorder.signal() }
        spawner.releaseLaunchReport()
        #expect(recorder.waitForAll(within: .seconds(20)))
        let elapsed = start.duration(to: clock.now)

        let snapshot = await host.resourceSnapshot()
        #expect(elapsed < .seconds(1))
        #expect(snapshot.isReleased)
        #expect(snapshot.census.forcedQuiescenceCount == 0)

        let leader = try #require(spawner.launchedLeader)
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
        let stalled = try makeHost()
        let chatty = try makeHost()
        let ordinary = try makeHost()
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
                in: String(decoding: host.outputBytes(), as: UTF8.self)
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
            #expect(snapshot.census.forcedQuiescenceCount == 0)
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
        let output = String(decoding: host.outputBytes(), as: UTF8.self)
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
        #expect(snapshot.census.forcedQuiescenceCount == 1)
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
        let lifecycle = ControlledTerminalPTYResourceLifecycle()
        let host = try makeHost(resourceLifecycle: lifecycle)
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let pid = try taggedInt(
            "__PID__",
            in: String(decoding: host.outputBytes(), as: UTF8.self)
        )
        let cancellationReached = ExitCompletionRecorder(expecting: 1)
        lifecycle.holdSourceCancellationAcknowledgements {
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

        lifecycle.releaseSourceCancellationAcknowledgements()
        #expect(completion.waitForAll(within: .seconds(20)))
        #expect(await waitForProcessExit(pid))
        #expect((await host.resourceSnapshot()).isReleased)
    }

    @Test("forced cleanup starts only after descriptor cancellation joins", .timeLimit(.minutes(1)))
    func forcedShutdownWaitsForDescriptorJoin() async throws {
        // Intent: the forced path leaves the child and master owned until the
        //   descriptor-source barrier opens, then completes the whole cleanup.
        // Why it exists: starting forced reap from closeMaster() itself can block
        //   before cancellation callbacks run or restart the superseded ladder.
        // Scenario: application exit forces a live pane while its source
        //   cancellation acknowledgements are deterministically paused.
        let lifecycle = ControlledTerminalPTYResourceLifecycle()
        let host = try makeHost(
            applicationExitBound: .seconds(30),
            resourceLifecycle: lifecycle
        )
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let pid = try taggedInt(
            "__PID__",
            in: String(decoding: host.outputBytes(), as: UTF8.self)
        )
        let cancellationReached = ExitCompletionRecorder(expecting: 1)
        lifecycle.holdSourceCancellationAcknowledgements {
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

        lifecycle.releaseSourceCancellationAcknowledgements()
        #expect(completion.waitForAll(within: .seconds(20)))
        #expect(await waitForProcessExit(pid))
        let finished = await host.resourceSnapshot()
        #expect(finished.census.forcedQuiescenceCount == 1)
        #expect(finished.isReleased)
    }

    @Test("forced cleanup does not resume a result-bearing reducer", .timeLimit(.minutes(1)))
    func forcedCleanupSupersedesResultBearingReducer() async throws {
        // Intent: forced cleanup consumes the pending close without reporting the
        //   parked child result or restarting the normal teardown ladder.
        // Why it exists: a close-completion event emitted after forced cleanup
        //   would revive the reducer that the host bypassed and publish stale state.
        // Scenario: a child exits with status 7 while the descriptor join is held;
        //   the host forces cleanup before that join is released.
        let lifecycle = ControlledTerminalPTYResourceLifecycle()
        let cancellationReached = ExitCompletionRecorder(expecting: 1)
        lifecycle.holdSourceCancellationAcknowledgements {
            cancellationReached.signal()
        }
        let host = try makeHost(
            applicationExitBound: .seconds(30),
            resourceLifecycle: lifecycle
        )
        let completion = ExitCompletionRecorder(expecting: 1)
        host.whenQuiescent { completion.signal() }

        await host.start(makeLaunchInput(command: "printf '__READY__'; exit 7"))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        #expect(cancellationReached.waitForAll(within: .seconds(20)))
        #expect(await host.result() == nil)

        await host.forceExitBoundForTesting()
        lifecycle.releaseSourceCancellationAcknowledgements()
        #expect(completion.waitForAll(within: .seconds(20)))

        let finished = await host.resourceSnapshot()
        #expect(await host.result() == nil)
        #expect(finished.census.forcedQuiescenceCount == 1)
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
        let lifecycle = ControlledTerminalPTYResourceLifecycle()
        let host = try makeHost(resourceLifecycle: lifecycle)
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) stalled \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        host.send([UInt8](repeating: 65, count: 4 * 1024 * 1024))
        let beforeShutdown = await host.resourceSnapshot()
        #expect(beforeShutdown.pendingInputByteCount > 0)
        #expect(beforeShutdown.descriptorSourceCount == 2)

        let cancellationReached = ExitCompletionRecorder(expecting: 1)
        lifecycle.holdSourceCancellationAcknowledgements {
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

        lifecycle.releaseSourceCancellationAcknowledgements()
        #expect(completion.waitForAll(within: .seconds(20)))
        #expect((await host.resourceSnapshot()).isReleased)
    }

    @Test("teardown releases a host whose canonical input hold is armed", .timeLimit(.minutes(1)))
    func teardownReleasesArmedCanonicalInputHold() async throws {
        // Intent: a line the child's canonical queue cannot accept, still waiting on its
        //   retry timer, does not stop either teardown path from reaching quiescence, and
        //   its submission is answered rather than dropped.
        // Why it exists: the canonical retry timer is retained like every other source, so
        //   a teardown path that does not cancel it waits on a release that never comes.
        //   No other canonical-input test asserts release.
        // Scenario: a pane holds an oversized line when the user quits -- once where the
        //   ladder converges, and once where the host's bound forces quiescence.
        for forcesBound in [false, true] {
            // The 30 second canonical wait is meant NOT to expire: the retry source has to
            // still be armed when teardown starts.
            let lifecycle = ControlledTerminalPTYResourceLifecycle()
            let host = try makeHost(
                applicationExitBound: .seconds(30),
                canonicalInputWait: .seconds(30),
                resourceLifecycle: lifecycle
            )
            await host.start(makeLaunchInput(
                command: "exec \(try probeExecutable()) canonical-hold \"$0\""
            ))
            #expect(await host.waitForOutput(containing: Array("__CANONICAL_READY__".utf8)))
            let held = InputCompletionRecorder(expecting: 1)
            host.send([UInt8](repeating: 0x61, count: CanonicalInputDeliveryGate.capacity)) {
                held.signal($0)
            }
            #expect(await waitForSnapshot(of: host) { $0.pendingInputByteCount > 0 })

            // Holding the acknowledgements stops the ordinary ladder short, so the forced
            // path is what resolves the host rather than a race between the two.
            let cancellationReached = ExitCompletionRecorder(expecting: 1)
            if forcesBound {
                lifecycle.holdSourceCancellationAcknowledgements {
                    cancellationReached.signal()
                }
            }
            let completion = ExitCompletionRecorder(expecting: 1)
            host.requestShutdown { completion.signal() }
            if forcesBound {
                #expect(cancellationReached.waitForAll(within: .seconds(20)))
                await host.forceExitBoundForTesting()
                lifecycle.releaseSourceCancellationAcknowledgements()
            }

            #expect(completion.waitForAll(within: .seconds(20)))
            #expect(held.waitForAll(within: .seconds(20)))
            #expect(held.results == [.rejected(.processEnded)])
            let finished = await host.resourceSnapshot()
            #expect(finished.census.forcedQuiescenceCount == (forcesBound ? 1 : 0))
            #expect(finished.isReleased)
        }
    }

    @Test("teardown releases a host whose lifecycle polls are armed", .timeLimit(.minutes(1)))
    func teardownReleasesArmedLifecyclePolls() async throws {
        // Intent: a running child-exit poll, alongside the session poll the ladder itself
        //   arms, does not stop either teardown path from reaching quiescence.
        // Why it exists: both are retained sources, and neither is armed in the common
        //   case, so a teardown path could drop one without any existing test noticing.
        // Scenario: a child's exit arrives before its wait status is readable, so the host
        //   is polling for it when the pane closes -- once where the ladder converges, and
        //   once where the child never becomes waitable and the bound forces quiescence.
        for forcesBound in [false, true] {
            // Int.max keeps the child unwaitable for the whole run, so the forced path is
            // the only way that host can resolve.
            let probe = TransientChildExitProbe(
                notYetWaitableCount: forcesBound ? Int.max : 20
            )
            let lifecycle = ControlledTerminalPTYResourceLifecycle()
            let host = try makeHost(
                applicationExitBound: .seconds(30),
                childExitProbe: probe,
                resourceLifecycle: lifecycle
            )
            await host.start(makeLaunchInput(command: "\(printMarker("READY")); exit 3"))
            #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
            // Two reports: the first arms the poll, the second can only come from the poll.
            #expect(await pollUntil(
                { probe.notYetWaitableReportCount >= 2 },
                within: .seconds(20)
            ))

            // Holding the acknowledgements stops the ordinary ladder short, so the forced
            // path is what resolves the host rather than a race between the two.
            let cancellationReached = ExitCompletionRecorder(expecting: 1)
            if forcesBound {
                lifecycle.holdSourceCancellationAcknowledgements {
                    cancellationReached.signal()
                }
            }
            let completion = ExitCompletionRecorder(expecting: 1)
            host.requestShutdown { completion.signal() }
            if forcesBound {
                #expect(cancellationReached.waitForAll(within: .seconds(20)))
                await host.forceExitBoundForTesting()
                lifecycle.releaseSourceCancellationAcknowledgements()
            }

            #expect(completion.waitForAll(within: .seconds(20)))
            let finished = await host.resourceSnapshot()
            #expect(finished.census.forcedQuiescenceCount == (forcesBound ? 1 : 0))
            #expect(finished.isReleased)
        }
    }

    @Test("a re-armed grace timer keeps driving teardown while its predecessor releases", .timeLimit(.minutes(1)))
    func reArmedGraceSourceKeepsDrivingTeardown() async throws {
        // Intent: every stage of the ladder re-arms the grace timer while the timer it
        //   replaced is still waiting to be released, and the ladder still escalates to
        //   kill and reaches quiescence on its own, without the host's bound.
        // Why it exists: the host's typed handle to a source and the registry of sources
        //   libdispatch has not released yet are different facts. Treating a release as
        //   the moment to drop the handle would let a predecessor clear the handle its
        //   successor now occupies.
        // Scenario: a pane holding a signal-resistant job tree closes while every
        //   cancellation acknowledgement lands one owner turn later than its cancel.
        let lifecycle = ControlledTerminalPTYResourceLifecycle()
        lifecycle.delaySourceCancellationAcknowledgements()
        let host = try makeHost(
            applicationExitBound: .seconds(30),
            resourceLifecycle: lifecycle
        )
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) teardown \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        let output = String(decoding: host.outputBytes(), as: UTF8.self)
        let ownedPIDs = try [
            taggedInt("__LEADER__", in: output),
            taggedInt("__FOREGROUND__", in: output),
            taggedInt("__BACKGROUND__", in: output),
            taggedInt("__STOPPED__", in: output),
            taggedInt("__RESISTANT__", in: output),
        ]

        await host.close()

        // The resistant job only dies to SIGKILL, so its exit is the ladder's last stage.
        for pid in ownedPIDs {
            #expect(await waitForProcessExit(pid), "owned process \(pid) survived teardown")
        }
        let finished = await host.resourceSnapshot()
        #expect(finished.census.forcedQuiescenceCount == 0)
        #expect(finished.isReleased)
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

        let lifecycle = ControlledTerminalPTYResourceLifecycle()
        lifecycle.installDescriptorReuseProbe(replacementFD: pipeFDs[0])
        let host = try makeHost(
            resourceLifecycle: lifecycle
        )
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        await host.close()

        let reusedFD = try #require(lifecycle.reusedDescriptor)
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
        let host = try makeHost(applicationExitBound: .seconds(30))
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
        #expect((await host.resourceSnapshot()).census.forcedQuiescenceCount == 0)
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
            in: String(decoding: host.outputBytes(), as: UTF8.self)
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
        let host = try makeHost()
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
        let spawner = ControlledTerminalPTYSpawner(holdLaunchReport: true)
        let host = try makeHost(
            applicationExitBound: .milliseconds(50),
            spawner: spawner
        )
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(spawner.waitForLaunchReport(within: .seconds(20)))
        defer { spawner.releaseLaunchReport() }

        let liveAtCompletion = LockedBox<[pid_t]>([])
        let recorder = ExitCompletionRecorder(expecting: 1)
        host.requestShutdown {
            liveAtCompletion.set(directChildProcessIDs())
            recorder.signal()
        }
        // The launch-report gate makes the front half deterministic: a child
        // exists and the host cannot see it. The short margin remains because
        // the abandonment flip is on the owner queue immediately before its
        // blocking join, and fencing that point would add a hook to InFlightLaunch.
        try await Task.sleep(for: .milliseconds(100))
        spawner.releaseLaunchReport()
        #expect(recorder.waitForAll(within: .seconds(20)))

        let launched = try #require(spawner.launchedLeader)
        // Named rather than counted: sibling suites launch their own children, so a
        // process-wide census cannot tell this pane's child from a neighbor's.
        #expect(
            liveAtCompletion.value.contains(launched) == false,
            "child \(launched) was still alive when the host reported quiescence"
        )
        let atCompletion = await host.resourceSnapshot()
        #expect(atCompletion.isReleased)
        #expect(atCompletion.census.forcedQuiescenceCount == 1)

        // Nothing arrives afterward either: the completed launch was abandoned
        // before its report gate opened, so no late delivery remains possible.
        let snapshot = await host.resourceSnapshot()
        #expect(snapshot.isReleased, "the abandoned launch was adopted after teardown")
        #expect(snapshot.census.callbacksAfterTeardown == 0)
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
        let spawner = ControlledTerminalPTYSpawner(holdDelivery: true)
        let host = try makeHost(
            applicationExitBound: .milliseconds(50),
            spawner: spawner
        )
        await host.start(makeLaunchInput(
            command: "exec \(try probeExecutable()) hold \"$0\""
        ))
        #expect(spawner.waitForDelivery(within: .seconds(20)))
        defer { spawner.releaseDelivery() }

        let liveAtCompletion = LockedBox<[pid_t]>([])
        let recorder = ExitCompletionRecorder(expecting: 1)
        host.requestShutdown {
            liveAtCompletion.set(directChildProcessIDs())
            recorder.signal()
        }
        #expect(recorder.waitForAll(within: .seconds(20)))

        let launched = try #require(spawner.launchedLeader)
        #expect(
            liveAtCompletion.value.contains(launched) == false,
            "resolved child \(launched) was still alive when the host reported quiescence"
        )
        #expect((await host.resourceSnapshot()).isReleased)

        // Let the worker submit its token-gated callback so the test also proves
        // a released delivery cannot revive the child claimed by application exit.
        spawner.releaseDelivery()
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
            #expect(host.inputWrites() == [Array(testCase.expectedWrite.utf8)])

            let output = String(decoding: host.outputBytes(), as: UTF8.self)
            #expect(output.components(separatedBy: "__INITIAL_EXECUTED__=").count - 1 == 1)
            #expect(output.contains("__INITIAL_EXECUTED__=\(testCase.name)"))

            // The census claims teardown returned, so it needs the fact that says so.
            // A reported result is not that fact: the host publishes the result in the
            // same queue turn that cancels its remaining sources, and each source is
            // only released when its cancel handler runs in a later turn. Censusing
            // straight off the result reads one to two sources still retained a few
            // milliseconds after a busy child exits.
            await host.close()
            #expect((await host.resourceSnapshot()).isReleased)
        }
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
        let host = try makeHost(
            childExitProbe: TransientChildExitProbe(notYetWaitableCount: 3)
        )
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

/// Holds the owner queue inside a wheel-completion callback so everything submitted after
/// `hold(_:)` returns provably queues behind one job.
///
/// Coalescing is only a deterministic verdict when the test controls *when the owner is
/// free*; measuring how much a burst collapses while the queue drains at its own pace
/// would assert the machine's speed instead. A zero-row standalone wheel sample carries the
/// hold because its completion runs caller code on the owner queue while changing nothing a
/// surrounding test observes: it records no applied transition, writes no bytes to the child,
/// and moves no viewport.
private struct OwnerHold {
    private let reached = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    /// Returns once the owner queue is blocked, so the caller's next submission waits.
    ///
    /// The guard names this waiter when the chosen entry point stops running caller code on
    /// the owner queue. Without it such a change reads as a whole wedged suite rather than
    /// one failed hold, because a blocking semaphore wait is what no `.timeLimit` can unwind.
    func hold(_ host: TerminalPTYHost) throws {
        let reached = reached
        let released = released
        host.sendWheel(.init(rowDelta: 0, column: 0, row: 0)) { _ in
            reached.signal()
            released.wait()
        }
        guard reached.wait(timeout: .now() + 30) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
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

/// Compares two byte payloads and reports a mismatch without diffing them.
///
/// `#expect(a == b)` renders a failed comparison by calling
/// `BidirectionalCollection.difference(from:)`, whose cost grows about
/// quadratically: 32 KiB against 16 KiB takes four seconds, and the megabyte
/// payloads these tests submit never finish at all. That is not a slow test but
/// a wedged one -- the diff is synchronous, so no `.timeLimit` can unwind it,
/// and one such process was found still holding a core 44 minutes later. This
/// reports the same mismatch in a single pass, naming the first byte that
/// differs, which is more useful than an edit script over a megabyte anyway.
private func expectBytes(
    _ actual: [UInt8],
    equal expected: [UInt8],
    _ label: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard actual != expected else { return }
    let shared = min(actual.count, expected.count)
    var index = 0
    while index < shared, actual[index] == expected[index] { index += 1 }

    let detail: String
    if index < shared {
        let window = max(0, index - 4)
        detail = "first differs at byte \(index): "
            + "\(hexBytes(actual[window...].prefix(9))) != \(hexBytes(expected[window...].prefix(9)))"
    } else {
        detail = "the first \(shared) bytes match, so one payload is a prefix of the other"
    }
    Issue.record(
        "\(label): \(actual.count) bytes != \(expected.count) bytes; \(detail)",
        sourceLocation: sourceLocation)
}

private func hexBytes(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

/// A child that prints one marker line and then drains everything sent to it,
/// for the flight-recording tests: they need a child that writes nothing of its
/// own once they start measuring.
///
/// `printf` assembles the marker from a format and an argument rather than
/// carrying it whole, so the marker cannot appear in the command line. The line
/// discipline echoes that command line before `stty -echo` takes effect, and a
/// marker spelled out there would be matched in the echo -- so the wait would
/// return before the child had printed anything, leaving every later step to
/// race the rest of its startup output.
private let drainingCommand =
    "stty raw -echo; printf '__DRAI%s__\\n' NING; exec cat > /dev/null"

/// The line `drainingCommand` prints once its startup output is complete.
private let drainingMarker = Array("__DRAINING__".utf8)

/// The screen with its blank padding removed, for a failure message that has to
/// stay readable. A raw `screenText` is 24 rows of 80 columns, which buries the
/// one or two lines a child actually printed.
private func occupiedScreenText(_ host: TerminalPTYHost) -> String {
    let rows = host.fencedSnapshot().screenText
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.reversed().drop { $0 == " " }.reversed() }
        .map(String.init)
    guard let last = rows.lastIndex(where: { !$0.isEmpty }) else { return "(blank screen)" }
    return rows[...last]
        .enumerated()
        .map { "  row \($0.offset + 1): \($0.element)" }
        .joined(separator: "\n")
}

/// The transmitted payload of one recorded input-direction transfer; nil for every other event.
private func writtenBytes(_ recorded: TerminalFlightRecordingEvent) -> [UInt8]? {
    guard case .write(let bytes) = recorded.event else { return nil }
    return bytes
}

/// The applied payload of one recorded read turn; nil for every other event.
private func fedBytes(_ recorded: TerminalFlightRecordingEvent) -> [UInt8]? {
    guard case .feed(let bytes) = recorded.event else { return nil }
    return bytes
}

/// The host's own read-turn cap, restated here because it bounds a recorded feed event and
/// the host does not publish the constant.
private let readTurnLimit = 16 * 1024

private let straddleCompletionMarker = Array("__STRADDLE_DONE__".utf8)

/// Output several kernel buffers long whose escape sequences land at every offset relative
/// to the 1024-byte pty read boundary, so some copy of each one is certainly cut in two.
///
/// The padding length steps by a value coprime with 1024, which is what sweeps the offsets;
/// an SGR run and an OSC 8 hyperlink are the two sequence shapes whose state a lost or
/// duplicated fragment would visibly corrupt on the screen.
private func boundaryStraddlingPayload() -> [UInt8] {
    var text = ""
    for index in 0..<400 {
        text += "\u{1B}[1;38;2;\(index % 256);\(index % 251);\(index % 241)m"
        text += "\u{1B}]8;;https://example.test/\(index)\u{7}link\u{1B}]8;;\u{7}"
        text += String(repeating: "x", count: index % 97)
        text += "\u{1B}[0m row \(index)\r\n"
    }
    return Array(text.utf8) + straddleCompletionMarker
}

private extension TerminalPTYHost {
    /// Polls until the pending-input buffer stops changing, so a later tape read describes the
    /// same settled state. Sampling the two independently would race a write still in progress.
    func settledPendingInputByteCount(within limit: Duration = .seconds(10)) async -> Int {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        var previous = -1
        while clock.now < deadline {
            let sample = resourceSnapshot().pendingInputByteCount
            if sample == previous { return sample }
            previous = sample
            // Stops on a cancelled sleep rather than sampling on with nothing left
            // to pace the loop. See `pollUntil`, which this cannot use: it reports
            // a count, and the count is what the caller asserts on.
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        return resourceSnapshot().pendingInputByteCount
    }

    /// Polls until the host holds no descriptor-backed source, and returns what is
    /// left if the bound elapses first.
    ///
    /// This is how end of output becomes observable: the host cancels its read source
    /// when the descriptor reports EOF, and cancellation is acknowledged on the host
    /// queue rather than at the call that closed the other end.
    func drainedDescriptorSourceCount(within limit: Duration = .seconds(20)) async -> Int {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            let sample = resourceSnapshot().descriptorSourceCount
            if sample == 0 { return 0 }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        return resourceSnapshot().descriptorSourceCount
    }

    /// Polls until the pending-input buffer is empty, and returns what is left if
    /// the bound elapses first.
    ///
    /// Deliberately not `settledPendingInputByteCount`: a buffer that reads the
    /// same twice has stopped changing, which is not the same as drained. On a
    /// loaded machine the child can be descheduled for longer than one sampling
    /// interval mid-drain, and the settled reading then reports bytes that were
    /// still in flight -- an intermittent failure that says nothing about the
    /// behavior under test.
    func drainedPendingInputByteCount(within limit: Duration = .seconds(30)) async -> Int {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            let sample = resourceSnapshot().pendingInputByteCount
            if sample == 0 { return 0 }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        return resourceSnapshot().pendingInputByteCount
    }
}

/// The launch command a childless host is started with.
///
/// No process ever runs it, because the channel launches nothing. The host still writes the
/// line to the PTY exactly as it would to a shell, so a test that reads back transmitted
/// bytes -- or counts input writes -- accounts for it first.
private let childlessLaunchCommand = "no command runs on a childless channel"

/// Forty numbered lines, the history the scroll, wheel, and viewport tests browse through.
///
/// Carriage returns are explicit: the child end is raw, so nothing turns a newline into a
/// carriage return and line feed on its way to the terminal.
private let scrollbackLines = (0..<40).map { "line-\($0)\r\n" }.joined()

/// A host driven across a real PTY master with nothing at the other end but the test.
///
/// The host's read, write, and ioctl calls are the production ones; only the child process
/// is missing, and the test plays it. Tests whose subject is a real process -- launch
/// ownership, the teardown ladder, exit status, the descriptor census -- launch `PTYProbe`
/// instead and are not built from here.
private struct ChildlessHost {
    let host: TerminalPTYHost
    let channel: ChildlessPTYChannel

    /// Writes bytes as a child would print them, returning once the host has applied them.
    ///
    /// The match is armed before the write, so no output that follows can bury the answer,
    /// and the host records output for tests only after feeding it to the terminal -- so a
    /// fenced read taken after this call sees these bytes.
    ///
    /// It carries `expectOutput`'s discard rule with it: a host that has already dropped
    /// output past its bounded window cannot answer, so a test that floods this pane must
    /// arm its own expectation before the flood and write through `channel` after it.
    @discardableResult
    func writeFromChild(_ bytes: [UInt8]) async -> Bool {
        let applied = host.expectOutput(containing: bytes)
        guard channel.writeFromChild(bytes) else { return false }
        return await applied.satisfied()
    }

    @discardableResult
    func writeFromChild(_ text: String) async -> Bool {
        await writeFromChild(Array(text.utf8))
    }
}

private extension TerminalPTYHost {
    /// The delivered-input occurrences the owner has queued, taken through the same drain
    /// a pane consumer uses, with the terminal's own semantics left out.
    nonisolated func drainedUserInputEvents() -> [PaneSemanticEvent] {
        fencedFrameState().semanticEvents.filter {
            if case .userInputDelivered = $0 { return true }
            return false
        }
    }

    /// Whether the pane's recorder still holds this wait's append notice, which is the host's
    /// only reference to the wait and to everything the wait captured. A nil follow snapshot is
    /// the recorder saying the subscription is not registered.
    nonisolated func holdsOutputWaitSubscription(
        _ expectation: TerminalPTYOutputExpectation
    ) -> Bool {
        fencedFlightRecordingFollowSnapshot(
            subscriptionId: expectation.subscriptionId,
            from: .beginning
        ) != nil
    }
}

private extension TerminalFlightRecorderConfiguration {
    /// Evicts every event as soon as it is recorded, so output loss is a property of the host
    /// under test instead of a race between a flood and the machine the suite runs on.
    static let retainingNothing = Self(budgetBytes: 0, eventLimit: 0, eventOverheadBytes: 0)

    /// Retains exactly the newest event, so the next applied chunk is what evicts the last one.
    static let retainingOneEvent = Self(
        budgetBytes: .max,
        eventLimit: 1,
        eventOverheadBytes: 0
    )
}

/// Starts a host on a PTY with no child and returns once its launch line has crossed.
///
/// That transmission is this fixture's readiness edge. A child's `__READY__` proved the same
/// thing indirectly -- a shell can only print it after reading the line -- and a test that
/// counts input writes needs the same anchor before it takes a baseline.
private func startChildlessHost(
    flightTapeConfiguration: TerminalFlightRecorderConfiguration = .production,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> ChildlessHost {
    let channel = try ChildlessPTYChannel()
    let host = try makeHost(
        flightTapeConfiguration: flightTapeConfiguration,
        spawner: channel
    )
    await host.start(makeLaunchInput(command: childlessLaunchCommand))
    let launchLine = Array("\(childlessLaunchCommand)\n".utf8)
    let transmitted = await pollUntil(
        { channel.bytesReceivedFromHost().starts(with: launchLine) },
        within: .seconds(20)
    )
    if transmitted == false {
        Issue.record(
            "the host never transmitted its launch command line",
            sourceLocation: sourceLocation
        )
    }
    return ChildlessHost(host: host, channel: channel)
}

private func makeHost(
    flightTapeConfiguration: TerminalFlightRecorderConfiguration = .production,
    applicationExitBound: DispatchTimeInterval = TerminalPTYHost.defaultApplicationExitBound,
    canonicalInputWait: DispatchTimeInterval = TerminalPTYHost.defaultCanonicalInputWait,
    childExitProbe: any TerminalPTYChildExitProbing = SystemTerminalPTYChildExitProbe(),
    resourceLifecycle: any TerminalPTYResourceLifecycling = SystemTerminalPTYResourceLifecycle(),
    spawner: any TerminalPTYSpawning = SystemTerminalPTYSpawner()
) throws -> TerminalPTYHost {
    try TerminalPTYHost(
        initialDimensions: .init(columns: 80, rows: 24),
        bootstrapExecutable: bootstrapExecutable(),
        flightTapeConfiguration: flightTapeConfiguration,
        applicationExitBound: applicationExitBound,
        canonicalInputWait: canonicalInputWait,
        childExitProbe: childExitProbe,
        resourceLifecycle: resourceLifecycle,
        spawner: spawner
    )
}

private final class ControlledTerminalPTYSpawner: TerminalPTYSpawning {
    private struct State: Sendable {
        var launchedLeader: pid_t?
    }

    private let inner: any TerminalPTYSpawning
    private let state = Mutex(State())
    private let holdLaunchReport: Bool
    private let holdDelivery: Bool
    private let launchReportReached = DispatchSemaphore(value: 0)
    private let launchReportRelease = DispatchSemaphore(value: 0)
    private let deliveryReached = DispatchSemaphore(value: 0)
    private let deliveryRelease = DispatchSemaphore(value: 0)

    /// `wrapping` picks what the held launch actually launches. It defaults to a real
    /// spawn, but a suite that must fork no child passes its own `ChildlessPTYChannel`
    /// and still gets the launch-report hold.
    init(
        wrapping inner: any TerminalPTYSpawning = SystemTerminalPTYSpawner(),
        holdLaunchReport: Bool = false,
        holdDelivery: Bool = false
    ) {
        self.inner = inner
        self.holdLaunchReport = holdLaunchReport
        self.holdDelivery = holdDelivery
    }

    func spawn(
        _ spec: PTYLaunchSpec,
        bootstrapExecutable: String,
        didLaunch: (SpawnedPTY) -> Bool
    ) -> PTYSpawnOutcome {
        inner.spawn(spec, bootstrapExecutable: bootstrapExecutable) { [self] spawned in
            state.withLock { $0.launchedLeader = spawned.leader }
            if holdLaunchReport {
                launchReportReached.signal()
                launchReportRelease.wait()
            }
            return didLaunch(spawned)
        }
    }

    func waitForDeliveryPermission() {
        inner.waitForDeliveryPermission()
        guard holdDelivery else { return }
        deliveryReached.signal()
        deliveryRelease.wait()
    }

    func waitForLaunchReport(within timeout: DispatchTimeInterval) -> Bool {
        launchReportReached.wait(timeout: .now() + timeout) == .success
    }

    func releaseLaunchReport() {
        launchReportRelease.signal()
    }

    func waitForDelivery(within timeout: DispatchTimeInterval) -> Bool {
        deliveryReached.wait(timeout: .now() + timeout) == .success
    }

    func releaseDelivery() {
        deliveryRelease.signal()
    }

    var launchedLeader: pid_t? {
        state.withLock { $0.launchedLeader }
    }
}

/// Replaces only the launched program so a real PTY can exercise a synthetic child's tty mode.
private final class ProgramReplacingTerminalPTYSpawner: TerminalPTYSpawning, @unchecked Sendable {
    let program: String
    let arguments: [String]
    private let production = SystemTerminalPTYSpawner()
    private let leader = Mutex<pid_t?>(nil)

    init(program: String, arguments: [String]) {
        self.program = program
        self.arguments = arguments
    }

    func spawn(
        _ spec: PTYLaunchSpec,
        bootstrapExecutable: String,
        didLaunch: (SpawnedPTY) -> Bool
    ) -> PTYSpawnOutcome {
        production.spawn(
            PTYLaunchSpec(
                program: program,
                arguments: arguments,
                workingDirectory: spec.workingDirectory,
                environment: spec.environment,
                initialDimensions: spec.initialDimensions
            ),
            bootstrapExecutable: bootstrapExecutable,
            didLaunch: { [self] spawned in
                leader.withLock { $0 = spawned.leader }
                return didLaunch(spawned)
            }
        )
    }

    func waitForDeliveryPermission() {}

    func requestRawMode() throws {
        try sendSignal(SIGUSR1)
    }

    func sendSignal(_ signal: Int32) throws {
        guard let pid = leader.withLock({ $0 }) else { throw POSIXError(.ESRCH) }
        guard kill(pid, signal) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

private final class ControlledTerminalPTYResourceLifecycle: TerminalPTYResourceLifecycling {
    private struct GateResult: Sendable {
        let verdict: TerminalPTYLifecycleGateVerdict
        let observer: (@Sendable () -> Void)?
    }

    private struct State: Sendable {
        var holdsSourceCancellationAcknowledgements = false
        var delaysSourceCancellationAcknowledgements = false
        var sourceCancellationObserver: (@Sendable () -> Void)?
        var sourceCancellationResumes: [@Sendable () -> Void] = []
        var descriptorReuseReplacementFD: Int32?
        var reusedDescriptor: Int32?
    }

    private let production = SystemTerminalPTYResourceLifecycle()
    private let state = Mutex(State())

    func gateSourceCancellationAcknowledgement(
        resume: @escaping @Sendable () -> Void
    ) -> TerminalPTYLifecycleGateVerdict {
        let result = state.withLock { state -> GateResult in
            guard state.holdsSourceCancellationAcknowledgements else {
                guard state.delaysSourceCancellationAcknowledgements else {
                    return GateResult(verdict: .proceed, observer: nil)
                }
                // Resumed off the owner's queue, so the acknowledgement re-enters in a
                // later turn than the cancel that produced it -- after a replace-on-arm
                // source has already armed its successor.
                DispatchQueue.global().async { resume() }
                return GateResult(verdict: .deferred, observer: nil)
            }
            state.sourceCancellationResumes.append(resume)
            let observer = state.sourceCancellationObserver
            state.sourceCancellationObserver = nil
            return GateResult(verdict: .deferred, observer: observer)
        }
        result.observer?()
        return result.verdict
    }

    func closeMasterDescriptor(_ descriptor: Int32) {
        let replacementFD = state.withLock { $0.descriptorReuseReplacementFD }
        guard let replacementFD, dup2(replacementFD, descriptor) == descriptor else {
            production.closeMasterDescriptor(descriptor)
            return
        }
        state.withLock { $0.reusedDescriptor = descriptor }
    }

    func holdSourceCancellationAcknowledgements(
        onFirstDeferred: @escaping @Sendable () -> Void
    ) {
        state.withLock { state in
            state.holdsSourceCancellationAcknowledgements = true
            state.sourceCancellationObserver = onFirstDeferred
        }
    }

    /// Makes every source cancellation acknowledgement arrive one owner turn after the
    /// cancel that caused it, instead of inline. Production acknowledges inline, which
    /// always lands before a replacement source is armed, so this is the only way a test
    /// can witness a predecessor releasing while its successor is already driving.
    func delaySourceCancellationAcknowledgements() {
        state.withLock { $0.delaysSourceCancellationAcknowledgements = true }
    }

    func releaseSourceCancellationAcknowledgements() {
        let resumes = state.withLock { state in
            state.holdsSourceCancellationAcknowledgements = false
            let resumes = state.sourceCancellationResumes
            state.sourceCancellationResumes.removeAll()
            return resumes
        }
        for resume in resumes { resume() }
    }

    func installDescriptorReuseProbe(replacementFD: Int32) {
        state.withLock { $0.descriptorReuseReplacementFD = replacementFD }
    }

    var reusedDescriptor: Int32? {
        state.withLock { $0.reusedDescriptor }
    }
}

private final class TransientChildExitProbe: TerminalPTYChildExitProbing {
    private struct State: Sendable {
        var remainingNotYetWaitableCount: Int
        var notYetWaitableReportCount = 0
    }

    private let production = SystemTerminalPTYChildExitProbe()
    private let state: Mutex<State>

    init(notYetWaitableCount: Int) {
        state = Mutex(State(remainingNotYetWaitableCount: notYetWaitableCount))
    }

    /// How many times this probe has said the child is not waitable yet. The host arms
    /// its child-exit poll on the first one, so a second can only come from that poll.
    var notYetWaitableReportCount: Int {
        state.withLock { $0.notYetWaitableReportCount }
    }

    func probe(_ leaderPID: pid_t) -> TerminalPTYChildExitProbeResult {
        let shouldReportNotYetWaitable = state.withLock { state in
            guard state.remainingNotYetWaitableCount > 0 else { return false }
            state.remainingNotYetWaitableCount -= 1
            state.notYetWaitableReportCount += 1
            return true
        }
        guard shouldReportNotYetWaitable == false else { return .notYetWaitable }
        return production.probe(leaderPID)
    }
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

/// Collects whole-submission results without adding a task hop to the host callback edge.
private final class InputCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResults: [PaneInputSubmissionResult] = []
    private let group = DispatchGroup()

    init(expecting count: Int) {
        for _ in 0..<count { group.enter() }
    }

    func signal(_ result: PaneInputSubmissionResult) {
        lock.lock()
        storedResults.append(result)
        lock.unlock()
        group.leave()
    }

    func waitForAll(within timeout: DispatchTimeInterval) -> Bool {
        group.wait(timeout: .now() + timeout) == .success
    }

    var results: [PaneInputSubmissionResult] {
        lock.lock()
        defer { lock.unlock() }
        return storedResults
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

private func findExecutable(named name: String) throws -> String {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    return try #require(path.split(separator: ":").lazy
        .map { URL(fileURLWithPath: String($0)).appending(path: name).path }
        .first(where: FileManager.default.isExecutableFile(atPath:)))
}

private func submitAndAwait(_ bytes: [UInt8], to host: TerminalPTYHost) throws {
    let completion = InputCompletionRecorder(expecting: 1)
    host.send(bytes) { completion.signal($0) }
    guard completion.waitForAll(within: .seconds(30)) else { throw POSIXError(.ETIMEDOUT) }
    #expect(completion.results == [.delivered])
}

/// Polls the host's own resource census until it satisfies the predicate.
///
/// The host's `waitForSnapshot(where:)` cannot answer this one: its predicate is
/// synchronous, and `resourceSnapshot()` is actor-isolated.
private func waitForSnapshot(
    of host: TerminalPTYHost,
    within limit: Duration = .seconds(20),
    where predicate: @Sendable (TerminalPTYResourceSnapshot) -> Bool
) async -> Bool {
    let deadline = ContinuousClock().now + limit
    while ContinuousClock().now < deadline {
        if predicate(await host.resourceSnapshot()) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
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
    await pollUntil({ processExists(processID) == false }, within: limit)
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
    await pollUntil({ directChildProcessIDs().contains(processID) == false }, within: limit)
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
