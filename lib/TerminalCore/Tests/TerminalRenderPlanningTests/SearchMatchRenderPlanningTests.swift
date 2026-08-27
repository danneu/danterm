// Search-match overlay planning proofs: semantic overlap, viewport clipping,
// and survival through the damage-clipped plan the app actually draws.
import Testing

@testable import TerminalCore
@testable import TerminalRenderPlanning

/// Pins active matches and selections to one semantic overlay layer so their overlap
/// survives planning instead of being erased by painter order.
struct SearchMatchRenderPlanningTests {
    private let presentation = RenderPresentation(
        theme: .dark,
        isCursorVisible: false,
        cursorShape: .block
    )

    @Test("an in-viewport active match plans one run and no match means no runs")
    func inViewportMatchPlansRuns() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("zzhitz".utf8))

        #expect(planFrame(for: terminal, presentation: presentation).overlayRuns.isEmpty)

        let found = terminal.beginSearch("hit")
        #expect(found)
        let plan = planFrame(for: terminal, presentation: presentation)
        let match = resolveOverlayStyle(
            state: .activeSearchMatch,
            background: presentation.theme.defaultBackground,
            foreground: presentation.theme.defaultForeground,
            theme: presentation.theme
        )
        #expect(plan.overlayRuns == [
            RenderOverlayRun(
                startColumn: 2,
                columnCount: 3,
                state: .activeSearchMatch,
                color: match.fill
            ),
        ])
        assertCanonical(plan)

        terminal.clearSearch()
        #expect(planFrame(for: terminal, presentation: presentation).overlayRuns.isEmpty)
    }

    @Test("every visible search occurrence plans an overlay")
    func everyVisibleMatchPlansAnOverlay() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("hit hit\r\nhit".utf8))

        let found = terminal.beginSearch("hit")
        #expect(found)

        let plan = planFrame(for: terminal, presentation: presentation)
        #expect(plan.overlayRunsWithRows.map(\.row) == [0, 0, 1])
        #expect(plan.overlayRuns.map(\.startColumn) == [0, 4, 0])
        #expect(plan.overlayRuns.map(\.columnCount) == [3, 3, 3])
        #expect(plan.overlayRuns.map(\.state) == [
            .searchMatch,
            .searchMatch,
            .activeSearchMatch,
        ])
    }

    @Test("navigation moves the active overlay without changing visible match coverage")
    func navigationMovesOnlyTheActiveOverlay() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("hit hit".utf8))
        let found = terminal.beginSearch("hit")
        #expect(found)

        let newest = planFrame(for: terminal, presentation: presentation).overlayRuns
        #expect(newest.map(\.state) == [.searchMatch, .activeSearchMatch])

        let moved = terminal.searchNext()
        #expect(moved)
        let older = planFrame(for: terminal, presentation: presentation).overlayRuns
        #expect(older.map(\.startColumn) == newest.map(\.startColumn))
        #expect(older.map(\.columnCount) == newest.map(\.columnCount))
        #expect(older.map(\.state) == [.activeSearchMatch, .searchMatch])
    }

    @Test("matches crossing both viewport edges and soft wraps stay visible")
    func edgeCrossingMatchesStayVisible() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("xxxhit\r\nxxxhit\r\nmore".utf8))
        let found = terminal.beginSearch("hit")
        #expect(found)
        terminal.scroll(toTopRow: 1)

        let plan = planFrame(for: terminal, presentation: presentation)
        #expect(plan.overlayRunsWithRows.map(\.row) == [0, 1])
        #expect(plan.overlayRuns.map(\.startColumn) == [0, 3])
        #expect(plan.overlayRuns.map(\.columnCount) == [2, 1])
        #expect(plan.overlayRuns.map(\.state) == [.searchMatch, .activeSearchMatch])
    }

    @Test("selection overlap preserves selected and unselected match identities")
    func selectionOverlapPreservesMatchIdentity() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("hit hit".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 7)
        ))
        let found = terminal.beginSearch("hit")
        #expect(found)

        let states = planFrame(for: terminal, presentation: presentation).overlayRuns.map(\.state)
        #expect(states == [
            .selectionAndSearchMatch,
            .selection,
            .selectionAndActiveSearchMatch,
        ])
    }

    @Test("planning visible matches never materializes the whole terminal projection")
    func visibleMatchPlanningStaysWindowBounded() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        for _ in 0..<100 {
            terminal.feed(Array("hit row\r\n".utf8))
        }
        _ = terminal.beginSearch("hit")

        let materializations = Instrument.wholeProjection.measure {
            _ = planFrame(for: terminal, presentation: presentation)
        }
        #expect(materializations == 0)
    }

    @Test("a match scrolled out of the viewport plans no runs")
    func offViewportMatchPlansNoRuns() throws {
        var terminal = try #require(Terminal(columns: 5, rows: 2))
        terminal.feed(Array("hit\r\naaa\r\nbbb\r\nccc".utf8))

        let found = terminal.beginSearch("hit")
        #expect(found)
        // `beginSearch` reveals the match, so scroll back to the live tail to strand it
        // above the window -- the state a user reaches by scrolling after a find.
        terminal.scrollToBottom()
        #expect(terminal.searchReadout?.activeMatch?.start.row == 0)
        #expect(terminal.scrollProjection.topRow > 0)

        let plan = planFrame(for: terminal, presentation: presentation)
        #expect(plan.overlayRuns.isEmpty)
        assertCanonical(plan)
    }

    @Test("search and selection split into three semantic overlay states")
    func selectionAndMatchCoexist() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("zzhitz".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 4)
        ))
        let found = terminal.beginSearch("hit")
        #expect(found)

        let plan = planFrame(for: terminal, presentation: presentation)
        let selection = resolveOverlayStyle(
            state: .selection,
            background: presentation.theme.defaultBackground,
            foreground: presentation.theme.selectionForeground,
            theme: presentation.theme
        )
        let combined = resolveOverlayStyle(
            state: .selectionAndActiveSearchMatch,
            background: presentation.theme.defaultBackground,
            foreground: presentation.theme.selectionForeground,
            theme: presentation.theme
        )
        let match = resolveOverlayStyle(
            state: .activeSearchMatch,
            background: presentation.theme.defaultBackground,
            foreground: presentation.theme.defaultForeground,
            theme: presentation.theme
        )
        #expect(plan.overlayRuns == [
            RenderOverlayRun(
                startColumn: 0,
                columnCount: 2,
                state: .selection,
                color: selection.fill
            ),
            RenderOverlayRun(
                startColumn: 2,
                columnCount: 2,
                state: .selectionAndActiveSearchMatch,
                color: combined.fill
            ),
            RenderOverlayRun(
                startColumn: 4,
                columnCount: 1,
                state: .activeSearchMatch,
                color: match.fill
            ),
        ])

        terminal.clearSelection()
        let matchOnly = planFrame(for: terminal, presentation: presentation)
        #expect(matchOnly.overlayRuns.allSatisfy { $0.state == .activeSearchMatch })
        assertCanonical(matchOnly)
    }

    @Test("the alternate screen plans no match runs")
    func alternateScreenPlansNoMatchRuns() throws {
        // Intent: with the alternate screen active, a needle still matching retained
        //   scrollback plans no highlight.
        // Why it exists: match anchors are absolute stream rows over scrollback, but the
        //   alternate projection restarts at row 0 -- an unguarded run would paint over
        //   unrelated full-screen-app content at the same numeric row.
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("hit\r\nzzz\r\nyyy".utf8))
        terminal.feed(Array("\u{1B}[?1049h".utf8))

        _ = terminal.beginSearch("hit")
        #expect(planFrame(for: terminal, presentation: presentation).overlayRuns.isEmpty)
    }

    @Test("a selection straddling two matches keeps each match's identity on both sides")
    func selectionStraddlingTwoMatches() throws {
        // Intent: a selection covering the tail of one match, the gap, and the head of the
        //   active match yields five overlay runs whose states name every combination.
        // Why it exists: the row resolves overlays through one match cursor; a cursor that
        //   advanced on the selection edge instead of the match edge would drop a match's
        //   state on one side of the selection.
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("hit hit".utf8))
        terminal.setSelection(TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 1),
            end: TerminalTextPosition(row: 0, column: 5)
        ))
        let found = terminal.beginSearch("hit")
        #expect(found)

        let runs = planFrame(for: terminal, presentation: presentation).overlayRuns
        #expect(runs.map(\.startColumn) == [0, 1, 3, 4, 5])
        #expect(runs.map(\.columnCount) == [1, 2, 1, 1, 2])
        #expect(runs.map(\.state) == [
            .searchMatch,
            .selectionAndSearchMatch,
            .selection,
            .selectionAndActiveSearchMatch,
            .activeSearchMatch,
        ])
    }

    @Test("overlapping matches give a contested cell to the earliest match")
    func overlappingMatchesResolveToTheEarliest() throws {
        // Intent: with matches at 0..<2, 1..<3, 4..<6 and the middle one active, column 1
        //   belongs to the first match and only column 2 shows the active state.
        // Why it exists: matches may overlap, and the earliest in start order wins a
        //   contested cell. A cursor that advanced past a match while it still covered the
        //   column, or that preferred the active match, would change the planned runs.
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("aaa aa".utf8))
        let found = terminal.beginSearch("aa")
        #expect(found)
        let moved = terminal.searchNext()
        #expect(moved)
        let readout = try #require(terminal.searchReadout)
        #expect(readout.viewportMatches.map(\.start.column) == [0, 1, 4])
        #expect(readout.activeMatch?.start.column == 1)

        let runs = planFrame(for: terminal, presentation: presentation).overlayRuns
        #expect(runs.map(\.startColumn) == [0, 2, 4])
        #expect(runs.map(\.columnCount) == [2, 1, 2])
        #expect(runs.map(\.state) == [.searchMatch, .activeSearchMatch, .searchMatch])
    }

}
