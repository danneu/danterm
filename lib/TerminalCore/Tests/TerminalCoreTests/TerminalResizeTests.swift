// Primary-screen resize proofs for reflow, cursor attachment, and viewport transfer.
import Testing

@testable import TerminalCore

struct TerminalResizeTests {
    @Test("same-size and invalid resize requests are bit-identical no-ops")
    func invalidAndSameSizeResizeAreNoOps() throws {
        // Adapted from kitty_tests/datatypes.py#test_rewrap_simple
        //   (kitty v0.48.2 2cb1d95, body sha256:4f347ba22878).
        //   Divergence: covers only that test's same-width identity leg, and asserts whole-
        //   terminal equality rather than kitty's per-line `lb2.line(i) == lb.line(i)`.
        //   Pre-existing coverage; annotated rather than duplicated.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("abcdefghijkl".utf8))
        #expect(terminal.scrollbackRowCount == 1)
        #expect(terminal.geometry.cursor?.isPendingWrap == true)
        let original = terminal

        terminal.resize(columns: 4, rows: 2)
        terminal.resize(columns: 1, rows: 2)
        terminal.resize(columns: 4, rows: 0)

        #expect(terminal == original)
    }

    @Test("no-op resize preserves partial stream and open-cluster state")
    func noOpResizePreservesPendingState() throws {
        var utf8 = try #require(Terminal(columns: 4, rows: 2))
        var uninterruptedUTF8 = utf8
        utf8.feed([0xE7, 0x95])
        uninterruptedUTF8.feed([0xE7, 0x95])
        utf8.resize(columns: 4, rows: 2)
        utf8.resize(columns: 1, rows: 2)
        utf8.feed([0x8C])
        uninterruptedUTF8.feed([0x8C])
        #expect(utf8 == uninterruptedUTF8)

        var csi = try #require(Terminal(columns: 4, rows: 2))
        var uninterruptedCSI = csi
        csi.feed(Array("\u{001B}[2;".utf8))
        uninterruptedCSI.feed(Array("\u{001B}[2;".utf8))
        csi.resize(columns: 4, rows: 2)
        csi.resize(columns: 4, rows: 0)
        csi.feed(Array("4Hq".utf8))
        uninterruptedCSI.feed(Array("4Hq".utf8))
        #expect(csi == uninterruptedCSI)

        var cluster = try #require(Terminal(columns: 4, rows: 2))
        var uninterruptedCluster = cluster
        cluster.feed(Array("a".utf8))
        uninterruptedCluster.feed(Array("a".utf8))
        cluster.resize(columns: 4, rows: 2)
        cluster.resize(columns: 1, rows: 2)
        cluster.feed(Array("\u{0301}".utf8))
        uninterruptedCluster.feed(Array("\u{0301}".utf8))
        #expect(cluster == uninterruptedCluster)
    }

    @Test("width reflow preserves logical text across narrow, wide, emoji, and spaces")
    func widthWalkConservesFullHistory() throws {
        var terminal = try #require(Terminal(columns: 12, rows: 4))
        terminal.feed(Array("espan\u{0303}ol \u{754C} \u{1F469}\u{200D}\u{1F4BB}  fin\r\nlinea dos".utf8))
        let expected = terminal.fullHistoryText

        for width in Array(stride(from: 11, through: 2, by: -1)) + Array(3...12) {
            terminal.resize(columns: width, rows: 4)
            #expect(terminal.fullHistoryText == expected)
            expectValidGrid(terminal)
        }
    }

    @Test("height walks and combined resize sequences conserve full-history text")
    func heightAndCombinedWalksConserveFullHistory() throws {
        var terminal = try #require(Terminal(columns: 9, rows: 4))
        terminal.feed(Array("uno \u{754C}\r\ndos  \r\n\u{1F642} tres\r\ncuatro\r\ncinco".utf8))
        let expected = terminal.fullHistoryText

        for height in [3, 2, 1, 2, 5, 3, 6, 4] {
            terminal.resize(columns: terminal.geometry.columns, rows: height)
            #expect(terminal.fullHistoryText == expected)
            expectValidGrid(terminal)
        }
        for dimensions in [(7, 3), (3, 6), (2, 2), (11, 5), (9, 4)] {
            terminal.resize(columns: dimensions.0, rows: dimensions.1)
            #expect(terminal.fullHistoryText == expected)
            expectValidGrid(terminal)
        }
    }

    @Test("height walks conserve a live prompt block and its semantic invariants")
    func promptedHeightWalkConservesFullHistory() throws {
        var terminal = try #require(Terminal(columns: 9, rows: 4))
        terminal.feed(Array("\u{1B}]133;A;redraw=1\u{7}one\r\ntwo\r\nthree\r\nfour\u{1B}]133;B\u{7}".utf8))
        let expected = terminal.fullHistoryText

        for height in [3, 2, 1, 2, 5, 3, 6, 4] {
            terminal.resize(columns: 9, rows: height)
            #expect(terminal.fullHistoryText == expected, "height \(height)")
            expectSemanticPromptInvariants(terminal, context: "prompted height \(height)")
            expectValidGrid(terminal)
        }
    }

    @Test("a prompt crossing the history seam remains singular through later reflow")
    func promptedSeamRoundTripDoesNotDuplicatePrompt() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("\u{1B}]133;A;redraw=1\u{7}PROMPT-A\r\nPROMPT-B\r\nPROMPT-C\u{1B}]133;B\u{7}".utf8))

        terminal.resize(columns: 8, rows: 1)
        terminal.resize(columns: 8, rows: 3)
        #expect(terminal.fullHistoryText.components(separatedBy: "PROMPT-A").count - 1 == 1)
        #expect(terminal.semanticPromptRowsForTesting.filter { $0.stamp == .prompt }.count == 1)

        terminal.resize(columns: 9, rows: 3)
        terminal.feed(Array("\u{1B}]133;A;redraw=1\u{7}PROMPT-NEW\u{1B}]133;B\u{7}".utf8))

        #expect(terminal.fullHistoryText.components(separatedBy: "PROMPT-").count - 1 == 1)
        expectSemanticPromptInvariants(terminal, context: "prompt seam round trip")
        expectValidGrid(terminal)
    }

    @Test("combined resize is exactly height then width")
    func combinedResizeUsesCanonicalOrder() throws {
        var combined = try #require(Terminal(columns: 6, rows: 3))
        combined.feed(Array("abcdefghi\r\nsecond".utf8))
        var sequential = combined

        combined.resize(columns: 4, rows: 2)
        sequential.resize(columns: 6, rows: 2)
        sequential.resize(columns: 4, rows: 2)

        #expect(combined == sequential)
    }

    @Test("height shrink trims filler then retains displaced top rows")
    func heightShrinkTransfersRows() throws {
        // Adapted from kitty_tests/datatypes.py#test_rewrap_simple
        //   (kitty v0.48.2 2cb1d95, body sha256:4f347ba22878).
        //   Divergence: covers that test's row-shrink leg. kitty's LineBuf has no history,
        //   so it asserts the top rows are gone; DanTerm retains them in scrollback, which
        //   is what `scrollbackRowCount` pins here. Pre-existing coverage; annotated
        //   rather than duplicated.
        var filler = try #require(Terminal(columns: 4, rows: 3))
        filler.feed(Array("ab".utf8))
        filler.moveCursor(row: 0, column: 2)
        filler.resize(columns: 4, rows: 1)
        #expect(filler.scrollbackRowCount == 0)
        #expect(filler.screenText == "ab  ")

        var content = try #require(Terminal(columns: 4, rows: 3))
        content.feed(Array("a\r\nb\r\nc".utf8))
        content.resize(columns: 4, rows: 2)
        #expect(content.scrollbackRowCount == 1)
        #expect(content.screenText == "b   \nc   ")
        #expect(content.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
    }

    @Test("height growth pulls history only for a bottom-row cursor")
    func heightGrowthEligibility() throws {
        // Adapted from kitty_tests/datatypes.py#test_rewrap_simple
        //   (kitty v0.48.2 2cb1d95, body sha256:4f347ba22878).
        //   Divergence: covers that test's row-growth leg -- content preserved, the added
        //   rows blank. kitty grows into empty lines unconditionally; DanTerm only pulls
        //   history back for a bottom-row cursor, which is the extra case here.
        //   Pre-existing coverage; annotated rather than duplicated.
        var bottom = try #require(Terminal(columns: 4, rows: 2))
        bottom.feed(Array("a\r\nb\r\nc\r\nd".utf8))
        #expect(bottom.scrollbackRowCount == 2)
        bottom.resize(columns: 4, rows: 4)
        #expect(bottom.scrollbackRowCount == 0)
        #expect(bottom.screenText == "a   \nb   \nc   \nd   ")
        #expect(bottom.geometry.cursor?.row == 3)

        var aboveBottom = try #require(Terminal(columns: 4, rows: 2))
        aboveBottom.feed(Array("a\r\nb\r\nc\r\nd".utf8))
        aboveBottom.moveCursor(row: 0, column: 1)
        aboveBottom.resize(columns: 4, rows: 4)
        #expect(aboveBottom.scrollbackRowCount == 2)
        #expect(aboveBottom.screenText == "c   \nd   \n    \n    ")
        #expect(aboveBottom.geometry.cursor?.row == 0)
    }

    @Test("a compact history row becomes full width when pulled into the live grid")
    func heightGrowthMaterializesCompactHistory() throws {
        // Intent: a retained row returning to the viewport accepts mutation at the last column.
        // Why it exists: live-grid algorithms index full-width rows directly, so transferring the
        //   compact allocation without materializing it would trap on the first edge write.
        // Scenario: height growth pulls a short history line back, then output targets its edge.
        var terminal = try #require(Terminal(columns: 8, rows: 1))
        terminal.feed(Array("abc\r\n".utf8))
        terminal.resize(columns: 8, rows: 2)
        terminal.moveCursor(row: 0, column: 7)
        terminal.feed(Array("Z".utf8))

        #expect(terminal.cell(row: 0, column: 7)?.scalars == ["Z"])
        expectValidGrid(terminal)
    }

    @Test("height transfer preserves wrap flags and does not accrete filler blanks")
    func heightTransferPreservesFlagsAndFillerIdentity() throws {
        var wrapped = try #require(Terminal(columns: 4, rows: 2))
        wrapped.feed(Array("abcdefghi".utf8))
        #expect(wrapped.scrollbackRow(at: 0)?.isSoftWrapped == true)
        wrapped.resize(columns: 4, rows: 3)
        #expect(wrapped.scrollbackRowCount == 0)
        #expect(wrapped.geometry.rows.map(\.isSoftWrapped) == [true, true, false])

        var filler = try #require(Terminal(columns: 4, rows: 1))
        filler.feed(Array("x".utf8))
        let history = filler.fullHistoryText
        filler.resize(columns: 4, rows: 4)
        filler.resize(columns: 4, rows: 1)
        #expect(filler.scrollbackRowCount == 0)
        #expect(filler.fullHistoryText == history)

        var blankHistory = try #require(Terminal(columns: 4, rows: 3))
        blankHistory.moveCursor(row: 2, column: 0)
        blankHistory.resize(columns: 4, rows: 1)
        #expect(blankHistory.scrollbackRowCount == 2)
        #expect(blankHistory.scrollbackRow(at: 0)?.isSoftWrapped == false)
        #expect(blankHistory.scrollbackRow(at: 1)?.isSoftWrapped == false)
    }

    @Test("height shrink clamps a displaced cursor without losing its column or wrap")
    func heightShrinkClampsDisplacedCursor() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("abcd\r\nefgh\r\nijkl".utf8))
        terminal.moveCursor(row: 0, column: 3)
        terminal.feed(Array("Z".utf8))
        #expect(terminal.geometry.cursor?.isPendingWrap == true)

        terminal.resize(columns: 4, rows: 1)

        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: true))
        #expect(terminal.scrollbackRowCount == 2)
    }

    @Test("cell anchors follow narrow, wide-tail, spacer, and interior padding cells")
    func cellAnchorsFollowReflowedCells() throws {
        var narrow = try #require(Terminal(columns: 6, rows: 3))
        narrow.feed(Array("abcdef".utf8))
        narrow.moveCursor(row: 0, column: 4)
        narrow.resize(columns: 4, rows: 3)
        #expect(narrow.geometry.cursor == TerminalCursor(row: 1, column: 0, isPendingWrap: false))

        var tail = try #require(Terminal(columns: 6, rows: 3))
        tail.feed(Array("ab\u{754C}c".utf8))
        tail.moveCursor(row: 0, column: 3)
        tail.resize(columns: 3, rows: 3)
        #expect(tail.geometry.cursor == TerminalCursor(row: 1, column: 0, isPendingWrap: false))

        var head = try #require(Terminal(columns: 6, rows: 3))
        head.feed(Array("ab\u{754C}c".utf8))
        head.moveCursor(row: 0, column: 2)
        head.resize(columns: 3, rows: 3)
        #expect(head.geometry.cursor == TerminalCursor(row: 1, column: 0, isPendingWrap: false))

        var spacer = try #require(Terminal(columns: 3, rows: 3))
        spacer.feed(Array("ab\u{754C}".utf8))
        spacer.moveCursor(row: 0, column: 2)
        spacer.resize(columns: 4, rows: 3)
        #expect(spacer.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))

        var padding = try #require(Terminal(columns: 5, rows: 3))
        padding.feed(Array("a".utf8))
        padding.moveCursor(row: 0, column: 3)
        padding.feed(Array("b".utf8))
        padding.moveCursor(row: 0, column: 1)
        padding.resize(columns: 3, rows: 3)
        #expect(padding.geometry.cursor == TerminalCursor(row: 0, column: 1, isPendingWrap: false))

        var softPadding = try #require(Terminal(columns: 4, rows: 3))
        softPadding.moveCursor(row: 0, column: 2)
        softPadding.feed(Array("abc".utf8))
        softPadding.moveCursor(row: 0, column: 0)
        softPadding.resize(columns: 3, rows: 3)
        #expect(softPadding.geometry.cursor == TerminalCursor(row: 0, column: 0, isPendingWrap: false))

        var writtenSpace = try #require(Terminal(columns: 4, rows: 2))
        writtenSpace.feed(Array("a b".utf8))
        writtenSpace.moveCursor(row: 0, column: 1)
        writtenSpace.resize(columns: 2, rows: 2)
        #expect(writtenSpace.geometry.cursor == TerminalCursor(row: 0, column: 1, isPendingWrap: false))
        #expect(writtenSpace.cell(row: 0, column: 1)?.kind == .narrow)
    }

    @Test("trailing padding anchors preserve distance and clamp without creating rows")
    func trailingPaddingAnchorPreservesDistance() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("ab".utf8))
        terminal.moveCursor(row: 0, column: 4)

        terminal.resize(columns: 5, rows: 2)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 4, isPendingWrap: false))
        terminal.resize(columns: 3, rows: 2)
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 2, isPendingWrap: false))
        #expect(terminal.geometry.rows[0].isSoftWrapped == false)

        var empty = try #require(Terminal(columns: 6, rows: 2))
        empty.moveCursor(row: 0, column: 5)
        empty.resize(columns: 3, rows: 2)
        #expect(empty.geometry.cursor?.column == 2)
    }

    @Test("pending-wrap boundary anchors become interior or remain pending at a row end")
    func boundaryAnchorFollowsReflowBoundary() throws {
        var wider = try #require(Terminal(columns: 6, rows: 3))
        wider.feed(Array("abcdef".utf8))
        wider.resize(columns: 8, rows: 3)
        #expect(wider.geometry.cursor == TerminalCursor(row: 0, column: 6, isPendingWrap: false))

        var narrower = try #require(Terminal(columns: 6, rows: 3))
        narrower.feed(Array("abcdef".utf8))
        narrower.resize(columns: 3, rows: 3)
        #expect(narrower.geometry.cursor == TerminalCursor(row: 1, column: 2, isPendingWrap: true))
    }

    @Test("a squeezed-out trailing-blank cursor defers its wrap instead of eating a cell")
    func trailingBlankAnchorDefersWrapWhenContentFillsRow() throws {
        // Intent: when the cursor rests on the blank just past the end of a line and a
        //   narrow removes that blank, the cursor keeps meaning "after the text" -- as a
        //   deferred wrap on the last column -- rather than sliding back onto the last
        //   character.
        // Why it exists: the trailing-padding anchor clamps its column to the right margin,
        //   and when the reflowed content fills the row exactly that clamp lands on
        //   committed output. Nothing downstream can tell that apart from the cursor
        //   legitimately sitting there, so the next printed scalar silently destroys a
        //   character. Sibling anchor tests miss it: they either start from a pending-wrap
        //   cursor or clamp onto a blank, where the same bug is harmless.
        // Scenario: found while replaying WezTerm issue 2162 (see
        //   TerminalWezTermAdaptedTests). Typing at a shell prompt after narrowing the
        //   window overwrote the final character of the prompt line.
        var terminal = try #require(Terminal(columns: 20, rows: 4))
        terminal.feed(Array("some long long text".utf8))
        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 19, isPendingWrap: false))

        terminal.resize(columns: 19, rows: 4)

        #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 18, isPendingWrap: true))

        // The behavioral consequence, and the reason this is a bug rather than a
        // representation quibble: printing must not overwrite committed output.
        terminal.feed(Array("X".utf8))
        #expect(terminal.geometry.rows[0].isSoftWrapped == true)
        #expect(terminal.fullHistoryText == "some long long textX")

        // A cursor clamped onto a *blank* keeps its plain column, with no deferred wrap:
        // there is no committed cell to protect, and `trailingPaddingAnchorPreservesDistance`
        // pins that neighboring case.
        var padded = try #require(Terminal(columns: 6, rows: 2))
        padded.feed(Array("ab".utf8))
        padded.moveCursor(row: 0, column: 5)
        padded.resize(columns: 4, rows: 2)
        #expect(padded.geometry.cursor == TerminalCursor(row: 0, column: 3, isPendingWrap: false))
    }

    @Test("width shrink uses viewport blanks before displacing content")
    func widthShrinkDoesNotSelfPush() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("abcdef".utf8))

        terminal.resize(columns: 4, rows: 3)

        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.screenText == "abcd\nef  \n    ")
    }

    @Test("a width round trip preserves a Codex composer viewport above the bottom")
    func widthRoundTripPreservesCodexComposerViewport() throws {
        // Intent: consecutive width changes preserve the primary viewport, cursor attachment,
        //   and history/live seam when the cursor starts above the bottom row.
        // Why it exists: the Codex composer incident showed that narrowing consumed unwritten
        //   trailing rows, then widening pulled retained history into their place and left a
        //   stale shifted composer after Codex redrew at its original coordinates.
        // Scenario: a 10x6 viewport has retained transcript, two full live rows, a composer,
        //   and three never-written rows before a 10 -> 5 -> 10 resize round trip.
        var terminal = try #require(Terminal(columns: 10, rows: 6))
        terminal.feed(Array("history-0\r\nhistory-1\r\nhistory-2\r\nhistory-3\r\nhistory-4\r\nhistory-5\r\n".utf8))
        terminal.feed(Array("\u{001B}[2J".utf8))
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed(Array("ABCDEFGHIJ".utf8))
        terminal.moveCursor(row: 1, column: 0)
        terminal.feed(Array("KLMNOPQRST".utf8))
        terminal.moveCursor(row: 2, column: 0)
        terminal.feed(Array("compose".utf8))

        let viewport = terminal.screenText
        let cursor = terminal.geometry.cursor
        let scrollbackRows = terminal.scrollbackRowCount
        let structure = terminal.rowStructure
        let fullHistory = terminal.fullHistoryText
        #expect(scrollbackRows > 0)

        terminal.resize(columns: 5, rows: 6)
        terminal.resize(columns: 10, rows: 6)

        #expect(terminal.screenText == viewport)
        #expect(terminal.geometry.cursor == cursor)
        #expect(terminal.scrollbackRowCount == scrollbackRows)
        #expect(terminal.rowStructure == structure)
        #expect(terminal.fullHistoryText == fullHistory)
        expectValidGrid(terminal)
    }

    @Test("a multi-step width series restores a trailing-padding cursor")
    func multiStepWidthSeriesRestoresTrailingPaddingCursor() throws {
        var terminal = try makeComposerFixture()
        terminal.moveCursor(row: 2, column: 9)
        let viewport = terminal.screenText
        let cursor = terminal.geometry.cursor
        let scrollbackRows = terminal.scrollbackRowCount
        let fullHistory = terminal.fullHistoryText

        for width in [7, 5, 8, 10] {
            terminal.resize(columns: width, rows: 6)
            #expect(terminal.fullHistoryText == fullHistory, "width \(width)")
            #expect(terminal.viewportText.contains("compose"), "width \(width)")
            #expect(terminal.geometry.cursor != nil, "width \(width)")
            expectValidGrid(terminal)
        }

        #expect(terminal.screenText == viewport)
        #expect(terminal.geometry.cursor == cursor)
        #expect(terminal.scrollbackRowCount == scrollbackRows)
    }

    @Test("primary output ends a width series before the next width change")
    func primaryOutputEndsWidthSeries() throws {
        var terminal = try makeComposerFixture()
        terminal.resize(columns: 5, rows: 6)
        terminal.feed(Array("X".utf8))
        let afterOutput = terminal.fullHistoryText
        var explicitlyEnded = terminal
        explicitlyEnded.scroll(byRows: 0)

        terminal.resize(columns: 10, rows: 6)
        explicitlyEnded.resize(columns: 10, rows: 6)

        #expect(terminal == explicitlyEnded)
        #expect(terminal.fullHistoryText == afterOutput)
        #expect(terminal.viewportText.contains("composeX"))
        expectValidGrid(terminal)
    }

    @Test("primary cursor motion ends a width series before the next width change")
    func primaryCursorMotionEndsWidthSeries() throws {
        var terminal = try makeComposerFixture()
        terminal.resize(columns: 5, rows: 6)
        terminal.feed(Array("\u{001B}[1;1H".utf8))
        var explicitlyEnded = terminal
        explicitlyEnded.scroll(byRows: 0)

        terminal.resize(columns: 10, rows: 6)
        explicitlyEnded.resize(columns: 10, rows: 6)

        #expect(terminal == explicitlyEnded)
        #expect(terminal.geometry.cursor?.column == 0)
        expectValidGrid(terminal)
    }

    @Test("height then width establishes a new resize layout")
    func heightChangeEndsWidthSeriesInCanonicalOrder() throws {
        var combined = try makeComposerFixture()
        combined.resize(columns: 5, rows: 6)
        combined.resize(columns: 5, rows: 7)
        var explicitlyEnded = combined
        explicitlyEnded.scroll(byRows: 0)

        combined.resize(columns: 10, rows: 7)
        explicitlyEnded.resize(columns: 10, rows: 7)

        #expect(combined == explicitlyEnded)
        expectValidGrid(combined)
    }

    @Test("viewport navigation replaces the resize-series viewport anchor")
    func viewportNavigationEndsWidthSeries() throws {
        var terminal = try makeComposerFixture()
        terminal.resize(columns: 5, rows: 6)
        terminal.scroll(toTopRow: 0)
        #expect(terminal.scrollProjection.isFollowing == false)

        terminal.resize(columns: 10, rows: 6)

        #expect(terminal.scrollProjection.isFollowing == false)
        #expect(terminal.viewportText.contains("history-0"))
        expectValidGrid(terminal)
    }

    @Test("reset prevents a later width from restoring the ended layout")
    func resetEndsWidthSeries() throws {
        for reset in [[UInt8](arrayLiteral: 0x1B, 0x63), Array("\u{001B}[!p".utf8)] {
            var terminal = try makeComposerFixture()
            terminal.resize(columns: 5, rows: 6)
            terminal.feed(reset)
            var explicitlyEnded = terminal
            explicitlyEnded.scroll(byRows: 0)

            terminal.resize(columns: 10, rows: 6)
            explicitlyEnded.resize(columns: 10, rows: 6)

            #expect(terminal == explicitlyEnded)
            expectValidGrid(terminal)
        }
    }

    @Test("a primary width series survives alternate-screen output")
    func alternateOutputDoesNotEndPrimaryWidthSeries() throws {
        var terminal = try makeComposerFixture()
        let viewport = terminal.screenText
        let cursor = terminal.geometry.cursor
        let scrollbackRows = terminal.scrollbackRowCount
        let fullHistory = terminal.fullHistoryText

        terminal.feed(Array("\u{001B}[?1047h".utf8))
        terminal.resize(columns: 5, rows: 6)
        terminal.feed(Array("alternate output".utf8))
        terminal.resize(columns: 10, rows: 6)
        terminal.moveCursor(row: 2, column: 7)
        terminal.feed(Array("\u{001B}[?1047l".utf8))

        #expect(terminal.screenText == viewport)
        #expect(terminal.geometry.cursor == cursor)
        #expect(terminal.scrollbackRowCount == scrollbackRows)
        #expect(terminal.fullHistoryText == fullHistory)
        expectValidGrid(terminal)
    }

    @Test("screen transitions end an existing primary width series")
    func screenTransitionEndsWidthSeries() throws {
        var terminal = try makeComposerFixture()
        terminal.resize(columns: 5, rows: 6)
        let historyBeforeTransition = terminal.scrollbackRowCount
        terminal.feed(Array("\u{001B}[?1047h".utf8))
        terminal.moveCursor(row: 5, column: 0)
        terminal.feed(Array("\u{001B}[?1047l".utf8))
        var explicitlyEnded = terminal
        explicitlyEnded.scroll(byRows: 0)

        terminal.resize(columns: 10, rows: 6)
        explicitlyEnded.resize(columns: 10, rows: 6)

        #expect(terminal == explicitlyEnded)
        #expect(terminal.geometry.cursor?.row == 3)
        #expect(terminal.scrollbackRowCount < historyBeforeTransition)
        expectValidGrid(terminal)
    }

    @Test("eviction clamps a width-series viewport to retained content")
    func widthSeriesClampsAfterEviction() throws {
        var terminal = try makeComposerFixture()
        terminal.resize(columns: 3, rows: 6)
        terminal.evictScrollbackRowsForTesting(Int.max)
        let retainedHistory = terminal.fullHistoryText

        terminal.resize(columns: 10, rows: 6)

        #expect(terminal.fullHistoryText == retainedHistory)
        #expect(terminal.viewportText.contains("compose"))
        #expect(terminal.viewportText.contains("history-0") == false)
        expectValidGrid(terminal)
    }

    @Test("continuation growth above the cursor consumes its bottom-row distance")
    func widthShrinkCountsAllContinuationsAboveCursor() throws {
        // Intent: count reflow growth from every viewport line at or above
        //   the cursor when deriving its new distance from the bottom.
        // Why it exists: counting only the cursor's logical line appended an
        //   extra blank and displaced a second source row into scrollback.
        // Scenario: two full hard lines above a cursor each gain a continuation
        //   row when the viewport narrows from six columns to three.
        var terminal = try #require(Terminal(columns: 6, rows: 4))
        terminal.feed(Array("abcdef\r\nghijkl\r\nm".utf8))
        #expect(terminal.geometry.cursor?.row == 2)

        terminal.resize(columns: 3, rows: 4)

        #expect(terminal.scrollbackRowCount == 1)
        #expect(terminal.screenText == "def\nghi\njkl\nm  ")
        #expect(terminal.geometry.cursor?.row == 3)
    }

    @Test("post-clear shrink keeps history out and overflow shrink moves only top rows")
    func widthShrinkViewportBoundaries() throws {
        var cleared = try #require(Terminal(columns: 4, rows: 2))
        cleared.feed(Array("a\r\nb\r\nc".utf8))
        cleared.feed(Array("\u{001B}[2J".utf8))
        #expect(cleared.scrollbackRowCount == 1)
        cleared.resize(columns: 2, rows: 2)
        #expect(cleared.scrollbackRowCount == 1)
        #expect(cleared.screenText == "  \n  ")

        var overflow = try #require(Terminal(columns: 6, rows: 2))
        overflow.feed(Array("top\r\nabcdef".utf8))
        overflow.resize(columns: 3, rows: 2)
        #expect(overflow.scrollbackRowCount == 1)
        #expect(overflow.scrollbackRow(at: 0)?.isSoftWrapped == false)
        #expect(overflow.screenText == "abc\ndef")
    }

    @Test("odd and even widths create and remove spacer heads without splitting wide cells")
    func spacerRoundTripAcrossWidths() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("ab\u{754C}c".utf8))
        let expected = terminal.fullHistoryText

        terminal.resize(columns: 3, rows: 3)
        #expect(terminal.geometry.rows[0].cells.last?.kind == .spacerHead)
        expectValidGrid(terminal)
        terminal.resize(columns: 4, rows: 3)
        #expect(terminal.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .narrow, .wideHead, .wideTail,
        ])
        #expect(terminal.fullHistoryText == expected)
        expectValidGrid(terminal)

        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        var cluster = try #require(Terminal(columns: 6, rows: 3))
        cluster.feed(Array(("a" + family + "b").utf8))
        cluster.resize(columns: 2, rows: 3)
        #expect(cluster.geometry.rows[0].cells.last?.kind == .spacerHead)
        #expect(cluster.cell(row: 1, column: 0)?.scalars == TerminalScalars(family.unicodeScalars))
        expectValidGrid(cluster)
    }

    @Test("width growth pulls reflowed history into the viewport")
    func widthGrowthPullsHistory() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("abcdefgh".utf8))
        terminal.feed(Array("ij".utf8))
        #expect(terminal.scrollbackRowCount == 1)

        terminal.resize(columns: 8, rows: 2)

        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.screenText == "abcdefgh\nij      ")
    }

    @Test("effective resize closes a cluster but preserves partial UTF-8 and CSI input")
    func effectiveResizeStreamSemantics() throws {
        var utf8 = try #require(Terminal(columns: 4, rows: 2))
        utf8.feed([0xE7, 0x95])
        utf8.resize(columns: 5, rows: 2)
        utf8.feed([0x8C])
        #expect(utf8.cell(row: 0, column: 0)?.scalars == ["\u{754C}".unicodeScalars.first!])

        var csi = try #require(Terminal(columns: 4, rows: 2))
        csi.feed(Array("x\u{001B}[2;".utf8))
        csi.resize(columns: 5, rows: 3)
        csi.feed(Array("5Hq".utf8))
        #expect(csi.cell(row: 1, column: 4)?.scalars == ["q".unicodeScalars.first!])

        var cluster = try #require(Terminal(columns: 4, rows: 2))
        cluster.feed(Array("a".utf8))
        cluster.resize(columns: 5, rows: 2)
        cluster.feed(Array("\u{0301}".utf8))
        #expect(cluster.cell(row: 0, column: 0)?.scalars == ["a".unicodeScalars.first!])
    }

    @Test("interleaved random resize and input preserves a valid grid")
    func resizeFuzzMaintainsGridValidity() throws {
        let alphabet: [UInt8] = Array("ab \u{754C}\u{1F642}\r\n\u{001B}[2J".utf8)
        for seed in UInt64(1)...128 {
            var generator = SeededByteGenerator(state: seed)
            var terminal = try #require(Terminal(columns: 7, rows: 3))
            for _ in 0..<128 {
                if generator.nextByte().isMultiple(of: 4) {
                    let history = terminal.fullHistoryText
                    terminal.resize(
                        columns: Int(generator.nextByte() % 10),
                        rows: Int(generator.nextByte() % 6)
                    )
                    #expect(terminal.fullHistoryText == history)
                } else {
                    terminal.feed([alphabet[Int(generator.nextByte()) % alphabet.count]])
                }
                expectValidGrid(terminal)
            }
            terminal.feed([0x18, 0x7C])
            #expect(terminal.screenText.contains("|"))
        }
    }

    private func makeComposerFixture() throws -> Terminal {
        var terminal = try #require(Terminal(columns: 10, rows: 6))
        terminal.feed(Array("history-0\r\nhistory-1\r\nhistory-2\r\nhistory-3\r\nhistory-4\r\nhistory-5\r\n".utf8))
        terminal.feed(Array("\u{001B}[2J".utf8))
        terminal.moveCursor(row: 0, column: 0)
        terminal.feed(Array("ABCDEFGHIJ".utf8))
        terminal.moveCursor(row: 1, column: 0)
        terminal.feed(Array("KLMNOPQRST".utf8))
        terminal.moveCursor(row: 2, column: 0)
        terminal.feed(Array("compose".utf8))
        return terminal
    }
}
