// UI-harness coverage for wheel consumption and scrollbar routing in the Swift pane.
import Cocoa
import CoreGraphics

@MainActor
func swiftTerminalSessionViewTests() {
    print("SwiftTerminalSessionView")

    uiTest("mounted pane consumes one wheel event and forwards normalized rows once") {
        // Intent: the Swift pane converts a line wheel event into one owner-side row intent
        //   and terminates responder-chain handling at the pane.
        // Why it exists: the enclosing terminal scroll view forwards wheel events to the
        //   pane, so calling super would bounce the same event back through the scroll view.
        // Scenario: a user wheels upward by two line units over a mounted Swift pane.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller)
        let enclosingScrollView = WheelBounceSentinelScrollView()
        let documentView = NSView()
        enclosingScrollView.documentView = documentView
        documentView.addSubview(pane)
        let event = try makeScrollWheelEvent(units: .line, deltaY: 2)

        pane.scrollWheel(with: event)

        try uiExpect(controller.wheelRows == [-6], "unexpected wheel rows: \(controller.wheelRows)")
        try uiExpect(
            enclosingScrollView.scrollWheelCalls == 0,
            "wheel event bounced to the enclosing scroll view"
        )
    }

    uiTest("pane maps viewport state and scrollbar commands through the controller") {
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller)
        let observer = SwiftPaneStateObserver()
        pane.stateObserver = observer

        try uiExpect(
            pane.state.scrollPosition == .init(total: 30, offset: 10, length: 20),
            "initial viewport projection was not mapped"
        )
        pane.scroll(toRow: 7)

        let changed = TerminalPaneViewportState(
            isScrollbarEnabled: false,
            projection: .init(totalRows: 12, topRow: 0, windowRows: 12, isFollowing: true)
        )
        controller.emitViewportState(changed)
        controller.emitViewportState(changed)

        try uiExpect(controller.scrolledTopRows == [7], "scrollbar row was not forwarded")
        try uiExpect(observer.states.count == 1, "duplicate state emission: \(observer.states)")
        try uiExpect(observer.states.first?.scrollbarEnabled == false, "alt state stayed enabled")
        try uiExpect(
            observer.states.first?.scrollPosition == .init(total: 12, offset: 0, length: 12),
            "changed viewport projection was not mapped"
        )
    }
}

private final class WheelBounceSentinelScrollView: NSScrollView {
    private(set) var scrollWheelCalls = 0

    override func scrollWheel(with event: NSEvent) {
        scrollWheelCalls += 1
    }
}

private final class SwiftPaneStateObserver: TerminalSessionStateObserver {
    var states: [TerminalSessionState] = []

    func terminalSessionStateDidChange(_ state: TerminalSessionState) {
        states.append(state)
    }
}

private func makeScrollWheelEvent(
    units: CGScrollEventUnit,
    deltaY: Int32
) throws -> NSEvent {
    guard let cgEvent = CGEvent(
        scrollWheelEvent2Source: nil,
        units: units,
        wheelCount: 1,
        wheel1: deltaY,
        wheel2: 0,
        wheel3: 0
    ), let event = NSEvent(cgEvent: cgEvent) else {
        throw UITestFailure(message: "could not synthesize a wheel event")
    }
    return event
}
