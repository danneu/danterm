// Coverage for the application-activation input every pane derives its reported
// terminal focus from: the launch seed the runtime is built with, and the push that
// carries a later activation change to every live session. Pane focus itself is the
// other input and is derived inside the host session, not here.
import DanTermProtocol
import Foundation
import Testing
@testable import DanTerm

@MainActor
struct AppRuntimeApplicationActivationTests {
    // Intent: a runtime built for an inactive launch says so in the model and on every
    //   session it asks the backend to create.
    // Why it exists: `isAppActive` defaults to true, and a pane created before the first
    //   activation callback would otherwise tell a mode-1004 child its terminal is
    //   focused -- exactly the background `tab new --cmd` pane this work is about.
    // Scenario: `danterm` launches detached, so the app never activates, and a launch
    //   command creates a pane. Spec-first -- no incident to cite.
    @Test("an inactive launch seeds the model and every session request")
    func inactiveLaunchSeedsModelAndRequests() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture, applicationActive: false)
        defer { runtime.shutdown() }

        #expect(runtime.model.isAppActive == false)

        runtime.perform(.createSession(
            sessionId: SessionId(rawValue: UUID()),
            paneId: PaneId(rawValue: UUID()),
            cwd: nil,
            command: nil,
            launchCommand: nil
        ))

        let request = try #require(fixture.sessionRequests.first)
        #expect(request.applicationActive == false)
        #expect(
            fixture.session.applicationActiveValues.isEmpty,
            "the launch state belongs on the request, not a push after mount"
        )
    }

    // Intent: an activation change reaches every live session.
    // Why it exists: the host session holds application activation as a retained input,
    //   so a session that misses the change keeps deriving focus from a stale value for
    //   the rest of the pane's life.
    // Scenario: the user switches away from DanTerm and back while two panes are open.
    //   Spec-first -- no incident to cite.
    @Test("activation changes reach every live session")
    func activationChangesReachEverySession() throws {
        let second = RecordingTerminalSession()
        let fixture = RecordingAppRuntimePorts()
        fixture.queuedSessions = [fixture.session, second]
        let runtime = makeCommandTestRuntime(fixture)
        defer { runtime.shutdown() }
        let groupId = try #require(runtime.model.groups.first?.id)

        runtime.send(.createTab(inGroupId: groupId, position: .atGroupEnd, launch: nil, background: false))
        runtime.send(.createTab(inGroupId: groupId, position: .atGroupEnd, launch: nil, background: false))
        #expect(runtime.paneHosts.count == 2)

        runtime.send(.appResignedActive)
        runtime.send(.appBecameActive)

        #expect(fixture.session.applicationActiveValues == [false, true])
        #expect(second.applicationActiveValues == [false, true])
    }
}
