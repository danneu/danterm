// Terminal-semantics cases adapted from Alacritty's inline `#[test]` functions: viewport
// survival across an in-place screen erase, and literal search over wide graphemes. Separate
// from TerminalViewportTests and TerminalSearchTests -- which pin behavior DanTerm chose --
// because everything here is tracked against an external suite: each test names the upstream
// test it follows and records a body hash, and `scripts/alacritty-parity-lint.py` fails when
// that upstream test is renamed, revised, or left behind by a pin bump. Adapted cases belong
// here so the citation block is the file's rule rather than a stray convention;
// DanTerm-originated coverage for the same subsystems stays in its own suites.
//
// We adopt Alacritty's scenarios, never its verdicts. Alacritty asserts through APIs and
// policies DanTerm does not share (`Grid::display_offset`, inclusive regex `Point` ranges,
// per-cell occupancy `Flags`), so every citation carries a `Divergence:` line saying what we
// assert instead. Which upstream names are ported, and why the other 132 are not, is the
// ledger in Fixtures/alacritty-inline-manifest.json.
import Testing

@testable import TerminalCore

/// Tracks a slice of `alacritty_terminal/src` unit tests as DanTerm behavior, so upstream
/// revisions surface as a lint failure instead of silent compatibility drift.
struct TerminalAlacrittyAdaptedTests {
    @Test("erasing the whole screen leaves a browsing viewport anchored where it was")
    func eraseDisplayPreservesBrowsingAnchor() throws {
        // Intent: ED 2 rewrites the live screen in place, so a viewport parked on retained
        //   history keeps its anchor and its non-following state, and the rows it shows change
        //   only where they overlap the erased screen.
        // Why it exists: DanTerm classifies some screen changes as replacements that reset
        //   browsing to following -- `screenReplacementClassification` pins alternate-screen
        //   entry and RIS as such. ED 2 resembles one and is not: it never evicts, never
        //   scrolls, and never changes the retained row count. Erase tests prove the grid
        //   mutation and viewport tests prove anchor stability under output, reflow, and ED 3
        //   eviction; their intersection is where a future "erasing the screen is a
        //   replacement" simplification would silently snap a browsing user to the bottom.
        // Scenario: a user scrolls back to read earlier output while a program runs, and the
        //   program clears the screen.
        //
        // Adapted from alacritty_terminal/src/term/mod.rs#clearing_viewport_keeps_history_position
        //   (alacritty 852e971c, body sha256:4db9394481da).
        //   Divergence: Alacritty asserts `grid.display_offset()` is unchanged -- a distance
        //   from the live bottom, which a shifted history would preserve while showing
        //   different rows. DanTerm has no display offset, so we assert the whole public
        //   `scrollProjection` (anchor, total rows, and `isFollowing == false`) plus the
        //   projected window text, and additionally assert that the erase really happened,
        //   which upstream's single assertion does not.
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("a\r\nb\r\nc\r\nd\r\ne".utf8))
        terminal.scroll(toTopRow: 0)

        let projectionBeforeErase = terminal.scrollProjection
        #expect(projectionBeforeErase == TerminalScrollProjection(
            totalRows: 5,
            topRow: 0,
            windowRows: 3,
            isFollowing: false
        ))
        #expect(terminal.screenText == "a   \nb   \nc   ")

        terminal.feed(Array("\u{1B}[2J".utf8))

        // The anchor and the retained rows are untouched; only the window's third row, which
        // is the live screen's first, was erased under the browsing user.
        #expect(terminal.scrollProjection == projectionBeforeErase)
        #expect(terminal.screenText == "a   \nb   \n    ")
        #expect(terminal.scrollbackRowCount == 2)
        #expect(terminal.fullHistoryText == "a\nb")

        terminal.scrollToBottom()
        #expect(terminal.scrollProjection.isFollowing)
        #expect(terminal.screenText == "    \n    \n    ")
        expectValidGrid(terminal)
    }

    @Test("a literal wide-grapheme match reports the range that covers both of its columns")
    func wideGraphemeSearchRangeCoversBothColumns() throws {
        // Intent: searching for a double-width grapheme reports a half-open range whose width
        //   is the grapheme's display width, so a highlight drawn from it covers the whole
        //   glyph rather than half of it.
        // Why it exists: search ranges are projection coordinates, and the projection
        //   collapses a wide cell and its spacer into one grapheme. Whether that grapheme
        //   spans one column or two in a match range is a choice nothing currently pins:
        //   selection tests prove wide atomicity for selection and search tests prove narrow
        //   ranges, but no search test measures a wide match. Off by one here paints half a
        //   glyph, or bleeds one column into the neighbour.
        // Scenario: a user searches a pane of Chinese output for a single character.
        //
        // Adapted from alacritty_terminal/src/term/search.rs#singlecell_fullwidth
        //   (alacritty 852e971c, body sha256:04342074e7f2).
        //   Divergence: two, both deliberate. Stimulus -- Alacritty searches for an emoji;
        //   DanTerm's proof obligation names Chinese, so we search for U+754C. Assertion --
        //   Alacritty asserts an inclusive `Point` range over its own cell grid, once per scan
        //   direction, through a compiled regex; DanTerm search is literal and
        //   canonical-caseless, so we assert one public half-open `TerminalTextRange`, and add
        //   the narrow neighbours upstream does not have so the width claim is a measurement
        //   rather than an assertion a uniformly generous range would also satisfy.
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("a\u{754C}b".utf8))

        var found = terminal.beginSearch("\u{754C}")
        #expect(found)
        #expect(terminal.activeSearchMatchRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 1),
            end: TerminalTextPosition(row: 0, column: 3)
        ))

        found = terminal.beginSearch("a")
        #expect(found)
        #expect(terminal.activeSearchMatchRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 0),
            end: TerminalTextPosition(row: 0, column: 1)
        ))
        found = terminal.beginSearch("b")
        #expect(found)
        #expect(terminal.activeSearchMatchRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 3),
            end: TerminalTextPosition(row: 0, column: 4)
        ))
    }

    @Test("a literal match crossing a soft wrap steps over the padding a pushed wide cell left")
    func wideGraphemeSearchRangeSpansSoftWrap() throws {
        // Intent: when a wide grapheme does not fit the columns left on its row, it moves to
        //   the next row whole and leaves a padding column behind. A literal match that
        //   crosses that break reports endpoints on whole-grapheme boundaries, and the
        //   abandoned padding column is not part of the searchable text.
        // Why it exists: the padding column is a row-local artifact of the current width, so
        //   the projection has one more cell than grapheme on that row. Narrow soft-wrap
        //   matching is already covered; this is where the projection-to-cell mapping has a
        //   column it can lose track of, and a needle would either fail to match or match a
        //   range shifted by one.
        // Scenario: a user searches for a phrase that the current pane width happens to have
        //   wrapped in the middle of a Chinese word.
        //
        // Adapted from alacritty_terminal/src/term/search.rs#wrapping_into_fullwidth
        //   (alacritty 852e971c, body sha256:be6fb5c2ed16).
        //   Divergence: Alacritty builds two hard-separated rows and searches within each row;
        //   we feed one logical line and let the width wrap it, because the wrap is the thing
        //   under test and a hard newline would not exercise it. We assert DanTerm's half-open
        //   projection range rather than an inclusive `Point` range, and use a Chinese
        //   character rather than an emoji, matching the sibling wide-search case.
        //   The closely related upstream `#no_spacer_fullwidth_linewrap` is deliberately not
        //   adapted: it reaches into `grid_mut()` to plant a wide char with no spacer, a state
        //   DanTerm's public byte feed cannot produce (see the ledger).
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("abc\u{754C}de".utf8))

        // One column is left after "abc", the wide grapheme needs two, so it starts the next
        // row and column 3 stays unwritten padding that the projection does not publish.
        #expect(terminal.screenText == "abc \n\u{754C}de\n    ")
        #expect(terminal.fullHistoryText == "abc\u{754C}de")

        var found = terminal.beginSearch("c\u{754C}")
        #expect(found)
        #expect(terminal.activeSearchMatchRange == TerminalTextRange(
            start: TerminalTextPosition(row: 0, column: 2),
            end: TerminalTextPosition(row: 1, column: 2)
        ))

        found = terminal.beginSearch("\u{754C}d")
        #expect(found)
        #expect(terminal.activeSearchMatchRange == TerminalTextRange(
            start: TerminalTextPosition(row: 1, column: 0),
            end: TerminalTextPosition(row: 1, column: 3)
        ))

        // A needle that would only match if the abandoned padding column were searchable text.
        found = terminal.beginSearch("c \u{754C}")
        #expect(found == false)
        expectValidGrid(terminal)
    }
}
