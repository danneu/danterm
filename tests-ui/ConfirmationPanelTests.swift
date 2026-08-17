// UI-harness tests for the confirmation panel's command area: what the copy
// affordance writes, how the panel sizes itself around the command document, and
// what a confirmation with no running command shows. The pure tests
// (CloseConfirmationTests) prove the projection carries every command in full;
// only this harness can prove the panel presents all of it, scrolls rather than
// elides, and hands the whole list to the clipboard.
import Cocoa

/// Registers confirmation-panel coverage in the standalone UI harness.
func confirmationPanelTests() {
    print("ConfirmationPanel")

    uiTest("copy writes every projected command, one per line") {
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let commands = ["make test", "npm run dev", "rsync -a source dest"]

        fx.panel.configure(makeConfirmationProjection(commands: commands))
        fx.panel.copyButton.performClick(nil)

        try uiExpect(fx.pasteboard.strings == [commands.joined(separator: "\n")],
                     "expected the whole command list, got \(fx.pasteboard.strings)")
        try uiExpect(fx.pasteboard.clearCount == 1, "a copy should replace the clipboard, not append to it")
    }

    uiTest("copy writes commands the panel is too short to draw") {
        // Intent: the clipboard gets the projected list, not the drawn text.
        // Why it exists: this is the regression the change exists to prevent.
        //   The old panel held one already-shortened string, so any copy button
        //   bolted onto it could only ever yield an ellipsis.
        // Scenario: spec-first -- enough long commands that the document must
        //   scroll, so most of them are outside the visible frame.
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        let commands = (1...40).map { "run-step-\($0) " + String(repeating: "x", count: 200) }

        fx.panel.configure(makeConfirmationProjection(commands: commands))
        fx.panel.contentView?.layoutSubtreeIfNeeded()
        let visible = fx.panel.commandScrollView.contentView.documentVisibleRect.height
        let document = fx.panel.commandTextView.frame.height
        try uiExpect(document > visible,
                     "precondition: the document should overflow its clip view, \(document) vs \(visible)")

        fx.panel.copyButton.performClick(nil)

        try uiExpect(fx.pasteboard.strings == [commands.joined(separator: "\n")],
                     "a scrolled panel should still copy every command in full")
    }

    uiTest("the panel sizes to its command document until the bound, then scrolls") {
        // Intent: the panel's height is derived from its content, capped by the
        //   bound that keeps it on screen; past the cap the document scrolls.
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
        try uiExpect(shortHeight > 0, "one command should give the document some height")
        try uiExpect(shortHeight < confirmationCommandAreaMaxHeight,
                     "one command should not reach the bound, got \(shortHeight)")
        try uiExpect(abs(contentView.frame.height - contentView.fittingSize.height) < 0.5,
                     "the panel should size to its content: frame \(contentView.frame.height), "
                     + "fitting \(contentView.fittingSize.height)")

        fx.panel.configure(makeConfirmationProjection(commands: (1...40).map { "step-\($0)" }))
        fx.panel.contentView?.layoutSubtreeIfNeeded()

        try uiExpect(abs(fx.panel.commandScrollView.frame.height - confirmationCommandAreaMaxHeight) < 0.5,
                     "the document should stop at the bound, got \(fx.panel.commandScrollView.frame.height)")
        try uiExpect(fx.panel.commandTextView.frame.height > confirmationCommandAreaMaxHeight,
                     "past the bound the document must remain scrollable, not shrink to fit")
        try uiExpect(contentView.hasAmbiguousLayout == false,
                     "the command area must not leave the panel ambiguously laid out")
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

        try uiExpect(fx.panel.commandTextView.isSelectable, "the user must be able to select the command")
        try uiExpect(!fx.panel.commandTextView.isEditable, "the command is not an editable field")
        try uiExpect(fx.panel.commandTextView.string == "make test", "the document should hold the command")
    }

    uiTest("a confirmation with no running command shows no command area") {
        let fx = makeConfirmationFixture()
        defer { fx.panel.close() }
        fx.panel.configure(makeConfirmationProjection(commands: ["make test"]))

        fx.panel.configure(makeConfirmationProjection(commands: []))
        fx.panel.contentView?.layoutSubtreeIfNeeded()

        try uiExpect(fx.panel.commandArea.isHidden, "an empty command list should hide the whole area")
        try uiExpect(fx.panel.copyButton.window == nil || fx.panel.copyButton.isHiddenOrHasHiddenAncestor,
                     "no commands means no copy affordance")
        try uiExpect(fx.panel.commandTextView.string.isEmpty, "the document should hold no stale command")

        fx.panel.copyButton.performClick(nil)
        try uiExpect(fx.pasteboard.strings.isEmpty, "copying nothing must not touch the clipboard")
    }
}

// MARK: - Fixture

private struct ConfirmationFixture {
    let runtime: AppRuntime
    let panel: ConfirmationPanel
    let pasteboard: RecordingConfirmationPasteboard
}

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
