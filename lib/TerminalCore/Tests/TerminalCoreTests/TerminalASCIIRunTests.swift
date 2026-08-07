// Behavioral pins for the bulk printable-ASCII run print path.
//
// The engine prints a maximal run of printable ASCII with one pass of the bookkeeping the
// per-character path pays per character (`research/33/T8`). That is sound only because a
// printable ASCII scalar is narrow and grapheme-break-`.other` by construction from the
// generated table, and only where the run's cut rules hold: row end, insert mode, an open
// cluster the run's head would join, a wide-or-spacer cell about to be overwritten, and the
// content-identity wrap.
//
// Every test here must pass both before and after the bulk path exists. They were written
// against the per-character engine on purpose: a test that only passed afterwards would be
// pinning the new implementation's behavior rather than the behavior it had to preserve.
//
// What does *not* belong here: proofs about how much bookkeeping collapsed. That is a count,
// not a behavior, and `scripts/research/33/t8-bulk-ascii-runs.py` is what measures it.
import Testing

@testable import TerminalCore

/// Holds the by-construction premise and every boundary at which a bulk ASCII run must stop.
struct TerminalASCIIRunTests {
    /// Chunkings the equivalence sweep replays each scenario at. 1 forces every run to a single
    /// character, which is the per-character path; the whole-input feed maximizes run length. Any
    /// disagreement between them is a bulk path that does not mean what the character path means.
    private static let chunkSizes = [1, 2, 3, 5, 7, 11, 64]

    @Test("every printable ASCII scalar is narrow and breaks as .other")
    func printableASCIIIsNarrowAndBreaksOther() {
        // Intent: the generated Unicode table classifies all of 0x20...0x7E as one cell wide with
        //   grapheme-break class `.other`.
        // Why it exists: this is the premise the bulk run path rests on -- it never calls
        //   `terminalUnicodeClassification`, so if the table ever disagreed the engine would print
        //   a wide or cluster-joining scalar as a plain narrow cell with nothing else to catch it.
        for value in 0x20...0x7E {
            let scalar = Unicode.Scalar(UInt8(value))
            let classification = terminalUnicodeClassification(for: scalar)
            #expect(
                classification.properties.cellWidth == .narrow,
                "U+\(String(value, radix: 16, uppercase: true)) is not narrow"
            )
            #expect(
                classification.graphemeBreakClass == .other,
                "U+\(String(value, radix: 16, uppercase: true)) does not break as .other"
            )
            #expect(classification.properties.isEmojiModifier == false)
        }
    }

    @Test(
        "a run means the same thing at every chunking",
        arguments: TerminalASCIIRunTests.equivalenceScenarios
    )
    func runsAreChunkInvariant(scenario: Scenario) throws {
        // Intent: replaying one byte stream at seven chunkings produces byte-identical terminals.
        // Why it exists: feeding one byte at a time makes every run a single character, so this
        //   compares the bulk path against the character path over each of `T8`'s cut rules --
        //   the wide-cell overwrite, the right margin in both `DECAWM` states, insert mode, an
        //   open prepend cluster, and the wrap spacer in the first two columns.
        // Scenario: the byte stream in `scenario`, fed at 1, 2, 3, 5, 7, 11 and 64 bytes a time.
        let reference = try replay(scenario, chunkSize: 1)
        expectValidGrid(reference, context: "\(scenario.name) at chunk 1")

        for chunkSize in Self.chunkSizes.dropFirst() {
            let replayed = try replay(scenario, chunkSize: chunkSize)
            #expect(
                replayed == reference,
                "\(scenario.name) diverged at chunk \(chunkSize): \(diagnosis(replayed, reference))"
            )
        }
    }

    @Test("a run stops at the right margin and latches pending wrap under DECAWM")
    func runStopsAtRightMarginWithAutoWrap() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("abcdefghij".utf8))

        #expect(terminal.screenText.hasPrefix("abcdef\nghij"))
        #expect(terminal.geometry.rows[0].isSoftWrapped)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 1, column: 4, isPendingWrap: false))
        expectValidGrid(terminal)

        var latched = try #require(Terminal(columns: 6, rows: 3))
        latched.feed(Array("abcdef".utf8))
        #expect(latched.geometry.cursor == TerminalCursor(row: 0, column: 5, isPendingWrap: true))
    }

    @Test("with DECAWM off a run piles up in the last column")
    func runOverwritesLastColumnWithoutAutoWrap() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("\u{1B}[?7labcdefghij".utf8))

        // Every character past the sixth overwrites column 5, so the last one wins and no row
        // is soft-wrapped.
        #expect(terminal.screenText.hasPrefix("abcdej"))
        #expect(terminal.geometry.rows[0].isSoftWrapped == false)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 5, isPendingWrap: false))
        expectValidGrid(terminal)
    }

    @Test("a run overwriting a wide cell clears its partner")
    func runOverwritingWideCellClearsPartner() throws {
        // Intent: a run that lands on a wide head, and one that lands on a wide tail, blank the
        //   other half of the pair rather than leaving an orphan.
        // Why it exists: the bulk write replaces cells directly, so it must refuse any cell whose
        //   overwrite has to touch a neighbour. An orphaned tail renders as a stray blank the
        //   grid validator catches, and an orphaned head renders the wrong glyph width.
        var onHead = try #require(Terminal(columns: 8, rows: 2))
        onHead.feed(Array("ab\u{754C}cd".utf8))
        onHead.moveCursor(row: 0, column: 2)
        onHead.feed(Array("XY".utf8))

        #expect(onHead.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .narrow, .narrow, .narrow, .narrow, .narrow, .padding, .padding,
        ])
        #expect(onHead.screenText.hasPrefix("abXYcd"))
        expectValidGrid(onHead)

        var onTail = try #require(Terminal(columns: 8, rows: 2))
        onTail.feed(Array("ab\u{754C}cd".utf8))
        onTail.moveCursor(row: 0, column: 3)
        onTail.feed(Array("XY".utf8))

        // Clearing the tail clears the head with it, so column 2 comes back blank.
        #expect(onTail.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .narrow, .padding, .narrow, .narrow, .narrow, .padding, .padding,
        ])
        expectValidGrid(onTail)
    }

    @Test("a run in the first columns clears the previous row's wrap spacer")
    func runClearsPrecedingWrapSpacer() throws {
        // Intent: printing over columns 0 and 1 of a row whose predecessor ends in a wrap spacer
        //   retires that spacer and the soft wrap it stands for.
        // Why it exists: the bulk path calls the spacer repair once for the whole run where the
        //   character path calls it per cell. Once is enough only because the repair is
        //   idempotent, and this is what says so in behavior rather than by reading it.
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.moveCursor(row: 0, column: 3)
        terminal.feed(Array("\u{754C}".utf8))

        #expect(terminal.geometry.rows[0].cells[3].kind == .spacerHead)
        #expect(terminal.geometry.rows[0].isSoftWrapped)

        terminal.moveCursor(row: 1, column: 0)
        terminal.feed(Array("xy".utf8))

        #expect(terminal.geometry.rows[0].cells[3].kind == .padding)
        expectValidGrid(terminal)
    }

    @Test("Prepend is the only class an ASCII scalar does not break from")
    func onlyPrependJoinsAnASCIIScalar() {
        // Intent: for every grapheme-break class and every look-behind state, a following
        //   `.other` scalar starts a new cluster -- except after Prepend, where GB9b joins it.
        // Why it exists: the bulk run path decides in one comparison whether its first character
        //   could join the open cluster, and that comparison is only sound if Prepend is the
        //   complete list. Enumerating the rule is what makes it a proof rather than a reading
        //   of `GraphemeBreak.swift`.
        let states: [GraphemeBreakState] = [
            .initial, .regionalIndicator, .extendedPictographic,
            .indicConjunctBreakConsonant, .indicConjunctBreakLinker,
        ]
        let classes: [GraphemeBreakClass] = [
            .other, .control, .prepend, .cr, .lf, .regionalIndicator, .spacingMark,
            .l, .v, .t, .lv, .lvt, .zwj, .zwnj, .extendedPictographic,
            .indicConjunctBreakExtend, .indicConjunctBreakLinker, .indicConjunctBreakConsonant,
        ]
        for previous in classes {
            for initial in states {
                var state = initial
                let breaks = graphemeBreak(between: previous, and: .other, state: &state)
                #expect(
                    breaks == (previous != .prepend),
                    "\(previous) before .other from \(initial) broke \(breaks)"
                )
            }
        }
    }

    @Test("an ASCII scalar still joins an open prepend cluster")
    func asciiJoinsOpenPrependCluster() throws {
        // Intent: a printable ASCII scalar printed straight after a Prepend scalar that occupies a
        //   cell extends that cluster instead of taking a cell of its own, and the character after
        //   it breaks away normally.
        // Why it exists: GB9b is the one rule under which an `.other` scalar does not break, so it
        //   is the single case where a run's first character must fall back to the character path.
        //   Nothing else in the suite prints ASCII onto an open prepend. U+0D4E is used because
        //   most Prepend scalars are zero width and so never open a cluster at all.
        let prepend = "\u{0D4E}"
        let classification = terminalUnicodeClassification(for: "\u{0D4E}")
        #expect(classification.graphemeBreakClass == .prepend)
        #expect(classification.properties.cellWidth != .zero)

        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array((prepend + "ab").utf8))

        #expect(terminal.cell(row: 0, column: 0)?.scalars == ["\u{0D4E}", "a"])
        #expect(terminal.screenText.hasPrefix("\u{0D4E}a"))
        expectValidGrid(terminal)
    }

    @Test("insert mode still shifts the row once per character")
    func insertModeShiftsPerCharacter() throws {
        // Intent: under IRM each character of a run pushes the row right by one, so the run
        //   arrives reversed relative to what a bulk overwrite would produce.
        // Why it exists: insert mode is the cut rule with no visible marker on the cells it
        //   touches. A bulk path that ignored it would write the run in place and read as
        //   correct on every other assertion in this file.
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("zz".utf8))
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed(Array("\u{1B}[4habc".utf8))

        #expect(terminal.screenText.hasPrefix("abczz"))
        expectValidGrid(terminal)
    }

    @Test("a run issues one contiguous content-identity range")
    func runIssuesContiguousIdentities() throws {
        // Intent: a row printed as one run reports a single contiguous identity run with every
        //   cell identified.
        // Why it exists: the packed retained row encodes an identity run as a base plus the
        //   column offset, so the bulk path has to allocate consecutive identities rather than
        //   one identity repeated across the run. A repeated identity would still round-trip
        //   through the live grid and only show up as retained-row corruption.
        var terminal = try #require(Terminal(columns: 20, rows: 1))
        terminal.feed(Array("abcdefghij\r\n".utf8))

        let shape = try #require(terminal.scrollbackRecordContentIdentityShape(at: 0))

        #expect(shape.runCount == 1)
        #expect(shape.identifiedCellCount == 10)
        #expect(shape.unidentifiedCellCount == 0)
    }

    // MARK: - Equivalence sweep

    /// One named byte stream the chunk sweep replays. A struct rather than a tuple so a failing
    /// parameterized case names the cut rule it was covering.
    struct Scenario: Sendable, CustomStringConvertible {
        let name: String
        let columns: Int
        let rows: Int
        let input: String

        var description: String { name }
    }

    static let equivalenceScenarios: [Scenario] = [
        Scenario(
            name: "plain text wrapping the right margin",
            columns: 7, rows: 4,
            input: "the quick brown fox jumps over it\r\n"
        ),
        Scenario(
            name: "right margin with DECAWM off",
            columns: 7, rows: 4,
            input: "\u{1B}[?7lthe quick brown fox\r\nsecond line here\r\n"
        ),
        Scenario(
            name: "right margin toggling DECAWM mid-line",
            columns: 7, rows: 4,
            input: "abcd\u{1B}[?7lefgh\u{1B}[?7hijkl\r\n"
        ),
        Scenario(
            name: "runs overwriting wide cells",
            columns: 9, rows: 3,
            input: "ab\u{754C}cd\u{754C}\r\n\u{1B}[HXYZWVUT\u{1B}[2;1HQRS"
        ),
        Scenario(
            name: "wide cell wrapping into a spacer then overwritten",
            columns: 5, rows: 3,
            input: "abcd\u{754C}efg\u{1B}[1;1Hxy\u{1B}[2;1Hzw"
        ),
        Scenario(
            name: "insert mode interleaved with overwrite",
            columns: 10, rows: 3,
            input: "abcdef\u{1B}[1;3H\u{1B}[4hXYZ\u{1B}[4lPQR\r\n"
        ),
        Scenario(
            name: "prepend clusters interrupting runs",
            columns: 8, rows: 3,
            input: "ab\u{0D4E}cd\u{0D4E}\u{0D4E}ef\r\n"
        ),
        Scenario(
            name: "combining marks interrupting runs",
            columns: 8, rows: 3,
            input: "abc\u{0301}de\u{0301}\u{0301}fg\r\n"
        ),
        Scenario(
            name: "runs scrolling off the bottom of the screen",
            columns: 6, rows: 3,
            input: "alpha\r\nbravo\r\ncharlie\r\ndelta\r\necho and more\r\n"
        ),
        Scenario(
            name: "styled runs with hyperlinks",
            columns: 12, rows: 3,
            input: "\u{1B}]8;;https://example.com\u{07}link text\u{1B}]8;;\u{07}"
                + " \u{1B}[31mred text\u{1B}[0m plain\r\n"
        ),
        Scenario(
            name: "runs under a scroll region",
            columns: 8, rows: 5,
            input: "\u{1B}[2;4rheader\r\none\r\ntwo\r\nthree\r\nfour\r\nfive\r\n"
        ),
        Scenario(
            name: "runs on the alternate screen",
            columns: 8, rows: 3,
            input: "\u{1B}[?1049hpainted text here\u{1B}[1;1Hover\u{1B}[?1049lafter"
        ),
        Scenario(
            name: "tabs and backspaces splitting runs",
            columns: 16, rows: 3,
            input: "ab\tcd\u{08}\u{08}ef\tg\r\nhij\tk\r\n"
        ),
    ]

    private func replay(_ scenario: Scenario, chunkSize: Int) throws -> Terminal {
        var terminal = try #require(Terminal(columns: scenario.columns, rows: scenario.rows))
        let bytes = Array(scenario.input.utf8)
        var index = 0
        while index < bytes.count {
            let end = min(index + chunkSize, bytes.count)
            terminal.feed(Array(bytes[index..<end]))
            index = end
        }
        return terminal
    }

    /// Names the first visible difference so a failure reads as a divergence rather than as
    /// "two opaque terminals are unequal".
    private func diagnosis(_ replayed: Terminal, _ reference: Terminal) -> String {
        if replayed.screenText != reference.screenText {
            return "screen text \(replayed.screenText.debugDescription) "
                + "vs \(reference.screenText.debugDescription)"
        }
        if replayed.geometry.cursor != reference.geometry.cursor {
            return "cursor \(replayed.geometry.cursor) vs \(reference.geometry.cursor)"
        }
        if replayed.geometry.rows.map(\.cells) != reference.geometry.rows.map(\.cells) {
            return "viewport cells differ at equal screen text"
        }
        if replayed.scrollbackRowCount != reference.scrollbackRowCount {
            return "scrollback rows \(replayed.scrollbackRowCount) vs \(reference.scrollbackRowCount)"
        }
        return "state outside the viewport differs"
    }
}
