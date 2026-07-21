// Selection-overlay planning proofs across live and retained-history viewport windows.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

/// Pins selection highlights to half-open current-stream ranges without perturbing other layers.
struct SelectionRenderPlanningTests {
    @Test("single-row selections use half-open columns and preserve existing layers")
    func singleRowSelection() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 1))
        terminal.feed(Array("\u{1B}[41;37;4mABCDE".utf8))
        let presentation = RenderPresentation(theme: .dark, isCursorVisible: true)
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
        #expect(selected.textRuns == baseline.textRuns)
        #expect(selected.decorationRuns == baseline.decorationRuns)
        #expect(selected.cursor == baseline.cursor)
        assertCanonical(selected)
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
            presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
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
            presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
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
            presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
        )
        #expect(fullyOutside.selectionRuns.isEmpty)
    }

    @Test("absent and empty selections produce no overlay runs")
    func absentAndEmptySelection() throws {
        var terminal = try #require(Terminal(columns: 5, rows: 2))
        terminal.feed(Array("abcd".utf8))
        let presentation = RenderPresentation(theme: .dark, isCursorVisible: false)

        #expect(planFrame(for: terminal, presentation: presentation).selectionRuns.isEmpty)

        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 2),
            end: TerminalTextPosition(row: 0, column: 2)
        ))
        #expect(terminal.selectionRange?.start == terminal.selectionRange?.end)
        #expect(planFrame(for: terminal, presentation: presentation).selectionRuns.isEmpty)
    }
}
