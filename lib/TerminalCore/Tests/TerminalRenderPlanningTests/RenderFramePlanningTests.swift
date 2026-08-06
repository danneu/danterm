// Behavioral proofs for complete, canonical viewport frame planning.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

struct RenderFramePlanningTests {
    @Test("Baked terminal defaults match the dark theme and planned frame")
    func bakedDefaultsMatchPresentation() throws {
        let defaults = TerminalDefaultColors.baked
        let expectedForeground = RenderColor(
            red: defaults.foreground.red,
            green: defaults.foreground.green,
            blue: defaults.foreground.blue
        )
        let expectedBackground = RenderColor(
            red: defaults.background.red,
            green: defaults.background.green,
            blue: defaults.background.blue
        )
        var terminal = try #require(Terminal(columns: 2, rows: 1))
        terminal.feed(Array("A".utf8))
        let plan = planFrame(
            for: terminal,
            presentation: .init(theme: .dark, isCursorVisible: false, cursorShape: .block)
        )

        #expect(RenderTheme.dark.defaultForeground == expectedForeground)
        #expect(RenderTheme.dark.defaultBackground == expectedBackground)
        #expect(plan.defaultBackground == expectedBackground)
        #expect(plan.textRuns.first?.foreground == expectedForeground)
    }

    @Test("Hovered links gain a single underline without replacing stronger decorations")
    func hoveredLinkDecoration() throws {
        var plain = try #require(Terminal(columns: 24, rows: 2))
        feed("https://a.co", to: &plain)
        let plainLink = try #require(plain.activatableLink(at: .init(row: 0, column: 2)))
        let admittedPlain = plain.setHoveredLink(plainLink)
        #expect(admittedPlain)
        let plainPlan = invisiblePlan(plain)
        #expect(plainPlan.decorationRuns == [
            RenderDecorationRun(
                row: 0,
                startColumn: 0,
                columnCount: 12,
                kinds: [.underlineSingle],
                color: RenderTheme.dark.defaultForeground
            ),
        ])

        var decorated = try #require(Terminal(columns: 24, rows: 2))
        feed("\u{1B}[4:3mhttps://a.co", to: &decorated)
        let decoratedLink = try #require(decorated.activatableLink(at: .init(row: 0, column: 2)))
        let admittedDecorated = decorated.setHoveredLink(decoratedLink)
        #expect(admittedDecorated)
        #expect(invisiblePlan(decorated).decorationRuns.map(\.kinds) == [[.underlineCurly]])

        let clipped = clipFramePlan(plainPlan, to: TerminalDamage(rows: [1]))
        #expect(clipped.decorationRuns.isEmpty)
    }
    @Test("Damage clipping keeps only visible damaged rows and preserves full plans")
    func damageClipping() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        feed("A\r\n\u{1B}[41mB\r\n\u{1B}[4mC", to: &terminal)
        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: true,
                cursorShape: .block
            )
        )

        let damage = TerminalDamage(rows: [-1, 1, 5])
        let first = clipFramePlan(plan, to: damage)
        let second = clipFramePlan(plan, to: damage)

        #expect(first == second)
        #expect(first.backgroundRuns.allSatisfy { $0.row == 1 })
        #expect(first.overlayRuns.allSatisfy { $0.row == 1 })
        #expect(first.textRuns.allSatisfy { $0.row == 1 })
        #expect(first.decorationRuns.allSatisfy { $0.row == 1 })
        #expect(first.cursor == nil)
        #expect(clipFramePlan(plan, to: .full) == plan)
        #expect(clipFramePlan(plan, to: .none).backgroundRuns.isEmpty)
        #expect(clipFramePlan(plan, to: .none).textRuns.isEmpty)
    }

    @Test("Damage naming every viewport row preserves the complete frame plan")
    func exhaustiveRowDamagePreservesPlan() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        feed("A\r\n\u{1B}[41mB\r\n\u{1B}[4mC", to: &terminal)
        let plan = invisiblePlan(terminal)

        let clipped = clipFramePlan(plan, to: TerminalDamage(rows: Set(0..<plan.rows)))

        #expect(clipped == plan)
    }

    @Test("Out-of-range damage cannot substitute for a missing viewport row")
    func outOfRangeDamageDoesNotQualifyAsExhaustive() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        feed("A\r\n\u{1B}[41mB\r\n\u{1B}[4mC", to: &terminal)
        let plan = invisiblePlan(terminal)

        let clipped = clipFramePlan(plan, to: TerminalDamage(rows: [0, 1, plan.rows]))

        #expect(clipped != plan)
        #expect(clipped.textRuns.allSatisfy { $0.row < 2 })
    }

    @Test("Frame planning preserves exact glyph payloads and canonical split keys")
    func textRunContentAndSplitting() throws {
        var terminal = try #require(Terminal(columns: 10, rows: 1))
        feed(
            "e\u{301}\u{1B}[4m \u{1B}[24;31mR\u{1B}[1mB\u{1B}[3mI",
            to: &terminal
        )

        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )

        #expect(plan.columns == 10)
        #expect(plan.rows == 1)
        #expect(plan.defaultBackground == RenderTheme.dark.defaultBackground)
        try #require(plan.textRuns.count == 4)
        #expect(plan.textRuns[0].startColumn == 0)
        #expect(plan.textRuns[0].cells == [
            RenderTextCell(scalars: TerminalScalars("e\u{301}".unicodeScalars), columnWidth: 1),
            RenderTextCell(scalars: TerminalScalars(" ".unicodeScalars), columnWidth: 1),
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
                + "\u{1B}[24;9mD\u{1B}[4mE\u{1B}[4:4;58:5:1mF"
                + "\u{1B}[4:5;58:2:1:2:3mG",
            to: &terminal
        )

        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )

        try #require(plan.textRuns.count == 2)
        #expect(plan.textRuns[1].cells.count == 6)
        #expect(plan.decorationRuns.map(\.kinds) == [
            [.underlineSingle],
            [.underlineDouble],
            [.underlineCurly],
            [.strikethrough],
            [.underlineSingle, .strikethrough],
            [.underlineDotted, .strikethrough],
            [.underlineDashed, .strikethrough],
        ])
        #expect(plan.decorationRuns.map(\.startColumn) == [0, 1, 2, 3, 4, 5, 6])
        let firstDecoration = try #require(plan.decorationRuns.first)
        #expect(firstDecoration.color == RenderColor(red: 10, green: 20, blue: 30))
        #expect(plan.decorationRuns[5].color == RenderTheme.dark.ansiColors[1])
        #expect(plan.decorationRuns[6].color == RenderColor(red: 1, green: 2, blue: 3))
        #expect(plan.decorationRuns[5].strikethroughColor == RenderTheme.dark.defaultForeground)
        #expect(plan.decorationRuns[6].strikethroughColor == RenderTheme.dark.defaultForeground)
        assertCanonical(plan)
    }

    @Test("Reverse and hidden retain post-resolution backgrounds without invisible work")
    func reverseAndHiddenLayers() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        feed("\u{1B}[31;42;7mA\u{1B}[8;4;9mB", to: &terminal)

        let plan = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
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
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )
        #expect(untouchedPlan.backgroundRuns.isEmpty)

        feed("\u{1B}[41m\u{1B}[2J", to: &untouched)
        let erasedPlan = planFrame(
            for: untouched,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
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
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: false,
                cursorShape: .block
            )
        )

        #expect(terminal.geometry.rows[0].cells.map(\.kind) == [.narrow, .narrow, .spacerHead])
        #expect(terminal.geometry.rows[1].cells.map(\.kind) == [.wideHead, .wideTail, .padding])
        try #require(plan.textRuns.count == 2)
        #expect(plan.textRuns[0].cells.map(\.columnWidth) == [1, 1])
        #expect(plan.textRuns[1].cells == [
            RenderTextCell(scalars: TerminalScalars("\u{754C}".unicodeScalars), columnWidth: 2),
        ])
        #expect(plan.backgroundRuns.map(\.columnCount) == [3, 2])
        #expect(plan.decorationRuns.map(\.columnCount) == [2, 2])
        assertCanonical(plan)
    }

    @Test("Cursor visibility controls span, pending wrap, and wide-cell style overrides")
    func cursorPlanning() throws {
        let narrow = try plannedCursor(after: "A\u{1B}[1;1H", columns: 3)
        #expect(narrow.cursor == RenderCursor(
            row: 0,
            column: 0,
            columnWidth: 1,
            shape: .block,
            color: RenderTheme.dark.cursor
        ))

        // Wide-head and wide-tail snapping lives in `cursorShapeWideCellSnapping`, which
        // runs these same two inputs for every cursor shape.
        var pendingTerminal = try #require(Terminal(columns: 2, rows: 1))
        feed("AB", to: &pendingTerminal)
        #expect(pendingTerminal.geometry.cursor?.isPendingWrap == true)
        let pendingWrap = planFrame(
            for: pendingTerminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: true,
                cursorShape: .block
            )
        )
        #expect(pendingWrap.cursor == RenderCursor(
            row: 0,
            column: 1,
            columnWidth: 1,
            shape: .block,
            color: RenderTheme.dark.cursor
        ))

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

    @Test("A hidden cell under a block cursor plans the cursor background but no text")
    func hiddenCellUnderBlockCursor() throws {
        // Intent: SGR 8 suppresses the text and decoration runs of the cell the block
        //   cursor covers, while the cursor's own background fill still lands.
        // Why it exists: the block-cursor override rewrites foreground, background, and
        //   underline color, so it is the step most likely to resurrect a hidden cell's
        //   glyph; the visible-cursor and invisible-cursor layer values are pinned by
        //   `cursorShapes`, which asserts them for every shape.
        let presentation = RenderPresentation(
            theme: .dark,
            isCursorVisible: true,
            cursorShape: .block
        )

        var hiddenTerminal = try #require(Terminal(columns: 3, rows: 1))
        feed("\u{1B}[8;4;9mA\u{1B}[1;1H", to: &hiddenTerminal)
        let hidden = planFrame(for: hiddenTerminal, presentation: presentation)
        #expect(hidden.cursor == RenderCursor(
            row: 0,
            column: 0,
            columnWidth: 1,
            shape: .block,
            color: RenderTheme.dark.cursor
        ))
        let hiddenBackground = try #require(hidden.backgroundRuns.first)
        #expect(hiddenBackground.color == RenderTheme.dark.cursor)
        #expect(hidden.textRuns.isEmpty)
        #expect(hidden.decorationRuns.isEmpty)
    }

    @Test("Cursor shapes preserve block overrides and plan underline and bar overlays")
    func cursorShapes() throws {
        var terminal = try #require(Terminal(columns: 3, rows: 1))
        feed("\u{1B}[31;44;4mA\u{1B}[1;1H", to: &terminal)

        let block = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: true,
                cursorShape: .block
            )
        )
        let underline = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: true,
                cursorShape: .underline
            )
        )
        let bar = planFrame(
            for: terminal,
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: true,
                cursorShape: .bar
            )
        )

        #expect(block.cursor == RenderCursor(
            row: 0,
            column: 0,
            columnWidth: 1,
            shape: .block,
            color: RenderTheme.dark.cursor
        ))
        #expect(block.backgroundRuns.first?.color == RenderTheme.dark.cursor)
        #expect(block.textRuns.first?.foreground == RenderTheme.dark.cursorText)
        #expect(block.decorationRuns.first?.color == RenderTheme.dark.cursorText)

        for overlay in [underline, bar] {
            #expect(overlay.backgroundRuns.first?.color == RenderTheme.dark.ansiColors[4])
            #expect(overlay.textRuns.first?.foreground == RenderTheme.dark.ansiColors[1])
            #expect(overlay.decorationRuns.first?.color == RenderTheme.dark.ansiColors[1])
            #expect(overlay.cursor?.color == RenderTheme.dark.cursor)
        }
        #expect(underline.cursor?.shape == .underline)
        #expect(bar.cursor?.shape == .bar)

        for shape in [TerminalCursorShape.block, .underline, .bar] {
            let hidden = planFrame(
                for: terminal,
                presentation: RenderPresentation(
                    theme: .dark,
                    isCursorVisible: false,
                    cursorShape: shape
                )
            )
            #expect(hidden.cursor == nil)
            #expect(hidden.backgroundRuns.first?.color == RenderTheme.dark.ansiColors[4])
            #expect(hidden.textRuns.first?.foreground == RenderTheme.dark.ansiColors[1])
            #expect(hidden.decorationRuns.first?.color == RenderTheme.dark.ansiColors[1])
        }
    }

    @Test("Every cursor shape shares wide-head and wide-tail snapping")
    func cursorShapeWideCellSnapping() throws {
        for shape in [TerminalCursorShape.block, .underline, .bar] {
            var head = try #require(Terminal(columns: 3, rows: 1))
            feed("\u{754C}\u{1B}[1;1H", to: &head)
            let headPlan = planFrame(
                for: head,
                presentation: .init(
                    theme: .dark,
                    isCursorVisible: true,
                    cursorShape: shape
                )
            )

            var tail = try #require(Terminal(columns: 3, rows: 1))
            feed("\u{754C}\u{1B}[1;2H", to: &tail)
            let tailPlan = planFrame(
                for: tail,
                presentation: .init(
                    theme: .dark,
                    isCursorVisible: true,
                    cursorShape: shape
                )
            )

            let expected = RenderCursor(
                row: 0,
                column: 0,
                columnWidth: 2,
                shape: shape,
                color: RenderTheme.dark.cursor
            )
            #expect(headPlan.cursor == expected)
            #expect(tailPlan.cursor == expected)
        }
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
            presentation: RenderPresentation(
                theme: .dark,
                isCursorVisible: true,
                cursorShape: .block
            )
        )
    }

    @Test("A grapheme cluster larger than inline scalar storage reaches the plan intact")
    func spilledClusterPayloadSurvivesPlanning() throws {
        // Intent: a cell whose payload is too large to hold inline is planned with every
        //   scalar, in order, in a single one-column text cell.
        // Why it exists: the cell payload keeps the empty and one-scalar cases off the
        //   heap and spills anything longer. Only the spill path can silently truncate or
        //   reorder, and before this the largest payload any planner test exercised was
        //   two scalars -- inside inline range, so the spill path was unproven end to end.
        // Scenario: a base letter carrying three combining marks, which the terminal
        //   stores as one cluster occupying one column.
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        feed("e\u{301}\u{327}\u{323}", to: &terminal)

        let plan = invisiblePlan(terminal)
        assertCanonical(plan)
        try #require(plan.textRuns.count == 1)
        #expect(plan.textRuns[0].cells == [
            RenderTextCell(
                scalars: TerminalScalars("e\u{301}\u{327}\u{323}".unicodeScalars),
                columnWidth: 1
            ),
        ])
    }

    @Test("Never-written cells contribute no text cells to the plan")
    func neverWrittenCellsAreOmittedFromTextRuns() throws {
        // Intent: cells that were never written produce no `RenderTextCell` at all,
        //   rather than a cell carrying an empty payload.
        // Why it exists: the planner reads every column of a damaged row and drops the
        //   ones with no content. Previously that filter was only observable through run
        //   start columns, so a change to how an absent payload is represented could have
        //   started emitting payload-free cells without any test noticing.
        // Scenario: two written columns separated by an untouched gap.
        var terminal = try #require(Terminal(columns: 6, rows: 1))
        feed("a\u{1B}[3Gb", to: &terminal)

        let plan = invisiblePlan(terminal)
        assertCanonical(plan)
        #expect(plan.textRuns.flatMap(\.cells).allSatisfy { $0.scalars.isEmpty == false })
        #expect(plan.textRuns.flatMap(\.cells).count == 2)
    }
}

private func feed(_ text: String, to terminal: inout Terminal) {
    terminal.feed(Array(text.utf8))
}

private func invisiblePlan(_ terminal: Terminal) -> RenderFramePlan {
    planFrame(
        for: terminal,
        presentation: RenderPresentation(
            theme: .dark,
            isCursorVisible: false,
            cursorShape: .block
        )
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
