// Logical-damage producer proofs for bounded, drainable viewport redraw state.

import Testing
@testable import TerminalCore

/// Pins terminal mutations to the conservative row-granular damage contract.
struct TerminalDamageTests {
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

        #expect(first.hasSamePendingConsumerWork(as: second))
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
}
