// UI-harness coverage for native pointer, wheel, copy, and scrollbar routing in the Swift pane.
import Cocoa
import CoreGraphics

@MainActor private var retainedSwiftPaneWindows: [NSWindow] = []

@MainActor
func swiftTerminalSessionViewTests() {
    print("SwiftTerminalSessionView")

    uiTest("partial terminal damage includes a bounded one-row glyph halo") {
        try uiExpect(
            terminalDamageRowsWithGlyphHalo([0], rowCount: 4) == [0, 1],
            "top-row damage did not include the following row"
        )
        try uiExpect(
            terminalDamageRowsWithGlyphHalo([2], rowCount: 4) == [1, 2, 3],
            "middle-row damage did not include both neighboring rows"
        )
        try uiExpect(
            terminalDamageRowsWithGlyphHalo([3], rowCount: 4) == [2, 3],
            "bottom-row damage escaped the viewport"
        )
        try uiExpect(
            terminalDamageRowsWithGlyphHalo([], rowCount: 4).isEmpty,
            "empty damage unexpectedly invalidated rows"
        )
    }

    uiTest("semantic notifications and progress cross the AppKit adapter") {
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var events: [TerminalSessionEvent] = []
        pane.onEvent = { events.append($0) }

        controller.emitSemanticEvents([
            .desktopNotification(title: "Build", body: "Done"),
            .progress(.set(percent: 42)),
            .progress(nil),
        ])

        try uiExpect(events == [
            .desktopNotification(title: "Build", body: "Done"),
            .progress(.set(percent: 42)),
            .progress(nil),
        ], "semantic adapter diverged: \(events)")
    }

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
        try uiExpect(controller.linkInteractionCancellations == 1,
                     "out-of-bounds release did not cancel link interaction first")
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

    uiTest("Edit > Copy routes through the responder chain and validates on cached selection") {
        // Intent: the standard `copy(_:)` action copies the selection, and Edit > Copy is
        //   enabled only while a selection exists, without disturbing Paste.
        // Why it exists: the Swift engine declines Command keys in `keyDown`, so Cmd-C only
        //   works if the pane owns `copy(_:)` on the responder chain; over-broad validation
        //   would silently disable unrelated Edit items such as Paste.
        // Scenario: a user drag-selects output, presses Cmd-C, then clicks to clear it.
        let controller = TerminalPaneSessionController()
        controller.selectedTextOnFence = "beta"
        let pane = makeMountedPane(controller: controller)
        let pasteboard = NSPasteboard(name: .init("danterm.swift-menu-copy-test"))
        pasteboard.clearContents()
        pane.selectionPasteboard = pasteboard
        let copyItem = NSMenuItem(
            title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"
        )
        let pasteItem = NSMenuItem(
            title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"
        )

        try uiExpect(pane.validateMenuItem(copyItem) == false,
                     "Copy was enabled with no selection")
        try uiExpect(pane.validateMenuItem(pasteItem), "Paste was disabled by copy validation")

        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            location: .init(x: 1, y: 159)
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            location: .init(x: 17, y: 159)
        ))
        pane.copy(nil)

        try uiExpect(pasteboard.string(forType: .string) == "beta",
                     "responder-chain copy missed finalized text")
        try uiExpect(pane.validateMenuItem(copyItem), "Copy stayed disabled with a selection")
        try uiExpect(pane.validateMenuItem(pasteItem), "Paste validation tracked the selection")
    }

    uiTest("Edit > Select All routes through the responder chain and validates as enabled") {
        // Intent: the nil-targeted `selectAll(_:)` action reaches the pane through AppKit's
        //   responder-chain lookup, produces a selection the pane reports, and leaves
        //   Edit > Select All validating as enabled.
        // Why it exists: the Swift engine declines Command keys in `keyDown`, so Cmd-A only
        //   works if the pane owns `selectAll(_:)` on the responder chain; dispatching through
        //   the chain (not calling the method directly) is the point -- a direct call would pass
        //   even if the menu item stayed disabled or the action resolved to another responder.
        // Scenario: a user makes the pane first responder and presses Cmd-A.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        guard let window = pane.window else {
            throw UITestFailure(message: "mounted pane had no window")
        }
        // Dispatch from a child first responder whose `nextResponder` is the pane, so the
        // nil-targeted action resolves up the responder chain to the pane rather than being
        // called on it directly. (A key-window-scoped `NSApp.sendAction` can't run headless.)
        let probe = FirstResponderProbeView(frame: .zero)
        pane.addSubview(probe)
        try uiExpect(window.makeFirstResponder(probe), "probe could not become first responder")
        let selectAllItem = NSMenuItem(
            title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"
        )

        try uiExpect(
            probe.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil),
            "responder chain declined the nil-targeted Select All action"
        )

        try uiExpect(controller.selectAllRequests == 1, "Select All did not reach the owner")
        try uiExpect(pane.hasSelection, "pane reported no selection after Select All")
        try uiExpect(pane.validateMenuItem(selectAllItem), "Select All validated as disabled")
    }

    uiTest("Command-modified keys produce no terminal input") {
        // Intent: Cmd-C and Cmd-A are owned by the menu/responder chain and never encoded as
        //   terminal input.
        // Why it exists: a fix that reintroduced a Command branch in `keyDown` would send a
        //   stray byte to the shell whenever such a shortcut fell through -- for Cmd-A, the
        //   `\x01` the line editor uses for start-of-line.
        // Scenario: the user presses Cmd-C then Cmd-A on a mounted pane with no selection.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let before = controller.inputBytes

        pane.keyDown(with: try makeKeyEvent(keyCode: 8, modifiers: [.command], characters: "c"))
        pane.keyDown(with: try makeKeyEvent(keyCode: 0, modifiers: [.command], characters: "a"))

        try uiExpect(controller.inputBytes == before,
                     "Command key leaked terminal input: \(controller.inputBytes)")
    }

    uiTest("OSC 52 writes and empty clears reach the injected pasteboard") {
        // Intent: delivered terminal clipboard effects write only at the AppKit boundary.
        // Why it exists: presentation gating and top-level model routing must not own OSC 52 data.
        // Scenario: a remote program writes text, then clears the general clipboard selection.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        let pasteboard = NSPasteboard(name: .init("danterm.swift-osc52-test"))
        pasteboard.clearContents()
        pane.selectionPasteboard = pasteboard

        controller.emitClipboardWrite("hello")
        try uiExpect(pasteboard.string(forType: .string) == "hello", "OSC 52 write was lost")
        controller.emitClipboardWrite("")
        try uiExpect(pasteboard.string(forType: .string) == "", "empty OSC 52 did not clear")
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
        try uiExpect(pane.trackingAreas.contains { $0.options.contains(.mouseEnteredAndExited) },
                     "pane installed no pointer-entry/exit tracking area")
        pane.mouseMoved(with: try makeMouseEvent(
            type: .mouseMoved,
            location: .init(x: 17, y: 125),
            modifiers: [.option]
        ))
        try uiExpect(controller.pointerEvents == [
            .move(column: 2, row: 2, modifiers: [.alt]),
        ], "mouse move did not reach the owner adapter")
    }

    uiTest("Cmd-click forwards Command and opens only boundary-valid web URLs") {
        // Intent: AppKit forwards Command intent to owner policy, then independently validates
        //   the click-time target before invoking the injected system opener.
        // Why it exists: terminal output must not reach file or custom URL handlers even if
        //   engine validation regresses or a malformed target crosses the owner boundary.
        // Scenario: a user Cmd-clicks links with valid HTTP(S), unsafe, and malformed targets.
        let controller = TerminalPaneSessionController()
        let pane = makeMountedPane(controller: controller)
        var opened: [URL] = []
        pane.linkOpener = { url in
            opened.append(url)
            return true
        }

        let down = try makeMouseEvent(
            type: .leftMouseDown,
            location: .init(x: 17, y: 125),
            modifiers: [.command]
        )
        let up = try makeMouseEvent(
            type: .leftMouseUp,
            location: .init(x: 17, y: 125),
            modifiers: [.command]
        )
        for target in [
            "http://example.com/path",
            "https://example.com/path",
            "HtTpS://example.com/path",
            "file:///etc/hosts",
            "javascript:alert(1)",
            "http:path",
            "http://",
            "http://example.com:0/path",
            "http://example.com:65536/path",
            "http://[/path",
        ] {
            controller.linkForCommandClick = .init(uri: target)
            pane.mouseDown(with: down)
            pane.mouseUp(with: up)
        }

        try uiExpect(
            controller.pointerEvents.first == .down(
                .left,
                column: 2,
                row: 2,
                modifiers: [.command],
                clickCount: 1
            ),
            "Cmd-down lost Command intent"
        )
        try uiExpect(
            controller.pointerEvents.dropFirst().first == .up(
                .left,
                column: 2,
                row: 2,
                modifiers: [.command]
            ),
            "Cmd-up lost Command intent"
        )
        try uiExpect(opened.map(\.absoluteString) == [
            "http://example.com/path",
            "https://example.com/path",
            "HtTpS://example.com/path",
        ], "unsafe or malformed target crossed the opener boundary: \(opened)")
    }

    uiTest("Cmd flags changes replay the stationary pointer and update link chrome") {
        // Intent: pressing and releasing Command without moving refreshes owner hover and native
        //   chrome at the last terminal position.
        // Why it exists: AppKit does not emit mouseMoved merely because modifier flags changed.
        // Scenario: the pointer rests over a web link while the user presses and releases Cmd.
        let controller = TerminalPaneSessionController()
        controller.hoveredLinkForCommandMove = .init(uri: "https://example.com/stationary")
        let pane = makeMountedPane(controller: controller)
        pane.mouseMoved(with: try makeMouseEvent(
            type: .mouseMoved,
            location: .init(x: 17, y: 125)
        ))

        pane.flagsChanged(with: try makeFlagsChangedEvent(keyCode: 55, modifiers: [.command]))

        try uiExpect(controller.pointerEvents.suffix(2) == [
            .move(column: 2, row: 2),
            .move(column: 2, row: 2, modifiers: [.command]),
        ], "Cmd press did not replay the last pointer cell")
        let preview = pane.subviews.compactMap { $0 as? LinkPreviewView }.first
        try uiExpect(preview?.isHidden == false, "hover did not show the URL pill")
        try uiExpect(
            preview?.label.stringValue == "https://example.com/stationary",
            "URL pill did not show the hovered target"
        )
        try uiExpect(NSCursor.current == .pointingHand, "hover did not install pointing-hand cursor")

        pane.flagsChanged(with: try makeFlagsChangedEvent(keyCode: 55, modifiers: []))

        try uiExpect(controller.pointerEvents.last == .move(column: 2, row: 2),
                     "Cmd release did not replay the last pointer cell")
        try uiExpect(preview?.isHidden == true, "Cmd release did not hide the URL pill")

        NSCursor.crosshair.set()
        controller.emitFrameForTest()
        try uiExpect(NSCursor.current == .crosshair,
                     "an unrelated render frame overwrote the current cursor")
    }

    uiTest("pointer exit clears hover and cancels a pending link click") {
        // Intent: leaving the viewport clears presentation and invalidates the owner-side arm.
        // Why it exists: a later release must not activate a link whose gesture left the pane.
        // Scenario: the user Cmd-presses a link, leaves the pane, then releases over the old cell.
        let controller = TerminalPaneSessionController()
        let link = TerminalHyperlink(uri: "https://example.com/exit")
        controller.hoveredLinkForCommandMove = link
        controller.linkForCommandClick = link
        let pane = makeMountedPane(controller: controller)
        var opened: [URL] = []
        pane.linkOpener = { url in opened.append(url); return true }

        pane.mouseMoved(with: try makeMouseEvent(
            type: .mouseMoved,
            location: .init(x: 17, y: 125),
            modifiers: [.command]
        ))
        pane.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            location: .init(x: 17, y: 125),
            modifiers: [.command]
        ))
        pane.mouseExited(with: try makePointerExitEvent(
            location: .init(x: 81, y: 125),
            modifiers: [.command]
        ))
        pane.mouseUp(with: try makeMouseEvent(
            type: .leftMouseUp,
            location: .init(x: 17, y: 125),
            modifiers: [.command]
        ))

        try uiExpect(controller.linkInteractionCancellations == 1,
                     "pointer exit did not reach owner cancellation")
        try uiExpect(opened.isEmpty, "release after exit opened \(opened)")
        let preview = pane.subviews.compactMap { $0 as? LinkPreviewView }.first
        try uiExpect(preview?.isHidden == true, "pointer exit left the URL pill visible")

        controller.emitHoveredLinkForTest(link)
        try uiExpect(preview?.isHidden == true, "a stale owner frame restored hover after exit")
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

    uiTest("multi-stage Chinese IME commits only final text through native input") {
        // Intent: successive Chinese IME marked-text replacements stay local until AppKit
        //   commits the final candidate through the native text-input callback.
        // Why it exists: partial candidates or their backing key events must not reach the PTY,
        //   and the final commit must not also be encoded as a terminal key.
        // Scenario: Pinyin input advances through "n", "ni", and a selected Chinese candidate
        //   before AppKit commits the two-character phrase.
        let controller = TerminalPaneSessionController()
        controller.inputModes.kittyKeyboardFlags = 1
        let pane = SwiftTerminalSessionView(controller: controller)
        let notFound = NSRange(location: NSNotFound, length: 0)

        pane.setMarkedText(
            "n",
            selectedRange: .init(location: 1, length: 0),
            replacementRange: notFound
        )
        pane.setMarkedText(
            "ni",
            selectedRange: .init(location: 2, length: 0),
            replacementRange: notFound
        )
        pane.setMarkedText(
            "\u{4F60}",
            selectedRange: .init(location: 1, length: 0),
            replacementRange: notFound
        )

        try uiExpect(controller.textInputs.isEmpty, "marked text escaped before commit")
        try uiExpect(controller.inputBytes.isEmpty, "marked text used terminal key encoding")

        pane.insertText("\u{4F60}\u{597D}", replacementRange: notFound)

        try uiExpect(controller.textInputs == ["\u{4F60}\u{597D}"],
                     "Chinese IME commit did not use the text path exactly once")
        try uiExpect(controller.inputBytes.isEmpty,
                     "Chinese IME commit leaked into terminal key encoding")
        try uiExpect(pane.hasMarkedText() == false, "committed IME text remained marked")
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

private func makePointerExitEvent(
    location: NSPoint,
    modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    guard let event = NSEvent.enterExitEvent(
        with: .mouseExited,
        location: location,
        modifierFlags: modifiers,
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        eventNumber: 1,
        trackingNumber: 1,
        userData: nil
    ) else {
        throw UITestFailure(message: "could not synthesize mouseExited")
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

/// A child view that can hold first-responder status so a nil-targeted action can be dispatched
/// up the responder chain (child -> pane) instead of being invoked on the pane directly.
private final class FirstResponderProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
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

private func makeFlagsChangedEvent(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .flagsChanged,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
    ) else {
        throw UITestFailure(message: "could not synthesize flagsChanged for keyCode \(keyCode)")
    }
    return event
}
