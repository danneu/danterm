// UI-harness coverage for notice-panel buttons and reserved key equivalents.
import Cocoa

/// Registers notice-panel message-routing coverage in the standalone UI harness.
@MainActor
func noticePanelTests() {
    print("NoticePanel")

    // The assertion the headless app-test gave up when the reconcile sweep stopped
    // building its own panel: the real panel renders a projection's words.
    uiTest("configure renders the projection title and message into the labels") {
        let runtime = AppRuntime()
        let panel = NoticePanel(runtime: runtime)
        defer { panel.orderOut(nil) }
        let projection = makeNoticeProjection()

        panel.configure(projection)

        try uiExpect(panel.headingLabel.stringValue == projection.title.text,
                     "heading was \(panel.headingLabel.stringValue)")
        try uiExpect(panel.bodyLabel.stringValue == projection.message,
                     "body was \(panel.bodyLabel.stringValue)")
    }

    uiTest("message notice has one OK button that sends dismiss") {
        let runtime = AppRuntime()
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

    uiTest("recovery buttons and Return and Escape send their projected answers") {
        let runtime = AppRuntime()
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

private func makeNoticeProjection() -> NoticeProjection {
    NoticeProjection(
        id: NoticeId(),
        title: "Import Failed",
        message: "The selected file is invalid.",
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
