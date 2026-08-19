// UI-harness tests for the confirmation panel's command area: that every
// projected command becomes its own item with its own copy action, what each
// copy action writes, how the panel sizes itself around the item list, and what
// a confirmation with no running command shows. The pure tests
// (CloseConfirmationTests) prove the projection carries every command in full;
// only this harness can prove the panel presents all of it, scrolls rather than
// elides, and hands one command at a time to the clipboard.
import Cocoa

/// Registers confirmation-panel coverage in the standalone UI harness.
@MainActor
func confirmationPanelTests() {
    print("ConfirmationPanel")

    uiTest("every projected command gets its own item and its own copy control") {
        // Intent: the panel presents the command list as items, one per
        //   projected command, in order and in full.
        // Why it exists: with one copy control per command and no others, there
        //   is no affordance left that could copy the whole list.
        // Scenario: spec-first -- three commands of very different lengths.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let commands = ["make test", "npm run dev", "rsync -a " + String(repeating: "long/", count: 40)]

        fx.panel.configure(makeConfirmationProjection(commands: commands))
        fx.panel.contentView?.layoutSubtreeIfNeeded()

        try uiExpect(fx.panel.commandItems.map(\.command) == commands,
                     "expected one item per command in order, got \(fx.panel.commandItems.map(\.command))")
        try uiExpect(fx.panel.commandItems.map(\.commandLabel.stringValue) == commands,
                     "each item should draw its whole command with no elision")
        try uiExpect(copyControls(in: fx.panel).count == commands.count,
                     "expected exactly one copy control per command, got \(copyControls(in: fx.panel).count)")
    }

    uiTest("an item's copy writes only its own command") {
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let commands = ["make test", "npm run dev", "rsync -a source dest"]

        fx.panel.configure(makeConfirmationProjection(commands: commands))
        fx.panel.commandItems[1].copyButton.performClick(nil)

        try uiExpect(fx.pasteboard.strings == ["npm run dev"],
                     "expected only the chosen command, got \(fx.pasteboard.strings)")
        try uiExpect(fx.pasteboard.clearCount == 1, "a copy should replace the clipboard, not append to it")
    }

    uiTest("copy works for an item the panel is too short to draw") {
        // Intent: an item's copy writes its projected command whether or not the
        //   panel has room to draw that item.
        // Why it exists: this is the regression the change exists to prevent.
        //   The old panel held one already-shortened string with a single copy
        //   button, so a command outside the visible frame could not be taken on
        //   its own at all.
        // Scenario: spec-first -- enough long commands that the list must
        //   scroll, so most items are outside the visible rect.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let commands = (1...40).map { "run-step-\($0) " + String(repeating: "x", count: 200) }

        fx.panel.configure(makeConfirmationProjection(commands: commands))
        fx.panel.contentView?.layoutSubtreeIfNeeded()
        let visible = fx.panel.commandScrollView.contentView.documentVisibleRect
        let last = fx.panel.commandItems[39]
        try uiExpect(!visible.intersects(last.frame),
                     "precondition: the last item should sit outside the clip view, "
                     + "\(last.frame) within \(visible)")

        last.copyButton.performClick(nil)

        try uiExpect(fx.pasteboard.strings == [commands[39]],
                     "an undrawn item should still copy its own command in full")
    }

    uiTest("an item copies the command its position holds now, not the one it held before") {
        // Intent: a reconfigure repoints every item at the new projection.
        // Why it exists: the panel is reused across confirmations and refreshes
        //   live as panes close, so an item that kept its old command would copy
        //   a command that is no longer in the list.
        // Scenario: spec-first -- two commands, then two different ones.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        fx.panel.configure(makeConfirmationProjection(commands: ["make test", "npm run dev"]))

        fx.panel.configure(makeConfirmationProjection(commands: ["cargo build", "go test ./..."]))
        fx.panel.commandItems[0].copyButton.performClick(nil)

        try uiExpect(fx.pasteboard.strings == ["cargo build"],
                     "the first item should copy the command it now shows, got \(fx.pasteboard.strings)")
    }

    uiTest("a partly selected item still copies its whole command") {
        // Intent: the copy action writes the projected command, never the text
        //   selection.
        // Why it exists: the command text stays selectable, so a stray selection
        //   left behind by a drag must not shrink what the copy control yields.
        // Scenario: spec-first -- select the first four characters, then copy.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        fx.panel.configure(makeConfirmationProjection(commands: ["make test"]))
        let item = fx.panel.commandItems[0]

        try uiExpect(fx.panel.makeFirstResponder(item.commandLabel),
                     "the panel refused focus to the command text")
        item.commandLabel.currentEditor()?.selectedRange = NSRange(location: 0, length: 4)
        item.copyButton.performClick(nil)

        try uiExpect(fx.pasteboard.strings == ["make test"],
                     "the copy control should ignore the selection, got \(fx.pasteboard.strings)")
    }

    uiTest("the panel sizes to its item list until the bound, then scrolls") {
        // Intent: the panel's height is derived from its content, capped by the
        //   bound that keeps it on screen; past the cap the list scrolls.
        // Why it exists: the old panel asserted a fixed 460x190 frame, so a long
        //   command had nowhere to go but a truncating single-line label.
        // Scenario: spec-first -- one short command, then far more than fit.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }

        fx.panel.configure(makeConfirmationProjection(commands: ["make test"]))
        fx.panel.contentView?.layoutSubtreeIfNeeded()
        guard let contentView = fx.panel.contentView else {
            throw UITestFailure(message: "expected a content view")
        }
        let shortHeight = fx.panel.commandScrollView.frame.height
        try uiExpect(shortHeight > 0, "one command should give the list some height")
        try uiExpect(shortHeight < confirmationCommandAreaMaxHeight,
                     "one command should not reach the bound, got \(shortHeight)")
        try uiExpect(abs(contentView.frame.height - contentView.fittingSize.height) < 0.5,
                     "the panel should size to its content: frame \(contentView.frame.height), "
                     + "fitting \(contentView.fittingSize.height)")

        fx.panel.configure(makeConfirmationProjection(commands: (1...40).map { "step-\($0)" }))
        fx.panel.contentView?.layoutSubtreeIfNeeded()

        try uiExpect(abs(fx.panel.commandScrollView.frame.height - confirmationCommandAreaMaxHeight) < 0.5,
                     "the list should stop at the bound, got \(fx.panel.commandScrollView.frame.height)")
        try uiExpect(fx.panel.commandList.frame.height > confirmationCommandAreaMaxHeight,
                     "past the bound the list must remain scrollable, not shrink to fit")
        try uiExpect(contentView.hasAmbiguousLayout == false,
                     "the command area must not leave the panel ambiguously laid out")
    }

    uiTest("a wrapped command shows every one of its lines") {
        // Intent: an item reports the height its wrapped text needs at the width
        //   it is actually given, so nothing is cut off below the bound.
        // Why it exists: sizing an item to a constant width would clip its last
        //   lines the moment a visible scroller narrows the real width.
        // Scenario: spec-first -- one command far too long for a single line,
        //   short enough that the whole list stays under the bound.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let command = (1...12).map { "step-\($0)-with-a-fairly-long-name" }.joined(separator: " ")

        fx.panel.configure(makeConfirmationProjection(commands: [command]))
        fx.panel.contentView?.layoutSubtreeIfNeeded()
        let item = fx.panel.commandItems[0]
        let label = item.commandLabel
        let needed = label.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 10_000)
        ).height ?? 0

        try uiExpect(label.bounds.width > 0, "the item should have been given a width")
        try uiExpect(needed > label.font.map { $0.boundingRectForFont.height * 1.5 } ?? 0,
                     "precondition: the command should wrap onto several lines, needed \(needed)")
        try uiExpect(label.bounds.height >= needed - 0.5,
                     "the label should be as tall as its wrapped text: \(label.bounds.height) vs \(needed)")
        try uiExpect(fx.panel.commandScrollView.contentView.documentVisibleRect.height
                     >= fx.panel.commandList.frame.height - 0.5,
                     "a list under the bound should show every line without scrolling")
    }

    uiTest("a resize on reconfigure holds the title bar still") {
        // Intent: a refresh that grows or shrinks the panel keeps its top edge.
        // Why it exists: the quit panel reconfigures live as panes close, and an
        //   AppKit resize anchors the bottom-left corner by default -- so the
        //   title bar would walk up and down under the pointer on every refresh.
        // Scenario: spec-first -- one command, then many, then none.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        fx.panel.configure(makeConfirmationProjection(commands: ["make test"]))
        fx.panel.center(on: nil)
        let top = fx.panel.frame.maxY

        for commands in [(1...40).map { "step-\($0)" }, [], ["make test"]] {
            fx.panel.configure(makeConfirmationProjection(commands: commands))
            try uiExpect(abs(fx.panel.frame.maxY - top) < 0.5,
                         "the title bar moved to \(fx.panel.frame.maxY) from \(top) "
                         + "for \(commands.count) commands")
        }
    }

    uiTest("the command text is selectable") {
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }

        fx.panel.configure(makeConfirmationProjection(commands: ["make test"]))
        let label = fx.panel.commandItems[0].commandLabel

        try uiExpect(label.isSelectable, "the user must be able to select the command")
        try uiExpect(!label.isEditable, "the command is not an editable field")
        try uiExpect(label.stringValue == "make test", "the item should hold the command")
    }

    uiTest("a confirmation with no running command shows no command area") {
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        fx.panel.configure(makeConfirmationProjection(commands: ["make test"]))

        fx.panel.configure(makeConfirmationProjection(commands: []))
        fx.panel.contentView?.layoutSubtreeIfNeeded()

        try uiExpect(fx.panel.commandScrollView.isHidden, "an empty command list should hide the whole area")
        try uiExpect(fx.panel.commandItems.isEmpty, "no commands means no items")
        try uiExpect(copyControls(in: fx.panel).isEmpty, "no commands means no copy affordance")
        try uiExpect(fx.pasteboard.strings.isEmpty, "an empty confirmation must not touch the clipboard")
    }

    uiTest("Return and Escape answer while focus sits in the command area") {
        // Intent: the panel's two reserved keys still work when a command's text
        //   holds first responder.
        // Why it exists: the command text is selectable, so it takes focus on a
        //   click and would otherwise swallow Return.
        // Scenario: spec-first -- focus the first item's text, press each key.
        //   The panel is never made key, so a harness run does not take the
        //   keyboard away from whatever the user is typing in.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        fx.panel.configure(makeConfirmationProjection(commands: ["make test"]))
        let label = fx.panel.commandItems[0].commandLabel
        try uiExpect(fx.panel.makeFirstResponder(label), "the panel refused focus to the command text")

        fx.panel.sendEvent(try keyEvent(in: fx.panel, characters: "\r", keyCode: 36))
        try uiExpect(fx.runtime.sentMessages.count == 1,
                     "Return should have answered once, got \(fx.runtime.sentMessages)")
        if case .confirmConfirmation = fx.runtime.sentMessages[0] {} else {
            throw UITestFailure(message: "Return should confirm, got \(fx.runtime.sentMessages[0])")
        }

        fx.panel.sendEvent(try keyEvent(in: fx.panel, characters: "\u{1b}", keyCode: 53))
        try uiExpect(fx.runtime.sentMessages.count == 2,
                     "Escape should have answered once, got \(fx.runtime.sentMessages)")
        if case .cancelConfirmation = fx.runtime.sentMessages[1] {} else {
            throw UITestFailure(message: "Escape should cancel, got \(fx.runtime.sentMessages[1])")
        }
    }
}

// MARK: - Fixture

private struct ConfirmationFixture {
    let runtime: AppRuntime
    let panel: ConfirmationPanel
    let pasteboard: RecordingConfirmationPasteboard
}

@MainActor
private func makeConfirmationFixture() -> ConfirmationFixture {
    let runtime = AppRuntime()
    let panel = ConfirmationPanel(runtime: runtime)
    let pasteboard = RecordingConfirmationPasteboard()
    panel.pasteboard = pasteboard
    return ConfirmationFixture(runtime: runtime, panel: panel, pasteboard: pasteboard)
}

private func makeConfirmationProjection(commands: [String]) -> ConfirmationProjection {
    ConfirmationProjection(
        id: ConfirmationId(),
        title: "Close tab \"Terminal\"?",
        informativeText: "This tab has a running command.",
        commands: commands.map { DisplayLine($0) },
        confirmTitle: "Close Tab",
        secondaryTitle: nil
    )
}

/// Every button anywhere in the panel's command area, so the count proves both
/// that each command has a copy control and that no extra whole-list one exists.
@MainActor
private func copyControls(in panel: ConfirmationPanel) -> [NSButton] {
    func buttons(under view: NSView) -> [NSButton] {
        view.subviews.flatMap { subview -> [NSButton] in
            (subview as? NSButton).map { [$0] } ?? buttons(under: subview)
        }
    }
    return buttons(under: panel.commandScrollView)
}

@MainActor
private func keyEvent(in window: NSWindow, characters: String, keyCode: UInt16) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode
    ) else { throw UITestFailure(message: "could not create key event") }
    return event
}

private final class RecordingConfirmationPasteboard: TextPasteboard {
    var strings: [String] = []
    var clearCount = 0

    @discardableResult func clearContents() -> Int {
        clearCount += 1
        strings.removeAll()
        return clearCount
    }

    @discardableResult func setString(
        _ string: String,
        forType dataType: NSPasteboard.PasteboardType
    ) -> Bool {
        strings.append(string)
        return true
    }
}
