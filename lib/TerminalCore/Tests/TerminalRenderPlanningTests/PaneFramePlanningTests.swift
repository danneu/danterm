// Behavioral proofs that damage-aware row reuse is invisible in the plan: every
// reusing call must produce exactly what a from-scratch plan would, and must
// refuse reuse whenever damage alone cannot account for the difference.
import Testing

import TerminalCore
@testable import TerminalRenderPlanning

struct PaneFramePlanningTests {
    @Test("A reused plan equals the plan built from scratch for the same frame")
    func reusedPlanEqualsFromScratch() throws {
        // Intent: after an incremental edit touching one row, the reusing planner's
        //   complete plan is identical to planning the whole viewport fresh.
        // Why it exists: reuse copies undamaged rows instead of re-deriving them, so
        //   this pins the entire correctness claim of the optimization -- a copied row
        //   that should have changed shows up here as an inequality.
        // Scenario: a pane sits with three rows of styled output and the user types a
        //   character on the middle row; only that row is damaged.
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        feed("\u{1B}[41mred\r\n\u{1B}[4munder\r\nplain", to: &terminal)
        _ = terminal.drainDamage()

        var planner = PaneFramePlanner()
        _ = planner.planFrame(for: terminal, presentation: blockCursor, damage: .full)

        terminal.feed(Array("\u{1B}[2;1H\u{1B}[42mX".utf8))
        let damage = terminal.drainDamage()
        try #require(damage.isFull == false)

        let reused = planner.planFrame(for: terminal, presentation: blockCursor, damage: damage)
        #expect(reused == planFrame(for: terminal, presentation: blockCursor))
        assertCanonical(reused)
    }

    @Test("Reuse is refused when presentation changes without recording damage")
    func reuseRefusedOnChangedPresentation() throws {
        // Intent: a presentation change alone forces a full replan even under `.none` damage.
        // Why it exists: presentation is the one planning input the damage model does not
        //   cover -- a per-pane theme switch would recolor every row while damaging none --
        //   so carrying it in the retained state is what makes the stale-row bug
        //   unrepresentable rather than merely untested.
        // Scenario: the pane's cursor shape changes from a block to a bar while the
        //   terminal itself is idle, so no row damage accompanies it.
        var terminal = try #require(Terminal(columns: 12, rows: 2))
        feed("cursor", to: &terminal)
        _ = terminal.drainDamage()

        let expected = planFrame(for: terminal, presentation: barCursor)
        try #require(expected != planFrame(for: terminal, presentation: blockCursor))

        var planner = PaneFramePlanner()
        _ = planner.planFrame(for: terminal, presentation: blockCursor, damage: .full)

        #expect(planner.planFrame(for: terminal, presentation: barCursor, damage: .none) == expected)
    }

    @Test("Selection changes remain identical under row reuse and full planning")
    func selectionChangesMatchFromScratch() throws {
        // Intent: every selection transition produces the same complete plan through
        //   damage-aware row reuse as through a fresh viewport traversal.
        // Why it exists: selected foreground now lives in retained text runs, making
        //   the selection damage rows load-bearing for reuse correctness.
        // Scenario: a user sets, extends, shrinks, moves, and then clears a selection
        //   across two rows while the terminal output itself stays quiescent.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        feed("abcdef\r\nghijkl", to: &terminal)
        _ = terminal.drainDamage()
        var planner = PaneFramePlanner()
        _ = planner.planFrame(for: terminal, presentation: blockCursor, damage: .full)

        let ranges: [TerminalTextRange?] = [
            .init(
                start: .init(row: 0, column: 1),
                end: .init(row: 0, column: 3)
            ),
            .init(
                start: .init(row: 0, column: 1),
                end: .init(row: 1, column: 4)
            ),
            .init(
                start: .init(row: 0, column: 2),
                end: .init(row: 1, column: 3)
            ),
            .init(
                start: .init(row: 1, column: 1),
                end: .init(row: 1, column: 5)
            ),
            nil,
        ]

        for range in ranges {
            if let range {
                terminal.setSelection(range)
            } else {
                terminal.clearSelection()
            }
            let damage = terminal.drainDamage()
            let reused = planner.planFrame(
                for: terminal,
                presentation: blockCursor,
                damage: damage
            )
            #expect(reused == planFrame(for: terminal, presentation: blockCursor))
        }
    }

    @Test("Reuse is refused when the grid dimensions differ from the retained frame")
    func reuseRefusedOnChangedDimensions() throws {
        // Intent: retained rows are discarded when the next frame's grid is a different
        //   size, whatever the accompanying damage claims.
        // Why it exists: viewport row indexes only mean the same thing across frames of
        //   equal geometry; reusing across a resize would copy runs onto unrelated rows,
        //   or read past the retained row array entirely.
        // Scenario: a pane is replanned against a taller grid, then a shorter one, then a
        //   wider one, while the damage says only row 0 changed. Both height directions
        //   matter: shrinking leaves the retained rows long enough to index into, so a
        //   bounds check alone would not catch rows copied from a different geometry.
        var short = try #require(Terminal(columns: 12, rows: 2))
        feed("\u{1B}[41mred\r\nrows", to: &short)

        var tall = try #require(Terminal(columns: 12, rows: 4))
        feed("\u{1B}[42mgreen\r\nrows\r\nmore\r\nhere", to: &tall)

        var wide = try #require(Terminal(columns: 20, rows: 4))
        feed("\u{1B}[44mblue\r\nrows\r\nmore\r\nhere", to: &wide)

        var planner = PaneFramePlanner()
        _ = planner.planFrame(for: short, presentation: blockCursor, damage: .full)

        let rowDamage = TerminalDamage(rows: [0])
        let taller = planner.planFrame(for: tall, presentation: blockCursor, damage: rowDamage)
        #expect(taller == planFrame(for: tall, presentation: blockCursor))

        let shorter = planner.planFrame(for: short, presentation: blockCursor, damage: rowDamage)
        #expect(shorter == planFrame(for: short, presentation: blockCursor))

        let wider = planner.planFrame(for: wide, presentation: blockCursor, damage: rowDamage)
        #expect(wider == planFrame(for: wide, presentation: blockCursor))
    }

    @Test("Reuse is refused when damage is full")
    func reuseRefusedOnFullDamage() throws {
        // Intent: full damage replans every row rather than copying any retained one.
        // Why it exists: `.full` is exactly how the engine reports that viewport row
        //   identity is unstable (scroll, alt-screen switch, reset), so honoring it is
        //   what keeps row reuse sound for every event the row set cannot describe.
        // Scenario: the pane switches to the alternate screen, whose content shares no
        //   row with what the planner retained.
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        feed("\u{1B}[41mfirst\r\nsecond\r\nthird", to: &terminal)
        _ = terminal.drainDamage()

        var planner = PaneFramePlanner()
        _ = planner.planFrame(for: terminal, presentation: blockCursor, damage: .full)

        terminal.feed(Array("\u{1B}[?1049h\u{1B}[4malternate".utf8))
        let damage = terminal.drainDamage()
        try #require(damage.isFull)

        let replanned = planner.planFrame(for: terminal, presentation: blockCursor, damage: damage)
        #expect(replanned == planFrame(for: terminal, presentation: blockCursor))
    }

    private var blockCursor: RenderPresentation {
        RenderPresentation(theme: .dark, isCursorVisible: true, cursorShape: .block)
    }

    private var barCursor: RenderPresentation {
        RenderPresentation(theme: .dark, isCursorVisible: true, cursorShape: .bar)
    }
}

private func feed(_ text: String, to terminal: inout Terminal) {
    terminal.feed(Array(text.utf8))
    _ = terminal.drainReplyBytes()
}
