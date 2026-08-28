// Deterministic traces for the light checkpoint tier's coverage and retry rule.
//
// The traces here stand in for a disk the tests never touch: a handoff is a write the runtime
// gave to its serial writer, and a completion is what that writer reported back. What matters
// is which projection the next fired window writes, so every trace ends on a capture decision.
//
// Each capture lands in a local first, because a `#expect`/`#require` argument may not call a
// mutating member.

import Testing
@testable import DanTermCore

/// Pins light-tier coverage against failed writes and out-of-order completions.
struct LightCheckpointPolicyTests {
    private func projection(_ title: String) -> LightCheckpointProjection {
        var model = makeModel()
        createTab(&model)
        update(&model, .renameTab(id: model.groups[0].tabs[0].id, name: title))
        return LightCheckpointProjection(snapshot: toSnapshot(model, home: "/Users/testhome"))
    }

    @Test("a failed write is retried and a successful one is not")
    func failedWriteIsRetried() throws {
        // Intent: coverage advances at handoff, a reported failure withdraws it, and a
        //   reported success leaves an unchanged projection with nothing to write.
        // Why it exists: the light tier used to advance its baseline at handoff and never
        //   hear the outcome, so a failed write left a stale file on disk until some other
        //   part of the model happened to change.
        // Scenario: spec-first. The launch projection is covered; one change is written,
        //   fails once, is retried, and then succeeds.
        let launch = projection("launch")
        let changed = projection("changed")
        var policy = LightCheckpointPolicy(covering: launch)

        let atLaunch = policy.capture(launch)
        #expect(atLaunch == nil)

        let firstWork = policy.capture(changed)
        let first = try #require(firstWork)
        #expect(try toSnapshot(decodeLightCapture(first.capture).model) == changed.snapshot)
        let repeated = policy.capture(changed)
        #expect(repeated == nil, "a handoff covers the projection it carried")

        policy.writeCompleted(handoff: first.handoff, succeeded: false)
        let retryWork = policy.capture(changed)
        let retry = try #require(retryWork)
        #expect(try toSnapshot(decodeLightCapture(retry.capture).model) == changed.snapshot)

        policy.writeCompleted(handoff: retry.handoff, succeeded: true)
        let afterSuccess = policy.capture(changed)
        #expect(afterSuccess == nil)
    }

    @Test("a failure cannot withdraw coverage a later handoff established")
    func staleFailureLeavesLaterCoverageIntact() throws {
        // Intent: an outcome only decides coverage when it names the newest handoff.
        // Why it exists: two light writes can be in flight at once, and the older one's
        //   failure says nothing about the newer projection already on its way to disk.
        //   Retrying on it would write a projection the runtime has moved past.
        // Scenario: spec-first. B and C are handed off in that order, and B's write fails.
        let launch = projection("launch")
        let b = projection("b")
        let c = projection("c")
        var policy = LightCheckpointPolicy(covering: launch)

        let workB = policy.capture(b)
        let handoffB = try #require(workB).handoff
        let workC = policy.capture(c)
        _ = try #require(workC)
        policy.writeCompleted(handoff: handoffB, succeeded: false)

        let afterStaleFailure = policy.capture(c)
        #expect(afterStaleFailure == nil)
    }

    @Test("the newest handoff's failure retries the current projection")
    func newestFailureRetriesCurrentProjection() throws {
        // Intent: when the newest handoff fails, the next window writes whatever the
        //   projection is then -- not the projection that failed.
        // Why it exists: a retry that replayed the failed capture could put a superseded
        //   model on disk, which is worse than the stale file it set out to repair.
        // Scenario: spec-first. B and C are handed off, C's write fails, and the model has
        //   moved on to D by the time the next window fires.
        let launch = projection("launch")
        let b = projection("b")
        let c = projection("c")
        let d = projection("d")
        var policy = LightCheckpointPolicy(covering: launch)

        let workB = policy.capture(b)
        _ = try #require(workB)
        let workC = policy.capture(c)
        let handoffC = try #require(workC).handoff
        policy.writeCompleted(handoff: handoffC, succeeded: false)

        let retryWork = policy.capture(d)
        let retry = try #require(retryWork)
        #expect(try toSnapshot(decodeLightCapture(retry.capture).model) == d.snapshot)
    }

    @Test("a reversion while a write is in flight becomes the next write")
    func reversionAfterCaptureBecomesNextWrite() throws {
        // Intent: advancing coverage at handoff still detects a later reversion, so serial
        //   writer order ends at the current projection.
        // Why it exists: comparing against the last completed disk write would require
        //   callback coordination and can lose the projection that wins while an earlier
        //   encode runs.
        // Scenario: A is on disk, B is captured, then state returns to A before B completes.
        let a = projection("a")
        let b = projection("b")
        var policy = LightCheckpointPolicy(covering: a)

        let workB = policy.capture(b)
        _ = try #require(workB)
        let revertedWork = policy.capture(a)
        let reverted = try #require(revertedWork)
        #expect(try toSnapshot(decodeLightCapture(reverted.capture).model) == a.snapshot)
    }
}
