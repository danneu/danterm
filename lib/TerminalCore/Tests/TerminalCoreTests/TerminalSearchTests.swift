// Literal logical-history search semantics and navigation proofs.
import Testing

@testable import TerminalCore

/// Locks unit-aligned search to live terminal content without a stale match cache.
struct TerminalSearchTests {
    @Test("search matches canonical caseless graphemes and preserves their cell ranges")
    func foldingAndUnicodeExactness() throws {
        // Intent: search compares one canonical caseless grapheme at a time and
        //   reports the exact cell range for both normalization forms.
        // Why it exists: boolean-only coverage allowed visually identical precomposed
        //   and decomposed text to disagree while the old ASCII behavior looked green.
        // Scenario: a pane contains the same Spanish letter typed in both forms and
        //   the user searches with either form and either case.
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("AbC ñ n\u{0303}".utf8))

        var result = terminal.beginSearch("aBc")
        #expect(result)
        #expect(terminal.activeSearchMatchRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 3)
        ))

        for needle in ["ñ", "Ñ", "N\u{0303}", "n\u{0303}"] {
            result = terminal.beginSearch(needle)
            #expect(result)
            #expect(terminal.activeSearchMatchRange == TerminalTextRange(
                start: TerminalTextPosition(row: 0, column: 6),
                end: TerminalTextPosition(row: 0, column: 7)
            ))
            result = terminal.searchNext()
            #expect(result)
            #expect(terminal.activeSearchMatchRange == TerminalTextRange(
                start: TerminalTextPosition(row: 0, column: 4),
                end: TerminalTextPosition(row: 0, column: 5)
            ))
            result = terminal.searchPrevious()
            #expect(result)
            #expect(terminal.activeSearchMatchRange == TerminalTextRange(
                start: TerminalTextPosition(row: 0, column: 6),
                end: TerminalTextPosition(row: 0, column: 7)
            ))
        }

        result = terminal.beginSearch("n")
        #expect(result == false)
        result = terminal.beginSearch("")
        #expect(result == false)
        #expect(terminal.activeSearchMatchRange == nil)
    }

    @Test("search keeps grapheme count and compatibility distinctions")
    func canonicalCaselessSearchLimits() throws {
        // Intent: full case folding stays inside one already-segmented grapheme and
        //   canonical search does not apply compatibility decomposition.
        // Why it exists: a whole-string fold would make sharp-s and ligatures match
        //   multi-cell needles, while NFKD would erase visible terminal distinctions.
        // Scenario: a user searches a pane containing characters whose case folds or
        //   compatibility mappings expand to ordinary ASCII text.
        var terminal = try #require(Terminal(columns: 12, rows: 2))
        terminal.feed(Array("ß ﬁ ① Ａ".utf8))

        var result = terminal.beginSearch("ß")
        #expect(result)
        #expect(terminal.activeSearchMatchRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 1)
        ))
        result = terminal.beginSearch("ss")
        #expect(result == false)
        result = terminal.beginSearch("ﬁ")
        #expect(result)
        #expect(terminal.activeSearchMatchRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 2),
            end: TerminalTextPosition(row: 0, column: 3)
        ))
        result = terminal.beginSearch("fi")
        #expect(result == false)
        result = terminal.beginSearch("1")
        #expect(result == false)
        result = terminal.beginSearch("A")
        #expect(result == false)
    }

    @Test("newest-first navigation exposes overlaps and wraps at both ends")
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
        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 4)
        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 0)
        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 1)
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
        // Row 0's "hit" was overwritten with "zip", so row 1 is now the oldest
        // match and stepping older wraps back to the newest.
        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.row == 2)
    }

    @Test("search status counts matches and orients the newest as index zero")
    func statusCountsAndOrientation() throws {
        // Intent: `searchStatus` reports the live match total plus the selected
        //   match's index, with the newest match reading as index 0 so the overlay
        //   renders it as 1/N.
        // Why it exists: pins the index orientation the find overlay's `selected + 1`
        //   counter depends on, and the wrap at both ends of the match list.
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
        // Past the oldest match, wrap around to the newest.
        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 3))
        // And back the other way: before the newest match, wrap to the oldest.
        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.searchStatus == .matched(selected: 2, total: 3))
        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.searchStatus == .matched(selected: 1, total: 3))
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

    @Test("evicting the selected match keeps the needle and lets navigation re-attach")
    func evictingTheSelectedMatchKeepsTheNeedle() throws {
        // Intent: when the row holding the selected match falls off the end of
        //   scrollback, the search stays open -- the needle survives, the status keeps
        //   reporting the matches that remain, and the next navigation adopts one.
        // Why it exists: eviction used to drop the whole search rather than just its
        //   occurrence, which made `searchNext` return false forever. The recovery for
        //   exactly this state already existed (`reattachToNewestMatch`) and eviction
        //   bypassed it by nulling the query too.
        // Scenario: a user searches a busy pane, walks to an old match, and the tail
        //   keeps streaming until that match scrolls out of history. Enter then stopped
        //   responding and the overlay froze on its last count, with no way back except
        //   retyping the needle.
        var terminal = try #require(Terminal(
            columns: 8,
            rows: 2,
            scrollbackBudgetBytes: historyRowCost(columns: 8) * 2
        ))
        terminal.feed(Array("hit\r\na".utf8))

        let found = terminal.beginSearch("hit")
        #expect(found)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))

        // Pushes the selected match past the two rows history can hold, while leaving a
        // newer occurrence for navigation to find.
        terminal.feed(Array("\r\nb\r\nc\r\nhit".utf8))

        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))
        let moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange != nil)
    }

    @Test("overwriting the selected match keeps the needle and lets navigation re-attach")
    func overwritingTheSelectedMatchKeepsTheNeedle() throws {
        // Intent: output that rewrites the row holding the selected match drops the
        //   occurrence and keeps the search itself open.
        // Why it exists: the sibling of the eviction defect above, on the path that
        //   invalidates by row intersection rather than by retention. It is reachable
        //   without any scrollback at all -- a `\r`-redrawn progress line is enough.
        // Scenario: a user searches, then the running program repaints the matched row.
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("hit\r\nzzz\r\nhit".utf8))

        let found = terminal.beginSearch("hit")
        #expect(found)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 2))

        // Rewrites row 1 -- where `beginSearch` left the selected (newest) match.
        terminal.feed(Array("\u{1B}[3;1HZZZ".utf8))

        #expect(terminal.activeSearchMatchRange == nil)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))
        let moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange != nil)
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

    @Test("the reported total grows as matching output arrives under an open search")
    func reportedTotalGrowsWithArrivingOutput() throws {
        // Intent: a search left open while the pane keeps producing output reports the
        //   matches that exist now, not the ones that existed when the needle was typed.
        // Why it exists: guards the freshness contract against any future memoization of
        //   the match list. `searchStatus` recomputes today, so this passes as written --
        //   its job is to fail the moment a cache serves an answer the buffer outgrew.
        // Scenario: a user searches a tailing log and watches the overlay's counter climb
        //   as new matching lines land, without retyping anything.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("hit".utf8))

        let found = terminal.beginSearch("hit")
        #expect(found)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))

        terminal.feed(Array("\r\nhit".utf8))
        #expect(terminal.searchStatus == .matched(selected: 1, total: 2))

        terminal.feed(Array("\r\nhit".utf8))
        #expect(terminal.searchStatus == .matched(selected: 2, total: 3))
    }

    @Test("re-searching a needle after it was cleared sees output that arrived meanwhile")
    func reSearchingAfterClearSeesInterveningOutput() throws {
        // Intent: closing a search and reopening the same needle reports the buffer as it
        //   stands, including everything printed while no search was open.
        // Why it exists: the invalidation path that drops stale occurrences
        //   (`invalidateInspection`) short-circuits when no selection, search, or link is
        //   live, so mutations arriving in that window are the ones a memoized match list
        //   is least likely to hear about. This is the hole, stated as behavior.
        // Scenario: a user searches, closes the overlay, lets the pane run, and searches
        //   the same term again -- the second search must not answer from the first.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("hit".utf8))

        var found = terminal.beginSearch("hit")
        #expect(found)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))

        terminal.clearSearch()
        #expect(terminal.searchStatus == nil)
        terminal.feed(Array("\r\nhit\r\nhit".utf8))

        found = terminal.beginSearch("hit")
        #expect(found)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 3))
    }

    @Test("the reported total shrinks when matching rows are evicted")
    func reportedTotalShrinksOnEviction() throws {
        // Intent: matches that fall off the end of scrollback stop being counted.
        // Why it exists: eviction removes rows from the front of the stream without
        //   touching any surviving row, so it is the one content change that alters the
        //   match set while mutating nothing a row-range invalidation would name.
        // Scenario: a user searches a busy pane and watches the total fall as the oldest
        //   matches age out of history.
        var terminal = try #require(Terminal(
            columns: 8,
            rows: 2,
            scrollbackBudgetBytes: historyRowCost(columns: 8) * 3
        ))
        terminal.feed(Array("hit\r\nhit\r\na".utf8))

        let found = terminal.beginSearch("hit")
        #expect(found)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 2))

        // Fills history exactly to its budget: both matches are still retained.
        terminal.feed(Array("\r\nb\r\nc".utf8))
        #expect(terminal.searchStatus == .matched(selected: 0, total: 2))

        // Each further row now evicts one from the front, taking a match with it.
        terminal.feed(Array("\r\nd".utf8))
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))

        terminal.feed(Array("\r\ne".utf8))
        #expect(terminal.searchStatus == .empty)
    }
}
