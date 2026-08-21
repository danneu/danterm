// Covers the stale-wrap-claim gate: EL 1/2 keep a row's soft-wrap claim for xterm parity
// (CSIEraseTests#eraseLineWrapAsymmetry), but a claim whose margin an erase blanked no longer
// names real content, and the line-structure readers -- admission, reflow, text projection --
// must not measure the row to full width on its strength. The raw claim itself stays
// observable through `geometry`; these tests pin the *derived* line structure.
//
// The distinction is provenance, not cell shape: a refolded line whose interior blank lands
// on the fold seam produces the same cells as an erased-and-rewritten row, so the gate rides
// on which writer last touched the margin, and both directions are pinned here.
import Testing

@testable import TerminalCore

@Suite("Stale wrap claims")
struct TerminalStaleWrapClaimTests {
    /// The Ink repaint transient: blank a wrapped row with EL 2, rewrite it shorter, put
    /// different content on the next row. Two logical lines, whatever the leftover claim says.
    private func makeRepaintTransient() throws -> Terminal {
        var terminal = try #require(Terminal(columns: 10, rows: 3))
        terminal.feed(Array("AAAAAAAAAABB".utf8))
        terminal.feed(Array("\u{1B}[H\u{1B}[2Kcccc".utf8))
        terminal.feed(Array("\u{1B}[2;1H\u{1B}[2Kdddd".utf8))
        return terminal
    }

    @Test("An erased-then-rewritten row admits as its own line, not a fused one")
    func staleClaimSeversAtAdmission() throws {
        // Intent: scroll-off admission treats a claim with an erased margin as a hard end.
        // Why it exists: admission measured claimed rows to full width unconditionally, so an
        //   Ink-style repaint (EL 2 + shorter rewrite) fused separately printed lines into one
        //   record padded to the fusing width -- correct at that width, garbled at every other.
        // Scenario: the 2026-08-07 zoom fusion,
        //   docs/research/33-by-construction-perf-survey/2026-08-07-stale-wrap-claim-line-fusion.md.
        var terminal = try makeRepaintTransient()

        terminal.feed(Array("\u{1B}[3;1H\n\n".utf8))

        #expect(terminal.primaryHistoryText == "cccc\ndddd")
    }

    @Test("An erased-then-rewritten row survives a resize as its own line")
    func staleClaimSeversInLiveReflow() throws {
        // Intent: the live-grid reflow applies the same gate admission does.
        // Why it exists: a SIGWINCH landing during the blank-and-claimed transient reflows the
        //   live rows directly, where admission never sees them -- validating at admission
        //   alone would leave this path fusing.
        // Scenario: the repaint transient is on screen when the pane narrows.
        var terminal = try makeRepaintTransient()

        terminal.resize(columns: 6, rows: 3)

        #expect(terminal.fullHistoryText == "cccc\ndddd")
    }

    @Test("A refolded line with an interior blank on the fold seam stays one line")
    func interiorPaddingAtFoldSeamKeepsContinuation() throws {
        // Intent: a genuine continuation whose margin cell is positional padding is not severed.
        // Why it exists: reflow folds a hard-ended row with an interior blank so the blank
        //   lands exactly on the new margin -- cell-for-cell identical to the erased transient,
        //   but genuinely one line. Gating on cell evidence alone would split it; the gate must
        //   ride on erase provenance instead. Found as the residual ablation violation in the
        //   2026-08-07 zoom fusion tape (source row contentEnd 113, blank at column 57).
        // Scenario: "AAA BBBB" printed with a cursor jump over column 4, folded at width 4.
        var terminal = try #require(Terminal(columns: 10, rows: 4))
        terminal.feed(Array("AAA\u{1B}[5GBBBB".utf8))

        terminal.resize(columns: 4, rows: 4)
        #expect(terminal.fullHistoryText == "AAA BBBB", "the fold row must keep its continuation")

        terminal.resize(columns: 10, rows: 4)
        #expect(terminal.fullHistoryText == "AAA BBBB")

        terminal.resize(columns: 4, rows: 4)
        terminal.feed(Array("\u{1B}[4;1H\n\n".utf8))
        #expect(terminal.primaryHistoryText == "AAA BBBB")
    }

    @Test("Rewriting an erased row back to full width restores its continuation")
    func fullWidthRewriteRestoresContinuation() throws {
        // Intent: rewrite-in-place -- the case EL 2's claim-keeping exists for -- keeps the
        //   line joined once the rewrite reaches the margin.
        // Why it exists: this is the behavior severing on EL 2 (tmux's choice) would destroy,
        //   and the reason the gate is a transient marker rather than a sever: printing the
        //   margin re-witnesses the claim.
        // Scenario: a wrapped row is blanked and repainted to exactly full width.
        var terminal = try #require(Terminal(columns: 10, rows: 3))
        terminal.feed(Array("AAAAAAAAAABB".utf8))
        terminal.feed(Array("\u{1B}[H\u{1B}[2KCCCCCCCCCC".utf8))

        terminal.feed(Array("\u{1B}[3;1H\n\n".utf8))

        #expect(terminal.primaryHistoryText == "CCCCCCCCCCBB")
    }

    @Test("A wrap declined by a pinned scroll region stamps no interior row")
    func pinnedFooterWrapStampsNoInteriorRow() throws {
        // Intent: when the cursor sits on the last screen row below the scroll region's
        //   bottom, a wrap that cannot advance restores no claim on the row above.
        // Why it exists: `advanceToNextRow` neither scrolled nor moved in this geometry, yet
        //   `restoreWrapClaimBeforeCursor` stamped `rows[cursor.row - 1]` -- a region-interior
        //   row the wrap never touched. Inline-viewport TUIs (codex/ratatui) pin a footer with
        //   `CSI 1;N r` and print below it.
        // Scenario: region rows 1-2 of a 4-row screen, wrap on the bottom row.
        var terminal = try #require(Terminal(columns: 10, rows: 4))
        terminal.feed(Array("\u{1B}[1;2r\u{1B}[4;1HAAAAAAAAAAB".utf8))

        #expect(terminal.geometry.rows[2].isSoftWrapped == false, "the wrap never touched row 2")
        #expect(terminal.geometry.rows[2].cells.allSatisfy { $0.kind == .padding })
    }

    @Test("A declined wide wrap records no gap or claim")
    func pinnedFooterWideWrapRecordsNoGapOrClaim() throws {
        // Intent: a wide glyph that cannot advance from below the scroll region leaves no wrap
        //   claim or spacer behind.
        // Why it exists: the wide print path wrote both before learning that row advance was
        //   declined, which made the row claim itself as its follower.
        // Scenario: region rows 1-2 of a 4-row screen, wide wrap on the bottom row.
        var terminal = try #require(Terminal(columns: 10, rows: 4))
        terminal.feed(Array("\u{1B}[1;2r\u{1B}[4;10H\u{754C}".utf8))

        #expect(terminal.geometry.rows[3].isSoftWrapped == false)
        #expect(terminal.geometry.rows[3].cells[9].kind == .padding)
        #expect(terminal.geometry.rows[3].cells[0].kind == .wideHead)
        #expect(terminal.geometry.rows[3].cells[1].kind == .wideTail)
        expectValidGrid(terminal)

        var upgraded = try #require(Terminal(columns: 10, rows: 4))
        upgraded.feed(Array("\u{1B}[1;2r\u{1B}[4;10H\u{00A9}\u{FE0F}".utf8))

        #expect(upgraded.geometry.rows[3].isSoftWrapped == false)
        #expect(upgraded.geometry.rows[3].cells[9].kind == .padding)
        #expect(upgraded.geometry.rows[3].cells[0].kind == .wideHead)
        #expect(upgraded.geometry.rows[3].cells[1].kind == .wideTail)
        expectValidGrid(upgraded)
    }
}
