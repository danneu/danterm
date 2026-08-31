// Pure pointer ownership, local-selection, wheel-routing, and geometry policy proofs.
import Testing

@testable import TerminalCore

/// Pins one-consumer gesture routing independently from PTY and AppKit integration.
struct TerminalInteractionPolicyTests {
    @Test("pointer down chooses Shift local capture report or uncaptured local behavior")
    func pointerRoutingMatrix() throws {
        var terminal = try #require(Terminal(columns: 12, rows: 2))

        var shifted = TerminalInteractionState()
        let shiftedResult = decideAndApply(
            .down(.left, cell: .init(column: 1, row: 0), modifiers: [.shift]),
            terminal: &terminal,
            state: &shifted
        )
        #expect(shiftedResult.consumption == .selection)
        #expect(shiftedResult.settledSelection == .caret)
        #expect(shiftedResult.inputBytes.isEmpty)

        var capturedTerminal = terminal
        capturedTerminal.feed(Array("\u{1B}[?1000;1006h".utf8))
        var captured = TerminalInteractionState()
        let capturedResult = decideAndApply(
            .down(.left, cell: .init(column: 1, row: 0)),
            terminal: &capturedTerminal,
            state: &captured
        )
        #expect(capturedResult.consumption == .report)
        #expect(capturedResult.inputBytes == Array("\u{1B}[<0;2;1M".utf8))
        #expect(capturedResult.settledSelection == .cleared)

        // A local right press has no arm: AppKit owns the pane menu and consumes the
        // gesture before the engine sees it, so shift-right under capture emits nothing.
        var shiftedRight = TerminalInteractionState()
        let shiftedRightDown = decideTerminalPointer(
            .down(.right, cell: .init(column: 2, row: 0), modifiers: [.shift]),
            terminal: capturedTerminal,
            state: &shiftedRight
        )
        #expect(shiftedRightDown.consumption == .ignored)
        #expect(shiftedRightDown.inputBytes.isEmpty)
        let shiftedRightUp = decideTerminalPointer(
            .up(.right, cell: .init(column: 2, row: 0), modifiers: [.shift]),
            terminal: capturedTerminal,
            state: &shiftedRight
        )
        #expect(shiftedRightUp.consumption == .ignored)
        #expect(shiftedRightUp.inputBytes.isEmpty)

        var uncapturedRight = TerminalInteractionState()
        #expect(decideTerminalPointer(
            .down(.right, cell: .init(column: 3, row: 1)), terminal: terminal, state: &uncapturedRight
        ).consumption == .ignored)
        #expect(decideTerminalPointer(
            .up(.right, cell: .init(column: 4, row: 1)), terminal: terminal, state: &uncapturedRight
        ).inputBytes.isEmpty)

        var middle = TerminalInteractionState()
        #expect(decideTerminalPointer(
            .down(.middle, cell: .init(column: 0, row: 0)), terminal: terminal, state: &middle
        ).consumption == .ignored)
    }

    @Test("pointer ownership stays latched when modifiers and mouse modes change")
    func pointerOwnershipLatch() throws {
        var localTerminal = try #require(Terminal(columns: 8, rows: 2))
        localTerminal.feed(Array("abcdef".utf8))
        var local = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0)), terminal: &localTerminal, state: &local
        )
        localTerminal.feed(Array("\u{1B}[?1003h".utf8))
        let redundantDown = decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0)), terminal: &localTerminal, state: &local
        )
        #expect(redundantDown.consumption == .selection)
        #expect(redundantDown.settledSelection == .unchanged)
        // Pressed at column 0's leading edge and dragged to column 3's, so the selection runs
        // from one boundary to the other and stops short of column 3's character.
        let localMove = decideTerminalPointer(
            .move(cell: .init(column: 3, row: 0), modifiers: [.alt]), terminal: localTerminal, state: &local
        )
        #expect(localMove.consumption == .selection)
        #expect(localMove.settledSelection == .selected(range(0, 0, 0, 3), granularity: .character))
        var settled = localTerminal
        settled.setSelection(range(0, 0, 0, 3))
        #expect(settled.selectedText == "abc")
        #expect(localMove.inputBytes.isEmpty)

        var reportTerminal = localTerminal
        var report = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0)), terminal: &reportTerminal, state: &report
        )
        reportTerminal.feed(Array("\u{1B}[?1003l".utf8))
        let reportMove = decideTerminalPointer(
            .move(cell: .init(column: 2, row: 0), modifiers: [.shift]), terminal: reportTerminal, state: &report
        )
        #expect(reportMove.consumption == .report)
        #expect(reportMove.settledSelection == .unchanged)
    }

    @Test("click counts cycle through character terminal-token and line units")
    func selectionGranularity() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("a.b c.d".utf8))

        let expectedMutations: [SettledSelectionOutcome] = [
            .caret,
            .selected(range(0, 0, 0, 3), granularity: .terminalToken),
            .selected(range(0, 0, 0, 7), granularity: .line),
            .caret,
            .selected(range(0, 0, 0, 3), granularity: .terminalToken),
            .selected(range(0, 0, 0, 7), granularity: .line),
        ]
        for clickCount in 1...6 {
            var state = TerminalInteractionState()
            let down = decideAndApply(
                .down(.left, cell: .init(column: 1, row: 0), clickCount: clickCount),
                terminal: &terminal,
                state: &state
            )
            #expect(down.settledSelection == expectedMutations[clickCount - 1])
        }

        // Character granularity runs boundary to boundary: pressed at column 1's leading edge
        // and dragged to column 3's, the selection is the two characters between them.
        var character = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 1, row: 0), clickCount: 4), terminal: &terminal, state: &character
        )
        #expect(decideTerminalPointer(
            .move(cell: .init(column: 3, row: 0)), terminal: terminal, state: &character
        ).settledSelection == .selected(range(0, 1, 0, 3), granularity: .character))
        var characterSettled = terminal
        characterSettled.setSelection(range(0, 1, 0, 3))
        #expect(characterSettled.selectedText == ".b")

        var terminalToken = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 1, row: 0), clickCount: 5), terminal: &terminal, state: &terminalToken
        )
        #expect(decideTerminalPointer(
            .move(cell: .init(column: 5, row: 0)), terminal: terminal, state: &terminalToken
        ).settledSelection == .selected(range(0, 0, 0, 7), granularity: .terminalToken))

        var hardLines = try #require(Terminal(columns: 8, rows: 3))
        hardLines.feed(Array("first\r\nsecond".utf8))
        var lineDrag = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 1, row: 0), clickCount: 6),
            terminal: &hardLines,
            state: &lineDrag
        )
        #expect(decideTerminalPointer(
            .move(cell: .init(column: 2, row: 1)), terminal: hardLines, state: &lineDrag
        ).settledSelection == .selected(range(0, 0, 1, 6), granularity: .line))

        #expect(decideTerminalPointer(
            .up(.left, cell: .init(column: 1, row: 0)), terminal: terminal, state: &terminalToken
        ).consumption == .selection)
    }

    @Test("line click counts select line content without its surrounding whitespace")
    func lineSelectionTrimsWhitespace() throws {
        // Intent: every click count that maps to line granularity yields the same
        //   whitespace-free line unit, in the viewport and in retained history alike.
        // Why it exists: the trimming rule lives behind the pointer path, so a wiring
        //   gap would leave triple-click selecting the line's padding.
        // Scenario: triple-clicking a padded prompt line, then the same line after it
        //   has aged into scrollback past an eviction.
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("  foo bar       ".utf8))

        for clickCount in [3, 6] {
            var state = TerminalInteractionState()
            let down = decideAndApply(
                .down(.left, cell: .init(column: 13, row: 0), clickCount: clickCount),
                terminal: &terminal,
                state: &state
            )
            #expect(down.settledSelection == .selected(range(0, 2, 0, 9), granularity: .line))
        }
        terminal.setSelection(range(0, 2, 0, 9))
        #expect(terminal.selectedText == "foo bar")

        var evicting = try #require(Terminal(
            columns: 12,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lines: 2, cells: 6, paneColumns: 12)
        ))
        evicting.feed(Array("  aa  \r\n  bb  \r\n  cc  \r\n  dd  \r\n  ee  ".utf8))
        evicting.scroll(toTopRow: 0)
        // Five hard lines fed into a two-row history budget: only four rows survive,
        // so the topmost retained line is the second one written.
        #expect(evicting.scrollProjection.totalRows == 4)

        var history = TerminalInteractionState()
        let historyDown = decideAndApply(
            .down(.left, cell: .init(column: 5, row: 0), clickCount: 3),
            terminal: &evicting,
            state: &history
        )
        #expect(historyDown.settledSelection == .selected(range(0, 2, 0, 4), granularity: .line))
        evicting.setSelection(range(0, 2, 0, 4))
        #expect(evicting.selectedText == "bb")
    }

    @Test("line dragging trims only the selection's outer edges")
    func lineDragTrimsOuterEdgesOnly() throws {
        // Intent: a multi-line line-granularity drag stays one contiguous range whose
        //   interior whitespace -- including the padding around the hard line break --
        //   survives, while its two outer edges are trimmed.
        // Why it exists: trimming each line separately would make the selection
        //   discontiguous and drop text between the drag endpoints.
        // Scenario: dragging a triple-click across two padded log lines.
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        terminal.feed(Array("  first  \r\n  second  ".utf8))

        var state = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0), clickCount: 3), terminal: &terminal, state: &state
        )
        let move = decideTerminalPointer(
            .move(cell: .init(column: 11, row: 1)), terminal: terminal, state: &state
        )

        #expect(move.settledSelection == .selected(range(0, 2, 1, 8), granularity: .line))
        terminal.setSelection(range(0, 2, 1, 8))
        #expect(terminal.selectedText == "first  \n  second")
    }

    @Test("click count never reaches an application that has captured the mouse")
    func capturedMouseIgnoresClickCount() throws {
        // Intent: under mouse capture, a high-click-count press reports exactly the
        //   bytes a single click reports, and takes the local selection away rather
        //   than settling one at any granularity.
        // Why it exists: adding a fourth granularity step made click counts above
        //   three reachable for the first time; the captured-mouse recording suite
        //   replays terminal state only and discards reported bytes, so it cannot
        //   catch a report that a new click count altered or suppressed.
        // Scenario: clicking four times in a TUI that tracks the mouse -- vim, btop --
        //   must look like four ordinary clicks to that application.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("\u{1B}[?1000;1006h".utf8))

        var single = TerminalInteractionState()
        let singleDown = decideAndApply(
            .down(.left, cell: .init(column: 1, row: 0), clickCount: 1), terminal: &terminal, state: &single
        )
        var quadruple = TerminalInteractionState()
        let quadrupleDown = decideAndApply(
            .down(.left, cell: .init(column: 1, row: 0), clickCount: 4), terminal: &terminal, state: &quadruple
        )

        #expect(singleDown.inputBytes.isEmpty == false)
        #expect(quadrupleDown.inputBytes == singleDown.inputBytes)
        #expect(quadrupleDown.consumption == .report)
        #expect(quadrupleDown.settledSelection == .cleared)
    }

    @Test("local selection maps displayed browsing rows into the current stream")
    func browsingSelectionCoordinates() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("old\r\nmid\r\nnew".utf8))
        terminal.scroll(toTopRow: 0)
        var state = TerminalInteractionState()

        let decision = decideAndApply(
            .down(.left, cell: .init(column: 1, row: 0), clickCount: 2),
            terminal: &terminal,
            state: &state
        )

        #expect(decision.settledSelection == .selected(range(0, 0, 0, 3), granularity: .terminalToken))
        #expect(terminal.scrollProjection.isFollowing == false)
    }

    @Test("a character click settles a caret and captured right clicks never open menus")
    func clickFinalization() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("text".utf8))
        terminal.setSelection(from: .init(row: 0, column: 0), to: .init(row: 0, column: 2))
        var local = TerminalInteractionState()
        #expect(decideAndApply(
            .down(.left, cell: .init(column: 2, row: 0)), terminal: &terminal, state: &local
        ).settledSelection == .caret)
        // The move lands on the same boundary the press did, so the pair is still empty and
        // still a caret -- not a present-but-empty selection that would leave Copy enabled.
        #expect(decideTerminalPointer(
            .move(cell: .init(column: 2, row: 0)), terminal: terminal, state: &local
        ).settledSelection == .caret)
        #expect(decideTerminalPointer(
            .up(.left, cell: .init(column: 2, row: 0)), terminal: terminal, state: &local
        ).settledSelection == .unchanged)

        terminal.feed(Array("\u{1B}[?1000h".utf8))
        var captured = TerminalInteractionState()
        #expect(decideTerminalPointer(
            .down(.right, cell: .init(column: 1, row: 0)), terminal: terminal, state: &captured
        ).consumption == .report)
        let up = decideTerminalPointer(
            .up(.right, cell: .init(column: 1, row: 0)), terminal: terminal, state: &captured
        )
        #expect(up.consumption == .report)
    }

    @Test("wheel priority and gesture ownership remain stable through momentum")
    func wheelPriorityAndLatch() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("\u{1B}[?1000;1006h".utf8))
        var state = TerminalInteractionState()

        let shifted = decideTerminalWheel(
            .init(rowDelta: -1, column: 2, row: 1, modifiers: [.shift], phase: .began),
            terminal: terminal,
            state: &state
        )
        #expect(shifted.route == .localViewport)
        #expect(shifted.localRowDelta == -1)
        #expect(shifted.inputBytes.isEmpty)

        let modeChanged = decideTerminalWheel(
            .init(rowDelta: -1, column: 2, row: 1, phase: .changed),
            terminal: terminal,
            state: &state
        )
        #expect(modeChanged.route == .localViewport)

        _ = decideTerminalWheel(
            .init(rowDelta: 0, column: 2, row: 1, phase: .ended),
            terminal: terminal,
            state: &state
        )
        let momentum = decideTerminalWheel(
            .init(rowDelta: -1, column: 2, row: 1, phase: .momentumChanged),
            terminal: terminal,
            state: &state
        )
        #expect(momentum.route == .localViewport)

        _ = decideTerminalWheel(
            .init(rowDelta: 0, column: 2, row: 1, phase: .momentumEnded),
            terminal: terminal,
            state: &state
        )
        let standalone = decideTerminalWheel(
            .init(rowDelta: -1, column: 2, row: 1), terminal: terminal, state: &state
        )
        #expect(standalone.route == .mouseReport)
        #expect(standalone.inputBytes == Array("\u{1B}[<64;3;2M".utf8))
    }

    @Test("wheel ownership survives Shift and mode changes in both directions")
    func wheelOwnershipAcrossStateChanges() throws {
        var reportTerminal = try #require(Terminal(columns: 8, rows: 2))
        reportTerminal.feed(Array("\u{1B}[?1000;1006h".utf8))
        var reportState = TerminalInteractionState()
        _ = decideTerminalWheel(
            .init(rowDelta: -1, column: 1, row: 0, phase: .began),
            terminal: reportTerminal,
            state: &reportState
        )
        reportTerminal.feed(Array("\u{1B}[?1000l".utf8))
        let stillReport = decideTerminalWheel(
            .init(
                rowDelta: -1,
                column: 1,
                row: 0,
                modifiers: [.shift],
                phase: .momentumChanged
            ),
            terminal: reportTerminal,
            state: &reportState
        )
        #expect(stillReport.route == .mouseReport)
        #expect(stillReport.localRowDelta == 0)

        let localTerminal = try #require(Terminal(columns: 8, rows: 2))
        var localState = TerminalInteractionState()
        _ = decideTerminalWheel(
            .init(rowDelta: -1, column: 1, row: 0, phase: .began),
            terminal: localTerminal,
            state: &localState
        )
        var newlyCaptured = localTerminal
        newlyCaptured.feed(Array("\u{1B}[?1000h".utf8))
        let stillLocal = decideTerminalWheel(
            .init(rowDelta: -1, column: 1, row: 0, phase: .changed),
            terminal: newlyCaptured,
            state: &localState
        )
        #expect(stillLocal.route == .localViewport)
        #expect(stillLocal.inputBytes.isEmpty)
    }

    @Test("wheel routes captured alternate and primary input in priority order")
    func wheelRoutes() throws {
        var capturedTerminal = try #require(Terminal(columns: 8, rows: 2))
        capturedTerminal.feed(Array("\u{1B}[?1000h".utf8))
        var captured = TerminalInteractionState()
        #expect(decideTerminalWheel(
            .init(rowDelta: 2, column: 1, row: 0), terminal: capturedTerminal, state: &captured
        ).route == .mouseReport)

        var alternate = try #require(Terminal(columns: 8, rows: 2))
        alternate.feed(Array("\u{1B}[?1049h\u{1B}[?1h".utf8))
        var alternateState = TerminalInteractionState()
        let alternateResult = decideTerminalWheel(
            .init(rowDelta: -2, column: 0, row: 0), terminal: alternate, state: &alternateState
        )
        #expect(alternateResult.route == .alternateScreen)
        #expect(alternateResult.inputBytes == Array("\u{1B}OA\u{1B}OA".utf8))

        let primary = try #require(Terminal(columns: 8, rows: 2))
        var primaryState = TerminalInteractionState()
        let primaryResult = decideTerminalWheel(
            .init(rowDelta: 2, column: 0, row: 0), terminal: primary, state: &primaryState
        )
        #expect(primaryResult.route == .localViewport)
        #expect(primaryResult.localRowDelta == 2)
    }

    @Test("captured horizontal wheel motion reports buttons 6 and 7 with per-axis remainder")
    func horizontalWheelReports() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("\u{1B}[?1000;1006h".utf8))
        var state = TerminalInteractionState()

        #expect(decideTerminalWheel(
            .init(rowDelta: 0, columnDelta: 1, column: 2, row: 1),
            terminal: terminal,
            state: &state
        ).inputBytes == Array("\u{1B}[<67;3;2M".utf8))
        #expect(decideTerminalWheel(
            .init(rowDelta: 0, columnDelta: -1, column: 2, row: 1),
            terminal: terminal,
            state: &state
        ).inputBytes == Array("\u{1B}[<66;3;2M".utf8))
        #expect(decideTerminalWheel(
            .init(rowDelta: 0, columnDelta: 0.5, column: 2, row: 1),
            terminal: terminal,
            state: &state
        ).inputBytes.isEmpty)
        #expect(decideTerminalWheel(
            .init(rowDelta: 0, columnDelta: 0.5, column: 2, row: 1),
            terminal: terminal,
            state: &state
        ).inputBytes == Array("\u{1B}[<67;3;2M".utf8))

        let uncaptured = try #require(Terminal(columns: 8, rows: 2))
        var uncapturedState = TerminalInteractionState()
        let ignored = decideTerminalWheel(
            .init(rowDelta: 0, columnDelta: 1, column: 2, row: 1),
            terminal: uncaptured,
            state: &uncapturedState
        )
        #expect(ignored.inputBytes.isEmpty)
        #expect(ignored.localRowDelta == 0)
    }

    @Test("wheel reports clamp every producer to the terminal grid")
    func wheelReportsClampToGrid() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("\u{1B}[?1000;1006h".utf8))

        var liveState = TerminalInteractionState()
        #expect(decideTerminalWheel(
            .init(rowDelta: -1, column: 100_000, row: 100_000),
            terminal: terminal,
            state: &liveState
        ).inputBytes == Array("\u{1B}[<64;8;2M".utf8))

        var replayState = TerminalInteractionState()
        #expect(decideTerminalMouseWheelReport(
            .right,
            column: -100,
            row: -100,
            terminal: terminal,
            state: &replayState
        ) == Array("\u{1B}[<67;1;1M".utf8))
    }

    @Test("off-grid pointer reports use the clamped cell supplied by the view")
    func offGridPointerReportsClampedCell() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("\u{1B}[?1000;1006h".utf8))
        var state = TerminalInteractionState()

        let decision = decideTerminalPointer(
            .down(
                .left,
                cell: .init(column: 7, row: 1, offsetX: 1, isInsideGrid: false)
            ),
            terminal: terminal,
            state: &state
        )
        #expect(decision.inputBytes == Array("\u{1B}[<0;8;2M".utf8))
    }

    @Test("alternate scroll is what turns wheel motion over the alternate screen into keys")
    func alternateScrollModeGatesTheWheel() throws {
        // Intent: mode 1007 decides whether an alternate screen's wheel reaches the child.
        // Why it exists: the route used to be unconditional, so a child that reset alternate
        //   scroll still received synthetic arrow keys it had asked not to get.
        // Scenario: a full-screen program with its own scrollback turns alternate scroll off
        //   so the user's wheel browses DanTerm's history instead of moving its cursor.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        var state = TerminalInteractionState()

        let enabled = decideTerminalWheel(
            .init(rowDelta: -2, column: 0, row: 0), terminal: terminal, state: &state
        )
        #expect(enabled.route == .alternateScreen)
        #expect(enabled.inputBytes == Array("\u{1B}[A\u{1B}[A".utf8))

        terminal.feed(Array("\u{1B}[?1007l".utf8))
        let disabled = decideTerminalWheel(
            .init(rowDelta: -2, column: 0, row: 0), terminal: terminal, state: &state
        )
        #expect(disabled.route == .localViewport)
        #expect(disabled.inputBytes.isEmpty)

        terminal.feed(Array("\u{1B}[?1007h".utf8))
        let restored = decideTerminalWheel(
            .init(rowDelta: -2, column: 0, row: 0), terminal: terminal, state: &state
        )
        #expect(restored.route == .alternateScreen)
    }

    @Test("fractional wheel rows never cross routes or action metadata")
    func wheelRemainderIsolation() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("\u{1B}[?1000;1006h".utf8))
        var state = TerminalInteractionState()

        #expect(decideTerminalWheel(
            .init(rowDelta: -0.6, column: 1, row: 0), terminal: terminal, state: &state
        ).inputBytes.isEmpty)
        #expect(decideTerminalWheel(
            .init(rowDelta: -0.6, column: 2, row: 0), terminal: terminal, state: &state
        ).inputBytes.isEmpty)
        #expect(decideTerminalWheel(
            .init(rowDelta: -0.6, column: 2, row: 0), terminal: terminal, state: &state
        ).inputBytes == Array("\u{1B}[<64;3;1M".utf8))

        #expect(decideTerminalWheel(
            .init(rowDelta: -0.6, column: 2, row: 0, modifiers: [.alt]),
            terminal: terminal,
            state: &state
        ).inputBytes.isEmpty)
        terminal.feed(Array("\u{1B}[?1006l".utf8))
        #expect(decideTerminalWheel(
            .init(rowDelta: -0.6, column: 2, row: 0, modifiers: [.alt]),
            terminal: terminal,
            state: &state
        ).inputBytes.isEmpty)

        #expect(decideTerminalWheel(
            .init(rowDelta: -0.6, column: 2, row: 0, modifiers: [.shift]),
            terminal: terminal,
            state: &state
        ).localRowDelta == 0)
        #expect(decideTerminalWheel(
            .init(rowDelta: -0.6, column: 2, row: 0, modifiers: [.shift]),
            terminal: terminal,
            state: &state
        ).localRowDelta == -1)

        var alternate = try #require(Terminal(columns: 8, rows: 2))
        alternate.feed(Array("\u{1B}[?1049h".utf8))
        var screenState = TerminalInteractionState()
        #expect(decideTerminalWheel(
            .init(rowDelta: -0.6, column: 0, row: 0, modifiers: [.shift]),
            terminal: alternate,
            state: &screenState
        ).localRowDelta == 0)
        alternate.feed(Array("\u{1B}[?1049l".utf8))
        #expect(decideTerminalWheel(
            .init(rowDelta: -0.6, column: 0, row: 0, modifiers: [.shift]),
            terminal: alternate,
            state: &screenState
        ).localRowDelta == 0)
    }

    @Test("navigation keys move the local viewport when no modifier reserves them")
    func navigationKeyRoutes() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array(scrollbackFeed.utf8))

        #expect(decideTerminalKey(.pageUp, modifiers: [], terminal: terminal)
            == .localViewport(.byRows(-4)))
        #expect(decideTerminalKey(.pageDown, modifiers: [], terminal: terminal)
            == .localViewport(.byRows(4)))
        #expect(decideTerminalKey(.home, modifiers: [], terminal: terminal)
            == .localViewport(.toTopRow(0)))
        #expect(decideTerminalKey(.end, modifiers: [], terminal: terminal)
            == .localViewport(.toBottom))

        // Command is byte-inert in the encoder, so it is the one modifier that cannot mean
        // "send the real sequence"; a Command chord the menu layer declined still scrolls.
        #expect(decideTerminalKey(.pageUp, modifiers: [.command], terminal: terminal)
            == .localViewport(.byRows(-4)))
    }

    @Test("a held modifier or the alternate screen hands every navigation key to the child")
    func navigationKeysReachTheChild() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array(scrollbackFeed.utf8))
        let navigationKeys: [TerminalInputKey] = [.pageUp, .pageDown, .home, .end]

        for key in navigationKeys {
            for modifiers: TerminalKeyModifiers in [[.shift], [.control], [.alt]] {
                #expect(decideTerminalKey(key, modifiers: modifiers, terminal: terminal) == .child)
            }
        }

        var alternate = terminal
        alternate.feed(Array("\u{1B}[?1049h".utf8))
        for key in navigationKeys {
            #expect(decideTerminalKey(key, modifiers: [], terminal: alternate) == .child)
        }
    }

    @Test("keys outside the four navigation keys always reach the child")
    func ordinaryKeysReachTheChild() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array(scrollbackFeed.utf8))
        var alternate = terminal
        alternate.feed(Array("\u{1B}[?1049h".utf8))
        let keys: [TerminalInputKey] = [.up, .down, .left, .right, .f5, .character("a")]

        for key in keys {
            #expect(decideTerminalKey(key, modifiers: [], terminal: terminal) == .child)
            #expect(decideTerminalKey(key, modifiers: [.command], terminal: terminal) == .child)
            #expect(decideTerminalKey(key, modifiers: [], terminal: alternate) == .child)
        }
    }

    @Test("a page is the current window height, so a resize changes it")
    func pageSizeTracksTheGrid() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array(scrollbackFeed.utf8))
        #expect(decideTerminalKey(.pageDown, modifiers: [], terminal: terminal)
            == .localViewport(.byRows(4)))

        terminal.resize(columns: 8, rows: 10)

        #expect(decideTerminalKey(.pageDown, modifiers: [], terminal: terminal)
            == .localViewport(.byRows(10)))
    }

    @Test("point normalization floors clamps and rejects degenerate geometry")
    func pointNormalization() {
        // The horizontal remainder is clamped with the column rather than on its own, so an
        // off-grid point reads as the edge it left through and a drag never snaps back across
        // the pointer.
        #expect(terminalCell(
            at: .init(x: 27.5, y: 39.9),
            cellSize: .init(width: 10, height: 13),
            columns: 8,
            rows: 4
        ) == .init(column: 2, row: 3, offsetX: 0.75))
        #expect(terminalCell(
            at: .init(x: -4, y: 100),
            cellSize: .init(width: 10, height: 13),
            columns: 8,
            rows: 4
        ) == .init(column: 0, row: 3, offsetX: 0, isInsideGrid: false))
        #expect(terminalCell(
            at: .init(x: 402, y: 0),
            cellSize: .init(width: 10, height: 13),
            columns: 8,
            rows: 4
        ) == .init(column: 7, row: 0, offsetX: 1, isInsideGrid: false))
        #expect(terminalCell(
            at: .init(x: 1, y: 1),
            cellSize: .init(width: 0, height: 13),
            columns: 8,
            rows: 4
        ) == nil)
        #expect(terminalCell(
            at: .init(x: .infinity, y: 1),
            cellSize: .init(width: 10, height: 13),
            columns: 8,
            rows: 4
        ) == nil)
    }

    @Test("a normalized cell reports whether its point fell inside the grid")
    func pointInsideness() {
        // Intent: `terminalCell` answers insideness for both axes independently, with the
        //   right and bottom edges excluded.
        // Why it exists: the clamped column and row cannot say whether the point was on the
        //   grid, so a caller that needs it -- link cancellation on an off-grid pointer --
        //   would otherwise re-derive the extents with its own math and drift.
        // Scenario: spec-first -- the pointer leaves an 8x4 grid of 10x13 cells through each
        //   side in turn.
        let cellSize = TerminalCellSize(width: 10, height: 13)
        func insideness(x: Double, y: Double) -> Bool? {
            terminalCell(at: .init(x: x, y: y), cellSize: cellSize, columns: 8, rows: 4)?
                .isInsideGrid
        }

        #expect(insideness(x: 27.5, y: 39.9) == true)
        #expect(insideness(x: 0, y: 0) == true)
        // Each side is left with the other axis in range, so an implementation that tests
        // only one axis cannot pass.
        #expect(insideness(x: -0.5, y: 20) == false)
        #expect(insideness(x: 80.5, y: 20) == false)
        #expect(insideness(x: 80, y: 20) == false, "the exact right edge is the first column past the grid")
        #expect(insideness(x: 30, y: -0.5) == false)
        #expect(insideness(x: 30, y: 52.5) == false)
        #expect(insideness(x: 30, y: 52) == false, "the exact bottom edge is the first row past the grid")
    }

    @Test("Cmd link ownership suppresses reports and revalidates the originating run")
    func commandLinkArmLifecycle() throws {
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("https://a.co https://a.co\u{1B}[?1003;1006h".utf8))
        var state = TerminalInteractionState()

        let down = decideTerminalPointer(
            .down(.left, cell: .init(column: 2, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(down.consumption == .link)
        #expect(down.inputBytes.isEmpty)
        applyTerminalPointerDecision(down, to: &terminal)

        let drag = decideTerminalPointer(
            .move(cell: .init(column: 5, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(drag.consumption == .link)
        #expect(drag.inputBytes.isEmpty)

        let wrongRun = decideTerminalPointer(
            .up(.left, cell: .init(column: 15, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(wrongRun.openLink == nil)
        #expect(wrongRun.hoverMutation == .clear)
        applyTerminalPointerDecision(wrongRun, to: &terminal)

        let secondDown = decideTerminalPointer(
            .down(.left, cell: .init(column: 2, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        applyTerminalPointerDecision(secondDown, to: &terminal)
        let open = decideTerminalPointer(
            .up(.left, cell: .init(column: 3, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(open.openLink?.uri == "https://a.co")
        #expect(open.inputBytes.isEmpty)
        #expect(open.hoverMutation == .clear)
    }

    @Test("Cmd link ownership wins in every mouse tracking mode")
    func commandLinkAcrossTrackingModes() throws {
        let modeSequences = ["", "\u{1B}[?1000h", "\u{1B}[?1002h", "\u{1B}[?1003h"]
        for sequence in modeSequences {
            var terminal = try #require(Terminal(columns: 16, rows: 2))
            terminal.feed(Array("https://a.co\(sequence)".utf8))
            var state = TerminalInteractionState()

            let down = decideTerminalPointer(
                .down(.left, cell: .init(column: 2, row: 0), modifiers: [.command]),
                terminal: terminal,
                state: &state
            )
            applyTerminalPointerDecision(down, to: &terminal)
            let up = decideTerminalPointer(
                .up(.left, cell: .init(column: 3, row: 0), modifiers: [.command]),
                terminal: terminal,
                state: &state
            )

            #expect(down.consumption == .link)
            #expect(down.inputBytes.isEmpty)
            #expect(up.openLink?.uri == "https://a.co")
            #expect(up.inputBytes.isEmpty)
        }
    }

    @Test("link release rejects a same-target run recreated after pointer down")
    func linkArmTracksRunIdentity() throws {
        // Intent: bind activation to the cells present at pointer down, not just URL and range.
        // Why it exists: output can recreate identical visible text before pointer release.
        // Scenario: a child overwrites one URL cell with the same scalar during a Cmd-click.
        var terminal = try #require(Terminal(columns: 16, rows: 2))
        terminal.feed(Array("https://a.co".utf8))
        var state = TerminalInteractionState()
        let down = decideTerminalPointer(
            .down(.left, cell: .init(column: 2, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        applyTerminalPointerDecision(down, to: &terminal)

        terminal.feed(Array("\u{1B}[1;1Hh".utf8))
        let release = decideTerminalPointer(
            .up(.left, cell: .init(column: 3, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )

        #expect(terminal.activatableLink(at: .init(row: 0, column: 3))?.hyperlink.uri
            == "https://a.co")
        #expect(release.openLink == nil)
    }

    @Test("link arm has move precedence over another report-owned button")
    func linkArmPrecedesReportMotion() throws {
        var terminal = try #require(Terminal(columns: 16, rows: 2))
        terminal.feed(Array("https://a.co\u{1B}[?1003;1006h".utf8))
        var state = TerminalInteractionState()

        #expect(decideTerminalPointer(
            .down(.right, cell: .init(column: 14, row: 0)), terminal: terminal, state: &state
        ).consumption == .report)
        #expect(decideTerminalPointer(
            .down(.left, cell: .init(column: 2, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        ).consumption == .link)
        let move = decideTerminalPointer(
            .move(cell: .init(column: 3, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(move.consumption == .link)
        #expect(move.inputBytes.isEmpty)
        #expect(decideTerminalPointer(
            .up(.left, cell: .init(column: 3, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        ).inputBytes.isEmpty)
    }

    @Test("Cmd moves set hover while release exit and out-of-bounds transitions clear it")
    func commandHoverAndCancellation() throws {
        var terminal = try #require(Terminal(columns: 16, rows: 2))
        terminal.feed(Array("https://a.co\u{1B}[?1003;1006h".utf8))
        var state = TerminalInteractionState()

        let hover = decideTerminalPointer(
            .move(cell: .init(column: 2, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        let resolved = try #require(terminal.activatableLink(at: .init(row: 0, column: 2)))
        #expect(hover.hoverMutation == .set(resolved))

        let clear = decideTerminalPointer(
            .move(cell: .init(column: 2, row: 0)), terminal: terminal, state: &state
        )
        #expect(clear.hoverMutation == .clear)

        _ = decideTerminalPointer(
            .down(.left, cell: .init(column: 2, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        let outside = decideTerminalPointer(
            .move(cell: .init(column: -1, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(outside.openLink == nil)
        #expect(outside.hoverMutation == .clear)
        #expect(outside.armMutation == .clear)
        applyTerminalPointerDecision(outside, to: &terminal)
        let release = decideTerminalPointer(
            .up(.left, cell: .init(column: 2, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        // The out-of-bounds move gave up link ownership in the same decision that cleared the
        // arm, so the release that follows it belongs to no arm and still opens nothing.
        #expect(release.consumption == .ignored)
        #expect(release.inputBytes.isEmpty)
        #expect(release.openLink == nil)

        #expect(cancelTerminalLinkInteraction(state: &state) == TerminalLinkCancellation(
            hoverMutation: .clear,
            armMutation: .clear
        ))
    }

    @Test("link cancellation preserves an independently report-owned button")
    func linkCancellationPreservesReportOwner() throws {
        // Intent: cancelling a link gesture clears only the button that owns that link.
        // Why it exists: pointer ownership is per button, so link cleanup must not erase a
        //   concurrent report gesture before its matching release reaches the child.
        // Scenario: a mouse-reporting application owns a held right button while Cmd-left
        //   activates a link, then the link is cancelled by an off-grid event or mouse exit.
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("https://a.co\u{1B}[?1000;1006h".utf8))
        let rightRelease = Array("\u{1B}[<2;15;1m".utf8)

        var offGridState = TerminalInteractionState()
        #expect(decideTerminalPointer(
            .down(.right, cell: .init(column: 14, row: 0)),
            terminal: terminal,
            state: &offGridState
        ).consumption == .report)
        #expect(decideTerminalPointer(
            .down(.left, cell: .init(column: 2, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &offGridState
        ).consumption == .link)
        _ = decideTerminalPointer(
            .move(cell: .init(column: 2, row: 0, isInsideGrid: false)),
            terminal: terminal,
            state: &offGridState
        )
        #expect(decideTerminalPointer(
            .up(.right, cell: .init(column: 14, row: 0)),
            terminal: terminal,
            state: &offGridState
        ).inputBytes == rightRelease)

        var explicitState = TerminalInteractionState()
        #expect(decideTerminalPointer(
            .down(.right, cell: .init(column: 14, row: 0)),
            terminal: terminal,
            state: &explicitState
        ).consumption == .report)
        #expect(decideTerminalPointer(
            .down(.left, cell: .init(column: 2, row: 0), modifiers: [.command]),
            terminal: terminal,
            state: &explicitState
        ).consumption == .link)
        _ = cancelTerminalLinkInteraction(state: &explicitState)
        #expect(decideTerminalPointer(
            .up(.right, cell: .init(column: 14, row: 0)),
            terminal: terminal,
            state: &explicitState
        ).inputBytes == rightRelease)
    }

    @Test("printing across the content-identity wrap keeps working and drops the armed link")
    func contentIdentityWrapDropsArmedLink() throws {
        // Intent: output that exhausts the per-cell content-identity counter keeps printing, and
        //   any link armed before the wrap is dropped rather than carried across it.
        // Why it exists: `research/15/H4` narrowed `contentIdentity` to 32 bits to take `GridCell`
        //   from 56 bytes to 48, and the counter issues one identity per printed cell -- so 2^32
        //   is a few minutes of maximal output, not a theoretical bound. A counter that simply
        //   increments traps on overflow, and one that simply wraps starts reissuing identities
        //   that an arm taken before the wrap would accept as its own.
        // Scenario: a long-running pane prints past the counter's range while the user is holding
        //   Cmd on a URL.
        var terminal = try #require(Terminal(columns: 16, rows: 2))
        terminal.feed(Array("https://a.co".utf8))
        let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 3)))
        let armed = terminal.setArmedLink(link)
        #expect(armed)

        terminal.primeContentIdentityWrapForTesting()
        terminal.feed(Array("\u{1B}[2;1Hx".utf8))

        #expect(terminal.armedLink == nil)
        #expect(terminal.fullHistoryText.hasSuffix("x"))

        // Printing past the wrap still produces armable runs.
        terminal.feed(Array("\u{1B}[2;1H\u{1B}[Khttps://b.co".utf8))
        let reprinted = try #require(terminal.activatableLink(at: .init(row: 1, column: 3)))
        let rearmed = terminal.setArmedLink(reprinted)
        #expect(rearmed)
        #expect(reprinted.matchesActivation(try #require(terminal.armedLink)))
    }

    @Test("a held drag anchor stays on its text across repeated evictions")
    func dragAnchorSurvivesRepeatedEvictions() throws {
        // Intent: while the button is held, the anchored end of a drag keeps naming the
        //   text it was placed on, however many rows eviction retires beneath it.
        // Why it exists: the anchor was captured as a projection-local range, which counts
        //   from the oldest *retained* row, so every evicted row silently restated it and
        //   the fixed end walked one row downward per eviction.
        // Scenario: the reported incident -- a pane scrolled up with output streaming into
        //   a saturated scrollback, where pressing and nudging the pointer showed the
        //   selection's far edge eight rows below where it was placed.
        var terminal = try #require(Terminal(
            columns: 12,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lines: 6, cells: 3)
        ))
        terminal.feed(Array("r01\r\nr02\r\nr03\r\nr04\r\nr05\r\nr06\r\nr07\r\nr08".utf8))
        terminal.scroll(toTopRow: 2)

        var state = TerminalInteractionState()
        let down = decideAndApply(
            .down(.left, cell: .init(column: 0, row: 1), clickCount: 3), terminal: &terminal, state: &state
        )
        #expect(down.settledSelection == .selected(range(3, 0, 3, 3), granularity: .line))

        // Two separate bursts, so a one-shot rebase at the first eviction cannot pass.
        for burst in 1...2 {
            terminal.feed(Array("\r\nr0\(8 + burst)".utf8))
            let anchoredRow = 3 - burst
            let held = decideTerminalPointer(
                .move(cell: .init(column: 0, row: 1)), terminal: terminal, state: &state
            )
            #expect(held.settledSelection == .selected(
                range(anchoredRow, 0, anchoredRow, 3),
                granularity: .line
            ))
            var settled = terminal
            settled.setSelection(range(anchoredRow, 0, anchoredRow, 3))
            #expect(settled.selectedText == "r04")
        }
    }

    @Test("a drag's moving end tracks the pointed text while following and while browsing")
    func dragMovingEndTracksPointedText() throws {
        // Intent: the endpoint under the pointer names the text under the pointer, in a
        //   bottom-following viewport and in a scrolled-up browsing one alike.
        // Why it exists: this is the premise that lets the eviction fix target only the
        //   anchored end. It was unpinned, so a regression here would look like the
        //   anchor bug returning.
        var following = try #require(Terminal(columns: 12, rows: 2))
        following.feed(Array("abc def\r\nghi jkl".utf8))
        var followingState = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0)), terminal: &following, state: &followingState
        )
        // Past the midpoint of column 2, so the character under the pointer is included.
        let followingMove = decideTerminalPointer(
            .move(cell: .init(column: 2, row: 1, offsetX: 0.6)), terminal: following, state: &followingState
        )
        #expect(followingMove.settledSelection == .selected(range(0, 0, 1, 3), granularity: .character))
        following.setSelection(range(0, 0, 1, 3))
        #expect(following.selectedText == "abc def\nghi")

        var browsing = try #require(Terminal(
            columns: 12,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lines: 6, cells: 12)
        ))
        browsing.feed(Array("r01\r\nr02\r\nr03\r\nr04\r\nr05\r\nr06\r\nr07\r\nr08".utf8))
        browsing.scroll(toTopRow: 2)
        var browsingState = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0)), terminal: &browsing, state: &browsingState
        )
        let browsingMove = decideTerminalPointer(
            .move(cell: .init(column: 2, row: 1, offsetX: 0.6)), terminal: browsing, state: &browsingState
        )
        #expect(browsingMove.settledSelection == .selected(range(2, 0, 3, 3), granularity: .character))
        browsing.setSelection(range(2, 0, 3, 3))
        #expect(browsing.selectedText == "r03\nr04")
    }

    @Test("a partially evicted drag anchor clamps forward and keeps extending")
    func dragAnchorClampsWhenPartiallyEvicted() throws {
        // Intent: when eviction retires part of the anchored unit, the anchored edge moves
        //   forward to the oldest retained row and the drag goes on extending from there.
        // Why it exists: this is the rule a settled selection already follows, and the
        //   anchor must not invent a second one -- dropping the drag or resolving against
        //   rows that no longer exist would both be visible as a dead or jumping gesture.
        // Scenario: triple-clicking a soft-wrapped line at the top of history while output
        //   streams in, until the line's first visual row is evicted.
        var terminal = try #require(Terminal(
            columns: 4,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lineCells: [8, 2, 2], paneColumns: 4)
        ))
        terminal.feed(Array("xx\r\naaaabbbb\r\nyy\r\nzz".utf8))
        terminal.scroll(toTopRow: 0)

        var state = TerminalInteractionState()
        let down = decideAndApply(
            .down(.left, cell: .init(column: 0, row: 1), clickCount: 3), terminal: &terminal, state: &state
        )
        #expect(down.settledSelection == .selected(range(1, 0, 2, 4), granularity: .line))

        terminal.feed(Array("\r\nww\r\nvv".utf8))
        let move = decideTerminalPointer(
            .move(cell: .init(column: 0, row: 1)), terminal: terminal, state: &state
        )

        #expect(move.settledSelection == .selected(range(0, 0, 1, 2), granularity: .line))
        terminal.setSelection(range(0, 0, 1, 2))
        #expect(terminal.selectedText == "bbbb\nyy")
    }

    @Test("reversing a token drag across the anchor restores the whole anchored token")
    func tokenDragReversalPreservesAnchoredUnit() throws {
        // Intent: after an eviction, dragging back past the anchored token still puts that
        //   whole token at the selection's far edge.
        // Why it exists: the anchor is a unit, not a boundary. Deriving it from the live
        //   selection cannot restore the far boundary a direction flip has consumed, so
        //   this pins the whole-unit property the pinned anchor exists to keep.
        var terminal = try #require(Terminal(
            columns: 20,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lineCells: [4, 4, 13, 2, 2, 2])
        ))
        terminal.feed(Array("top1\r\ntop2\r\none two three\r\nf1\r\nf2".utf8))
        terminal.scroll(toTopRow: 2)

        var state = TerminalInteractionState()
        let down = decideAndApply(
            .down(.left, cell: .init(column: 4, row: 0), clickCount: 2), terminal: &terminal, state: &state
        )
        #expect(down.settledSelection == .selected(range(2, 4, 2, 7), granularity: .terminalToken))
        let forward = decideTerminalPointer(
            .move(cell: .init(column: 9, row: 0)), terminal: terminal, state: &state
        )
        #expect(forward.settledSelection == .selected(range(2, 4, 2, 13), granularity: .terminalToken))

        // Four more lines rather than two: the byte bound evicts a whole logical line at a
        // time now, so the feed has to be long enough for one to go.
        terminal.feed(Array("\r\nf3\r\nf4\r\nf5\r\nf6".utf8))
        let reversed = decideTerminalPointer(
            .move(cell: .init(column: 1, row: 0)), terminal: terminal, state: &state
        )

        #expect(reversed.settledSelection == .selected(range(1, 0, 1, 7), granularity: .terminalToken))
        terminal.setSelection(range(1, 0, 1, 7))
        #expect(terminal.selectedText == "one two")
    }

    @Test("a press that never moves selects nothing even after eviction")
    func unmovedCharacterPressSelectsNothingAcrossEviction() throws {
        // Intent: a character press whose pointer never crosses a character midpoint leaves no
        //   selection present, and eviction beneath the pointer does not count as crossing one.
        // Why it exists: the press boundary is re-derived from the pinned anchor on every move.
        //   A drifting anchor would move it for free, so eviction alone would turn a plain
        //   click into a selection of text the user never dragged over.
        var terminal = try #require(Terminal(
            columns: 12,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lines: 6, cells: 3)
        ))
        terminal.feed(Array("r01\r\nr02\r\nr03\r\nr04\r\nr05\r\nr06\r\nr07\r\nr08".utf8))
        terminal.scroll(toTopRow: 2)

        var state = TerminalInteractionState()
        #expect(decideAndApply(
            .down(.left, cell: .init(column: 1, row: 1)), terminal: &terminal, state: &state
        ).settledSelection == .caret)

        terminal.feed(Array("\r\nr09".utf8))
        // Asserted as the absence of a selection, not as empty selected text: a present but
        // empty selection is exactly the state this test exists to exclude.
        #expect(decideTerminalPointer(
            .move(cell: .init(column: 1, row: 1)), terminal: terminal, state: &state
        ).settledSelection == .caret)

        let extended = decideTerminalPointer(
            .move(cell: .init(column: 2, row: 1)), terminal: terminal, state: &state
        )
        #expect(extended.settledSelection == .selected(range(2, 1, 2, 2), granularity: .character))
        terminal.setSelection(range(2, 1, 2, 2))
        #expect(terminal.selectedText == "0")
    }

    @Test("a pointer position resolves to a whole character's nearer outer boundary")
    func characterBoundariesSnapAcrossTheWholeCharacter() throws {
        // Intent: every position inside a character resolves to one of the two boundaries
        //   around it, choosing by distance across the character's full width -- so a
        //   double-width character snaps at its visual center, not at either cell's.
        // Why it exists: measuring within each cell separately would put a boundary in the
        //   middle of a wide character, which is a position no selection can name.
        var terminal = try #require(Terminal(columns: 12, rows: 2))
        terminal.feed(Array("a\u{6F22}b".utf8))

        // The wide character owns columns 1 and 2; its boundaries are 1 and 3.
        let wideProbes: [(Int, Double, Int)] = [
            (1, 0.0, 1), (1, 0.4, 1), (1, 0.9, 1),
            (2, 0.0, 3), (2, 0.5, 3), (2, 0.9, 3),
        ]
        for (column, offsetX, expected) in wideProbes {
            let boundary = terminal.characterBoundary(
                at: .init(row: 0, column: column),
                offsetX: offsetX
            )
            #expect(boundary == .init(row: 0, column: expected), "column \(column) @ \(offsetX)")
        }

        // A narrow character snaps at its own midpoint, which belongs to the boundary after it.
        #expect(terminal.characterBoundary(at: .init(row: 0, column: 0), offsetX: 0.49)
            == .init(row: 0, column: 0))
        #expect(terminal.characterBoundary(at: .init(row: 0, column: 0), offsetX: 0.5)
            == .init(row: 0, column: 1))
    }

    @Test("a drag inside one cell selects that one character once it crosses the midpoint")
    func singleCharacterDragSelectsOneCharacter() throws {
        // Intent: the smallest reachable drag selects exactly one character, without leaving
        //   the cell it started in.
        // Why it exists: the reported symptom. A whole-cell union of the pressed and pointed
        //   cells always spans both, so its smallest non-empty result was two characters and a
        //   drag confined to one cell selected nothing at all.
        var terminal = try #require(Terminal(columns: 12, rows: 2))
        terminal.feed(Array("abcdef".utf8))

        var state = TerminalInteractionState()
        #expect(decideAndApply(
            .down(.left, cell: .init(column: 2, row: 0, offsetX: 0.1)), terminal: &terminal, state: &state
        ).settledSelection == .caret)
        let crossed = decideTerminalPointer(
            .move(cell: .init(column: 2, row: 0, offsetX: 0.9)), terminal: terminal, state: &state
        )

        #expect(crossed.settledSelection == .selected(range(0, 2, 0, 3), granularity: .character))
        terminal.setSelection(range(0, 2, 0, 3))
        #expect(terminal.selectedText == "c")
    }

    @Test("a character drag grows shrinks and reverses symmetrically, including across a wrap")
    func characterDragExtendsAndShrinksInBothDirections() throws {
        // Intent: the selection is the ordered pair of the press boundary and the current one,
        //   so dragging further grows it, dragging back shortens it, and dragging past the
        //   press point selects on the other side -- within a row and across a soft wrap alike.
        // Why it exists: a union of two whole-cell ranges can only ever grow, so reversing and
        //   shrinking were both unreachable; and the two spellings of a wrap seam are one
        //   visual position, which a boundary comparison has to agree about.
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("abcdefgh".utf8))
        #expect(terminal.characterRange(at: .init(row: 0, column: 3)) == range(0, 3, 0, 4))

        var state = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 1, row: 0, offsetX: 0.1)), terminal: &terminal, state: &state
        )

        let gestures: [(String, Int, Int, Double, TerminalTextRange, String)] = [
            ("extended into the wrapped row", 1, 1, 0.9, range(0, 1, 1, 2), "bcdef"),
            ("shrunk back toward the press", 0, 1, 0.9, range(0, 1, 0, 2), "b"),
            ("reversed past the press", 0, 0, 0.1, range(0, 0, 0, 1), "a"),
        ]
        for (label, row, column, offsetX, expected, text) in gestures {
            let moved = decideTerminalPointer(
                .move(cell: .init(column: column, row: row, offsetX: offsetX)),
                terminal: terminal,
                state: &state
            )
            #expect(moved.settledSelection == .selected(expected, granularity: .character), "\(label)")
            var settled = terminal
            settled.setSelection(expected)
            #expect(settled.selectedText == text, "\(label)")
        }

        // The seam itself: the trailing boundary of row 0's last column and the leading
        // boundary of row 1's first name one position, so a drag between them selects nothing.
        var seam = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 3, row: 0, offsetX: 0.9)), terminal: &terminal, state: &seam
        )
        #expect(decideTerminalPointer(
            .move(cell: .init(column: 0, row: 1, offsetX: 0.1)), terminal: terminal, state: &seam
        ).settledSelection == .caret)
    }

    @Test("a drag leaving the grid selects out to the edge it left through")
    func offGridDragSelectsToTheEdgeItLeftThrough() throws {
        // Intent: normalization clamps the horizontal position together with the column, so a
        //   pointer dragged off the right edge keeps selecting through the last character
        //   instead of snapping back to the boundary before it.
        // Why it exists: clamping the column while leaving the offset at its raw value would
        //   put the resolved boundary on the wrong side of the last character -- the selection
        //   would visibly retreat across the pointer at the moment it left the grid.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("wxyz".utf8))
        let offGrid = try #require(terminalCell(
            at: .init(x: 97, y: 1),
            cellSize: .init(width: 10, height: 13),
            columns: 4,
            rows: 2
        ))

        var state = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 2, row: 0, offsetX: 0.1)), terminal: &terminal, state: &state
        )
        let dragged = decideTerminalPointer(
            .move(cell: .init(column: offGrid.column, row: offGrid.row, offsetX: offGrid.offsetX)),
            terminal: terminal,
            state: &state
        )

        #expect(dragged.settledSelection == .selected(range(0, 2, 0, 4), granularity: .character))
        terminal.setSelection(range(0, 2, 0, 4))
        #expect(terminal.selectedText == "yz")
    }

    @Test("settling a selection unit and reading its anchor back reproduces it exactly")
    func settledAnchorRoundTripsEverySelectionUnit() throws {
        // Intent: settle-then-read is the identity on every unit a pointer gesture can anchor
        //   on, including the boundary shapes -- a wide cell, a hard line end, and a line that
        //   trims to nothing.
        // Why it exists: every drag sample and every Shift press reads the anchor unit back
        //   off the terminal and pivots on it. An anchor that came back with a boundary
        //   shifted by one column would misplace all of them silently.
        var fed = try #require(Terminal(columns: 12, rows: 3))
        fed.feed(Array("a\u{6F22}b cd\r\n\r\nlast".utf8))

        let wideCell = fed.characterRange(at: .init(row: 0, column: 1))
        let wideTail = fed.characterRange(at: .init(row: 0, column: 2))
        let token = fed.terminalTokenRange(at: .init(row: 0, column: 0))
        let separator = fed.terminalTokenRange(at: .init(row: 0, column: 4))
        let line = fed.trimmedLogicalLineRange(at: .init(row: 0, column: 0))
        let blankLine = fed.trimmedLogicalLineRange(at: .init(row: 1, column: 0))
        let lineEnd = fed.characterRange(at: .init(row: 2, column: 3))
        let lastLine = fed.trimmedLogicalLineRange(at: .init(row: 2, column: 0))

        // Anchoring the round trip: a unit that came back degenerate would round trip
        // trivially, so pin what these units actually are.
        #expect(wideCell == range(0, 1, 0, 3))
        #expect(wideTail == wideCell)
        #expect(token == range(0, 0, 0, 4))
        #expect(line == range(0, 0, 0, 7))
        #expect(blankLine == range(1, 0, 1, 0))
        #expect(lineEnd == range(2, 3, 2, 4))

        let units: [(String, TerminalTextRange)] = [
            ("wide cell", wideCell),
            ("wide tail", wideTail),
            ("token", token),
            ("separator run", separator),
            ("trimmed line", line),
            ("blank line", blankLine),
            ("hard line end", lineEnd),
            ("last line", lastLine),
        ]
        for (label, unit) in units {
            var settled = fed
            settled.setSelection(anchorUnit: unit, focus: unit.end, granularity: .character)
            #expect(settled.selectionAnchorUnit == unit, "\(label)")
        }
    }

    @Test("a hard reset and a screen replacement each stop a held drag")
    func droppingTheSelectionStopsTheDrag() throws {
        // Intent: after an event the selection cannot survive, a held drag stops extending
        //   instead of pivoting on an anchor that no longer names the text it named.
        // Why it exists: the anchor is the settled selection, and a hard reset returns the
        //   eviction count to zero while a screen swap puts a different grid under the same
        //   rows. Either one left with an anchor would read as the selection jumping to text
        //   the user never touched.
        // Note: a width reflow belongs to the other list -- the selection is restated across
        //   it and the drag keeps going, which is `dragSurvivesEventsTheSelectionSurvives`.
        let drops: [(String, (inout Terminal) -> Void)] = [
            ("hard reset", { $0.feed(Array("\u{1b}c".utf8)) }),
            ("screen replacement", { $0.feed(Array("\u{1b}[?1049h".utf8)) }),
        ]
        for (label, renumber) in drops {
            var terminal = try #require(Terminal(columns: 12, rows: 3))
            terminal.feed(Array("one two\r\nthree\r\nfour".utf8))

            var state = TerminalInteractionState()
            let down = decideAndApply(
                .down(.left, cell: .init(column: 0, row: 0), clickCount: 2), terminal: &terminal, state: &state
            )
            #expect(
                down.settledSelection == .selected(range(0, 0, 0, 3), granularity: .terminalToken),
                "\(label)"
            )

            renumber(&terminal)
            let moved = decideTerminalPointer(
                .move(cell: .init(column: 4, row: 0)), terminal: terminal, state: &state
            )

            #expect(moved.settledSelection == .unchanged, "\(label)")
            // The gesture is over as a selection, not as input: the button stays
            // selection-owned so its release cannot send bytes to the child.
            #expect(moved.consumption == .selection, "\(label)")
            #expect(moved.inputBytes.isEmpty, "\(label)")
        }
    }

    @Test("a drag keeps extending across every event its selection survives")
    func dragSurvivesEventsTheSelectionSurvives() throws {
        // Intent: a drag stops only where the selection itself is dropped. A taller viewport,
        //   a soft reset on the primary screen, and a width reflow all keep the selection, so
        //   all three keep the drag alive.
        // Why it exists: the cheap way to satisfy the stop rule is to invalidate on anything
        //   that smells structural, which would kill live drags during an ordinary window
        //   resize or a shell's prompt-time DECSTR. The reflow leg is the newer half: the
        //   anchor is restated onto the same logical content rather than retired.
        let preservations: [(String, (inout Terminal) -> Void)] = [
            ("height-only resize", { $0.resize(columns: 12, rows: 4) }),
            ("primary-screen soft reset", { $0.feed(Array("\u{1b}[!p".utf8)) }),
            ("width reflow", { $0.resize(columns: 10, rows: 3) }),
        ]
        for (label, preserve) in preservations {
            var terminal = try #require(Terminal(columns: 12, rows: 3))
            terminal.feed(Array("one two\r\nthree\r\nfour".utf8))

            var state = TerminalInteractionState()
            let down = decideAndApply(
                .down(.left, cell: .init(column: 0, row: 0), clickCount: 2), terminal: &terminal, state: &state
            )
            #expect(
                down.settledSelection == .selected(range(0, 0, 0, 3), granularity: .terminalToken),
                "\(label)"
            )

            preserve(&terminal)
            let moved = decideTerminalPointer(
                .move(cell: .init(column: 4, row: 0)), terminal: terminal, state: &state
            )

            #expect(
                moved.settledSelection == .selected(range(0, 0, 0, 7), granularity: .terminalToken),
                "\(label)"
            )
            var settled = terminal
            settled.setSelection(range(0, 0, 0, 7))
            #expect(settled.selectedText == "one two", "\(label)")
        }
    }

    @Test("an alternate-screen soft reset leaves a held drag extending")
    func alternateSoftResetKeepsTheDragExtending() throws {
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        terminal.feed(Array("\u{1b}[?1049hone two\r\nthree".utf8))

        var state = TerminalInteractionState()
        let down = decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0), clickCount: 2), terminal: &terminal, state: &state
        )
        #expect(down.settledSelection == .selected(range(0, 0, 0, 3), granularity: .terminalToken))

        terminal.feed(Array("\u{1b}[!p".utf8))
        let moved = decideTerminalPointer(
            .move(cell: .init(column: 4, row: 0)), terminal: terminal, state: &state
        )

        #expect(moved.settledSelection == .selected(range(0, 0, 0, 7), granularity: .terminalToken))
    }

    @Test("leaving the alternate screen by mode reset stops a held drag")
    func leavingTheAlternateScreenStopsTheDrag() throws {
        // Intent: putting the primary screen back underneath a drag anchored on the
        //   alternate one stops it.
        // Why it exists: the mode reset replaces the projection and invalidates the anchor.
        let exits = [("mode reset", "\u{1b}[?1049l")]
        for (label, exit) in exits {
            var terminal = try #require(Terminal(columns: 12, rows: 3))
            terminal.feed(Array("\u{1b}[?1049hone two\r\nthree".utf8))

            var state = TerminalInteractionState()
            let down = decideAndApply(
                .down(.left, cell: .init(column: 0, row: 0), clickCount: 2), terminal: &terminal, state: &state
            )
            #expect(
                down.settledSelection == .selected(range(0, 0, 0, 3), granularity: .terminalToken),
                "\(label)"
            )

            terminal.feed(Array(exit.utf8))
            let moved = decideTerminalPointer(
                .move(cell: .init(column: 4, row: 0)), terminal: terminal, state: &state
            )

            #expect(moved.settledSelection == .unchanged, "\(label)")
            #expect(moved.consumption == .selection, "\(label)")
        }
    }

    @Test("clearing the scrollback drops a scrollback anchor and keeps a viewport one")
    func clearingScrollbackDropsOnlyTheScrollbackAnchor() throws {
        // Intent: erasing the scrollback retires an anchor that lived in it and renumbers --
        //   without invalidating -- one that lived in the viewport.
        // Why it exists: a wholesale scrollback erase is the largest eviction a terminal can
        //   perform. Treating it as a renumbering event would kill drags anchored on text
        //   that is still on screen; treating it as nothing would resolve a dropped anchor
        //   against rows that no longer exist.
        var scrollbackHeld = try #require(Terminal(columns: 12, rows: 2))
        scrollbackHeld.feed(Array("s01\r\ns02\r\nv01 xy\r\nv02".utf8))
        scrollbackHeld.scroll(toTopRow: 0)

        var scrollbackState = TerminalInteractionState()
        let scrollbackDown = decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0), clickCount: 2),
            terminal: &scrollbackHeld,
            state: &scrollbackState
        )
        #expect(scrollbackDown.settledSelection == .selected(range(0, 0, 0, 3), granularity: .terminalToken))

        scrollbackHeld.feed(Array("\u{1b}[3J".utf8))
        #expect(decideTerminalPointer(
            .move(cell: .init(column: 4, row: 0)), terminal: scrollbackHeld, state: &scrollbackState
        ).settledSelection == .unchanged)

        var viewportHeld = try #require(Terminal(columns: 12, rows: 2))
        viewportHeld.feed(Array("s01\r\ns02\r\nv01 xy\r\nv02".utf8))

        var viewportState = TerminalInteractionState()
        let viewportDown = decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0), clickCount: 2),
            terminal: &viewportHeld,
            state: &viewportState
        )
        #expect(viewportDown.settledSelection == .selected(range(2, 0, 2, 3), granularity: .terminalToken))

        viewportHeld.feed(Array("\u{1b}[3J".utf8))
        let extended = decideTerminalPointer(
            .move(cell: .init(column: 4, row: 0)), terminal: viewportHeld, state: &viewportState
        )

        #expect(extended.settledSelection == .selected(range(0, 0, 0, 6), granularity: .terminalToken))
        viewportHeld.setSelection(range(0, 0, 0, 6))
        #expect(viewportHeld.selectedText == "v01 xy")
    }

    @Test("rewriting the anchored cells in place leaves the drag extending from that position")
    func rewritingAnchoredCellsKeepsTheDragExtending() throws {
        // Intent: output that overwrites the anchored text without moving any row keeps the
        //   drag alive, anchored at the same position and now covering the new text.
        // Why it exists: the pinned drag anchor and settled selection now share the same
        //   position-over-content rule; the policy layer must keep extending from that position.
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        terminal.feed(Array("one two\r\nthree\r\nfour".utf8))

        var state = TerminalInteractionState()
        let down = decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0), clickCount: 2), terminal: &terminal, state: &state
        )
        #expect(down.settledSelection == .selected(range(0, 0, 0, 3), granularity: .terminalToken))

        terminal.feed(Array("\u{1b}[1;1Hzzz".utf8))
        let moved = decideTerminalPointer(
            .move(cell: .init(column: 5, row: 0)), terminal: terminal, state: &state
        )

        #expect(moved.settledSelection == .selected(range(0, 0, 0, 7), granularity: .terminalToken))
        terminal.setSelection(range(0, 0, 0, 7))
        #expect(terminal.selectedText == "zzz two")
    }

    @Test("a held drag selection is present across interleaved repaints and pointer moves")
    func heldDragSelectionNeverFlickersAcrossRepaints() throws {
        // Intent: while the left button remains down, every observation between pointer
        //   movement and child repaint sees a live selection.
        // Why it exists: an end-state assertion misses the clear-and-restore alternation that
        //   made selections flicker at a TUI's frame rate.
        // Scenario: the user drags across a row while a TUI rewrites that same row twice.
        var terminal = try #require(Terminal(columns: 12, rows: 2))
        terminal.feed(Array("one two".utf8))
        var state = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0)), terminal: &terminal, state: &state
        )

        let firstMove = decideTerminalPointer(
            .move(cell: .init(column: 2, row: 0)), terminal: terminal, state: &state
        )
        #expect(firstMove.settledSelection != .unchanged, "first pointer move did not set a selection")
        applyTerminalPointerDecision(firstMove, to: &terminal)
        #expect(terminal.selectionRange != nil)

        terminal.feed(Array("\u{1B}[1;1HTWO".utf8))
        #expect(terminal.selectionRange != nil)

        let secondMove = decideTerminalPointer(
            .move(cell: .init(column: 6, row: 0)), terminal: terminal, state: &state
        )
        #expect(secondMove.settledSelection != .unchanged, "second pointer move did not set a selection")
        applyTerminalPointerDecision(secondMove, to: &terminal)
        #expect(terminal.selectionRange != nil)

        terminal.feed(Array("\u{1B}[1;1Hone".utf8))
        #expect(terminal.selectionRange != nil)
    }

    @Test("only a selection-owned release reports a completed selection gesture")
    func selectionGestureCompletionOwnership() throws {
        // Intent: the release of every local selection gesture -- drag, double-click word,
        //   triple-click line, and Shift-drag under mouse reporting -- reports completion,
        //   while a release any other arm owned reports none.
        // Why it exists: eligibility for copy-on-select is pointer ownership and nothing
        //   else. If the flag leaked onto a consumed release, a click inside a
        //   mouse-reporting application would overwrite the user's clipboard.
        var terminal = try #require(Terminal(columns: 12, rows: 2))
        terminal.feed(Array("alpha beta".utf8))

        for clickCount in 1...3 {
            var state = TerminalInteractionState()
            decideAndApply(
                .down(.left, cell: .init(column: 0, row: 0), clickCount: clickCount),
                terminal: &terminal,
                state: &state
            )
            _ = decideTerminalPointer(
                .move(cell: .init(column: 4, row: 0)), terminal: terminal, state: &state
            )
            let release = decideTerminalPointer(
                .up(.left, cell: .init(column: 4, row: 0)), terminal: terminal, state: &state
            )
            #expect(release.consumption == .selection, "click count \(clickCount)")
            #expect(release.completedSelectionGesture, "click count \(clickCount)")
        }

        var reporting = terminal
        reporting.feed(Array("\u{1B}[?1000;1006h".utf8))

        var shiftDrag = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0), modifiers: [.shift]),
            terminal: &reporting,
            state: &shiftDrag
        )
        let shiftRelease = decideTerminalPointer(
            .up(.left, cell: .init(column: 4, row: 0), modifiers: [.shift]),
            terminal: reporting,
            state: &shiftDrag
        )
        #expect(shiftRelease.consumption == .selection)
        #expect(shiftRelease.completedSelectionGesture)

        var reported = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 0, row: 0)), terminal: &reporting, state: &reported
        )
        let reportedRelease = decideTerminalPointer(
            .up(.left, cell: .init(column: 4, row: 0)), terminal: reporting, state: &reported
        )
        #expect(reportedRelease.consumption == .report)
        #expect(reportedRelease.completedSelectionGesture == false)

        var menu = TerminalInteractionState()
        _ = decideTerminalPointer(
            .down(.right, cell: .init(column: 0, row: 0)), terminal: terminal, state: &menu
        )
        #expect(decideTerminalPointer(
            .up(.right, cell: .init(column: 0, row: 0)), terminal: terminal, state: &menu
        ).completedSelectionGesture == false)

        var linked = try #require(Terminal(columns: 24, rows: 2))
        linked.feed(Array("\u{1B}]8;;https://a.co\u{7}link\u{1B}]8;;\u{7}".utf8))
        var link = TerminalInteractionState()
        let linkDown = decideTerminalPointer(
            .down(.left, cell: .init(column: 1, row: 0), modifiers: [.command]),
            terminal: linked,
            state: &link
        )
        #expect(linkDown.consumption == .link)
        applyTerminalPointerDecision(linkDown, to: &linked)
        let linkRelease = decideTerminalPointer(
            .up(.left, cell: .init(column: 1, row: 0), modifiers: [.command]),
            terminal: linked,
            state: &link
        )
        #expect(linkRelease.consumption == .link)
        #expect(linkRelease.completedSelectionGesture == false)

        var ignored = TerminalInteractionState()
        _ = decideTerminalPointer(
            .down(.middle, cell: .init(column: 0, row: 0)), terminal: terminal, state: &ignored
        )
        #expect(decideTerminalPointer(
            .up(.middle, cell: .init(column: 0, row: 0)), terminal: terminal, state: &ignored
        ).completedSelectionGesture == false)
    }

    @Test("a multi-click press on a blank pane still settles a copyable empty selection")
    func blankPaneMultiClickKeepsAnEmptySelection() throws {
        // Intent: a token or line press that finds no text settles a present, empty selection
        //   -- Copy stays enabled -- while the single click beside it settles the caret and
        //   leaves Copy disabled.
        // Why it exists: the caret and this are both empty pairs, and the only thing telling
        //   them apart is the unit the press was made at. Collapsing the two would either
        //   enable Copy on every click or break selecting blank cells.
        // Scenario: a user double-clicks, then triple-clicks, in an empty pane.
        for granularity in [2, 3] {
            var terminal = try #require(Terminal(columns: 8, rows: 2))
            var state = TerminalInteractionState()
            decideAndApply(
                .down(.left, cell: .init(column: 3, row: 0), clickCount: granularity),
                terminal: &terminal,
                state: &state
            )
            #expect(terminal.selectionRange != nil, "click count \(granularity)")
            #expect(terminal.selectedText == "", "click count \(granularity)")

            var single = TerminalInteractionState()
            decideAndApply(
                .down(.left, cell: .init(column: 3, row: 0), clickCount: 1),
                terminal: &terminal,
                state: &single
            )
            #expect(terminal.selectionRange == nil, "click count \(granularity)")
            #expect(terminal.selectedText == nil, "click count \(granularity)")
        }
    }

    @Test("Shift-click pivots on the anchor wherever it lands")
    func shiftClickPivotsOnTheSettledAnchor() throws {
        // Intent: a Shift press selects anchor-to-click and nothing else -- before the
        //   selection, inside it, on the anchor itself, and past it -- and the drag it starts
        //   keeps pivoting on that same anchor across the anchor and back.
        // Why it exists: DanTerm used to pin whichever endpoint was farther from the click,
        //   which grows the selection where AppKit shrinks it, and treated a click inside the
        //   selection as a no-op. The NSTextView probe of 2026-08-24 measured both cases and
        //   both came back anchor-to-click.
        // Scenario: a captured-mouse application has "cde" selected, anchored at its start.
        //   The user Shift-clicks each region in turn, then drags across the anchor.
        var terminal = try #require(Terminal(columns: 12, rows: 2))
        terminal.feed(Array("abcdefghij\u{1B}[?1003h".utf8))

        // Column, in-cell offset, and the text the Shift-click must leave selected. Every
        // expectation is anchor-to-click: the anchor is "cde"'s start, at column 2.
        let regions: [(String, Int, Double, String)] = [
            ("before the selection", 1, 0.25, "b"),
            ("inside it, near the anchor", 3, 0.0, "c"),
            ("inside it, at the far end", 4, 0.0, "cd"),
            ("past the far end", 6, 0.5, "cdefg"),
        ]
        for (label, column, offsetX, expected) in regions {
            terminal.setSelection(range(0, 2, 0, 5))
            var state = TerminalInteractionState()
            let down = decideAndApply(
                .down(.left, cell: .init(column: column, row: 0, offsetX: offsetX),
                    modifiers: [.shift]),
                terminal: &terminal,
                state: &state
            )
            #expect(terminal.selectedText == expected, "\(label)")
            #expect(down.inputBytes.isEmpty, "\(label)")
            let release = decideTerminalPointer(
                .up(.left, cell: .init(column: column, row: 0), modifiers: [.shift]),
                terminal: terminal,
                state: &state
            )
            #expect(release.completedSelectionGesture, "\(label)")
            #expect(release.inputBytes.isEmpty, "\(label)")
        }

        // Landing on the anchor itself collapses the selection to the caret it pivots on.
        terminal.setSelection(range(0, 2, 0, 5))
        var collapsing = TerminalInteractionState()
        #expect(decideAndApply(
            .down(.left, cell: .init(column: 2, row: 0), modifiers: [.shift]),
            terminal: &terminal,
            state: &collapsing
        ).settledSelection == .caret)
        #expect(terminal.selectionRange == nil)

        // A Shift drag that crosses the anchor and comes back flips sides around it rather
        // than dragging the anchor along.
        terminal.setSelection(range(0, 2, 0, 5))
        var crossing = TerminalInteractionState()
        decideAndApply(
            .down(.left, cell: .init(column: 7, row: 0, offsetX: 0.5), modifiers: [.shift]),
            terminal: &terminal,
            state: &crossing
        )
        #expect(terminal.selectedText == "cdefgh")
        for (label, column, expected) in [
            ("across the anchor", 0, "ab"),
            ("back past it", 9, "cdefghi"),
        ] as [(String, Int, String)] {
            let moved = decideTerminalPointer(
                .move(cell: .init(column: column, row: 0), modifiers: [.shift]),
                terminal: terminal,
                state: &crossing
            )
            applyTerminalPointerDecision(moved, to: &terminal)
            #expect(terminal.selectedText == expected, "\(label)")
            #expect(moved.inputBytes.isEmpty, "\(label)")
        }
    }

    @Test("Applied decisions settle the unit the policy chose and hand it to the next extension")
    func appliedDecisionsCarryTheirSelectionUnit() throws {
        // Intent: applying a decision through the shared applier settles the unit the policy
        //   named, and the Shift extension that follows reads that unit back off the terminal.
        // Why it exists: the unit used to travel beside the mutation, so every consumer chose a
        //   default for a set that named none, and a wrong settled unit is what the next
        //   Shift-click inherits.
        // Scenario: a double-click selects "two", then a Shift-click inside "three" extends by
        //   whole tokens rather than by character.
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("one two three".utf8))
        var state = TerminalInteractionState()

        let doubleClick = decideAndApply(
            .down(.left, cell: .init(column: 5, row: 0), modifiers: [], clickCount: 2),
            terminal: &terminal,
            state: &state
        )
        applyTerminalPointerDecision(doubleClick, to: &terminal)
        #expect(terminal.selectionRange == range(0, 4, 0, 7))
        #expect(terminal.selectionGranularity == .terminalToken)

        var extending = TerminalInteractionState()
        let shiftExtension = decideAndApply(
            .down(.left, cell: .init(column: 9, row: 0, offsetX: 0.5),
                modifiers: [.shift],
                clickCount: 1),
            terminal: &terminal,
            state: &extending
        )
        applyTerminalPointerDecision(shiftExtension, to: &terminal)
        #expect(terminal.selectionRange == range(0, 4, 0, 13))
        #expect(terminal.selectionGranularity == .terminalToken)
    }

    @Test("Shift extension inherits token granularity whatever the extending click count")
    func shiftExtensionInheritsTokenGranularity() throws {
        // Intent: the settled token unit, not the extending click count, controls every
        //   sample, and the pointer takes the whole token it is inside.
        // Why it exists: recomputing granularity from the Shift click breaks native word
        //   extension, and a gesture that could not reverse around its anchor would be unable
        //   to shrink a word selection at all.
        // Scenario: "two" is selected, each click count reaches into "three", then one token
        //   gesture reverses back through the anchor.
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("one two three".utf8))
        terminal.setSelection(
            range(0, 4, 0, 7),
            granularity: .terminalToken
        )

        for clickCount in 1...3 {
            var state = TerminalInteractionState()
            let boundary = decideAndApply(
                .down(.left, cell: .init(column: 8, row: 0),
                    modifiers: [.shift],
                    clickCount: clickCount),
                terminal: &terminal,
                state: &state
            )
            #expect(boundary.settledSelection == .selected(range(0, 4, 0, 13), granularity: .terminalToken))
            #expect(boundary.inputBytes.isEmpty)
        }

        var reversal = TerminalInteractionState()
        #expect(decideAndApply(
            .down(.left, cell: .init(column: 8, row: 0, offsetX: 0.75),
                modifiers: [.shift],
                clickCount: 1),
            terminal: &terminal,
            state: &reversal
        ).settledSelection == .selected(range(0, 4, 0, 13), granularity: .terminalToken))
        // Back inside the anchored token, the selection is that token whole -- the anchor is
        // a unit, so a reversal through it cannot cut it in half.
        #expect(decideTerminalPointer(
            .move(cell: .init(column: 4, row: 0), modifiers: [.shift]),
            terminal: terminal,
            state: &reversal
        ).settledSelection == .selected(range(0, 4, 0, 7), granularity: .terminalToken))
        #expect(decideTerminalPointer(
            .move(cell: .init(column: 2, row: 0, offsetX: 0.25), modifiers: [.shift]),
            terminal: terminal,
            state: &reversal
        ).settledSelection == .selected(range(0, 0, 0, 4), granularity: .terminalToken))
    }

    @Test("Shift extension inherits trimmed-line granularity for every click count")
    func shiftExtensionInheritsTrimmedLineGranularity() throws {
        // Intent: line selection extends by whole trimmed logical lines, wherever inside the
        //   adjacent line the pointer lands.
        // Why it exists: line granularity must survive release just like token granularity;
        //   otherwise a later Shift click would use its own character or token click count.
        // Scenario: "second" is selected, then click counts one through three extend into the
        //   indented third line, at its first cell and just inside that cell.
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        terminal.feed(Array(" first \r\n second \r\n third ".utf8))
        terminal.setSelection(
            range(1, 1, 1, 7),
            granularity: .line
        )

        for clickCount in 1...3 {
            var boundaryState = TerminalInteractionState()
            #expect(decideAndApply(
                .down(.left, cell: .init(column: 1, row: 2),
                    modifiers: [.shift],
                    clickCount: clickCount),
                terminal: &terminal,
                state: &boundaryState
            ).settledSelection == .selected(range(1, 1, 2, 6), granularity: .line))

            var enteredState = TerminalInteractionState()
            #expect(decideAndApply(
                .down(.left, cell: .init(column: 1, row: 2, offsetX: 0.75),
                    modifiers: [.shift],
                    clickCount: clickCount),
                terminal: &terminal,
                state: &enteredState
            ).settledSelection == .selected(range(1, 1, 2, 6), granularity: .line))
        }
    }

    @Test("a measured off-grid press move or release arms opens and hovers nothing")
    func offGridPointerDecidesNoLinkWork() throws {
        // Intent: the one pointer decision refuses every link effect when the view measured the
        //   point outside the grid, and clears whatever link state an earlier event left.
        // Why it exists: the coordinates the view sends are clamped into the viewport, so the
        //   geometry test alone accepts an off-grid pointer. Each case below lands on a real
        //   activatable link at an in-range cell, which is exactly the pointer that used to
        //   arm, hover, or open a link the user never pointed at.
        // Scenario: the pointer sits past the right edge of a pane whose first row is a URL.
        func linkTerminal() throws -> Terminal {
            var terminal = try #require(Terminal(columns: 24, rows: 2))
            terminal.feed(Array("https://a.co".utf8))
            let link = try #require(terminal.activatableLink(at: .init(row: 0, column: 2)))
            terminal.setHoveredLink(link)
            _ = terminal.setArmedLink(link)
            return terminal
        }
        let offGrid = TerminalViewportCell(column: 2, row: 0, isInsideGrid: false)

        var pressTerminal = try linkTerminal()
        var pressState = TerminalInteractionState()
        let press = decideTerminalPointer(
            .down(.left, cell: offGrid, modifiers: [.command]),
            terminal: pressTerminal,
            state: &pressState
        )
        #expect(press.armMutation == .clear)
        #expect(press.hoverMutation == .clear)
        #expect(press.openLink == nil)
        applyTerminalPointerDecision(press, to: &pressTerminal)
        #expect(pressTerminal.armedLink == nil)

        var moveTerminal = try linkTerminal()
        var moveState = TerminalInteractionState()
        let move = decideTerminalPointer(
            .move(cell: offGrid, modifiers: [.command]),
            terminal: moveTerminal,
            state: &moveState
        )
        #expect(move.armMutation == .clear)
        #expect(move.hoverMutation == .clear)
        #expect(move.openLink == nil)
        applyTerminalPointerDecision(move, to: &moveTerminal)
        #expect(moveTerminal.armedLink == nil)

        // The release starts from a real on-grid link press, so the arm it must refuse to
        // activate is one this same gesture took.
        var releaseTerminal = try #require(Terminal(columns: 24, rows: 2))
        releaseTerminal.feed(Array("https://a.co".utf8))
        var releaseState = TerminalInteractionState()
        let releasePress = decideTerminalPointer(
            .down(.left, cell: .init(column: 2, row: 0), modifiers: [.command]),
            terminal: releaseTerminal,
            state: &releaseState
        )
        #expect(releasePress.armMutation != nil)
        applyTerminalPointerDecision(releasePress, to: &releaseTerminal)
        let release = decideTerminalPointer(
            .up(.left, cell: offGrid, modifiers: [.command]),
            terminal: releaseTerminal,
            state: &releaseState
        )
        #expect(release.openLink == nil)
        #expect(release.armMutation == .clear)
        #expect(release.hoverMutation == .clear)
        applyTerminalPointerDecision(release, to: &releaseTerminal)
        #expect(releaseTerminal.armedLink == nil)
    }

    @Test("a plain click leaves an anchor a following Shift-click selects from")
    func plainClickAnchorsTheFollowingShiftClick() throws {
        // Intent: click, then Shift-click, selects the text between the two points, and does
        //   so even when the plain click first replaced an existing selection.
        // Why it exists: every macOS text surface works this way, and DanTerm could not do it
        //   at all -- the plain click cleared the selection, so the Shift press had nothing to
        //   extend from and started a fresh gesture instead.
        // Scenario: the repro from the plan -- click between D and E, Shift-click between O
        //   and P, on a line of the alphabet.
        var terminal = try #require(Terminal(columns: 30, rows: 2))
        terminal.feed(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8))
        terminal.setSelection(range(0, 20, 0, 24))

        var state = TerminalInteractionState()
        let click = decideAndApply(
            .down(.left, cell: .init(column: 4, row: 0, offsetX: 0.1)),
            terminal: &terminal,
            state: &state
        )
        applyTerminalPointerDecision(click, to: &terminal)
        #expect(terminal.selectionRange == nil)
        _ = decideTerminalPointer(
            .up(.left, cell: .init(column: 4, row: 0, offsetX: 0.1)),
            terminal: terminal,
            state: &state
        )

        var extending = TerminalInteractionState()
        let shiftClick = decideAndApply(
            .down(.left, cell: .init(column: 14, row: 0, offsetX: 0.9), modifiers: [.shift]),
            terminal: &terminal,
            state: &extending
        )
        applyTerminalPointerDecision(shiftClick, to: &terminal)
        #expect(terminal.selectedText == "EFGHIJKLMNO")
    }

    private func range(
        _ startRow: Int,
        _ startColumn: Int,
        _ endRow: Int,
        _ endColumn: Int
    ) -> TerminalTextRange {
        TerminalTextRange(
            start: .init(row: startRow, column: startColumn),
            end: .init(row: endRow, column: endColumn)
        )
    }
}

/// Enough retained rows that every routing case has scrollback to move through, so a route
/// that reaches the viewport is never mistaken for one the terminal had nowhere to apply.
private let scrollbackFeed = (0..<20).map { "line-\($0)\r\n" }.joined()
