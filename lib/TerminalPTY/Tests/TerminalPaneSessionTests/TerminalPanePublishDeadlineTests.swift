// Deterministic tests for the consumer-held publish deadline (research 33/D8):
// the controller will not fence again until one display interval after the last
// delivery, arms exactly one one-shot timer only while host work is pending,
// and delivers the urgent classes -- clipboard, semantic events, primary-history
// mutation, child exit -- without waiting on that deadline.
import Foundation
import PaneProcessLifecycle
@testable import TerminalCore
import TerminalRenderPlanning
import Testing
@testable import TerminalPTYHost
import TerminalPTYTestSupport
@testable import TerminalPaneSession

/// One captured one-shot timer request, fired manually by the test.
@MainActor
private final class ManualDeadlineTimer {
    private(set) var scheduled: [(delayNanoseconds: UInt64, fire: @MainActor @Sendable () -> Void)] = []
    private(set) var cancelledCount = 0

    func schedule(
        delayNanoseconds: UInt64,
        fire: @escaping @MainActor @Sendable () -> Void
    ) -> () -> Void {
        scheduled.append((delayNanoseconds, fire))
        return { [weak self] in
            MainActor.assumeIsolated { self?.cancelledCount += 1 }
        }
    }

    func fire(_ index: Int) {
        scheduled[index].fire()
    }
}

/// Exercises the delivery deadline through a real PTY host with an injected
/// clock and timer, so every publish decision in these tests is deterministic.
@MainActor
@Suite(.serialized)
struct TerminalPanePublishDeadlineTests {
    /// The launch command for tests that need a quiescent pane: the marker is
    /// printed after the shell's own echo of the command line, so once it is
    /// observed, every launch byte is already applied on the owner -- and the
    /// `exec sleep 30` that follows emits nothing further, ever.
    static let settledLaunchCommand = "\(printMarker("READY", newline: false)); exec sleep 30"

    /// Drains the launch's own PTY noise so the assertions that follow count
    /// only the test's synthetic feeds. Waiting on the runtime-assembled marker
    /// (not the echo text) is what makes this airtight: a trailing echo chunk
    /// arriving after the checkpoint would defer against the injected clock
    /// and silently swallow the next feed's signal. The caller then moves its
    /// clock past any deadline this settle started.
    private func settleLaunchEcho(
        host: TerminalPTYHost,
        controller: TerminalPaneSessionController
    ) async {
        #expect(await host.waitForOutput(containing: Array("__READY__".utf8)))
        controller.synchronizeState()
        await drainMainQueue()
    }
    @Test("damage inside the interval defers to one one-shot timer, then publishes", .timeLimit(.minutes(1)))
    func damageInsideIntervalDefersToDeadline() async throws {
        // Intent: a publish inside the refresh interval is deferred, exactly one
        //   timer is armed for the remainder, and firing it publishes the newest
        //   frame with the accumulated damage -- never a stale final frame.
        // Why it exists: 33/F12 measured 594 publishes/s against 120 draws/s; the
        //   deadline is what bounds the fence rate to display demand, and a lost
        //   timer would freeze the pane one frame in the past.
        // Scenario: a flood delivers twice within one display interval, then stops.
        var now: UInt64 = 0
        let timer = ManualDeadlineTimer()
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: Self.settledLaunchCommand),
            fenceClock: { now },
            deadlineTimer: { delay, fire in timer.schedule(delayNanoseconds: delay, fire: fire) }
        )
        controller.displayRefreshIntervalNanoseconds = { 1_000 }
        var frames: [TerminalPaneFrame] = []
        controller.onFrame = { frames.append($0) }
        await settleLaunchEcho(host: host, controller: controller)
        frames.removeAll()
        let settleTimers = timer.scheduled.count
        now = 100_000

        host.stageFixtureOutput(Array("first".utf8))
        await drainMainQueue()
        #expect(frames.count == 1)
        #expect(timer.scheduled.count == settleTimers)

        now = 100_400
        host.stageFixtureOutput(Array("second".utf8))
        await drainMainQueue()
        #expect(frames.count == 1)
        #expect(timer.scheduled.count == settleTimers + 1)
        #expect(timer.scheduled.last!.delayNanoseconds <= 1_000)

        now = 101_000
        timer.fire(timer.scheduled.count - 1)
        #expect(frames.count == 2)
        #expect(controller.readViewportText().contains("first"))
        #expect(controller.readViewportText().contains("second"))

        controller.tearDown()
        await host.close()
    }

    @Test("no pending host work arms no timer", .timeLimit(.minutes(1)))
    func noPendingWorkArmsNoTimer() async throws {
        // Intent: once the deferred fence has drained everything, no further
        //   timer is armed until new work is signaled.
        // Why it exists: doc 25's T1 idle shape -- an idle pane must keep its
        //   zero-wakeup steady state, so the timer exists only while work pends.
        // Scenario: a deferred publish completes, then the pane goes idle.
        var now: UInt64 = 0
        let timer = ManualDeadlineTimer()
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: Self.settledLaunchCommand),
            fenceClock: { now },
            deadlineTimer: { delay, fire in timer.schedule(delayNanoseconds: delay, fire: fire) }
        )
        controller.displayRefreshIntervalNanoseconds = { 1_000 }
        var frames: [TerminalPaneFrame] = []
        controller.onFrame = { frames.append($0) }
        await settleLaunchEcho(host: host, controller: controller)
        frames.removeAll()
        let settleTimers = timer.scheduled.count
        now = 100_000

        host.stageFixtureOutput(Array("first".utf8))
        await drainMainQueue()
        now = 100_400
        host.stageFixtureOutput(Array("second".utf8))
        await drainMainQueue()
        #expect(timer.scheduled.count == settleTimers + 1)

        now = 101_000
        timer.fire(timer.scheduled.count - 1)
        #expect(frames.count == 2)

        now = 110_000
        await drainMainQueue()
        #expect(timer.scheduled.count == settleTimers + 1)

        controller.tearDown()
        await host.close()
    }

    @Test("damage after the deadline publishes immediately", .timeLimit(.minutes(1)))
    func damageAfterDeadlinePublishesImmediately() async throws {
        // Intent: a producer slower than the display rate never waits and never
        //   arms a timer -- the event-driven path is byte-for-byte today's.
        // Why it exists: 33/F19's partition -- the paced regime is T9's alone,
        //   and T10 must not tax it. The 30 lines/s gate scenario pins this live;
        //   this is its deterministic counterpart.
        // Scenario: a paced producer delivers one line well after the deadline.
        var now: UInt64 = 0
        let timer = ManualDeadlineTimer()
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: Self.settledLaunchCommand),
            fenceClock: { now },
            deadlineTimer: { delay, fire in timer.schedule(delayNanoseconds: delay, fire: fire) }
        )
        controller.displayRefreshIntervalNanoseconds = { 1_000 }
        var frames: [TerminalPaneFrame] = []
        controller.onFrame = { frames.append($0) }
        await settleLaunchEcho(host: host, controller: controller)
        frames.removeAll()
        let settleTimers = timer.scheduled.count
        now = 100_000

        host.stageFixtureOutput(Array("first".utf8))
        await drainMainQueue()
        #expect(frames.count == 1)

        now = 105_000
        host.stageFixtureOutput(Array("second".utf8))
        await drainMainQueue()
        #expect(frames.count == 2)
        #expect(timer.scheduled.count == settleTimers)

        controller.tearDown()
        await host.close()
    }

    @Test("clipboard, semantics, and history mutation bypass a deferred fence", .timeLimit(.minutes(1)))
    func urgentClassesBypassDeferredFence() async throws {
        // Intent: while frame publishes are deferred, a bell, a completed OSC 52
        //   write, and a primary-history mutation are each delivered without
        //   waiting for the deadline, and no frame rides the bypass.
        // Why it exists: doc 25 rejected an urgent-only occluded tier because
        //   these classes reach the runtime only through delivery; D8 readmits
        //   the deadline only with this bypass intact.
        // Scenario: a flood is mid-interval when the child rings, writes the
        //   clipboard, and appends a history line.
        var now: UInt64 = 0
        let timer = ManualDeadlineTimer()
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: Self.settledLaunchCommand),
            fenceClock: { now },
            deadlineTimer: { delay, fire in timer.schedule(delayNanoseconds: delay, fire: fire) }
        )
        controller.displayRefreshIntervalNanoseconds = { 1_000 }
        var frames: [TerminalPaneFrame] = []
        var clipboardWrites: [String] = []
        var semanticEvents: [TerminalSemanticEvent] = []
        var historyMutations = 0
        controller.onFrame = { frames.append($0) }
        controller.onClipboardWrite = { clipboardWrites.append($0) }
        controller.onSemanticEvents = { semanticEvents.append(contentsOf: $0) }
        controller.onPrimaryHistoryMutation = { historyMutations += 1 }
        await settleLaunchEcho(host: host, controller: controller)
        frames.removeAll()
        let settleTimers = timer.scheduled.count
        now = 100_000

        host.stageFixtureOutput(Array("seed".utf8))
        await drainMainQueue()
        #expect(frames.count == 1)
        let mutationsAfterSeed = historyMutations

        now = 100_100
        host.stageFixtureOutput(
            Array("\u{07}\u{1B}]52;c;aGVsbG8=\u{07}payload line\n".utf8)
        )
        await drainMainQueue()
        #expect(frames.count == 1)
        #expect(clipboardWrites == ["hello"])
        #expect(semanticEvents.contains(.bell))
        #expect(historyMutations > mutationsAfterSeed)
        #expect(timer.scheduled.count == settleTimers + 1)

        now = 101_000
        timer.fire(timer.scheduled.count - 1)
        #expect(frames.count == 2)
        #expect(controller.readViewportText().contains("payload line"))

        controller.tearDown()
        await host.close()
    }

    @Test("a checkpoint fence cannot overtake bypass payloads already in flight", .timeLimit(.minutes(1)))
    func checkpointFenceFlushesPendingUrgentFirst() async throws {
        // Intent: urgent payloads queued for the main hop are delivered before
        //   any synchronous fence's own effects, preserving today's ordering of
        //   semantics before the frame that follows them.
        // Why it exists: the bypass is a second delivery path; a synchronizeState
        //   racing it must not reorder or drop what the signal already drained.
        // Scenario: a bell is signaled, then a checkpoint fence runs before the
        //   main hop delivers.
        let host = try makeHost()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: Self.settledLaunchCommand)
        )
        var order: [String] = []
        controller.onSemanticEvents = { events in
            if events.contains(.bell) { order.append("bell") }
        }
        controller.onFrame = { _ in order.append("frame") }

        host.stageFixtureOutput(Array("ding\u{07}".utf8))
        controller.synchronizeState()
        #expect(order.first == "bell")
        #expect(order.contains("frame"))

        controller.tearDown()
        await host.close()
    }

    @Test("child exit bypasses the deadline and delivers the final frame", .timeLimit(.minutes(1)))
    func childExitBypassesDeadline() async throws {
        // Intent: a child exit is consumed immediately even when the deadline
        //   would otherwise defer the fence, so the exit status and final screen
        //   never wait on a flood's timer.
        // Why it exists: doc 25's rejection turned on exactly this class going
        //   silent; with an injected timer nobody fires, only the bypass can
        //   deliver the result at all.
        // Scenario: the deadline is armed far in the future when the child exits.
        var now: UInt64 = 0
        let timer = ManualDeadlineTimer()
        let host = try makeHost()
        let results = AsyncStream<PaneProcessLifecycleResult>.makeStream()
        var iterator = results.stream.makeAsyncIterator()
        let controller = TerminalPaneSessionController(
            host: host,
            launchInput: makeLaunchInput(command: "printf 'closing'; exit 7"),
            fenceClock: { now },
            deadlineTimer: { delay, fire in timer.schedule(delayNanoseconds: delay, fire: fire) }
        )
        controller.displayRefreshIntervalNanoseconds = { 10_000_000_000 }
        controller.onSessionEnded = { results.continuation.yield($0) }

        #expect(await iterator.next() == .exited(.exited(7)))
        #expect(controller.readViewportText().contains("closing"))

        controller.tearDown()
        await host.close()
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

private func makeHost() throws -> TerminalPTYHost {
    try TerminalPTYHost(
        initialDimensions: .init(columns: 80, rows: 24),
        bootstrapExecutable: bootstrapExecutable(),
        captureTransitions: true
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
