// Selection-overlay planning proofs across live and retained-history viewport windows.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

/// Pins selection highlights to half-open current-stream ranges without perturbing other layers.
struct SelectionRenderPlanningTests {
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

        #expect(selected.selectionRuns == [
            RenderSelectionRun(row: 0, startColumn: 1, columnCount: 3),
        ])
        #expect(selected.backgroundRuns == baseline.backgroundRuns)
        #expect(selected.textRuns.count == 3)
        #expect(selected.textRuns.map(\.startColumn) == [0, 1, 4])
        #expect(selected.textRuns.map { $0.cells.count } == [1, 3, 1])
        #expect(selected.textRuns.map(\.foreground) == [
            theme.ansiColors[7],
            theme.selectionForeground,
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

        #expect(plan.searchMatchRuns == [
            RenderSelectionRun(row: 0, startColumn: 0, columnCount: 1),
        ])
        #expect(plan.textRuns.map(\.startColumn) == [0, 1, 2])
        #expect(plan.textRuns.map(\.foreground) == [
            theme.selectionForeground,
            theme.cursorText,
            theme.defaultForeground,
        ])
        #expect(plan.cursor?.color == theme.cursor)
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

    private func selectionTheme() throws -> RenderTheme {
        let colors: [RenderColor] = (0..<16).map { index in
            let red = UInt8(index)
            let green = UInt8(index + 20)
            let blue = UInt8(index + 40)
            return RenderColor(red: red, green: green, blue: blue)
        }
        let palette = try #require(RenderANSIColors(exactly: colors))
        return RenderTheme(
            ansiColors: palette,
            defaultForeground: RenderColor(red: 100, green: 101, blue: 102),
            defaultBackground: RenderColor(red: 1, green: 2, blue: 3),
            selectionForeground: RenderColor(red: 200, green: 201, blue: 202),
            selectionBackground: RenderColor(red: 4, green: 5, blue: 6),
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

        #expect(plan.selectionRuns == [
            RenderSelectionRun(row: 0, startColumn: 2, columnCount: 3),
            RenderSelectionRun(row: 1, startColumn: 0, columnCount: 5),
            RenderSelectionRun(row: 2, startColumn: 0, columnCount: 3),
        ])
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
        #expect(following.selectionRuns == [
            RenderSelectionRun(row: 0, startColumn: 0, columnCount: 5),
            RenderSelectionRun(row: 1, startColumn: 0, columnCount: 3),
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
        #expect(fullyOutside.selectionRuns.isEmpty)
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

        #expect(planFrame(for: terminal, presentation: presentation).selectionRuns.isEmpty)

        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 2),
            end: TerminalTextPosition(row: 0, column: 2)
        ))
        #expect(terminal.selectionRange?.start == terminal.selectionRange?.end)
        #expect(planFrame(for: terminal, presentation: presentation).selectionRuns.isEmpty)
    }
}
