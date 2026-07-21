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

    @Test("click counts select character word and line units and drag their union")
    func selectionGranularity() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("one two three".utf8))

        var character = TerminalInteractionState()
        _ = decideTerminalPointer(
            .down(.left, column: 1, row: 0, clickCount: 1), terminal: terminal, state: &character
        )
        let characterMove = decideTerminalPointer(
            .move(column: 3, row: 0), terminal: terminal, state: &character
        )
        #expect(characterMove.selectionMutation == .set(range(0, 1, 0, 4)))

        var word = TerminalInteractionState()
        let wordDown = decideTerminalPointer(
            .down(.left, column: 1, row: 0, clickCount: 2), terminal: terminal, state: &word
        )
        #expect(wordDown.selectionMutation == .set(range(0, 0, 0, 3)))
        let wordMove = decideTerminalPointer(
            .move(column: 2, row: 1), terminal: terminal, state: &word
        )
        #expect(wordMove.selectionMutation == .set(range(0, 0, 1, 5)))

        var line = TerminalInteractionState()
        let lineDown = decideTerminalPointer(
            .down(.left, column: 1, row: 0, clickCount: 5), terminal: terminal, state: &line
        )
        #expect(lineDown.selectionMutation == .set(range(0, 0, 1, 5)))

        var hardLines = try #require(Terminal(columns: 8, rows: 3))
        hardLines.feed(Array("first\r\nsecond".utf8))
        var lineDrag = TerminalInteractionState()
        _ = decideTerminalPointer(
            .down(.left, column: 1, row: 0, clickCount: 3),
            terminal: hardLines,
            state: &lineDrag
        )
        #expect(decideTerminalPointer(
            .move(column: 2, row: 1), terminal: hardLines, state: &lineDrag
        ).selectionMutation == .set(range(0, 0, 1, 6)))

        #expect(decideTerminalPointer(
            .up(.left, column: 1, row: 0), terminal: terminal, state: &line
        ).consumption == .selection)
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
