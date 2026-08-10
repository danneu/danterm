// Characterization proofs for the inputs overlay colorization resolves against
// and the boundaries it is allowed to draw. Written before run-level colorize
// replaced the per-cell overlay pass, so every expectation here is the
// pre-refactor planner's own output and any drift is a regression, not a
// restatement. Broader selection and search behavior stays in the layer-named
// suites; only the colorization contract lives here.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

/// Pins overlay fills to the cell background beneath them, overlay boundaries to
/// the columns the selection actually covers, and coalescing to final colors.
struct OverlayColorizationTests {
    // Intent: an overlay fill resolves against the cell's own background, not
    // against the background a block cursor bakes into the same cell.
    // Why it exists: the cursor rewrite and the overlay resolution both claim the
    // background of the cursor cell, and resolving in the wrong order would both
    // recolor the overlay and split its run at the cursor column.
    // Scenario: a three-cell selection over a non-default background with the
    // block cursor parked in its middle.
    @Test("A block cursor inside a selection neither recolors nor splits the overlay")
    func blockCursorInsideSelectionOverNonDefaultBackground() throws {
        let theme = try colorizationTheme()
        let background = RenderColor(red: 140, green: 140, blue: 140)
        var terminal = try #require(Terminal(columns: 3, rows: 1))
        terminal.feed(Array("\u{1B}[48;2;140;140;140mABC\u{1B}[1;2H".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 3)
        ))

        let plan = planFrame(
            for: terminal,
            presentation: .init(theme: theme, isCursorVisible: true, cursorShape: .block)
        )

        let selected = resolveOverlayStyle(
            state: .selection,
            background: background,
            foreground: theme.selectionForeground,
            theme: theme
        )
        let cursor = resolveCursorStyle(background: selected.fill, theme: theme)

        #expect(plan.overlayRuns == [
            RenderOverlayRun(
                row: 0,
                startColumn: 0,
                columnCount: 3,
                state: .selection,
                color: selected.fill
            ),
        ])
        #expect(plan.backgroundRuns.map { [$0.startColumn, $0.columnCount] } == [
            [0, 1], [1, 1], [2, 1],
        ])
        #expect(plan.backgroundRuns.map(\.color) == [background, cursor.fill, background])
        #expect(plan.textRuns.map(\.startColumn) == [0, 1, 2])
        #expect(plan.textRuns.map(\.foreground) == [
            selected.foreground,
            cursor.foreground,
            selected.foreground,
        ])
        #expect(plan.cursor?.color == cursor.fill)
        assertCanonical(plan)
    }

    // Intent: a selection edge aimed inside a wide glyph moves every layer
    // together -- overlay coverage, the glyph's color, and its decorations all
    // start at the glyph's head column.
    // Why it exists: overlay coverage and decoration recoloring are attributed per
    // column while glyph recoloring follows the cell's start column, so a mid-glyph
    // boundary is the one input where the three could disagree. `setSelection`
    // snaps both endpoints to cell boundaries, which is what makes them agree; a
    // colorize step that split the text layer per column instead would still pass
    // every other selection proof.
    // Scenario: a selection asked to start on the tail column of a
    // struck-through wide glyph.
    @Test("A selection edge inside a wide glyph moves every layer to the head column")
    func selectionEdgeInsideWideGlyph() throws {
        let theme = try colorizationTheme()
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("\u{1B}[9mA\u{6F22}".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 2),
            end: TerminalTextPosition(row: 0, column: 4)
        ))

        let plan = planFrame(
            for: terminal,
            presentation: .init(theme: theme, isCursorVisible: false, cursorShape: .block)
        )

        let selected = resolveOverlayStyle(
            state: .selection,
            background: theme.defaultBackground,
            foreground: theme.selectionForeground,
            theme: theme
        )

        #expect(plan.overlayRuns == [
            RenderOverlayRun(
                row: 0,
                startColumn: 1,
                columnCount: 3,
                state: .selection,
                color: selected.fill
            ),
        ])
        #expect(plan.textRuns.map(\.startColumn) == [0, 1])
        #expect(plan.textRuns.map { $0.cells.map(\.columnWidth) } == [[1], [2]])
        #expect(plan.textRuns.map(\.foreground) == [
            theme.defaultForeground,
            selected.foreground,
        ])
        #expect(plan.decorationRuns.map { [$0.startColumn, $0.columnCount] } == [[0, 1], [1, 2]])
        #expect(plan.decorationRuns.map(\.color) == [
            theme.defaultForeground,
            selected.foreground,
        ])
        assertCanonical(plan)
    }

    // Intent: coalescing is decided by the colors that reach the plan, not by the
    // inputs that produced them.
    // Why it exists: run-level colorization introduces fragment boundaries at
    // background transitions and at base-foreground transitions, and a fragment
    // boundary whose two sides resolve to the same color must leave no seam.
    // Scenario: an active search match spanning two cells whose backgrounds
    // differ but share a brightness, carrying two foregrounds that both push to
    // black against the match fill.
    @Test("Fragments that resolve to equal colors emit one merged run per layer")
    func coincidentallyEqualColorsCoalesce() throws {
        let theme = try colorizationTheme()
        let firstBackground = RenderColor(red: 140, green: 140, blue: 140)
        let secondBackground = RenderColor(red: 255, green: 108, blue: 0)
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array(
            "\u{1B}[38;2;255;0;0;48;2;140;140;140mA\u{1B}[38;2;0;0;255;48;2;255;108;0mB".utf8
        ))
        let found = terminal.beginSearch("AB")
        try #require(found)

        let plan = planFrame(
            for: terminal,
            presentation: .init(theme: theme, isCursorVisible: false, cursorShape: .block)
        )

        let overFirst = resolveOverlayStyle(
            state: .activeSearchMatch,
            background: firstBackground,
            foreground: RenderColor(red: 255, green: 0, blue: 0),
            theme: theme
        )
        let overSecond = resolveOverlayStyle(
            state: .activeSearchMatch,
            background: secondBackground,
            foreground: RenderColor(red: 0, green: 0, blue: 255),
            theme: theme
        )
        // The scenario is only meaningful while both halves still resolve alike;
        // these two are its preconditions, not its subject.
        #expect(overFirst.fill == overSecond.fill)
        #expect(overFirst.foreground == overSecond.foreground)

        #expect(plan.backgroundRuns.map(\.color) == [firstBackground, secondBackground])
        #expect(plan.overlayRuns == [
            RenderOverlayRun(
                row: 0,
                startColumn: 0,
                columnCount: 2,
                state: .activeSearchMatch,
                color: overFirst.fill
            ),
        ])
        #expect(plan.textRuns.count == 1)
        #expect(plan.textRuns.first?.startColumn == 0)
        #expect(plan.textRuns.first?.cells.count == 2)
        #expect(plan.textRuns.first?.foreground == overFirst.foreground)
        assertCanonical(plan)
    }

    /// Fixes every color these proofs reason about, so a themed default cannot
    /// quietly move a fill out of the brightness band the scenarios depend on.
    private func colorizationTheme() throws -> RenderTheme {
        let colors: [RenderColor] = (0..<16).map { index in
            let component = UInt8(16 * index)
            return RenderColor(red: component, green: component, blue: component)
        }
        let palette = try #require(RenderANSIColors(exactly: colors))
        return RenderTheme(
            ansiColors: palette,
            defaultForeground: RenderColor(red: 200, green: 200, blue: 200),
            defaultBackground: RenderColor(red: 0, green: 0, blue: 0),
            selectionForeground: RenderColor(red: 240, green: 240, blue: 240),
            selectionBackground: RenderColor(red: 220, green: 220, blue: 220),
            cursor: RenderColor(red: 255, green: 255, blue: 255),
            cursorText: RenderColor(red: 0, green: 0, blue: 0)
        )
    }
}
