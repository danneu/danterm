// Behavioral proofs for complete, canonical viewport frame planning.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

struct RenderFramePlanningTests {
    @Test("Frame planning preserves exact glyph payloads and canonical split keys")
    func textRunContentAndSplitting() throws {
        var terminal = try #require(Terminal(columns: 10, rows: 1))
        feed(
            "e\u{301}\u{1B}[4m \u{1B}[24;31mR\u{1B}[1mB\u{1B}[3mI",
            to: &terminal
        )

        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
        )

        #expect(plan.columns == 10)
        #expect(plan.rows == 1)
        #expect(plan.defaultBackground == RenderTheme.dark.defaultBackground)
        try #require(plan.textRuns.count == 4)
        #expect(plan.textRuns[0].startColumn == 0)
        #expect(plan.textRuns[0].cells == [
            RenderTextCell(scalars: Array("e\u{301}".unicodeScalars), columnWidth: 1),
            RenderTextCell(scalars: Array(" ".unicodeScalars), columnWidth: 1),
        ])
        #expect(plan.textRuns[0].foreground == RenderTheme.dark.defaultForeground)
        #expect(plan.textRuns[1].startColumn == 2)
        #expect(plan.textRuns[1].foreground == RenderTheme.dark.ansiColors[1])
        #expect(plan.textRuns[2].bold)
        #expect(plan.textRuns[3].italic)
        #expect(plan.decorationRuns == [
            RenderDecorationRun(
                row: 0,
                startColumn: 1,
                columnCount: 1,
                kinds: [.underlineSingle],
                color: RenderTheme.dark.defaultForeground
            ),
        ])
        assertCanonical(plan)
    }

    @Test("Every decoration kind survives and coexisting kinds never overlap")
    func decorationKinds() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        feed(
            "\u{1B}[38;2;100;80;60;48;2;20;40;60;7;2;4mA"
                + "\u{1B}[0;21mB\u{1B}[24m\u{1B}[4:3mC"
                + "\u{1B}[24;9mD\u{1B}[4mE",
            to: &terminal
        )

        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
        )

        try #require(plan.textRuns.count == 2)
        #expect(plan.textRuns[1].cells.count == 4)
        #expect(plan.decorationRuns.map(\.kinds) == [
            [.underlineSingle],
            [.underlineDouble],
            [.underlineCurly],
            [.strikethrough],
            [.underlineSingle, .strikethrough],
        ])
        #expect(plan.decorationRuns.map(\.startColumn) == [0, 1, 2, 3, 4])
        let firstDecoration = try #require(plan.decorationRuns.first)
        #expect(firstDecoration.color == RenderColor(red: 10, green: 20, blue: 30))
        assertCanonical(plan)
    }

    @Test("Reverse and hidden retain post-resolution backgrounds without invisible work")
    func reverseAndHiddenLayers() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        feed("\u{1B}[31;42;7mA\u{1B}[8;4;9mB", to: &terminal)

        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
        )

        #expect(plan.backgroundRuns == [
            RenderBackgroundRun(
                row: 0,
                startColumn: 0,
                columnCount: 2,
                color: RenderTheme.dark.ansiColors[1]
            ),
        ])
        try #require(plan.textRuns.count == 1)
        #expect(plan.textRuns[0].startColumn == 0)
        #expect(plan.textRuns[0].foreground == RenderTheme.dark.ansiColors[2])
        #expect(plan.decorationRuns.isEmpty)
        assertCanonical(plan)
    }

    @Test("Background planning trims default padding and maximally coalesces erased cells")
    func backgroundTrimmingAndErase() throws {
        var untouched = try #require(Terminal(columns: 5, rows: 2))
        let untouchedPlan = planFrame(
            for: untouched,
            presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
        )
        #expect(untouchedPlan.backgroundRuns.isEmpty)

        feed("\u{1B}[41m\u{1B}[2J", to: &untouched)
        let erasedPlan = planFrame(
            for: untouched,
            presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
        )

        #expect(erasedPlan.backgroundRuns == [
            RenderBackgroundRun(
                row: 0,
                startColumn: 0,
                columnCount: 5,
                color: RenderTheme.dark.ansiColors[1]
            ),
            RenderBackgroundRun(
                row: 1,
                startColumn: 0,
                columnCount: 5,
                color: RenderTheme.dark.ansiColors[1]
            ),
        ])
        assertCanonical(erasedPlan)
    }

    @Test("Wide cells use head geometry while tails and wrap spacers stay textless")
    func wideCellAndSpacerGeometry() throws {
        var terminal = try #require(Terminal(columns: 3, rows: 2))
        feed("\u{1B}[4;44mAB\u{754C}", to: &terminal)

        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
        )

        #expect(terminal.geometry.rows[0].cells.map(\.kind) == [.narrow, .narrow, .spacerHead])
        #expect(terminal.geometry.rows[1].cells.map(\.kind) == [.wideHead, .wideTail, .padding])
        try #require(plan.textRuns.count == 2)
        #expect(plan.textRuns[0].cells.map(\.columnWidth) == [1, 1])
        #expect(plan.textRuns[1].cells == [
            RenderTextCell(scalars: Array("\u{754C}".unicodeScalars), columnWidth: 2),
        ])
        #expect(plan.backgroundRuns.map(\.columnCount) == [3, 2])
        #expect(plan.decorationRuns.map(\.columnCount) == [2, 2])
        assertCanonical(plan)
    }

    @Test("Cursor visibility controls span, snapping, pending wrap, and style overrides")
    func cursorPlanning() throws {
        let narrow = try plannedCursor(after: "A\u{1B}[1;1H", columns: 3)
        #expect(narrow.cursor == RenderCursor(row: 0, column: 0, columnWidth: 1))

        let wideHead = try plannedCursor(after: "\u{754C}\u{1B}[1;1H", columns: 3)
        #expect(wideHead.cursor == RenderCursor(row: 0, column: 0, columnWidth: 2))

        let wideTail = try plannedCursor(after: "\u{754C}\u{1B}[1;2H", columns: 3)
        #expect(wideTail.cursor == RenderCursor(row: 0, column: 0, columnWidth: 2))

        var pendingTerminal = try #require(Terminal(columns: 2, rows: 1))
        feed("AB", to: &pendingTerminal)
        try #require(pendingTerminal.geometry.cursor.isPendingWrap)
        let pendingWrap = planFrame(
            for: pendingTerminal,
            presentation: RenderPresentation(theme: .dark, isCursorVisible: true)
        )
        #expect(pendingWrap.cursor == RenderCursor(row: 0, column: 1, columnWidth: 1))

        let styledWide = try plannedCursor(
            after: "\u{1B}[31;44;4m\u{754C}\u{1B}[1;1H",
            columns: 3
        )
        let wideBackground = try #require(styledWide.backgroundRuns.first)
        let wideText = try #require(styledWide.textRuns.first)
        let wideDecoration = try #require(styledWide.decorationRuns.first)
        #expect(wideBackground.columnCount == 2)
        #expect(wideBackground.color == RenderTheme.dark.cursor)
        #expect(wideText.foreground == RenderTheme.dark.cursorText)
        #expect(wideDecoration.columnCount == 2)
        #expect(wideDecoration.color == RenderTheme.dark.cursorText)
    }

    @Test("Cursor overrides every visible layer but preserves hidden suppression")
    func cursorLayerOverridesAndInvisibility() throws {
        var terminal = try #require(Terminal(columns: 3, rows: 1))
        feed("\u{1B}[31;44;4mA\u{1B}[1;1H", to: &terminal)
        let presentation = RenderPresentation(theme: .dark, isCursorVisible: true)
        let visible = planFrame(for: terminal, presentation: presentation)

        let visibleBackground = try #require(visible.backgroundRuns.first)
        let visibleText = try #require(visible.textRuns.first)
        let visibleDecoration = try #require(visible.decorationRuns.first)
        #expect(visibleBackground.color == RenderTheme.dark.cursor)
        #expect(visibleText.foreground == RenderTheme.dark.cursorText)
        #expect(visibleDecoration.color == RenderTheme.dark.cursorText)

        let invisible = planFrame(
            for: terminal,
            presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
        )
        #expect(invisible.cursor == nil)
        let invisibleBackground = try #require(invisible.backgroundRuns.first)
        let invisibleText = try #require(invisible.textRuns.first)
        let invisibleDecoration = try #require(invisible.decorationRuns.first)
        #expect(invisibleBackground.color == RenderTheme.dark.ansiColors[4])
        #expect(invisibleText.foreground == RenderTheme.dark.ansiColors[1])
        #expect(invisibleDecoration.color == RenderTheme.dark.ansiColors[1])

        var hiddenTerminal = try #require(Terminal(columns: 3, rows: 1))
        feed("\u{1B}[8;4;9mA\u{1B}[1;1H", to: &hiddenTerminal)
        let hidden = planFrame(for: hiddenTerminal, presentation: presentation)
        #expect(hidden.cursor == RenderCursor(row: 0, column: 0, columnWidth: 1))
        let hiddenBackground = try #require(hidden.backgroundRuns.first)
        #expect(hiddenBackground.color == RenderTheme.dark.cursor)
        #expect(hidden.textRuns.isEmpty)
        #expect(hidden.decorationRuns.isEmpty)
    }

    @Test("Plans ignore scrollback and an unwritten live pen")
    func viewportOnlyInputs() throws {
        var withScrollback = try #require(Terminal(columns: 2, rows: 1))
        feed("A\r\nB", to: &withScrollback)
        var withoutScrollback = try #require(Terminal(columns: 2, rows: 1))
        feed("B", to: &withoutScrollback)

        #expect(withScrollback.scrollbackRowCount == 1)
        #expect(withoutScrollback.scrollbackRowCount == 0)
        #expect(withScrollback.geometry == withoutScrollback.geometry)
        #expect(viewportCells(withScrollback) == viewportCells(withoutScrollback))
        #expect(invisiblePlan(withScrollback) == invisiblePlan(withoutScrollback))

        var changedPen = withoutScrollback
        feed("\u{1B}[31;1m", to: &changedPen)
        #expect(changedPen.currentStyle != withoutScrollback.currentStyle)
        #expect(invisiblePlan(changedPen) == invisiblePlan(withoutScrollback))
    }

    private func plannedCursor(after input: String, columns: Int) throws -> RenderFramePlan {
        var terminal = try #require(Terminal(columns: columns, rows: 1))
        feed(input, to: &terminal)
        return planFrame(
            for: terminal,
            presentation: RenderPresentation(theme: .dark, isCursorVisible: true)
        )
    }
}

private func feed(_ text: String, to terminal: inout Terminal) {
    terminal.feed(Array(text.utf8))
}

private func invisiblePlan(_ terminal: Terminal) -> RenderFramePlan {
    planFrame(
        for: terminal,
        presentation: RenderPresentation(theme: .dark, isCursorVisible: false)
    )
}

private func viewportCells(_ terminal: Terminal) -> [TerminalCell] {
    let geometry = terminal.geometry
    return (0..<geometry.rows.count).flatMap { row in
        (0..<geometry.columns).compactMap { column in
            terminal.cell(row: row, column: column)
        }
    }
}
