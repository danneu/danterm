// Swift Testing migration of the legacy `tests/DebouncerTests.swift` harness
// suite. Pins the trailing-edge dispatch debouncer's lifecycle (cancel/rebuild)
// and central re-arm contract that callers like the title-spam coalescer rely
// on.
import Foundation
import Testing

@testable import DanTermSupport

@Suite struct DebouncerTests {
    @Test("Debouncer: cancel before schedule is a no-op")
    func cancelBeforeScheduleIsNoOp() {
        // Intent: cancelling a never-scheduled debouncer leaves it idle.
        // Why it exists: guards the lifecycle path that must not release a
        //   suspended timer source.
        // Scenario: spec-first lifecycle check for a caller that tears down
        //   defensively before any event has armed the debounce.
        let debouncer = Debouncer(queue: .main)

        debouncer.cancel()

        #expect(!debouncer.isPending)
    }

    @Test("Debouncer: cancel disarms and stays reusable")
    func cancelDisarmsAndStaysReusable() {
        // Intent: a scheduled debouncer can be cancelled and scheduled again.
        // Why it exists: pins the cancel/rebuild lifecycle so source
        //   retirement does not make the owning Debouncer one-shot.
        // Scenario: spec-first lifecycle check for search teardown followed by
        //   a later short search needle in the same pane.
        let debouncer = Debouncer(queue: .main)

        debouncer.schedule(after: 30) {}
        #expect(debouncer.isPending)
        debouncer.cancel()
        #expect(!debouncer.isPending)
        debouncer.schedule(after: 30) {}

        #expect(debouncer.isPending)
        debouncer.cancel()
    }

    @Test("Debouncer: rapid reschedule stays cancellable")
    func rapidRescheduleStaysCancellable() {
        // Intent: repeated schedule calls re-arm without crashing or losing
        //   the pending state.
        // Why it exists: guards against accidentally resuming an already-
        //   resumed dispatch source while preserving one trailing fire slot.
        // Scenario: spec-first lifecycle check for high-frequency title or
        //   cwd events repeatedly pushing a checkpoint deadline forward.
        let debouncer = Debouncer(queue: .main)

        debouncer.schedule(after: 30) {}
        debouncer.schedule(after: 30) {}
        debouncer.schedule(after: 30) {}
        #expect(debouncer.isPending)
        debouncer.cancel()

        #expect(!debouncer.isPending)
    }

    @Test("Debouncer: reschedule moves deadline and keeps newest action")
    func rescheduleMovesDeadlineAndKeepsNewestAction() {
        // Intent: a later schedule moves the fire to the later trailing
        //   deadline, runs only the newest action, and clears pending.
        // Why it exists: locks down the central debounce contract against a
        //   fixed-window coalescer or a stale-action reschedule.
        // Scenario: spec-first behavior check for a title-spam burst where
        //   each event must push the checkpoint write until after the last
        //   event.
        let queue = DispatchQueue(label: "danterm.tests.debouncer")
        let debouncer = Debouncer(queue: queue)
        defer { queue.sync { debouncer.cancel() } }

        let delay: TimeInterval = 0.4
        let semaphore = DispatchSemaphore(value: 0)
        var fires: [String] = []
        var secondScheduleAt: DispatchTime?
        var firedAt: DispatchTime?

        queue.sync {
            debouncer.schedule(after: delay) {
                fires.append("A")
                firedAt = .now()
                semaphore.signal()
            }
        }

        Thread.sleep(forTimeInterval: delay * 0.5)
        secondScheduleAt = .now()
        queue.sync {
            debouncer.schedule(after: delay) {
                fires.append("B")
                firedAt = .now()
                semaphore.signal()
            }
        }

        let result = semaphore.wait(timeout: .now() + 3)
        #expect(result == .success, "debounced action should fire")

        let snapshot = queue.sync { (fires, firedAt, debouncer.isPending) }
        guard let secondScheduleAt, let firedAt = snapshot.1 else {
            Issue.record("missing timing sample")
            return
        }
        let elapsed = Double(firedAt.uptimeNanoseconds - secondScheduleAt.uptimeNanoseconds) / 1_000_000_000

        #expect(
            elapsed >= delay * 0.75,
            "fire should be measured from the last schedule, elapsed \(elapsed)"
        )
        #expect(snapshot.0 == ["B"])
        #expect(!snapshot.2)
    }

    @Test("Debouncer: schedule with a leeway still fires the trailing action")
    func scheduleWithLeewayStillFiresTrailingAction() {
        // Intent: a nonzero timer leeway still preserves the trailing debounce
        //   contract: the action fires, not before the deadline, and pending clears.
        // Why it exists: covers the new schedule API path used by checkpoint
        //   timers without asserting the OS's nondeterministic coalescing choice.
        // Scenario: spec-first behavior check for the light checkpoint debounce,
        //   which can tolerate delayed delivery but must still write after settling.
        let queue = DispatchQueue(label: "danterm.tests.debouncer.leeway")
        let debouncer = Debouncer(queue: queue)
        defer { queue.sync { debouncer.cancel() } }

        let delay: TimeInterval = 0.2
        let semaphore = DispatchSemaphore(value: 0)
        var scheduledAt: DispatchTime?
        var fired = false
        var firedAt: DispatchTime?

        queue.sync {
            scheduledAt = .now()
            debouncer.schedule(after: delay, leeway: .milliseconds(200)) {
                fired = true
                firedAt = .now()
                semaphore.signal()
            }
        }

        let result = semaphore.wait(timeout: .now() + 3)
        #expect(result == .success, "debounced action should fire")

        let snapshot = queue.sync { (fired, firedAt, debouncer.isPending) }
        guard let scheduledAt, let firedAt = snapshot.1 else {
            Issue.record("missing timing sample")
            return
        }
        let elapsed = Double(firedAt.uptimeNanoseconds - scheduledAt.uptimeNanoseconds) / 1_000_000_000

        #expect(snapshot.0)
        #expect(snapshot.2 == false)
        #expect(
            elapsed >= delay * 0.75,
            "fire should not precede the trailing deadline, elapsed \(elapsed)"
        )
    }
}
