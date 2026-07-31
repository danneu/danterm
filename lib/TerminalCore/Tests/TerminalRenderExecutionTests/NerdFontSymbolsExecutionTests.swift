// Behavioral proofs for packaged Nerd Font loading, BMP-PUA routing, and cell containment.
import CoreGraphics
import CoreText
import Foundation
import Testing

import TerminalCore
@testable import TerminalRenderExecution

struct NerdFontSymbolsExecutionTests {
    @Test("The packaged symbols face is loaded from its resource bytes at one-cell em size")
    func packagedFaceSourceAndSize() throws {
        let resourceURL = try #require(NerdFontSymbolsResource.packagedURL())
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let face = try #require(metrics.fonts.symbols)

        #expect(metrics.fonts.symbolsResourceURL == resourceURL)
        #expect(CTFontGetSize(face.font) == metrics.cellSize.width)
        #expect(CTFontCopyPostScriptName(face.font) == "SymbolsNFM" as CFString)
    }

    @Test("Every mapped BMP private-use glyph advances exactly one terminal cell")
    func everyMappedPrivateUseGlyphAdvancesOneCell() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let font = try #require(metrics.fonts.symbols?.font)
        var mappedCount = 0

        for value in UInt32(0xE000)...UInt32(0xF8FF) {
            var character = UniChar(value)
            var glyph = CGGlyph()
            _ = CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
            guard glyph != 0 else { continue }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            #expect(advance.width == metrics.cellSize.width)
            mappedCount += 1
        }

        #expect(mappedCount == 3500)
    }

    @Test("The base face and CoreText cascade both decline a BMP private-use icon")
    func coreTextDeclinesBMPPrivateUseFallback() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let scalar: Unicode.Scalar = "\u{F07B}"
        let baseFont = metrics.fonts.regular.font
        var character = UniChar(scalar.value)
        var glyph = CGGlyph()

        #expect(CTFontGetGlyphsForCharacters(baseFont, &character, &glyph, 1) == false)
        #expect(glyph == 0)

        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: String(scalar),
            attributes: [kCTFontAttributeName as NSAttributedString.Key: baseFont]
        ))
        let runs = CTLineGetGlyphRuns(line) as NSArray
        let runObject = try #require(runs.firstObject)
        let run = runObject as! CTRun
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let selectedFontObject = try #require(attributes[kCTFontAttributeName])
        let selectedFont = selectedFontObject as! CTFont
        #expect(CTFontCopyPostScriptName(selectedFont) == "LastResort" as CFString)
    }

    @Test("A mapped BMP private-use icon renders packaged ink in one cell", arguments: [1.0, 2.0])
    func privateUseIconRendering(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let metricsWithoutSymbols = try #require(TerminalRenderMetrics(
            displayScale: scale,
            symbolsFontURL: nil
        ))
        let icon = try renderBitmap(
            plan: makePlan(input: "\u{F07B}X", columns: 3, rows: 1),
            metrics: metrics
        )
        let oldPath = try renderBitmap(
            plan: makePlan(input: "\u{F07B}X", columns: 3, rows: 1),
            metrics: metricsWithoutSymbols
        )
        let trailingControl = try renderBitmap(
            plan: makePlan(input: "\u{1B}[2GX", columns: 3, rows: 1),
            metrics: metrics
        )
        let iconCell = cellRect(row: 0, column: 0, metrics: metrics)
        let trailingCell = cellRect(row: 0, column: 1, metrics: metrics)

        #expect(icon.inkCount(in: iconCell) > 0)
        #expect(icon.bytes(in: iconCell) != oldPath.bytes(in: iconCell))
        #expect(icon.bytes(in: trailingCell) == trailingControl.bytes(in: trailingCell))
        #expect(icon.inkCount(in: cellRect(row: 0, column: 2, metrics: metrics)) == 0)
    }

    @Test("Existing sprite, base-face PUA, and supplementary PUA routes stay byte-identical")
    func existingRoutesKeepPrecedence() throws {
        let withSymbols = try #require(TerminalRenderMetrics(displayScale: 2))
        let withoutSymbols = try #require(TerminalRenderMetrics(
            displayScale: 2,
            symbolsFontURL: nil
        ))

        for scalar in ["\u{E0B0}", "\u{F8FF}", "\u{F0219}"] {
            let routed = try renderBitmap(
                plan: makePlan(input: scalar + "X", columns: 3, rows: 1),
                metrics: withSymbols
            )
            let control = try renderBitmap(
                plan: makePlan(input: scalar + "X", columns: 3, rows: 1),
                metrics: withoutSymbols
            )
            #expect(routed.bytes == control.bytes, Comment(rawValue: scalar))
        }
    }

    @Test("A symbols cell does not leak into a later text run")
    func symbolsScratchDoesNotLeak() throws {
        // Intent: a later run draws only its own cells after an earlier run used
        //   the packaged symbols route.
        // Why it exists: symbols cells use a retained per-draw scratch buffer;
        //   missing its per-run reset would redraw the prior icon on later rows.
        // Scenario: a Nerd Font icon on one terminal row is followed by ordinary
        //   text at a different column on the next row.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let content = try renderBitmap(
            plan: makePlan(input: "\u{F07B}\u{1B}[2;2HA", columns: 3, rows: 2),
            metrics: metrics
        )
        let control = try renderBitmap(
            plan: makePlan(input: "\u{1B}[2;2HA", columns: 3, rows: 2),
            metrics: metrics
        )
        let secondRow = cellRect(row: 1, column: 0, columnCount: 3, metrics: metrics)

        #expect(content.bytes(in: secondRow) == control.bytes(in: secondRow))
    }

    @Test("An unreadable symbols resource preserves the no-symbols rendering path")
    func unreadableResourcePreservesOldPath() throws {
        let missing = URL(fileURLWithPath: "/no/such/DanTerm-symbols-font.ttf")
        let unavailable = try #require(TerminalRenderMetrics(
            displayScale: 2,
            symbolsFontURL: missing
        ))
        let absent = try #require(TerminalRenderMetrics(displayScale: 2, symbolsFontURL: nil))
        let plan = try makePlan(input: "\u{F07B}X", columns: 3, rows: 1)

        #expect(unavailable.fonts.symbols == nil)
        #expect(try renderBitmap(plan: plan, metrics: unavailable).bytes
            == renderBitmap(plan: plan, metrics: absent).bytes)
    }
}
