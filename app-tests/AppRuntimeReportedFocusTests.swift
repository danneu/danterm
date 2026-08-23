// Headless coverage that a runtime-created pane receives an explicit initial
// reported-focus value from the reconcile sweep.
import DanTermProtocol
import Foundation
import Testing
@testable import DanTerm

@MainActor
struct AppRuntimeReportedFocusTests {
    // Intent: a pane created through the runtime's message entry receives one
    //   explicit false focus write before that send returns.
    // Why it exists: this headless half proves the reconcile pass reached the
    //   newborn pane. With no window the claimant is unclaimed, so PO1, not this
    //   case, proves the activation arithmetic.
    // Scenario: an inactive detached launch creates its first tab. Spec-first --
    //   no incident to cite.
    @Test("an inactive runtime-created pane receives one initial false focus write")
    func inactiveCreatedPaneReceivesInitialFalseFocus() throws {
        let fixture = RecordingAppRuntimePorts()
        let runtime = makeCommandTestRuntime(fixture, applicationActive: false)
        defer { runtime.shutdown() }
        let groupId = try #require(runtime.model.groups.first?.id)

        runtime.send(.createTab(
            inGroupId: groupId,
            position: .atGroupEnd,
            launch: nil,
            background: false
        ))

        #expect(fixture.session.focusedValues == [false])
    }
}
