// UI-harness coverage for native pointer, wheel, copy, and scrollbar routing in the Swift pane.
import Cocoa
import CoreGraphics

@MainActor private var retainedSwiftPaneWindows: [NSWindow] = []

@MainActor
func swiftTerminalSessionViewTests() {
    print("SwiftTerminalSessionView")

    uiTest("mounted pane forwards fractional wheel metadata once") {
        // Intent: the Swift pane converts a line wheel event into one owner-side row intent
        //   and terminates responder-chain handling at the pane.
        // Why it exists: the enclosing terminal scroll view forwards wheel events to the
        //   pane, so calling super would bounce the same event back through the scroll view.
        // Scenario: a user wheels upward by two line units over a mounted Swift pane.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let enclosingScrollView = WheelBounceSentinelScrollView()
        pane.nextResponder = enclosingScrollView
        let event = try makeScrollWheelEvent(
            units: .line,
            deltaY: 2,
            location: .init(x: 17, y: 125),
            modifiers: [.shift, .control],
            phase: .began
        )

        pane.scrollWheel(with: event)

        try uiExpect(controller.wheelEvents == [
            .init(
                rowDelta: -6,
                column: 2,
                row: 0,
                modifiers: [.shift, .control],
                phase: .began
            ),
        ], "unexpected wheel event: \(controller.wheelEvents)")
        try uiExpect(
            enclosingScrollView.scrollWheelCalls == 0,
            "wheel event bounced to the enclosing scroll view"
        )
    }

    uiTest("pointer callbacks normalize cells buttons modifiers and click counts") {
        // Intent: every native left-button transition becomes one platform-neutral pointer event.
        // Why it exists: view-side routing or point-space forwarding would bypass owner policy.
        // Scenario: a Shift-double-click drag crosses cells and releases beyond the viewport.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)

        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            location: .init(x: 17, y: 125),
            modifiers: [.shift],
            clickCount: 2
        ))
        pane.mouseDragged(with: try makeMouseEvent(
            type: .leftMouseDragged,
            location: .init(x: 31, y: 111),
            modifiers: [.shift]
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            location: .init(x: 200, y: -40),
            modifiers: [.shift]
        ))

        try uiExpect(controller.pointerEvents == [
            .down(.left, column: 2, row: 2, modifiers: [.shift], clickCount: 2),
            .move(column: 3, row: 3, modifiers: [.shift]),
            .up(.left, column: 9, row: 9, modifiers: [.shift]),
        ], "pointer normalization diverged: \(controller.pointerEvents)")
    }

    uiTest("wheel direct and momentum phases reach the owner unchanged") {
        // Intent: precise fractional motion and its direct/momentum lifecycle reach the owner.
        // Why it exists: route latching and remainder ownership both depend on these boundaries.
        // Scenario: a trackpad gesture ends its direct phase and continues with momentum.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)

        for phase in [NSEvent.Phase.began, .changed, .ended] {
            pane.scrollWheel(with: try makeScrollWheelEvent(
                units: .pixel,
                deltaY: 4,
                location: .init(x: 9, y: 143),
                phase: phase
            ))
        }
        for phase in [NSEvent.Phase.began, .changed, .ended] {
            pane.scrollWheel(with: try makeScrollWheelEvent(
                units: .pixel,
                deltaY: 4,
                location: .init(x: 9, y: 143),
                momentumPhase: phase
            ))
        }

        try uiExpect(controller.wheelEvents.map(\.phase) == [
            .began, .changed, .ended, .momentumBegan, .momentumChanged, .momentumEnded,
        ], "wheel phase normalization diverged: \(controller.wheelEvents)")
        try uiExpect(controller.wheelEvents.allSatisfy { $0.rowDelta == -0.25 },
                     "precise wheel motion was quantized in the view")
    }

    uiTest("automatic menus stay suppressed and owner menu requests arrive after right up") {
        // Intent: only the serialized owner can authorize a terminal-surface context menu.
        // Why it exists: AppKit's automatic down-time lookup races child mouse-capture modes.
        // Scenario: an uncaptured right-click opens after up, then a captured click does not reopen.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var menuCells: [TerminalViewportCell] = []
        pane.paneMenuHandler = { menuCells.append($0) }
        let down = try makeMouseEvent(type: .rightMouseDown, location: .init(x: 17, y: 125))
        let up = try makeMouseEvent(type: .rightMouseUp, location: .init(x: 17, y: 125))

        try uiExpect(pane.menu(for: down) == nil, "AppKit menu lookup was not suppressed")
        pane.rightMouseDown(with: down)
        try uiExpect(menuCells.isEmpty, "pane menu opened before button-up")
        pane.rightMouseUp(with: up)
        try uiExpect(menuCells == [.init(column: 2, row: 2)], "pane menu did not follow owner up")

        controller.allowsPaneMenu = false
        pane.rightMouseDown(with: down)
        pane.rightMouseUp(with: up)
        try uiExpect(menuCells.count == 1, "captured right-click reopened the dismissed menu")
    }

    uiTest("control click uses the owner right-button lifecycle") {
        // Intent: macOS Control-click is normalized as a right-button gesture before owner policy.
        // Why it exists: AppKit otherwise asks for a menu before delivering the mouse lifecycle.
        // Scenario: a shell Control-click opens the pane menu only after its synthesized right up.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var menuCells: [TerminalViewportCell] = []
        pane.paneMenuHandler = { menuCells.append($0) }
        let down = try makeMouseEvent(
            type: .leftMouseDown,
            location: .init(x: 9, y: 143),
            modifiers: [.control]
        )
        let up = try makeMouseEvent(
            type: .leftMouseUp,
            location: .init(x: 9, y: 143),
            modifiers: [.control]
        )

        try uiExpect(pane.menu(for: down) == nil, "control-click menu lookup was not suppressed")
        pane.mouseDown(with: down)
        pane.mouseUp(with: up)

        try uiExpect(controller.pointerEvents == [
            .down(.right, column: 1, row: 1, modifiers: [.control], clickCount: 1),
            .up(.right, column: 1, row: 1, modifiers: [.control]),
        ], "control-click escaped the right-button owner lifecycle")
        try uiExpect(menuCells == [.init(column: 1, row: 1)], "control-click menu was not deferred")
    }

    uiTest("explicit copy fences selection and hasSelection stays cache-only") {
        // Intent: Copy fences pending selection work while menu enablement reads only cached state.
        // Why it exists: asynchronous drag consumption must not put stale text on the pasteboard.
        // Scenario: a selection ends immediately before the user invokes Copy.
        let controller = TerminalPaneSessionController()
        controller.selectedTextOnFence = "alpha"
        let pane = makeMountedPane(controller: controller)
        let pasteboard = NSPasteboard(name: .init("danterm.swift-selection-test"))
        pasteboard.clearContents()
        pane.selectionPasteboard = pasteboard

        try uiExpect(pane.hasSelection == false, "selection cache unexpectedly fenced the owner")
        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            location: .init(x: 1, y: 159)
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            location: .init(x: 17, y: 159)
        ))
        pane.copySelection()

        try uiExpect(controller.synchronizedSelectionReads == 1, "copy did not fence the owner")
        try uiExpect(pasteboard.string(forType: .string) == "alpha", "copy missed finalized text")
        try uiExpect(pane.hasSelection, "cached selection did not refresh after fenced copy")
    }

    uiTest("tracking area delivers mouse moves to the normalized adapter") {
        // Intent: the pane continuously forwards normalized hover motion without a mode mirror.
        // Why it exists: any-motion capture can begin from child output between native callbacks.
        // Scenario: an Option-modified pointer move lands over a visible terminal cell.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        pane.updateTrackingAreas()

        try uiExpect(pane.trackingAreas.contains { $0.options.contains(.mouseMoved) },
                     "pane installed no mouse-move tracking area")
        pane.mouseMoved(with: try makeMouseEvent(
            type: .mouseMoved,
            location: .init(x: 17, y: 125),
            modifiers: [.option]
        ))
        try uiExpect(controller.pointerEvents == [
            .move(column: 2, row: 2, modifiers: [.alt]),
        ], "mouse move did not reach the owner adapter")
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
    deltaY: Int32,
    location: CGPoint = .zero,
    modifiers: NSEvent.ModifierFlags = [],
    phase: NSEvent.Phase = [],
    momentumPhase: NSEvent.Phase = []
) throws -> NSEvent {
    guard let cgEvent = CGEvent(
        scrollWheelEvent2Source: nil,
        units: units,
        wheelCount: 1,
        wheel1: deltaY,
        wheel2: 0,
        wheel3: 0
    ) else {
        throw UITestFailure(message: "could not synthesize a wheel event")
    }
    cgEvent.location = location
    cgEvent.flags = cgEventFlags(modifiers)
    cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhaseCode(phase))
    cgEvent.setIntegerValueField(
        .scrollWheelEventMomentumPhase,
        value: momentumPhaseCode(momentumPhase)
    )
    guard let event = NSEvent(cgEvent: cgEvent) else {
        throw UITestFailure(message: "could not bridge a wheel event")
    }
    return event
}

private func makeMouseEvent(
    type: NSEvent.EventType,
    location: NSPoint,
    modifiers: NSEvent.ModifierFlags = [],
    clickCount: Int = 1
) throws -> NSEvent {
    guard let event = NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: modifiers,
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        eventNumber: 1,
        clickCount: clickCount,
        pressure: 1
    ) else {
        throw UITestFailure(message: "could not synthesize \(type)")
    }
    return event
}

private func cgEventFlags(_ modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
    var flags: CGEventFlags = []
    if modifiers.contains(.shift) { flags.insert(.maskShift) }
    if modifiers.contains(.control) { flags.insert(.maskControl) }
    if modifiers.contains(.option) { flags.insert(.maskAlternate) }
    return flags
}

private func scrollPhaseCode(_ phase: NSEvent.Phase) -> Int64 {
    if phase.contains(.began) { return 1 }
    if phase.contains(.changed) { return 2 }
    if phase.contains(.ended) || phase.contains(.cancelled) { return 4 }
    return 0
}

private func momentumPhaseCode(_ phase: NSEvent.Phase) -> Int64 {
    if phase.contains(.began) { return 1 }
    if phase.contains(.changed) { return 2 }
    if phase.contains(.ended) || phase.contains(.cancelled) { return 3 }
    return 0
}

@discardableResult
@MainActor
private func makeMountedPane(controller: TerminalPaneSessionController) -> SwiftTerminalSessionView {
    let pane = SwiftTerminalSessionView(controller: controller)
    pane.frame = NSRect(x: 0, y: 0, width: 80, height: 160)
    mountInTestWindow(pane, frame: pane.frame)
    return pane
}

@MainActor
private func mountInTestWindow(_ view: NSView, frame: NSRect) {
    let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
    window.contentView = view
    retainedSwiftPaneWindows.append(window)
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
