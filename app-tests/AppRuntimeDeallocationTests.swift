// Proof that dropping an AppRuntime performs no work that assumes an executor.
//
// Teardown itself belongs to `AppRuntime.shutdown()` and is covered by the scheduling
// lifecycle suites. What is proved here is only that deallocation adds nothing to it.
import Foundation
import Synchronization
import Testing
@testable import DanTerm

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppRuntimeDeallocationTests {
    @Test("a runtime released off the main actor deallocates")
    func releaseOffTheMainActorDeallocates() async throws {
        // Intent: the last reference to a runtime can be dropped on any executor.
        // Why it exists: deallocation used to run `MainActor.assumeIsolated`, which asserts
        //   that whoever drops the last reference is on the main actor -- a fact no caller
        //   can be held to, and one the IPC actor broke. Against a tree that still does it,
        //   this dies as a process trap rather than as a failed expectation.
        // Scenario: a task on the cooperative pool holds the last reference and finishes.
        var owner: AppRuntime? = makeCommandTestRuntime(RecordingAppRuntimePorts())
        owner?.shutdown()
        weak let released = owner
        // The handoff, in order: the pool's box takes a reference, this frame gives up its
        // own, and only then does the pool drop the one that is now the last.
        let box = Mutex<AppRuntime?>(owner)
        owner = nil

        let releasedOffMainThread = await Task.detached {
            // `Thread.isMainThread` is unavailable from an async context, and this has to
            // report the thread that performs the release below.
            let offMainThread = pthread_main_np() == 0
            box.withLock { $0 = nil }
            return offMainThread
        }.value

        #expect(releasedOffMainThread)
        #expect(released == nil)
    }
}
