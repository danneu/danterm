// Deterministic traces for bounded, event-driven enriched recovery scheduling.

import Testing
@testable import DanTermCore

/// Pins recovery freshness and quiescence without relying on wall-clock test delays.
struct RecoveryCheckpointPolicyTests {
    private let window: UInt64 = 600

    @Test("isolated and sustained mutations retain the first covering deadline")
    func mutationsRetainFirstDeadline() {
        var policy = RecoveryCheckpointPolicy(window: window)

        #expect(policy.mutation(at: 10) == .schedule(deadline: 610))
        #expect(policy.mutation(at: 300) == .none)
        #expect(policy.deadlineReached(at: 609) == .none)
        #expect(policy.deadlineReached(at: 610) == .write(revision: 2))
    }

    @Test("a mutation during a write remains dirty until a later write covers it")
    func mutationDuringWriteNeedsLaterCoverage() {
        var policy = RecoveryCheckpointPolicy(window: window)

        _ = policy.mutation(at: 0)
        #expect(policy.deadlineReached(at: 600) == .write(revision: 1))
        #expect(policy.mutation(at: 650) == .schedule(deadline: 1_250))
        #expect(policy.writeCompleted(revision: 1, succeeded: true, at: 700) == .none)
        #expect(policy.isDirty)
        #expect(policy.deadlineReached(at: 1_250) == .write(revision: 2))
        #expect(policy.writeCompleted(revision: 2, succeeded: true, at: 1_251) == .cancel)
        #expect(policy.isDirty == false)
    }

    @Test("an in-flight write hands an overdue mutation directly to a covering write")
    func overdueMutationStartsWhenOlderWriteCompletes() {
        var policy = RecoveryCheckpointPolicy(window: window)

        _ = policy.mutation(at: 0)
        #expect(policy.deadlineReached(at: 600) == .write(revision: 1))
        #expect(policy.mutation(at: 650) == .schedule(deadline: 1_250))
        #expect(policy.deadlineReached(at: 1_250) == .none)
        #expect(policy.writeCompleted(revision: 1, succeeded: true, at: 1_300) == .write(revision: 2))
    }

    @Test("failed writes retry until covering success then become quiescent")
    func failureRetriesToSuccess() {
        var policy = RecoveryCheckpointPolicy(window: window)

        _ = policy.mutation(at: 5)
        #expect(policy.deadlineReached(at: 605) == .write(revision: 1))
        #expect(policy.writeCompleted(revision: 1, succeeded: false, at: 606) == .schedule(deadline: 1_206))
        #expect(policy.deadlineReached(at: 1_206) == .write(revision: 1))
        #expect(policy.writeCompleted(revision: 1, succeeded: true, at: 1_207) == .cancel)
        #expect(policy.scheduledDeadline == nil)
        #expect(policy.deadlineReached(at: 10_000) == .none)
    }

    @Test("clean idle and termination schedule no recurring work")
    func cleanIdleAndTerminationAreQuiescent() {
        var clean = RecoveryCheckpointPolicy(window: window)
        #expect(clean.deadlineReached(at: 10_000) == .none)
        clean.terminate()
        #expect(clean.scheduledDeadline == nil)
        #expect(clean.mutation(at: 20) == .none)

        var dirty = RecoveryCheckpointPolicy(window: window)
        _ = dirty.mutation(at: 10)
        dirty.terminate()
        #expect(dirty.scheduledDeadline == nil)
        #expect(dirty.mutation(at: 20) == .none)
    }
}
