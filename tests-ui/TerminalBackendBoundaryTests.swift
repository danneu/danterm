// UI-harness coverage for the main-actor callback gate shared by terminal adapters.
import Cocoa

@MainActor
func terminalBackendBoundaryTests() {
    print("TerminalBackendBoundary")

    uiTest("callback gate delivers events and session state while active") {
        let gate = TerminalSessionCallbackGate()
        let observer = RecordingSessionStateObserver()
        var events: [TerminalSessionEvent] = []
        gate.onEvent = { events.append($0) }
        gate.stateObserver = observer
        let state = TerminalSessionState(
            scrollbarEnabled: false,
            cellHeight: 18,
            scrollPosition: .init(total: 100, offset: 20, length: 30),
            background: NSColor.black.cgColor
        )

        gate.emit(.report(.title("vim")))
        gate.emit(state)

        try uiExpect(events == [.report(.title("vim"))], "active event was not delivered")
        try uiExpect(observer.states == [state], "active session state was not delivered")
    }

    uiTest("callback gate drops both channels after teardown") {
        // Intent: terminal product events and view-local scrollbar state stop at
        //   the same teardown boundary.
        // Why it exists: a C callback racing final session teardown must never
        //   message the model or a shorter-lived AppKit scroll wrapper.
        // Scenario: spec-first lifecycle race -- teardown wins, then late callbacks arrive.
        let gate = TerminalSessionCallbackGate()
        let observer = RecordingSessionStateObserver()
        var events: [TerminalSessionEvent] = []
        gate.onEvent = { events.append($0) }
        gate.stateObserver = observer

        gate.tearDown()
        gate.emit(.bell)
        gate.emit(TerminalSessionState(
            scrollbarEnabled: true, cellHeight: 16, scrollPosition: nil,
            background: NSColor.black.cgColor))

        try uiExpect(events.isEmpty, "event escaped after teardown: \(events)")
        try uiExpect(observer.states.isEmpty, "session state escaped after teardown: \(observer.states)")
    }
}

private final class RecordingSessionStateObserver: TerminalSessionStateObserver {
    var states: [TerminalSessionState] = []

    func terminalSessionStateDidChange(_ state: TerminalSessionState) {
        states.append(state)
    }
}
