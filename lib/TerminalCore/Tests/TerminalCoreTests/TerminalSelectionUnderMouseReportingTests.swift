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
        drag(from: 0, to: 5, modifiers: [.shift], terminal: &terminal, state: &state)
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
        drag(from: 0, to: 5, modifiers: [.shift], terminal: &live, state: &liveState)
        decideAndApply(
            .down(.left, cell: .init(column: 2, row: 0)),
            terminal: &live,
            state: &liveState
        )

        var replayed = try #require(trackingTerminal())
        var replayState = TerminalInteractionState()
        drag(from: 0, to: 5, modifiers: [.shift], terminal: &replayed, state: &replayState)
        _ = applyNeutralTerminalMouse(
            .init(action: .down, button: 1, column: 2, row: 0),
            terminal: &replayed,
            interactionState: &replayState
        )

        #expect(live.selectionRange == nil)
        #expect(replayed.selectionRange == live.selectionRange)
        #expect(replayed.selectedText == live.selectedText)
    }

    // Intent: a caret a Shift press mints goes away with the gesture that minted it.
    // Why it exists: a Shift press pivots on a settled caret, and under mouse reporting it is
    //   also the only gesture that can place one. A caret that outlived its gesture would let
    //   the next Shift press select a span between two points the user never saw chosen, and
    //   the same trap is reachable in a plain shell.
    // Scenario: inside opencode, one Shift click looks inert, and a Shift click somewhere else
    //   highlights everything between the two.
    @Test("two Shift presses in a row select nothing", arguments: [true, false])
    func shiftCaretDoesNotOutliveItsGesture(reporting: Bool) throws {
        var terminal = try #require(trackingTerminal(reporting: reporting))
        var state = TerminalInteractionState()
        shiftClick(at: 0, terminal: &terminal, state: &state)
        #expect(terminal.holdsCaret == false)

        shiftClick(at: 5, terminal: &terminal, state: &state)
        #expect(terminal.selectionRange == nil)
        #expect(terminal.selectedText == nil)
    }

    // Intent: the caret a Shift press mints still anchors its own gesture.
    // Why it exists: the caret ends at release, not at the press, so the one gesture that can
    //   still select text while the child owns the mouse has to keep working.
    @Test("a Shift drag still selects while the child owns the mouse")
    func shiftDragSelectsUnderReporting() throws {
        var terminal = try #require(trackingTerminal())
        var state = TerminalInteractionState()
        drag(from: 0, to: 5, modifiers: [.shift], terminal: &terminal, state: &state)
        #expect(terminal.selectedText == "hello")
    }

    // Intent: a plain click still leaves the caret a later Shift click selects from.
    // Why it exists: G6 records that parity with AppKit, and ending the Shift-placed caret
    //   must not end the aimed one. It is only reachable with mouse reporting off, because a
    //   plain press otherwise belongs to the child.
    @Test("a plain click leaves a caret for a later Shift click")
    func plainClickCaretOutlivesItsGesture() throws {
        var terminal = try #require(trackingTerminal(reporting: false))
        var state = TerminalInteractionState()
        click(at: 0, terminal: &terminal, state: &state)
        #expect(terminal.holdsCaret)

        shiftClick(at: 5, terminal: &terminal, state: &state)
        #expect(terminal.selectedText == "hello")
    }

    // Intent: mouse reporting turning on or off inside a gesture does not change what that
    //   gesture leaves behind.
    // Why it exists: the child can enable or disable tracking between a press and its release,
    //   so reading the mode at release would let a plain click in a shell that starts a TUI
    //   lose its caret, and a Shift gesture that outlives a TUI keep an invisible one.
    // Scenario: a click in the shell launches opencode, which enables tracking before the
    //   button comes back up.
    @Test("the press decides the caret's fate, not the release")
    func caretFateFollowsThePressAcrossAModeChange() throws {
        var starting = try #require(trackingTerminal(reporting: false))
        var startingState = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0)),
            terminal: &starting,
            state: &startingState
        )
        starting.feed(Array("\u{1B}[?1000;1006h".utf8))
        decideAndApply(
            .up(.left, cell: .init(column: 0, row: 0)),
            terminal: &starting,
            state: &startingState
        )
        #expect(starting.holdsCaret)

        var quitting = try #require(trackingTerminal())
        var quittingState = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0), modifiers: [.shift]),
            terminal: &quitting,
            state: &quittingState
        )
        quitting.feed(Array("\u{1B}[?1000;1006l".utf8))
        decideAndApply(
            .up(.left, cell: .init(column: 0, row: 0), modifiers: [.shift]),
            terminal: &quitting,
            state: &quittingState
        )
        #expect(quitting.holdsCaret == false)
    }

    // Intent: a replayed selection-owned release ends the caret a live one ends.
    // Why it exists: the caret's fate is decided from a latch the press wrote, so a replay
    //   that rebuilt its own interaction state would keep a caret the live session dropped and
    //   every later gesture in the tape would pivot differently.
    @Test("a replayed Shift click ends its caret like a live one")
    func replayedShiftClickMatchesLive() throws {
        var live = try #require(trackingTerminal())
        var liveState = TerminalInteractionState()
        shiftClick(at: 0, terminal: &live, state: &liveState)

        var replayed = try #require(trackingTerminal())
        var replayState = TerminalInteractionState()
        for action in [NeutralTerminalMouseAction.down, .up] {
            _ = applyNeutralTerminalMouse(
                .init(action: action, button: 1, column: 0, row: 0, modifiers: [.shift]),
                terminal: &replayed,
                interactionState: &replayState
            )
        }

        #expect(live.holdsCaret == false)
        #expect(replayed.holdsCaret == live.holdsCaret)
        #expect(replayed.selectionRange == live.selectionRange)
    }

    // Intent: a Shift click still extends a selection the user can see.
    // Why it exists: ending the hidden caret must not touch the visible pivot a Shift drag
    //   leaves, which is the whole of the local escape hatch under mouse reporting.
    @Test("a Shift click extends a visible selection")
    func shiftClickExtendsVisibleSelection() throws {
        var terminal = try #require(trackingTerminal())
        var state = TerminalInteractionState()
        drag(from: 0, to: 5, modifiers: [.shift], terminal: &terminal, state: &state)
        shiftClick(at: 7, terminal: &terminal, state: &state)
        #expect(terminal.selectedText == "hello w")
    }

    // Intent: while the child owns the mouse, a Shift multi-click replaces the selection with
    //   the unit under the pointer instead of extending the old one.
    // Why it exists: extension is anchored on a point a plain click placed, and under mouse
    //   reporting there is no plain click, so an extending multi-click could only ever grow a
    //   selection from wherever the last gesture ended.
    // Scenario: in opencode, Shift-double-clicking a file path while an earlier Shift drag is
    //   still highlighted should select the path, not the span up to it.
    @Test(
        "a Shift multi-click replaces the selection under mouse reporting",
        arguments: [(2, "world"), (3, "hello world")]
    )
    func shiftMultiClickReplacesSelection(clickCount: Int, expected: String) throws {
        var terminal = try #require(trackingTerminal())
        var state = TerminalInteractionState()
        drag(from: 0, to: 5, modifiers: [.shift], terminal: &terminal, state: &state)

        let release = shiftClick(
            at: 8,
            through: clickCount,
            terminal: &terminal,
            state: &state
        )
        #expect(terminal.selectedText == expected)
        // The owner materializes copy-on-select text from the gesture it is told completed,
        // so the run must end on one for the token to reach the clipboard.
        #expect(release?.completedSelectionGesture == true)
    }

    // Intent: with mouse reporting off, Shift extension stays independent of the click count.
    // Why it exists: the replacing multi-click is scoped to the mode that takes the plain
    //   click away. In a plain shell the user can still aim an anchor, and G6 keeps the
    //   AppKit extension that follows it.
    @Test("a Shift multi-click still extends in a plain shell", arguments: [1, 2, 3])
    func shiftMultiClickExtendsWithoutReporting(clickCount: Int) throws {
        var terminal = try #require(trackingTerminal(reporting: false))
        var state = TerminalInteractionState()
        drag(from: 0, to: 5, modifiers: [], terminal: &terminal, state: &state)
        #expect(terminal.selectedText == "hello")

        shiftClick(at: 8, through: clickCount, terminal: &terminal, state: &state)
        #expect(terminal.selectedText == "hello wo")
    }

    /// Builds the situation most tests here start from: text on screen and the child holding
    /// the mouse through SGR tracking, which is what a full-screen TUI enables. `reporting:
    /// false` gives the plain shell the same gestures are compared against.
    private func trackingTerminal(reporting: Bool = true) -> Terminal? {
        guard var terminal = Terminal(columns: 12, rows: 2) else { return nil }
        terminal.feed(Array("hello world".utf8))
        if reporting {
            terminal.feed(Array("\u{1B}[?1000;1006h".utf8))
        }
        return terminal
    }

    @discardableResult
    private func click(
        at column: Int,
        modifiers: TerminalKeyModifiers = [],
        clickCount: Int = 1,
        terminal: inout Terminal,
        state: inout TerminalInteractionState
    ) -> TerminalPointerDecision {
        decideAndApply(
            .down(
                .left,
                cell: .init(column: column, row: 0),
                modifiers: modifiers,
                clickCount: clickCount
            ),
            terminal: &terminal,
            state: &state
        )
        return decideAndApply(
            .up(.left, cell: .init(column: column, row: 0), modifiers: modifiers),
            terminal: &terminal,
            state: &state
        )
    }

    /// Delivers a Shift multi-click the way macOS does: every click of the run arrives as its
    /// own press and release, with the count rising. A test that sent only the last press
    /// would prove a gesture the app never sees.
    @discardableResult
    private func shiftClick(
        at column: Int,
        through clickCount: Int = 1,
        terminal: inout Terminal,
        state: inout TerminalInteractionState
    ) -> TerminalPointerDecision? {
        var last: TerminalPointerDecision?
        for count in 1...max(clickCount, 1) {
            last = click(
                at: column,
                modifiers: [.shift],
                clickCount: count,
                terminal: &terminal,
                state: &state
            )
        }
        return last
    }

    /// Runs a drag selection. With `[.shift]` it is the one gesture that can still select text
    /// while the child owns the mouse; plain, it is the shell's ordinary drag.
    private func drag(
        from startColumn: Int,
        to endColumn: Int,
        modifiers: TerminalKeyModifiers,
        terminal: inout Terminal,
        state: inout TerminalInteractionState
    ) {
        decideAndApply(
            .down(.left, cell: .init(column: startColumn, row: 0), modifiers: modifiers),
            terminal: &terminal,
            state: &state
        )
        decideAndApply(
            .move(cell: .init(column: endColumn, row: 0), modifiers: modifiers),
            terminal: &terminal,
            state: &state
        )
        decideAndApply(
            .up(.left, cell: .init(column: endColumn, row: 0), modifiers: modifiers),
            terminal: &terminal,
            state: &state
        )
    }
}
