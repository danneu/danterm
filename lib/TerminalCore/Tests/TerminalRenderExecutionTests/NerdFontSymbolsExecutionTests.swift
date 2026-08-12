// Behavioral proofs for packaged Nerd Font loading, BMP-PUA routing, and cell containment.
import CoreGraphics
import CoreText
import Foundation
import Testing

import TerminalCore
@testable import TerminalRenderExecution

struct NerdFontSymbolsExecutionTests {
    @Test("The packaged symbols resource is loaded once per process")
    func packagedResourceIsShared() throws {
        // Intent: every caller resolves the same parsed packaged resource.
        // Why it exists: loading from the resource URL per font set retained one
        //   multi-megabyte font buffer per terminal pane.
        // Scenario: two independent resolutions in one process compare by identity.
        let first = try #require(NerdFontSymbolsResource.packaged)
        let second = try #require(NerdFontSymbolsResource.packaged)

        #expect(first === second)
    }

    @Test("The packaged symbols face is loaded from its resource file at one-cell em size")
    func packagedFaceSourceAndSize() throws {
        let resource = try #require(NerdFontSymbolsResource.packaged)
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let face = try #require(metrics.fonts.symbols)

        #expect(metrics.fonts.symbolsResourceURL == resource.sourceURL)
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
            symbolsResource: nil
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
            symbolsResource: nil
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
            expectBitmap(routed, matches: control, Comment(rawValue: scalar))
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

    @Test("The packaged symbols face references its font file rather than a copy of its bytes")
    func packagedFaceReferencesItsFile() throws {
        // Intent: every face projected from the packaged resource resolves back to
        //   the font file on disk.
        // Why it exists: reading the 2.4 MB resource into a Data and building the
        //   descriptor from those bytes left one permanently dirty malloc buffer
        //   alive for the whole process, because the descriptor retains the data
        //   it was created from and the resource is process-wide. A face built
        //   from the file instead lets CoreText map it, so the bytes stay clean
        //   and file-backed. A face carrying no URL is the observable signature of
        //   the copying path.
        // Scenario: the packaged resource projects a face, which is asked where it
        //   came from.
        let resource = try #require(NerdFontSymbolsResource.packaged)
        let face = resource.face(pointSize: 12)

        let attribute = try #require(CTFontCopyAttribute(face, kCTFontURLAttribute))
        #expect((attribute as! NSURL) as URL == resource.sourceURL)
    }

    @Test("A readable file that is not a font disables the symbols feature")
    func nonFontFileDisablesSymbols() throws {
        // Intent: a resource URL that resolves to readable non-font bytes yields no
        //   resource, exactly like a missing file.
        // Why it exists: loading from a URL reports failure as either a null or an
        //   empty descriptor array, so an unchecked first element would trap on
        //   input that the byte-loading path rejected by returning nil.
        // Scenario: a temporary file holding plain text is offered as the resource.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("danterm-not-a-font-\(UUID().uuidString).ttf")
        try Data("not a font".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(NerdFontSymbolsResource.load(at: url) == nil)
    }

    @Test("An unreadable symbols resource preserves the no-symbols rendering path")
    func unreadableResourcePreservesOldPath() throws {
        let missing = URL(fileURLWithPath: "/no/such/DanTerm-symbols-font.ttf")
        let unavailable = try #require(TerminalRenderMetrics(
            displayScale: 2,
            symbolsResource: NerdFontSymbolsResource.load(at: missing)
        ))
        let absent = try #require(TerminalRenderMetrics(displayScale: 2, symbolsResource: nil))
        let plan = try makePlan(input: "\u{F07B}X", columns: 3, rows: 1)

        #expect(unavailable.fonts.symbols == nil)
        #expect(try renderBitmap(plan: plan, metrics: unavailable).bytes
            == renderBitmap(plan: plan, metrics: absent).bytes)
    }
}
