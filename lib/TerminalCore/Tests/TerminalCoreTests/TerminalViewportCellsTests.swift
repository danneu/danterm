// Behavioral proofs for the viewport cell projection used by coordinate-aware inspection.
import Testing
@testable import TerminalCore

@Suite("Terminal viewport cells")
struct TerminalViewportCellsTests {
    @Test("spans preserve columns, grapheme byte offsets, wide cells, and padding")
    func spanProjection() throws {
        // Intent: reconstruct every occupied column from only the public span payload.
        // Why it exists: character indexes do not name terminal columns when combining or
        //   wide graphemes occur, and interior padding must keep later text in place.
        // Scenario: a row contains a combining grapheme, a cursor-move gap, and a wide glyph;
        //   the next row begins with the spacer left by an early wide wrap.
        var terminal = try #require(Terminal(columns: 8, rows: 3))
        terminal.feed(Array("e\u{301} x\u{1B}[5G\u{754C}z".utf8))

        let readout = terminal.viewportCells
        #expect(readout.columns == 8)
        #expect(readout.rowCount == 3)
        #expect(readout.rows[0].index == 0)
        #expect(readout.rows[0].spans == [
            TerminalViewportCellSpan(
                kind: .narrow,
                column: 0,
                cellWidth: 1,
                text: "e\u{301} x ",
                utf8Offsets: [0, 3, 4, 5]
            ),
            TerminalViewportCellSpan(
                kind: .wide,
                column: 4,
                cellWidth: 2,
                text: "\u{754C}",
                utf8Offsets: [0]
            ),
            TerminalViewportCellSpan(
                kind: .narrow,
                column: 6,
                cellWidth: 1,
                text: "z",
                utf8Offsets: [0]
            ),
        ])
        #expect(readout.rows[1].spans.isEmpty)
        #expect(reconstructedColumns(readout.rows[0], columns: readout.columns)
            == rendererColumns(terminal, row: 0))

        var wrapped = try #require(Terminal(columns: 5, rows: 2))
        wrapped.feed(Array("abcd\u{754C}".utf8))
        #expect(wrapped.viewportCells.rows[0].spans == [
            TerminalViewportCellSpan(
                kind: .narrow,
                column: 0,
                cellWidth: 1,
                text: "abcd",
                utf8Offsets: [0, 1, 2, 3]
            ),
            TerminalViewportCellSpan(
                kind: .spacer,
                column: 4,
                cellWidth: 1,
                text: nil,
                utf8Offsets: nil
            ),
        ])
        #expect(wrapped.viewportCells.rows[1].spans.first?.column == 0)
        #expect(wrapped.viewportCells.rows[1].spans.first?.cellWidth == 2)
        #expect(wrapped.viewportCells.rows[1].spans.first?.text == "\u{754C}")
        for row in wrapped.viewportCells.rows {
            #expect(reconstructedColumns(row, columns: wrapped.viewportCells.columns)
                == rendererColumns(wrapped, row: row.index))
        }
    }

    @Test("origin converts viewport rows to pane row indexes on both screens")
    func paneRowsOrigin() throws {
        // Intent: adding a viewport row to paneRowsOrigin names the matching pane.rows row.
        // Why it exists: primary browsing and alternate-screen display use different stream
        //   bases, and retained-history eviction rebases the primary index.
        // Scenario: a small retained primary stream is browsed, then an alternate screen opens.
        var terminal = try #require(Terminal(columns: 4, rows: 2))
        terminal.feed(Array("a\r\nb\r\nc\r\nd".utf8))
        terminal.scroll(toTopRow: 1)

        #expect(terminal.viewportCells.paneRowsOrigin == 1)
        #expect(terminal.viewportCells.rows.map { terminal.viewportCells.paneRowsOrigin + $0.index }
            == [1, 2])

        var evicting = try #require(Terminal(
            columns: 4,
            rows: 2,
            scrollbackBudgetBytes: historyBudget(lines: 2, cells: 1, paneColumns: 4)
        ))
        evicting.feed(Array("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng".utf8))
        #expect(evicting.viewportCells.paneRowsOrigin == evicting.scrollProjection.topRow)
        #expect(evicting.viewportCells.paneRowsOrigin < evicting.absoluteViewportTopRow)

        terminal.feed(Array("\u{1B}[?1049hALT".utf8))
        let retainedPrimaryRows = terminal.rowStructure.prefix { $0.isRetained }.count
        #expect(terminal.viewportCells.paneRowsOrigin == retainedPrimaryRows)
        #expect(terminal.viewportCells.rows.flatMap(\.spans).contains { $0.text == "ALT" })
    }

    @Test("reading cells is a stable non-mutating projection")
    func readIsPure() throws {
        var terminal = try #require(Terminal(columns: 6, rows: 2))
        terminal.feed(Array("one\r\ntwo\r\nthree".utf8))
        terminal.scroll(toTopRow: 0)
        let before = terminal

        let first = terminal.viewportCells
        let second = terminal.viewportCells

        #expect(first == second)
        #expect(terminal == before)
    }
}

private func rendererColumns(_ terminal: Terminal, row: Int) -> [String?] {
    var columns = [String?](repeating: nil, count: terminal.viewportColumnCount)
    terminal.forEachViewportRow(rows: row..<(row + 1)) { _, visit in
        visit { _, _, visitCells in
            visitCells { column, kind, scalars in
                switch kind {
                case .padding:
                    break
                case .narrow:
                    columns[column] = String(describing: scalars)
                case .wideHead:
                    columns[column] = String(describing: scalars)
                case .wideTail:
                    columns[column] = "<wideTail>"
                case .spacerHead:
                    columns[column] = "<spacer>"
                }
            }
        }
    }
    guard let first = columns.firstIndex(where: { $0 != nil }),
          let last = columns.lastIndex(where: { $0 != nil })
    else { return columns }
    for column in first...last where columns[column] == nil { columns[column] = " " }
    return columns
}

private func reconstructedColumns(
    _ row: TerminalViewportCellRow,
    columns count: Int
) -> [String?] {
    var columns = [String?](repeating: nil, count: count)
    for span in row.spans {
        guard let text = span.text, let offsets = span.utf8Offsets else {
            columns[span.column] = "<spacer>"
            continue
        }
        let bytes = Array(text.utf8)
        for (index, start) in offsets.enumerated() {
            let end = index + 1 < offsets.count ? offsets[index + 1] : bytes.count
            let column = span.column + index * span.cellWidth
            columns[column] = String(decoding: bytes[start..<end], as: UTF8.self)
            if span.cellWidth == 2 { columns[column + 1] = "<wideTail>" }
        }
    }
    return columns
}
