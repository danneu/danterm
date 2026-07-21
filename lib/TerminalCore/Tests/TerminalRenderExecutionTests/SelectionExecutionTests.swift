// Pixel proofs that selection is executed between ordinary backgrounds and glyphs.
import Testing

import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

/// Locks the selection overlay into the executor's background-before-text layer order.
struct SelectionExecutionTests {
    @Test("selection overwrites cell backgrounds while text remains visible above it")
    func selectionDrawOrder() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        var terminal = try #require(Terminal(columns: 3, rows: 1))
        terminal.feed(Array("\u{1B}[41;37mA".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 1)
        ))
        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )

        let bitmap = try renderBitmap(plan: plan, metrics: metrics)
        let selectedPixels = bitmap.pixels(in: cellRect(row: 0, column: 0, metrics: metrics))
        let selection = Pixel(RenderTheme.dark.selectionBackground)

        #expect(selectedPixels.contains(selection))
        #expect(selectedPixels.contains { $0 != selection })
        #expect(selectedPixels.contains(Pixel(RenderTheme.dark.ansiColors[1])) == false)
    }
}
