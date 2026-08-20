// Logical-damage producer proofs for bounded, drainable viewport redraw state.

import Testing
@testable import TerminalCore

/// Pins terminal mutations to the conservative row-granular damage contract.
struct TerminalDamageTests {
    @Test("consumer-work generation covers every pending category and re-arms after drain")
    func consumerWorkGenerationCategoriesAndRearming() throws {
        // Intent: a cheap generation token identifies every feed that changes pending consumer work.
        // Why it exists: the PTY host must stop copying the full terminal without changing wakeups.
        // Scenario: independent and combined redraw, clipboard, coalesced semantic, and discrete
        //   mutations accumulate, drain, and then advance the generation again -- and a feed that
        //   adds no new pending work leaves the token where it was, which is the half of the
        //   contract that keeps the host from waking once per read.
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        _ = terminal.drainDamage()

        func verify(_ bytes: [UInt8], terminal: inout Terminal) {
            let generation = terminal.pendingConsumerWorkGeneration
            terminal.feed(bytes)
            #expect(terminal.pendingConsumerWorkGeneration != generation)
        }

        verify(Array("A".utf8), terminal: &terminal)
        _ = terminal.drainDamage()
        verify(Array("\u{1B}]52;c;aGVsbG8=\u{07}".utf8), terminal: &terminal)
        _ = terminal.drainPendingClipboardWrite()
        verify(Array("\u{1B}]52;c;\u{07}".utf8), terminal: &terminal)
        _ = terminal.drainPendingClipboardWrite()
        verify(Array("\u{1B}]2;first\u{07}\u{1B}]2;second\u{07}".utf8), terminal: &terminal)
        _ = terminal.drainSemanticEvents()
        verify(Array("\u{1B}]7;file://localhost/a\u{07}\u{1B}]7;file://localhost/b\u{07}".utf8), terminal: &terminal)
        _ = terminal.drainSemanticEvents()
        verify(Array("\u{1B}]9;4;1;10\u{07}\u{1B}]9;4;1;20\u{07}".utf8), terminal: &terminal)
        _ = terminal.drainSemanticEvents()
        verify(Array("\u{07}\u{1B}]777;notify;title;body\u{07}".utf8), terminal: &terminal)
        _ = terminal.drainSemanticEvents()
        verify(Array("Z\u{1B}]52;c;YQ==\u{07}\u{1B}]2;title\u{07}\u{07}".utf8), terminal: &terminal)

        let alreadySignaled = terminal.pendingConsumerWorkGeneration
        terminal.feed(Array("more\u{07}\u{1B}]2;newer\u{07}".utf8))
        #expect(terminal.pendingConsumerWorkGeneration != alreadySignaled)
        _ = terminal.drainDamage()
        _ = terminal.drainPendingClipboardWrite()
        _ = terminal.drainSemanticEvents()
        verify(Array("again".utf8), terminal: &terminal)

        // Negative legs. Without these the suite is satisfied by a regression that bumps the
        // generation on every `feed`, which would restore a wakeup per read.
        _ = terminal.drainDamage()
        _ = terminal.drainPendingClipboardWrite()
        _ = terminal.drainSemanticEvents()
        let quiescent = terminal.pendingConsumerWorkGeneration
        // An unrecognized CSI final falls through `dispatchCSI` and mutates nothing.
        terminal.feed(Array("\u{1B}[9z".utf8))
        #expect(terminal.pendingConsumerWorkGeneration == quiescent)
        // A print into an already-damaged row re-sets a bit that is already set, so
        // `TerminalDamage.record(row:)` returns false and nothing bumps. Both prints
        // stay on the same row so neither can scroll and escalate to full damage.
        terminal.feed(Array("\u{1B}[1;1HP".utf8))
        let damagedRow = terminal.pendingConsumerWorkGeneration
        terminal.feed(Array("\u{1B}[1;3HQ".utf8))
        #expect(terminal.pendingConsumerWorkGeneration == damagedRow)
    }

    @Test("row damage crosses storage word boundaries without changing public indexes")
    func rowDamageWordBoundaries() throws {
        var terminal = try #require(Terminal(columns: 2, rows: 130))
        _ = terminal.drainDamage()

        terminal.feed(Array("\u{1B}[63;1HA\u{1B}[66;1HB\u{1B}[130;1HC".utf8))

        #expect(terminal.drainDamage() == TerminalDamage(rows: [0, 62, 65, 129]))
        #expect(terminal.drainDamage() == .none)
    }

    @Test("full damage discards previously accumulated row distinctions")
    func fullDamageCanonicalizesRows() throws {
        var first = try #require(Terminal(columns: 3, rows: 3))
        var second = first
        _ = first.drainDamage()
        _ = second.drainDamage()
        first.feed(Array("\u{1B}[2;1H\u{1B}[1;1H".utf8))

        first.feed(Array("\u{1B}[?1049h".utf8))
        second.feed(Array("\u{1B}[?1049h".utf8))

        #expect(first == second)
        #expect(first.drainDamage() == .full)
        #expect(second.drainDamage() == .full)
    }

    @Test("fresh damage drains once and repeated drains stay empty")
    func drainCanonicality() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 3))

        #expect(terminal.drainDamage() == .full)
        #expect(terminal.drainDamage() == .none)
    }

    @Test("printing and cursor movement damage only affected viewport rows")
    func printAndCursorDamage() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 4))
        _ = terminal.drainDamage()

        terminal.feed(Array("A".utf8))
        #expect(terminal.drainDamage() == TerminalDamage(rows: [0]))

        terminal.feed(Array("\u{1B}[3;1H".utf8))
        #expect(terminal.drainDamage() == TerminalDamage(rows: [0, 2]))

        terminal.feed(Array("\u{1B}[C".utf8))
        #expect(terminal.drainDamage() == TerminalDamage(rows: [2]))
    }

    @Test("selection changes damage the old and new selected row spans")
    func selectionDamage() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 4))
        terminal.feed(Array("one\r\ntwo\r\nthree".utf8))
        _ = terminal.drainDamage()

        terminal.setSelection(
            TerminalTextRange(
                start: TerminalTextPosition(row: 0, column: 0),
                end: TerminalTextPosition(row: 2, column: 2)
            )
        )
        #expect(terminal.drainDamage() == TerminalDamage(rows: [0, 1, 2]))

        terminal.setSelection(
            TerminalTextRange(
                start: TerminalTextPosition(row: 2, column: 0),
                end: TerminalTextPosition(row: 2, column: 2)
            )
        )
        #expect(terminal.drainDamage() == TerminalDamage(rows: [0, 1, 2]))

        terminal.clearSelection()
        #expect(terminal.drainDamage() == TerminalDamage(rows: [2]))
    }

    @Test("erase and scroll-region edits remain confined to changed rows")
    func editingDamage() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 5))
        terminal.feed(Array("a\r\nb\r\nc\r\nd".utf8))
        _ = terminal.drainDamage()

        terminal.feed(Array("\u{1B}[2;1H\u{1B}[2K".utf8))
        #expect(terminal.drainDamage() == TerminalDamage(rows: [1, 3]))

        terminal.feed(Array("\u{1B}[2;4r\u{1B}[2;1H".utf8))
        _ = terminal.drainDamage()
        terminal.feed(Array("\u{1B}[1M".utf8))
        // Delete-line is a scroll of rows 1..<4: since research/33 T9 the drained
        // value carries the translation plus the vacated row and the cursor row,
        // not the whole moved range.
        let deleted = terminal.drainDamage()
        #expect(deleted.shift == TerminalDamageShift(region: 1..<4, delta: -1))
        #expect(deleted.rowIndices == [1, 3])
    }

    @Test("mapping and whole-screen mutations escalate to full damage")
    func fullDamageEscalation() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("1\r\n2\r\n3\r\n4".utf8))
        _ = terminal.drainDamage()

        terminal.scroll(toTopRow: 0)
        #expect(terminal.drainDamage() == .full)

        terminal.feed(Array("X".utf8))
        #expect(terminal.drainDamage() == .full)

        terminal.scrollToBottom()
        #expect(terminal.drainDamage() == .full)
        terminal.scrollToBottom()
        #expect(terminal.drainDamage() == .none)

        terminal.feed(Array("\u{1B}[?1049h".utf8))
        #expect(terminal.drainDamage() == .full)
        terminal.feed(Array("\u{1B}c".utf8))
        #expect(terminal.drainDamage() == .full)

        terminal.resize(columns: 7, rows: 3)
        #expect(terminal.drainDamage() == .full)
        terminal.resize(columns: 7, rows: 3)
        #expect(terminal.drainDamage() == .none)
    }

    @Test("alternate cursor damage covers old and new rows over non-empty primary scrollback")
    func alternateCursorDamageOverScrollback() throws {
        // Intent: with the alternate screen active over non-empty primary scrollback, moving
        //   the cursor damages both the row it left and the row it entered.
        // Why it exists: `damageActionSnapshot` projects the cursor through the same
        //   primary-vs-alternate branch as `geometry`, and this suite otherwise uses the
        //   alternate screen only to prove full-damage escalation. Inverted, the projected
        //   row leaves the viewport, the snapshot cursor reads nil, and the vacated row is
        //   simply never repainted -- a stale cursor no assertion here would catch.
        // Scenario: a full-screen program moves its cursor down a line after the session has
        //   already scrolled output into history.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("ABCDEFGHI".utf8))
        #expect(terminal.scrollbackRowCount > 0)

        terminal.feed(Array("\u{1B}[?1047h\u{1B}[1;1H".utf8))
        _ = terminal.drainDamage()

        terminal.feed(Array("\u{1B}[2;1H".utf8))
        #expect(terminal.drainDamage() == TerminalDamage(rows: [0, 1]))
    }

    @Test("damage accumulation is canonical bounded and chunk invariant")
    func accumulationAndChunkInvariance() throws {
        var oneChunk = try #require(Terminal(columns: 6, rows: 4))
        var byteChunks = oneChunk
        _ = oneChunk.drainDamage()
        _ = byteChunks.drainDamage()
        let bytes = Array("ab\u{1B}[3;1Hc\u{1B}[1;1H".utf8)

        oneChunk.feed(bytes)
        for byte in bytes {
            byteChunks.feed([byte])
        }

        #expect(oneChunk == byteChunks)
        #expect(oneChunk.drainDamage() == TerminalDamage(rows: [0, 2]))
        #expect(byteChunks.drainDamage() == TerminalDamage(rows: [0, 2]))
    }

    @Test("a region-mismatch escalation keeps recording damage for the live grid")
    func mismatchedShiftRegionsEscalateAndKeepRecording() throws {
        // Intent: after two scroll regions collide into full damage and that full damage
        //   drains, the terminal still records ordinary row damage for the same grid.
        // Why it exists: the escalation branch is shared with the value-level `formUnion`,
        //   where "become full" may be spelled as an assignment of the static `.full`.
        //   That value carries a zero-height bitset, so a producer spelled the same way
        //   would silently refuse every row recorded after the drain and the pane would
        //   stop repainting.
        var terminal = try #require(Terminal(columns: 8, rows: 12))
        terminal.feed(Array("\u{1B}[3;10r\u{1B}[10;1H".utf8))
        _ = terminal.drainDamage()

        terminal.feed(Array("\r\n".utf8))
        terminal.feed(Array("\u{1B}[2;12r\u{1B}[12;1H".utf8))
        terminal.feed(Array("\r\n".utf8))
        #expect(terminal.drainDamage() == .full)

        terminal.feed(Array("\u{1B}[1;1HX".utf8))
        let damage = terminal.drainDamage()
        #expect(damage.isFull == false)
        #expect(damage.contains(row: 0))
    }

    @Test("a shift reports its own change to the consumer-work generation")
    func shiftReportsChangeToConsumerWorkGeneration() throws {
        // Intent: recording a scroll translation bumps the consumer-work generation when
        //   it changes pending damage, and leaves it alone when it does not.
        // Why it exists: the suites that read drained damage cannot see this contract at
        //   all, so a recording path that reported nothing would still leave them green
        //   while the PTY host stopped waking for a scroll.
        // Scenario: eight one-line scrolls of an eight-row DECSTBM region. The eighth
        //   collapses the summed shift into region-wide rows, which pre-fills the vacated
        //   row and both cursor rows -- so the shift is the only change left to report.
        var terminal = try #require(Terminal(columns: 8, rows: 12))
        terminal.feed(Array("\u{1B}[3;10r\u{1B}[10;1H".utf8))
        _ = terminal.drainDamage()
        for _ in 0..<7 { terminal.feed(Array("\r\n".utf8)) }

        let beforeCollapse = terminal.pendingConsumerWorkGeneration
        terminal.feed(Array("\r\n".utf8))
        #expect(terminal.pendingConsumerWorkGeneration != beforeCollapse)

        // The negative leg: with pending damage already escalated to full, a further
        // scroll adds nothing a consumer can act on and must not wake one.
        terminal.feed(Array("\u{1B}[?1049h\u{1B}[12;1H".utf8))
        let alreadyFull = terminal.pendingConsumerWorkGeneration
        terminal.feed(Array("\r\n".utf8))
        #expect(terminal.pendingConsumerWorkGeneration == alreadyFull)
    }

    // The negative-row sanitizer test that used to close this suite is gone with the
    // sanitizer itself: the word-backed representation cannot hold an out-of-range row,
    // and `TerminalShiftDamageTests.outOfRangeRowsAreUnrepresentable` pins the traps
    // that replaced the silent filter.
}
