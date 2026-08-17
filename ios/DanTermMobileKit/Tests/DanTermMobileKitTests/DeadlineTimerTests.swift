// Verifies the instrument that delivers a moment the reconnect policy named: on the
// policy's own monotonic base, and without depending on a run loop that a drag can park.
import Foundation
import Testing
@testable import DanTermMobileKit

/// Records one delivery. The timer's callback escapes, so the moment it observed cannot be
/// held in a local variable.
@MainActor
private final class DeliveryProbe {
    var deliveredAt: TimeInterval?
}

/// Waits for a delivery without blocking the main actor, and reports an expiry as an expiry.
@MainActor
private func waitForDelivery(_ probe: DeliveryProbe) async throws -> TimeInterval {
    let expiry = Date().addingTimeInterval(30)
    while probe.deliveredAt == nil {
        if Date() >= expiry { throw POSIXError(.ETIMEDOUT) }
        try await Task.sleep(for: .milliseconds(5))
    }
    return probe.deliveredAt ?? 0
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DeadlineTimerTests {
    // Intent: the deadline is a deadline, not a hint -- delivery never happens before it,
    // measured on the same monotonic base the caller computed it on.
    // Why it exists: the shell converted the policy's monotonic deadline into an interval
    // and handed it to a timer that fires against a wall-clock date, so the base the policy
    // chose on purpose was not the base the retry arrived on.
    @Test func neverDeliversBeforeTheDeadline() async throws {
        let probe = DeliveryProbe()
        let timer = MobileDeadlineTimer()
        let deadline = MobileMonotonicClock.now + 0.2

        timer.schedule(until: deadline) { probe.deliveredAt = MobileMonotonicClock.now }

        #expect(try await waitForDelivery(probe) >= deadline)
    }

    // Intent: scheduling again replaces the pending deadline, and a cancelled deadline is
    // never delivered.
    // Why it exists: the shell cancels the pending retry on every decision the policy
    // returns, so a superseded deadline that still fired would hand the policy a tick it
    // no longer owes.
    @Test func schedulingReplacesAndCancellingDrops() async throws {
        let probe = DeliveryProbe()
        let timer = MobileDeadlineTimer()

        timer.schedule(until: MobileMonotonicClock.now + 0.02) {
            probe.deliveredAt = MobileMonotonicClock.now
        }
        let later = MobileMonotonicClock.now + 0.1
        timer.schedule(until: later) { probe.deliveredAt = MobileMonotonicClock.now }
        #expect(try await waitForDelivery(probe) >= later)

        probe.deliveredAt = nil
        timer.schedule(until: MobileMonotonicClock.now + 0.02) {
            probe.deliveredAt = MobileMonotonicClock.now
        }
        timer.cancel()
        // Meant to expire: the claim is that nothing arrives, so the only way to observe it
        // is to wait well past the deadline that was dropped.
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.deliveredAt == nil)
        #expect(timer.isPending == false)
    }
}
