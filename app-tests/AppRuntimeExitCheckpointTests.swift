// Runtime-side coverage for what the exit path leaves on disk: the structure checkpoint
// is flushed before the scrollback write, so the restore the next launch offers is the
// model at exit time -- and an exit that empties the model leaves the previous session
// on disk untouched. The write decisions themselves are pure and tested in DanTermCore;
// this file exists for the exit path's ordering, which no pure test can reach.
import Foundation
import Testing

@testable import DanTerm

@MainActor
struct AppRuntimeExitCheckpointTests {
    /// Builds a runtime over a temporary instance whose recovery directory exists, which
    /// in the app is the session lock claim's job rather than the checkpoint writer's.
    private func makeRuntime(
        _ fixture: RecordingAppRuntimePorts,
        _ instance: TemporaryInstancePaths
    ) -> AppRuntime {
        _ = claimSessionLock(paths: instance.paths)
        return AppRuntime(
            ports: fixture.value,
            dialogSurfaces: RecordingDialogSurfaces().value,
            instancePaths: instance.paths,
            configStore: DanTermConfigStore(url: instance.absentConfigURL),
            startsApplicationServices: false,
            applicationActive: true
        )
    }

    /// What the next launch would offer to restore from this instance's checkpoints.
    private func offeredRestore(_ instance: TemporaryInstancePaths) -> ValidatedAppRestore? {
        loadLaunchCheckpoints(
            paths: instance.paths,
            startup: .promptForRecovery,
            hasInitSnapshot: false
        )
    }

    @Test("the exit path persists a structural edit made inside the last checkpoint window")
    func exitFlushesStructureEditedSinceTheLastWindow() throws {
        // Intent: a tab renamed after the last flush is in the restore the next launch
        //   offers, because the exit path writes the structure checkpoint too (plan I2, PO1).
        // Why it exists: the exit path used to write only the scrollback file, and the
        //   loader takes structure from the other file, so up to one coalescing window of
        //   structural edits -- renames, closes, splits, colors, todos -- was discarded at
        //   load on every clean quit.
        // Scenario: spec-first. A tab is flushed to disk, then renamed with no flush, and
        //   the application exit path runs.
        let fixture = RecordingAppRuntimePorts()
        let instance = TemporaryInstancePaths()
        defer { instance.remove() }
        let runtime = makeRuntime(fixture, instance)
        defer { runtime.shutdown() }

        runtime.send(.createTabInSelectedGroup())
        runtime.flushPendingCheckpoint()
        let tabId = try #require(runtime.model.groups.first?.tabs.first?.id)
        runtime.send(.renameTab(id: tabId, name: "renamed after the flush"))

        runtime.prepareRecoveryForApplicationExit()

        let restore = try #require(offeredRestore(instance))
        #expect(restore.model.groups.flatMap(\.tabs).map(\.customTitle)
            == ["renamed after the flush"])
    }

    @Test("closing the last tab to quit leaves the previous session on disk")
    func exitFromAnEmptiedModelKeepsThePreviousSession() throws {
        // Intent: after the close-last-tab quit empties the model, the exit path writes
        //   neither checkpoint, so the next launch still offers the session as it was
        //   before the close (plan I3, PO2).
        // Why it exists: flushing structure on exit without the restorability refusal
        //   would replace the last good session with an empty one the loader rejects,
        //   turning every quit-by-closing-the-last-tab into no restore offer at all.
        // Scenario: spec-first. The only tab holds two panes, so closing it asks for the
        //   close confirmation that carries the quit authorization; confirming it empties
        //   the model and asks to terminate in the same frame.
        let fixture = RecordingAppRuntimePorts()
        let instance = TemporaryInstancePaths()
        defer { instance.remove() }
        let runtime = makeRuntime(fixture, instance)
        defer { runtime.shutdown() }

        runtime.send(.createTabInSelectedGroup())
        runtime.send(.splitFocusedPane(direction: .vertical))
        runtime.flushPendingCheckpoint()
        runtime.performScrollbackCheckpoint(async: false)
        let sidecarBefore = try Data(contentsOf: instance.paths.scrollbackCheckpointFile)

        let tabId = try #require(runtime.model.groups.first?.tabs.first?.id)
        runtime.send(.requestCloseTab(id: tabId))
        let confirmationId = try #require(runtime.model.pendingConfirmation?.id)
        runtime.send(.answerConfirmation(id: confirmationId, answer: .confirm))
        #expect(runtime.model.groups.flatMap(\.tabs).isEmpty)
        #expect(fixture.terminateCount == 1)

        runtime.prepareRecoveryForApplicationExit()

        let restore = try #require(offeredRestore(instance))
        #expect(restore.model.groups.flatMap(\.tabs).count == 1)
        #expect(try Data(contentsOf: instance.paths.scrollbackCheckpointFile) == sidecarBefore)
    }
}
