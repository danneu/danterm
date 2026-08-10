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
        let selection = Pixel(try #require(plan.overlayRuns.first?.color))
        let foreground = Pixel(try #require(plan.textRuns.first?.foreground))

        #expect(selectedPixels.contains(selection))
        #expect(selectedPixels.contains(foreground))
        #expect(selectedPixels.contains(Pixel(RenderTheme.dark.ansiColors[1])) == false)
    }

    @Test("selection foreground draws above a search match while a block cursor stays intact")
    func selectionForegroundAndCursorPrecedence() throws {
        // Intent: selection changes glyph foreground above a search highlight, while
        //   a selected block-cursor cell still paints cursor text on cursor background.
        // Why it exists: planning the right colors does not prove executor layer order;
        //   highlight fills can overwrite a block cursor before glyph drawing.
        // Scenario: selected text spans the active search match and the visible block
        //   cursor at the same time.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let theme = try selectionTheme()
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array("AB\u{1B}[1;2H".utf8))
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

        let bitmap = try renderBitmap(plan: plan, metrics: metrics)
        let matched = bitmap.pixels(in: cellRect(row: 0, column: 0, metrics: metrics))
        let combined = try #require(plan.overlayRuns.first {
            $0.state == .selectionAndActiveSearchMatch
        })
        let combinedText = try #require(plan.textRuns.first { $0.startColumn == 0 })
        #expect(matched.contains(Pixel(combined.color)))
        #expect(matched.contains(Pixel(combinedText.foreground)))

        let cursor = bitmap.pixels(in: cellRect(row: 0, column: 1, metrics: metrics))
        let cursorPlan = try #require(plan.cursor)
        let cursorText = try #require(plan.textRuns.first { $0.startColumn == 1 })
        #expect(cursor.contains(Pixel(cursorPlan.color)))
        #expect(cursor.contains(Pixel(cursorText.foreground)))
        #expect(cursor.contains(Pixel(theme.selectionBackground)) == false)
    }

    private func selectionTheme() throws -> RenderTheme {
        let colors = (0..<16).map { index in
            RenderColor(red: UInt8(index), green: UInt8(index), blue: UInt8(index))
        }
        return RenderTheme(
            ansiColors: try #require(RenderANSIColors(exactly: colors)),
            defaultForeground: .init(red: 240, green: 240, blue: 240),
            defaultBackground: .init(red: 1, green: 2, blue: 3),
            selectionForeground: .init(red: 220, green: 221, blue: 222),
            selectionBackground: .init(red: 30, green: 31, blue: 32),
            cursor: .init(red: 60, green: 61, blue: 62),
            cursorText: .init(red: 250, green: 251, blue: 252)
        )
    }
}
