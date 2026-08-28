// Runtime-side coverage for the light checkpoint tier's retry: what reaches disk after a
// write fails. The decision itself is pure and tested in `LightCheckpointPolicyTests`; this
// file exists for the seam the pure test cannot reach -- the runtime hearing the writer's
// outcome at all.
import Foundation
import Testing

@testable import DanTerm

@MainActor
struct AppRuntimeLightCheckpointTests {
    /// Waits until every deferred runtime callback has run, which is how a test observes that
    /// the checkpoint writer's outcome reached the runtime: the writer always delivers on the
    /// main queue, so the token it consumes disappears from the census only after delivery.
    ///
    /// The deadline is a hang guard, not a threshold: a passing run returns in one turn.
    private func waitForCheckpointOutcome(_ runtime: AppRuntime) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if runtime.schedulingLifecycle.captureOwnerCensus()[.deferredCallback] == nil {
                return
            }
            await Task.yield()
        }
        throw POSIXError(.ETIMEDOUT)
    }

    @Test("a failed light write is retried once the destination is writable again",
          .timeLimit(.minutes(1)))
    func failedLightWriteIsRetried() async throws {
        // Intent: after a light write fails, the next window writes the same projection,
        //   with no further change to persisted state.
        // Why it exists: the light tier took coverage of a projection when it handed the
        //   write off and never heard whether it landed, so one failed write left a stale
        //   checkpoint on disk until some unrelated part of the model happened to change.
        // Scenario: spec-first. A directory sits where the checkpoint file belongs, so the
        //   first write cannot land; it is removed, and a second window fires.
        let fixture = RecordingAppRuntimePorts()
        let instance = TemporaryInstancePaths()
        defer { instance.remove() }
        let runtime = AppRuntime(
            ports: fixture.value,
            dialogSurfaces: RecordingDialogSurfaces().value,
            instancePaths: instance.paths,
            configStore: DanTermConfigStore(url: instance.absentConfigURL),
            startsApplicationServices: false,
            applicationActive: true
        )
        defer { runtime.shutdown() }
        // An atomic write cannot replace a directory, so this fails the write and nothing else.
        try FileManager.default.createDirectory(
            at: instance.paths.lightCheckpointFile,
            withIntermediateDirectories: true
        )

        runtime.send(.createTabInSelectedGroup())
        runtime.flushPendingCheckpoint()
        try await waitForCheckpointOutcome(runtime)
        #expect(
            (try? Data(contentsOf: instance.paths.lightCheckpointFile)) == nil,
            "the blocked write must not have produced a checkpoint"
        )

        try FileManager.default.removeItem(at: instance.paths.lightCheckpointFile)
        runtime.flushPendingCheckpoint()
        try await waitForCheckpointOutcome(runtime)

        let checkpoint = try loadValidatedInitFile(
            from: try Data(contentsOf: instance.paths.lightCheckpointFile)
        )
        #expect(checkpoint.model.allPaneIds == runtime.model.allPaneIds)
        #expect(checkpoint.model.allPaneIds.isEmpty == false)
    }
}
