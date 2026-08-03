// Terminal-semantics cases adapted from WezTerm's `term/src/test/` corpus. Separate from
// TerminalResizeTests and the libvterm fixtures -- which pin behavior DanTerm chose or
// inherited from a spec suite -- because everything here is tracked against an external
// implementation: each test names the upstream test it follows so a pin bump that renames
// or revises that test is a reviewable event rather than silent compatibility drift.
//
// We adopt WezTerm's scenarios, never its verdict by default. WezTerm asserts through a
// `Line`/stable-row/`seqno` model and a one-past-end cursor that DanTerm does not have, so
// every citation carries a `Divergence:` line saying what we assert instead. The
// per-case disposition ledger for the full 56-test corpus lives in
// docs/scratch/wezterm-test-portage.md.
import Testing

@testable import TerminalCore

/// Tracks the slice of WezTerm's terminal tests that survived the portage audit as DanTerm
/// behavior, so upstream revisions surface here instead of drifting unnoticed.
struct TerminalWezTermAdaptedTests {
    /// Feeds `bytes` whole, one byte at a time, and at every single split point, applying
    /// `after` to each resulting terminal before handing it to `check`. A reflow bug that
    /// only appears when a control sequence straddles a chunk boundary is invisible to a
    /// single whole-stream feed, and this scenario exists precisely to put a control
    /// sequence next to a boundary.
    private func expectAcrossFeedSplits(
        columns: Int,
        rows: Int,
        _ bytes: [UInt8],
        after: (inout Terminal) -> Void = { _ in },
        check: (Terminal, Comment) -> Void
    ) throws {
        var chunkings: [(Comment, [[UInt8]])] = [
            ("whole", [bytes]),
            ("bytewise", bytes.map { [$0] }),
        ]
        for split in 1..<bytes.count {
            chunkings.append(("split at \(split)", [Array(bytes[..<split]), Array(bytes[split...])]))
        }

        for (label, chunks) in chunkings {
            var terminal = try #require(Terminal(columns: columns, rows: rows))
            for chunk in chunks { terminal.feed(chunk) }
            after(&terminal)
            check(terminal, label)
        }
    }

    @Test(
        "a control between an exactly-full row and its CRLF still yields a hard boundary",
        arguments: [
            ("no control", "====\r\nSS\r\n"),
            ("DECTCM around the text", "\u{1B}[?25l====\u{1B}[?25h\r\nSS\r\n"),
            ("SGR reset before the CR", "====\u{1B}[0m\r\nSS\r\n"),
        ]
    )
    func exactWidthHardBoundarySurvivesInterveningControl(label: String, stream: String) throws {
        // Intent: when text exactly fills the final column and a supported control sequence
        //   is dispatched before the CR/LF that ends the row, the row is still a hard line
        //   end -- so widening the terminal must not pull the next row up into it.
        // Why it exists: printing into the last column leaves the cursor in deferred-wrap
        //   state rather than on the next row, and it is that state which decides whether
        //   the following CR/LF records a hard break or a soft one. Any control that
        //   incidentally clears or commits the deferred wrap converts the boundary to a
        //   soft one, and the corruption stays invisible until a later widen joins two
        //   unrelated logical lines. The unwidened grid looks correct either way.
        // Scenario: a program hides the cursor (or resets SGR) around a line of output that
        //   happens to be exactly as wide as the window, then the user widens the window.
        //
        // Honest TDD note: this passed the first time it ran -- DanTerm marks a row wrapped
        //   lazily, at the next print, so the eager-flag bug WezTerm hit here is structurally
        //   absent. It is kept as a compositional regression boundary, not as a fix. Each
        //   link (a control preserves pending wrap, CR clears it, an exact-width CRLF is a
        //   hard boundary, a widen does not join hard rows) has its own stronger proof --
        //   `SGR preserves pending wrap and open grapheme assembly`,
        //   Fixtures/libvterm/flow-hard-boundary.json, and
        //   `rewrap never joins two rows that were not soft-wrapped together` -- but nothing
        //   pinned them end to end. Verified non-tautological by three injected mutations
        //   (eager wrap-flagging in printNarrow, dispatchCSI committing a deferred wrap, and
        //   reflow inferring a join from row fullness); this test failed under all three.
        //
        // Adapted from term/src/test/mod.rs#test_resize_wrap_dectcm_issue_978 and
        //   term/src/test/mod.rs#test_resize_wrap_escape_code_issue_978 (WezTerm d69264d),
        //   with the control-free leg from #test_resize_wrap_issue_971 as the control case.
        //   Divergence: WezTerm asserts rendered `visible_lines()` text only; we also assert
        //   per-row `isSoftWrapped` and the cursor, which is what actually distinguishes a
        //   hard boundary from a soft one that happens to render the same before the widen.
        //   WezTerm's `test_resize_wrap_sgc_issue_978` leg is deliberately not ported: it
        //   asserts DEC Special Graphics glyph mapping, which DanTerm does not implement.
        try expectAcrossFeedSplits(columns: 4, rows: 4, Array(stream.utf8)) { terminal, chunking in
            #expect(terminal.screenText == "====\nSS  \n    \n    ", "\(label), \(chunking)")
            #expect(
                terminal.geometry.rows.map(\.isSoftWrapped) == [false, false, false, false],
                "\(label), \(chunking)"
            )
            #expect(
                terminal.geometry.cursor == TerminalCursor(row: 2, column: 0, isPendingWrap: false),
                "\(label), \(chunking)"
            )
            expectValidGrid(terminal)
        }

        try expectAcrossFeedSplits(
            columns: 4,
            rows: 4,
            Array(stream.utf8),
            after: { $0.resize(columns: 6, rows: 4) }
        ) { terminal, chunking in
            #expect(terminal.screenText == "====  \nSS    \n      \n      ", "\(label), \(chunking)")
            #expect(
                terminal.geometry.rows.map(\.isSoftWrapped) == [false, false, false, false],
                "\(label), \(chunking)"
            )
            #expect(terminal.scrollbackRowCount == 0, "\(label), \(chunking)")
            expectValidGrid(terminal)
        }
    }

    @Test("the cursor at the end of a long line survives a shrink-and-rewiden walk")
    func cursorAnchorSurvivesNarrowAndRewidenWalk() throws {
        // Intent: with the cursor parked just past the last character of a line that is one
        //   column short of the width, narrowing and then widening again must land the
        //   cursor back on that same character boundary, not drift away from it.
        // Why it exists: narrowing pushes the tail onto a continuation row, so the cursor's
        //   anchor has to survive being expressed against a wrapped line and then folded
        //   back. Existing anchor coverage proves each single transition; a drift that only
        //   accumulates when the walk returns to a wider width would pass all of them.
        // Scenario: a shell prompt sits at the end of its line and the user resizes the
        //   window narrower and then back, or drags a split divider through both.
        //
        // Adapted from term/src/test/mod.rs#test_resize_2162,
        //   #test_resize_2162_by_2 and #test_resize_2162_by_2_then_up_1 (WezTerm d69264d),
        //   collapsed into one walk because DanTerm's resize is order-canonical
        //   (see `combinedResizeUsesCanonicalOrder`), so the by-2-then-up-1 variant adds a
        //   height leg rather than a distinct width transition.
        //   Divergence: WezTerm asserts a one-past-end cursor (`x == cols`) and a `seqno`;
        //   DanTerm has no such position, so each of those states is translated to the
        //   last cell plus `isPendingWrap: true`, and no sequence number is asserted.
        var terminal = try #require(Terminal(columns: 20, rows: 4))
        terminal.feed(Array("some long long text".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 19, isPendingWrap: false))
        #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [false, false, false, false])

        // WezTerm's by-1 leg: 19 characters exactly fill 19 columns, so its one-past-end
        // cursor (19, 0) becomes DanTerm's last cell with the wrap deferred.
        terminal.resize(columns: 19, rows: 4)
        #expect(terminal.screenText.split(separator: "\n")[0] == "some long long text")
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 18, isPendingWrap: true))

        // WezTerm's by-2 leg: the tail moves to a continuation row and the cursor follows it.
        terminal.resize(columns: 18, rows: 4)
        #expect(terminal.screenText.split(separator: "\n")[0] == "some long long tex")
        #expect(terminal.geometry.rows[0].isSoftWrapped == true)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))

        // The height leg from #test_resize_2162_by_2_then_up_1, folded back to full width.
        terminal.resize(columns: 20, rows: 3)
        #expect(terminal.screenText.split(separator: "\n")[0] == "some long long text ")
        #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [false, false, false])
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 19, isPendingWrap: false))

        terminal.resize(columns: 20, rows: 4)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 19, isPendingWrap: false))
        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.fullHistoryText == "some long long text")
        expectValidGrid(terminal)
    }
}
