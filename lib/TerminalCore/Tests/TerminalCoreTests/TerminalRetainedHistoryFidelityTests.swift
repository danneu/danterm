// What a row keeps when it leaves the live grid, proved through the public terminal API.
//
// Belongs here: end-to-end proofs that history preserves a row across the three paths a
// retained row takes -- admission, a width reflow, and a height transfer back into the live
// grid -- plus the two row-level fields no cell carries (`isSoftWrapped`, `semanticPrompt`)
// and the stored extent canonical trimming leaves behind. Does not belong here: anything
// about how the arena lays a record out. Byte offsets, table layout and the charge are
// `TerminalLogicalLineStoreTests`' subject, and asserting them here would make this file
// fail on a representation change that broke nothing observable.
//
// Its own file because these are the assertions that hold whatever the storage is. Every one
// of them drives a `Terminal` and reads back through the public API, so they survived the
// per-display-row store being replaced by the logical-line arena without an edit.
import Testing

@testable import TerminalCore

/// Holds retained history to what it must reproduce, independent of how it stores it.
struct TerminalRetainedHistoryFidelityTests {
    // MARK: - Canonical extent through the terminal

    @Test("A retained row's stored extent is exactly where canonical trim put it")
    func retainedExtentMatchesCanonicalTrim() throws {
        // Intent: for blank, ragged, trailing-whitespace and full-width rows, the number of
        //   cells history stores is the canonical trimmed extent -- the index of the last
        //   non-default cell plus one, floored at one.
        // Why it exists: the stored extent must remain a pure function of observable
        //   content. The trim runs at admission, so a writer that padded a row out to the
        //   pane width or rounded a table would silently widen every retained row and turn
        //   the budget's row count into a different number.
        // Scenario: spec-first.
        let columns = 12
        var terminal = try #require(Terminal(columns: columns, rows: 2))
        // A blank row, a ragged row, a row whose content ends in spaces, and a full-width
        // row -- in that order. The two-row pane keeps only the last of them live, so all
        // four reach history.
        terminal.feed(Array("\r\n".utf8))
        terminal.feed(Array("abc\r\n".utf8))
        terminal.feed(Array("de   \r\n".utf8))
        terminal.feed(Array("123456789012\r\n".utf8))
        terminal.feed(Array("z\r\n".utf8))

        var extents: [Int] = []
        for index in 0..<terminal.scrollbackRowCount {
            let row = try #require(terminal.scrollbackRow(at: index))
            let last = row.cells.lastIndex {
                $0 != TerminalCell(kind: .padding, scalars: .empty, style: TerminalStyle(), hyperlink: nil)
            }
            extents.append((last ?? 0) + 1)
        }
        #expect(extents == [1, 3, 5, 12])
        // The census counts what history *stores*, and a blank logical line stores no cells at
        // all (`research/31/DD15`): its single display row is the fold's floor, not a stored cell. So the
        // stored total is the displayed extents less the blank row's one column.
        #expect(terminal.memoryCensus.retainedStoredCellCount == extents.reduce(0, +) - 1)
    }

    // MARK: - Observability through the terminal's three paths

    @Test("A combined-metadata row survives admission, width reflow, and height transfer")
    func combinedRowSurvivesAllThreePaths() throws {
        // Intent: a row carrying a hyperlink, a style, a wide glyph and a combining
        //   sequence reads back identically after it scrolls into history, after the pane
        //   is made narrower and wider again, and after it is pulled back into the live
        //   grid by a taller pane.
        // Why it exists: all three paths must preserve the row because they are three
        //   different pieces of code. Admission writes the record, reflow refolds it, and
        //   height transfer decodes it back into the live grid -- and only the first is
        //   exercised by a test that merely scrolls content off.
        // Scenario: spec-first.
        var terminal = try #require(Terminal(columns: 20, rows: 3, scrollbackBudgetBytes: 1 << 20))
        terminal.feed(Array("\u{1B}]8;id=x;https://danterm.test\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}[31mlink".utf8))
        terminal.feed(Array("\u{1B}]8;;\u{1B}\\".utf8))
        terminal.feed(Array("\u{1B}[0m 界 e\u{0301}\r\n".utf8))
        terminal.feed(Array("filler-a\r\nfiller-b\r\nfiller-c\r\n".utf8))

        func retainedRow() throws -> TerminalScrollbackRow {
            let match = try #require((0..<terminal.scrollbackRowCount).first {
                terminal.scrollbackRow(at: $0)?.cells.first?.scalars.first == "l"
            })
            return try #require(terminal.scrollbackRow(at: match))
        }

        let admitted = try retainedRow()
        #expect(admitted.cells[0].hyperlink?.uri == "https://danterm.test")
        #expect(admitted.cells[3].hyperlink?.explicitId == "x")
        #expect(admitted.cells[0].style != TerminalStyle())
        #expect(admitted.cells.contains { $0.kind == .wideHead && $0.scalars.first == "界" })
        #expect(admitted.cells.contains { $0.scalars.count == 2 })

        terminal.resize(columns: 12, rows: 3)
        terminal.resize(columns: 20, rows: 3)
        let reflowed = try retainedRow()
        #expect(reflowed.cells.prefix(4).map(\.scalars.first) == admitted.cells.prefix(4).map(\.scalars.first))
        #expect(reflowed.cells[0].hyperlink?.uri == "https://danterm.test")
        #expect(reflowed.cells.contains { $0.kind == .wideHead && $0.scalars.first == "界" })
        #expect(reflowed.cells.contains { $0.scalars.count == 2 })

        // Height transfer: a taller pane pulls retained rows back into the live grid.
        let beforeTransfer = terminal.scrollbackRowCount
        terminal.resize(columns: 20, rows: 6)
        #expect(terminal.scrollbackRowCount < beforeTransfer)
        let live = (0..<6).compactMap { row in
            (0..<20).compactMap { terminal.cell(row: row, column: $0) }
        }
        let linkRow = try #require(live.first { $0.first?.scalars.first == "l" })
        #expect(linkRow[0].hyperlink?.uri == "https://danterm.test")
        #expect(linkRow.contains { $0.kind == .wideHead && $0.scalars.first == "界" })
        #expect(linkRow.contains { $0.scalars.count == 2 })
    }

    @Test("A soft-wrapped line read out of history still rejoins through a width reflow")
    func softWrapSurvivesHistoryAndReflow() throws {
        // Intent: a logical line long enough to wrap, once fully in history, still reflows
        //   as one line when the pane widens -- which requires history to have kept
        //   `isSoftWrapped`.
        // Why it exists: `isSoftWrapped` is a row field no cell carries, so every cell-wise
        //   round-trip passes with it dropped. What breaks is only visible a resize later,
        //   as a wrapped line that will not rejoin.
        // Scenario: spec-first. Human review of doc 28's plan named this axis.
        var terminal = try #require(Terminal(columns: 10, rows: 2, scrollbackBudgetBytes: 1 << 20))
        terminal.feed(Array("abcdefghijklmnopqrstuvwxy\r\n".utf8))
        terminal.feed(Array("tail-a\r\ntail-b\r\ntail-c\r\n".utf8))

        terminal.resize(columns: 30, rows: 2)
        let rejoined = (0..<terminal.scrollbackRowCount).compactMap { index -> String? in
            guard let row = terminal.scrollbackRow(at: index) else { return nil }
            return String(String.UnicodeScalarView(row.cells.flatMap { Array($0.scalars) }))
        }
        #expect(rejoined.contains { $0.hasPrefix("abcdefghijklmnopqrstuvwxy") })
    }

    @Test("A prompt-marked row keeps its OSC 133 stamp after scrolling into history")
    func semanticPromptSurvivesHistory() throws {
        // Intent: an OSC 133 prompt row scrolled into history and pulled back by a taller
        //   pane still reports as a prompt row.
        // Why it exists: `semanticPrompt` is the second row-level field with no cell to
        //   carry it, and prompt navigation anchors on it. History that dropped it would
        //   break jump-to-previous-prompt while every cell read stayed correct.
        // Scenario: spec-first.
        var terminal = try #require(Terminal(columns: 20, rows: 2, scrollbackBudgetBytes: 1 << 20))
        terminal.feed(Array("\u{1B}]133;A\u{1B}\\$ command\r\n".utf8))
        terminal.feed(Array("\u{1B}]133;C\u{1B}\\output-a\r\noutput-b\r\noutput-c\r\n".utf8))

        terminal.resize(columns: 20, rows: 8)
        let stamps = terminal.semanticPromptRowsForTesting
        #expect(stamps.contains { $0.stamp == .prompt })
    }

    @Test("A row whose identities were assembled out of order reaches history in several runs")
    func fragmentedIdentityRowReachesHistoryStillIdentified() throws {
        // Intent: a row printed out of order -- so its `contentIdentity` values do not step
        //   by one across the columns -- lands in history with more than one identity run,
        //   and its decoded cells still carry identities.
        // Why it exists: the run encoding is the cheap case, and content assembled by cursor
        //   moves is what forces the other one. This proves the terminal really produces that
        //   shape, so the store's fallback is reachable from the outside and not just from a
        //   hand-built record. `activationIdentity` reads these values out of history, so a
        //   row that arrived with them dropped would stop adjudicating links in scrollback.
        // Scenario: spec-first; the row models a line assembled by cursor moves.
        var terminal = try #require(Terminal(columns: 30, rows: 2, scrollbackBudgetBytes: 1 << 20))
        // Print right-to-left in chunks so identities descend across the row.
        for column in stride(from: 20, through: 0, by: -5) {
            terminal.feed(Array("\u{1B}[1;\(column + 1)H".utf8))
            terminal.feed(Array("https".utf8))
        }
        terminal.feed(Array("\u{1B}[2;1H".utf8))
        terminal.feed(Array("filler-a\r\nfiller-b\r\n".utf8))

        let shape = try #require(terminal.scrollbackRecordContentIdentityShape(at: 0))
        #expect(shape.strictRunCount > 1)
        #expect(shape.identifiedCellCount > 0)

        let decoded = try #require(terminal.retainedRowForTesting(at: 0))
        #expect(decoded.cells.contains { $0.contentIdentity != nil })
    }
}
