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
        //   mutations accumulate, drain, and then advance the generation again.
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
        #expect(terminal.drainDamage() == TerminalDamage(rows: [1, 2, 3]))
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

    @Test("row damage never carries a negative index, however it is built")
    func negativeRowsCannotEnterDamage() {
        // Intent: no `TerminalDamage` a consumer can construct or accumulate holds a
        //   negative row index.
        // Why it exists: `rows` is `private(set)`, so this filter plus `formUnion` are
        //   the only two ways rows enter -- and downstream consumers rely on it rather
        //   than re-checking. `terminalDamageMaximalContiguousSpanCount` used to guard
        //   `row == Int.min` before computing `row - 1`; that guard was deleted on the
        //   strength of this invariant, so if this test ever fails, the span helpers
        //   trap on overflow rather than merely miscounting.
        // Scenario: spec-first; no incident. The negative index is not a value any
        //   engine path produces, which is exactly why the invariant needs pinning
        //   rather than assuming.
        #expect(TerminalDamage(rows: [-1, 0, 3]).rows == [0, 3])
        #expect(TerminalDamage(rows: [Int.min]).rows.isEmpty)

        var accumulated = TerminalDamage(rows: [2])
        accumulated.formUnion(TerminalDamage(rows: [-5, 7]))
        #expect(accumulated.rows == [2, 7])
    }
}
