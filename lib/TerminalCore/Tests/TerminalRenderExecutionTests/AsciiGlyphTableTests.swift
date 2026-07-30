// Proofs for the eager printable-ASCII glyph table each styled face carries, which lets the
// run loop skip the per-draw cmap lookup for the characters a terminal actually draws. The
// table is a memo of `CTFontGetGlyphsForCharacters`, so its whole correctness claim is that
// it agrees with that function -- these tests state that against a fresh call rather than
// against a recorded golden, and pin that splitting the run loop into a table path and a
// residual cmap path keeps every cell in its own column.
import CoreGraphics
import CoreText
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

struct AsciiGlyphTableTests {
    private static let styles: [(bold: Bool, italic: Bool)] = [
        (false, false),
        (true, false),
        (false, true),
        (true, true),
    ]

    @Test("Every table entry equals a fresh cmap lookup on its own face", arguments: [1.0, 2.0])
    func tableAgreesWithCoreText(scale: CGFloat) throws {
        // Intent: for all four styled faces, the eager table's glyph for each printable
        //   ASCII scalar is the glyph CoreText maps that scalar to right now.
        // Why it exists: the table replaces a per-draw call with a value computed once, so
        //   nothing at draw time can notice a wrong entry -- the wrong glyph just renders.
        //   The mapping is a pure function of face and code unit
        //   (`CTFont.h`, `CTFontGetGlyphsForCharacters`), which is the only reason
        //   precomputing it is sound; this test is that reasoning made
        //   executable. Indexing is the real risk: an off-by-one against the table's base
        //   would shift every character by one.
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        for style in Self.styles {
            let face = metrics.fonts.face(bold: style.bold, italic: style.italic)
            for value in asciiGlyphTableRange {
                var character = UniChar(value)
                var expected = CGGlyph()
                let mapped = CTFontGetGlyphsForCharacters(face.font, &character, &expected, 1)
                #expect(
                    face.asciiGlyph(value) == (mapped ? expected : 0),
                    "scalar \(value) on bold=\(style.bold) italic=\(style.italic)"
                )
            }
        }
    }

    @Test("The table covers exactly printable ASCII and refuses everything else")
    func tableRangeIsPrintableAscii() {
        // Intent: `asciiGlyphTableRange` is 0x20...0x7E, and `asciiGlyph` returns nil off it
        //   so the caller falls back to the cmap path rather than reading a wrong entry.
        // Why it exists: a table consulted one scalar beyond its bounds is either a crash or
        //   a silently wrong glyph, and the run loop's bounds check is the only thing between
        //   them. Control characters are excluded deliberately: they are not glyph-bearing,
        //   and including them would only widen the table.
        #expect(asciiGlyphTableRange == 0x20...0x7E)
        let face = TerminalFontSet(baseName: "Menlo", baseSize: 13).face(bold: false, italic: false)
        #expect(face.asciiGlyph(0x1F) == nil)
        #expect(face.asciiGlyph(0x7F) == nil)
        #expect(face.asciiGlyph(0x20) != nil)
        #expect(face.asciiGlyph(0x7E) != nil)
    }

    @Test("A run mixing table and cmap characters keeps every cell in its own column")
    func mixedRunKeepsCellAlignment() throws {
        // Intent: in one text run containing both printable ASCII and scalars the table does
        //   not cover, each cell renders exactly what it renders alone in that column.
        // Why it exists: the table path and the residual cmap path fill the glyph and
        //   position buffers separately, so the two can disagree about which cell a glyph
        //   belongs to. A misalignment here would look like plausible text, not a crash --
        //   and it would survive every single-character test.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let cells = ["a", "\u{E9}", "b", "\u{3A9}", "c"]
        let mixed = try renderBitmap(
            plan: makePlan(input: cells.joined(), columns: cells.count + 1, rows: 1),
            metrics: metrics
        )

        for (column, text) in cells.enumerated() {
            let isolated = try renderBitmap(
                plan: makePlan(
                    input: "\u{1B}[\(column + 1)G" + text,
                    columns: cells.count + 1,
                    rows: 1
                ),
                metrics: metrics
            )
            let rect = cellRect(row: 0, column: column, metrics: metrics)
            #expect(
                mixed.bytes(in: rect) == isolated.bytes(in: rect),
                "column \(column) rendering \(text)"
            )
            #expect(mixed.inkCount(in: rect) > 0, "column \(column) rendering \(text)")
        }
    }
}
