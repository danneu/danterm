// Row-intersection invalidation proofs for selection and active search state.
import Testing

@testable import TerminalCore

/// Exercises every retained-content mutation family against intersecting and disjoint anchors.
struct TerminalInspectionInvalidationTests {
    @Test("cell mutations clear intersecting inspection and preserve disjoint rows")
    func cellMutationMatrix() throws {
        let cases: [(name: String, intersecting: String, disjoint: String)] = [
            ("print", "\u{1B}[2;1HZ", "\u{1B}[4;1HZ"),
            ("REP", "\u{1B}[2;1H\u{1B}[b", "\u{1B}[4;1H\u{1B}[b"),
            ("ICH", "\u{1B}[2;2H\u{1B}[@", "\u{1B}[4;2H\u{1B}[@"),
            ("DCH", "\u{1B}[2;2H\u{1B}[P", "\u{1B}[4;2H\u{1B}[P"),
            ("ECH", "\u{1B}[2;2H\u{1B}[X", "\u{1B}[4;2H\u{1B}[X"),
            ("EL", "\u{1B}[2;2H\u{1B}[K", "\u{1B}[4;2H\u{1B}[K"),
            ("ED 0", "\u{1B}[2;2H\u{1B}[J", "\u{1B}[4;2H\u{1B}[J"),
            ("ED 1", "\u{1B}[2;2H\u{1B}[1J", "\u{1B}[1;2H\u{1B}[1J"),
        ]

        for mutation in cases {
            var intersecting = try makeSubject(selectedRow: 1)
            intersecting.feed(Array(mutation.intersecting.utf8))
            #expect(intersecting.selectionRange == nil, "\(mutation.name) kept selection")
            #expect(intersecting.activeSearchMatchRange == nil, "\(mutation.name) kept search")

            var disjoint = try makeSubject(selectedRow: 1)
            disjoint.feed(Array(mutation.disjoint.utf8))
            #expect(disjoint.selectionRange != nil, "\(mutation.name) cleared selection")
            #expect(disjoint.activeSearchMatchRange != nil, "\(mutation.name) cleared search")
        }
    }

    @Test("row rotations clear intersecting inspection and preserve rows outside their region")
    func rowMutationMatrix() throws {
        let sequences = [
            "\u{1B}[2;3r\u{1B}[2;1H\u{1B}[L",
            "\u{1B}[2;3r\u{1B}[2;1H\u{1B}[M",
            "\u{1B}[2;3r\u{1B}[S",
            "\u{1B}[2;3r\u{1B}[T",
            "\u{1B}[2;3r\u{1B}[2;1H\u{1B}M",
        ]

        for sequence in sequences {
            var intersecting = try makeSubject(selectedRow: 1)
            intersecting.feed(Array(sequence.utf8))
            #expect(intersecting.selectionRange == nil)
            #expect(intersecting.activeSearchMatchRange == nil)

            var disjoint = try makeSubject(selectedRow: 0)
            disjoint.feed(Array(sequence.utf8))
            #expect(disjoint.selectionRange != nil)
            #expect(disjoint.activeSearchMatchRange != nil)
        }
    }

    @Test("whole-screen mutations leave scrollback inspection alone")
    func wholeScreenMutationScope() throws {
        for sequence in ["\u{1B}[2J", "\u{1B}#8"] {
            var viewport = try makeSubject(selectedRow: 1)
            viewport.feed(Array(sequence.utf8))
            #expect(viewport.selectionRange == nil)
            #expect(viewport.activeSearchMatchRange == nil)

            var history = try makeHistorySubject()
            history.feed(Array(sequence.utf8))
            #expect(history.selectionRange != nil)
            #expect(history.activeSearchMatchRange != nil)
        }
    }

    @Test("scrollback-tail wrap and spacer edits invalidate that retained row")
    func scrollbackTailEdits() throws {
        var wrap = try #require(Terminal(columns: 4, rows: 2))
        wrap.feed(Array("ABCDEFGHI".utf8))
        wrap.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 3)
        )
        let foundWrap = wrap.beginSearch("ABCD")
        #expect(foundWrap)
        wrap.feed(Array("\u{1B}[1;1H\u{1B}[L".utf8))
        #expect(wrap.selectionRange == nil)
        #expect(wrap.activeSearchMatchRange == nil)

        var spacer = try #require(Terminal(columns: 3, rows: 1))
        spacer.moveCursor(row: 0, column: 2)
        spacer.feed(Array("\u{754C}".utf8))
        spacer.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 2)
        )
        spacer.moveCursor(row: 0, column: 0)
        spacer.feed(Array("A".utf8))
        #expect(spacer.selectionRange == nil)
    }

    @Test("selection and search invalidate independently by row")
    func independentInvalidation() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 3))
        terminal.feed(Array("AAAA\r\nBBBB\r\nCCCC".utf8))
        terminal.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 3)
        )
        let found = terminal.beginSearch("BBBB")
        #expect(found)

        terminal.feed(Array("\u{1B}[2;1HZ".utf8))

        #expect(terminal.selectionRange != nil)
        #expect(terminal.activeSearchMatchRange == nil)
    }

    @Test("a hard-boundary match excludes its end row at column zero")
    func hardBoundaryEndRowIsExclusive() throws {
        // Intent: a newline-only match is invalidated by its source row, not by
        //   content changes on the row reached by its exclusive endpoint.
        // Why it exists: row intersection can accidentally treat the end row as
        //   inclusive even when the half-open range ends at column zero.
        // Scenario: search selects the hard break between A and B, then B is
        //   overwritten without changing that break.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("A\r\nB".utf8))
        let found = terminal.beginSearch("\n")
        #expect(found)

        terminal.feed(Array("\u{1B}[2;1HC".utf8))

        #expect(terminal.activeSearchMatchRange != nil)
        terminal.feed(Array("\u{1B}[1;1HD".utf8))
        #expect(terminal.activeSearchMatchRange == nil)
    }

    @Test("wide wrapping invalidates overwritten continuation rows")
    func wideWrapDestinationInvalidation() throws {
        for suffix in ["\u{754C}", "\u{00A9}\u{FE0F}"] {
            var terminal = try #require(Terminal(columns: 3, rows: 2))
            terminal.feed(Array("\u{1B}[2;1HBBB\u{1B}[1;3H".utf8))
            if suffix.hasPrefix("\u{00A9}") {
                terminal.feed(Array("\u{00A9}".utf8))
            }
            terminal.setSelection(
                from: TerminalTextPosition(row: 1, column: 0),
                to: TerminalTextPosition(row: 1, column: 2)
            )
            let found = terminal.beginSearch("BBB")
            #expect(found)

            let bytes = suffix.hasPrefix("\u{00A9}") ? "\u{FE0F}" : suffix
            terminal.feed(Array(bytes.utf8))

            #expect(terminal.selectionRange == nil)
            #expect(terminal.activeSearchMatchRange == nil)
        }
    }

    private func makeSubject(selectedRow: Int) throws -> Terminal {
        var terminal = try #require(Terminal(columns: 6, rows: 4))
        terminal.feed(Array("AAAA\r\nBBBB\r\nCCCC\r\nDDDD".utf8))
        let query = ["AAAA", "BBBB", "CCCC", "DDDD"][selectedRow]
        terminal.setSelection(
            from: TerminalTextPosition(row: selectedRow, column: 0),
            to: TerminalTextPosition(row: selectedRow, column: 3)
        )
        let found = terminal.beginSearch(query)
        #expect(found)
        return terminal
    }

    private func makeHistorySubject() throws -> Terminal {
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("AAAA\r\nBBBB\r\nCCCC".utf8))
        terminal.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 3)
        )
        let found = terminal.beginSearch("AAAA")
        #expect(found)
        return terminal
    }
}
