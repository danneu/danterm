/// UI tests for TodoInputView focus-acquisition callbacks.

import Cocoa

private final class TodoInputFocusSinkView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

func todoInputViewTests() {
    print("TodoInputView")

    uiTest("programmatic focus does not fire mouse-acquire callback") {
        let host = makeTodoInputHost()
        defer { host.window.close() }

        var callbackCount = 0
        host.input.onTextViewMouseDownAcquireFocus = {
            callbackCount += 1
        }

        try uiExpect(host.window.makeFirstResponder(host.input.textView), "text view should accept first responder")
        try uiExpect(callbackCount == 0, "programmatic focus should not fire callback")
    }

    uiTest("mouse-down on unfocused text view fires mouse-acquire callback once") {
        let host = makeTodoInputHost()
        defer { host.window.close() }

        var callbackCount = 0
        host.input.onTextViewMouseDownAcquireFocus = {
            callbackCount += 1
        }

        try uiExpect(host.window.makeFirstResponder(host.focusSink), "focus sink should accept first responder")
        try clickTextView(host.input.textView, in: host.window)

        try uiExpect(host.window.firstResponder === host.input.textView, "text view should become first responder")
        try uiExpect(callbackCount == 1, "mouse-acquired focus should fire callback exactly once")
    }

    uiTest("mouse-down on already focused text view does not fire mouse-acquire callback") {
        let host = makeTodoInputHost()
        defer { host.window.close() }

        var callbackCount = 0
        host.input.onTextViewMouseDownAcquireFocus = {
            callbackCount += 1
        }

        try uiExpect(host.window.makeFirstResponder(host.input.textView), "text view should accept first responder")
        try clickTextView(host.input.textView, in: host.window)

        try uiExpect(callbackCount == 0, "already-focused mouse-down should not fire callback")
    }
}

/// Build a minimal window-backed TodoInputView so first-responder transitions work.
private func makeTodoInputHost() -> (window: NSWindow, input: TodoInputView, focusSink: TodoInputFocusSinkView) {
    let size = NSSize(width: 360, height: 180)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    let container = NSView(frame: NSRect(origin: .zero, size: size))
    window.contentView = container

    let focusSink = TodoInputFocusSinkView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    let input = TodoInputView()
    container.addSubview(focusSink)
    container.addSubview(input)

    NSLayoutConstraint.activate([
        input.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
        input.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
        input.widthAnchor.constraint(equalToConstant: 260),
        input.heightAnchor.constraint(equalToConstant: TodoInputView.inputHeight),
    ])
    container.layoutSubtreeIfNeeded()
    input.layoutSubtreeIfNeeded()
    window.makeKeyAndOrderFront(nil)

    return (window, input, focusSink)
}

/// Dispatch a click directly to the text view with a queued mouse-up event.
private func clickTextView(_ textView: NSTextView, in window: NSWindow) throws {
    NSApp.postEvent(try mouseEvent(.leftMouseUp, for: textView, in: window, eventNumber: 2), atStart: false)
    textView.mouseDown(with: try mouseEvent(.leftMouseDown, for: textView, in: window, eventNumber: 1))
}

/// Create a mouse event at a visible point near the view origin.
private func mouseEvent(_ type: NSEvent.EventType, for view: NSView, in window: NSWindow, eventNumber: Int) throws -> NSEvent {
    let localPoint = NSPoint(
        x: min(max(view.bounds.minX + 8, view.bounds.minX), view.bounds.maxX),
        y: min(max(view.bounds.minY + 8, view.bounds.minY), view.bounds.maxY)
    )
    let windowPoint = view.convert(localPoint, to: nil)
    guard let event = NSEvent.mouseEvent(
        with: type,
        location: windowPoint,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: eventNumber,
        clickCount: 1,
        pressure: 1.0
    ) else {
        throw UITestFailure(message: "could not synthesize mouse event")
    }
    return event
}
