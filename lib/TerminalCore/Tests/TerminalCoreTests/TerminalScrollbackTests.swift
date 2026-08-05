// Proves retained primary rows and their shared logical-text projection.
import Darwin
import Testing

@testable import TerminalCore

/// Locks scroll-off retention and full-history inspection to exact public row state.
struct TerminalScrollbackTests {
    @Test("scroll-off retains exact cells and soft-wrap identity in oldest-first order")
    func scrollbackRetention() throws {
        // Intent: prove the viewport's single scroll-off path moves whole rows
        //   into retained history without flattening their continuation state.
        // Why it exists: dropping the wrap flag or written-space cell identity
        //   makes later projection and resize reflow change logical content.
        // Scenario: a wrapped line followed by a written-space line scrolls
        //   completely above a two-row primary viewport.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("ABCDE\r\n \r\n\r\n".utf8))

        #expect(terminal.scrollbackRowCount == 3)
        let first = try #require(terminal.scrollbackRow(at: 0))
        #expect(first.isSoftWrapped)
        #expect(first.cells.map(\.kind) == [.narrow, .narrow, .narrow, .narrow])
        #expect(first.cells.map(\.scalars) == [["A"], ["B"], ["C"], ["D"]])

        let second = try #require(terminal.scrollbackRow(at: 1))
        #expect(second.isSoftWrapped == false)
        #expect(second.cells.map(\.kind) == [.narrow, .padding, .padding, .padding])
        #expect(second.cells[0].scalars == ["E"])

        let third = try #require(terminal.scrollbackRow(at: 2))
        #expect(third.isSoftWrapped == false)
        #expect(third.cells.map(\.kind) == [.narrow, .padding, .padding, .padding])
        #expect(third.cells[0].scalars == [" "])
        #expect(terminal.scrollbackRow(at: -1) == nil)
        #expect(terminal.scrollbackRow(at: 3) == nil)
    }

    @Test("a background-erase sever and spacer clear leave the vacated column painted")
    func backgroundErasePaintsTheSeveredSpacerColumn() throws {
        // Intent: when a non-default background erase severs a retained wrap claim -- or clears
        //   the spacer through EL -- the column the spacer occupied is painted in the erase
        //   colour, and under the default erase style it is painted in the default colour.
        // Why it exists: `31/PO2`. History stores logical lines and never stores a spacer, so
        //   the naive mapping loses a cell the engine really holds and paints: `31/D3`
        //   Decision 3 measured the four states against the real engine and made the repair a
        //   tail append, asymmetric on purpose -- today's canonical trimming drops a
        //   *default*-styled blank there, so storing nothing is what reproduces it.
        // Scenario: a wide glyph wraps at the right margin, its row scrolls off, and a
        //   background-erased insert or erase-in-line takes the column back.
        var painted: [TerminalColor?] = []
        for sgr in ["\u{1B}[41m", ""] {
            var terminal = try #require(Terminal(columns: 4, rows: 2))
            terminal.feed(Array("abc\u{754C}".utf8))
            terminal.feed(Array("\r\n".utf8))
            let seam = terminal.scrollbackRowCount - 1
            #expect(terminal.scrollbackRow(at: seam)?.cells[3].kind == .spacerHead)

            terminal.feed(Array("\u{1B}[H\(sgr)\u{1B}[L".utf8))

            let repaired = try #require(terminal.scrollbackRow(at: seam))
            #expect(repaired.isSoftWrapped == false)
            #expect(repaired.cells[3].kind == .padding)
            painted.append(repaired.cells[3].style.background)
            expectValidGrid(terminal)
        }
        // The whole of `31/D3` Decision 3: the erase colour survives into history, and the
        // default one is still the default rather than the erase colour left over.
        #expect(painted[0] != painted[1])
        #expect(painted[1] == TerminalStyle().background)
    }

    @Test("clearing a viewport wide cell repairs its retained spacer row")
    func crossBoundarySpacerRepair() throws {
        // Intent: preserve wide-cell atomicity when the scrollback/viewport
        //   boundary falls between a deferred spacer and its wide head.
        // Why it exists: the pre-scrollback pair cleanup only inspected the
        //   preceding viewport row, leaving an orphaned spacer in history.
        // Scenario: a right-edge wide glyph scrolls until its spacer is the
        //   newest retained row, then the visible glyph is overwritten.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.moveCursor(row: 1, column: 3)
        terminal.feed(Array("\u{754C}".utf8))
        terminal.feed([0x0A])

        let before = try #require(terminal.scrollbackRow(at: 1))
        #expect(before.cells[3].kind == .spacerHead)
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed(Array("X".utf8))

        let after = try #require(terminal.scrollbackRow(at: 1))
        #expect(after.cells[3].kind == .padding)
        #expect(terminal.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .padding, .padding, .padding,
        ])
    }

    @Test("full-history text joins soft wraps and preserves interior padding")
    func fullHistorySoftWrapProjection() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[4GA".utf8))
        terminal.feed(Array("B".utf8))

        #expect(terminal.fullHistoryText == "   AB")
    }

    @Test("full-history logical lines are identical at every terminal width")
    func fullHistoryLogicalLinesAreWidthIndependent() throws {
        // Intent: the same fed content projects to the same logical lines no
        //   matter how wide the terminal is, so soft wraps never become line
        //   boundaries.
        // Why it exists: `pane read --lines N` is one step on top of this
        //   projection -- AppRuntime takes fullHistoryText and chops the last N
        //   newline-delimited lines. If the projection ever emitted visual rows,
        //   --lines would silently return N screen rows instead of N logical
        //   lines, and its result would change when the pane is resized. The
        //   existing soft-wrap tests each pin a single width, so none of them
        //   would catch that.
        // Scenario: three logical lines, each long enough to wrap at the narrow
        //   widths and not at the wide one, read back at four widths.
        let content = "the first logical line is quite long\r\n"
            + "second\r\n"
            + "a third line that also wraps at narrow widths\r\n"
        let expected = [
            "the first logical line is quite long",
            "second",
            "a third line that also wraps at narrow widths",
        ]

        for columns in [8, 13, 20, 60] {
            var terminal = try #require(Terminal(columns: columns, rows: 4))
            terminal.feed(Array(content.utf8))

            let lines = terminal.fullHistoryText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.isEmpty }
            #expect(lines == expected, "logical lines differed at width \(columns)")
        }
    }

    @Test("full-history text omits a structural spacer before a wrapped wide cell")
    func fullHistorySpacerProjection() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("\u{1B}[4G\u{754C}".utf8))

        #expect(terminal.fullHistoryText == "   \u{754C}")
    }

    @Test("full-history text preserves every scalar in an emoji cluster")
    func fullHistoryEmojiProjection() throws {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array(family.utf8))

        #expect(terminal.fullHistoryText == family)
    }

    @Test("full-history text preserves written trailing spaces without padding or final newline")
    func fullHistoryWrittenSpaces() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("A  ".utf8))

        #expect(terminal.fullHistoryText == "A  ")
    }

    @Test("full-history text preserves empty hard lines but omits trailing blank rows")
    func fullHistoryEmptyLines() throws {
        var terminal = try #require(Terminal(columns: 3, rows: 2))
        terminal.feed([0x0A, 0x0A])
        terminal.feed(Array("A".utf8))

        #expect(terminal.scrollbackRowCount == 1)
        #expect(terminal.fullHistoryText == "\n\nA")
    }

    @Test("primary-history text matches full history while the primary screen is active")
    func primaryHistoryMatchesFullHistory() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("ABCDE\r\nFG".utf8))

        #expect(terminal.primaryHistoryText == terminal.fullHistoryText)
        #expect(terminal.primaryHistoryText == "ABCDE\nFG")
    }

    @Test("projecting history text scales with its length rather than its square")
    func primaryHistoryTextStaysLinear() throws {
        // Intent: projecting N characters of retained history costs O(N), so a history
        //   eight times longer costs about eight times as much and not sixty.
        // Why it exists: the projection walk emits one unit per *cell*, and the obvious
        //   accumulator -- `result.unicodeScalars.append(contentsOf:)` -- routes through a
        //   stdlib overload that reads `self = (String(self._guts) + other).unicodeScalars`.
        //   That `+` sees the accumulator referenced twice and copies the whole string on
        //   every cell, which is quadratic and produces an identical answer, so no
        //   correctness test can see it.
        // Scenario: quitting with one long-lived pane hung the app for ~30s -- the quit
        //   checkpoint reads `primaryHistoryText` per pane on the main thread, and a
        //   budget-full 16 MB scrollback took 38s to project.
        // Thread CPU time, not the wall clock: the regression is `memmove` this thread runs,
        // so preemption by whatever else the machine is doing is noise the measurement should
        // not carry. Against a wall clock the same two populations below overlap far more --
        // measured on a deliberately oversubscribed box, the linear arm reached 1.51x and the
        // quadratic arm fell to 2.85x, which is a gate a loaded test pool can cross in both
        // directions. On this clock they were 1.12x and 3.03x under the same load. Nothing in
        // the measured region suspends, so the work stays on the thread being charged.
        func projectionCost(lines: Int) throws -> (cpuSeconds: Double, characters: Int) {
            let terminal = try historyProjectionTerminal(lines: lines)
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let text = terminal.primaryHistoryText
            let end = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            return (Double(end - start) / 1e9, text.unicodeScalars.count)
        }

        _ = try projectionCost(lines: 200)  // warm up caches and any one-time growth
        let small = try projectionCost(lines: 400)
        let large = try projectionCost(lines: 3_200)

        // A clock that reports nothing would make the ratio below 0/0 or a division by zero
        // rather than a failure, so it has to say it measured something first.
        #expect(
            small.cpuSeconds > 0 && large.cpuSeconds > 0,
            "thread CPU clock reported no time: \(small.cpuSeconds)s, \(large.cpuSeconds)s"
        )
        // Cost per character, not total: under O(N) it is flat regardless of history length,
        // and under O(N^2) it rises with it. That ratio is what separates the two, and it
        // needs no absolute time budget, so a slower machine moves both terms together.
        let smallPerCharacter = small.cpuSeconds / Double(small.characters)
        let largePerCharacter = large.cpuSeconds / Double(large.characters)
        #expect(
            Double(large.characters) / Double(small.characters) > 7,
            "large history should dwarf the small one: \(small.characters) -> \(large.characters)"
        )
        // Measured here (debug, the configuration tests run in) over 22 idle and 12 contended
        // trials: 0.99-1.12x with the linear accumulator, against 3.03-3.22x with the quadratic
        // one restored. 2x sits between with ~1.8x of margin on the passing side and ~1.5x on
        // the failing side. The 8x history spread is what buys that separation -- the quadratic
        // ratio grows with it -- so shrink the sizes together or not at all.
        #expect(
            largePerCharacter < smallPerCharacter * 2,
            """
            per character: \(smallPerCharacter)s at \(small.characters) chars, \
            \(largePerCharacter)s at \(large.characters) chars
            """
        )
    }
}
