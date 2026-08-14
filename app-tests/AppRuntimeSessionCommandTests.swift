// Command-interpreter coverage for terminal sessions and search scheduling.
import DanTermProtocol
import Foundation
import Testing
@testable import DanTerm

@MainActor
struct AppRuntimeSessionCommandTests {
    @Test("session creation forwards launch inputs and installs the returned session")
    func createSessionInstallsPortResult() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let sessionId = SessionId(rawValue: UUID())
        let paneId = PaneId(rawValue: UUID())

        runtime.perform(.createSession(
            sessionId: sessionId,
            paneId: paneId,
            cwd: "/tmp/worktree",
            command: "printf ready",
            launchCommand: "codex"
        ))

        let request = try #require(fixture.sessionRequests.first)
        #expect(fixture.sessionRequests.count == 1)
        #expect(request.workingDirectory == "/tmp/worktree")
        #expect(request.command == "printf ready")
        #expect(request.launchCommand == "codex")
        #expect(request.waitAfterCommand)
        #expect(request.environment.contains { key, value in
            key == EnvVars.pane && value == paneId.rawValue.uuidString
        })
        #expect(runtime.sessions[paneId] === fixture.session)
        #expect(runtime.paneHosts[paneId]?.session === fixture.session)
        #expect(fixture.session.renderingAvailableValues == [true])
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.subscription] == 1)
    }

    @Test("session input, focus, and immediate search commands reach the selected session")
    func sessionCommandsReachSession() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.sessions[paneId] = fixture.session

        runtime.perform(.sendText(paneId: paneId, text: "pasted"))
        runtime.perform(.sendInputText(paneId: paneId, text: "typed"))
        runtime.perform(.sendInputKey(
            paneId: paneId,
            key: .named(.up),
            mods: [.ctrl, .shift]
        ))
        runtime.perform(.sendInputWheel(
            paneId: paneId,
            direction: .up,
            column: 4,
            row: 2
        ))
        runtime.perform(.focusSession(paneId: paneId, focused: true))
        runtime.perform(.sendStartSearch(paneId: paneId))
        runtime.perform(.sendSearchNeedle(paneId: paneId, needle: "find"))
        runtime.perform(.sendSearchNavigate(paneId: paneId, direction: .previous))

        #expect(fixture.session.sentText == ["pasted"])
        #expect(fixture.session.sentInputText == ["typed"])
        let key = try #require(fixture.session.sentInputKeys.first)
        #expect(fixture.session.sentInputKeys.count == 1)
        #expect(key.key == .named(.up))
        #expect(key.modifiers == [.ctrl, .shift])
        let wheel = try #require(fixture.session.sentInputWheels.first)
        #expect(fixture.session.sentInputWheels.count == 1)
        #expect(wheel.direction == .up)
        #expect(wheel.column == 4)
        #expect(wheel.row == 2)
        #expect(fixture.session.focusedValues == [true])
        #expect(fixture.session.startSearchCount == 1)
        #expect(fixture.session.searchNeedles == ["find"])
        #expect(fixture.session.searchDirections.count == 1)
        if case .previous = fixture.session.searchDirections[0] {
        } else {
            Issue.record("expected previous search navigation")
        }
    }

    @Test("ending search cancels a pending short-needle delivery")
    func endSearchCancelsPendingNeedle() {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.sessions[paneId] = fixture.session

        runtime.perform(.sendSearchNeedle(paneId: paneId, needle: "go"))

        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == 1)
        #expect(fixture.session.searchNeedles.isEmpty)

        runtime.perform(.sendEndSearch(paneId: paneId))

        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == nil)
        #expect(fixture.session.searchNeedles.isEmpty)
        #expect(fixture.session.endSearchCount == 1)
    }
}
