// Pixel proofs that selection is executed between ordinary backgrounds and glyphs.
import Testing

import TerminalCore
import TerminalRenderExecution
import TerminalRenderPlanning

/// Locks the selection overlay into the executor's background-before-text layer order.
struct SelectionExecutionTests {
    // Intent: selection remains visibly painted over both the pane canvas and a
    //   nearby TUI surface instead of reproducing canvas-colored pixels.
    // Why it exists: planning contrast does not prove the executor covers the
    //   painted band; the original incident looked like a hole in that surface.
    // Scenario: one selected cell uses the default canvas and its neighbor uses
    //   the Claude Code user-message band under Monokai Remastered colors.
    @Test("selection paints a dark TUI band distinctly from the pane canvas")
    func selectionDoesNotErasePaintedBandToCanvas() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let canvas = RenderColor(red: 12, green: 12, blue: 12)
        let band = RenderColor(red: 55, green: 55, blue: 55)
        let theme = try selectionTheme(
            defaultForeground: RenderColor(red: 217, green: 217, blue: 217),
            defaultBackground: canvas,
            selectionBackground: RenderColor(red: 52, green: 52, blue: 52)
        )
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array("A\u{1B}[48;2;55;55;55mB".utf8))
        terminal.setSelection(.init(
            start: .init(row: 0, column: 0),
            end: .init(row: 0, column: 2)
        ))
        let plan = planFrame(
            for: terminal,
            presentation: .init(theme: theme, isCursorVisible: false, cursorShape: .block)
        )

        let bitmap = try renderBitmap(plan: plan, metrics: metrics)
        let bandRun = try #require(plan.overlayRuns.first { $0.startColumn == 1 })
        let bandPixels = bitmap.pixels(in: cellRect(row: 0, column: 1, metrics: metrics))

        #expect(testBrightnessSeparation(bandRun.color, canvas) >= 40)
        #expect(testBrightnessSeparation(bandRun.color, band) >= 40)
        #expect(bandPixels.contains(Pixel(bandRun.color)))
        #expect(bandPixels.contains(Pixel(canvas)) == false)
    }

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

    private func selectionTheme(
        defaultForeground: RenderColor = RenderColor(red: 240, green: 240, blue: 240),
        defaultBackground: RenderColor = RenderColor(red: 1, green: 2, blue: 3),
        selectionBackground: RenderColor = RenderColor(red: 30, green: 31, blue: 32)
    ) throws -> RenderTheme {
        let colors = (0..<16).map { index in
            RenderColor(red: UInt8(index), green: UInt8(index), blue: UInt8(index))
        }
        return RenderTheme(
            ansiColors: try #require(RenderANSIColors(exactly: colors)),
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground,
            selectionForeground: .init(red: 220, green: 221, blue: 222),
            selectionBackground: selectionBackground,
            cursor: .init(red: 60, green: 61, blue: 62),
            cursorText: .init(red: 250, green: 251, blue: 252)
        )
    }

    private func testBrightnessSeparation(_ first: RenderColor, _ second: RenderColor) -> Int {
        func brightness(_ color: RenderColor) -> Int {
            (77 * Int(color.red) + 151 * Int(color.green) + 28 * Int(color.blue)) >> 8
        }
        return abs(brightness(first) - brightness(second))
    }
}
