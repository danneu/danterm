// Pixel-level proofs for per-cell CoreText shaping, traits, fallback, clipping, and orientation.
import AppKit
import CoreGraphics
import CoreText
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

struct TextExecutionTests {
    @Test("A fast-path glyph may overhang its horizontal grid boundary", arguments: [1.0, 2.0])
    func positionedFastPathGlyphMayOverhang(scale: CGFloat) throws {
        // Intent: direct glyph batching preserves the font's horizontal
        //   overhang instead of paying for a clip around every mapped glyph.
        // Why it exists: accepting horizontal overhang is the explicit
        //   correctness trade-off that makes the fast path clip-free.
        // Scenario: a bold-italic glyph reaches from its terminal cell into an
        //   adjacent blank cell at either standard display scale.
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let plan = try makePlan(
            input: "\u{1B}[2;3H\u{1B}[1;3mX",
            columns: 5,
            rows: 3
        )
        let bitmap = try renderBitmap(plan: plan, metrics: metrics)
        let target = cellRect(row: 1, column: 2, metrics: metrics)

        #expect(bitmap.inkCount(in: target) > 0)
        var neighboringInk = 0
        for row in 0..<3 {
            for column in 0..<5 where row != 1 || column != 2 {
                neighboringInk += bitmap.inkCount(in: cellRect(
                    row: row,
                    column: column,
                    metrics: metrics
                ))
            }
        }
        #expect(neighboringInk > 0)
    }

    @Test("Adjacent f and i cells match independently shaped controls")
    func adjacentCellsDoNotFormLigatures() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let adjacent = try renderBitmap(
            plan: makePlan(input: "fi", columns: 3, rows: 1),
            metrics: metrics
        )
        let onlyF = try renderBitmap(
            plan: makePlan(input: "f", columns: 3, rows: 1),
            metrics: metrics
        )
        let onlyI = try renderBitmap(
            plan: makePlan(input: "\u{1B}[2Gi", columns: 3, rows: 1),
            metrics: metrics
        )

        let firstCell = cellRect(row: 0, column: 0, metrics: metrics)
        let secondCell = cellRect(row: 0, column: 1, metrics: metrics)
        #expect(adjacent.bytes(in: firstCell) == onlyF.bytes(in: firstCell))
        #expect(adjacent.bytes(in: secondCell) == onlyI.bytes(in: secondCell))
    }

    @Test("Bold and italic change only the styled cell")
    func fontTraitsPreserveGridGeometry() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let regular = try renderBitmap(
            plan: makePlan(input: "AX", columns: 3, rows: 1),
            metrics: metrics
        )
        let bold = try renderBitmap(
            plan: makePlan(input: "\u{1B}[1mA\u{1B}[0mX", columns: 3, rows: 1),
            metrics: metrics
        )
        let italic = try renderBitmap(
            plan: makePlan(input: "\u{1B}[3mA\u{1B}[0mX", columns: 3, rows: 1),
            metrics: metrics
        )
        let boldItalic = try renderBitmap(
            plan: makePlan(input: "\u{1B}[1;3mA\u{1B}[0mX", columns: 3, rows: 1),
            metrics: metrics
        )
        let styledCell = cellRect(row: 0, column: 0, metrics: metrics)
        let controlCell = cellRect(row: 0, column: 1, metrics: metrics)

        #expect(bold.bytes(in: styledCell) != regular.bytes(in: styledCell))
        #expect(italic.bytes(in: styledCell) != regular.bytes(in: styledCell))
        #expect(boldItalic.bytes(in: styledCell) != bold.bytes(in: styledCell))
        #expect(boldItalic.bytes(in: styledCell) != italic.bytes(in: styledCell))
        #expect(bold.bytes(in: controlCell) == regular.bytes(in: controlCell))
        #expect(italic.bytes(in: controlCell) == regular.bytes(in: controlCell))
        #expect(boldItalic.bytes(in: controlCell) == regular.bytes(in: controlCell))
    }

    @Test(
        "Unicode text and clusters stay in their spans and do not move a trailing glyph",
        arguments: [
            UnicodeSample(text: "áéíóúñ", columnCount: 6),
            UnicodeSample(text: "中", columnCount: 2),
            UnicodeSample(text: "😀", columnCount: 2),
            UnicodeSample(text: "e\u{0301}", columnCount: 1),
            UnicodeSample(text: "ا", columnCount: 1),
        ]
    )
    func unicodeClusterContainment(sample: UnicodeSample) throws {
        // Intent: every supported script or cluster stays in its terminal span
        //   and leaves an independently positioned trailing glyph unchanged.
        // Why it exists: CoreText fallback advances and multi-scalar shaping
        //   must never become an alternate source of terminal grid geometry.
        // Scenario: a shell prints Spanish, CJK, emoji, combining text, or a
        //   fallback-only scalar immediately before ordinary ASCII output.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let targetColumn = sample.columnCount
        let columns = max(4, targetColumn + 2)
        let content = try renderBitmap(
            plan: makePlan(input: sample.text + "X", columns: columns, rows: 1),
            metrics: metrics
        )
        let control = try renderBitmap(
            plan: makePlan(
                input: "\u{1B}[\(targetColumn + 1)GX",
                columns: columns,
                rows: 1
            ),
            metrics: metrics
        )
        let clusterSpan = cellRect(
            row: 0,
            column: 0,
            columnCount: sample.columnCount,
            metrics: metrics
        )
        let trailingCell = cellRect(row: 0, column: targetColumn, metrics: metrics)

        #expect(content.inkCount(in: clusterSpan) > 0)
        #expect(content.bytes(in: trailingCell) == control.bytes(in: trailingCell))
        for column in targetColumn + 1..<columns {
            #expect(content.inkCount(in: cellRect(
                row: 0,
                column: column,
                metrics: metrics
            )) == 0)
        }
    }

    @Test("CoreText substitutes a usable font for an unsupported base-font scalar")
    func fallbackSubstitutionIsReal() throws {
        // Intent: prove the fallback containment case uses a substituted font
        //   with real glyph output, not the base face's missing-glyph box.
        // Why it exists: a .notdef glyph could otherwise satisfy containment
        //   and neighbor-isolation probes without exercising font fallback.
        // Scenario: terminal output contains Arabic alef, which the baked
        //   system-monospace base face cannot map on the supported platform.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let scalar: Unicode.Scalar = "ا"
        let baseFont = CTFontCreateWithName(
            metrics.baseFontName as CFString,
            metrics.baseFontSize,
            nil
        )
        var characters = Array(String(scalar).utf16)
        var baseGlyphs = Array(repeating: CGGlyph(), count: characters.count)

        #expect(CTFontGetGlyphsForCharacters(
            baseFont,
            &characters,
            &baseGlyphs,
            characters.count
        ) == false)

        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: baseFont,
            kCTLigatureAttributeName as NSAttributedString.Key: 0,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: String(scalar),
            attributes: attributes
        ))
        let runs = CTLineGetGlyphRuns(line) as NSArray
        let runObject = try #require(runs.firstObject)
        let run = runObject as! CTRun
        let runAttributes = CTRunGetAttributes(run) as NSDictionary
        let selectedFontObject = try #require(runAttributes[kCTFontAttributeName])
        let selectedFont = selectedFontObject as! CTFont
        let glyphCount = CTRunGetGlyphCount(run)
        var glyphs = Array(repeating: CGGlyph(), count: glyphCount)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)

        #expect(CTFontCopyPostScriptName(selectedFont) != CTFontCopyPostScriptName(baseFont))
        #expect(glyphs.isEmpty == false)
        #expect(glyphs.allSatisfy { $0 != 0 })
    }

    @Test("A repeated foreground color renders the same on its second run as on its first")
    func repeatedForegroundColorMatchesFirstUse() throws {
        // Intent: a run whose foreground color was already resolved by an
        //   earlier run in the same draw renders byte-identically to the same
        //   run drawn as that color's first use.
        // Why it exists: `drawTextRuns` memoizes `CGColor`s per draw, so the
        //   second run of a color takes a different code path (cache hit) than
        //   the first (cache miss). This pins the two paths together, including
        //   the color the fallback path carries in its text attributes, against
        //   a refactor that lets them diverge.
        // Scenario: colored terminal output repeats the same SGR foreground on
        //   consecutive rows -- the ordinary case for any colorized program.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        // A fallback scalar next to an ASCII one, so both the glyph fast path
        // and the attributed fallback path carry the memoized color.
        let text = "ا A"
        let repeated = try renderBitmap(
            plan: makePlan(
                input: "\u{1B}[31m\(text)\u{1B}[2;1H\(text)",
                columns: 6,
                rows: 2
            ),
            metrics: metrics
        )
        let firstUseOnly = try renderBitmap(
            plan: makePlan(
                input: "\u{1B}[2;1H\u{1B}[31m\(text)",
                columns: 6,
                rows: 2
            ),
            metrics: metrics
        )
        let secondRow = cellRect(row: 1, column: 0, columnCount: 6, metrics: metrics)

        #expect(repeated.inkCount(in: secondRow) > 0)
        #expect(repeated.bytes(in: secondRow) == firstUseOnly.bytes(in: secondRow))
    }

    @Test("High and low glyphs remain upright in top-left coordinates", arguments: [1.0, 2.0])
    func glyphOrientation(scale: CGFloat) throws {
        // Intent: distinguish upright glyph placement from a vertically
        //   mirrored CoreText result in the executor's top-left coordinates.
        // Why it exists: ink-presence and cell-containment probes both pass
        //   when the text matrix is inverted around the baseline.
        // Scenario: a terminal row renders punctuation at the cap line and an
        //   underscore at the bottom edge at either standard display scale.
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let high = try renderBitmap(
            plan: makePlan(input: "'", columns: 2, rows: 1),
            metrics: metrics
        )
        let low = try renderBitmap(
            plan: makePlan(input: "_", columns: 2, rows: 1),
            metrics: metrics
        )
        let wholeCell = cellRect(row: 0, column: 0, metrics: metrics)
        let highRows = high.inkRows(in: wholeCell)
        let lowRows = low.inkRows(in: wholeCell)
        let lowerBandStart = metrics.cellHeightPixels * 2 / 3

        #expect(highRows.isEmpty == false)
        #expect(
            highRows.allSatisfy { $0 < lowerBandStart },
            "High glyph rows: \(highRows)"
        )
        #expect(lowRows.isEmpty == false)
        #expect(
            lowRows.allSatisfy { $0 >= lowerBandStart },
            "Low glyph rows: \(lowRows)"
        )
    }

    @Test("Row zero glyph ink renders above row one", arguments: [1.0, 2.0])
    func rowOrder(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let bitmap = try renderBitmap(
            plan: makePlan(input: "A\u{1B}[2;1HA", columns: 2, rows: 2),
            metrics: metrics
        )

        let rowZeroInk = bitmap.inkRows(in: cellRect(row: 0, column: 0, metrics: metrics))
        let rowOneInk = bitmap.inkRows(in: cellRect(row: 1, column: 0, metrics: metrics))
        let bottomOfRowZero = try #require(rowZeroInk.last)
        let topOfRowOne = try #require(rowOneInk.first)

        #expect(bottomOfRowZero < topOfRowOne)
    }
}

struct UnicodeSample: Sendable, CustomTestStringConvertible {
    let text: String
    let columnCount: Int

    var testDescription: String { text }
}
