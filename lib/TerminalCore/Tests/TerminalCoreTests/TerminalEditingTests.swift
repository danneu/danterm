// Proves CSI character/line editing and scrollback erasure through public byte ingestion.
import Testing

@testable import TerminalCore

/// Locks editing controls to clipped BCE moves, valid wide cells, and strict history policy.
struct TerminalEditingTests {
    @Test("ICH and DCH shift styled cells, clamp counts, and preserve the cursor")
    func characterEditingMovesAndClamps() throws {
        // Intent: prove horizontal editing moves source cells intact and BCE-fills
        //   every vacated position without moving the cursor.
        // Why it exists: character edits combine count clamping, style fidelity,
        //   and the current pen's background-color erase semantics.
        // Scenario: a styled prompt is opened and closed around the cursor while
        //   the active pen carries attributes that must not leak into blank cells.
        let eraseStyle = TerminalStyle(foreground: .indexed(1), background: .indexed(4))
        let movedStyle = TerminalStyle(foreground: .indexed(2))
        var inserted = try #require(Terminal(columns: 6, rows: 2))
        inserted.feed(Array("A\u{1B}[32mB\u{1B}[mCDE\u{1B}[1;2;3;4;7;8;9;31;44m".utf8))
        inserted.moveCursor(row: 0, column: 1)
        let insertedCursor = inserted.geometry.cursor

        inserted.feed(Array("\u{1B}[2@".utf8))

        #expect(inserted.screenText == "A  BCD\n      ")
        #expect(inserted.cell(row: 0, column: 3)?.style == movedStyle)
        #expect(inserted.cell(row: 0, column: 1)?.style == eraseStyle)
        #expect(inserted.cell(row: 0, column: 2)?.style == eraseStyle)
        #expect(inserted.geometry.cursor == insertedCursor)
        expectValidGrid(inserted)

        inserted.feed(Array("\u{1B}[99@".utf8))
        #expect(inserted.geometry.rows[0].cells.dropFirst().allSatisfy { $0.kind == .padding })
        for column in 1..<6 {
            #expect(inserted.cell(row: 0, column: column)?.style == eraseStyle)
        }
        #expect(inserted.geometry.cursor == insertedCursor)
        expectValidGrid(inserted)

        var deleted = try #require(Terminal(columns: 6, rows: 2))
        deleted.feed(Array("A\u{1B}[32mB\u{1B}[mCDE\u{1B}[1;2;3;4;7;8;9;31;44m".utf8))
        deleted.moveCursor(row: 0, column: 1)
        let deletedCursor = deleted.geometry.cursor

        deleted.feed(Array("\u{1B}[0P".utf8))

        #expect(deleted.screenText == "ACDE  \n      ")
        #expect(deleted.cell(row: 0, column: 1)?.scalars == ["C"])
        #expect(deleted.cell(row: 0, column: 5)?.style == eraseStyle)
        #expect(deleted.geometry.cursor == deletedCursor)
        expectValidGrid(deleted)

        deleted.feed(Array("\u{1B}[99P".utf8))
        #expect(deleted.geometry.rows[0].cells.dropFirst().allSatisfy { $0.kind == .padding })
        for column in 1..<6 {
            #expect(deleted.cell(row: 0, column: column)?.style == eraseStyle)
        }
        #expect(deleted.geometry.cursor == deletedCursor)
        expectValidGrid(deleted)
    }

    @Test("ICH and DCH repair wide pairs at the cursor and row edge")
    func characterEditingRepairsWidePairs() throws {
        // Intent: reduce every wide half severed by a horizontal move to BCE padding.
        // Why it exists: a cursor can begin on a wide tail, and ICH can shift a
        //   wide head beyond the right edge while dropping its matching tail.
        // Scenario: a TUI edits ASCII beside a Chinese glyph at both clipping boundaries.
        var insertBoundary = try #require(Terminal(columns: 6, rows: 1))
        insertBoundary.feed(Array("A\u{754C}BC".utf8))
        insertBoundary.moveCursor(row: 0, column: 2)
        insertBoundary.feed(Array("\u{1B}[@".utf8))
        #expect(insertBoundary.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .padding, .padding, .padding, .narrow, .narrow,
        ])
        expectValidGrid(insertBoundary)

        var insertEdge = try #require(Terminal(columns: 6, rows: 1))
        insertEdge.feed(Array("ABCD\u{754C}".utf8))
        insertEdge.moveCursor(row: 0, column: 0)
        insertEdge.feed(Array("\u{1B}[@".utf8))
        #expect(insertEdge.geometry.rows[0].cells.map(\.kind) == [
            .padding, .narrow, .narrow, .narrow, .narrow, .padding,
        ])
        expectValidGrid(insertEdge)

        var deleteBoundary = try #require(Terminal(columns: 6, rows: 1))
        deleteBoundary.feed(Array("A\u{754C}BC".utf8))
        deleteBoundary.moveCursor(row: 0, column: 2)
        deleteBoundary.feed(Array("\u{1B}[P".utf8))
        #expect(deleteBoundary.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .padding, .narrow, .narrow, .padding, .padding,
        ])
        expectValidGrid(deleteBoundary)

        var deleteSourceBoundary = try #require(Terminal(columns: 6, rows: 1))
        deleteSourceBoundary.feed(Array("A\u{754C}BC".utf8))
        deleteSourceBoundary.moveCursor(row: 0, column: 1)
        deleteSourceBoundary.feed(Array("\u{1B}[P".utf8))
        #expect(deleteSourceBoundary.geometry.rows[0].cells.map(\.kind) == [
            .narrow, .padding, .narrow, .narrow, .padding, .padding,
        ])
        expectValidGrid(deleteSourceBoundary)

        var incomingSpacer = try #require(Terminal(columns: 4, rows: 2))
        incomingSpacer.moveCursor(row: 0, column: 3)
        incomingSpacer.feed(Array("\u{754C}".utf8))
        incomingSpacer.moveCursor(row: 1, column: 1)
        incomingSpacer.feed(Array("\u{1B}[@".utf8))
        #expect(incomingSpacer.geometry.rows[0].cells[3].kind == .padding)
        #expect(incomingSpacer.geometry.rows[1].cells[0].kind == .padding)
        #expect(incomingSpacer.geometry.rows[1].cells[2].kind == .padding)
        expectValidGrid(incomingSpacer)
    }

    @Test("horizontal edits sever outgoing wrap and spacer claims")
    func characterEditingSeversWrapClaim() throws {
        var wrapped = try #require(Terminal(columns: 4, rows: 2))
        wrapped.moveCursor(row: 0, column: 3)
        wrapped.feed(Array("\u{754C}".utf8))
        #expect(wrapped.geometry.rows[0].isSoftWrapped)
        #expect(wrapped.geometry.rows[0].cells[3].kind == .spacerHead)

        wrapped.moveCursor(row: 0, column: 1)
        wrapped.feed(Array("\u{1B}[@".utf8))

        #expect(wrapped.geometry.rows[0].isSoftWrapped == false)
        #expect(wrapped.geometry.rows[0].cells[3].kind == .padding)
        #expect(wrapped.fullHistoryText == "\n\u{754C}")
        expectValidGrid(wrapped)
    }

    @Test("IL and DL clip to the active region, keep the cursor, and never push history")
    func lineEditingRegionSemantics() throws {
        // Intent: pin line editing to the cursor-through-bottom-margin strip,
        //   including count clamping and the keep-column deviation.
        // Why it exists: IL/DL share vertical scrolling mechanics but must not
        //   inherit full-screen SU's history push policy.
        // Scenario: a full-screen editor inserts and deletes rows inside a
        //   bounded work area while its cursor remains in a nonzero column.
        var inserted = try labeledTerminal(columns: 3, rows: 4)
        inserted.feed(Array("\u{1B}[2;4r\u{1B}[2;2H\u{1B}[L".utf8))
        #expect(inserted.screenText == "A  \n   \nB  \nC  ")
        #expect(inserted.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
        #expect(inserted.scrollbackRowCount == 0)
        expectValidGrid(inserted)

        var deleted = try labeledTerminal(columns: 3, rows: 4)
        deleted.feed(Array("\u{1B}[2;4r\u{1B}[2;2H\u{1B}[M".utf8))
        #expect(deleted.screenText == "A  \nC  \nD  \n   ")
        #expect(deleted.geometry.cursor == TerminalCursor(row: 1, column: 1, isPendingWrap: false))
        #expect(deleted.scrollbackRowCount == 0)
        expectValidGrid(deleted)

        var clamped = try labeledTerminal(columns: 3, rows: 4)
        clamped.feed(Array("\u{1B}[2;4r\u{1B}[3;2H\u{1B}[99L".utf8))
        #expect(clamped.screenText == "A  \nB  \n   \n   ")
        #expect(clamped.geometry.cursor == TerminalCursor(row: 2, column: 1, isPendingWrap: false))
        expectValidGrid(clamped)

        var fullDelete = try labeledTerminal(columns: 3, rows: 3)
        fullDelete.feed(Array("\u{1B}[H\u{1B}[M".utf8))
        #expect(fullDelete.screenText == "B  \nC  \n   ")
        #expect(fullDelete.scrollbackRowCount == 0)
        expectValidGrid(fullDelete)
    }

    @Test("edits outside the region suppress grid movement but clear side state")
    func editingOutsideRegionGuard() throws {
        for sequence in ["\u{1B}[@", "\u{1B}[P", "\u{1B}[L", "\u{1B}[M"] {
            var terminal = try labeledTerminal(columns: 3, rows: 4)
            terminal.feed(Array("\u{1B}[2;3r\u{1B}[1;1HA\u{200D}".utf8))
            let expectedScreen = terminal.screenText
            let expectedScalars = terminal.cell(row: 0, column: 0)?.scalars

            terminal.feed(Array("\(sequence)\u{0301}".utf8))

            #expect(terminal.screenText == expectedScreen)
            #expect(terminal.cell(row: 0, column: 0)?.scalars == expectedScalars)
            #expect(terminal.geometry.cursor == TerminalCursor(row: 0, column: 1, isPendingWrap: false))
            expectValidGrid(terminal)
        }
    }

    @Test("IL and DL sever wrap claims at both moved-strip seams")
    func lineEditingSeversWrapSeams() throws {
        // Intent: sever logical-line joins when line insertion or deletion
        //   displaces either side of a moved vertical strip.
        // Why it exists: row movement preserves wrap flags with content, so
        //   both the preceding seam and the last surviving row need repair.
        // Scenario: an editor modifies rows in the middle of a wrapped transcript.
        var deleted = try #require(Terminal(columns: 3, rows: 4))
        deleted.feed(Array("ABCDEFGHIJ".utf8))
        deleted.feed(Array("\u{1B}[2;4r\u{1B}[2;1H\u{1B}[M".utf8))
        #expect(deleted.geometry.rows[0].isSoftWrapped == false)
        #expect(deleted.geometry.rows[2].isSoftWrapped == false)
        #expect(deleted.fullHistoryText == "ABC\nGHIJ")
        expectValidGrid(deleted)

        var inserted = try #require(Terminal(columns: 3, rows: 4))
        inserted.feed(Array("ABCDEFGHIJ".utf8))
        inserted.feed(Array("\u{1B}[2;4r\u{1B}[2;1H\u{1B}[L".utf8))
        #expect(inserted.geometry.rows[0].isSoftWrapped == false)
        #expect(inserted.geometry.rows[3].isSoftWrapped == false)
        #expect(inserted.fullHistoryText == "ABC\n\nDEFGHI")
        expectValidGrid(inserted)

        var historySeam = try #require(Terminal(columns: 3, rows: 3))
        historySeam.feed(Array("ABCDEFGHIJ".utf8))
        #expect(historySeam.scrollbackRow(at: 0)?.isSoftWrapped == true)
        historySeam.feed(Array("\u{1B}[H\u{1B}[L".utf8))
        #expect(historySeam.scrollbackRowCount == 1)
        #expect(historySeam.scrollbackRow(at: 0)?.isSoftWrapped == false)
        #expect(historySeam.fullHistoryText == "ABC\n\nDEFGHI")
        expectValidGrid(historySeam)
    }

    @Test("valid edit dispatches clear motion state and invalid arity is bit-identical")
    func editingDispatchSideStateGate() throws {
        for sequence in ["\u{1B}[@", "\u{1B}[P", "\u{1B}[L", "\u{1B}[M"] {
            var pending = try #require(Terminal(columns: 2, rows: 2))
            pending.feed(Array("AB".utf8))
            pending.feed(Array(sequence.utf8))
            #expect(pending.geometry.cursor?.isPendingWrap == false)
            expectValidGrid(pending)
        }

        for sequence in ["\u{1B}[1;2@", "\u{1B}[1;2P", "\u{1B}[1;2L", "\u{1B}[1;2M"] {
            var invalid = try #require(Terminal(columns: 2, rows: 2))
            invalid.feed(Array("AB\u{200D}".utf8))
            let expected = invalid
            invalid.feed(Array(sequence.utf8))
            #expect(invalid == expected)
        }

        var combining = try #require(Terminal(columns: 4, rows: 2))
        combining.feed(Array("\u{1B}[2;1HB\u{1B}[1;1HA\u{200D}\u{1B}[M\u{0301}".utf8))
        #expect(combining.cell(row: 0, column: 0)?.scalars == ["B"])
        expectValidGrid(combining)
    }

    @Test("editing controls are invariant across every chunk split")
    func editingChunkInvariance() throws {
        let bytes = Array("ABCDE\u{1B}[2;3r\u{1B}[2;2H\u{1B}[@\u{1B}[P\u{1B}[L\u{1B}[M\u{1B}[3J".utf8)
        var expected = try #require(Terminal(columns: 4, rows: 3))
        expected.feed(bytes)

        for split in 0...bytes.count {
            var terminal = try #require(Terminal(columns: 4, rows: 3))
            terminal.feed(Array(bytes[..<split]))
            terminal.feed(Array(bytes[split...]))
            #expect(terminal == expected)
        }

        var bytewise = try #require(Terminal(columns: 4, rows: 3))
        for byte in bytes {
            bytewise.feed([byte])
        }
        #expect(bytewise == expected)
    }
}
