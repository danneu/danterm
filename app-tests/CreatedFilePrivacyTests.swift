// Swift Testing suite for the modes of the files a live runtime creates: both checkpoint
// tiers, the recovery directory that holds them, and the scrollback replay file a restore
// hands the shell. The seam's own contract is DanTermSupport's subject; what this file
// proves is that the production paths through the runtime actually reach it, with nothing
// else in the process arranging the modes on their behalf.
import DanTermProtocol
import Darwin
import Foundation
import Testing

@testable import DanTerm

/// Reads the permission bits an artifact carries, without following a symlink.
private func posixMode(of url: URL) throws -> mode_t {
    var status = stat()
    try #require(lstat(url.path, &status) == 0, "\(url.path) should exist")
    return status.st_mode & 0o777
}

@MainActor
struct CreatedFilePrivacyTests {
    @Test("an instance that never served a request still writes private checkpoints")
    func checkpointsArePrivateWithoutAnAuditWriter() throws {
        // Intent: both checkpoint tiers land at 0600 inside a 0700 recovery directory in a
        //   process that never constructed an IPC audit writer.
        // Why it exists: the recovery directory used to reach 0700 only because the audit
        //   writer chmod'd it on the first `danterm` invocation (DT-SEC-05). An instance
        //   nobody ever addressed left every pane's scrollback in a umask-default directory,
        //   and removing that incidental chmod would silently bring the exposure back.
        // Scenario: the DT-SEC-05 report -- a launched instance, no CLI command, quit.
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

        runtime.bootstrapFromSnapshot(makeCommandSnapshot(paneId: PaneId(rawValue: UUID())))
        runtime.flushPendingCheckpoint()
        runtime.performEnrichedCheckpoint(async: false)

        #expect(try posixMode(of: instance.paths.lightCheckpointFile) == 0o600)
        #expect(try posixMode(of: instance.paths.enrichedCheckpointFile) == 0o600)
        #expect(try posixMode(of: instance.paths.recoveryDirectory) == 0o700)
    }

    @Test("the scrollback replay file a restore writes is owner-only")
    func replayFileIsPrivate() throws {
        // Intent: the file a restored pane's shell replays from, and the directory holding
        //   it, are unreadable by another user.
        // Why it exists: the replay file is a verbatim copy of a pane's history written into
        //   a temporary root, which is the most exposed place this process writes at all
        //   (DT-SEC-16). It was created at the umask default under a directory with no mode.
        // Scenario: a restore that carries pane scrollback, driven through the runtime's own
        //   restore path so the path under test is the one production takes.
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
        let paneId = PaneId(rawValue: UUID())
        let snapshot = makeCommandSnapshot(paneId: paneId, scrollback: "secret history\n")
        let built = try #require(validateAndBuildDetailed(snapshot))

        runtime.bootstrapFromValidatedRestore(ValidatedAppRestore(
            snapshot: snapshot,
            model: built.model,
            paneSnapshots: built.paneSnapshots
        ))

        let request = try #require(fixture.sessionRequests.last)
        let replayPath = try #require(
            request.environment.first { $0.0 == "DANTERM_RESTORE_SCROLLBACK_FILE" }?.1
        )
        let replayFile = URL(fileURLWithPath: replayPath)
        #expect(try posixMode(of: replayFile) == 0o600)
        #expect(try posixMode(of: instance.paths.scrollbackReplayDirectory) == 0o700)
    }
}
