// Pins the runtime's one message-send entry point: every route a Msg can take into
// the runtime -- a direct send, or a fact a view reported through the outbox --
// passes through `send(_:)`. The UI suite substitutes that method to observe what a
// view reported, so a second, private route would make a whole class of reports
// invisible to it.
import Cocoa
import Testing
@testable import DanTerm

@Suite struct AppRuntimeSendEntryPointTests {
    // Intent: an outbox report reaches the same entry point a direct send does.
    // Why it exists: the outbox used to dispatch through a private method, so a
    // subclass observing `send(_:)` saw direct sends and missed every reported fact.
    // Scenario: a view reports a fact with no send frame open, and the scheduled
    // drain delivers it.
    @Test("a fact reported through the outbox arrives at the send entry point")
    @MainActor
    func outboxReportsReachSend() async throws {
        let runtime = makeObservingRuntime()
        defer { runtime.shutdown() }

        runtime.outbox.report([.appBecameActive])
        // The outbox wakes a frameless report on the next main-queue turn, so the
        // test yields to that turn rather than waiting on a duration.
        await Task.yield()
        await MainActor.run {}

        #expect(runtime.observedMessages.isEmpty == false)
    }
}

/// Substitutes the runtime's send entry point the way the UI suite does, so this
/// suite proves the substitution point catches every route rather than describing it.
@MainActor
private final class ObservingAppRuntime: AppRuntime {
    var observedMessages: [Msg] = []

    override func send(_ msg: Msg) {
        observedMessages.append(msg)
    }
}

@MainActor
private func makeObservingRuntime() -> ObservingAppRuntime {
    let instance = TemporaryInstancePaths()
    return ObservingAppRuntime(
        ports: .live(terminalBackend: SwiftTerminalBackend()),
        dialogSurfaces: RecordingDialogSurfaces().value,
        instancePaths: instance.paths,
        configStore: DanTermConfigStore(url: instance.absentConfigURL),
        startsApplicationServices: false,
        applicationActive: true
    )
}
