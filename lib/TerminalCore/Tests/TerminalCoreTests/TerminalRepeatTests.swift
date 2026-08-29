// Verifies CSI REP replays the last complete grapheme the requested number of times,
// wrapping and scrolling exactly as the same run of characters printed by hand.
import Testing

@testable import TerminalCore

/// Pins REP memory, normalization, and print-path integration.
struct TerminalRepeatTests {
    @Test("REP defaults zero to one and uses the current pen after cursor movement")
    func defaultCountMovementAndStyle() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("\u{1B}[31mA\u{0301}\u{1B}[3G\u{1B}[32m\u{1B}[b\u{1B}[0b".utf8))

        let green = TerminalStyle(foreground: .indexed(2))
        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["A", "\u{0301}"])
        #expect(terminal.cell(row: 0, column: 2)?.scalars == ["A", "\u{0301}"])
        #expect(terminal.cell(row: 0, column: 3)?.scalars == ["A", "\u{0301}"])
        #expect(terminal.cell(row: 0, column: 2)?.style == green)
        #expect(terminal.cell(row: 0, column: 3)?.style == green)
        expectValidGrid(terminal)
    }

    @Test("REP repeats its full count, wrapping and scrolling like an ordinary print run")
    func fullCountWrapsAndScrolls() throws {
        // Intent: REP repeats the requested count through the print path, so a count that
        //   outruns the row wraps onto the next one and scrolls at the bottom.
        // Why it exists: an earlier version capped the count at what fit in the current row and
        //   dropped the rest, which xterm, ghostty, foot, kitty, wezterm, iTerm2 and Windows
        //   Terminal all disagree with -- see `references/xterm/charproc.c:6152` (`case CASE_REP:`,
        //   a raw `while (count-- > 0)` around `dotext`) and ghostty's own
        //   `test "Terminal: printRepeat wrap"` (`references/ghostty/src/terminal/Terminal.zig:11394`).
        // Scenario: spec-first; the cap was written into a plan and pinned by this test's
        //   predecessor before the reference check was made.
        var narrow = try #require(Terminal(columns: 4, rows: 3))
        narrow.feed(Array("a\u{1B}[10b".utf8))

        #expect(narrow.screenText == "aaaa\naaaa\naaa ")
        #expect(narrow.geometry.rows[0].isSoftWrapped)
        #expect(narrow.geometry.cursor == TerminalCursor(row: 2, column: 3, isPendingWrap: false))

        var wide = try #require(Terminal(columns: 6, rows: 3))
        wide.feed(Array("\u{754C}\u{1B}[5b".utf8))

        #expect(wide.screenText == "\u{754C}\u{754C}\u{754C}\n\u{754C}\u{754C}\u{754C}\n      ")
        #expect(wide.geometry.rows[0].isSoftWrapped)

        var scrolled = try #require(Terminal(columns: 4, rows: 2))
        scrolled.feed(Array("a\u{1B}[10b".utf8))

        #expect(scrolled.screenText == "aaaa\naaa ")
        #expect(scrolled.geometry.cursor == TerminalCursor(row: 1, column: 3, isPendingWrap: false))

        var upgraded = try #require(Terminal(columns: 6, rows: 1))
        upgraded.feed(Array("#\u{FE0F}\u{1B}[2b".utf8))
        #expect(upgraded.geometry.rows[0].cells.map(\.kind) == [
            .wideHead, .wideTail, .wideHead, .wideTail, .wideHead, .wideTail,
        ])
        #expect(upgraded.cell(row: 0, column: 4)?.scalars == ["#", "\u{FE0F}"])
        #expect(upgraded.geometry.cursor?.isPendingWrap == true)
        expectValidGrid(narrow)
        expectValidGrid(wide)
        expectValidGrid(scrolled)
        expectValidGrid(upgraded)
    }

    @Test("REP does nothing when no cluster exists and consumes armed wrap like ordinary print")
    func inertWithoutAvailableCluster() throws {
        var fresh = try #require(Terminal(columns: 3, rows: 2))
        let freshExpected = fresh
        fresh.feed(Array("\u{1B}[b".utf8))
        #expect(fresh == freshExpected)

        var pending = try #require(Terminal(columns: 2, rows: 2))
        pending.feed(Array("AB".utf8))
        pending.feed(Array("\u{1B}[3b".utf8))
        #expect(pending.screenText == "BB\nB ")
        #expect(pending.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))

        var excessParameters = try #require(Terminal(columns: 4, rows: 1))
        excessParameters.feed(Array("A".utf8))
        let excessExpected = excessParameters
        excessParameters.feed(Array("\u{1B}[1;2b".utf8))
        #expect(excessParameters == excessExpected)
    }

    @Test("REP fills but never wraps while DECAWM is disabled")
    func autoWrapDisabled() throws {
        var narrow = try #require(Terminal(columns: 4, rows: 2))
        narrow.feed(Array("\u{1B}[?7la\u{1B}[1000b".utf8))
        #expect(narrow.screenText == "aaaa\n    ")
        #expect(narrow.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: true))

        // A wide cluster that cannot fit the last column backs onto columns 3-4 and orphans the
        // blank at column 2 -- DECAWM off, so nothing wraps. This is `print`'s rule, not REP's:
        // `\u{1B}[?7l` + four `\u{754C}` typed by hand lands in exactly this state.
        var wide = try #require(Terminal(columns: 5, rows: 2))
        wide.feed(Array("\u{1B}[?7l\u{754C}\u{1B}[1000b".utf8))
        #expect(wide.screenText == "\u{754C} \u{754C}\n     ")
        #expect(wide.geometry.cursor == TerminalCursor(row: 0, column: 4, isPendingWrap: true))

        var armedWide = try #require(Terminal(columns: 4, rows: 2))
        armedWide.feed(Array("\u{1B}[?7l\u{754C}\u{754C}\u{1B}[1000b".utf8))
        #expect(armedWide.screenText == "\u{754C}\u{754C}\n    ")
        #expect(armedWide.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: true))
        expectValidGrid(narrow)
        expectValidGrid(wide)
        expectValidGrid(armedWide)
    }

    @Test("REP honors insert mode and leaves the final repeat open for combining")
    func insertModeAndOpenCluster() throws {
        var terminal = try #require(Terminal(columns: 7, rows: 1))
        terminal.feed(Array("ABCDE\u{1B}[2G\u{1B}[4hX\u{1B}[2b\u{0301}".utf8))

        #expect(terminal.screenText == "AXXX\u{0301}BCD")
        #expect(terminal.cell(row: 0, column: 3)?.scalars == ["X", "\u{0301}"])
        expectValidGrid(terminal)
    }

    @Test("REP leaves the terminal exactly as the cluster typed that many more times")
    func matchesHandTypedRun() throws {
        // Intent: `CSI Ps b` is defined as the last cluster fed again Ps times through the print
        //   path, so the whole terminal -- grid, cursor, wrap flags, scrollback -- must land where
        //   typing those characters lands it.
        // Why it exists: REP used to cap its count at the current row's remaining columns, which
        //   is a wrap rule restated outside `print`. Asserting the equality directly means any
        //   future rule REP restates fails here, whatever shape it takes.
        // Scenario: spec-first. Each case is one that the cap used to answer differently --
        //   wrapping, scrolling off the bottom, a wide cluster, DECAWM off, and insert mode.
        let cases: [(columns: Int, rows: Int, prefix: String, cluster: String, count: Int)] = [
            (4, 3, "", "a", 10),
            (6, 3, "", "\u{754C}", 5),
            (4, 2, "", "a", 10),
            (5, 2, "\u{1B}[?7l", "\u{754C}", 6),
            (4, 2, "\u{1B}[?7l", "a", 9),
            (7, 1, "ABCDE\u{1B}[2G\u{1B}[4h", "X", 4),
            // A narrow REP is filled as runs of identical cells, so the cases below are the
            // states a run has to cut on: a count of one, a count that scrolls the screen away
            // more than once, a REP entered with the wrap already latched, a run that lands on
            // wide pairs it must split at both ends, and insert mode at the margin.
            (4, 3, "", "a", 1),
            (4, 2, "", "a", 30),
            (4, 2, "abc", "d", 5),
            (8, 2, "\u{754C}\u{754C}\u{754C}\u{754C}\u{1B}[3G", "a", 3),
            (4, 2, "\u{1B}[4h", "Z", 8),
            (5, 1, "abcd\u{1B}[1G\u{1B}[4h", "Z", 6),
            // The parameter ceiling, which a run has to fill row segment by row segment for as
            // many rows as it scrolls.
            (4, 2, "", "a", 65535),
            // A wide and a multi-scalar REP are filled as runs too, so each cluster shape meets
            // the same states: a soft wrap with DECAWM on and off, a count of one, a wrap already
            // latched, insert mode at the margin, and a run that lands on wide pairs it must
            // split at both ends. `#\u{FE0F}` is the multi-scalar cluster whose width the
            // variation selector upgraded, so a repeat of it must land as a wide pair.
            (4, 3, "", "a\u{0301}", 10),
            (6, 3, "", "#\u{FE0F}", 5),
            (6, 3, "", "#\u{FE0F}", 1),
            (5, 2, "\u{1B}[?7l", "a\u{0301}", 9),
            (5, 2, "\u{1B}[?7l", "#\u{FE0F}", 6),
            (4, 2, "\u{754C}", "\u{754C}", 3),
            (5, 2, "a\u{0301}b\u{0301}", "c\u{0301}", 7),
            (6, 2, "\u{1B}[4h", "\u{754C}", 4),
            (7, 2, "\u{1B}[4h", "a\u{0301}", 6),
            (8, 2, "\u{754C}\u{754C}\u{754C}\u{754C}\u{1B}[2G", "\u{754C}", 2),
            (8, 2, "\u{754C}\u{754C}\u{754C}\u{754C}\u{1B}[2G", "a\u{0301}", 3),
            // A repaint: the run overwrites wide pairs it lands on exactly, which is what a
            // program redrawing a line of CJK does and what the run must not refuse.
            (8, 1, "\u{754C}\u{754C}\u{754C}\u{754C}\u{1B}[1G", "\u{754C}", 3),
            (8, 1, "\u{754C}\u{754C}\u{754C}\u{754C}\u{1B}[1G", "a\u{0301}", 6),
        ]

        for testCase in cases {
            var repeated = try #require(Terminal(columns: testCase.columns, rows: testCase.rows))
            repeated.feed(Array(
                (testCase.prefix + testCase.cluster + "\u{1B}[\(testCase.count)b").utf8))

            var handTyped = try #require(Terminal(columns: testCase.columns, rows: testCase.rows))
            handTyped.feed(Array(
                (testCase.prefix
                    + String(repeating: testCase.cluster, count: testCase.count + 1)).utf8))

            #expect(repeated == handTyped, "\(testCase)")
            expectValidGrid(repeated)
        }
    }

    @Test("REP repeats a multi-scalar cluster after its source cell is gone")
    func survivesLossOfSourceCell() throws {
        // Intent: REP's memory is a cluster the terminal owns, so it repeats the whole cluster
        //   however the cell it was printed into is later disposed of.
        // Why it exists: the memory used to be a reference into the row's own payload storage.
        //   These three cases are the ones a reference cannot survive -- the cell erased, the
        //   row's payload storage rebuilt under it, and the row itself recycled as a blank.
        // Scenario: spec-first, written to pin REP before `research/39/H2` moved the payload storage.
        let cluster: [Unicode.Scalar] = ["a", "\u{0301}"]

        var erased = try #require(Terminal(columns: 8, rows: 1))
        erased.feed(Array("a\u{0301}\u{1B}[1G\u{1B}[1X\u{1B}[5G\u{1B}[b".utf8))
        #expect(erased.cell(row: 0, column: 4)?.scalars.elementsEqual(cluster) == true)

        // 40 rewrites of one cell outruns the row's 32-payload compaction threshold, so the
        // payload REP was told about has been moved at least once by the time REP runs.
        var compacted = try #require(Terminal(columns: 8, rows: 1))
        for _ in 0..<40 {
            compacted.feed(Array("\u{1B}[1Ga\u{0301}".utf8))
        }
        compacted.feed(Array("\u{1B}[5G\u{1B}[b".utf8))
        #expect(compacted.cell(row: 0, column: 0)?.scalars.elementsEqual(cluster) == true)
        #expect(compacted.cell(row: 0, column: 4)?.scalars.elementsEqual(cluster) == true)

        var recycled = try #require(Terminal(columns: 8, rows: 2))
        recycled.feed(Array("a\u{0301}\r\n\r\n\r\n\u{1B}[b".utf8))
        #expect(recycled.cell(row: 1, column: 0)?.scalars.elementsEqual(cluster) == true)

        expectValidGrid(erased)
        expectValidGrid(compacted)
        expectValidGrid(recycled)
    }

    @Test("a repeated narrow cell never joins the cell before the REP")
    func repeatedNarrowCellsStaySeparate() throws {
        // Intent: every repeat starts a fresh grapheme cluster, so a REP whose cursor sits right
        //   after a Prepend cell stamps its own cell instead of extending that cluster.
        // Why it exists: the run path asks the grid for look-behind before it decides it can fill
        //   cells in bulk. If a declined run left that recovered context in place, the single cell
        //   printed in its stead would join the Prepend -- which REP never does today.
        // Scenario: spec-first, from `research/39`'s bulk-REP risk AR2.
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("\u{0D4E}\u{1B}[5Ga\u{1B}[2G\u{1B}[3b".utf8))

        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["\u{0D4E}"])
        #expect(terminal.cell(row: 0, column: 1)?.scalars == ["a"])
        #expect(terminal.cell(row: 0, column: 2)?.scalars == ["a"])
        #expect(terminal.cell(row: 0, column: 3)?.scalars == ["a"])
        expectValidGrid(terminal)
    }

    @Test("REP leaves the repeat memory and the open cluster where a typed run leaves them")
    func repeatPreservesMemoryAndOpenCluster() throws {
        // Intent: what a REP stamps is still the last printed cluster, so a second REP repeats it
        //   again from the new cursor and a mark fed after a REP decorates the last repeat only.
        // Why it exists: filling a REP as a run rewrites the cluster memory from the cells it
        //   stamped rather than from one print per repeat, so both must survive the run.
        // Scenario: spec-first.
        var chained = try #require(Terminal(columns: 8, rows: 1))
        chained.feed(Array("a\u{1B}[3b\u{1B}[2b".utf8))
        var typed = try #require(Terminal(columns: 8, rows: 1))
        typed.feed(Array("aaaaaa".utf8))
        #expect(chained == typed)

        var marked = try #require(Terminal(columns: 8, rows: 1))
        marked.feed(Array("a\u{1B}[3b\u{0301}".utf8))
        #expect(marked.cell(row: 0, column: 2)?.scalars == ["a"])
        #expect(marked.cell(row: 0, column: 3)?.scalars == ["a", "\u{0301}"])
        expectValidGrid(marked)
    }

    @Test("a repeated cluster never joins its neighbours, whatever it segments as")
    func repeatedClustersStaySeparate() throws {
        // Intent: every repeat is its own grapheme cluster, so the three classes the narrow
        //   scalar run refuses -- a regional indicator, which joins the one before it; a Prepend
        //   character, which joins whatever follows it; and an extended pictograph, which the
        //   emoji properties bar -- still land as `count` separate cells, and a mark fed after
        //   the REP decorates only the last of them.
        // Why it exists: a wide or multi-scalar REP now stamps whole cells instead of replaying
        //   the memory's scalars through the segmenter. Stamping is what makes the repeats
        //   independent, and it is also what would hide a joining rule if the run ever took a
        //   cluster the segmenter would have merged.
        // Scenario: spec-first, from `research/39`'s bulk-REP risks AR1 and AR2.
        let cases: [(name: String, cluster: String, width: Int)] = [
            ("regional indicator", "\u{1F1E6}", 2),
            ("extended pictograph", "\u{1F600}", 2),
            ("prepend", "\u{0D4E}", 1),
        ]

        for testCase in cases {
            var terminal = try #require(Terminal(columns: 12, rows: 1))
            terminal.feed(Array((testCase.cluster + "\u{1B}[3b\u{0301}").utf8))

            for repeatIndex in 0..<3 {
                #expect(
                    terminal.cell(row: 0, column: repeatIndex * testCase.width)?.scalars
                        == TerminalScalars(Array(testCase.cluster.unicodeScalars)),
                    "\(testCase.name) repeat \(repeatIndex)"
                )
            }
            #expect(
                terminal.cell(row: 0, column: 3 * testCase.width)?.scalars
                    == TerminalScalars(Array(testCase.cluster.unicodeScalars) + ["\u{0301}"]),
                "\(testCase.name) mark"
            )
            expectValidGrid(terminal)
        }
    }

    @Test("a REP retires the link state anchored in the rows it fills, as a typed run does")
    func retiresInspectionStateLikeTypedRun() throws {
        // Intent: filling a REP as one run per row segment still retires the content-derived
        //   inspection state anchored in the cells it overwrites.
        // Why it exists: the run invalidates inspection once per segment instead of once per
        //   cell, so an arm over a cell in the middle of a segment is exactly what a
        //   per-cell invalidation would catch and a mis-scoped range would strand.
        // Scenario: the user holds Cmd on a URL while the program repaints that line with REP.
        for cluster in ["a", "\u{754C}", "a\u{0301}"] {
            var terminal = try #require(Terminal(columns: 16, rows: 2))
            terminal.feed(Array("\r\nhttps://a.co".utf8))
            let link = try #require(terminal.activatableLink(at: .init(row: 1, column: 3)))
            let armed = terminal.setArmedLink(link)
            #expect(armed)

            terminal.feed(Array(("\u{1B}[2;1H" + cluster + "\u{1B}[6b").utf8))
            #expect(terminal.armedLink == nil, "\(cluster)")
        }
    }

    @Test("a multi-scalar REP fills a row from one arena and reads back through every reader")
    func multiScalarRunAllocatesOncePerRow() throws {
        // Intent: repeating a multi-scalar cluster across a whole row stores the cluster in each
        //   cell it fills, readable through the cell accessor and through the synchronization
        //   encoder, while the row keeps the single scalar arena `research/39/D6` bounds it to.
        // Why it exists: the run interns one cluster per stamped cell. An arena that grew per
        //   cell instead of per row would still read back correctly and would only show up here.
        // Scenario: spec-first, from `research/39`'s I6.
        let cluster: [Unicode.Scalar] = ["a", "\u{0301}"]
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("a\u{0301}\u{1B}[7b".utf8))

        for column in 0..<8 {
            #expect(
                terminal.cell(row: 0, column: column)?.scalars.elementsEqual(cluster) == true,
                "column \(column)"
            )
        }
        #expect(terminal.memoryCensus.multiScalarAllocationCount == 1)

        let synchronization = terminal.stateSynchronization
        var replica = try #require(Terminal(
            columns: synchronization.columns,
            rows: synchronization.rows
        ))
        replica.feed(synchronization.bytes)
        for column in 0..<8 {
            #expect(
                replica.cell(row: 0, column: column)?.scalars.elementsEqual(cluster) == true,
                "replica column \(column)"
            )
        }
        expectValidGrid(terminal)
    }

    @Test("last-cluster memory participates in terminal equality")
    func memoryAffectsEquality() throws {
        // Intent: `lastPrintedCluster` is a stored property of `Terminal`, so two terminals that
        //   differ only in the cluster they last printed must compare unequal.
        // Why it exists: `Terminal` relies on synthesized `Equatable` over every stored property,
        //   so the two operands have to be built to leave the cluster memory as the *only*
        //   difference. An earlier version compared a printed terminal against a cursor-moved one,
        //   which also differed in `nextContentIdentity` and `damage` -- it stayed green even with
        //   `lastPrintedCluster` deleted from the type outright.
        // Scenario: REP and combining-mark handling read this memory, so equality has to see it.
        var remembered = try #require(Terminal(columns: 3, rows: 1))
        remembered.feed(Array("A\u{1B}[2J".utf8))
        var plain = try #require(Terminal(columns: 3, rows: 1))
        plain.feed(Array("B\u{1B}[2J".utf8))

        // Both fed one narrow cell then ED 2, so grids, cursors, damage and the content-identity
        // counter all match; only the remembered cluster ("A" vs "B") differs.
        #expect(remembered != plain)
    }

    @Test("REP repeats the cell the printer's own cluster grew into")
    func memoryFollowsTheClusterThePrinterOpened() throws {
        // Intent: however a cell the printer opened grows -- one scalar, a wide scalar, several
        //   marks, or a mark that widens it -- REP repeats what that cell now holds.
        // Why it exists: the printer keeps the memory as a mirror of what it places instead of
        //   reading the cell back after every scalar (`research/39/D8`), so a scalar the mirror
        //   missed, or a width it failed to follow, would show up only through REP.
        // Scenario: spec-first, from `research/39`'s I5.
        let cases: [(name: String, input: String, width: Int)] = [
            ("fresh narrow cell", "a", 1),
            ("fresh wide cell", "\u{754C}", 2),
            ("two marks", "a\u{0301}\u{0302}", 1),
            ("width upgrade", "#\u{FE0F}", 2),
            ("width downgrade", "\u{2764}\u{FE0F}\u{FE0E}", 1),
        ]

        for testCase in cases {
            var terminal = try #require(Terminal(columns: 12, rows: 1))
            terminal.feed(Array((testCase.input + "\u{1B}[b").utf8))

            let source = try #require(terminal.cell(row: 0, column: 0), "\(testCase.name)")
            let repeated = try #require(
                terminal.cell(row: 0, column: testCase.width),
                "\(testCase.name)"
            )
            #expect(repeated.scalars == source.scalars, "\(testCase.name)")
            #expect(repeated.kind == source.kind, "\(testCase.name)")
            expectValidGrid(terminal)
        }

        // The upgrade that runs out of room carries the cluster onto the next row, so the memory
        // has to follow the cell rather than the position it was opened at.
        var wrapped = try #require(Terminal(columns: 4, rows: 2))
        wrapped.feed(Array("abc#\u{FE0F}\u{1B}[b".utf8))
        let carried = try #require(wrapped.cell(row: 1, column: 0))
        #expect(carried.scalars == ["#", "\u{FE0F}"])
        #expect(wrapped.cell(row: 1, column: 2)?.scalars == carried.scalars)
        #expect(wrapped.cell(row: 1, column: 2)?.kind == .wideHead)
        expectValidGrid(wrapped)
    }

    @Test("a scalar joining a cluster the printer did not open remembers that cell, not the memory")
    func memoryIsRebuiltForAnAdoptedCluster() throws {
        // Intent: when the join path accepts a scalar for a cluster context the printer did not
        //   open -- recovered from the grid, or restored by the synchronization stream, which can
        //   restore a memory and a context naming different cells -- REP still repeats the cell
        //   the context targets, whether the scalar was appended or refused.
        // Why it exists: the printer mirrors the memory from what it places, which is only valid
        //   for a context it opened itself. Extending an inherited memory instead of reading the
        //   target cell would repeat a cluster no cell ever held (`research/39`'s AR3).
        // Scenario: spec-first, from `research/39`'s I5 and AR3.
        // "Z" as the memory the terminal inherits, which no cell on screen holds.
        let inheritedMemory = "\u{1B}]133;S;repeat=none\u{7}\u{1B}]133;S;repeat-add=1:5a\u{7}"

        // Recovered from the grid: the memory names the "Z" printed after the cluster.
        var recovered = try #require(Terminal(columns: 12, rows: 1))
        recovered.feed(Array("a\u{0301}\u{1B}[5GZ\u{1B}[2G\u{0302}\u{1B}[b".utf8))
        #expect(recovered.cell(row: 0, column: 0)?.scalars == ["a", "\u{0301}", "\u{0302}"])
        #expect(recovered.cell(row: 0, column: 1)?.scalars == ["a", "\u{0301}", "\u{0302}"])
        expectValidGrid(recovered)

        // Restored by the synchronization stream, and appended to.
        var appended = try #require(Terminal(columns: 12, rows: 1))
        appended.feed(Array(("a\u{0301}" + inheritedMemory + "\u{0302}\u{1B}[b").utf8))
        #expect(appended.cell(row: 0, column: 0)?.scalars == ["a", "\u{0301}", "\u{0302}"])
        #expect(appended.cell(row: 0, column: 1)?.scalars == ["a", "\u{0301}", "\u{0302}"])
        expectValidGrid(appended)

        // Restored, then refused by the retained-cluster byte limit: the cell does not change,
        // and the memory still has to name it rather than the inherited "Z".
        let mark = "\u{0301}"
        let retained = "A" + String(
            repeating: mark,
            count: (Terminal.graphemeClusterByteLimit - 1) / mark.utf8.count
        )
        var refusedByLimit = try #require(Terminal(columns: 12, rows: 1))
        refusedByLimit.feed(Array((retained + inheritedMemory + mark + "\u{1B}[b").utf8))
        #expect(refusedByLimit.cell(row: 0, column: 0)?.scalars
            == TerminalScalars(retained.unicodeScalars))
        #expect(refusedByLimit.cell(row: 0, column: 1)?.scalars
            == TerminalScalars(retained.unicodeScalars))
        expectValidGrid(refusedByLimit)

        // Restored onto a cell the cursor does not sit beside, so the emoji joins by ZWJ but the
        // width change it asks for is refused: again the cell does not change, and the memory
        // has to name it.
        var source = try #require(Terminal(columns: 12, rows: 2))
        source.feed(Array("\u{2764}\u{200D}".utf8))
        let restoreContext = try #require(clusterSynchronizationChunk(of: source))
        var refusedByWidth = try #require(Terminal(columns: 12, rows: 2))
        refusedByWidth.feed(Array(("\u{2764}\u{200D}\u{1B}[2;1H" + inheritedMemory).utf8))
        refusedByWidth.feed(restoreContext)
        refusedByWidth.feed(Array("\u{1F600}\u{1B}[b".utf8))
        #expect(refusedByWidth.cell(row: 0, column: 0)?.scalars == ["\u{2764}", "\u{200D}"])
        #expect(refusedByWidth.cell(row: 1, column: 0)?.scalars == ["\u{2764}", "\u{200D}"])
        expectValidGrid(refusedByWidth)
    }

    /// Isolates the `cluster=` chunk of a synchronization stream so a test can restore a cluster
    /// context on its own, onto a cursor the context does not sit beside.
    private func clusterSynchronizationChunk(of terminal: Terminal) -> [UInt8]? {
        let text = String(decoding: terminal.stateSynchronization.bytes, as: UTF8.self)
        guard let start = text.range(of: "\u{1B}]133;S;cluster="),
              let end = text[start.upperBound...].firstIndex(of: "\u{7}")
        else { return nil }
        return Array(text[start.lowerBound...end].utf8)
    }
}
