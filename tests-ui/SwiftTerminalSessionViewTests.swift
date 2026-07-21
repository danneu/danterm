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

    uiTest("composition commits text before terminal key encoding") {
        // Intent: marked-text composition commits through sendText even while Kitty mode is active.
        // Why it exists: terminal key encoding must never reinterpret native Option/dead-key text.
        // Scenario: AppKit reports the marked and committed phases of Option+e, e as acute e.
        let controller = TerminalPaneSessionController()
        controller.inputModes.kittyKeyboardFlags = 1
        let pane = SwiftTerminalSessionView(controller: controller)

        let notFound = NSRange(location: NSNotFound, length: 0)
        pane.setMarkedText(
            "\u{00B4}",
            selectedRange: .init(location: 1, length: 0),
            replacementRange: notFound
        )
        pane.keyDown(with: try makeKeyEvent(keyCode: 14, modifiers: [.option]))
        pane.insertText("\u{00E9}", replacementRange: notFound)

        try uiExpect(controller.textInputs == ["\u{00E9}"], "dead-key composition did not use text path")
        try uiExpect(controller.inputBytes.isEmpty, "composition leaked into terminal key encoding")
    }

    uiTest("control punctuation and function keys normalize into core bytes") {
        // Intent: layout-derived Control punctuation and function keys retain semantic identity.
        // Why it exists: AppKit mutates Control characters and represents function keys as PUA text.
        // Scenario: a user enters the ASCII control-punctuation set, then F3 in Kitty mode.
        let controller = TerminalPaneSessionController()
        let pane = SwiftTerminalSessionView(controller: controller)
        let cases: [(UInt16, NSEvent.ModifierFlags, [UInt8])] = [
            (49, [.control], [0x00]),
            (33, [.control], [0x1B]),
            (42, [.control], [0x1C]),
            (30, [.control], [0x1D]),
            (22, [.control, .shift], [0x1E]),
            (27, [.control, .shift], [0x1F]),
        ]
        for (keyCode, modifiers, expected) in cases {
            pane.keyDown(with: try makeKeyEvent(keyCode: keyCode, modifiers: modifiers))
            try uiExpect(controller.inputBytes.last == expected,
                         "keyCode \(keyCode) produced \(String(describing: controller.inputBytes.last))")
        }
        pane.keyDown(with: try makeKeyEvent(keyCode: 48, modifiers: [.shift]))
        try uiExpect(controller.inputBytes.last == Array("\u{1B}[Z".utf8),
                     "Shift-Tab diverged from shared input vocabulary")

        controller.inputModes.kittyKeyboardFlags = 1
        pane.keyDown(with: try makeKeyEvent(keyCode: 99, modifiers: []))
        try uiExpect(controller.inputBytes.last == Array("\u{1B}[13~".utf8),
                     "F3 did not use Kitty encoding: \(String(describing: controller.inputBytes.last))")
    }

    uiTest("numeric keypad keys retain their semantic identity") {
        // Intent: keypad text is encoded as a keypad key instead of ordinary committed text.
        // Why it exists: application-keypad mode changes bytes even though AppKit supplies a digit.
        // Scenario: the child enables DECKPAM and the user presses keypad zero.
        let controller = TerminalPaneSessionController()
        controller.inputModes.applicationKeypad = true
        let pane = SwiftTerminalSessionView(controller: controller)

        pane.keyDown(with: try makeKeyEvent(
            keyCode: 82,
            modifiers: [.numericPad],
            characters: "0"
        ))

        try uiExpect(controller.textInputs.isEmpty, "keypad zero escaped through the text path")
        try uiExpect(controller.inputBytes == [Array("\u{1B}Op".utf8)],
                     "keypad zero lost application-keypad semantics: \(controller.inputBytes)")
    }

    uiTest("menu and context paste share the owner-side safe-paste path") {
        // Intent: both AppKit paste entry points submit raw clipboard text to owner-side policy.
        // Why it exists: bypassing the owner could admit escape injection or skip bracket markers.
        // Scenario: Edit > Paste and the pane menu paste text containing an embedded marker.
        let controller = TerminalPaneSessionController()
        controller.inputModes.bracketedPaste = true
        let pane = SwiftTerminalSessionView(controller: controller)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("one\u{1B}[201~\ntwo", forType: .string)
        let expected = Array("\u{1B}[200~one[201~\ntwo\u{1B}[201~".utf8)

        pane.paste(nil)
        pane.pasteClipboard()

        try uiExpect(controller.inputBytes == [expected, expected],
                     "paste entry points diverged: \(controller.inputBytes)")
    }

    uiTest("runtime and responder focus signals are deduplicated") {
        // Intent: logical pane focus and first-responder callbacks share one transition funnel.
        // Why it exists: AppKit and reconcile commonly report the same transition back-to-back.
        // Scenario: a pane gains and loses focus through both signal sources with mode 1004 active.
        let controller = TerminalPaneSessionController()
        controller.inputModes.focusReporting = true
        let pane = SwiftTerminalSessionView(controller: controller)

        pane.setFocused(true)
        _ = pane.becomeFirstResponder()
        pane.setFocused(true)
        _ = pane.resignFirstResponder()
        pane.setFocused(false)

        try uiExpect(controller.focusChanges == [true, false],
                     "focus funnel emitted duplicates: \(controller.focusChanges)")
        try uiExpect(controller.inputBytes == [Array("\u{1B}[I".utf8), Array("\u{1B}[O".utf8)],
                     "focus reports were not owner-gated: \(controller.inputBytes)")
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

private func makeKeyEvent(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    characters: String = ""
) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        throw UITestFailure(message: "could not synthesize keyCode \(keyCode)")
    }
    return event
}
