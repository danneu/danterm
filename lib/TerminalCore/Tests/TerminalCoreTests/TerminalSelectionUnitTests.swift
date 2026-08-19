// Terminal-token and logical-line range queries used by local multi-click selection.
import Testing

@testable import TerminalCore

/// Pins selection units to the terminal's logical projection rather than visual rows.
struct TerminalSelectionUnitTests {
    @Test("terminal-token ranges use DanTerm's fixed punctuation separators")
    func terminalTokenPunctuationSeparators() throws {
        // Intent: every fixed punctuation separator splits the terminal tokens
        //   on either side.
        // Why it exists: the fixed set is DanTerm's selection contract, so omitting
        //   one scalar silently changes what double-click selects.
        // Scenario: a user double-clicks beside each kind of shell punctuation
        //   in otherwise path-like text.
        let boundaries = Array(" '\"\u{2502}`|:;,()[]{}<>$")
        for boundary in boundaries {
            var terminal = try #require(Terminal(columns: 16, rows: 2))
            terminal.feed(Array("x/\(boundary).-_\u{00E9}".utf8))

            #expect(
                terminal.terminalTokenRange(at: .init(row: 0, column: 1)) == range(0, 0, 0, 2),
                "boundary \(boundary) must stop the left run"
            )
            #expect(
                terminal.terminalTokenRange(at: .init(row: 0, column: 3)) == range(0, 3, 0, 7),
                "boundary \(boundary) must stop the right run"
            )
        }
    }

    @Test("terminal-token ranges treat Unicode whitespace as adjacent separators")
    func terminalTokenUnicodeWhitespaceSeparators() throws {
        // Intent: double-click selection classifies non-ASCII whitespace with
        //   ASCII space and keeps a heterogeneous separator run contiguous.
        // Why it exists: terminal-token selection previously recognized only
        //   literal space and tab, despite line trimming using Unicode whitespace.
        // Scenario: output aligns two shell tokens with no-break and ideographic
        //   spaces, and the user double-clicks either the padding or a token.
        var terminal = try #require(Terminal(columns: 16, rows: 2))
        terminal.feed(Array("left\u{00A0}\u{3000}right".utf8))

        terminal.setSelection(terminal.terminalTokenRange(at: .init(row: 0, column: 4)))
        #expect(terminal.selectedText == "\u{00A0}\u{3000}")
        terminal.setSelection(terminal.terminalTokenRange(at: .init(row: 0, column: 7)))
        #expect(terminal.selectedText == "right")
    }

    @Test("terminal-token ranges select shell-oriented non-separators")
    func terminalTokenSelectsShellRuns() throws {
        var terminal = try #require(Terminal(columns: 32, rows: 2))
        terminal.feed(Array("(/foo/bar.txt) --flag a_b=c".utf8))

        terminal.setSelection(terminal.terminalTokenRange(at: .init(row: 0, column: 7)))
        #expect(terminal.selectedText == "/foo/bar.txt")
        terminal.setSelection(terminal.terminalTokenRange(at: .init(row: 0, column: 18)))
        #expect(terminal.selectedText == "--flag")
        terminal.setSelection(terminal.terminalTokenRange(at: .init(row: 0, column: 25)))
        #expect(terminal.selectedText == "a_b=c")
    }

    @Test("terminal-token and line ranges cross soft wraps but stop at hard lines")
    func logicalWrapRanges() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 4))
        terminal.feed(Array("abcdef\r\nXY".utf8))

        #expect(terminal.terminalTokenRange(at: .init(row: 1, column: 1)) == range(0, 0, 1, 2))
        #expect(terminal.logicalLineRange(at: .init(row: 1, column: 0)) == range(0, 0, 1, 2))
        #expect(terminal.logicalLineRange(at: .init(row: 2, column: 1)) == range(2, 0, 2, 2))

        var empty = try #require(Terminal(columns: 4, rows: 3))
        empty.feed(Array("A\r\n\r\nB".utf8))
        #expect(empty.logicalLineRange(at: .init(row: 1, column: 2)) == range(1, 0, 1, 0))

        let wrappedLine = terminal.logicalLineRange(at: .init(row: 1, column: 0))
        terminal.setSelection(wrappedLine)
        #expect(terminal.selectedText == "abcdef")
    }

    @Test("heterogeneous adjacent separators form one terminal-token unit")
    func heterogeneousSeparatorRun() throws {
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("a;,(b x (y".utf8))

        terminal.setSelection(terminal.terminalTokenRange(at: .init(row: 0, column: 2)))
        #expect(terminal.selectedText == ";,(")
        terminal.setSelection(terminal.terminalTokenRange(at: .init(row: 0, column: 7)))
        #expect(terminal.selectedText == " (")
    }

    @Test("terminal-token classification uses each cell's leading scalar")
    func leadingScalarClassification() throws {
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("x'\u{0301}y e\u{0301}.z".utf8))

        terminal.setSelection(terminal.terminalTokenRange(at: .init(row: 0, column: 1)))
        #expect(terminal.selectedText == "'\u{0301}")
        terminal.setSelection(terminal.terminalTokenRange(at: .init(row: 0, column: 4)))
        #expect(terminal.selectedText == "e\u{0301}.z")
    }

    @Test("terminal-token ranges fall back past retained content and clamp at stream edges")
    func fallbackAndClamping() throws {
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("ab   cd".utf8))

        #expect(terminal.terminalTokenRange(at: .init(row: 0, column: 3)) == range(0, 2, 0, 5))
        #expect(terminal.terminalTokenRange(at: .init(row: 0, column: 20)) == range(0, 5, 0, 7))

        var retained = try #require(Terminal(columns: 4, rows: 2))
        retained.feed(Array("old\r\nnew\r\nend".utf8))
        #expect(retained.terminalTokenRange(at: .init(row: 0, column: 1)) == range(0, 0, 0, 3))
        #expect(retained.terminalTokenRange(at: .init(row: -20, column: -20)) == range(0, 0, 0, 3))
        #expect(retained.terminalTokenRange(at: .init(row: 200, column: 200)) == range(2, 0, 2, 3))
        #expect(retained.logicalLineRange(at: .init(row: 200, column: 200))
            == range(2, 0, 2, 3))
    }

    @Test("line ranges trim whitespace at both outer edges of the logical line")
    func lineRangeTrimsOuterWhitespace() throws {
        var terminal = try #require(Terminal(columns: 20, rows: 2))
        terminal.feed(Array("  foo bar       ".utf8))

        let trimmed = terminal.trimmedLogicalLineRange(at: .init(row: 0, column: 12))
        #expect(trimmed == range(0, 2, 0, 9))
        terminal.setSelection(trimmed)
        #expect(terminal.selectedText == "foo bar")
    }

    @Test("line trimming removes whole Unicode-whitespace units")
    func lineRangeTrimsUnicodeWhitespaceUnits() throws {
        // Intent: trimming classifies a projected unit by its leading scalar's
        //   Unicode whitespace property and never splits a wide cell.
        // Why it exists: the ASCII set {NUL, space, tab} would leave a no-break or
        //   ideographic space selected, and a per-column trim could start the range
        //   on a wide cell's tail column.
        // Scenario: a line padded with CJK-era spacing whose content starts on a
        //   double-width glyph.
        var terminal = try #require(Terminal(columns: 24, rows: 2))
        terminal.feed(Array("\u{00A0}\u{3000} \u{0301}\u{6F22}z \u{3000}\u{00A0}".utf8))

        let trimmed = terminal.trimmedLogicalLineRange(at: .init(row: 0, column: 0))
        #expect(trimmed == range(0, 4, 0, 7))
        terminal.setSelection(trimmed)
        #expect(terminal.selectedText == "\u{6F22}z")
    }

    @Test("line trimming spans a soft-wrapped line and keeps whitespace inside it")
    func lineRangeTrimsAcrossSoftWrap() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 4))
        terminal.feed(Array("  ab  cd  \r\nX".utf8))

        let wrapped = terminal.trimmedLogicalLineRange(at: .init(row: 1, column: 0))
        #expect(wrapped == range(0, 2, 1, 4))
        terminal.setSelection(wrapped)
        #expect(terminal.selectedText == "ab  cd")

        let afterHardLine = terminal.trimmedLogicalLineRange(at: .init(row: 3, column: 2))
        #expect(afterHardLine == range(3, 0, 3, 1))
        terminal.setSelection(afterHardLine)
        #expect(terminal.selectedText == "X")
    }

    @Test("whitespace-only and unwritten lines trim to empty ranges at their line start")
    func lineRangeEmptyForBlankLines() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("A\r\n   \r\nB".utf8))

        #expect(terminal.trimmedLogicalLineRange(at: .init(row: 1, column: 2)) == range(1, 0, 1, 0))
        #expect(terminal.trimmedLogicalLineRange(at: .init(row: 3, column: 5)) == range(3, 0, 3, 0))
    }

    @Test("link detection keeps scanning the untrimmed logical line")
    func detectedLinksIgnoreLineTrimming() throws {
        // Intent: a URL on a line whose first row holds only whitespace still
        //   resolves, because detection scans `logicalLineRange`, not the trimmed unit.
        // Why it exists: trimming inside `logicalLineRange` would have moved the row
        //   window link detection searches, silently dropping links.
        // Scenario: an indented wrapped line whose visible URL begins after the wrap.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("        https://a.example/x".utf8))

        #expect(terminal.logicalLineRange(at: .init(row: 0, column: 0)) == range(0, 0, 3, 3))
        #expect(terminal.trimmedLogicalLineRange(at: .init(row: 0, column: 0)) == range(1, 0, 3, 3))
        let link = try #require(terminal.activatableLink(at: .init(row: 1, column: 2)))
        #expect(link.hyperlink.uri == "https://a.example/x")
    }

    @Test("selection range APIs index the active stream while alternate screen is active")
    func alternateScreenSelectionRangesCharacterization() throws {
        // Intent: characterize -- not fix -- what character, terminal-token, and
        //   line range queries return while the alternate screen is active over
        //   retained primary scrollback.
        // Why it exists: this is the baseline an upcoming point-local projection
        //   optimization must preserve. The optimization replaces whole-stream row
        //   materialization with indexed access, and alternate screen is the one
        //   configuration where the active stream is not simply "all primary
        //   history" -- scrollback and alt rows are concatenated with a hard seam.
        //   Without this test the refactor could silently re-coordinate alt-screen
        //   selection and nothing would fail.
        // Scenario: a session scrolls output into history, then a full-screen
        //   program takes over the alternate screen; the user selects text.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("ab cd\r\nef gh\r\nij kl\r\n".utf8))
        terminal.feed(Array("\u{1B}[?1047h\u{1B}[HWX YZ".utf8))

        #expect(terminal.isAlternateScreenActive)
        #expect(terminal.scrollbackRowCount == 5)

        // The active stream is primary scrollback (rows 0-4) followed by the two
        // alternate rows (5-6). Range queries index that concatenation.
        #expect(terminal.characterRange(at: .init(row: 0, column: 0)) == range(0, 0, 0, 1))
        #expect(terminal.terminalTokenRange(at: .init(row: 0, column: 0)) == range(0, 0, 0, 2))
        #expect(terminal.trimmedLogicalLineRange(at: .init(row: 0, column: 0)) == range(0, 0, 1, 1))

        // The alternate rows sit at the end of the same stream, and a soft wrap
        // joins them: the logical line spans the seam from row 5 into row 6.
        #expect(terminal.characterRange(at: .init(row: 5, column: 0)) == range(5, 0, 5, 1))
        #expect(terminal.terminalTokenRange(at: .init(row: 5, column: 0)) == range(5, 0, 5, 2))
        #expect(terminal.trimmedLogicalLineRange(at: .init(row: 5, column: 0)) == range(5, 0, 6, 1))
        #expect(terminal.terminalTokenRange(at: .init(row: 6, column: 0)) == range(5, 3, 6, 1))

        for (row, expected) in [(0, "ab"), (5, "WX"), (6, "YZ")] {
            var selected = terminal
            selected.setSelection(selected.terminalTokenRange(at: .init(row: row, column: 0)))
            #expect(selected.selectedText == expected)
        }

        // The last retained primary row is truncated where the alternate screen
        // replaced the live rows beneath it: "ij kl" reads back as "ij k".
        var line = terminal
        line.setSelection(line.trimmedLogicalLineRange(at: .init(row: 4, column: 0)))
        #expect(line.selectedText == "ij k")
    }

    @Test("a click on the alternate screen resolves against primary scrollback, not the alt row under the cursor")
    func alternateScreenClickCoordinateMismatchCharacterization() throws {
        // Intent: characterize the viewport-row -> stream-row mapping a real click
        //   takes while the alternate screen is active, which does not currently
        //   address the alternate rows at all.
        // Why it exists: `scrollProjection` reports `totalRows == rows` while alt is
        //   active, so `topRow` is 0 and viewport row 0 maps to stream row 0 -- the
        //   oldest primary scrollback row -- even though the alt content the user
        //   sees lives at the far end of the same stream. The point-local
        //   optimization must preserve this mapping rather than accidentally
        //   correcting it, because correcting it is a separate, deliberate change.
        //   Pinning it also stops the bug from being reintroduced silently after
        //   it is eventually fixed on purpose.
        // Scenario: a full-screen program is showing "WX YZ"; the user
        //   double-clicks the visible "WX" and the selection resolves to "ab",
        //   text from primary scrollback that is not on screen.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("ab cd\r\nef gh\r\nij kl\r\n".utf8))
        terminal.feed(Array("\u{1B}[?1047h\u{1B}[HWX YZ".utf8))

        #expect(terminal.scrollProjection.totalRows == 2)
        #expect(terminal.scrollProjection.topRow == 0)

        var state = TerminalInteractionState()
        let decision = decideTerminalPointer(
            .down(.left, cell: .init(column: 0, row: 0), clickCount: 2),
            terminal: terminal,
            state: &state
        )
        guard case let .set(selected) = decision.selectionMutation else {
            Issue.record("double-click down must set a selection, got \(String(describing: decision.selectionMutation))")
            return
        }
        // Not "WX", which is what row 0 of the alternate screen displays.
        #expect(selected == range(0, 0, 0, 2))
        terminal.setSelection(selected)
        #expect(terminal.selectedText == "ab")
    }

    @Test("nearest-unit fallback searches the whole stream backward, then forward")
    func nearestUnitFallbackAcrossBlankRegions() throws {
        // Intent: a terminal-token query on a row that projects no unit resolves to
        //   the nearest unit in the whole retained stream -- backward first, forward
        //   only when nothing precedes the click.
        // Why it exists: this is one of the three whole-stream dependencies an
        //   upcoming point-local projection change has to reproduce inside a bounded
        //   slice. A slice that searched only the clicked row would return an empty
        //   range for every case here, and the change would look correct because no
        //   existing test covers a click on a blank row between content.
        // Scenario: a user double-clicks in the vertical gap between two command
        //   outputs, below the last output, or above the first.

        // Blank line between two content lines: falls back to the preceding line.
        var between = try #require(Terminal(columns: 8, rows: 4))
        between.feed(Array("alpha\r\n\r\nbeta\r\n".utf8))
        for column in [0, 3, 7] {
            #expect(between.terminalTokenRange(at: .init(row: 1, column: column)) == range(0, 0, 0, 5))
        }
        between.setSelection(between.terminalTokenRange(at: .init(row: 1, column: 3)))
        #expect(between.selectedText == "alpha")

        // Blank rows after all content: still backward, across more than one row.
        var after = try #require(Terminal(columns: 8, rows: 4))
        after.feed(Array("alpha\r\nbeta\r\n".utf8))
        #expect(after.terminalTokenRange(at: .init(row: 2, column: 0)) == range(1, 0, 1, 4))
        #expect(after.terminalTokenRange(at: .init(row: 3, column: 0)) == range(1, 0, 1, 4))

        // Blank rows before all content: nothing precedes, so the search runs forward.
        var before = try #require(Terminal(columns: 8, rows: 4))
        before.feed(Array("\r\n\r\nbeta\r\n".utf8))
        #expect(before.terminalTokenRange(at: .init(row: 0, column: 0)) == range(2, 0, 2, 4))
        #expect(before.terminalTokenRange(at: .init(row: 1, column: 2)) == range(2, 0, 2, 4))
        before.setSelection(before.terminalTokenRange(at: .init(row: 0, column: 4)))
        #expect(before.selectedText == "beta")

        // A whitespace row inside a soft-wrapped line is NOT a fallback case: it
        // projects its own whitespace unit, so the query stays on the clicked row.
        var wrapped = try #require(Terminal(columns: 6, rows: 4))
        wrapped.feed(Array("abcdef      ghi".utf8))
        #expect(wrapped.terminalTokenRange(at: .init(row: 1, column: 3)) == range(1, 0, 1, 6))
        wrapped.setSelection(wrapped.terminalTokenRange(at: .init(row: 1, column: 3)))
        #expect(wrapped.selectedText == "      ")
        #expect(wrapped.trimmedLogicalLineRange(at: .init(row: 1, column: 3)) == range(0, 0, 2, 3))
    }

    @Test("expansion on whitespace inside a soft-wrapped line truncates at the global last-content boundary")
    func expansionWhitespaceTruncatesAtLastContent() throws {
        // Intent: a terminal-token query on trailing whitespace inside a
        //   soft-wrapped line yields a whitespace unit that crosses the wrap and
        //   ends at the stream's last-content boundary, not at a row edge.
        // Why it exists: the second of the three whole-stream dependencies. The
        //   boundary is a property of the whole retained stream, so a bounded slice
        //   that recomputed it from the clicked row's own content would truncate in
        //   the wrong place -- and would still return a plausible-looking range.
        // Scenario: a command emits a line with trailing padding that wraps past the
        //   window width, and the user double-clicks inside the padding.
        var terminal = try #require(Terminal(columns: 6, rows: 4))
        terminal.feed(Array("ab    cd      ".utf8))

        // Content ends mid-row-1 at "d"; the trailing run spans row 1 into row 2 and
        // stops where retained content stops.
        let trailing = terminal.terminalTokenRange(at: .init(row: 1, column: 2))
        #expect(trailing == range(1, 2, 2, 2))
        terminal.setSelection(trailing)
        #expect(terminal.selectedText == "      ")

        // Clicking further into the same run, on the next row, resolves to the same
        // unit rather than to a row-local one.
        #expect(terminal.terminalTokenRange(at: .init(row: 2, column: 0)) == trailing)
        #expect(terminal.terminalTokenRange(at: .init(row: 2, column: 3)) == trailing)

        // The interior whitespace run is a separate unit, bounded by content.
        #expect(terminal.terminalTokenRange(at: .init(row: 0, column: 3)) == range(0, 2, 0, 6))

        // Line trimming drops the trailing run entirely.
        #expect(terminal.trimmedLogicalLineRange(at: .init(row: 1, column: 2)) == range(0, 0, 1, 2))
    }

    @Test("range queries over deep scrollback answer for the clicked point, not the stream")
    func rangeQueriesOverDeepScrollback() throws {
        // Intent: with a large body of unrelated scrollback retained, character,
        //   terminal-token and line queries near the live bottom and deep in browsed
        //   history return the ranges and text of the clicked line.
        // Why it exists: this is the equivalence baseline for point-local expansion.
        //   Every one of these queries used to be answered by materializing the whole
        //   retained stream; the point-local walk has to return the same answers with
        //   the unrelated rows never projected, so the assertions have to hold with
        //   hundreds of rows of noise on both sides of the click.
        // Scenario: a long-running session with hundreds of lines of build output;
        //   the user double-clicks a word on the last line, then scrolls back and
        //   double-clicks one buried deep in history.
        var terminal = try #require(Terminal(columns: 16, rows: 4))
        terminal.feed(Array("deep marker\r\n".utf8))
        for index in 0..<400 {
            terminal.feed(Array("fill \(index)\r\n".utf8))
        }
        terminal.feed(Array("hello world\r\n".utf8))
        terminal.feed(Array("tail token".utf8))
        #expect(terminal.scrollbackRowCount == 399)

        // Row 401 is the last hard-ended line; row 402 is live.
        #expect(terminal.characterRange(at: .init(row: 401, column: 0)) == range(401, 0, 401, 1))
        #expect(terminal.terminalTokenRange(at: .init(row: 401, column: 2)) == range(401, 0, 401, 5))
        #expect(terminal.trimmedLogicalLineRange(at: .init(row: 401, column: 9))
            == range(401, 0, 401, 11))
        #expect(terminal.terminalTokenRange(at: .init(row: 402, column: 7)) == range(402, 5, 402, 10))

        // Browsing history does not re-coordinate the queries: the same deep row
        // answers the same way whether or not it is on screen.
        let deepToken = terminal.terminalTokenRange(at: .init(row: 0, column: 2))
        terminal.scroll(toTopRow: 0)
        #expect(terminal.terminalTokenRange(at: .init(row: 0, column: 2)) == deepToken)
        #expect(deepToken == range(0, 0, 0, 4))
        #expect(terminal.characterRange(at: .init(row: 0, column: 5)) == range(0, 5, 0, 6))
        #expect(terminal.trimmedLogicalLineRange(at: .init(row: 0, column: 0)) == range(0, 0, 0, 11))

        for (query, expected) in [
            (terminal.terminalTokenRange(at: .init(row: 401, column: 2)), "hello"),
            (terminal.terminalTokenRange(at: .init(row: 402, column: 7)), "token"),
            (deepToken, "deep"),
            (terminal.trimmedLogicalLineRange(at: .init(row: 0, column: 0)), "deep marker"),
        ] {
            var selected = terminal
            selected.setSelection(query)
            #expect(selected.selectedText == expected)
        }
    }

    @Test("a terminal token spans a soft-wrapped line straddling scrollback and live rows")
    func terminalTokenSpansScrollbackToLiveWrap() throws {
        // Intent: a token whose soft-wrapped rows begin in scrollback storage and end
        //   in the live rows selects as one unit, and a hard line ending still bounds it.
        // Why it exists: the scrollback/live boundary is a storage seam, not a text
        //   boundary. A point-local walk steps row by row rather than over one
        //   materialized array, so it is exactly where the two storages could be
        //   mistaken for a line ending.
        // Scenario: a command prints a long unbroken path that wraps across the
        //   bottom of the window while earlier rows have already scrolled off.
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("stop\r\nabcdefghijklmnop".utf8))

        // The wrapped token occupies stream rows 1-3, and the storage seam falls
        // inside it: row 1 has scrolled into scrollback, rows 2-3 are still live.
        #expect(terminal.scrollbackRowCount == 2)
        let wrapped = terminal.terminalTokenRange(at: .init(row: 2, column: 3))
        #expect(wrapped == range(1, 0, 3, 4))
        terminal.setSelection(wrapped)
        #expect(terminal.selectedText == "abcdefghijklmnop")

        // The hard line ending above it is still a boundary: the row above is its own token.
        #expect(terminal.terminalTokenRange(at: .init(row: 0, column: 1)) == range(0, 0, 0, 4))
    }

    @Test("applying a computed range through setSelection preserves the range and its text")
    func computedRangesRoundTripThroughSetSelection() throws {
        // Intent: every locally computed range survives being applied -- the selection
        //   reads back as the same range and yields the same text.
        // Why it exists: endpoint normalization inside `setSelection` is a second
        //   projection-dependent path. A range computed point-locally has to normalize
        //   to itself, or a double-click would select one unit and report another.
        // Scenario: a double-click or triple-click, which computes a range and
        //   immediately applies it.
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("one two\r\n\u{6F22}z ab\r\n  pad  ".utf8))

        let queries: [(TerminalTextRange, String)] = [
            (terminal.characterRange(at: .init(row: 0, column: 4)), "t"),
            (terminal.terminalTokenRange(at: .init(row: 0, column: 5)), "two"),
            (terminal.terminalTokenRange(at: .init(row: 0, column: 3)), " "),
            (terminal.characterRange(at: .init(row: 1, column: 1)), "\u{6F22}"),
            (terminal.terminalTokenRange(at: .init(row: 1, column: 0)), "\u{6F22}z"),
            (terminal.trimmedLogicalLineRange(at: .init(row: 1, column: 4)), "\u{6F22}z ab"),
            (terminal.trimmedLogicalLineRange(at: .init(row: 2, column: 0)), "pad"),
        ]
        for (query, expected) in queries {
            var applied = terminal
            applied.setSelection(query)
            #expect(applied.selectionRange == query)
            #expect(applied.selectedText == expected)
        }
    }

    private func range(
        _ startRow: Int,
        _ startColumn: Int,
        _ endRow: Int,
        _ endColumn: Int
    ) -> TerminalTextRange {
        TerminalTextRange(
            start: .init(row: startRow, column: startColumn),
            end: .init(row: endRow, column: endColumn)
        )
    }
}
