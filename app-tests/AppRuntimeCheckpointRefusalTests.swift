// Runtime-side coverage for the enriched checkpoint's restorability refusal: an
// unrestorable model writes no file and reports success, and the refusal leaves the
// write path able to write the next restorable model. The rule itself is the snapshot
// predicate tested in DanTermCore; this file exists for the write chokepoint and its
// completion reporting, which the pure tests cannot reach.
import Foundation
import Testing

@testable import DanTerm

/// Collects writer outcomes on the main actor, because a `@Sendable` completion may
/// not capture a mutable local.
@MainActor
private final class OutcomeLog {
    var outcomes: [CheckpointWriteOutcome] = []
}

@MainActor
struct AppRuntimeCheckpointRefusalTests {
    @Test("an unrestorable model's enriched write is refused as a success, and a restorable one still writes")
    func unrestorableEnrichedWriteIsRefusedAsSuccess() throws {
        // Intent: with the empty launch model, performEnrichedCheckpoint(async: false)
        //   creates no file and completes as a success; once a tab exists, the same
        //   call writes a checkpoint the loader accepts (plan I1, PO4).
        // Why it exists: refusing with a failure would wedge the mutation-driven retry
        //   policy on a write that must never happen, and writing anyway would replace
        //   a restorable checkpoint on disk with one the next launch refuses.
        // Scenario: spec-first. A bare runtime (one group, no tabs) refuses; creating
        //   a tab makes the next synchronous write land.
        let fixture = RecordingAppRuntimePorts()
        let instance = TemporaryInstancePaths()
        defer { instance.remove() }
        // The lock claim is what creates the recovery directory at launch, and the
        // checkpoint writer creates none, so a checkpoint needs this step first.
        _ = claimSessionLock(paths: instance.paths)
        let runtime = AppRuntime(
            ports: fixture.value,
            dialogSurfaces: RecordingDialogSurfaces().value,
            instancePaths: instance.paths,
            configStore: DanTermConfigStore(url: instance.absentConfigURL),
            startsApplicationServices: false,
            applicationActive: true
        )
        defer { runtime.shutdown() }

        let log = OutcomeLog()
        runtime.performEnrichedCheckpoint(async: false) { log.outcomes.append($0) }

        #expect(
            FileManager.default.fileExists(atPath: instance.paths.enrichedCheckpointFile.path) == false,
            "the refused write must not create a checkpoint"
        )
        #expect(log.outcomes.map(\.isSucceeded) == [true])

        runtime.send(.createTabInSelectedGroup())
        runtime.performEnrichedCheckpoint(async: false)

        let checkpoint = try loadValidatedInitFile(
            from: try Data(contentsOf: instance.paths.enrichedCheckpointFile)
        )
        #expect(checkpoint.model.allPaneIds.isEmpty == false)
    }
}
