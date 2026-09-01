// Swift Testing suite for the modes of the files a live runtime creates: both checkpoint
// tiers, the recovery directory that holds them, the scrollback replay file a restore hands
// the shell, and the state export the user picks a destination for. It also pins the one
// artifact deliberately left public -- the config file and its directory. The seam's own
// contract is DanTermSupport's subject; what this file proves is that the production paths
// through the runtime actually reach it, with nothing else in the process arranging the
// modes on their behalf.
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
        //   and removing that incidental chmod would silently bring the exposure back. The
        //   directory now comes from the launch lock claim, which is why the test takes that
        //   step before it drives the runtime.
        // Scenario: the DT-SEC-05 report -- a launched instance, no CLI command, quit.
        let fixture = RecordingAppRuntimePorts()
        let instance = TemporaryInstancePaths()
        defer { instance.remove() }
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

        runtime.bootstrapFromTestSnapshot(makeCommandSnapshot(paneId: PaneId(rawValue: UUID())))
        runtime.flushPendingCheckpoint()
        runtime.performScrollbackCheckpoint(async: false)

        #expect(try posixMode(of: instance.paths.sessionCheckpointFile) == 0o600)
        #expect(try posixMode(of: instance.paths.scrollbackCheckpointFile) == 0o600)
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

    @Test("restore replay uses the model-owned agent session")
    func restoreReplayUsesModelOwnedAgentSession() throws {
        // Intent: the runtime adds the recovery hint from the restored pane model.
        // Why it exists: the raw pane snapshot remains available for scrollback and
        //   launch facts, but it must not become a second agent-session authority.
        // Scenario: a valid persisted Claude session restores through the runtime's
        //   production staging path and writes its resume hint to the replay file.
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
        let snapshot = makeCommandSnapshot(
            paneId: paneId,
            agentSession: AgentSessionSnapshot(kind: "claude", sessionId: "abc123")
        )
        let built = try #require(validateAndBuildDetailed(snapshot))

        runtime.bootstrapFromValidatedRestore(ValidatedAppRestore(
            model: built.model,
            paneSnapshots: built.paneSnapshots
        ))

        let request = try #require(fixture.sessionRequests.last)
        let replayPath = try #require(
            request.environment.first { $0.0 == "DANTERM_RESTORE_SCROLLBACK_FILE" }?.1
        )
        let replayText = try String(contentsOfFile: replayPath, encoding: .utf8)
        #expect(replayText == """
        [DanTerm] Restored Claude session. Resume with:
          claude --resume abc123

        """)
    }

    @Test("an exported state file is owner-only, wherever the user chose to put it")
    func exportedStateIsPrivate() async throws {
        // Intent: the file `Export State` writes lands at 0600, and narrows a destination the
        //   user picked that already existed at 0644.
        // Why it exists: the export carries every pane's scrollback, exactly like the scrollback
        //   checkpoint, but the user names its destination -- often a shared or synced folder.
        //   Content decides the mode here, not the path (AR1).
        // Scenario: a user picking a destination that already holds a previous export.
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        let snapshot = makeCommandSnapshot(paneId: paneId)
        fixture.session.primaryHistoryTail = "secret history\n"
        runtime.installTerminalSession(fixture.session, paneId: paneId)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-export-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("state.json")
        try Data("previous export".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: destination.path
        )
        fixture.exportDestination = destination
        let descriptor = Darwin.open(directory.path, O_EVTONLY)
        try #require(descriptor >= 0)
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        let destinationPath = destination.path
        let eventHandler: @Sendable () -> Void = {
            // The export renames a staged sibling over a destination that already held a
            // previous export, so "finished" is the size changing, not the file appearing.
            var status = stat()
            guard lstat(destinationPath, &status) == 0, status.st_size > 16 else { return }
            continuation.yield()
            continuation.finish()
        }
        let cancelHandler: @Sendable () -> Void = { Darwin.close(descriptor) }
        source.setEventHandler(handler: eventHandler)
        source.setCancelHandler(handler: cancelHandler)
        source.resume()
        defer { source.cancel() }

        runtime.perform(.exportState(snapshot))

        for await _ in events { break }
        #expect(try posixMode(of: destination) == 0o600)
        #expect(
            try String(decoding: Data(contentsOf: destination), as: UTF8.self)
                .contains("secret history")
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            == ["state.json"])
    }

    @Test("the harness sampler logs are owner-only, including one left behind at 0644")
    func samplerLogsArePrivate() throws {
        // Intent: the two live samplers open their logs at 0600, and narrow a log a previous
        //   run left at a broader mode.
        // Why it exists: these are compiled into every build and turned on by an environment
        //   variable, so they are production file creators even though only a harness asks for
        //   them. Their lines carry a pane's delivery timing, not its content, but the seam
        //   owns the mode of everything this process makes rather than only of what looks
        //   sensitive (I1, I3).
        // Scenario: spec-first -- a profiling run pointed at a directory a previous run used.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-sampler-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let frameRateLog = root.appendingPathComponent("frame-rate.jsonl")
        let deliveryLog = root.appendingPathComponent("delivery.jsonl")
        let deliveryTrace = root.appendingPathComponent("delivery-trace.jsonl")
        try Data("{}\n".utf8).write(to: frameRateLog)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: frameRateLog.path
        )

        let frameRateSampler = TerminalFrameRateSampler.make(
            environment: [TerminalFrameRateSampler.environmentVariable: frameRateLog.path]
        )
        let deliverySampler = TerminalDeliveryShapeSampler.make(environment: [
            TerminalDeliveryShapeSampler.environmentVariable: deliveryLog.path,
            TerminalDeliveryShapeSampler.traceEnvironmentVariable: deliveryTrace.path,
        ])
        defer {
            frameRateSampler?.flush(deliveryCount: 0)
            deliverySampler?.flush(deliveryCount: 0)
        }

        try #require(frameRateSampler != nil)
        try #require(deliverySampler != nil)
        #expect(try posixMode(of: frameRateLog) == 0o600)
        #expect(try posixMode(of: deliveryLog) == 0o600)
        #expect(try posixMode(of: deliveryTrace) == 0o600)
    }

    @Test("the config file and its directory stay at the umask default")
    func configArtifactsAreNotPrivate() throws {
        // Intent: `~/.config/danterm/config.json` and the directory holding it come out at the
        //   same mode any other program's file would, not at 0600 and 0700.
        // Why it exists: the config is one of three artifacts deliberately left outside the
        //   private-write seam, because the user opens and edits it directly and it carries no
        //   terminal content. Routing it through the seam later would be a silent regression
        //   with no test to catch it (I4).
        // Scenario: a first launch seeding a config into a directory that does not exist yet.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-config-privacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configDirectory = root.appendingPathComponent("danterm")
        let store = DanTermConfigStore(url: configDirectory.appendingPathComponent("config.json"))

        try store.seedIfMissing()

        // The umask is process-global and this suite runs in parallel, so the reference
        // artifacts are made the same way any other program would make them rather than by
        // reading the umask.
        let referenceDirectory = root.appendingPathComponent("reference", isDirectory: true)
        try FileManager.default.createDirectory(
            at: referenceDirectory,
            withIntermediateDirectories: true
        )
        let referenceFile = referenceDirectory.appendingPathComponent("reference.json")
        try Data("{}".utf8).write(to: referenceFile, options: .atomic)

        #expect(try posixMode(of: store.url) == (try posixMode(of: referenceFile)))
        #expect(try posixMode(of: configDirectory) == (try posixMode(of: referenceDirectory)))
    }
}
