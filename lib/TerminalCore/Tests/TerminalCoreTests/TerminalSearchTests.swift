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

    @Test("a failed search resolves immediately once output supplies a match")
    func failedNeedleResolvesWhenItStartsMatching() throws {
        // Intent: a needle that matched nothing when it was typed, followed by output
        //   containing it, immediately selects the occurrence nearest its stored position.
        // Why it exists: the old occurrence-based model sat in "matches exist but none
        //   selected" until a navigation command reattached it.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("zzz".utf8))

        let found = terminal.beginSearch("hit")
        #expect(found == false)
        #expect(terminal.searchStatus == .empty)

        // The position resolves immediately when the new occurrence arrives.
        terminal.feed(Array("\r\nhit".utf8))
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))
        #expect(terminal.activeSearchMatchRange?.start.row == 1)

        let moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))
        #expect(terminal.activeSearchMatchRange?.start.row == 1)
    }

    @Test("evicting the selected match resolves the needle to a surviving occurrence")
    func evictingTheSelectedMatchResolvesToASurvivor() throws {
        // Intent: when the row holding the selected match falls off the end of
        //   scrollback, the search stays open -- the needle survives, the status keeps
        //   reporting the matches that remain, with a surviving one selected.
        // Why it exists: eviction used to drop the whole search rather than just its
        //   occurrence, which made `searchNext` return false forever.
        // Scenario: a user searches a busy pane, walks to an old match, and the tail
        //   keeps streaming until that match scrolls out of history. Enter then stopped
        //   responding and the overlay froze on its last count, with no way back except
        //   retyping the needle.
        var terminal = try #require(Terminal(
            columns: 8,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lines: 2, cells: 1)
        ))
        terminal.feed(Array("hit\r\na".utf8))

        let found = terminal.beginSearch("hit")
        #expect(found)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))

        // Pushes the selected match past the two rows history can hold, while leaving a
        // newer occurrence for navigation to find.
        terminal.feed(Array("\r\nb\r\nc\r\nhit".utf8))

        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))
        #expect(terminal.activeSearchMatchRange != nil)
        let moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange != nil)
    }

    @Test("overwriting the selected match resolves to the nearest survivor and ties later")
    func overwritingTheSelectedMatchResolvesToTheNearestSurvivor() throws {
        // Intent: output that destroys the selected occurrence leaves exactly one
        //   surviving occurrence selected, choosing the later one when distances tie.
        // Why it exists: dropping the occurrence created a state with matches but no
        //   highlight, and at-or-after selection could jump arbitrarily far through a pane.
        // Scenario: a progress row has three evenly spaced matches, the middle one is
        //   selected, and a redraw overwrites only that middle occurrence.
        var terminal = try #require(Terminal(columns: 16, rows: 2))
        terminal.feed(Array("hit hit hit".utf8))

        let found = terminal.beginSearch("hit")
        #expect(found)
        let moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.activeSearchMatchRange?.start.column == 4)
        let viewportTop = terminal.scrollProjection.topRow

        terminal.feed(Array("\u{1B}[1;5Hxxx".utf8))

        #expect(terminal.activeSearchMatchRange?.start.column == 8)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 2))
        #expect(terminal.scrollProjection.topRow == viewportTop)
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

    @Test("every search mutation damages the whole viewport")
    func searchMutationsRecordFullDamage() throws {
        // Intent: begin, next, previous, clear, and needle replacement repaint every
        //   viewport row because any row's visible match set may have changed.
        // Why it exists: per-match damage encoded the old one-highlight model and can
        //   leave stale pixels when the renderer consumes the complete visible set.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("hit\r\nzzz\r\nhit\r\nyyy".utf8))
        _ = terminal.drainDamage()

        var moved = terminal.beginSearch("hit")
        #expect(moved)
        #expect(terminal.drainDamage() == .full)

        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.drainDamage() == .full)

        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.drainDamage() == .full)

        moved = terminal.beginSearch("nope")
        #expect(moved == false)
        #expect(terminal.drainDamage() == .full)

        moved = terminal.beginSearch("hit")
        #expect(moved)
        _ = terminal.drainDamage()
        terminal.clearSearch()
        #expect(terminal.drainDamage() == .full)
    }

    @Test("content damage reaches rows where a multiline match begins")
    func contentDamageWidensByNeedleSpan() throws {
        // Intent: writing the last unit of a multiline match damages the earlier row
        //   where the newly highlighted occurrence begins.
        // Why it exists: row-local content damage otherwise leaves the first half of a
        //   cross-row highlight unchanged until an unrelated repaint.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("ABC\r\n".utf8))
        _ = terminal.beginSearch("ABC\nZ")
        _ = terminal.drainDamage()

        terminal.feed(Array("Z".utf8))
        let damage = terminal.drainDamage()

        #expect(terminal.activeSearchMatchRange?.start.row == 0)
        #expect(damage.contains(row: 0))
        #expect(damage.contains(row: 1))
    }

    @Test("scroll shifts are refused while a search is open")
    func openSearchForcesFullScrollDamage() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("a\r\nb\r\nc".utf8))
        _ = terminal.beginSearch("a")
        _ = terminal.drainDamage()

        terminal.feed(Array("\r\nd".utf8))

        #expect(terminal.drainDamage() == .full)
    }

    @Test("windowed matches equal the whole ordered sequence restricted to the window")
    func windowedMatchesEqualWholeSequenceRestriction() throws {
        // Intent: every row-window read returns the whole search sequence restricted
        //   to matches intersecting that window across blanks, wraps, and storage seams.
        // Why it exists: rendering must stay bounded without inventing separate matching
        //   semantics at viewport edges or the history/live seam.
        let cases = [
            (columns: 4, rows: 4, before: "ABCDABCDABCD", after: "", needle: "DAB"),
            (columns: 4, rows: 2, before: "one\r\ntwo\r\nthr", after: "", needle: "o\nt"),
            (columns: 4, rows: 2, before: "old\r\nABCDEFG", after: "HIJK", needle: "\nA"),
            (columns: 4, rows: 2, before: "A", after: "\r\n\r\nB", needle: "\n"),
            (columns: 4, rows: 2, before: "A", after: "\r\n\r\n", needle: "\n"),
        ]

        for testCase in cases {
            var terminal = try #require(Terminal(columns: testCase.columns, rows: testCase.rows))
            terminal.feed(Array(testCase.before.utf8))
            _ = terminal.beginSearch(testCase.needle)
            terminal.feed(Array(testCase.after.utf8))

            let totalRows = terminal.scrollProjection.totalRows
            for lower in 0..<totalRows {
                for upper in (lower + 1)...totalRows {
                    let window = lower..<upper
                    #expect(
                        terminal.searchMatchRanges(in: window)
                            == terminal.scannedSearchMatchRanges(in: window)
                    )
                }
            }
        }
    }

    @Test("the search scan agrees with an independently segmented projection oracle")
    func searchScanMatchesIndependentOracle() throws {
        // Intent: search returns exactly the overlapping grapheme-aligned matches in the
        //   painted logical-text projection under per-grapheme canonical caseless folding.
        // Why it exists: index-versus-scan tests share one matcher, so a streaming rewrite
        //   could change the match set while both sides stayed green.
        // Scenario: a pane combines normalization forms, expanding folds, padding, soft wraps,
        //   hard boundaries, and the retained/live seam while a user searches each distinction.
        let cases = [
            (columns: 5, rows: 2, text: "AaA ñ n\u{0303}", needles: ["aa", "Ñ", "n\u{0303}"]),
            (columns: 5, rows: 2, text: "ß ﬁ ① Ａ", needles: ["ß", "ss", "ﬁ", "fi", "1", "A"]),
            (columns: 5, rows: 2, text: "🙂A🙂a", needles: ["🙂a"]),
            (columns: 4, rows: 2, text: "ABCDABCDABCD", needles: ["DAB", "BCDAB"]),
            (columns: 4, rows: 2, text: "A\r\n\r\nB", needles: ["\n", "A\n", "\nB"]),
        ]

        for testCase in cases {
            var terminal = try #require(Terminal(columns: testCase.columns, rows: testCase.rows))
            terminal.feed(Array(testCase.text.utf8))

            for needle in testCase.needles {
                _ = terminal.beginSearch(needle)
                let rows = 0..<terminal.scrollProjection.totalRows
                #expect(
                    terminal.searchMatchRanges(in: rows)
                        == independentSearchMatchRanges(in: terminal, needle: needle)
                )
            }
        }

        var padding = try #require(Terminal(columns: 4, rows: 2))
        padding.moveCursor(row: 0, column: 3)
        padding.feed(Array("XY".utf8))
        _ = padding.beginSearch("  XY")
        let paddingRows = 0..<padding.scrollProjection.totalRows
        #expect(
            padding.searchMatchRanges(in: paddingRows)
                == independentSearchMatchRanges(in: padding, needle: "  XY")
        )
    }

    @Test("sequential search scans locate retained history once")
    func sequentialSearchScansLocateRetainedHistoryOnce() throws {
        // Intent: a sequential search scan enters retained history once and advances through it.
        // Why it exists: one display-row lookup per retained row makes a whole-history scan
        //   quadratic-ish in the number of stored records.
        // Scenario: a deep pane scans all matches, then a window wholly inside retained history.
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        for index in 0..<80 {
            terminal.feed(Array("row\(index)\r\n".utf8))
        }
        _ = terminal.beginSearch("row")
        let totalRows = terminal.scrollProjection.totalRows
        let scans = [0..<totalRows, 0..<(totalRows - 3)]

        for rows in scans {
            let locates = LocateCounter.measure {
                _ = terminal.scannedSearchMatchRanges(in: rows)
            }

            #expect(locates == 1)
        }
    }

    @Test("the retained index equals a full rescan across output tail changes and resize")
    func retainedIndexMatchesFullRescanAcrossStoreMutations() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("ABCDAB".utf8))
        _ = terminal.beginSearch("DAB")

        assertSearchIndexMatchesFullScan(terminal)
        terminal.feed(Array("CD\r\nDAB".utf8))
        assertSearchIndexMatchesFullScan(terminal)
        terminal.resize(columns: 3, rows: 3)
        assertSearchIndexMatchesFullScan(terminal)
        terminal.resize(columns: 6, rows: 2)
        assertSearchIndexMatchesFullScan(terminal)
    }

    @Test("blank rows contribute boundaries only when later content exists")
    func blankRowBoundariesFollowTheFullProjection() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("A".utf8))
        _ = terminal.beginSearch("\n")
        #expect(terminal.searchStatus == .empty)

        terminal.feed(Array("\r\n\r\nB".utf8))

        #expect(terminal.searchStatus == .matched(selected: 0, total: 2))
        assertSearchIndexMatchesFullScan(terminal)

        var trailing = try #require(Terminal(columns: 4, rows: 4))
        trailing.feed(Array("A\r\n".utf8))
        _ = trailing.beginSearch("\n")
        #expect(trailing.searchStatus == .empty)
        assertSearchIndexMatchesFullScan(trailing)
    }

    @Test("navigation cost stays bounded across quiet and streaming history depths")
    func navigationUsesTheOrderedIndex() throws {
        func measuredRows(depth: Int, streaming: Bool) throws -> Int {
            var terminal = try #require(Terminal(columns: 8, rows: 3))
            terminal.feed(Array("hit\r\n".utf8))
            if streaming { _ = terminal.beginSearch("hit") }
            for index in 0..<depth {
                terminal.feed(Array("row\(index)\r\n".utf8))
            }
            terminal.feed(Array("hit\r\nlast".utf8))
            if streaming == false { _ = terminal.beginSearch("hit") }

            let materializations = WholeProjectionCounter.measure {
                _ = terminal.searchNext()
                _ = terminal.searchPrevious()
                _ = terminal.searchStatus
            }
            #expect(materializations == 0)
            return ProjectionRowCounter.measure {
                _ = terminal.searchNext()
            }
        }

        for streaming in [false, true] {
            let shallowRows = try measuredRows(depth: 20, streaming: streaming)
            let deepRows = try measuredRows(depth: 200, streaming: streaming)
            #expect(shallowRows <= 6)
            #expect(deepRows <= shallowRows)
        }
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
        assertSearchIndexMatchesFullScan(terminal)

        terminal.feed(Array("\r\nhit".utf8))
        #expect(terminal.searchStatus == .matched(selected: 2, total: 3))
        assertSearchIndexMatchesFullScan(terminal)
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
            scrollbackBudgetBytes: historyBudget(lineCells: [3, 3, 1])
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
        assertSearchIndexMatchesFullScan(terminal)

        terminal.feed(Array("\r\ne\r\nf".utf8))
        #expect(terminal.searchStatus == .empty)
        assertSearchIndexMatchesFullScan(terminal)
    }
}

private func assertSearchIndexMatchesFullScan(
    _ terminal: Terminal,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let rows = 0..<terminal.scrollProjection.totalRows
    #expect(
        terminal.searchMatchRanges(in: rows) == terminal.scannedSearchMatchRanges(in: rows),
        sourceLocation: sourceLocation
    )
}

private struct SearchOracleScalar {
    var scalar: Unicode.Scalar
    var start: TerminalTextPosition
    var end: TerminalTextPosition
}

private struct SearchOracleGrapheme {
    var key: [Unicode.Scalar]
    var start: TerminalTextPosition
    var end: TerminalTextPosition
}

private func independentSearchMatchRanges(
    in terminal: Terminal,
    needle: String
) -> [TerminalTextRange] {
    let projection = independentSearchProjection(terminal)
    let projectionScalars = projection.map(\.scalar)
    let projectedGraphemes = graphemeRanges(in: projectionScalars).map { range in
        SearchOracleGrapheme(
            key: canonicalCaselessKey(for: Array(projectionScalars[range])),
            start: projection[range.lowerBound].start,
            end: projection[range.upperBound - 1].end
        )
    }
    let needleScalars = Array(needle.unicodeScalars)
    let needleKeys = graphemeRanges(in: needleScalars).map {
        canonicalCaselessKey(for: Array(needleScalars[$0]))
    }
    guard needleKeys.isEmpty == false, needleKeys.count <= projectedGraphemes.count else {
        return []
    }

    return projectedGraphemes.indices.dropLast(needleKeys.count - 1).compactMap { start in
        let end = start + needleKeys.count
        guard projectedGraphemes[start..<end].map(\.key) == needleKeys else { return nil }
        return TerminalTextRange(
            start: projectedGraphemes[start].start,
            end: projectedGraphemes[end - 1].end
        )
    }
}

private func independentSearchProjection(_ terminal: Terminal) -> [SearchOracleScalar] {
    let structures = terminal.rowStructure
    let retainedCount = terminal.scrollbackRowCount
    let rows = structures.compactMap { structure -> Terminal.GridRow? in
        structure.isRetained
            ? terminal.retainedRowForTesting(at: structure.index)
            : terminal.liveRowForTesting(at: structure.index - retainedCount)
    }
    guard let lastContentRow = structures.lastIndex(where: { $0.contentEnd > 0 }) else {
        return []
    }

    var result: [SearchOracleScalar] = []
    for rowIndex in 0...lastContentRow {
        let row = rows[rowIndex]
        let structure = structures[rowIndex]
        let projectedEnd = structure.isSoftWrapped
            ? min(
                terminal.viewportColumnCount,
                structure.marginCellKind == .spacerHead
                    ? row.cells.count + 1
                    : row.cells.count
            )
            : structure.contentEnd
        var column = 0
        while column < projectedEnd {
            let cell = row.cell(at: column)
            let width = cell.kind == .wideHead ? 2 : 1
            let scalars: [Unicode.Scalar]
            switch cell.kind {
            case .narrow, .wideHead:
                scalars = Array(cell.scalars)
            case .padding:
                scalars = [" "]
            case .wideTail, .spacerHead:
                scalars = []
            }
            for scalar in scalars {
                result.append(SearchOracleScalar(
                    scalar: scalar,
                    start: TerminalTextPosition(row: rowIndex, column: column),
                    end: TerminalTextPosition(row: rowIndex, column: column + width)
                ))
            }
            column += width
        }
        if rowIndex < lastContentRow, structure.isSoftWrapped == false {
            result.append(SearchOracleScalar(
                scalar: "\n",
                start: TerminalTextPosition(row: rowIndex, column: projectedEnd),
                end: TerminalTextPosition(row: rowIndex + 1, column: 0)
            ))
        }
    }
    return result
}

private func graphemeRanges(in scalars: [Unicode.Scalar]) -> [Range<Int>] {
    guard scalars.isEmpty == false else { return [] }
    var result: [Range<Int>] = []
    var start = 0
    var previous = scalars[0]
    var state = GraphemeBreakState()
    for index in scalars.indices.dropFirst() {
        let current = scalars[index]
        if graphemeBreak(between: previous, and: current, state: &state) {
            result.append(start..<index)
            start = index
            state = GraphemeBreakState()
        }
        previous = current
    }
    result.append(start..<scalars.endIndex)
    return result
}
