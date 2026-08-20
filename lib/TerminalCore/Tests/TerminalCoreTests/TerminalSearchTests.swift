// Literal logical-history search semantics and navigation proofs.
import Testing

@testable import TerminalCore

/// Locks unit-aligned search to live terminal content without a stale match cache.
struct TerminalSearchTests {
    @Test("incremental needle entry is identical to a fresh search")
    func incrementalNeedleEntryMatchesFreshSearch() throws {
        // Intent: every strict grapheme-key append produces exactly the state a fresh search of
        //   the final needle produces, while re-segmentation falls back without changing results.
        // Why it exists: refining from old match starts can otherwise lose overlaps, boundaries,
        //   wide cells, folded graphemes, or a match that crosses the closed/live seam.
        // Scenario: a user types and pastes through representative needles over mixed history.
        var base = try #require(Terminal(columns: 8, rows: 3))
        base.feed(Array("aaaa\r\nwide🙂x\r\nA\r\nX\r\nn\u{0303} sharpß\r\nseam error".utf8))

        let sequences = [
            ["a", "aa", "aaa"],
            ["w", "wide🙂"],
            ["A", "A\n", "A\nX"],
            ["n", "n\u{0303}"],
            ["s", "sharpß"],
            ["ß", "ßx"],
            ["e", "error"],
            ["z", "zz"],
        ]
        for sequence in sequences {
            var incremental = base
            for needle in sequence {
                _ = incremental.beginSearch(needle)
                var fresh = base
                _ = fresh.beginSearch(needle)

                #expect(incremental == fresh, "needle: \(needle)")
                assertSearchIndexMatchesOracle(incremental, needle: needle)
            }
        }

        var denseBase = try #require(Terminal(columns: 4, rows: 1))
        denseBase.feed(Array("a\r\na\r\na\r\na".utf8))
        var denseIncremental = denseBase
        _ = denseIncremental.beginSearch("a")
        _ = denseIncremental.beginSearch("aa")
        var denseFresh = denseBase
        _ = denseFresh.beginSearch("aa")
        #expect(denseIncremental == denseFresh)
        assertSearchIndexMatchesOracle(denseIncremental, needle: "aa")

        var seamBase = try #require(Terminal(columns: 8, rows: 1))
        seamBase.feed(Array("old\r\nerr\r\nor".utf8))
        var seamIncremental = seamBase
        _ = seamIncremental.beginSearch("err\n")
        _ = seamIncremental.beginSearch("err\nor")
        var seamFresh = seamBase
        _ = seamFresh.beginSearch("err\nor")
        #expect(seamIncremental == seamFresh)
        assertSearchIndexMatchesOracle(seamIncremental, needle: "err\nor")
    }

    @Test("needle append scans only old-match neighborhoods")
    func needleAppendClosedRecordWorkIsIndependentOfUnmatchedDepth() throws {
        // Intent: extending a needle visits only closed records near matches of the old needle.
        // Why it exists: rebuilding from record zero makes every find-field keystroke scale with
        //   retained history even when all added history cannot contain the longer needle.
        // Scenario: shallow and deep panes have the same matching tail after different amounts of
        //   non-matching history; an append costs the same, while a replacement scans both depths.
        func work(depth: Int) throws -> (append: Int, rebuild: Int) {
            var terminal = try #require(Terminal(columns: 16, rows: 3))
            for index in 0..<depth {
                terminal.feed(Array("quiet \(index)\r\n".utf8))
            }
            terminal.feed(Array("target error\r\ntail one\r\ntail two\r\ntail three".utf8))
            _ = terminal.beginSearch("err")

            let append = Instrument.closedRecordSearchScan.measure {
                _ = terminal.beginSearch("error")
            }
            let rebuild = Instrument.closedRecordSearchScan.measure {
                _ = terminal.beginSearch("miss")
            }
            return (append, rebuild)
        }

        let shallow = try work(depth: 20)
        let deep = try work(depth: 200)

        #expect(shallow.append > 0, "the append path must scan its old-match neighborhood")
        #expect(deep.append == shallow.append)
        #expect(shallow.rebuild > shallow.append)
        #expect(deep.rebuild > shallow.rebuild, "the full-build instrument must remain live")
    }

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

    @Test("forced-split erase fill never enters copied or searched text")
    func forcedSplitEraseFillIsNotTextAtAnyWidth() throws {
        // Intent: a forced-split logical line projects only stored cells and its hard boundary,
        //   independent of the width used to paint its trailing background erase.
        // Why it exists: treating the erase fill as padding text made copy and the match set
        //   change on resize even though the retained record's content did not change.
        // Scenario: a line longer than the small arena's forced-split cap ends under EL 0 with a
        //   background color, then the user copies and searches it before and after a reflow.
        let content = String(repeating: "A", count: 400)
        let expected = content + "\nX\nY\nZ\nW"
        var terminal = try #require(Terminal(
            columns: 32,
            rows: 2,
            scrollbackBudgetBytes: 1 << 16
        ))
        terminal.feed(Array(
            (content + "\u{1B}[41m\u{1B}[K\u{1B}[0m\r\nX\r\nY\r\nZ\r\nW").utf8
        ))

        #expect(terminal.retainedRecordSummaryForTesting(at: 0)?.isForcedSplit == true)
        #expect(terminal.fullHistoryText == expected)
        var found = terminal.beginSearch("A\nX")
        #expect(found)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))
        let recordCoordinates = terminal.indexedSearchRecordRangesForTesting
        #expect(recordCoordinates.count == 1)

        terminal.resize(columns: 17, rows: 2)

        #expect(terminal.fullHistoryText == expected)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 1))
        #expect(terminal.indexedSearchRecordRangesForTesting == recordCoordinates)
        found = terminal.beginSearch("A \nX")
        #expect(found == false)
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

    @Test("the alternate screen refuses to begin a search")
    func alternateScreenReportsNoSearch() throws {
        // Intent: alternate-screen content cannot create search state that outlives the screen.
        // Why it exists: match anchors are absolute primary-stream rows, while the alternate
        //   projection restarts at row zero and uses different soft-wrap semantics.
        // Scenario: an alternate-screen application paints a match, starts search, exits, and
        //   then ordinary primary output arrives.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("hit\r\nzzz\r\nyyy".utf8))
        terminal.feed(Array("\u{1B}[?1049h".utf8))
        terminal.feed(Array("hit".utf8))

        let found = terminal.beginSearch("hit")
        #expect(found == false)
        #expect(terminal.searchStatus == nil)
        #expect(terminal.activeSearchMatchRange == nil)

        terminal.feed(Array("\u{1B}[?1049l".utf8))
        terminal.feed(Array("\r\nmore".utf8))
        #expect(terminal.searchStatus == nil)
        #expect(terminal.activeSearchMatchRange == nil)
    }

    @Test("entering the alternate screen clears primary search state")
    func alternateScreenClearsPrimarySearch() throws {
        // Intent: an alternate-screen transition drops every part of a primary-screen search.
        // Why it exists: lifting search into one durable subsystem must not leave its match index
        //   alive after the query and visible selection have been cleared.
        // Scenario: the primary screen has multiple matches and an active search, then an
        //   alternate-screen application opens and closes before navigation is attempted again.
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("hit\r\nhit".utf8))
        var moved = terminal.beginSearch("hit")
        #expect(moved)
        #expect(terminal.searchStatus == .matched(selected: 0, total: 2))

        terminal.feed(Array("\u{1B}[?1049h".utf8))
        #expect(terminal.searchStatus == nil)
        moved = terminal.searchNext()
        #expect(moved == false)
        moved = terminal.searchPrevious()
        #expect(moved == false)

        terminal.feed(Array("\u{1B}[?1049l".utf8))
        #expect(terminal.searchStatus == nil)
        moved = terminal.searchNext()
        #expect(moved == false)
        moved = terminal.searchPrevious()
        #expect(moved == false)
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

    @Test("a seam boundary ending at row start belongs to the preceding row")
    func seamBoundaryEndingAtRowStartIntersectsPrecedingRow() throws {
        // Intent: a hard boundary synthesized between closed history and the live suffix
        //   remains visible in the row containing its start, not the row after its end.
        // Why it exists: the suffix matcher admits this boundary through seed context, and
        //   moving its intersection filter to the caller must preserve half-open row geometry.
        // Scenario: a one-row pane scrolls A into a closed record while B remains live, and
        //   a newline search asks for matches in each side of that seam separately.
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("A\r\nB".utf8))
        _ = terminal.beginSearch("\n")

        let seam = TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 1),
            end: TerminalTextPosition(row: 1, column: 0)
        )
        #expect(terminal.searchMatchRanges(in: 0..<1) == [seam])
        #expect(terminal.searchMatchRanges(in: 1..<2).isEmpty)
        #expect(terminal.scannedSearchMatchRanges(in: 0..<1) == [seam])
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
            let locates = Instrument.displayRowLocate.measure {
                _ = terminal.scannedSearchMatchRanges(in: rows)
            }

            #expect(locates == 1)
        }
    }

    @Test("width changes do no retained search work at shallow and deep history")
    func widthChangeSearchCostIsIndependentOfHistoryDepth() throws {
        // Intent: changing width neither projects retained rows nor visits retained matches when
        //   the closed-history seam stays put.
        // Why it exists: display-row-keyed matches forced every width step to rebuild the whole
        //   retained index, so resize cost grew with scrollback depth.
        // Scenario: otherwise identical panes retain tens or hundreds of short hard-ended lines,
        //   keep a dense search open, then widen without moving a record across the live seam.
        for depth in [40, 400] {
            var terminal = try #require(Terminal(columns: 8, rows: 3))
            for _ in 0..<depth {
                terminal.feed(Array("hit\r\n".utf8))
            }
            _ = terminal.beginSearch("hit")

            var projectedRows = 0
            let maintenance = Instrument.searchIndexMaintenance.measure {
                projectedRows = Instrument.projectionRow.measure {
                    terminal.resize(columns: 9, rows: 3)
                }
            }

            #expect(projectedRows == 0)
            #expect(maintenance == 0)
            assertSearchIndexMatchesFullScan(terminal)
        }
    }

    @Test("closed-history match endpoints survive width changes unchanged")
    func closedHistoryMatchCoordinatesAreWidthInvariant() throws {
        // Intent: a retained match keeps the same record identities and cell offsets while its
        //   display rows refold around a narrower width.
        // Why it exists: matching content is stable across reflow only if the index stores
        //   content coordinates rather than recomputed row and column pairs.
        // Scenario: one match crosses a hard boundary between two closed records, then the first
        //   record grows from one display row to two.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("alpha\r\nbeta\r\ngamma\r\ndelta".utf8))
        _ = terminal.beginSearch("pha\nbeta")
        let before = terminal.indexedSearchRecordRangesForTesting

        #expect(before.count == 1)
        terminal.resize(columns: 4, rows: 2)

        #expect(terminal.indexedSearchRecordRangesForTesting == before)
        assertSearchIndexMatchesOracle(terminal, needle: "pha\nbeta")
    }

    @Test("a tail match never retargets after its record is pulled and readmitted")
    func tailRecordReuseRetiresIndexedCoordinates() throws {
        // Intent: removing the closed tail invalidates its indexed match, and admitting the same
        //   text again gives the replacement match a distinct record coordinate.
        // Why it exists: a position-derived record id lets a retired match silently name the next
        //   record admitted at that sequence slot.
        // Scenario: a height increase pulls one matching record into the live grid, then shrinking
        //   returns that text to closed history.
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("hit\r\n".utf8))
        _ = terminal.beginSearch("hit")
        let retired = try #require(terminal.indexedSearchRecordRangesForTesting.first)

        terminal.resize(columns: 4, rows: 2)
        #expect(terminal.indexedSearchRecordRangesForTesting.isEmpty)
        terminal.resize(columns: 4, rows: 1)

        let replacement = try #require(terminal.indexedSearchRecordRangesForTesting.first)
        #expect(replacement != retired)
        assertSearchIndexMatchesOracle(terminal, needle: "hit")
    }

    @Test("head trimming retires a match whose start leaves the record")
    func headTrimRetiresMatchStartingInEvictedCells() throws {
        // Intent: trimming only the first display row of a record removes a match that began in
        //   that row even when its end remains retained under the same record identity.
        // Why it exists: keeping the record id stable across a trim must not keep a coordinate
        //   whose original cell offset has already left history.
        // Scenario: a two-row logical line holds a cross-row match, then a later hard line makes
        //   the budget trim the logical line's first row.
        var terminal = try #require(Terminal(
            columns: 4,
            rows: 1,
            scrollbackBudgetBytes: historyBudget(lineCells: [8, 1, 1, 1], paneColumns: 4)
        ))
        terminal.feed(Array("ABCDhitZ\r\nx".utf8))
        _ = terminal.beginSearch("Dhit")
        #expect(terminal.indexedSearchRecordRangesForTesting.count == 1)

        terminal.feed(Array("\r\ny\r\nz\r\na\r\nb\r\nc".utf8))

        #expect(terminal.indexedSearchRecordRangesForTesting.isEmpty)
        assertSearchIndexMatchesOracle(terminal, needle: "Dhit")
    }

    @Test("a width change reports search work only when the closed seam moves")
    func widthChangeSearchMaintenanceInstrumentDetectsSeamMovement() throws {
        // Intent: the resize maintenance counter stays live for the bounded case where reflow
        //   closes new history even though stable closed records require no work.
        // Why it exists: an instrument that always reports zero cannot prove retained-depth
        //   independence on ordinary width changes.
        // Scenario: widening a pane pulls a matching closed record back across the live seam.
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("hit\r\nhit\r\nhit\r\nABCDEFGHIJK".utf8))
        _ = terminal.beginSearch("hit")

        var projectedRows = 0
        let maintenance = Instrument.searchIndexMaintenance.measure {
            projectedRows = Instrument.projectionRow.measure {
                terminal.resize(columns: 12, rows: 3)
            }
        }

        #expect(projectedRows == 0)
        #expect(maintenance > 0)
        assertSearchIndexMatchesOracle(terminal, needle: "hit")
    }

    @Test("a position between matches resolves to the same occurrence at every width")
    func nearestOccurrenceIsWidthInvariant() throws {
        // Intent: nearest-match resolution measures content rather than hard-line display padding.
        // Why it exists: row times width gives each hard-ended line width-dependent phantom space,
        //   which can switch the selected occurrence even though the text and anchor did not move.
        // Scenario: an anchor three cells into the middle line is nearer the first of two matches;
        //   widening or narrowing changes the rows but not that choice.
        var terminal = try #require(Terminal(columns: 8, rows: 5))
        terminal.feed(Array("hit\r\nabcdefghij\r\nhit".utf8))
        _ = terminal.beginSearch("hit")
        terminal.setSearchPositionForTesting(TerminalTextPosition(row: 1, column: 3))

        #expect(terminal.activeSearchMatchRange?.start.row == 0)
        // The older occurrence, counted the way the find bar counts.
        #expect(terminal.searchStatus == .matched(selected: 1, total: 2))

        // Narrower splits the middle line in two, wider joins it back into one; neither moves a
        // cell of text, so neither may move the choice.
        for columns in [5, 16] {
            terminal.resize(columns: columns, rows: 5)

            #expect(terminal.activeSearchMatchRange?.start.row == 0, "at \(columns) columns")
            #expect(
                terminal.searchStatus == .matched(selected: 1, total: 2),
                "at \(columns) columns"
            )
        }
    }

    @Test("nearest distance crosses from closed history into the live suffix")
    func nearestOccurrenceAcrossClosedLiveSeamUsesOneContentCoordinate() throws {
        // Intent: a durable position in the live suffix compares a retained match and a live
        //   match in the same content-unit coordinate, including the hard seam boundary.
        // Why it exists: closed ranks stop at `LogicalLineStore`, while live ranks scan from the
        //   seam; either dropping or double-counting that boundary can switch the nearest match.
        // Scenario: the first occurrence has scrolled into a closed record, the position is in
        //   the middle live line, and the second occurrence remains live.
        var terminal = try #require(Terminal(columns: 16, rows: 2))
        terminal.feed(Array("hit\r\nabcdefghij\r\nhit".utf8))
        _ = terminal.beginSearch("hit")
        terminal.setSearchPositionForTesting(TerminalTextPosition(row: 1, column: 3))

        #expect(terminal.activeSearchMatchRange?.start.row == 0)
        #expect(terminal.searchStatus == .matched(selected: 1, total: 2))
    }

    @Test("closed-history nearest distance does endpoint-local work")
    func closedHistoryNearestDistanceWorkIsIndependentOfDepthAndGap() throws {
        // Intent: resolving between two retained matches spends the same bounded work at shallow
        //   and deep retained depths, whether the matches have a short or long gap between them.
        // Why it exists: the former distance walk visited every projected unit in that gap, so a
        //   find-bar read could grow with retained depth even though both endpoints were indexed.
        // Scenario: equally aligned records bracket the durable position at two history depths
        //   and across gaps spanning one or three complete record blocks.
        func work(depth: Int, gap: Int) throws -> Int {
            var terminal = try #require(Terminal(columns: 8, rows: 3))
            for _ in 0..<depth { terminal.feed(Array("x\r\n".utf8)) }
            terminal.feed(Array("hit\r\n".utf8))
            for _ in 0..<gap { terminal.feed(Array("x\r\n".utf8)) }
            terminal.feed(Array("hit\r\ntail\r\ntail\r\ntail".utf8))
            _ = terminal.beginSearch("hit")
            terminal.setSearchPositionForTesting(
                TerminalTextPosition(row: depth + 1 + gap / 2, column: 0)
            )

            var selected: TerminalTextRange?
            let spent = Instrument.searchDistanceWork.measure {
                selected = terminal.activeSearchMatchRange
            }
            #expect(selected != nil)
            return spent
        }

        let shallowShort = try work(depth: 64, gap: 64)
        let shallowLong = try work(depth: 64, gap: 192)
        let deepShort = try work(depth: 640, gap: 64)
        let deepLong = try work(depth: 640, gap: 192)

        let costs = [shallowShort, shallowLong, deepShort, deepLong]
        let least = costs.min() ?? 0
        let most = costs.max() ?? 0
        #expect(least > 0, "the instrument must observe distance resolution")
        #expect(deepShort == shallowShort)
        #expect(deepLong == shallowLong)
        #expect(
            most - least <= 8,
            "fixed-block endpoint alignment may differ by one short record, not by the gap"
        )
        #expect(most <= Terminal.LogicalLineStore.blockSize * 4)
    }

    @Test("closed-record index advance performs no display-row projection")
    func closedRecordIndexAdvanceAvoidsDisplayProjection() throws {
        // Intent: advancing the closed-history search index reads record content directly.
        // Why it exists: a display-row projection on index maintenance makes its stored
        //   coordinates width-dependent and adds fold work to the feed path.
        // Scenario: identical tailing panes keep absent one- and 24-character needles open.
        func measuredRows(needle: String) throws -> Int {
            var terminal = try #require(Terminal(columns: 32, rows: 3))
            terminal.feed(Array("seed\r\nseed\r\nseed".utf8))
            _ = terminal.beginSearch(needle)

            return Instrument.projectionRow.measure {
                for index in 0..<20 {
                    terminal.feed(Array("row \(index)\r\n".utf8))
                }
            }
        }

        let shortNeedleRows = try measuredRows(needle: "z")
        let longNeedleRows = try measuredRows(needle: String(repeating: "z", count: 24))

        #expect(shortNeedleRows == 0)
        #expect(longNeedleRows == 0)
    }

    @Test("a highlighted frame resolves the matches it draws, not the matches history holds")
    func frameSearchResolutionCostIsIndependentOfHistoryDepth() throws {
        // Intent: the reads one highlighted frame makes -- the counter, the visible ranges and
        //   the selected occurrence -- resolve a viewport-sized number of record coordinates and
        //   spend a fixed number of display-row locates, at any retained depth.
        // Why it exists: `31/I7` and `31/AR3`. Record coordinates only order matches if the
        //   comparison stays in record space; comparing them by resolving turns each ordered read
        //   into a logarithmic walk of folds over retained history, which every behavioral
        //   assertion in this suite passes straight through.
        // Scenario: a user holds a dense search open over shallow and deep scrollback while the
        //   renderer plans frames.
        func frameCost(depth: Int) throws -> (resolutions: Int, locates: Int) {
            var terminal = try #require(Terminal(columns: 16, rows: 8))
            for _ in 0..<depth {
                terminal.feed(Array("hit line\r\n".utf8))
            }
            _ = terminal.beginSearch("hit")
            // Warm the read paths once, so the counts measure a steady frame rather than
            // whatever the first one happens to fault in.
            _ = terminal.searchStatus

            var locates = 0
            let resolutions = Instrument.recordPositionResolution.measure {
                locates = Instrument.displayRowLocate.measure {
                    _ = terminal.searchStatus
                    _ = terminal.searchMatchRanges(in: 0..<8)
                    _ = terminal.activeSearchMatchRange
                }
            }
            return (resolutions, locates)
        }

        let shallow = try frameCost(depth: 40)
        let deep = try frameCost(depth: 400)

        // Calibration first: the frame highlights retained matches, so a working read path must
        // resolve the ones it draws. Without this the whole test passes at zero -- a disconnected
        // counter, or a read path that stopped consulting the index -- which is the instrument
        // that cannot say "not measured" `agent-docs/measurement-discipline.md` rules out.
        #expect(shallow.resolutions >= 8)
        #expect(deep.resolutions == shallow.resolutions)
        #expect(deep.locates == shallow.locates)
        // Two endpoints for each of the eight visible matches and the selected one, plus the
        // needle-length seam seed each of the three reads resolves.
        #expect(shallow.resolutions <= 48)
    }

    @Test("entering a needle builds the retained index without materializing record cells")
    func needleEntryBuildStreamsClosedRecordCells() throws {
        // Intent: building the closed-history index for a new needle streams the arena, so no
        //   depth of retained history turns a keystroke into decoded cells.
        // Why it exists: a build that materializes each record's cells pays a style read, a
        //   hyperlink probe and a content-identity probe per cell for a scan that keeps a folded
        //   key, so the per-keystroke cost is retained depth times work the scan discards.
        // Scenario: a user types a needle into the find bar over shallow and deep scrollback.
        func buildCost(depth: Int) throws -> Int {
            var terminal = try #require(Terminal(columns: 16, rows: 4))
            for index in 0..<depth {
                terminal.feed(Array("line \(index) hit\r\n".utf8))
            }
            return Instrument.recordCellMaterialization.measure {
                _ = terminal.beginSearch("hit")
            }
        }

        #expect(try buildCost(depth: 50) == 0)
        #expect(try buildCost(depth: 500) == 0)

        // Calibration: the counter reports a materializing read, so the zeroes above are the
        // build's behavior rather than an instrument nothing reaches.
        var probe = try #require(Terminal(columns: 16, rows: 4))
        for _ in 0..<8 {
            probe.feed(Array("abcd\r\n".utf8))
        }
        let materialized = Instrument.recordCellMaterialization.measure {
            _ = probe.scrollbackRecordContentIdentityShape(at: 0)
        }
        #expect(materialized == 4)
    }

    @Test("the retained index keys wide and spilled cells the way a full scan does")
    func retainedIndexKeysWideAndSpilledCellsLikeAFullScan() throws {
        // Intent: occurrences indexed out of closed records agree with an independent scan when
        //   those records hold two-column clusters and multi-scalar graphemes.
        // Why it exists: the index reads closed records through a streaming decoder of its own,
        //   so a cell whose scalars live in the spill table, or whose width is two, is exactly
        //   where that decoder can disagree with the painted one while every other search test
        //   stays green.
        // Scenario: a pane scrolls emoji and combining-mark text into scrollback and the user
        //   searches for it.
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("🙂ab\r\nn\u{0303}xy\r\nz🙂q\r\ntail".utf8))
        #expect(terminal.scrollbackRowCount >= 2)

        for needle in ["🙂", "🙂a", "ñ", "n\u{0303}x", "🙂q", "b\nñ"] {
            _ = terminal.beginSearch(needle)
            assertSearchIndexMatchesOracle(terminal, needle: needle)
        }
    }

    @Test("closed-history maintenance examines logarithmically many existing matches")
    func closedHistoryMaintenanceCostStaysBoundedWithManyExistingMatches() throws {
        // Intent: closing one more history row never walks the retained match sequence.
        // Why it exists: eviction and truncation maintenance filtered every stored match on
        //   each scrolled row, making a dense open search progressively slow down the feed path.
        // Scenario: a pane retains hundreds of matching log lines before one non-match scrolls.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        for _ in 0..<512 {
            terminal.feed(Array("hit\r\n".utf8))
        }
        _ = terminal.beginSearch("hit")

        let comparisons = Instrument.searchIndexMaintenance.measure {
            terminal.feed(Array("miss\r\n".utf8))
        }

        #expect(comparisons <= 32)
    }

    @Test("head eviction cost is unchanged by retained match density")
    func headEvictionMaintenanceIsIndependentOfMatchDensity() throws {
        // Intent: evicting one display row never inspects the surviving closed match sequence.
        // Why it exists: filtering or binary-searching retained matches makes head maintenance
        //   depend on how many occurrences history holds even though their coordinates do not move.
        // Scenario: identical bounded panes evict one row while equal-length needles match every
        //   retained line or none of them.
        func measuredCost(needle: String) throws -> Int {
            var terminal = try #require(Terminal(
                columns: 8,
                rows: 2,
                scrollbackBudgetBytes: historyBudget(lines: 32, cells: 3, paneColumns: 8)
            ))
            for _ in 0..<34 {
                terminal.feed(Array("hit\r\n".utf8))
            }
            _ = terminal.beginSearch(needle)
            return Instrument.searchIndexMaintenance.measure {
                terminal.feed(Array("new\r\n".utf8))
            }
        }

        let dense = try measuredCost(needle: "hit")
        let empty = try measuredCost(needle: "zzz")

        #expect(dense == empty)
        #expect(dense <= 2)
    }

    @Test("the retained index agrees with the oracle across store boundary mutations")
    func retainedIndexMatchesOracleAcrossStoreMutations() throws {
        // Intent: every admitted history mutation preserves the exact ordered search result.
        // Why it exists: stable record ranges must be retired at either end and extended at the
        //   closed seam without retargeting an old coordinate or losing a boundary match.
        // Scenario: searches spanning the closed/live boundary survive output, both resize directions,
        //   a severed and restored wrap claim, ED 3, eviction, a forced split, and a needle
        //   longer than history.
        let spanningNeedle = "DAB"
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("ABCDAB".utf8))
        _ = terminal.beginSearch(spanningNeedle)

        assertSearchIndexMatchesOracle(terminal, needle: spanningNeedle)
        terminal.feed(Array("CD\r\nDAB".utf8))
        assertSearchIndexMatchesOracle(terminal, needle: spanningNeedle)
        terminal.resize(columns: 3, rows: 3)
        assertSearchIndexMatchesOracle(terminal, needle: spanningNeedle)
        terminal.resize(columns: 6, rows: 2)
        assertSearchIndexMatchesOracle(terminal, needle: spanningNeedle)
        terminal.resize(columns: 6, rows: 4)
        assertSearchIndexMatchesOracle(terminal, needle: spanningNeedle)
        terminal.resize(columns: 6, rows: 2)
        assertSearchIndexMatchesOracle(terminal, needle: spanningNeedle)

        var restoredWrap = try #require(Terminal(columns: 4, rows: 1))
        restoredWrap.feed(Array("ABCD\r\n".utf8))
        _ = restoredWrap.beginSearch("BCDE")
        restoredWrap.restoreWrapClaimBeforeCursorForTesting()
        assertSearchIndexMatchesOracle(restoredWrap, needle: "BCDE")
        restoredWrap.feed(Array("E".utf8))
        assertSearchIndexMatchesOracle(restoredWrap, needle: "BCDE")

        terminal.feed(Array("\u{1B}[3J".utf8))
        assertSearchIndexMatchesOracle(terminal, needle: spanningNeedle)

        let longNeedle = "ABCDEFGHIJK"
        var shortHistory = try #require(Terminal(columns: 4, rows: 2))
        shortHistory.feed(Array("AB".utf8))
        _ = shortHistory.beginSearch(longNeedle)
        assertSearchIndexMatchesOracle(shortHistory, needle: longNeedle)
        shortHistory.feed(Array("CDE\r\n".utf8))
        assertSearchIndexMatchesOracle(shortHistory, needle: longNeedle)

        let evictionNeedle = "it\nh"
        var evicting = try #require(Terminal(
            columns: 8,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lineCells: [3, 3, 1])
        ))
        evicting.feed(Array("hit\r\nhit\r\na".utf8))
        _ = evicting.beginSearch(evictionNeedle)
        assertSearchIndexMatchesOracle(evicting, needle: evictionNeedle)
        evicting.feed(Array("\r\nb\r\nc\r\nd".utf8))
        assertSearchIndexMatchesOracle(evicting, needle: evictionNeedle)

        let splitBudget = 1 << 12
        let splitColumns = 4
        let splitCellCap = Terminal.LogicalLineStore.forcedSplitCellCount(
            forCapacity: splitBudget
        )
        let splitBoundary = splitCellCap / splitColumns * splitColumns
        let splitNeedle = "aXYb"
        let splitContent = String(repeating: "a", count: splitBoundary - 1)
            + "XY"
            + String(repeating: "b", count: splitColumns * 3)
        var splitting = try #require(Terminal(
            columns: splitColumns,
            rows: 2,
            scrollbackBudgetBytes: splitBudget
        ))
        _ = splitting.beginSearch(splitNeedle)
        splitting.feed(Array(splitContent.utf8))

        func forcedRecordIndex() -> Int? {
            (0..<splitting.scrollbackRowCount).first {
                splitting.retainedRecordSummaryForTesting(at: $0)?.isForcedSplit == true
            }
        }

        let splitRecordIndex = try #require(forcedRecordIndex())
        #expect(splitting.retainedRecordSummaryForTesting(at: splitRecordIndex)?.cellCount == splitBoundary)
        assertSearchIndexMatchesOracle(splitting, needle: splitNeedle)

        splitting.feed(Array("\r\nq\r\nr".utf8))
        #expect(
            splitting.retainedRecordSummaryForTesting(at: splitRecordIndex + 1)?.isOpen == false
        )
        assertSearchIndexMatchesOracle(splitting, needle: splitNeedle)

        for _ in 0..<512 where forcedRecordIndex() != nil {
            splitting.feed(Array("z\r\n".utf8))
        }
        #expect(forcedRecordIndex() == nil)
        assertSearchIndexMatchesOracle(splitting, needle: splitNeedle)
    }

    @Test("a whole-store replacement leaves search agreeing with the oracle")
    func retainedIndexSurvivesWholeStoreReplacement() throws {
        // Intent: replacing retained history wholesale keeps search reporting exactly the
        //   occurrences the replacement store holds.
        // Why it exists: a replacement store mints record identities from one again, so match
        //   coordinates minted while the old store was evicting name different content in the
        //   replacement. Advancing the index over the difference keeps those coordinates; only
        //   re-deriving the index from the replacement retires them.
        // Scenario: a bounded pane evicts retained lines while a search matches in history, then
        //   the eviction oracle rebases that history onto a larger arena.
        let needle = "hit"
        var evicting = try #require(Terminal(
            columns: 8,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lines: 8, cells: 3, paneColumns: 8)
        ))
        for _ in 0..<24 {
            evicting.feed(Array("hit\r\n".utf8))
        }
        _ = evicting.beginSearch(needle)
        #expect(evicting.scrollbackRecordCount < 24)
        assertSearchIndexMatchesOracle(evicting, needle: needle)

        let replaced = evicting.withUnlimitedScrollbackForTesting()

        assertSearchIndexMatchesOracle(replaced, needle: needle)
        #expect(replaced.searchStatus == evicting.searchStatus)
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

            let materializations = Instrument.wholeProjection.measure {
                _ = terminal.searchNext()
                _ = terminal.searchPrevious()
                _ = terminal.searchStatus
            }
            #expect(materializations == 0)
            return Instrument.projectionRow.measure {
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

private func assertSearchIndexMatchesOracle(
    _ terminal: Terminal,
    needle: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let rows = 0..<terminal.scrollProjection.totalRows
    #expect(
        terminal.searchMatchRanges(in: rows)
            == independentSearchMatchRanges(in: terminal, needle: needle),
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
