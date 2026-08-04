// Agreement between the three readers of a *retained* row, on content that exercises
// every exception table a packed row can carry.
//
// Belongs here: assertions that the browsing render walk
// (`forEachViewportCell(row:_:)`), the geometry projection (`geometry`), and the
// public row reader (`scrollbackRow(at:)`) report the same cells for the same
// retained row. Does not belong here: anything about how the row is stored --
// stride, table layout, or byte counts are `TerminalPackedRetainedRowTests`'
// subject, and asserting them here would make this file fail on a representation
// change that broke nothing observable.
//
// Its own file because it pins a *cross-reader* contract that no single reader's
// test owns. `28/F17` cut the render walk and the geometry projection over from
// materializing each retained row (`unpacked()`) to streaming it, and the risk
// that carries is not "the packed row decodes wrong" -- `PO1`-`PO5` cover that --
// but "one of three readers drifts from the other two on an exception". These
// tests fail on that drift and are otherwise indifferent to the representation.
import Testing
@testable import TerminalCore

@Suite("Retained-row read paths agree")
struct TerminalRetainedRowReadPathTests {
    /// Content chosen to force every exception table off its fast path at once: a wide
    /// glyph (kind exceptions, and a scalar too large for a 1-byte stride), a combining
    /// cluster (the spill table), two style runs, and a hyperlink.
    private static let stimulus =
        "\u{1B}[31mab\u{1B}[0m"                      // two style runs
        + "\u{1B}]8;;https://example.com\u{1B}\\cd\u{1B}]8;;\u{1B}\\"  // hyperlink run
        + "\u{4E16}\u{754C}"                          // wide glyphs -> head/tail kinds
        + "e\u{0301}"                                 // combining cluster -> spill
        + "f\r\n"

    private func browsedTerminal(columns: Int) throws -> Terminal {
        var terminal = try #require(Terminal(columns: columns, rows: 1))
        terminal.feed(Array(Self.stimulus.utf8))
        // One row of viewport, one fed line: the line is now retained, and scrolling to
        // the top puts the *retained* row under the viewport -- which is the only way to
        // make the render walk read packed storage rather than the live grid.
        terminal.scroll(toTopRow: 0)
        return terminal
    }

    @Test("The render walk reports the same cells the public row reader does")
    func renderWalkAgreesWithRowReader() throws {
        // Intent: `forEachViewportCell` yields, for a retained row, exactly the scalars and
        //   styles `scrollbackRow(at:)` reports for the same columns -- across wide glyphs,
        //   a spilled cluster, a style change, and a hyperlink.
        // Why it exists: these two readers reach the same bytes by different routes, and
        //   after `F17` they no longer share `unpacked()` as a common decoder. Nothing else
        //   would catch a streaming walk that advanced one table's cursor differently from
        //   the materializing path -- the symptom would be a wrong glyph or color on screen
        //   several columns after an exception, which no byte-level test sees.
        let columns = 24
        let terminal = try browsedTerminal(columns: columns)
        let expected = try #require(terminal.scrollbackRow(at: 0))

        var rendered: [(column: Int, scalars: TerminalScalars, style: TerminalStyle)] = []
        terminal.forEachViewportCell(row: 0) {
            rendered.append((column: $0, scalars: $1, style: $2))
        }

        #expect(rendered.count == columns)
        #expect(rendered.map(\.column) == Array(0..<columns))
        for entry in rendered {
            #expect(entry.scalars == expected.cells[entry.column].scalars)
            #expect(entry.style == expected.cells[entry.column].style)
        }
    }

    @Test("Geometry reports the same cell kinds the public row reader does")
    func geometryAgreesWithRowReader() throws {
        // Intent: `geometry.rows[0]` carries the same per-column kind, and the same
        //   `isSoftWrapped`, as the public reader for a retained row.
        // Why it exists: geometry needs only kinds, so `F17` stopped it materializing
        //   whole cells. A kind-only walk that mis-tracked the kind exception table would
        //   put `wideTail` at the wrong column, which the renderer turns into a dropped or
        //   doubled glyph -- and no scalar-level assertion would notice.
        let columns = 24
        let terminal = try browsedTerminal(columns: columns)
        let expected = try #require(terminal.scrollbackRow(at: 0))
        let geometry = terminal.geometry

        #expect(geometry.columns == columns)
        #expect(geometry.rows.count == 1)
        #expect(geometry.rows[0].cells.count == columns)
        #expect(geometry.rows[0].isSoftWrapped == expected.isSoftWrapped)
        for column in 0..<columns {
            #expect(geometry.rows[0].cells[column].kind == expected.cells[column].kind)
        }
    }

    @Test("A soft-wrapped retained row reports its wrap through geometry")
    func softWrapSurvivesTheReadPath() throws {
        // Intent: a row that wrapped rather than ending in a newline still reports
        //   `isSoftWrapped` through geometry once retained.
        // Why it exists: the wrap flag lives in the packed row's header byte, not in its
        //   cells, so a read path rebuilt around cells alone can drop it silently. It is
        //   load-bearing for selection and reflow, and nothing user-visible fails until a
        //   copy spans the wrap.
        var terminal = try #require(Terminal(columns: 4, rows: 1))
        terminal.feed(Array("abcdefgh".utf8))
        terminal.scroll(toTopRow: 0)

        let expected = try #require(terminal.scrollbackRow(at: 0))
        #expect(expected.isSoftWrapped)
        #expect(terminal.geometry.rows[0].isSoftWrapped)
    }

    @Test("The render walk pads a short retained row out to the pane width")
    func shortRowPadsToPaneWidth() throws {
        // Intent: a retained row storing fewer cells than the pane is wide still yields one
        //   entry per column, with default content past the stored extent.
        // Why it exists: retained rows are content-sized, so the padding tail is produced by
        //   the reader rather than stored. A streaming walk that ended at the stored extent
        //   would leave the row's tail undrawn, which reads as stale pixels rather than a
        //   crash.
        var terminal = try #require(Terminal(columns: 32, rows: 1))
        terminal.feed(Array("hi\r\n".utf8))
        terminal.scroll(toTopRow: 0)

        var rendered: [(Int, TerminalScalars, TerminalStyle)] = []
        terminal.forEachViewportCell(row: 0) { rendered.append(($0, $1, $2)) }

        #expect(rendered.count == 32)
        #expect(rendered[0].1 == ["h"])
        #expect(rendered[1].1 == ["i"])
        #expect(rendered[31].1.isEmpty)
        #expect(rendered[31].2 == TerminalStyle())
        #expect(terminal.geometry.rows[0].cells[31].kind == .padding)
    }
}
