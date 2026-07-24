// Pixel proof that the search-match highlight outranks selection while glyphs stay above both.
import Testing

import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

/// Locks the draw order of the two highlight channels where they overlap.
struct SearchMatchExecutionTests {
    @Test("an overlapping search match overrides the selection background")
    func searchMatchDrawsOverSelection() throws {
        // Intent: a cell covered by both highlights shows the search-match color, and
        //   its glyph is still drawn on top.
        // Why it exists: planning proves the two run arrays coexist, but coexistence
        //   says nothing about draw order -- selection painted last would swallow the
        //   match a user just navigated to, exactly when they need to see it.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        var terminal = try #require(Terminal(columns: 3, rows: 1))
        terminal.feed(Array("\u{1B}[37mAB".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 2)
        ))
        let found = terminal.beginSearch("A")
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

        let overlapped = bitmap.pixels(in: cellRect(row: 0, column: 0, metrics: metrics))
        let match = Pixel(RenderTheme.dark.searchMatchBackground)
        #expect(overlapped.contains(match))
        #expect(overlapped.contains(Pixel(RenderTheme.dark.selectionBackground)) == false)
        #expect(overlapped.contains { $0 != match })

        let selectedOnly = bitmap.pixels(in: cellRect(row: 0, column: 1, metrics: metrics))
        #expect(selectedOnly.contains(Pixel(RenderTheme.dark.selectionBackground)))
        #expect(selectedOnly.contains(match) == false)
    }
}
