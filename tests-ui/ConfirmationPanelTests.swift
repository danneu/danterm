// UI-harness tests for the confirmation panel's command area: that every
// projected command becomes its own item with its own copy action, what each
// copy action writes, how the panel sizes itself around the item list, and what
// a confirmation with no running command shows. The pure tests
// (CloseConfirmationTests) prove the projection carries every command in full;
// only this harness can prove the panel presents all of it, scrolls rather than
// elides, and hands one command at a time to the clipboard.
import Cocoa
import ChipArtwork
import PaneProcessLifecycle
import TerminalCore
import TerminalPaneSession
import TerminalPTYHost
import TerminalRenderExecution
import TerminalRenderPlanning
@testable import DanTerm

/// Registers confirmation-panel coverage in the standalone UI harness.
@MainActor
func confirmationPanelTests() async {
    print("ConfirmationPanel")

    await uiTest("every projected command gets its own item and its own copy control") {
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

    await uiTest("an item's copy writes only its own command") {
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let commands = ["make test", "npm run dev", "rsync -a source dest"]

        fx.panel.configure(makeConfirmationProjection(commands: commands))
        fx.panel.commandItems[1].copyButton.performClick(nil)

        try uiExpect(fx.pasteboard.strings == ["npm run dev"],
                     "expected only the chosen command, got \(fx.pasteboard.strings)")
        try uiExpect(fx.pasteboard.clearCount == 1, "a copy should replace the clipboard, not append to it")
    }

    await uiTest("copy works for an item the panel is too short to draw") {
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

    await uiTest("an item copies the command its position holds now, not the one it held before") {
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

    await uiTest("a partly selected item still copies its whole command") {
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

    await uiTest("a refresh leaves the panel nothing left to lay out") {
        // Intent: a refresh reaches the panel's final layout in one pass: no
        //   layout is owed when it returns, and laying out again moves no frame.
        // Why it exists: the panel used to discover a command's wrap width by
        //   reading back the width a finished pass had given it, so width A
        //   produced a label that asked for width B and B asked for A again. The
        //   size never settled, and in a real display cycle the window's
        //   update-constraints pass threw NSGenericException and took the app
        //   down when quitting with ten or more running commands.
        // Scenario: spec-first -- enough long commands that the list must scroll.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let commands = (1...40).map { "run-step-\($0) " + String(repeating: "x", count: 120) }

        fx.panel.configure(makeConfirmationProjection(commands: commands))

        guard let contentView = fx.panel.contentView else {
            throw UITestFailure(message: "expected a content view")
        }
        try uiExpect(!contentView.needsLayout, "the panel still owed a layout pass after a refresh")
        try uiExpect(!contentView.hasAmbiguousLayout, "the refreshed panel is ambiguously laid out")

        let panelFrame = fx.panel.frame
        let itemFrames = fx.panel.commandItems.map(\.frame)
        contentView.layoutSubtreeIfNeeded()

        try uiExpect(fx.panel.frame == panelFrame,
                     "laying out again moved the panel to \(fx.panel.frame) from \(panelFrame)")
        try uiExpect(fx.panel.commandItems.map(\.frame) == itemFrames,
                     "laying out again moved the items")
    }

    await uiTest("the panel states one width whatever the command list holds") {
        // Intent: the panel's width is computed before anything wraps, so no
        //   content of the panel can push it wider.
        // Why it exists: a command label used to report its own intrinsic width
        //   upward, which is the half of the negotiation that oscillated.
        // Scenario: spec-first -- no commands, one, forty, and a single command
        //   longer than the panel that cannot be broken at a space.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let lists: [[String]] = [
            [],
            ["make test"],
            (1...40).map { "run-step-\($0) " + String(repeating: "x", count: 120) },
            [String(repeating: "x", count: 400)],
        ]

        var widths: [CGFloat] = []
        for commands in lists {
            fx.panel.configure(makeConfirmationProjection(commands: commands))
            widths.append(fx.panel.frame.width)
        }

        try uiExpect(widths.allSatisfy { abs($0 - widths[0]) < 0.5 },
                     "the command list changed the panel's width: \(widths)")
        let label = fx.panel.commandItems[0].commandLabel
        try uiExpect(label.frame.width <= fx.panel.commandScrollView.frame.width + 0.5,
                     "an unbreakable command stretched its label to \(label.frame.width), "
                     + "past the \(fx.panel.commandScrollView.frame.width) area that clips it")
    }

    await uiTest("a command's wrap width ignores the scroller and its style") {
        // Intent: the width a command wraps to is the same whether or not a
        //   scroller shows, and under either scroller style.
        // Why it exists: the scroller's channel is reserved out of the stated
        //   width up front. Deriving the width from the scroller that is showing
        //   would make content height an input to wrap width -- a second loop --
        //   and reading the ambient style would make a system preference decide
        //   how text wraps.
        // Scenario: spec-first -- one command, then forty of them, then the same
        //   one command under each scroller style.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let command = (1...12).map { "step-\($0)-with-a-fairly-long-name" }.joined(separator: " ")

        @MainActor func labelWidth(_ commands: [String]) -> CGFloat {
            fx.panel.configure(makeConfirmationProjection(commands: commands))
            return fx.panel.commandItems[0].commandLabel.frame.width
        }

        let short = labelWidth([command])
        let scrolling = labelWidth(Array(repeating: command, count: 40))
        fx.panel.commandScrollView.scrollerStyle = .overlay
        let overlay = labelWidth([command])
        fx.panel.commandScrollView.scrollerStyle = .legacy
        let legacy = labelWidth([command])

        try uiExpect(short > 0, "the item should have been given a width")
        try uiExpect([scrolling, overlay, legacy].allSatisfy { abs($0 - short) < 0.5 },
                     "the wrap width moved: \(short) alone, \(scrolling) scrolling, "
                     + "\(overlay) overlay, \(legacy) legacy")
    }

    await uiTest("the panel sizes to its item list until the bound, then scrolls") {
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

        // The clipped height must not be pushed back onto the list: the items
        // keep their own heights and a positive gap, in projection order down
        // the panel, and the buttons stay inside the panel's content.
        let drawn = fx.panel.commandItems.map { $0.convert($0.bounds, to: contentView) }
        for (above, below) in zip(drawn, drawn.dropFirst()) {
            try uiExpect(above.minY - below.maxY > 0,
                         "items overlapped or fell out of order: \(above) then \(below)")
        }
        guard let last = fx.panel.actionRow.buttonsInVisualOrder.last else {
            throw UITestFailure(message: "the panel drew no buttons")
        }
        try uiExpect(contentView.bounds.contains(last.convert(last.bounds, to: contentView)),
                     "the buttons were pushed out of the panel by the command list")
    }

    await uiTest("a wrapped command shows every one of its lines") {
        // Intent: an item reports the height its wrapped text needs at the width
        //   it is actually given, so nothing is cut off below the bound.
        // Why it exists: the panel states the width each command wraps to before
        //   layout runs. Telling a label one width and drawing it at another
        //   would cut off its last lines, and the scroller's channel is reserved
        //   out of the stated width so that a scroller cannot narrow it.
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

    await uiTest("a resize on reconfigure holds the title bar still") {
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

    await uiTest("the command text is selectable") {
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }

        fx.panel.configure(makeConfirmationProjection(commands: ["make test"]))
        let label = fx.panel.commandItems[0].commandLabel

        try uiExpect(label.isSelectable, "the user must be able to select the command")
        try uiExpect(!label.isEditable, "the command is not an editable field")
        try uiExpect(label.stringValue == "make test", "the item should hold the command")
    }

    await uiTest("a confirmation with no running command shows no command area") {
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

    await uiTest("Return and Escape answer while focus sits in the command area") {
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
        if case .answerConfirmation(_, .confirm) = fx.runtime.sentMessages[0] {} else {
            throw UITestFailure(message: "Return should confirm, got \(fx.runtime.sentMessages[0])")
        }

        fx.panel.sendEvent(try keyEvent(in: fx.panel, characters: "\u{1b}", keyCode: 53))
        try uiExpect(fx.runtime.sentMessages.count == 2,
                     "Escape should have answered once, got \(fx.runtime.sentMessages)")
        if case .answerConfirmation(_, .cancel) = fx.runtime.sentMessages[1] {} else {
            throw UITestFailure(message: "Escape should cancel, got \(fx.runtime.sentMessages[1])")
        }
    }

    await uiTest("a delete-group confirmation draws its three choices in dialog order") {
        // Intent: the alternative sits leading, cancel next, and the default
        //   rightmost against the panel's content inset.
        // Why it exists: this path had no harness coverage at all, and it drew
        //   left-aligned in the order [Cancel] [Close Tabs] [Move to General].
        //   The default is now Close Tabs, and moving the tabs is the
        //   alternative.
        // Scenario: spec-first -- the only three-button confirmation there is.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }

        fx.panel.configure(makeDeleteGroupProjection())
        fx.panel.contentView?.layoutSubtreeIfNeeded()

        let buttons = fx.panel.actionRow.buttonsInVisualOrder
        let drawn = buttons.sorted { $0.frame.minX < $1.frame.minX }.map(\.title)
        try uiExpect(drawn == ["Move to group \"General\"", "Cancel", "Close Tabs"],
                     "expected the alternative, cancel, then the default, got \(drawn)")
        guard let contentView = fx.panel.contentView, let last = buttons.last else {
            throw UITestFailure(message: "the panel drew no buttons")
        }
        let trailing = last.convert(last.bounds, to: contentView).maxX
        let rowTrailing = fx.panel.actionRow.convert(fx.panel.actionRow.bounds, to: contentView).maxX
        try uiExpect(abs(trailing - rowTrailing) < 0.5,
                     "the default button should end at the content inset, got \(trailing) vs \(rowTrailing)")
    }

    await uiTest("each confirmation button sends the message its choice names") {
        // Intent: the message follows the answered choice.
        // Why it exists: the panel used to pick between confirm and the
        //   delete-group choice by reading a hidden button's visibility.
        // Scenario: spec-first -- click all three delete-group buttons.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let projection = makeDeleteGroupProjection()
        fx.panel.configure(projection)

        for button in fx.panel.actionRow.buttonsInVisualOrder {
            button.performClick(nil)
        }

        let expected: [String] = ["Move to group \"General\"", "Cancel", "Close Tabs"]
        try uiExpect(fx.runtime.sentMessages.count == 3,
                     "expected one message per button, got \(fx.runtime.sentMessages)")
        let order = fx.panel.actionRow.buttonsInVisualOrder.map(\.title)
        try uiExpect(order == expected, "unexpected button order \(order)")
        if case .answerConfirmation(projection.id, .deleteGroup(moveTabs: true)) = fx.runtime.sentMessages[0] {} else {
            throw UITestFailure(message: "Move to group should move tabs, got \(fx.runtime.sentMessages[0])")
        }
        if case .answerConfirmation(projection.id, .cancel) = fx.runtime.sentMessages[1] {} else {
            throw UITestFailure(message: "Cancel should cancel, got \(fx.runtime.sentMessages[1])")
        }
        if case .answerConfirmation(projection.id, .deleteGroup(moveTabs: false)) = fx.runtime.sentMessages[2] {} else {
            throw UITestFailure(message: "Close Tabs should keep no tabs, got \(fx.runtime.sentMessages[2])")
        }
    }

    await uiTest("Return answers the delete-group default from the command area") {
        // Intent: the reserved Return key answers the projected confirm choice,
        //   whichever confirmation is open.
        // Why it exists: the deleted isHidden branch is what used to make Return
        //   mean "move the tabs" on this subject; the choice must carry it now,
        //   and the default it names is Close Tabs.
        // Scenario: spec-first -- the three-button confirmation, Return pressed
        //   while the panel holds focus.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let projection = makeDeleteGroupProjection()
        fx.panel.configure(projection)

        fx.panel.sendEvent(try keyEvent(in: fx.panel, characters: "\r", keyCode: 36))

        try uiExpect(fx.runtime.sentMessages.count == 1,
                     "Return should have answered once, got \(fx.runtime.sentMessages)")
        if case .answerConfirmation(projection.id, .deleteGroup(moveTabs: false)) = fx.runtime.sentMessages[0] {} else {
            throw UITestFailure(message: "Return should close the tabs, got \(fx.runtime.sentMessages[0])")
        }
    }

    await uiTest("a long confirm title keeps the buttons inside the panel") {
        // Intent: a button row wider than the text column widens the panel
        //   instead of overflowing it, and the size still settles.
        // Why it exists: the ceiling on the column was a required constraint the
        //   row could not honor, so a wide row broke a constraint rather than
        //   growing the panel.
        // Scenario: spec-first -- a confirm title far wider than the text
        //   column, and still narrow enough to fit any display DanTerm supports,
        //   so the case cannot turn on the tester's screen width.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let long = String(repeating: "Close Every Tab ", count: 8)

        fx.panel.configure(makeConfirmationProjection(commands: ["make test"], confirmTitle: long))
        fx.panel.contentView?.layoutSubtreeIfNeeded()
        let settled = fx.panel.frame

        guard let contentView = fx.panel.contentView,
              let last = fx.panel.actionRow.buttonsInVisualOrder.last else {
            throw UITestFailure(message: "the panel drew no buttons")
        }
        let drawn = last.convert(last.bounds, to: contentView)
        try uiExpect(drawn.maxX <= contentView.bounds.maxX + 0.5,
                     "the default button ran past the panel at \(drawn.maxX) of \(contentView.bounds.maxX)")
        // A broken width bound shows up as a squeezed button: the row's cancel
        // and default resist compression at required priority, so either they
        // are drawn at their natural width or a required constraint gave way.
        try uiExpect(fx.panel.actionRow.frame.width >= fx.panel.actionRow.requiredWidth - 0.5,
                     "the row was given \(fx.panel.actionRow.frame.width) of the "
                     + "\(fx.panel.actionRow.requiredWidth) its buttons need")
        try uiExpect(abs(last.frame.width - last.fittingSize.width) < 0.5,
                     "the default button was squeezed to \(last.frame.width) "
                     + "from \(last.fittingSize.width)")

        fx.panel.configure(makeConfirmationProjection(commands: ["make test"], confirmTitle: long))
        try uiExpect(abs(fx.panel.frame.width - settled.width) < 0.5
                     && abs(fx.panel.frame.height - settled.height) < 0.5,
                     "the same projection resized the panel to \(fx.panel.frame) from \(settled)")
    }
}

// MARK: - Fixture

private struct ConfirmationFixture {
    let runtime: RecordingAppRuntime
    let panel: ConfirmationPanel
    let pasteboard: RecordingConfirmationPasteboard
}

@MainActor
private func makeConfirmationFixture() -> ConfirmationFixture {
    let runtime = makeUITestRuntime()
    let panel = ConfirmationPanel(runtime: runtime)
    let pasteboard = RecordingConfirmationPasteboard()
    panel.pasteboard = pasteboard
    return ConfirmationFixture(runtime: runtime, panel: panel, pasteboard: pasteboard)
}

private func makeConfirmationProjection(
    commands: [String],
    confirmTitle: String = "Close Tab"
) -> ConfirmationProjection {
    ConfirmationProjection(
        id: ConfirmationId(),
        title: "Close tab \"Terminal\"?",
        informativeText: "This tab has a running command.",
        commands: commands.map { DisplayLine($0) },
        confirm: ConfirmationChoice(
            title: DisplayLine(confirmTitle), answer: .confirm, isDestructive: true),
        cancel: ConfirmationChoice(title: "Cancel", answer: .cancel)
    )
}

/// The three-button confirmation, the only one with two affirmative answers.
private func makeDeleteGroupProjection() -> ConfirmationProjection {
    ConfirmationProjection(
        id: ConfirmationId(),
        title: "Delete group \"Work\"?",
        informativeText: "This group has 2 tab(s).",
        commands: [],
        confirm: ConfirmationChoice(
            title: "Close Tabs", answer: .deleteGroup(moveTabs: false), isDestructive: true),
        cancel: ConfirmationChoice(title: "Cancel", answer: .cancel),
        alternatives: [
            ConfirmationChoice(
                title: "Move to group \"General\"", answer: .deleteGroup(moveTabs: true))
        ]
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
