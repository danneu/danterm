// Whole-frame rendering parity across faces, truecolor foregrounds, sprite families, and
// the fallback CTLine path: every row and every cell of a mixed frame must render exactly
// as it renders alone. The per-cell suites cover one family or one style at a time, so
// nothing else here pins what happens when a single frame mixes them and the executor has
// to keep each cell's face, colour, and column straight across run boundaries.
//
// Written to guard a glyph-batching change that was then rejected on its measurement
// (`docs/research/18-*.md` `F13`, `D5`), and kept because the guarantees are the
// executor's, not that change's: any future edit to how `drawTextRuns` groups or defers
// submission has to keep these passing. Verified by mutation to catch a lost bold, italic,
// or foreground colour, and a glyph positioned relative to its run instead of the frame.
// Deliberately not covered: the order submissions reach CoreGraphics in. Runs do not
// overlap, so ordering is invisible to a bitmap; catching it would need a call-order seam.
import CoreGraphics
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

struct MultiStyleFrameTests {
    /// One row of the probe frame. `sgr` is the parameter list of the CSI m that styles it,
    /// chosen so the rows collide in every way that could confuse a grouped submission:
    /// the same (face, colour) pair on non-adjacent rows, one colour across two faces, and
    /// two distinct pairs inside a single row.
    private struct ProbeRow {
        let sgr: String
        let text: String
    }

    private static let probeRows: [ProbeRow] = [
        ProbeRow(sgr: "0", text: "plain"),
        ProbeRow(sgr: "1", text: "bold!"),
        ProbeRow(sgr: "3", text: "itals"),
        ProbeRow(sgr: "1;3", text: "both!"),
        // Truecolor, so colour handling is exercised with a value the 256-colour
        // palette cannot produce.
        ProbeRow(sgr: "0;38;2;220;50;50", text: "red__"),
        // Same colour as row 4, different face: must not inherit row 4's weight.
        ProbeRow(sgr: "1;38;2;220;50;50", text: "redbd"),
        // Identical style to row 4 and not adjacent to it, so any grouping that merges
        // like-styled rows merges these two across the rows between them.
        ProbeRow(sgr: "0;38;2;220;50;50", text: "red2_"),
        // Two distinct styles inside a single row.
        ProbeRow(sgr: "0;38;2;40;200;90", text: "grn"),
    ]

    private static let columns = 14
    private static let rows = probeRows.count

    /// Cursor-positions each row so a row's content is independent of every other row's,
    /// which is what lets one row be rendered alone at the same coordinates.
    private static func input(rowsIncluded: Set<Int>) -> String {
        var output = ""
        for (index, row) in probeRows.enumerated() where rowsIncluded.contains(index) {
            output += "\u{1B}[\(index + 1);1H\u{1B}[\(row.sgr)m\(row.text)"
            if index == probeRows.count - 1 {
                // Second style on the same row: a different colour mid-row.
                output += "\u{1B}[1;38;2;90;120;240mblu"
            }
            output += "\u{1B}[0m"
        }
        return output
    }

    @Test("Every row of a multi-style frame renders as it does alone", arguments: [1.0, 2.0])
    func everyRowMatchesItsIsolatedRendering(scale: CGFloat) throws {
        // Intent: in a frame whose rows deliberately share faces and colours, each row's
        //   pixels are exactly what that row renders when it is the only row.
        // Why it exists: a lost bold or italic trait, a foreground colour taken from the
        //   wrong run, or a glyph positioned relative to its run instead of the frame all
        //   produce plausible text in the wrong place, weight, or colour rather than a
        //   crash, and no per-cell suite would notice. Rows 4 and 6 are identically styled
        //   and non-adjacent, so any change that groups like-styled rows together is
        //   exercised across the rows in between.
        // Scenario: spec-first -- a TUI frame mixing bold, italic, and truecolor spans,
        //   where the same colour recurs on rows that are far apart.
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let all = try renderBitmap(
            plan: makePlan(
                input: Self.input(rowsIncluded: Set(0..<Self.rows)),
                columns: Self.columns,
                rows: Self.rows
            ),
            metrics: metrics
        )

        for row in 0..<Self.rows {
            let isolated = try renderBitmap(
                plan: makePlan(
                    input: Self.input(rowsIncluded: [row]),
                    columns: Self.columns,
                    rows: Self.rows
                ),
                metrics: metrics
            )
            let rect = cellRect(row: row, column: 0, columnCount: Self.columns, metrics: metrics)
            #expect(
                all.bytes(in: rect) == isolated.bytes(in: rect),
                "row \(row) styled \(Self.probeRows[row].sgr)"
            )
            #expect(all.inkCount(in: rect) > 0, "row \(row) drew nothing")
        }
    }

    @Test("Rows sharing a face or a color still render in their own color")
    func sharedStyleRowsKeepTheirColors() throws {
        // Intent: the identically styled rows both render red, the bold row sharing only
        //   that colour renders red too, and a differently coloured row does not pick red up.
        // Why it exists: the parity test above compares bytes, so it would catch a colour
        //   swap but cannot say which colour is wrong, and it cannot distinguish "both rows
        //   wrong the same way" from correct -- an isolated row rendered with the same bug
        //   matches. This asserts the colour itself, so submitting a run under another
        //   run's fill colour fails loudly.
        // Scenario: spec-first -- prompt text in one truecolor and a diagnostic line in
        //   another, several rows apart.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let bitmap = try renderBitmap(
            plan: makePlan(
                input: Self.input(rowsIncluded: Set(0..<Self.rows)),
                columns: Self.columns,
                rows: Self.rows
            ),
            metrics: metrics
        )

        // Rows 4, 5 and 6 are red; row 7 starts green. Ink is antialiased, so assert
        // channel dominance rather than an exact pixel -- but *strictly*: the default
        // foreground is near-grey, so a non-strict `red >= green` holds for it too and
        // would pass for text that lost its colour entirely. That is not hypothetical;
        // it is the mutation that first slipped through this test.
        for row in [4, 5, 6] {
            let rect = cellRect(row: row, column: 0, columnCount: 5, metrics: metrics)
            let ink = bitmap.pixels(in: rect).filter { $0 != Pixel(RenderTheme.dark.defaultBackground) }
            #expect(ink.isEmpty == false, "row \(row) drew nothing")
            #expect(
                ink.allSatisfy { $0.red > $0.green && $0.red > $0.blue },
                "row \(row) should be strictly reddest"
            )
        }

        let greenRect = cellRect(row: 7, column: 0, columnCount: 3, metrics: metrics)
        let greenInk = bitmap.pixels(in: greenRect)
            .filter { $0 != Pixel(RenderTheme.dark.defaultBackground) }
        #expect(greenInk.isEmpty == false)
        #expect(
            greenInk.allSatisfy { $0.green > $0.red && $0.green > $0.blue },
            "row 7's first span should be strictly greenest"
        )
    }

    @Test("Sprite cells and text cells in one frame each render as they do alone")
    func spritesAndTextKeepTheirCells() throws {
        // Intent: a frame mixing sprite-family cells with text cells renders each cell the
        //   same as that cell rendered by itself.
        // Why it exists: sprites, mapped glyphs, and the fallback CTLine path are three
        //   separate submission routes, and they are interleaved per run today. Any change
        //   to when each one flushes relies on cells being disjoint so the order cannot
        //   matter. This makes that argument executable instead of assumed.
        // Scenario: spec-first -- a box-drawn TUI border with labels inside it.
        //
        // `e` + combining acute is in the list on purpose: it is a multi-scalar cluster,
        // so it takes the fallback CTLine path, which sets its own text matrix and does not
        // restore it. That makes it the one route that can corrupt whatever is submitted
        // after it, so it sits between two ordinary text cells here.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let cells = ["a", "\u{2500}", "b", "\u{2588}", "c", "\u{28FF}", "e\u{301}", "d"]
        let columns = cells.count + 1
        let mixed = try renderBitmap(
            plan: makePlan(input: cells.joined(), columns: columns, rows: 1),
            metrics: metrics
        )

        for (column, text) in cells.enumerated() {
            let isolated = try renderBitmap(
                plan: makePlan(
                    input: "\u{1B}[\(column + 1)G" + text,
                    columns: columns,
                    rows: 1
                ),
                metrics: metrics
            )
            let rect = cellRect(row: 0, column: column, metrics: metrics)
            #expect(
                mixed.bytes(in: rect) == isolated.bytes(in: rect),
                "column \(column) rendering \(text)"
            )
            #expect(mixed.inkCount(in: rect) > 0, "column \(column) drew nothing")
        }
    }
}
