// Selection-overlay planning proofs across live and retained-history viewport windows.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

/// Pins selection highlights to half-open current-stream ranges without perturbing other layers.
struct SelectionRenderPlanningTests {
    // Intent: selection over nearby painted surfaces follows one pane-wide
    //   direction and remains distinct from the pane canvas.
    // Why it exists: under Monokai Remastered, selection over Claude Code's
    //   user-message band was darkened to near-canvas pixels while the nearby
    //   Codex band was lightened, making one drag read as two different effects.
    // Scenario: truecolor SGR paints the two observed band colors and one
    //   selection spans both cells.
    @Test("Selection across nearby dark surfaces stays light and clear of the canvas")
    func selectionUsesPanePolarityAcrossPaintedSurfaces() throws {
        let canvas = RenderColor(red: 12, green: 12, blue: 12)
        let theme = try selectionTheme(
            defaultForeground: RenderColor(red: 217, green: 217, blue: 217),
            defaultBackground: canvas,
            selectionBackground: RenderColor(red: 52, green: 52, blue: 52)
        )
        let backgrounds = [
            RenderColor(red: 55, green: 55, blue: 55),
            RenderColor(red: 41, green: 41, blue: 41),
        ]
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array(
            "\u{1B}[48;2;55;55;55mA\u{1B}[48;2;41;41;41mB".utf8
        ))
        terminal.setSelection(.init(
            start: .init(row: 0, column: 0),
            end: .init(row: 0, column: 2)
        ))

        let plan = planFrame(
            for: terminal,
            presentation: .init(theme: theme, isCursorVisible: false, cursorShape: .block)
        )

        #expect(plan.overlayRuns.count == 2)
        for (run, background) in zip(plan.overlayRuns, backgrounds) {
            #expect(perceivedBrightness(of: run.color) > perceivedBrightness(of: background))
            #expect(brightnessSeparation(run.color, background) >= 40)
            #expect(brightnessSeparation(run.color, canvas) >= 40)
        }
    }

    @Test("Selection adapts fill and text when a cell background matches the theme seed")
    func selectionAdaptsToResolvedCellBackground() throws {
        let collision = RenderColor(red: 56, green: 88, blue: 140)
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array("\u{1B}[38;2;56;88;140;48;2;56;88;140mA".utf8))
        terminal.setSelection(.init(
            start: .init(row: 0, column: 0),
            end: .init(row: 0, column: 1)
        ))

        let plan = planFrame(
            for: terminal,
            presentation: .init(theme: .dark, isCursorVisible: false, cursorShape: .block)
        )
        let overlay = try #require(plan.overlayRuns.first)
        let text = try #require(plan.textRuns.first)

        #expect(overlay.state == .selection)
        #expect(brightnessSeparation(overlay.color, collision) >= 40)
        #expect(brightnessSeparation(text.foreground, overlay.color) >= 100)
    }

    @Test("single-row selections use half-open columns and recolor only selected text")
    func singleRowSelection() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 1))
        terminal.feed(Array("\u{1B}[41;37;4mABCDE".utf8))
        let theme = try selectionTheme()
        let presentation = RenderPresentation(
            theme: theme,
            isCursorVisible: true,
            cursorShape: .block
        )
        let baseline = planFrame(for: terminal, presentation: presentation)

        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 1),
            end: TerminalTextPosition(row: 0, column: 4)
        ))
        let selected = planFrame(for: terminal, presentation: presentation)
        let selectedStyle = resolveOverlayStyle(
            state: .selection,
            background: theme.ansiColors[1],
            foreground: theme.selectionForeground,
            theme: theme
        )

        #expect(selected.overlayRuns == [
            RenderOverlayRun(
                startColumn: 1,
                columnCount: 3,
                state: .selection,
                color: selectedStyle.fill
            ),
        ])
        #expect(selected.backgroundRuns == baseline.backgroundRuns)
        #expect(selected.textRuns.count == 3)
        #expect(selected.textRuns.map(\.startColumn) == [0, 1, 4])
        #expect(selected.textRuns.map { $0.cells.count } == [1, 3, 1])
        #expect(selected.textRuns.map(\.foreground) == [
            theme.ansiColors[7],
            selectedStyle.foreground,
            theme.ansiColors[7],
        ])
        #expect(selected.cursor == baseline.cursor)
        assertCanonical(selected)
    }

    @Test("selection foreground outranks search background but not a block cursor")
    func selectionForegroundPrecedence() throws {
        let theme = try selectionTheme()
        var terminal = try #require(Terminal(columns: 3, rows: 1))
        terminal.feed(Array("ABC\u{1B}[1;2H".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 2)
        ))
        let found = terminal.beginSearch("A")
        try #require(found)

        let plan = planFrame(
            for: terminal,
            presentation: .init(theme: theme, isCursorVisible: true, cursorShape: .block)
        )
        let combinedStyle = resolveOverlayStyle(
            state: .selectionAndActiveSearchMatch,
            background: theme.defaultBackground,
            foreground: theme.selectionForeground,
            theme: theme
        )
        let selectedStyle = resolveOverlayStyle(
            state: .selection,
            background: theme.defaultBackground,
            foreground: theme.selectionForeground,
            theme: theme
        )
        let cursorStyle = resolveCursorStyle(background: selectedStyle.fill, theme: theme)

        #expect(plan.overlayRuns.first?.state == .selectionAndActiveSearchMatch)
        #expect(plan.textRuns.map(\.startColumn) == [0, 1, 2])
        #expect(plan.textRuns.map(\.foreground) == [
            combinedStyle.foreground,
            cursorStyle.foreground,
            theme.defaultForeground,
        ])
        #expect(plan.cursor?.color == cursorStyle.fill)
    }

    @Test("A selection beginning mid-row splits one uniform text run in two")
    func midRowSelectionSplitsUniformRun() throws {
        let theme = try selectionTheme()
        var terminal = try #require(Terminal(columns: 5, rows: 1))
        terminal.feed(Array("ABCDE".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 2),
            end: TerminalTextPosition(row: 0, column: 5)
        ))

        let plan = planFrame(
            for: terminal,
            presentation: .init(theme: theme, isCursorVisible: false, cursorShape: .block)
        )

        #expect(plan.textRuns.count == 2)
        #expect(plan.textRuns.map(\.startColumn) == [0, 2])
        #expect(plan.textRuns.flatMap(\.cells).map(\.scalars) == [
            TerminalScalars("A".unicodeScalars),
            TerminalScalars("B".unicodeScalars),
            TerminalScalars("C".unicodeScalars),
            TerminalScalars("D".unicodeScalars),
            TerminalScalars("E".unicodeScalars),
        ])
    }

    private func selectionTheme(
        defaultForeground: RenderColor = RenderColor(red: 100, green: 101, blue: 102),
        defaultBackground: RenderColor = RenderColor(red: 1, green: 2, blue: 3),
        selectionBackground: RenderColor = RenderColor(red: 4, green: 5, blue: 6)
    ) throws -> RenderTheme {
        let colors: [RenderColor] = (0..<16).map { index in
            let red = UInt8(index)
            let green = UInt8(index + 20)
            let blue = UInt8(index + 40)
            return RenderColor(red: red, green: green, blue: blue)
        }
        let palette = try #require(RenderANSIColors(exactly: colors))
        return RenderTheme(
            ansiColors: palette,
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground,
            selectionForeground: RenderColor(red: 200, green: 201, blue: 202),
            selectionBackground: selectionBackground,
            cursor: RenderColor(red: 7, green: 8, blue: 9),
            cursorText: RenderColor(red: 10, green: 11, blue: 12)
        )
    }

    @Test("multi-row selections emit start interior and end shapes")
    func multiRowSelection() throws {
        var terminal = try #require(Terminal(columns: 5, rows: 3))
        terminal.feed(Array("abcd\r\nefgh\r\nijkl".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 2),
            end: TerminalTextPosition(row: 2, column: 3)
        ))

        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )

        #expect(plan.overlayRunsWithRows.map { [$0.row, $0.run.startColumn, $0.run.columnCount] } == [
            [0, 2, 3],
            [1, 0, 5],
            [2, 0, 3],
        ])
        #expect(plan.overlayRuns.allSatisfy { $0.state == .selection })
        assertCanonical(plan)
    }

    @Test("selection planning intersects retained stream coordinates with the viewport")
    func viewportIntersection() throws {
        var terminal = try #require(Terminal(columns: 5, rows: 3))
        terminal.feed(Array("aaaa\r\nbbbb\r\ncccc\r\ndddd\r\neeee".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 1, column: 2),
            end: TerminalTextPosition(row: 3, column: 3)
        ))

        let following = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )
        #expect(terminal.scrollProjection.topRow == 2)
        #expect(following.overlayRunsWithRows.map { [$0.row, $0.run.startColumn, $0.run.columnCount] } == [
            [0, 0, 5],
            [1, 0, 3],
        ])

        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 1, column: 1)
        ))
        let fullyOutside = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )
        #expect(fullyOutside.overlayRuns.isEmpty)
    }

    @Test("absent and empty selections produce no overlay runs")
    func absentAndEmptySelection() throws {
        var terminal = try #require(Terminal(columns: 5, rows: 2))
        terminal.feed(Array("abcd".utf8))
        let presentation = RenderPresentation(
            theme: .dark,
            isCursorVisible: false,
            cursorShape: .block
        )

        #expect(planFrame(for: terminal, presentation: presentation).overlayRuns.isEmpty)

        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 2),
            end: TerminalTextPosition(row: 0, column: 2)
        ))
        #expect(terminal.selectionRange?.start == terminal.selectionRange?.end)
        #expect(planFrame(for: terminal, presentation: presentation).overlayRuns.isEmpty)
    }
}
