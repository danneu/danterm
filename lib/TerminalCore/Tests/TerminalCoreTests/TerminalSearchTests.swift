// Literal logical-history search semantics and navigation proofs.
import Testing

@testable import TerminalCore

/// Locks unit-aligned search to live terminal content without a stale match cache.
struct TerminalSearchTests {
    @Test("search folds ASCII only and requires complete non-ASCII units")
    func foldingAndUnicodeExactness() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("AbC ñ n\u{0303}".utf8))

        var result = terminal.beginSearch("aBc")
        #expect(result)
        #expect(terminal.activeSearchMatchRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 3)
        ))
        result = terminal.beginSearch("Ñ")
        #expect(result == false)
        result = terminal.beginSearch("n\u{0303}")
        #expect(result)
        result = terminal.beginSearch("n")
        #expect(result == false)
        result = terminal.beginSearch("ñ")
        #expect(result)
        result = terminal.beginSearch("")
        #expect(result == false)
        #expect(terminal.activeSearchMatchRange == nil)
    }

    @Test("newest-first navigation exposes overlaps and stops without moving")
    func navigationAndOverlaps() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("aaa aa".utf8))

        var moved = terminal.beginSearch("aa")
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 4)
        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 1)
        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 0)
        let oldest = terminal.activeSearchMatchRange
        moved = terminal.searchNext()
        #expect(moved == false)
        #expect(terminal.activeSearchMatchRange == oldest)
        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 1)
        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 4)
        let newest = terminal.activeSearchMatchRange
        moved = terminal.searchPrevious()
        #expect(moved == false)
        #expect(terminal.activeSearchMatchRange == newest)
    }

    @Test("search spans soft wraps and only requested hard boundaries")
    func wrapAndBoundaryMatching() throws {
        var soft = try #require(Terminal(columns: 4, rows: 3))
        soft.feed(Array("ABCDEF".utf8))
        var result = soft.beginSearch("CDEF")
        #expect(result)

        var padding = try #require(Terminal(columns: 4, rows: 2))
        padding.moveCursor(row: 0, column: 3)
        padding.feed(Array("XY".utf8))
        result = padding.beginSearch("  XY")
        #expect(result)

        var hard = try #require(Terminal(columns: 4, rows: 3))
        hard.feed(Array("AB\r\nCD".utf8))
        result = hard.beginSearch("BC")
        #expect(result == false)
        result = hard.beginSearch("B\nC")
        #expect(result)
        result = hard.beginSearch("\n")
        #expect(result)
        #expect(hard.activeSearchMatchRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 2),
            end: TerminalTextPosition(row: 1, column: 0)
        ))
    }

    @Test("navigation rescans changed nonintersecting rows")
    func navigationUsesLiveContent() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("hit\r\nhit\r\nhit".utf8))
        var moved = terminal.beginSearch("hit")
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.row == 2)

        terminal.feed(Array("\u{1B}[1;1Hzip".utf8))
        #expect(terminal.activeSearchMatchRange?.start.row == 2)
        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.row == 1)
        moved = terminal.searchNext()
        #expect(moved == false)
    }

    @Test("search status counts matches and orients the newest as index zero")
    func statusCountsAndOrientation() throws {
        // Intent: `searchStatus` reports the live match total plus the selected
        //   match's index, with the newest match reading as index 0 so the overlay
        //   renders it as 1/N.
        // Why it exists: pins the index orientation the find overlay's `selected + 1`
        //   counter depends on, and the no-wrap edges where navigation must leave
        //   the status untouched.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("hit\r\nzzz\r\nhit\r\nhit".utf8))

        #expect(terminal.searchStatus == nil)
        var moved = terminal.beginSearch("hit")
        #expect(moved)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 3))
        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.searchStatus == .matched(selected: 1, total: 3))
        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.searchStatus == .matched(selected: 2, total: 3))
        moved = terminal.searchNext()
        #expect(moved == false)
        #expect(terminal.searchStatus == .matched(selected: 2, total: 3))
        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.searchStatus == .matched(selected: 1, total: 3))
        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 3))
        moved = terminal.searchPrevious()
        #expect(moved == false)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 3))
    }

    @Test("a needle that matches nothing reports an empty status, and clearing reports none")
    func statusDistinguishesFailedSearchFromNoSearch() throws {
        // Intent: a non-empty needle with no occurrences stays an active search
        //   reporting `.empty`, while an empty needle or an explicit clear reports
        //   no status at all.
        // Why it exists: the overlay renders `-/0` for the failed-search status and
        //   nothing for a nil status; collapsing the two would make a failed search
        //   indistinguishable from a closed one.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("hit".utf8))

        var moved = terminal.beginSearch("nope")
        #expect(moved == false)
        #expect(terminal.searchStatus == .empty)
        #expect(terminal.activeSearchMatchRange == nil)
        moved = terminal.searchNext()
        #expect(moved == false)
        moved = terminal.searchPrevious()
        #expect(moved == false)
        #expect(terminal.searchStatus == .empty)

        terminal.clearSearch()
        #expect(terminal.searchStatus == nil)

        moved = terminal.beginSearch("")
        #expect(moved == false)
        #expect(terminal.searchStatus == nil)
    }

    @Test("navigating a failed search adopts the newest match once output supplies one")
    func navigationReattachesAfterAFailedNeedleStartsMatching() throws {
        // Intent: a needle that matched nothing when it was typed, followed by output
        //   containing it, has the next `searchNext`/`searchPrevious` adopt the newest
        //   match instead of refusing to move.
        // Why it exists: without the re-attach the engine sits in "matches exist but
        //   none is selected" -- the overlay shows a count with no highlight and Cmd-G
        //   does nothing until the user retypes a character. That state is exactly what
        //   the total status enum forbids, so navigation has to close it.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("zzz".utf8))

        let found = terminal.beginSearch("hit")
        #expect(found == false)
        #expect(terminal.searchStatus == .empty)

        // The status read has no occurrence to point at yet, so it names the match the
        // re-attach below is about to select rather than an unselected count.
        terminal.feed(Array("\r\nhit".utf8))
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))
        #expect(terminal.activeSearchMatchRange == nil)

        let moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))
        #expect(terminal.activeSearchMatchRange?.start.row == 1)
    }

    @Test("the alternate screen suppresses both search reads")
    func alternateScreenReportsNoSearch() throws {
        // Intent: while the alternate screen is active, both `searchStatus` and
        //   `activeSearchMatchRange` report nothing even though the needle still
        //   matches retained scrollback.
        // Why it exists: match anchors are absolute stream rows spanning scrollback,
        //   but the alternate screen's projection restarts at row 0 -- an unguarded
        //   read would paint a scrollback match over unrelated alt-screen content at
        //   the same numeric row. `revealSearchMatchIfNeeded` already carries this
        //   guard; these reads must agree with it.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("hit\r\nzzz\r\nyyy".utf8))
        terminal.feed(Array("\u{1B}[?1049h".utf8))

        _ = terminal.beginSearch("hit")
        #expect(terminal.searchStatus == nil)
        #expect(terminal.activeSearchMatchRange == nil)

        // Leaving the alternate screen drops inspection state, so re-run the search to
        // prove the suppression is a read-time guard rather than a permanent loss.
        terminal.feed(Array("\u{1B}[?1049l".utf8))
        let found = terminal.beginSearch("hit")
        #expect(found)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))
        #expect(terminal.activeSearchMatchRange != nil)
    }

    @Test("every search mutation damages the departing and arriving match rows")
    func searchMutationsRecordRowDamage() throws {
        // Intent: begin, next, previous, clear, and a needle that transitions from
        //   matching to not matching each record row damage covering both the match
        //   that left and the match that arrived -- including when the match moves
        //   entirely within the current viewport, so nothing scrolls.
        // Why it exists: the renderer redraws only damaged rows. A search mutation
        //   that publishes `.none` damage leaves the previous highlight painted and
        //   the new one invisible.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("hit\r\nzzz\r\nhit\r\nyyy".utf8))
        _ = terminal.drainDamage()

        var moved = terminal.beginSearch("hit")
        #expect(moved)
        #expect(terminal.drainDamage() == TerminalDamage(rows: [2]))

        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.drainDamage() == TerminalDamage(rows: [0, 2]))

        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.drainDamage() == TerminalDamage(rows: [0, 2]))

        moved = terminal.beginSearch("nope")
        #expect(moved == false)
        #expect(terminal.drainDamage() == TerminalDamage(rows: [2]))

        moved = terminal.beginSearch("hit")
        #expect(moved)
        _ = terminal.drainDamage()
        terminal.clearSearch()
        #expect(terminal.drainDamage() == TerminalDamage(rows: [2]))
    }
}
