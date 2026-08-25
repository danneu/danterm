// Proofs about the lifetime of a local selection while the child owns the mouse. The gestures
// that make and extend a selection are proved in `TerminalInteractionPolicyTests`; what belongs
// here is the other half -- what removes one, and what a Shift press is allowed to pivot on --
// because under mouse reporting the plain click that normally answers both is not available.
import Testing
import TerminalCoreRecording

@testable import TerminalCore

/// Pins selection lifetime against a child that has enabled mouse tracking.
struct TerminalSelectionUnderMouseReportingTests {
    // Intent: a press the child receives also removes the local selection.
    // Why it exists: while tracking is on, every unmodified press is routed to the report arm
    //   and settles nothing, so a Shift-drag selection has no gesture left that can remove it.
    //   Every button the child can be told about answers the same way.
    // Scenario: a Shift-drag selects "hello" inside a full-screen TUI, then an ordinary click
    //   into the TUI leaves the stale highlight behind for the rest of the session.
    @Test(
        "a reported press clears the local selection",
        arguments: [TerminalMouseButton.left, .middle, .right]
    )
    func reportedPressClearsSelection(button: TerminalMouseButton) throws {
        var terminal = try #require(trackingTerminal())
        var state = TerminalInteractionState()
        shiftDrag(from: 0, to: 5, terminal: &terminal, state: &state)
        #expect(terminal.selectedText == "hello")

        var pressing = TerminalInteractionState()
        let press = decideAndApply(
            .down(button, cell: .init(column: 2, row: 0)),
            terminal: &terminal,
            state: &pressing
        )
        #expect(press.consumption == .report)
        #expect(press.settledSelection == .cleared)
        #expect(press.inputBytes.isEmpty == false)
        #expect(terminal.selectionRange == nil)
    }

    // Intent: a replayed recording reaches the same selection state a live session does.
    // Why it exists: the clear is a decision effect, so it reaches the terminal only through
    //   the shared applier. A replay that settled the decision itself would drift from the
    //   live host over exactly this gesture.
    @Test("a replayed reported press clears the selection like a live one")
    func replayedReportedPressMatchesLive() throws {
        var live = try #require(trackingTerminal())
        var liveState = TerminalInteractionState()
        shiftDrag(from: 0, to: 5, terminal: &live, state: &liveState)
        decideAndApply(
            .down(.left, cell: .init(column: 2, row: 0)),
            terminal: &live,
            state: &liveState
        )

        var replayed = try #require(trackingTerminal())
        var replayState = TerminalInteractionState()
        shiftDrag(from: 0, to: 5, terminal: &replayed, state: &replayState)
        _ = applyNeutralTerminalMouse(
            .init(action: .down, button: 1, column: 2, row: 0),
            terminal: &replayed,
            interactionState: &replayState
        )

        #expect(live.selectionRange == nil)
        #expect(replayed.selectionRange == live.selectionRange)
        #expect(replayed.selectedText == live.selectedText)
    }

    /// Builds the situation every test here starts from: text on screen and the child holding
    /// the mouse through SGR tracking, which is what a full-screen TUI enables.
    private func trackingTerminal() -> Terminal? {
        guard var terminal = Terminal(columns: 12, rows: 2) else { return nil }
        terminal.feed(Array("hello world".utf8))
        terminal.feed(Array("\u{1B}[?1000;1006h".utf8))
        return terminal
    }

    /// Runs the one gesture that can still select text while the child owns the mouse.
    private func shiftDrag(
        from startColumn: Int,
        to endColumn: Int,
        terminal: inout Terminal,
        state: inout TerminalInteractionState
    ) {
        decideAndApply(
            .down(.left, cell: .init(column: startColumn, row: 0), modifiers: [.shift]),
            terminal: &terminal,
            state: &state
        )
        decideAndApply(
            .move(cell: .init(column: endColumn, row: 0), modifiers: [.shift]),
            terminal: &terminal,
            state: &state
        )
        decideAndApply(
            .up(.left, cell: .init(column: endColumn, row: 0), modifiers: [.shift]),
            terminal: &terminal,
            state: &state
        )
    }
}
