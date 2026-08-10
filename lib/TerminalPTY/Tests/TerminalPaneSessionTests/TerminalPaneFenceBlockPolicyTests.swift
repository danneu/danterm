// Behavioral tests for marker-to-completion fence metric sampling.
import Testing
@testable import TerminalPaneSession

struct TerminalPaneFenceBlockPolicyTests {
    @Test("completion reports the delta from the start-marker sample")
    func completionReportsStartMarkerDelta() {
        // Intent: one completed block contains exactly the attributed and raw
        //   fence growth after its start marker.
        // Why it exists: cumulative process-lifetime counters would otherwise
        //   leak initialization and earlier block work into benchmark evidence.
        // Scenario: a block begins after initialization, then performs delivery,
        //   checkpoint, and teardown fences before its completion draw.
        var policy = TerminalPaneFenceBlockPolicy()
        policy.beginBlock(at: metrics(
            delivery: (10, 1),
            checkpoint: (20, 2),
            hostEntryCount: 3
        ))

        let result = policy.completeBlock(at: metrics(
            delivery: (40, 4),
            checkpoint: (70, 5),
            teardown: (11, 1),
            hostEntryCount: 10
        ))

        #expect(result == metrics(
            delivery: (30, 3),
            checkpoint: (50, 3),
            teardown: (11, 1),
            hostEntryCount: 7
        ))
    }

    @Test("application-exit fence invalidates an open block")
    func applicationExitInvalidatesOpenBlock() {
        // Intent: an exit-fenced controller cannot provide completion metrics.
        // Why it exists: a queued draw can outlive application-exit preparation,
        //   but it must not sample a controller whose lifetime has ended.
        // Scenario: the app receives SIGTERM after a marker but before the final draw.
        var policy = TerminalPaneFenceBlockPolicy()
        policy.beginBlock(at: metrics(delivery: (10, 1), hostEntryCount: 1))

        policy.invalidateAfterApplicationExitFence()

        #expect(policy.completeBlock(
            at: metrics(delivery: (20, 2), teardown: (5, 1), hostEntryCount: 3)
        ) == nil)
    }

    @Test("persistent blocks exclude fences between marker baselines")
    func persistentBlocksExcludeInterBlockFences() {
        // Intent: each persistent block establishes a fresh cumulative baseline.
        // Why it exists: reset and command-echo fences between blocks are harness
        //   overhead, not work performed inside either measured span.
        // Scenario: one app completes a block, resets, then opens and completes another.
        var policy = TerminalPaneFenceBlockPolicy()
        policy.beginBlock(at: metrics(delivery: (10, 1), hostEntryCount: 1))
        let first = policy.completeBlock(
            at: metrics(delivery: (20, 2), hostEntryCount: 2)
        )

        policy.beginBlock(at: metrics(
            delivery: (50, 5),
            checkpoint: (20, 2),
            hostEntryCount: 7
        ))
        let second = policy.completeBlock(at: metrics(
            delivery: (80, 8),
            checkpoint: (30, 3),
            hostEntryCount: 11
        ))

        #expect(first == metrics(delivery: (10, 1), hostEntryCount: 1))
        #expect(second == metrics(
            delivery: (30, 3),
            checkpoint: (10, 1),
            hostEntryCount: 4
        ))
    }

    @Test("a decreasing cumulative sample cannot produce a block")
    func decreasingSampleIsRejected() {
        var policy = TerminalPaneFenceBlockPolicy()
        policy.beginBlock(at: metrics(delivery: (20, 2), hostEntryCount: 2))

        #expect(policy.completeBlock(
            at: metrics(delivery: (10, 1), hostEntryCount: 1)
        ) == nil)
    }

    private func metrics(
        delivery: (UInt64, UInt64) = (0, 0),
        checkpoint: (UInt64, UInt64) = (0, 0),
        teardown: (UInt64, UInt64) = (0, 0),
        initialization: (UInt64, UInt64) = (0, 0),
        diagnostic: (UInt64, UInt64) = (0, 0),
        hostEntryCount: UInt64
    ) -> TerminalPaneFenceMetrics {
        TerminalPaneFenceMetrics(
            delivery: .init(waitNanoseconds: delivery.0, count: delivery.1),
            checkpoint: .init(waitNanoseconds: checkpoint.0, count: checkpoint.1),
            teardown: .init(waitNanoseconds: teardown.0, count: teardown.1),
            initialization: .init(
                waitNanoseconds: initialization.0,
                count: initialization.1
            ),
            diagnostic: .init(waitNanoseconds: diagnostic.0, count: diagnostic.1),
            hostEntryCount: hostEntryCount
        )
    }
}
