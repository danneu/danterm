// Proofs that `primaryHistoryGeneration` tracks primary-history content and only
// primary-history content. The forward test pins that every structurally distinct content
// funnel advances the generation while the viewport is scrolled back -- the state in which
// `recordDamage(since:)` used to supply a blanket bump that masked them all. The converse test
// pins that presentation-only interaction (cursor, selection, hover, scroll, search
// navigation) leaves the generation alone. Those two are each only meaningful as the other's
// counterweight: drop the forward half and the converse invites silently dropping emissions;
// drop the converse and the generation degrades back into a render-damage token no recovery
// consumer can trust. The third test sweeps a whole session's worth of mixed frames --
// unchanged frames, coalesced edits, alternate-screen output, a truncating resize -- against
// `primaryHistoryText`, so the pair's per-funnel and per-interaction claims are also checked
// end to end against the text a recovery consumer actually reads.

import Testing
@testable import TerminalCore

/// Pins the history generation to content mutation in both directions (I-A and I-B).
struct TerminalHistoryGenerationTests {
    @Test("every content funnel advances the history generation while scrolled back")
    func contentFunnelsAdvanceGenerationWhileScrolledBack() throws {
        // Intent: with the viewport browsing scrollback, each structurally distinct path that
        //   mutates primary history advances `primaryHistoryGeneration` on its own.
        // Why it exists: `recordDamage(since:)` no longer bumps the generation, and its
        //   `isFollowing == false` early return was previously a blanket bump covering every
        //   scrolled-back mutation at once. Without per-funnel coverage, a funnel that quietly
        //   stopped reporting would leave recovery holding stale text with no failing test.
        //   These cases exhaust the current content funnels; adding another funnel
        //   requires adding its behavioral proof here.
        // Scenario: the PROBE-BROWSE case -- the user scrolls up to read history while the
        //   shell keeps writing, resizes nothing, and expects recovery to still see the output.
        // Funnels 1 and 3 are reachable in isolation. Funnels 2 and 4 are not -- a scrollback
        //   row is only wrap-claimed while its continuation is live in the viewport, and
        //   eviction only runs off a scrollback append -- so each necessarily co-fires with a
        //   viewport-row funnel, and its case pins the scrolled-back scenario rather than the
        //   lone funnel. Both cases still assert the history-text consequence, so a scenario
        //   that silently stopped mutating history would fail rather than pass vacuously.

        // Funnel 1: cell writes routed through `invalidateInspection(inViewportRows:)`.
        var printing = try makeScrolledBackTerminal()
        try expectGenerationAdvances(&printing) { $0.feed(Array("X".utf8)) }

        // Funnel 2: scrollback wrap-claim rewrite via `invalidateInspection(inScrollbackRow:)`.
        // `ESC[2J` blanks the whole of live row 0, so it severs the last scrollback row's
        // soft-wrap claim before erasing the viewport (`research/31/D2` operation 2). Both halves of the
        // recovered text's line structure change: the remainder of the wrapped line goes with
        // the viewport, and the retained head stops claiming a continuation.
        var wrapClaim = try makeScrolledBackTerminal(trailingWrappedLine: true)
        #expect(wrapClaim.primaryHistoryText.contains("wrapping line"))
        #expect(wrapClaim.scrollbackRow(at: wrapClaim.scrollbackRowCount - 1)?.isSoftWrapped == true)
        try expectGenerationAdvances(&wrapClaim) { $0.feed(Array("\u{1B}[2J".utf8)) }
        #expect(wrapClaim.primaryHistoryText.contains("wrapping line") == false)
        #expect(wrapClaim.scrollbackRow(at: wrapClaim.scrollbackRowCount - 1)?.isSoftWrapped == false)

        // Funnel 3: linefeed-driven scrollback append, which damages the scroll region
        // directly and passes `invalidatesInspection: false`.
        var lineFeed = try makeScrolledBackTerminal()
        try expectGenerationAdvances(&lineFeed) { $0.feed(Array("\r\n".utf8)) }

        // Funnel 4: `enforceScrollbackBudget` eviction, which drops the history head.
        var eviction = try makeScrolledBackTerminal(scrollbackBudgetBytes: historyBudget(lines: 1, cells: 8, paneColumns: 8))
        #expect(eviction.primaryHistoryText.contains("second"))
        try expectGenerationAdvances(&eviction) { $0.feed(Array("evict me\r\n".utf8)) }
        #expect(eviction.primaryHistoryText.contains("second") == false)
    }

    @Test("presentation-only interaction leaves the history generation unchanged")
    func presentationInteractionLeavesGenerationUnchanged() throws {
        // Intent: cursor movement, selection, link hover, viewport scrolling, and search
        //   navigation never advance `primaryHistoryGeneration`.
        // Why it exists: this is the property that makes "generation advanced" readable as
        //   "primary history changed". Without it no consumer can trust the token, and the
        //   recovery pipeline is pushed back toward a consumer-side text filter.
        // Scenario: the PROBE-CURSOR / PROBE-SELECT case -- a user reading and selecting
        //   output in an idle pane must not schedule recovery checkpoints by doing so.
        // Note: identical-content cell rewrites (a shell repainting its prompt on each
        //   keystroke) still advance the generation; that is AR1, not a gap in this test.
        var terminal = try #require(Terminal(columns: 12, rows: 3))
        terminal.feed(Array("alpha\r\nbeta\r\ngamma\r\ndelta\r\nsecond\r\nhttps://a.co".utf8))
        let baseline = terminal.primaryHistoryGeneration

        terminal.feed(Array("\u{1B}[H\u{1B}[2C\u{1B}[B".utf8))
        #expect(terminal.primaryHistoryGeneration == baseline, "cursor movement")

        terminal.setSelection(
            from: TerminalTextPosition(row: 5, column: 0),
            to: TerminalTextPosition(row: 5, column: 4)
        )
        terminal.clearSelection()
        #expect(terminal.primaryHistoryGeneration == baseline, "selection")

        let link = try #require(terminal.activatableLink(
            at: TerminalTextPosition(row: 5, column: 3)
        ))
        let admittedHover = terminal.setHoveredLink(link)
        #expect(admittedHover)
        terminal.clearHoveredLink()
        #expect(terminal.primaryHistoryGeneration == baseline, "link hover")

        terminal.scroll(toTopRow: 0)
        #expect(terminal.scrollProjection.isFollowing == false)
        terminal.scroll(byRows: 1)
        terminal.scrollToBottom()
        #expect(terminal.primaryHistoryGeneration == baseline, "viewport scrolling")

        // "alpha" only exists in scrollback, so revealing it drives the viewport off-bottom.
        let revealedMatch = terminal.beginSearch("alpha")
        #expect(revealedMatch)
        #expect(terminal.scrollProjection.isFollowing == false)
        terminal.clearSearch()
        terminal.scrollToBottom()
        // "a" recurs across the whole stream, so both navigation directions have somewhere to go.
        let foundRecurringMatch = terminal.beginSearch("a")
        #expect(foundRecurringMatch)
        let movedToOlderMatch = terminal.searchNext()
        #expect(movedToOlderMatch)
        let movedToNewerMatch = terminal.searchPrevious()
        #expect(movedToNewerMatch)
        #expect(terminal.primaryHistoryGeneration == baseline, "search navigation")
    }

    @Test("primary-history generation covers every session string mutation")
    func primaryHistoryGenerationDifferential() throws {
        // Intent: every recovery projection change advances the primary-history generation.
        // Why it exists: recovery callbacks must stay complete while generation over-approximation
        //   remains free to trade a redundant write for simpler mutation tracking.
        // Scenario: unchanged frames, primary edits, coalesced edits, alternate-screen output, and
        //   a truncating resize are observed through both the old and new frame classifiers.
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        var lastText = terminal.primaryHistoryText
        var lastGeneration = terminal.primaryHistoryGeneration

        func verifyMutation(_ mutate: (inout Terminal) -> Void, terminal: inout Terminal) {
            mutate(&terminal)
            let text = terminal.primaryHistoryText
            // Over-approximation is safe (a redundant recovery write); a missed emission is not.
            if text != lastText {
                #expect(terminal.primaryHistoryGeneration != lastGeneration)
            }
            lastText = text
            lastGeneration = terminal.primaryHistoryGeneration
        }

        func verifyFrame(_ bytes: [UInt8], terminal: inout Terminal) {
            verifyMutation({ $0.feed(bytes) }, terminal: &terminal)
        }

        verifyFrame(Array("\u{1B}[?25l".utf8), terminal: &terminal)
        verifyFrame(Array("A".utf8), terminal: &terminal)
        verifyFrame(Array("BC\rZ".utf8), terminal: &terminal)
        verifyFrame(Array("\u{1B}[2K".utf8), terminal: &terminal)
        verifyFrame(Array("1\r\n2\r\n3\r\n4".utf8), terminal: &terminal)
        verifyFrame(Array("\u{1B}[3J".utf8), terminal: &terminal)
        verifyFrame(Array("\u{1B}[?1049hALT\u{1B}[?1049l".utf8), terminal: &terminal)
        verifyFrame(Array("\u{1B}[31m".utf8), terminal: &terminal)
        verifyFrame(Array("D".utf8), terminal: &terminal)

        terminal = try #require(Terminal(columns: 4, rows: 1, scrollbackBudgetBytes: 352))
        terminal.feed(Array("ABCDEFGHI".utf8))
        lastText = terminal.primaryHistoryText
        lastGeneration = terminal.primaryHistoryGeneration
        verifyMutation({ $0.resize(columns: 2, rows: 1) }, terminal: &terminal)
    }

    /// Builds a terminal browsing its scrollback, the state where the funnel proofs are load-bearing.
    private func makeScrolledBackTerminal(
        trailingWrappedLine: Bool = false,
        scrollbackBudgetBytes: Int? = nil
    ) throws -> Terminal {
        var terminal = try #require(Terminal(
            columns: 8,
            rows: 2,
            scrollbackBudgetBytes: scrollbackBudgetBytes ?? Terminal.scrollbackByteLimit
        ))
        // The trailing line overflows the 8-column width, so it enters scrollback soft-wrapped.
        let tail = trailingWrappedLine ? "wrapping line\r\n" : "third\r\n"
        terminal.feed(Array("first\r\nsecond\r\n\(tail)fourth".utf8))
        terminal.scroll(toTopRow: 0)
        #expect(terminal.scrollProjection.isFollowing == false)
        return terminal
    }

    private func expectGenerationAdvances(
        _ terminal: inout Terminal,
        _ mutate: (inout Terminal) -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let before = terminal.primaryHistoryGeneration
        mutate(&terminal)
        #expect(
            terminal.primaryHistoryGeneration != before,
            sourceLocation: sourceLocation
        )
    }
}
