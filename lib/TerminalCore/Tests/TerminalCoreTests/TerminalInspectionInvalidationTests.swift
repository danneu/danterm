// Row-mutation proofs for position-based search, content-derived links, and selection survival.
import Testing

@testable import TerminalCore

/// Exercises every retained-content mutation family against intersecting and disjoint anchors.
struct TerminalInspectionInvalidationTests {
    @Test("a vacated prompt selection never survives width reflow as a collapsed range")
    func promptSelectionUsesReflowDomain() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("\u{1B}]133;A;redraw=1\u{7}> prompt\u{1B}]133;B\u{7}".utf8))
        terminal.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 7)
        )
        #expect(terminal.selectedText == "> prompt")

        terminal.resize(columns: 8, rows: 4)
        #expect(terminal.selectedText == "> prompt")

        terminal.resize(columns: 9, rows: 4)
        if let range = terminal.selectionRange {
            #expect(range.start != range.end)
        }
    }

    @Test("cell mutations preserve selection and clear intersecting search matches")
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
            #expect(intersecting.selectionRange != nil, "\(mutation.name) cleared selection")
            #expect(intersecting.searchReadout?.activeMatch == nil, "\(mutation.name) kept search")

            var disjoint = try makeSubject(selectedRow: 1)
            disjoint.feed(Array(mutation.disjoint.utf8))
            #expect(disjoint.selectionRange != nil, "\(mutation.name) cleared selection")
            #expect(disjoint.searchReadout?.activeMatch != nil, "\(mutation.name) cleared search")
        }
    }

    @Test("row rotations preserve selection and resolve search against surviving matches")
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
            #expect(intersecting.selectionRange != nil)
            let intersectingRows = 0..<intersecting.scrollProjection.totalRows
            #expect(
                (intersecting.searchReadout?.activeMatch != nil)
                    == (intersecting.scannedSearchMatchRanges(in: intersectingRows).isEmpty == false)
            )

            var disjoint = try makeSubject(selectedRow: 0)
            disjoint.feed(Array(sequence.utf8))
            #expect(disjoint.selectionRange != nil)
            #expect(disjoint.searchReadout?.activeMatch != nil)
        }
    }

    @Test("whole-viewport pushes preserve selection and search across the history seam")
    func wholeViewportPushesPreserveInspection() throws {
        // Intent: selection and the active search result keep naming the same retained content
        //   when LF or `SU 2` pushes viewport rows into history.
        // Why it exists: the whole-viewport ring branch will bypass the general row mover, whose
        //   LF and CSI paths currently differ on whether they run inspection invalidation.
        // Scenario: each push runs with an anchor on the evicted prefix and on a surviving row.
        let cases: [(name: String, sequence: String)] = [
            ("LF", "\u{1B}[4;1H\n"),
            ("SU 2", "\u{1B}[2S"),
        ]

        for mutation in cases {
            for selectedRow in [0, 2] {
                var terminal = try makeSubject(selectedRow: selectedRow)
                let selection = terminal.selectionRange
                let match = terminal.searchReadout?.activeMatch

                terminal.feed(Array(mutation.sequence.utf8))

                #expect(
                    terminal.selectionRange == selection,
                    "\(mutation.name) changed the row \(selectedRow) selection"
                )
                #expect(
                    terminal.searchReadout?.activeMatch == match,
                    "\(mutation.name) changed the row \(selectedRow) search match"
                )
                expectValidGrid(terminal)
            }
        }
    }

    @Test("whole-screen mutations leave scrollback inspection alone")
    func wholeScreenMutationScope() throws {
        for sequence in ["\u{1B}[2J", "\u{1B}#8"] {
            var viewport = try makeSubject(selectedRow: 1)
            viewport.feed(Array(sequence.utf8))
            #expect(viewport.selectionRange != nil)
            #expect(viewport.searchReadout?.activeMatch == nil)

            var history = try makeHistorySubject()
            history.feed(Array(sequence.utf8))
            #expect(history.selectionRange != nil)
            #expect(history.searchReadout?.activeMatch != nil)
        }
    }

    @Test("scrollback-tail wrap and spacer edits resolve search from live content")
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
        #expect(wrap.selectionRange != nil)
        #expect(wrap.searchReadout?.activeMatch != nil)

        var spacer = try #require(Terminal(columns: 3, rows: 1))
        spacer.moveCursor(row: 0, column: 2)
        spacer.feed(Array("\u{754C}".utf8))
        spacer.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 2)
        )
        spacer.moveCursor(row: 0, column: 0)
        spacer.feed(Array("A".utf8))
        #expect(spacer.selectionRange != nil)
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
        #expect(terminal.searchReadout?.activeMatch == nil)
    }

    @Test("a hard-boundary match survives edits on either adjacent row while the break remains")
    func hardBoundaryEndRowIsExclusive() throws {
        // Intent: a newline-only match remains selected while edits preserve the
        //   hard boundary itself, regardless of which adjacent row changes.
        // Why it exists: row-based invalidation used to retire a still-valid occurrence
        //   even though a full rescan continued to find the same hard break.
        // Scenario: search selects the hard break between A and B, then B is
        //   overwritten without changing that break.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("A\r\nB".utf8))
        let found = terminal.beginSearch("\n")
        #expect(found)

        terminal.feed(Array("\u{1B}[2;1HC".utf8))

        #expect(terminal.searchReadout?.activeMatch != nil)
        terminal.feed(Array("\u{1B}[1;1HD".utf8))
        #expect(terminal.searchReadout?.activeMatch != nil)
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

            #expect(terminal.selectionRange != nil)
            #expect(terminal.searchReadout?.activeMatch == nil)
        }
    }

    @Test("output received with only a selection live remains searchable")
    func selectionOnlyOutputRemainsSearchable() throws {
        var terminal = try #require(Terminal(columns: 8, rows: 2))
        terminal.feed(Array("old".utf8))
        terminal.setSelection(
            from: TerminalTextPosition(row: 0, column: 0),
            to: TerminalTextPosition(row: 0, column: 2)
        )

        terminal.feed(Array("\u{1B}[1;1Hnew".utf8))

        let found = terminal.beginSearch("new")
        #expect(found)
        #expect(terminal.searchReadout?.activeMatch != nil)
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
