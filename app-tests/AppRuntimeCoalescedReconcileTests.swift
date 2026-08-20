// How a send frame arms and retires the coalesced whole-model sweep.
import Foundation
import Testing
@testable import DanTerm

/// Proves the deferred reconcile sweep is armed once and retired by an inline reconcile.
@MainActor
struct AppRuntimeCoalescedReconcileTests {
    // Intent: a coalescing message defers one sweep, a non-coalescing message retires it
    //   because the inline reconcile already covered the model, and a later coalescing
    //   message arms a fresh one.
    // Why it exists: the sweep is the only reconcile a burst of cosmetic reports gets, so
    //   an owner left armed after an inline reconcile, or never re-armed after one, is a
    //   sweep the model silently loses.
    // Scenario: a search total report, then an integration-ready report, then another
    //   search total report.
    @Test("a coalescing message arms one sweep that a non-coalescing message retires")
    func coalescedSweepArmsAndRetires() {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        let sessionId = SessionId(rawValue: UUID())
        func armedTimers() -> Int {
            runtime.schedulingLifecycle.captureOwnerCensus()[.timer] ?? 0
        }

        // The light-checkpoint window also reports as a `.timer`, and the first send opens
        // it, so every assertion below is a delta against this settled count.
        runtime.send(.sessionReport(sessionId: sessionId, report: .integrationReady))
        let settled = armedTimers()

        runtime.send(.searchTotalReported(paneId: paneId, total: 3))
        #expect(armedTimers() == settled + 1)

        runtime.send(.sessionReport(sessionId: sessionId, report: .integrationReady))
        #expect(armedTimers() == settled)

        runtime.send(.searchTotalReported(paneId: paneId, total: 4))
        #expect(armedTimers() == settled + 1)
    }
}
