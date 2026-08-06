// Deterministic proof that application-runtime scheduling has a terminal shutdown state.
import Testing
@testable import DanTerm

/// Proves the runtime scheduling census closes every callback route at application exit.
@MainActor
struct AppRuntimeSchedulingLifecycleTests {
    @Test("shutdown empties every owner category and makes captured callbacks inert")
    func shutdownEmptiesEveryOwnerCategory() {
        // Intent: shutdown cancels every runtime scheduling category exactly once and is terminal.
        // Why it exists: app termination previously relied on scattered cancellation paths that
        //   neither enumerated outstanding work nor prevented a late callback from rearming it.
        // Scenario: every production category is armed, shutdown runs twice, then callbacks
        //   captured before shutdown fire and every category attempts to rearm.
        let lifecycle = AppRuntimeSchedulingLifecycle()
        var cancellations: [AppRuntimeSchedulingCategory: Int] = [:]
        var effects: [AppRuntimeSchedulingCategory] = []
        var callbacks: [(AppRuntimeSchedulingToken, AppRuntimeSchedulingCategory)] = []

        for category in AppRuntimeSchedulingCategory.allCases {
            let token = lifecycle.arm(category) {
                cancellations[category, default: 0] += 1
            }
            if let token {
                callbacks.append((token, category))
            }
        }

        #expect(lifecycle.isActive)
        #expect(lifecycle.snapshot.state == .active)
        #expect(lifecycle.snapshot.ownerCounts == Dictionary(
            uniqueKeysWithValues: AppRuntimeSchedulingCategory.allCases.map { ($0, 1) }
        ))

        lifecycle.shutdown()
        lifecycle.shutdown()

        #expect(lifecycle.isActive == false)
        #expect(lifecycle.snapshot == .shutdown)
        #expect(cancellations == Dictionary(
            uniqueKeysWithValues: AppRuntimeSchedulingCategory.allCases.map { ($0, 1) }
        ))

        for (token, category) in callbacks {
            lifecycle.run(token) {
                effects.append(category)
            }
        }
        for category in AppRuntimeSchedulingCategory.allCases {
            #expect(lifecycle.arm(category) {} == nil)
        }

        #expect(effects.isEmpty)
        #expect(lifecycle.snapshot == .shutdown)
    }
}
