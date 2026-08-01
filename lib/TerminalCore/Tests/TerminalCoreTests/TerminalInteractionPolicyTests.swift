// Pure pointer ownership, local-selection, wheel-routing, and geometry policy proofs.
import Testing

@testable import TerminalCore

/// Pins one-consumer gesture routing independently from PTY and AppKit integration.
struct TerminalInteractionPolicyTests {
    @Test("pointer down chooses Shift local capture report or uncaptured local behavior")
    func pointerRoutingMatrix() throws {
        let terminal = try #require(Terminal(columns: 12, rows: 2))

        var shifted = TerminalInteractionState()
        let shiftedResult = decideTerminalPointer(
            .down(.left, column: 1, row: 0, modifiers: [.shift]),
            terminal: terminal,
            state: &shifted
        )
        #expect(shiftedResult.consumption == .selection)
        #expect(shiftedResult.selectionMutation == .clear)
        #expect(shiftedResult.inputBytes.isEmpty)

        var capturedTerminal = terminal
        capturedTerminal.feed(Array("\u{1B}[?1000;1006h".utf8))
        var captured = TerminalInteractionState()
        let capturedResult = decideTerminalPointer(
            .down(.left, column: 1, row: 0),
            terminal: capturedTerminal,
            state: &captured
        )
        #expect(capturedResult.consumption == .report)
        #expect(capturedResult.inputBytes == Array("\u{1B}[<0;2;1M".utf8))
        #expect(capturedResult.selectionMutation == nil)

        var shiftedMenu = TerminalInteractionState()
        #expect(decideTerminalPointer(
            .down(.right, column: 2, row: 0, modifiers: [.shift]),
            terminal: capturedTerminal,
            state: &shiftedMenu
        ).consumption == .paneMenu)
        #expect(decideTerminalPointer(
            .up(.right, column: 2, row: 0, modifiers: [.shift]),
            terminal: capturedTerminal,
            state: &shiftedMenu
        ).paneMenuCell == .init(column: 2, row: 0))

        var menu = TerminalInteractionState()
        #expect(decideTerminalPointer(
            .down(.right, column: 3, row: 1), terminal: terminal, state: &menu
        ).paneMenuCell == nil)
        #expect(decideTerminalPointer(
            .up(.right, column: 4, row: 1), terminal: terminal, state: &menu
        ).paneMenuCell == .init(column: 4, row: 1))

        var middle = TerminalInteractionState()
        #expect(decideTerminalPointer(
            .down(.middle, column: 0, row: 0), terminal: terminal, state: &middle
        ).consumption == .ignored)
    }

    @Test("pointer ownership stays latched when modifiers and mouse modes change")
    func pointerOwnershipLatch() throws {
        var localTerminal = try #require(Terminal(columns: 8, rows: 2))
        localTerminal.feed(Array("abcdef".utf8))
        var local = TerminalInteractionState()
        _ = decideTerminalPointer(
            .down(.left, column: 0, row: 0), terminal: localTerminal, state: &local
        )
        localTerminal.feed(Array("\u{1B}[?1003h".utf8))
        let redundantDown = decideTerminalPointer(
            .down(.left, column: 0, row: 0), terminal: localTerminal, state: &local
        )
        #expect(redundantDown.consumption == .selection)
        #expect(redundantDown.selectionMutation == nil)
        let localMove = decideTerminalPointer(
            .move(column: 3, row: 0, modifiers: [.alt]), terminal: localTerminal, state: &local
        )
        #expect(localMove.consumption == .selection)
        #expect(localMove.selectionMutation == .set(range(0, 0, 0, 4)))
        #expect(localMove.inputBytes.isEmpty)

        var reportTerminal = localTerminal
        var report = TerminalInteractionState()
        _ = decideTerminalPointer(
            .down(.left, column: 0, row: 0), terminal: reportTerminal, state: &report
        )
        reportTerminal.feed(Array("\u{1B}[?1003l".utf8))
        let reportMove = decideTerminalPointer(
            .move(column: 2, row: 0, modifiers: [.shift]), terminal: reportTerminal, state: &report
        )
        #expect(reportMove.consumption == .report)
        #expect(reportMove.selectionMutation == nil)
    }

    @Test("click counts cycle through character terminal-token and line units")
    func selectionGranularity() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("a.b c.d".utf8))

        let expectedMutations: [TerminalSelectionMutation] = [
            .clear,
            .set(range(0, 0, 0, 3)),
            .set(range(0, 0, 0, 7)),
            .clear,
            .set(range(0, 0, 0, 3)),
            .set(range(0, 0, 0, 7)),
        ]
        for clickCount in 1...6 {
            var state = TerminalInteractionState()
            let down = decideTerminalPointer(
                .down(.left, column: 1, row: 0, clickCount: clickCount),
                terminal: terminal,
                state: &state
            )
            #expect(down.selectionMutation == expectedMutations[clickCount - 1])
        }

        var character = TerminalInteractionState()
        _ = decideTerminalPointer(
            .down(.left, column: 1, row: 0, clickCount: 4), terminal: terminal, state: &character
        )
        #expect(decideTerminalPointer(
            .move(column: 3, row: 0), terminal: terminal, state: &character
        ).selectionMutation == .set(range(0, 1, 0, 4)))

        var terminalToken = TerminalInteractionState()
        _ = decideTerminalPointer(
            .down(.left, column: 1, row: 0, clickCount: 5), terminal: terminal, state: &terminalToken
        )
        #expect(decideTerminalPointer(
            .move(column: 5, row: 0), terminal: terminal, state: &terminalToken
        ).selectionMutation == .set(range(0, 0, 0, 7)))

        var hardLines = try #require(Terminal(columns: 8, rows: 3))
        hardLines.feed(Array("first\r\nsecond".utf8))
        var lineDrag = TerminalInteractionState()
        _ = decideTerminalPointer(
            .down(.left, column: 1, row: 0, clickCount: 6),
            terminal: hardLines,
            state: &lineDrag
        )
        #expect(decideTerminalPointer(
            .move(column: 2, row: 1), terminal: hardLines, state: &lineDrag
        ).selectionMutation == .set(range(0, 0, 1, 6)))

        #expect(decideTerminalPointer(
            .up(.left, column: 1, row: 0), terminal: terminal, state: &terminalToken
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
            let down = decideTerminalPointer(
                .down(.left, column: 13, row: 0, clickCount: clickCount),
                terminal: terminal,
                state: &state
            )
            #expect(down.selectionMutation == .set(range(0, 2, 0, 9)))
        }
        terminal.setSelection(range(0, 2, 0, 9))
        #expect(terminal.selectedText == "foo bar")

        var evicting = try #require(Terminal(
            columns: 12,
            rows: 2,
            scrollbackBudgetBytes: compactHistoryRowCost(storedCells: 6) * 2
        ))
        evicting.feed(Array("  aa  \r\n  bb  \r\n  cc  \r\n  dd  \r\n  ee  ".utf8))
        evicting.scroll(toTopRow: 0)
        // Five hard lines fed into a two-row history budget: only four rows survive,
        // so the topmost retained line is the second one written.
        #expect(evicting.scrollProjection.totalRows == 4)

        var history = TerminalInteractionState()
        let historyDown = decideTerminalPointer(
            .down(.left, column: 5, row: 0, clickCount: 3),
            terminal: evicting,
            state: &history
        )
        #expect(historyDown.selectionMutation == .set(range(0, 2, 0, 4)))
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
        _ = decideTerminalPointer(
            .down(.left, column: 0, row: 0, clickCount: 3), terminal: terminal, state: &state
        )
        let move = decideTerminalPointer(
            .move(column: 11, row: 1), terminal: terminal, state: &state
        )

        #expect(move.selectionMutation == .set(range(0, 2, 1, 8)))
        terminal.setSelection(range(0, 2, 1, 8))
        #expect(terminal.selectedText == "first  \n  second")
    }

    @Test("click count never reaches an application that has captured the mouse")
    func capturedMouseIgnoresClickCount() throws {
        // Intent: under mouse capture, a high-click-count press reports exactly the
        //   bytes a single click reports, and still makes no selection.
        // Why it exists: adding a fourth granularity step made click counts above
        //   three reachable for the first time; the captured-mouse recording suite
        //   replays terminal state only and discards reported bytes, so it cannot
        //   catch a report that a new click count altered or suppressed.
        // Scenario: clicking four times in a TUI that tracks the mouse -- vim, btop --
        //   must look like four ordinary clicks to that application.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("\u{1B}[?1000;1006h".utf8))

        var single = TerminalInteractionState()
        let singleDown = decideTerminalPointer(
            .down(.left, column: 1, row: 0, clickCount: 1), terminal: terminal, state: &single
        )
        var quadruple = TerminalInteractionState()
        let quadrupleDown = decideTerminalPointer(
            .down(.left, column: 1, row: 0, clickCount: 4), terminal: terminal, state: &quadruple
        )

        #expect(singleDown.inputBytes.isEmpty == false)
        #expect(quadrupleDown.inputBytes == singleDown.inputBytes)
        #expect(quadrupleDown.consumption == .report)
        #expect(quadrupleDown.selectionMutation == nil)
    }

    @Test("local selection maps displayed browsing rows into the current stream")
    func browsingSelectionCoordinates() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("old\r\nmid\r\nnew".utf8))
        terminal.scroll(toTopRow: 0)
        var state = TerminalInteractionState()

        let decision = decideTerminalPointer(
            .down(.left, column: 1, row: 0, clickCount: 2),
            terminal: terminal,
            state: &state
        )

        #expect(decision.selectionMutation == .set(range(0, 0, 0, 3)))
        #expect(terminal.scrollProjection.isFollowing == false)
    }

    @Test("an empty character click clears selection and captured right clicks never open menus")
    func clickFinalization() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("text".utf8))
        terminal.setSelection(from: .init(row: 0, column: 0), to: .init(row: 0, column: 2))
        var local = TerminalInteractionState()
        #expect(decideTerminalPointer(
            .down(.left, column: 2, row: 0), terminal: terminal, state: &local
        ).selectionMutation == .clear)
        #expect(decideTerminalPointer(
            .move(column: 2, row: 0), terminal: terminal, state: &local
        ).selectionMutation == nil)
        #expect(decideTerminalPointer(
            .up(.left, column: 2, row: 0), terminal: terminal, state: &local
        ).selectionMutation == nil)

        terminal.feed(Array("\u{1B}[?1000h".utf8))
        var captured = TerminalInteractionState()
        #expect(decideTerminalPointer(
            .down(.right, column: 1, row: 0), terminal: terminal, state: &captured
        ).consumption == .report)
        let up = decideTerminalPointer(
            .up(.right, column: 1, row: 0), terminal: terminal, state: &captured
        )
        #expect(up.consumption == .report)
        #expect(up.paneMenuCell == nil)
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

    @Test("point normalization floors clamps and rejects degenerate geometry")
    func pointNormalization() {
        #expect(terminalCell(
            at: .init(x: 25.9, y: 39.9),
            cellSize: .init(width: 10, height: 13),
            columns: 8,
            rows: 4
        ) == .init(column: 2, row: 3))
        #expect(terminalCell(
            at: .init(x: -4, y: 100),
            cellSize: .init(width: 10, height: 13),
            columns: 8,
            rows: 4
        ) == .init(column: 0, row: 3))
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

    @Test("Cmd link ownership suppresses reports and revalidates the originating run")
    func commandLinkArmLifecycle() throws {
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("https://a.co https://a.co\u{1B}[?1003;1006h".utf8))
        var state = TerminalInteractionState()

        let down = decideTerminalPointer(
            .down(.left, column: 2, row: 0, modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(down.consumption == .link)
        #expect(down.inputBytes.isEmpty)
        apply(down.armMutation, to: &terminal)

        let drag = decideTerminalPointer(
            .move(column: 5, row: 0, modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(drag.consumption == .link)
        #expect(drag.inputBytes.isEmpty)

        let wrongRun = decideTerminalPointer(
            .up(.left, column: 15, row: 0, modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(wrongRun.openLink == nil)
        #expect(wrongRun.hoverMutation == .clear)
        apply(wrongRun.armMutation, to: &terminal)

        let secondDown = decideTerminalPointer(
            .down(.left, column: 2, row: 0, modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        apply(secondDown.armMutation, to: &terminal)
        let open = decideTerminalPointer(
            .up(.left, column: 3, row: 0, modifiers: [.command]),
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
                .down(.left, column: 2, row: 0, modifiers: [.command]),
                terminal: terminal,
                state: &state
            )
            apply(down.armMutation, to: &terminal)
            let up = decideTerminalPointer(
                .up(.left, column: 3, row: 0, modifiers: [.command]),
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
            .down(.left, column: 2, row: 0, modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        apply(down.armMutation, to: &terminal)

        terminal.feed(Array("\u{1B}[1;1Hh".utf8))
        let release = decideTerminalPointer(
            .up(.left, column: 3, row: 0, modifiers: [.command]),
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
            .down(.right, column: 14, row: 0), terminal: terminal, state: &state
        ).consumption == .report)
        #expect(decideTerminalPointer(
            .down(.left, column: 2, row: 0, modifiers: [.command]),
            terminal: terminal,
            state: &state
        ).consumption == .link)
        let move = decideTerminalPointer(
            .move(column: 3, row: 0, modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(move.consumption == .link)
        #expect(move.inputBytes.isEmpty)
        #expect(decideTerminalPointer(
            .up(.left, column: 3, row: 0, modifiers: [.command]),
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
            .move(column: 2, row: 0, modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        let resolved = try #require(terminal.activatableLink(at: .init(row: 0, column: 2)))
        #expect(hover.hoverMutation == .set(resolved))

        let clear = decideTerminalPointer(
            .move(column: 2, row: 0), terminal: terminal, state: &state
        )
        #expect(clear.hoverMutation == .clear)

        _ = decideTerminalPointer(
            .down(.left, column: 2, row: 0, modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        let outside = decideTerminalPointer(
            .move(column: -1, row: 0, modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(outside.openLink == nil)
        #expect(outside.hoverMutation == .clear)
        #expect(outside.armMutation == .clear)
        apply(outside.armMutation, to: &terminal)
        let release = decideTerminalPointer(
            .up(.left, column: 2, row: 0, modifiers: [.command]),
            terminal: terminal,
            state: &state
        )
        #expect(release.consumption == .link)
        #expect(release.inputBytes.isEmpty)
        #expect(release.openLink == nil)

        #expect(cancelTerminalLinkInteraction(state: &state) == TerminalLinkCancellation(
            hoverMutation: .clear,
            armMutation: .clear
        ))
    }

    @Test("printing across the content-identity wrap keeps working and drops the armed link")
    func contentIdentityWrapDropsArmedLink() throws {
        // Intent: output that exhausts the per-cell content-identity counter keeps printing, and
        //   any link armed before the wrap is dropped rather than carried across it.
        // Why it exists: doc 15's `H4` narrowed `contentIdentity` to 32 bits to take `GridCell`
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
            scrollbackBudgetBytes: compactHistoryRowCost(storedCells: 3) * 6
        ))
        terminal.feed(Array("r01\r\nr02\r\nr03\r\nr04\r\nr05\r\nr06\r\nr07\r\nr08".utf8))
        terminal.scroll(toTopRow: 2)

        var state = TerminalInteractionState()
        let down = decideTerminalPointer(
            .down(.left, column: 0, row: 1, clickCount: 3), terminal: terminal, state: &state
        )
        #expect(down.selectionMutation == .set(range(3, 0, 3, 3)))

        // Two separate bursts, so a one-shot rebase at the first eviction cannot pass.
        for burst in 1...2 {
            terminal.feed(Array("\r\nr0\(8 + burst)".utf8))
            let anchoredRow = 3 - burst
            let held = decideTerminalPointer(
                .move(column: 0, row: 1), terminal: terminal, state: &state
            )
            #expect(held.selectionMutation == .set(range(anchoredRow, 0, anchoredRow, 3)))
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
        _ = decideTerminalPointer(
            .down(.left, column: 0, row: 0), terminal: following, state: &followingState
        )
        let followingMove = decideTerminalPointer(
            .move(column: 2, row: 1), terminal: following, state: &followingState
        )
        #expect(followingMove.selectionMutation == .set(range(0, 0, 1, 3)))
        following.setSelection(range(0, 0, 1, 3))
        #expect(following.selectedText == "abc def\nghi")

        var browsing = try #require(Terminal(
            columns: 12,
            rows: 2,
            scrollbackBudgetBytes: historyRowCost(columns: 12) * 6
        ))
        browsing.feed(Array("r01\r\nr02\r\nr03\r\nr04\r\nr05\r\nr06\r\nr07\r\nr08".utf8))
        browsing.scroll(toTopRow: 2)
        var browsingState = TerminalInteractionState()
        _ = decideTerminalPointer(
            .down(.left, column: 0, row: 0), terminal: browsing, state: &browsingState
        )
        let browsingMove = decideTerminalPointer(
            .move(column: 2, row: 1), terminal: browsing, state: &browsingState
        )
        #expect(browsingMove.selectionMutation == .set(range(2, 0, 3, 3)))
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
            scrollbackBudgetBytes: historyRowCost(columns: 4) * 3
        ))
        terminal.feed(Array("xx\r\naaaabbbb\r\nyy\r\nzz".utf8))
        terminal.scroll(toTopRow: 0)

        var state = TerminalInteractionState()
        let down = decideTerminalPointer(
            .down(.left, column: 0, row: 1, clickCount: 3), terminal: terminal, state: &state
        )
        #expect(down.selectionMutation == .set(range(1, 0, 2, 4)))

        terminal.feed(Array("\r\nww\r\nvv".utf8))
        let move = decideTerminalPointer(
            .move(column: 0, row: 1), terminal: terminal, state: &state
        )

        #expect(move.selectionMutation == .set(range(0, 0, 1, 2)))
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
            scrollbackBudgetBytes: compactHistoryRowCost(storedCells: 4) * 3
                + compactHistoryRowCost(storedCells: 13)
        ))
        terminal.feed(Array("top1\r\ntop2\r\none two three\r\nf1\r\nf2".utf8))
        terminal.scroll(toTopRow: 2)

        var state = TerminalInteractionState()
        let down = decideTerminalPointer(
            .down(.left, column: 4, row: 0, clickCount: 2), terminal: terminal, state: &state
        )
        #expect(down.selectionMutation == .set(range(2, 4, 2, 7)))
        let forward = decideTerminalPointer(
            .move(column: 9, row: 0), terminal: terminal, state: &state
        )
        #expect(forward.selectionMutation == .set(range(2, 4, 2, 13)))

        terminal.feed(Array("\r\nf3\r\nf4".utf8))
        let reversed = decideTerminalPointer(
            .move(column: 1, row: 0), terminal: terminal, state: &state
        )

        #expect(reversed.selectionMutation == .set(range(1, 0, 1, 7)))
        terminal.setSelection(range(1, 0, 1, 7))
        #expect(terminal.selectedText == "one two")
    }

    @Test("a press that never moves selects nothing even after eviction")
    func unmovedCharacterPressSelectsNothingAcrossEviction() throws {
        // Intent: character granularity suppresses a drag that has not left its own cell,
        //   and eviction beneath the pointer does not count as leaving it.
        // Why it exists: the suppression compares the resolved anchor against a freshly
        //   computed unit. A drifting anchor makes those differ for free, so eviction alone
        //   would turn a plain click into a selection of text the user never dragged over.
        var terminal = try #require(Terminal(
            columns: 12,
            rows: 2,
            scrollbackBudgetBytes: compactHistoryRowCost(storedCells: 3) * 6
        ))
        terminal.feed(Array("r01\r\nr02\r\nr03\r\nr04\r\nr05\r\nr06\r\nr07\r\nr08".utf8))
        terminal.scroll(toTopRow: 2)

        var state = TerminalInteractionState()
        #expect(decideTerminalPointer(
            .down(.left, column: 1, row: 1), terminal: terminal, state: &state
        ).selectionMutation == .clear)

        terminal.feed(Array("\r\nr09".utf8))
        #expect(decideTerminalPointer(
            .move(column: 1, row: 1), terminal: terminal, state: &state
        ).selectionMutation == nil)

        let extended = decideTerminalPointer(
            .move(column: 2, row: 1), terminal: terminal, state: &state
        )
        #expect(extended.selectionMutation == .set(range(2, 1, 2, 3)))
        terminal.setSelection(range(2, 1, 2, 3))
        #expect(terminal.selectedText == "04")
    }

    @Test("pinning a selection unit and resolving it back reproduces it exactly")
    func pinnedRangeRoundTripsEverySelectionUnit() throws {
        // Intent: mint-then-resolve is the identity on every unit a pointer gesture can
        //   anchor on, including the boundary shapes -- a wide cell, a hard line end, and a
        //   line that trims to nothing.
        // Why it exists: the drag compares its resolved anchor against a freshly computed
        //   unit, both to decide `hasExtended` and to suppress an unmoved character press.
        //   A round trip that shifted a boundary by one column would misfire both silently,
        //   with no eviction anywhere in sight.
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
            #expect(fed.resolvedRange(fed.pinnedRange(unit)) == unit, "\(label)")
        }
    }

    @Test("hard reset width reflow and screen replacement each stop a held drag")
    func renumberingRowsStopsTheDrag() throws {
        // Intent: after an event that makes absolute row numbers name different text, a held
        //   drag stops extending instead of resolving its anchor against the new numbering.
        // Why it exists: the pin resolves through a row number that survives eviction, but a
        //   hard reset returns the eviction count to zero and a reflow or a screen swap
        //   rewrites what those rows hold -- each leaves a stale anchor resolving to a
        //   wrong-but-in-range position, which reads as the selection jumping to text the
        //   user never touched.
        let renumberings: [(String, (inout Terminal) -> Void)] = [
            ("hard reset", { $0.feed(Array("\u{1b}c".utf8)) }),
            ("width reflow", { $0.resize(columns: 10, rows: 3) }),
            ("screen replacement", { $0.feed(Array("\u{1b}[?1049h".utf8)) }),
        ]
        for (label, renumber) in renumberings {
            var terminal = try #require(Terminal(columns: 12, rows: 3))
            terminal.feed(Array("one two\r\nthree\r\nfour".utf8))

            var state = TerminalInteractionState()
            let down = decideTerminalPointer(
                .down(.left, column: 0, row: 0, clickCount: 2), terminal: terminal, state: &state
            )
            #expect(down.selectionMutation == .set(range(0, 0, 0, 3)), "\(label)")

            renumber(&terminal)
            let moved = decideTerminalPointer(
                .move(column: 4, row: 0), terminal: terminal, state: &state
            )

            #expect(moved.selectionMutation == nil, "\(label)")
            // The gesture is over as a selection, not as input: the button stays
            // selection-owned so its release cannot send bytes to the child.
            #expect(moved.consumption == .selection, "\(label)")
            #expect(moved.inputBytes.isEmpty, "\(label)")
        }
    }

    @Test("a height-only resize and a primary-screen soft reset leave a held drag extending")
    func rowPreservingEventsKeepTheDragExtending() throws {
        // Intent: only events that renumber absolute rows stop a drag. A taller viewport and
        //   a soft reset on the primary screen leave every row naming the text it named.
        // Why it exists: the cheap way to satisfy the stop rule is to invalidate on anything
        //   that smells structural, which would kill live drags during an ordinary window
        //   resize or a shell's prompt-time DECSTR.
        let preservations: [(String, (inout Terminal) -> Void)] = [
            ("height-only resize", { $0.resize(columns: 12, rows: 4) }),
            ("primary-screen soft reset", { $0.feed(Array("\u{1b}[!p".utf8)) }),
        ]
        for (label, preserve) in preservations {
            var terminal = try #require(Terminal(columns: 12, rows: 3))
            terminal.feed(Array("one two\r\nthree\r\nfour".utf8))

            var state = TerminalInteractionState()
            let down = decideTerminalPointer(
                .down(.left, column: 0, row: 0, clickCount: 2), terminal: terminal, state: &state
            )
            #expect(down.selectionMutation == .set(range(0, 0, 0, 3)), "\(label)")

            preserve(&terminal)
            let moved = decideTerminalPointer(
                .move(column: 4, row: 0), terminal: terminal, state: &state
            )

            #expect(moved.selectionMutation == .set(range(0, 0, 0, 7)), "\(label)")
            var settled = terminal
            settled.setSelection(range(0, 0, 0, 7))
            #expect(settled.selectedText == "one two", "\(label)")
        }
    }

    @Test("leaving the alternate screen stops a held drag, by mode reset or by soft reset")
    func leavingTheAlternateScreenStopsTheDrag() throws {
        // Intent: putting the primary screen back underneath a drag anchored on the
        //   alternate one stops it, by whichever route the child took.
        // Why it exists: the soft-reset case pairs with the primary-screen soft reset above
        //   to name why the two differ -- it is the screen replacement that invalidates the
        //   anchor, not the reset, so keying the rule on "is this a reset" gets both wrong.
        //   The mode-reset case covers the other direction of the swap.
        let exits = [("mode reset", "\u{1b}[?1049l"), ("soft reset", "\u{1b}[!p")]
        for (label, exit) in exits {
            var terminal = try #require(Terminal(columns: 12, rows: 3))
            terminal.feed(Array("\u{1b}[?1049hone two\r\nthree".utf8))

            var state = TerminalInteractionState()
            let down = decideTerminalPointer(
                .down(.left, column: 0, row: 0, clickCount: 2), terminal: terminal, state: &state
            )
            #expect(down.selectionMutation == .set(range(0, 0, 0, 3)), "\(label)")

            terminal.feed(Array(exit.utf8))
            let moved = decideTerminalPointer(
                .move(column: 4, row: 0), terminal: terminal, state: &state
            )

            #expect(moved.selectionMutation == nil, "\(label)")
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
        let scrollbackDown = decideTerminalPointer(
            .down(.left, column: 0, row: 0, clickCount: 2),
            terminal: scrollbackHeld,
            state: &scrollbackState
        )
        #expect(scrollbackDown.selectionMutation == .set(range(0, 0, 0, 3)))

        scrollbackHeld.feed(Array("\u{1b}[3J".utf8))
        #expect(decideTerminalPointer(
            .move(column: 4, row: 0), terminal: scrollbackHeld, state: &scrollbackState
        ).selectionMutation == nil)

        var viewportHeld = try #require(Terminal(columns: 12, rows: 2))
        viewportHeld.feed(Array("s01\r\ns02\r\nv01 xy\r\nv02".utf8))

        var viewportState = TerminalInteractionState()
        let viewportDown = decideTerminalPointer(
            .down(.left, column: 0, row: 0, clickCount: 2),
            terminal: viewportHeld,
            state: &viewportState
        )
        #expect(viewportDown.selectionMutation == .set(range(2, 0, 2, 3)))

        viewportHeld.feed(Array("\u{1b}[3J".utf8))
        let extended = decideTerminalPointer(
            .move(column: 4, row: 0), terminal: viewportHeld, state: &viewportState
        )

        #expect(extended.selectionMutation == .set(range(0, 0, 0, 6)))
        viewportHeld.setSelection(range(0, 0, 0, 6))
        #expect(viewportHeld.selectedText == "v01 xy")
    }

    @Test("rewriting the anchored cells in place leaves the drag extending from that position")
    func rewritingAnchoredCellsKeepsTheDragExtending() throws {
        // Intent: output that overwrites the anchored text without moving any row keeps the
        //   drag alive, anchored at the same position and now covering the new text.
        // Why it exists: records a deliberate divergence from what a settled selection does
        //   -- `Terminal` clears that one on an in-place rewrite. The button is still held
        //   and the user is actively re-selecting, so position wins over content; the policy
        //   layer has no cell-rewrite signal anyway, and killing a live gesture is worse.
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        terminal.feed(Array("one two\r\nthree\r\nfour".utf8))

        var state = TerminalInteractionState()
        let down = decideTerminalPointer(
            .down(.left, column: 0, row: 0, clickCount: 2), terminal: terminal, state: &state
        )
        #expect(down.selectionMutation == .set(range(0, 0, 0, 3)))

        terminal.feed(Array("\u{1b}[1;1Hzzz".utf8))
        let moved = decideTerminalPointer(
            .move(column: 5, row: 0), terminal: terminal, state: &state
        )

        #expect(moved.selectionMutation == .set(range(0, 0, 0, 7)))
        terminal.setSelection(range(0, 0, 0, 7))
        #expect(terminal.selectedText == "zzz two")
    }

    private func apply(_ mutation: TerminalLinkArmMutation?, to terminal: inout Terminal) {
        switch mutation {
        case .clear:
            terminal.clearArmedLink()
        case .set(let link):
            _ = terminal.setArmedLink(link)
        case nil:
            break
        }
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
