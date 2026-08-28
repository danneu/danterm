// Local viewport navigation, anchoring, and logical window projection proofs.
import Testing

@testable import TerminalCore

/// Locks local-window state to retained logical content independently of live-grid mutation.
struct TerminalViewportTests {
    @Test("default viewport follows the live grid and navigation selects stream windows")
    func navigationAndFollowingProjection() throws {
        var terminal = try makeLineHistory()

        #expect(terminal.scrollProjection == TerminalScrollProjection(
            totalRows: 5,
            topRow: 2,
            windowRows: 3,
            isFollowing: true
        ))
        #expect(terminal.screenText == "c   \nd   \ne   ")

        terminal.scroll(byRows: -2)

        #expect(terminal.scrollProjection == TerminalScrollProjection(
            totalRows: 5,
            topRow: 0,
            windowRows: 3,
            isFollowing: false
        ))
        #expect(terminal.screenText == "a   \nb   \nc   ")
        #expect(terminal.geometry.cursor == nil)
        #expect(terminal.viewportText == "a\nb\nc")

        terminal.scroll(toTopRow: 1)
        #expect(terminal.scrollProjection.topRow == 1)
        #expect(terminal.scrollProjection.isFollowing == false)

        terminal.scroll(byRows: Int.min)
        #expect(terminal.scrollProjection.topRow == 0)
        terminal.scroll(byRows: Int.max)
        #expect(terminal.scrollProjection.isFollowing)

        terminal.scroll(toTopRow: 10_000)
        #expect(terminal.scrollProjection.topRow == 2)
        #expect(terminal.scrollProjection.isFollowing)
    }

    @Test("browsing is a content-neutral lens and output leaves its top row stable")
    func outputPreservesBrowsingAnchorAndContent() throws {
        // Intent: navigation changes only the presented window, and later output
        //   leaves a browsing anchor on the same retained logical row.
        // Why it exists: viewport state participates in Terminal equality, so a
        //   lens proof must distinguish semantic viewport state from grid state.
        // Scenario: a user scrolls to the oldest retained line while a command
        //   continues printing, then returns to the prompt.
        var following = try makeLineHistory()
        var browsing = following
        browsing.scroll(toTopRow: 0)

        following.feed(Array("\r\nf\r\ng".utf8))
        browsing.feed(Array("\r\nf\r\ng".utf8))

        #expect(browsing.screenText == "a   \nb   \nc   ")
        #expect(browsing.scrollProjection.isFollowing == false)
        #expect(browsing.fullHistoryText == following.fullHistoryText)
        #expect(browsing.primaryHistoryText == following.primaryHistoryText)
        #expect(browsing.pendingReplyBytes == following.pendingReplyBytes)

        browsing.scrollToBottom()
        // Pending damage is path-dependent since research/33 T9: the following
        // copy accumulated its scrolls as a shift while the browsing copy
        // escalated to `.full`, so the lens proof compares drained values.
        _ = browsing.drainDamage()
        _ = following.drainDamage()
        #expect(browsing == following)
    }

    @Test("width and height changes remap a retained browsing anchor without following")
    func resizePreservesBrowsingAnchor() throws {
        // Intent: reflow attaches the viewport top to its source row, including
        //   blank retained rows, while height changes only re-fit the window.
        // Why it exists: selection attachment is partial over trailing blanks;
        //   viewport anchoring requires the total per-row reflow metadata path.
        // Scenario: a user browses wrapped output and then resizes a pane twice.
        var wrapped = try #require(Terminal(columns: 4, rows: 3))
        wrapped.feed(Array("abcdefghijklmnopqrst".utf8))
        wrapped.scroll(toTopRow: 1)

        wrapped.resize(columns: 2, rows: 3)
        #expect(wrapped.screenText == "ef\ngh\nij")
        #expect(wrapped.scrollProjection.totalRows == 10)
        #expect(wrapped.scrollProjection.topRow == 2)
        #expect(wrapped.scrollProjection.isFollowing == false)

        wrapped.resize(columns: 4, rows: 3)
        #expect(wrapped.screenText == "efgh\nijkl\nmnop")
        #expect(wrapped.scrollProjection.totalRows == 5)
        #expect(wrapped.scrollProjection.topRow == 1)
        #expect(wrapped.scrollProjection.isFollowing == false)

        var blanks = try #require(Terminal(columns: 4, rows: 4))
        blanks.moveCursor(row: 3, column: 0)
        blanks.resize(columns: 4, rows: 1)
        blanks.scroll(toTopRow: 1)
        blanks.resize(columns: 2, rows: 1)
        #expect(blanks.scrollProjection.topRow == 1)
        #expect(blanks.scrollProjection.isFollowing == false)

        var height = try makeLineHistory()
        height.scroll(toTopRow: 1)
        height.resize(columns: 4, rows: 2)
        #expect(height.scrollProjection.topRow == 1)
        #expect(height.scrollProjection.isFollowing == false)
        height.resize(columns: 4, rows: 4)
        #expect(height.scrollProjection.topRow == 1)
        #expect(height.scrollProjection.isFollowing == false)
    }

    @Test("height growth that absorbs all history resumes bottom follow")
    func heightGrowthRestoresBottomFollow() throws {
        var height = try makeLineHistory()
        height.scroll(toTopRow: 1)

        height.resize(columns: 4, rows: 5)
        #expect(height.scrollProjection.topRow == 0)
        #expect(height.scrollProjection.isFollowing)
        height.feed(Array("\r\nf".utf8))
        #expect(height.scrollProjection.isFollowing)
        #expect(height.screenText.hasSuffix("f   "))
    }

    @Test("eviction keeps browsing while older retained content remains")
    func evictionClampsBrowsingAnchor() throws {
        var terminal = try #require(Terminal(
            columns: 4,
            rows: 3,
            scrollbackBudgetBytes: historyBudget(lines: 2, cells: 1, paneColumns: 4)
        ))
        terminal.feed(Array("a\r\nb\r\nc\r\nd\r\ne".utf8))
        terminal.scroll(toTopRow: 0)

        terminal.feed(Array("\r\nf\r\ng\r\nh".utf8))

        #expect(terminal.scrollProjection.topRow == 0)
        #expect(terminal.scrollProjection.isFollowing == false)
        #expect(terminal.scrollbackRowCount <= 2)
    }

    @Test("absolute viewport top row stays monotone across history eviction")
    func absoluteViewportTopRowSurvivesEviction() throws {
        // Intent: `absoluteViewportTopRow` counts every line the following viewport
        //   has scrolled past, in the same eviction-corrected coordinates anchors pin.
        // Why it exists: `scrollProjection.topRow` is retained-relative and plateaus
        //   once eviction begins, so a sampler diffing it under-reads a long stream;
        //   the absolute form is what makes scrolled-lines-per-delivery a plain delta.
        // Scenario: a stream outgrows a two-line budget while the viewport follows.
        var terminal = try #require(Terminal(
            columns: 4,
            rows: 3,
            scrollbackBudgetBytes: historyBudget(lines: 2, cells: 1, paneColumns: 4)
        ))
        terminal.feed(Array("a\r\nb\r\nc".utf8))
        #expect(terminal.absoluteViewportTopRow == 0)

        terminal.feed(Array("\r\nd\r\ne".utf8))
        #expect(terminal.absoluteViewportTopRow == 2)

        terminal.feed(Array("\r\nf\r\ng\r\nh\r\ni".utf8))
        #expect(terminal.absoluteViewportTopRow == 6)
        #expect(terminal.scrollProjection.topRow < 6)
    }

    @Test("history wipe returns a displaced browsing viewport to live-bottom follow")
    func historyWipeRestoresBottomFollow() throws {
        // Intent: a history wipe that destroys the browse anchor resumes live-bottom follow.
        // Why it exists: codex clears and reprints its inline transcript after SIGWINCH; keeping
        //   the now-unaddressable anchor strands that repaint below the visible window.
        // Scenario: the captured repaint shape clears retained history before emitting a fresh
        //   transcript, as codex 0.146.1 did when a split resized its PTY.
        var terminal = try makeLineHistory()
        terminal.scroll(toTopRow: 1)
        _ = terminal.drainDamage()

        terminal.feed(Array("\u{1B}[r\u{1B}[H\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8))
        #expect(terminal.scrollbackRowCount == 0)
        #expect(terminal.scrollProjection.topRow == 0)
        #expect(terminal.scrollProjection.isFollowing)
        #expect(terminal.drainDamage() == .full)

        terminal.feed(Array("new0\r\nnew1\r\nnew2\r\nnew3".utf8))
        #expect(terminal.scrollProjection.isFollowing)
        #expect(terminal.screenText == "new1\nnew2\nnew3")
    }

    @Test("width reflow that displaces browsing onto the newest window resumes follow")
    func shorteningWidthReflowRestoresBottomFollow() throws {
        var reflow = try #require(Terminal(
            columns: 2,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lines: 20, cells: 40)
        ))
        reflow.feed(Array("abcdefghijklmnopqrstuvwxyz012345".utf8))
        reflow.scroll(toTopRow: 10)
        let rowsBeforeReflow = reflow.scrollProjection.totalRows
        reflow.resize(columns: 8, rows: 2)
        #expect(reflow.scrollProjection.totalRows < rowsBeforeReflow)
        #expect(reflow.scrollProjection.topRow == 2)
        #expect(reflow.scrollProjection.isFollowing)

        reflow.feed(Array("\r\nZ".utf8))
        #expect(reflow.scrollProjection.isFollowing)
        #expect(reflow.screenText.hasSuffix("Z       "))
    }

    @Test("screen replacements reset browsing while primary soft reset and no-op modes preserve it")
    func screenReplacementClassification() throws {
        var terminal = try makeLineHistory()
        terminal.scroll(toTopRow: 0)

        terminal.feed(Array("\u{1B}[!p\u{1B}[?2047h\u{1B}[?1047l\u{1B}[?1049l".utf8))
        #expect(terminal.scrollProjection.isFollowing == false)

        terminal.feed(Array("\u{1B}[?1047h".utf8))
        #expect(terminal.scrollProjection == TerminalScrollProjection(
            totalRows: 3,
            topRow: 0,
            windowRows: 3,
            isFollowing: true
        ))
        let alternate = terminal
        terminal.scroll(byRows: -1)
        terminal.scroll(toTopRow: 0)
        #expect(terminal == alternate)

        terminal.feed(Array("\u{1B}[?1047l".utf8))
        #expect(terminal.scrollProjection.isFollowing)
        #expect(terminal.scrollProjection.topRow == terminal.scrollbackRowCount)

        terminal.scroll(toTopRow: 0)
        terminal.feed([0x1B, 0x63])
        #expect(terminal.scrollProjection.isFollowing)
    }

    @Test("search reveal minimally moves the viewport and never enables follow")
    func searchRevealAndInspectionRetention() throws {
        var terminal = try makeLineHistory()
        terminal.setSelection(
            from: TerminalTextPosition(row: 1, column: 0),
            to: TerminalTextPosition(row: 1, column: 0)
        )

        var found = terminal.beginSearch("a")
        #expect(found)
        #expect(terminal.scrollProjection.topRow == 0)
        #expect(terminal.scrollProjection.isFollowing == false)
        #expect(terminal.selectionRange != nil)

        found = terminal.beginSearch("e")
        #expect(found)
        #expect(terminal.scrollProjection.topRow == 2)
        #expect(terminal.scrollProjection.isFollowing == false)
        #expect(terminal.searchReadout?.activeMatch != nil)

        terminal.resize(columns: 4, rows: 2)
        #expect(terminal.scrollProjection.topRow == 2)
        #expect(terminal.scrollProjection.isFollowing == false)
        terminal.feed(Array("\r\nf".utf8))
        #expect(terminal.scrollProjection.topRow == 2)
        #expect(terminal.scrollProjection.isFollowing == false)

        terminal.scroll(byRows: -1)
        #expect(terminal.selectionRange != nil)
        #expect(terminal.searchReadout?.activeMatch != nil)

        let beforeReply = terminal.scrollProjection
        terminal.feed(Array("\u{1B}[5n".utf8))
        #expect(terminal.pendingReplyBytes.isEmpty == false)
        _ = terminal.drainReplyBytes()
        #expect(terminal.scrollProjection == beforeReply)

        let beforeFailure = terminal.scrollProjection
        found = terminal.beginSearch("missing")
        #expect(found == false)
        #expect(terminal.scrollProjection == beforeFailure)
    }

    @Test("search navigation reveals above below and already-visible matches minimally")
    func searchNavigationReveal() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("hit0\r\nline\r\nhit1\r\nline\r\nhit2".utf8))

        var moved = terminal.beginSearch("hit")
        #expect(moved)
        #expect(terminal.scrollProjection.isFollowing)

        moved = terminal.searchNext()
        #expect(moved)
        #expect(terminal.scrollProjection.topRow == 2)
        #expect(terminal.scrollProjection.isFollowing == false)

        let visibleTop = terminal.scrollProjection.topRow
        moved = terminal.searchPrevious()
        #expect(moved)
        #expect(terminal.scrollProjection.topRow == 3)
        #expect(terminal.scrollProjection.isFollowing == false)

        terminal.scroll(toTopRow: visibleTop)
        moved = terminal.beginSearch("hit1")
        #expect(moved)
        #expect(terminal.scrollProjection.topRow == visibleTop)
        #expect(terminal.scrollProjection.isFollowing == false)
    }

    @Test("viewport text joins soft wraps and omits grid padding for each selected window")
    func logicalViewportText() throws {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("abcdef\r\nx\r\ny".utf8))

        #expect(terminal.screenText == "ef  \nx   \ny   ")
        #expect(terminal.viewportText == "ef\nx\ny")
        let fullHistory = terminal.fullHistoryText

        terminal.scroll(toTopRow: 0)

        #expect(terminal.screenText == "abcd\nef  \nx   ")
        #expect(terminal.viewportText == "abcdef\nx")
        #expect(terminal.fullHistoryText == fullHistory)
    }

    @Test("equal terminal reductions expose equal scroll projections")
    func chunkInvariantScrollProjection() throws {
        var oneChunk = try #require(Terminal(columns: 4, rows: 2))
        var split = oneChunk
        oneChunk.feed(Array("a\r\nb\r\nc".utf8))
        split.feed(Array("a\r\n".utf8))
        split.feed(Array("b\r\nc".utf8))

        #expect(oneChunk == split)
        #expect(oneChunk.scrollProjection == split.scrollProjection)

        split.scroll(toTopRow: 0)
        #expect(oneChunk != split)
    }

    @Test("shared grid assertions remain valid for a scrolled wide-cell window")
    func scrolledGridStructure() throws {
        var terminal = try #require(Terminal(columns: 3, rows: 2))
        terminal.feed(Array("ab\u{754C}cd\u{754C}ef\u{754C}".utf8))
        terminal.scroll(toTopRow: 0)

        expectValidGrid(terminal)
    }

    @Test("readers and the damage snapshot see one window in every viewport configuration")
    func projectionAgreesWithDamageSnapshot() throws {
        // Intent: the projection a reader gets from `scrollProjection` is the projection the
        //   per-action damage snapshot decides with, on both screens, following and browsing,
        //   with and without evicted history.
        // Why it exists: the two now derive the window from one function so the feed path stops
        //   copying a whole terminal per parser action (`research/39/H3`). If the derivation and
        //   the getter ever drifted apart, a following viewport would publish full damage or a
        //   browsing one would publish rows, and no reader assertion alone would show it.
        // Scenario: each configuration drains pending damage, prints one character, and is read
        //   for both the published window and the damage that window implies.
        func printOneCharacter(into terminal: inout Terminal) -> TerminalDamage {
            _ = terminal.drainDamage()
            terminal.feed(Array("x".utf8))
            return terminal.drainDamage()
        }

        var following = try makeLineHistory()
        #expect(following.scrollProjection == TerminalScrollProjection(
            totalRows: 5,
            topRow: 2,
            windowRows: 3,
            isFollowing: true
        ))
        let followingDamage = printOneCharacter(into: &following)
        #expect(followingDamage.isFull == false)
        #expect(followingDamage.rowIndices == [2])

        var browsing = try makeLineHistory()
        browsing.scroll(toTopRow: 0)
        #expect(browsing.scrollProjection == TerminalScrollProjection(
            totalRows: 5,
            topRow: 0,
            windowRows: 3,
            isFollowing: false
        ))
        #expect(printOneCharacter(into: &browsing) == .full)

        var evicted = try #require(Terminal(
            columns: 4,
            rows: 3,
            scrollbackBudgetBytes: historyBudget(lines: 2, cells: 1, paneColumns: 4)
        ))
        evicted.feed(Array("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng".utf8))
        #expect(evicted.scrollbackRowCount <= 2)
        #expect(evicted.absoluteViewportTopRow > evicted.scrollProjection.topRow)
        #expect(evicted.scrollProjection.isFollowing)
        let evictedDamage = printOneCharacter(into: &evicted)
        #expect(evictedDamage.isFull == false)
        #expect(evictedDamage.rowIndices == [2])

        var evictedBrowsing = evicted
        evictedBrowsing.scroll(toTopRow: 0)
        #expect(evictedBrowsing.scrollProjection.isFollowing == false)
        #expect(printOneCharacter(into: &evictedBrowsing) == .full)

        var alternate = try makeLineHistory()
        alternate.feed(Array("\u{1B}[?1049h".utf8))
        #expect(alternate.scrollProjection == TerminalScrollProjection(
            totalRows: 3,
            topRow: 0,
            windowRows: 3,
            isFollowing: true
        ))
        let alternateDamage = printOneCharacter(into: &alternate)
        #expect(alternateDamage.isFull == false)
    }

    private func makeLineHistory() throws -> Terminal {
        var terminal = try #require(Terminal(columns: 4, rows: 3))
        terminal.feed(Array("a\r\nb\r\nc\r\nd\r\ne".utf8))
        return terminal
    }
}
