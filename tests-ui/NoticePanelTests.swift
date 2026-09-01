// UI-harness coverage for notice-panel buttons and reserved key equivalents.
import Cocoa
import ChipArtwork
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

/// Registers notice-panel message-routing coverage in the standalone UI harness.
@MainActor
func noticePanelTests() async {
    print("NoticePanel")

    // The assertion the headless app-test gave up when the reconcile sweep stopped
    // building its own panel: the real panel renders a projection's words.
    await uiTest("configure renders the projection title and message into the labels") {
        let runtime = makeUITestRuntime()
        let panel = NoticePanel(runtime: runtime)
        defer { panel.orderOut(nil) }
        let projection = makeNoticeProjection()

        panel.configure(projection)

        try uiExpect(panel.headingLabel.stringValue == projection.title.text,
                     "heading was \(panel.headingLabel.stringValue)")
        try uiExpect(panel.bodyLabel.stringValue == projection.message,
                     "body was \(panel.bodyLabel.stringValue)")
    }

    await uiTest("message notice has one OK button that sends dismiss") {
        let runtime = makeUITestRuntime()
        let panel = NoticePanel(runtime: runtime)
        defer { panel.orderOut(nil) }
        let projection = makeNoticeProjection()
        panel.configure(projection)

        let buttons = panel.actionRow.buttonsInVisualOrder
        try uiExpect(buttons.map(\.title) == ["OK"], "expected one OK button")
        buttons[0].performClick(nil)

        try uiExpect(runtime.sentMessages.count == 1, "OK should send exactly one answer")
        if case .noticeAnswered(projection.id, .dismiss) = runtime.sentMessages[0] {} else {
            throw UITestFailure(message: "OK sent \(runtime.sentMessages[0])")
        }
    }

    await uiTest("a resize on reconfigure holds the title bar still") {
        // Intent: a refresh that grows or shrinks the notice keeps its top edge.
        // Why it exists: an AppKit resize anchors the bottom-left corner, so the
        //   title bar would walk up and down under the pointer on every refresh.
        //   The confirmation panel had this covered and the notice panel did not,
        //   and the two now share one resize.
        // Scenario: spec-first -- a one-line message, then a much taller one,
        //   then back. The lines are broken by hand so the case moves the height
        //   and not the width.
        let runtime = makeUITestRuntime()
        let panel = NoticePanel(runtime: runtime)
        defer { panel.orderOut(nil) }
        panel.configure(makeNoticeProjection())
        panel.center(on: nil)
        let top = panel.frame.maxY

        let tall = (1...8).map { "Detail line \($0)." }.joined(separator: "\n")
        for message in [tall, "The selected file is invalid.", tall] {
            panel.configure(makeNoticeProjection(message: message))
            try uiExpect(abs(panel.frame.maxY - top) < 0.5,
                         "the title bar moved to \(panel.frame.maxY) from \(top)")
        }
    }

    await uiTest("recovery buttons and Return and Escape send their projected answers") {
        let runtime = makeUITestRuntime()
        let panel = NoticePanel(runtime: runtime)
        defer { panel.orderOut(nil) }
        let projection = makeRecoveryNoticeProjection()
        panel.configure(projection)

        let buttons = panel.actionRow.buttonsInVisualOrder
        try uiExpect(buttons.map(\.title) == ["Start Fresh", "Restore"],
                     "expected alternate then default, got \(buttons.map(\.title))")
        buttons[0].performClick(nil)
        buttons[1].performClick(nil)
        panel.sendEvent(try noticeKeyEvent(in: panel, characters: "\r", keyCode: 36))
        panel.sendEvent(try noticeKeyEvent(in: panel, characters: "\u{1b}", keyCode: 53))

        let expected: [NoticeAnswer] = [.startFresh, .restore, .restore, .startFresh]
        try uiExpect(runtime.sentMessages.count == expected.count,
                     "expected one message per action, got \(runtime.sentMessages)")
        for (message, answer) in zip(runtime.sentMessages, expected) {
            if case .noticeAnswered(projection.id, answer) = message { continue }
            throw UITestFailure(message: "expected \(answer), got \(message)")
        }
    }
}

private func makeNoticeProjection(
    message: String = "The selected file is invalid."
) -> NoticeProjection {
    NoticeProjection(
        id: NoticeId(),
        title: "Import Failed",
        message: message,
        primary: NoticeChoice(title: "OK", answer: .dismiss),
        secondary: nil
    )
}

private func makeRecoveryNoticeProjection() -> NoticeProjection {
    NoticeProjection(
        id: NoticeId(),
        title: "Restore Previous Session?",
        message: "1 tab, 1 pane.",
        primary: NoticeChoice(title: "Restore", answer: .restore),
        secondary: NoticeChoice(title: "Start Fresh", answer: .startFresh)
    )
}

@MainActor
private func noticeKeyEvent(in window: NSWindow, characters: String, keyCode: UInt16) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        throw UITestFailure(message: "could not create notice-panel key event")
    }
    return event
}
