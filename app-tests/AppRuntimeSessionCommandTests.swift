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
        let host = try #require(runtime.paneHosts[paneId])
        #expect(host.session === fixture.session)
        #expect(host.wrapper.terminalSession === fixture.session)
        #expect(fixture.session.renderingAvailableValues == [true])
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.subscription] == 1)
    }

    @Test("session input, focus, and immediate search commands reach the selected session")
    func sessionCommandsReachSession() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(fixture.session, paneId: paneId)

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
        runtime.installTerminalSession(fixture.session, paneId: paneId)

        runtime.perform(.sendSearchNeedle(paneId: paneId, needle: "go"))

        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == 1)
        #expect(fixture.session.searchNeedles.isEmpty)

        runtime.perform(.sendEndSearch(paneId: paneId))

        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == nil)
        #expect(fixture.session.searchNeedles.isEmpty)
        #expect(fixture.session.endSearchCount == 1)
    }

    // Intent: a pane's session and its chrome enter and leave the runtime together.
    // Why it exists: they used to live in two tables written by different call sites,
    // so one could survive the other.
    // Scenario: create a pane through the command interpreter, then tear it down.
    @Test("pane teardown drops the session and the pane chrome together")
    func tearDownRemovesSessionAndChrome() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())

        runtime.perform(.createSession(
            sessionId: SessionId(rawValue: UUID()),
            paneId: paneId,
            cwd: nil,
            command: nil,
            launchCommand: nil
        ))

        #expect(runtime.paneSession(for: paneId) === fixture.session)
        #expect(runtime.findPaneWrapper(for: paneId) != nil)

        runtime.tearDownSession(paneId)

        #expect(runtime.paneSession(for: paneId) == nil)
        #expect(runtime.findPaneWrapper(for: paneId) == nil)
        #expect(runtime.paneHosts[paneId] == nil)
    }

    // Intent: the reconcile pass destroys a pane the model no longer has.
    // Why it exists: the reconciler selects panes from the runtime's live table, and
    // that table is now the pane records rather than a separate session map.
    @Test("reconcile tears down a pane that left the model")
    func reconcileTearsDownAbsentPane() {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let paneId = PaneId(rawValue: UUID())
        runtime.installTerminalSession(fixture.session, paneId: paneId)

        runtime.reconcileSessionExistence()

        #expect(runtime.paneHosts[paneId] == nil)
    }

    // Intent: replacing the whole session tears every live pane down through the same
    // body the per-pane path uses -- record, replay file, and scheduled search work.
    // Why it exists: the whole-session path used to repeat that body inline and omit
    // the search debouncer, so a restore during a short needle's debounce left an armed
    // owner alive past the session it belonged to.
    // Scenario: a restored pane is mid-debounce on a two-character needle when a second
    // restore lands.
    @Test("a whole-session restore tears down every live pane and its scheduled work")
    func wholeSessionRestoreTearsDownLivePanes() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let livePaneId = PaneId(rawValue: UUID())
        let replacementPaneId = PaneId(rawValue: UUID())

        runtime.bootstrapFromSnapshot(
            makeCommandSnapshot(paneId: livePaneId, scrollback: "restored history\n")
        )
        let replayPath = try #require(fixture.sessionRequests.first?.environment.first {
            $0.0 == "DANTERM_RESTORE_SCROLLBACK_FILE"
        }?.1)
        #expect(FileManager.default.fileExists(atPath: replayPath))
        runtime.perform(.sendSearchNeedle(paneId: livePaneId, needle: "go"))
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == 1)

        runtime.bootstrapFromSnapshot(makeCommandSnapshot(paneId: replacementPaneId))

        #expect(runtime.paneHosts[livePaneId] == nil)
        #expect(runtime.paneHosts[replacementPaneId] != nil)
        #expect(FileManager.default.fileExists(atPath: replayPath) == false)
        #expect(runtime.schedulingLifecycle.captureOwnerCensus()[.debouncer] == nil)
        #expect(fixture.session.searchNeedles.isEmpty)
    }
}
