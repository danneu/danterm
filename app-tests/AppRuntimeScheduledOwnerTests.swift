// Proof that one scheduled handle and its census entry cannot come apart.
import Dispatch
import Foundation
import Testing
@testable import DanTerm

/// Stands in for a real scheduled handle so a test can watch the owner retire it.
@MainActor
private final class TestScheduledHandle {
    let id: Int

    init(id: Int) {
        self.id = id
    }
}

/// Records what the owner did, so an escaping callback never has to mutate a local.
@MainActor
private final class ScheduledOwnerRecorder {
    var retired: [Int] = []
    var handled: [Int] = []
}

/// Waits for one fire, and says plainly when the wait expired instead of the timer firing.
private func awaitOneFire(_ fires: AsyncStream<Void>) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await _ in fires { break }
        }
        group.addTask {
            // Hang guard, not a threshold: a passing run fires in milliseconds.
            try await Task.sleep(for: .seconds(30))
            throw POSIXError(.ETIMEDOUT)
        }
        try await group.next()
        group.cancelAll()
    }
}

/// Proves the census-owned scheduled owner keeps its handle and its census entry in step.
@MainActor
struct AppRuntimeScheduledOwnerTests {
    private func makeOwner(
        _ lifecycle: AppRuntimeSchedulingLifecycle,
        _ recorder: ScheduledOwnerRecorder
    ) -> AppRuntimeScheduledOwner<TestScheduledHandle> {
        AppRuntimeScheduledOwner(
            lifecycle: lifecycle,
            category: .timer,
            retire: { recorder.retired.append($0.id) }
        )
    }

    @Test("arming adds one census entry and cancelling retires the handle once")
    func armThenCancel() {
        let lifecycle = AppRuntimeSchedulingLifecycle()
        let recorder = ScheduledOwnerRecorder()
        let owner = makeOwner(lifecycle, recorder)

        owner.arm { _ in TestScheduledHandle(id: 1) }

        #expect(owner.isArmed)
        #expect(lifecycle.captureOwnerCensus()[.timer] == 1)

        owner.cancel()
        owner.cancel()

        #expect(owner.isArmed == false)
        #expect(lifecycle.captureOwnerCensus().isEmpty)
        #expect(recorder.retired == [1])
    }

    @Test("re-arming retires the previous handle and never holds two census entries")
    func rearmRetiresPrevious() {
        let lifecycle = AppRuntimeSchedulingLifecycle()
        let recorder = ScheduledOwnerRecorder()
        let owner = makeOwner(lifecycle, recorder)

        owner.arm { _ in TestScheduledHandle(id: 1) }
        owner.arm { _ in TestScheduledHandle(id: 2) }

        #expect(owner.isArmed)
        #expect(lifecycle.captureOwnerCensus()[.timer] == 1)
        #expect(recorder.retired == [1])
    }

    @Test("arming after shutdown retires the offered handle and arms nothing")
    func armAfterShutdownFailsClosed() {
        let lifecycle = AppRuntimeSchedulingLifecycle()
        let recorder = ScheduledOwnerRecorder()
        let owner = makeOwner(lifecycle, recorder)

        lifecycle.shutdown()
        owner.arm { _ in TestScheduledHandle(id: 7) }

        #expect(owner.isArmed == false)
        #expect(lifecycle.captureOwnerCensus().isEmpty)
        #expect(recorder.retired == [7])
    }

    @Test("lifecycle shutdown empties every armed owner")
    func shutdownEmptiesOwner() {
        let lifecycle = AppRuntimeSchedulingLifecycle()
        let recorder = ScheduledOwnerRecorder()
        let owner = makeOwner(lifecycle, recorder)

        owner.arm { _ in TestScheduledHandle(id: 3) }
        lifecycle.shutdown()

        #expect(owner.isArmed == false)
        #expect(lifecycle.captureOwnerCensus().isEmpty)
        #expect(recorder.retired == [3])
    }

    // Intent: a handler may re-arm the owner it was fired from.
    // Why it exists: the scrollback-checkpoint handler reschedules itself, so the census
    //   entry has to be consumed before the handler runs or the re-arm would be the
    //   second entry for one owner.
    // Scenario: the first arm's handler arms the owner again.
    @Test("a fire consumes the census entry before the handler runs")
    func fireConsumesEntryBeforeHandler() throws {
        let lifecycle = AppRuntimeSchedulingLifecycle()
        let recorder = ScheduledOwnerRecorder()
        let owner = makeOwner(lifecycle, recorder)
        var capturedFire: ((() -> Void) -> Void)?

        owner.arm { fire in
            capturedFire = fire
            return TestScheduledHandle(id: 1)
        }
        let fire = try #require(capturedFire)
        fire {
            recorder.handled.append(1)
            #expect(owner.isArmed == false)
            #expect(lifecycle.captureOwnerCensus().isEmpty)
            owner.arm { _ in TestScheduledHandle(id: 2) }
        }

        #expect(recorder.handled == [1])
        #expect(owner.isArmed)
        #expect(lifecycle.captureOwnerCensus()[.timer] == 1)
        // A fire is not a retirement: only the re-arm retired anything.
        #expect(recorder.retired.isEmpty)
    }

    // Intent: the census owns an armed owner outright.
    // Why it exists: the pairing this type replaces let an external field hold the
    //   handle while the census held only a token, so releasing the field stranded a
    //   census entry whose handle was gone.
    // Scenario: arm an owner, drop the only external reference to it, then shut down.
    @Test("an armed owner survives losing every external reference")
    func censusOwnsArmedOwner() {
        let lifecycle = AppRuntimeSchedulingLifecycle()
        let recorder = ScheduledOwnerRecorder()

        do {
            let owner = makeOwner(lifecycle, recorder)
            owner.arm { _ in TestScheduledHandle(id: 9) }
        }

        #expect(lifecycle.captureOwnerCensus()[.timer] == 1)
        #expect(recorder.retired.isEmpty)

        lifecycle.shutdown()

        #expect(lifecycle.captureOwnerCensus().isEmpty)
        #expect(recorder.retired == [9])
    }

    @Test("a fire callback from a superseded arm does nothing")
    func supersededFireIsInert() throws {
        let lifecycle = AppRuntimeSchedulingLifecycle()
        let recorder = ScheduledOwnerRecorder()
        let owner = makeOwner(lifecycle, recorder)
        var capturedFire: ((() -> Void) -> Void)?

        owner.arm { fire in
            capturedFire = fire
            return TestScheduledHandle(id: 1)
        }
        owner.arm { _ in TestScheduledHandle(id: 2) }
        let staleFire = try #require(capturedFire)
        staleFire { recorder.handled.append(1) }

        #expect(recorder.handled.isEmpty)
        #expect(owner.isArmed)
        #expect(lifecycle.captureOwnerCensus()[.timer] == 1)
    }

    @Test("a fire callback from a cancelled arm does nothing")
    func cancelledFireIsInert() throws {
        let lifecycle = AppRuntimeSchedulingLifecycle()
        let recorder = ScheduledOwnerRecorder()
        let owner = makeOwner(lifecycle, recorder)
        var capturedFire: ((() -> Void) -> Void)?

        owner.arm { fire in
            capturedFire = fire
            return TestScheduledHandle(id: 1)
        }
        owner.cancel()
        let staleFire = try #require(capturedFire)
        staleFire { recorder.handled.append(1) }

        #expect(recorder.handled.isEmpty)
        #expect(owner.isArmed == false)
        #expect(lifecycle.captureOwnerCensus().isEmpty)
        #expect(recorder.retired == [1])
    }

    @Test(
        "a real main-queue timer fires once and returns the census to empty",
        .timeLimit(.minutes(1))
    )
    func realTimerFiresOnce() async throws {
        let lifecycle = AppRuntimeSchedulingLifecycle()
        let recorder = ScheduledOwnerRecorder()
        let owner = AppRuntimeScheduledOwner<DispatchSourceTimer>(timerIn: lifecycle)
        let fires = AsyncStream<Void>.makeStream()

        owner.armTimer(deadline: .now() + .milliseconds(1)) {
            recorder.handled.append(1)
            fires.continuation.finish()
        }

        #expect(lifecycle.captureOwnerCensus()[.timer] == 1)

        try await awaitOneFire(fires.stream)

        #expect(recorder.handled == [1])
        #expect(owner.isArmed == false)
        #expect(lifecycle.captureOwnerCensus().isEmpty)
    }
}
