// Command-interpreter coverage for injected macOS effects and export scheduling.
import Darwin
import Foundation
import Testing
@testable import DanTerm

@MainActor
struct AppRuntimeAmbientCommandTests {
    @Test("notification command preserves presentation and routing fields")
    func notificationBuildsPortRequest() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let alertId = AlertId(rawValue: UUID())
        let paneId = PaneId(rawValue: UUID())

        runtime.perform(.sendNotification(
            alertId: alertId,
            paneId: paneId,
            title: "Build complete",
            subtitle: "danterm",
            body: "All checks passed."
        ))

        let request = try #require(fixture.notifications.first)
        #expect(fixture.notifications.count == 1)
        #expect(request.content.title == "Build complete")
        #expect(request.content.subtitle == "danterm")
        #expect(request.content.body == "All checks passed.")
        #expect(request.content.threadIdentifier == paneId.rawValue.uuidString)
        #expect(request.content.userInfo["alertId"] as? String == alertId.rawValue.uuidString)
        #expect(request.trigger == nil)
    }

    @Test("export writes a pretty snapshot with captured session scrollback")
    func exportWritesEnrichedSnapshot() async throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        let snapshot = makeCommandSnapshot(paneId: paneId)
        fixture.session.primaryHistoryTail = "first line\nsecond line\n"
        runtime.sessions[paneId] = fixture.session
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("danterm-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("state.json")
        fixture.exportDestination = destination
        let descriptor = Darwin.open(directory.path, O_EVTONLY)
        try #require(descriptor >= 0)
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        let eventHandler: @Sendable () -> Void = {
            guard FileManager.default.fileExists(atPath: destination.path) else { return }
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
        let data = try Data(contentsOf: destination)
        let encoded = try #require(String(data: data, encoding: .utf8))
        let restored = try loadValidatedInitFile(from: data)
        #expect(encoded.contains("\n  \""), "export should use pretty-printed JSON")
        #expect(restored.snapshot.groups.count == 1)
        #expect(restored.paneSnapshots[paneId]?.scrollback == "first line\nsecond line\n")
    }

    @Test("terminate cancels timers, removes replay files, and calls the port once")
    func terminateClearsScheduledWorkAndReplayFiles() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        fixture.session.primaryHistoryText = nil
        let snapshot = makeCommandSnapshot(paneId: paneId, scrollback: "restored history\n")

        runtime.bootstrapFromSnapshot(snapshot)

        let request = try #require(fixture.sessionRequests.first)
        let replayPath = try #require(request.environment.first {
            $0.0 == "DANTERM_RESTORE_SCROLLBACK_FILE"
        }?.1)
        #expect(FileManager.default.fileExists(atPath: replayPath))
        fixture.session.onPrimaryHistoryMutation?()
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.timer] == 1)

        runtime.perform(.terminate)

        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.timer] == nil)
        #expect(FileManager.default.fileExists(atPath: replayPath) == false)
        #expect(fixture.terminateCount == 1)
    }

    @Test("activation command calls the activation port")
    func activationCallsPort() {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }

        runtime.perform(.activateApp)

        #expect(fixture.activationCount == 1)
    }
}
