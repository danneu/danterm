// Pixel proof that selection, search, and their overlap remain distinct below glyphs.
import Testing

import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

/// Locks all three semantic highlight fills into the executor's overlay pass.
struct SearchMatchExecutionTests {
    @Test("selection search and overlap render as three distinct fills")
    func semanticOverlayFillsRemainDistinct() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        var terminal = try #require(Terminal(columns: 3, rows: 1))
        terminal.feed(Array("\u{1B}[37mABC".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 2)
        ))
        let found = terminal.beginSearch("BC")
        #expect(found)

        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )
        let bitmap = try renderBitmap(plan: plan, metrics: metrics)
        let combined = try #require(plan.overlayRuns.first { $0.state == .selectionAndActiveSearchMatch })
        let selection = try #require(plan.overlayRuns.first { $0.state == .selection })

        let match = try #require(plan.overlayRuns.first { $0.state == .activeSearchMatch })

        let overlapped = bitmap.pixels(in: cellRect(row: 0, column: 1, metrics: metrics))
        #expect(overlapped.contains(Pixel(combined.color)))
        #expect(overlapped.contains(Pixel(selection.color)) == false)
        #expect(overlapped.contains { $0 != Pixel(combined.color) })

        let selectedOnly = bitmap.pixels(in: cellRect(row: 0, column: 0, metrics: metrics))
        #expect(selectedOnly.contains(Pixel(selection.color)))
        #expect(selectedOnly.contains(Pixel(combined.color)) == false)
        let matchedOnly = bitmap.pixels(in: cellRect(row: 0, column: 2, metrics: metrics))
        #expect(matchedOnly.contains(Pixel(match.color)))
        #expect(matchedOnly.contains(Pixel(combined.color)) == false)
        #expect(combined.color != selection.color)
        #expect(combined.color != match.color)
        #expect(selection.color != match.color)
        #expect(combined.color != plan.defaultBackground)
        #expect(selection.color != plan.defaultBackground)
        #expect(match.color != plan.defaultBackground)
    }
}
