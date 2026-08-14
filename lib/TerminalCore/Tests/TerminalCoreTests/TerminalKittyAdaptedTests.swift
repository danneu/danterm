// Terminal-semantics cases adapted from kitty's own test suite: prompt marking under
// resize (Tier A) and rewrap row splits (Tier B). Separate from TerminalOSC133Tests and
// TerminalResizeTests -- which pin behavior DanTerm chose -- because everything here is
// tracked against an external suite: each test names the upstream test it follows and
// records a body hash, and `scripts/kitty-parity-lint.py` fails when that upstream test
// is renamed, revised, or left behind by a pin bump. Adapted cases belong here so the
// citation block is the file's rule rather than a stray convention; DanTerm-originated
// coverage for the same subsystems stays in its own suites.
//
// We adopt kitty's scenarios, never its assertions. kitty asserts through APIs DanTerm
// does not have (LineBuf.is_continued, scroll_to_prompt, cmd_output), so every citation
// carries a `Divergence:` line saying what we assert instead.
import Testing

@testable import TerminalCore

/// Tracks a slice of `kitty_tests` as DanTerm behavior, so upstream revisions surface as
/// a lint failure instead of silent compatibility drift.
struct TerminalKittyAdaptedTests {
    // MARK: - Tier A: prompt marking across resize

    @Test("a marked prompt leaves no debris on the cursor row after an alt-screen resize")
    func promptSurvivesAlternateScreenResize() throws {
        // Intent: resizing while the primary screen is parked behind the alternate screen
        //   leaves the primary's cursor row empty, as it was before the alt screen opened.
        // Why it exists: the primary screen is resized through a saved-state swap
        //   (`Terminal.resize`), so a prompt marked just before the switch is reflowed by a
        //   code path the live-screen tests never take. A prompt row mis-restored by that
        //   swap shows up as debris on the row the shell is about to print at.
        // Scenario: a full-screen program opens while a shell prompt is on screen, the
        //   window is narrowed, and the program exits.
        //
        // Adapted from kitty_tests/screen.py#test_prompt_marking
        //   (kitty v0.48.2 2cb1d95, body sha256:38e06cf3bf69).
        //   Divergence: kitty asserts `str(s.line(s.cursor.y))` is falsy; we assert the
        //   cursor row of `screenText` is blank, and only over the first of that test's
        //   five sections -- the rest drives scroll_to_prompt/cmd_output, which DanTerm
        //   deliberately does not implement (see the plan's "Deliberately out of scope").
        var terminal = try #require(Terminal(columns: 5, rows: 5))
        terminal.feed(Array("\u{1B}]133;C\u{7}0oo\r\n1oo\r\n2oo\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;A\u{7}$ pp\r\n\u{1B}]133;C\u{7}".utf8))

        terminal.feed(Array("\u{1B}[?1049h".utf8))
        terminal.resize(columns: 2, rows: 5)
        terminal.feed(Array("\u{1B}[?1049l".utf8))

        let cursorRow = try #require(terminal.geometry.cursor?.row)
        let rows = terminal.screenText.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(rows[cursorRow].allSatisfy { $0 == " " })
        expectValidGrid(terminal)
    }

    @Test("a wrapped prompt in scrollback round-trips through a narrow and back")
    func wrappedPromptInScrollbackRoundTripsAcrossWidths() throws {
        // Intent: once a marked prompt has scrolled into history, reflow treats it as
        //   ordinary wrapped text -- same logical lines at every width, one copy of it, and
        //   the same row split when the original width comes back.
        // Why it exists: the prompt stamps that `clearPromptForResizeIfNeeded` reads are
        //   carried through reflow alongside the cells. A stamp that survives reflow but
        //   lands on the wrong row is invisible until the next resize blanks from it; the
        //   observable early symptom is the prompt splitting into two logical lines or
        //   being duplicated. Neither is reachable through the stamps themselves, which
        //   are private by design, so the text is the whole proof obligation.
        // Scenario: a long prompt scrolls off under a build's output, and the pane is
        //   dragged narrow and back.
        //
        // Adapted from kitty_tests/screen.py#test_prompt_marking
        //   (kitty v0.48.2 2cb1d95, body sha256:38e06cf3bf69).
        //   Divergence: kitty's version of this scenario (`draw_prompt('P' * s.columns)`
        //   then output to push it into scrollback) asserts through `cmd_output` and
        //   `scroll_to_prompt`; we assert logical-text round-trip fidelity and
        //   non-duplication, and claim nothing about the stamps.
        var terminal = try #require(Terminal(columns: 8, rows: 4))
        terminal.feed(Array("\u{1B}]133;A\u{7}PROMPT-ONE-X$ \r\n".utf8))
        terminal.feed(Array("\u{1B}]133;C\u{7}".utf8))
        for index in 0..<6 { terminal.feed(Array("\(index)a\r\n".utf8)) }
        #expect(terminal.fullHistoryText.contains("PROMPT-ONE-X$"))
        #expect(terminal.screenText.contains("PROMPT-ONE-X") == false)

        let originalHistory = terminal.fullHistoryText
        let originalRows = retainedRows(of: terminal)

        terminal.resize(columns: 5, rows: 4)
        #expect(terminal.fullHistoryText == originalHistory)
        expectPromptIsOneWholeLine(terminal)
        expectValidGrid(terminal)

        terminal.resize(columns: 8, rows: 4)
        #expect(terminal.fullHistoryText == originalHistory)
        expectPromptIsOneWholeLine(terminal)
        #expect(retainedRows(of: terminal) == originalRows)
        expectValidGrid(terminal)
    }

    @Test("an anchorless resize blanks nothing and the next prompt cycle still blanks")
    func anchorlessResizeBlanksNothingAndRecovers() throws {
        // Intent: when the prompt head has left both the viewport and history, a resize
        //   blanks nothing at all -- and the next marked prompt is blanked normally.
        // Why it exists: prompt blanking finds its block by walking up from the cursor.
        //   With the head evicted, that walk reaches row 0 having seen neither a stamp nor
        //   the output floor, and the only safe answer is to blank nothing. The second half
        //   is what distinguishes "the stamp was safely lost" from "stale debris survived
        //   and now anchors the walk": debris would make the next resize blank from the
        //   wrong row, eating the rows above the new prompt.
        // Scenario: a long-running command's output evicts the prompt that launched it out
        //   of a small scrollback, and the pane is resized before the command finishes.
        //
        // Adapted from kitty_tests/screen.py#test_prompt_marking
        //   (kitty v0.48.2 2cb1d95, body sha256:38e06cf3bf69).
        //   Divergence: kitty degrades the same anchor via `clear_scrollback` and checks it
        //   through `scroll_to_prompt` returning False; DanTerm reaches the state through
        //   `scrollbackBudgetBytes` eviction and asserts on the text a resize leaves behind.
        var terminal = try #require(Terminal(columns: 8, rows: 3, scrollbackBudgetBytes: historyBudget(lines: 2, cells: 8, paneColumns: 8)))
        terminal.feed(Array("\u{1B}]133;A\u{7}HEAD$ \r\n".utf8))
        for index in 0..<12 { terminal.feed(Array("L\(index)\r\n".utf8)) }
        #expect(terminal.fullHistoryText.contains("HEAD$") == false)

        let beforeHistory = terminal.fullHistoryText
        let beforeViewport = terminal.viewportText

        terminal.resize(columns: 6, rows: 3)
        #expect(terminal.viewportText == beforeViewport)
        #expect(terminal.fullHistoryText == beforeHistory)
        #expect(terminal.fullHistoryText.contains("HEAD$") == false)
        terminal.resize(columns: 8, rows: 3)
        #expect(terminal.viewportText == beforeViewport)
        #expect(terminal.fullHistoryText == beforeHistory)
        #expect(terminal.fullHistoryText.contains("HEAD$") == false)
        expectValidGrid(terminal)

        // The next cycle is clean: a fresh mark anchors the walk again, and blanking is
        // confined to the new prompt block -- the rows above it are untouched.
        let aboveBefore = viewportLines(of: terminal).dropLast().map(String.init)
        terminal.feed(Array("\u{1B}]133;A\u{7}NEW$ \u{1B}]133;B\u{7}".utf8))
        terminal.resize(columns: 7, rows: 3)

        #expect(terminal.screenText.contains("NEW$") == false)
        #expect(viewportLines(of: terminal).dropLast().map(String.init) == aboveBefore)
        expectValidGrid(terminal)
    }

    // MARK: - Tier B: rewrap row splits

    @Test("widening shifts a continued row's trailing space instead of trimming it")
    func widenKeepsTrailingSpaceInsideAContinuedLine() throws {
        // Intent: a space at the end of a soft-wrapped row is content, so widening moves
        //   the following characters up past it rather than reclaiming it as padding.
        //
        // Adapted from kitty_tests/datatypes.py#test_rewrap_wider
        //   (kitty v0.48.2 2cb1d95, body sha256:7745ed8137eb).
        //   Divergence: kitty builds the buffer with `create_lbuf` and asserts
        //   `LineBuf.is_continued`; we drive the same shape through the parser and assert
        //   `screenText` rows plus `isSoftWrapped`, which is DanTerm's inverted spelling of
        //   the same flag (row i wraps into row i+1).
        var terminal = try #require(Terminal(columns: 5, rows: 3))
        terminal.feed(Array("0123 56789".utf8))
        #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [true, false, false])

        terminal.resize(columns: 6, rows: 3)

        #expect(terminal.screenText == "0123 5\n6789  \n      ")
        #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [true, false, false])
        expectValidGrid(terminal)
    }

    @Test("rewrap never joins two rows that were not soft-wrapped together")
    func rewrapDoesNotJoinUnwrappedRows() throws {
        // Intent: two hard lines stay two logical lines through a widen, even when the
        //   first is short enough that the second would fit beside it.
        //
        // Adapted from kitty_tests/datatypes.py#test_rewrap_wider
        //   (kitty v0.48.2 2cb1d95, body sha256:7745ed8137eb).
        //   Divergence: kitty asserts `is_continued == (False, False)` on the rewrapped
        //   LineBuf; we assert the row texts and that no row claims a soft wrap.
        var terminal = try #require(Terminal(columns: 3, rows: 3))
        terminal.feed(Array("12\r\nabc".utf8))

        terminal.resize(columns: 6, rows: 3)

        #expect(terminal.screenText == "12    \nabc   \n      ")
        #expect(terminal.geometry.rows.allSatisfy { $0.isSoftWrapped == false })
        expectValidGrid(terminal)
    }

    @Test("narrowing splits only the row that overflows")
    func narrowSplitsOnlyTheOverflowingRow() throws {
        // Intent: narrowing re-splits the line that no longer fits and leaves the line
        //   above it alone, including its wrap flag.
        //
        // Adapted from kitty_tests/datatypes.py#test_rewrap_narrower
        //   (kitty v0.48.2 2cb1d95, body sha256:dacf8a9efad9).
        //   Divergence: kitty consumes a trailing blank while DanTerm preserves it and moves
        //   the unchanged first row into scrollback.
        var terminal = try #require(Terminal(columns: 5, rows: 4))
        terminal.feed(Array("123\r\nabcde".utf8))

        terminal.resize(columns: 3, rows: 4)

        #expect(terminal.scrollbackRowCount == 1)
        #expect(terminal.scrollbackRow(at: 0)?.isSoftWrapped == false)
        #expect(terminal.screenText == "abc\nde \n   \n   ")
        #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [true, false, false, false])
        expectValidGrid(terminal)
    }

    @Test("narrowing carries a continued row's trailing spaces into the split")
    func narrowCarriesTrailingSpacesOfAContinuedRow() throws {
        // Intent: when a full row ending in spaces wraps into the row below, those spaces
        //   are interior content of one logical line and must reappear in the middle of the
        //   narrowed split rather than being dropped at the row boundary.
        //
        // Adapted from kitty_tests/datatypes.py#test_rewrap_narrower
        //   (kitty v0.48.2 2cb1d95, body sha256:dacf8a9efad9).
        //   Divergence: kitty's `create_lbuf('123  ', 'abcde')` marks line 1 continued
        //   because line 0 fills the width; we produce the same single logical line by
        //   feeding it as one overflowing write, and assert row texts plus `isSoftWrapped`
        //   instead of `is_continued`. Kitty consumes the trailing blank rows; DanTerm keeps
        //   them and displaces the first two narrowed rows into scrollback.
        var terminal = try #require(Terminal(columns: 5, rows: 5))
        terminal.feed(Array("123  abcde".utf8))
        #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [true, false, false, false, false])

        terminal.resize(columns: 3, rows: 5)

        #expect(terminal.scrollbackRowCount == 2)
        #expect(terminal.scrollbackRow(at: 0)?.isSoftWrapped == true)
        #expect(terminal.scrollbackRow(at: 1)?.isSoftWrapped == true)
        #expect(terminal.screenText == "bcd\ne  \n   \n   \n   ")
        #expect(terminal.geometry.rows.map(\.isSoftWrapped) == [true, false, false, false, false])
        expectValidGrid(terminal)
    }

    // MARK: - Helpers

    /// Row text plus wrap flag for the whole retained stream, which is what "the rows split
    /// exactly as they did originally" means without reaching into private row state.
    private func retainedRows(of terminal: Terminal) -> [String] {
        let history = (0..<terminal.scrollbackRowCount).map { index -> String in
            guard let row = terminal.scrollbackRow(at: index) else { return "<missing>" }
            return rowText(row.cells) + (row.isSoftWrapped ? "|wrap" : "")
        }
        let screen = terminal.screenText.split(separator: "\n", omittingEmptySubsequences: false)
        let viewport = zip(screen, terminal.geometry.rows).map { text, row in
            String(text) + (row.isSoftWrapped ? "|wrap" : "")
        }
        return history + viewport
    }

    private func viewportLines(of terminal: Terminal) -> [Substring] {
        terminal.viewportText.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private func rowText(_ cells: [TerminalCell]) -> String {
        var result = ""
        for cell in cells {
            switch cell.kind {
            case .narrow, .wideHead:
                for scalar in cell.scalars { result.unicodeScalars.append(scalar) }
            case .padding, .spacerHead:
                result.append(" ")
            case .wideTail:
                break
            }
        }
        return result
    }

    /// Asserts the A2 prompt is exactly one whole logical line and appears exactly once.
    private func expectPromptIsOneWholeLine(
        _ terminal: Terminal,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let lines = terminal.fullHistoryText.split(separator: "\n", omittingEmptySubsequences: false)
        let matches = lines.filter { $0.contains("PROMPT-ONE-X") }
        #expect(matches.count == 1, sourceLocation: sourceLocation)
        // The trailing space was written by the shell, so it is content and stays with the
        // line; the assertion is exact so a reflow that joined or split the line fails here.
        #expect(matches.first.map(String.init) == "PROMPT-ONE-X$ ", sourceLocation: sourceLocation)
    }
}
