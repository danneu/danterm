// Behavioral proofs for packaged Nerd Font loading, PUA routing, and cell containment.
import CoreGraphics
import CoreText
import Foundation
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

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

    @Test("The public entry point projects the packaged resource at the requested size")
    func publicEntryPointMatchesPackagedResource() throws {
        // Intent: the one public seam hands back the same face the packaged
        //   resource would, at the size the caller asked for.
        // Why it exists: the seam exists so callers outside this module cannot
        //   reach the loader; it is only correct if it still serves the face.
        // Scenario: a host tool asks for a 13 point face and compares it against
        //   the same projection taken from the resource directly.
        let resource = try #require(NerdFontSymbolsResource.packaged)
        let face = try #require(PackagedSymbolsFace.face(pointSize: 13))

        #expect(CTFontGetSize(face) == 13)
        #expect(CTFontCopyPostScriptName(face) == CTFontCopyPostScriptName(
            resource.face(pointSize: 13)
        ))
    }

    @Test("The packaged symbols face is loaded from its resource file")
    func packagedFaceSource() throws {
        let resource = try #require(NerdFontSymbolsResource.packaged)
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let face = try #require(metrics.fonts.symbols)

        #expect(metrics.fonts.symbolsResourceURL == resource.sourceURL)
        #expect(CTFontCopyPostScriptName(face.font) == "SymbolsNFM" as CFString)
    }

    @Test("The symbols face starts at the metrics base font size")
    func symbolsFaceStartsAtBaseFontSize() throws {
        for scale in [1.0, 2.0] as [CGFloat] {
            for size in [9.0, 13.0, 24.0] as [CGFloat] {
                for family in [nil, "Menlo"] as [String?] {
                    let metrics = try #require(TerminalRenderMetrics(
                        displayScale: scale,
                        fontSize: size,
                        fontFamily: family
                    ))
                    let symbolsFont = try #require(metrics.fonts.symbols?.font)
                    let bitmap = try renderBitmap(
                        plan: makePlan(input: "\u{F07B}X", columns: 3, rows: 1),
                        metrics: metrics
                    )
                    let cell = cellRect(row: 0, column: 0, metrics: metrics)
                    let ink = try #require(bitmap.inkBounds(in: cell))

                    #expect(CTFontGetSize(symbolsFont) == metrics.baseFontSize)
                    #expect(ink.x.count >= metrics.cellWidthPixels - 2)
                    #expect(abs(
                        (ink.x.lowerBound - cell.x.lowerBound)
                            - (cell.x.upperBound - ink.x.upperBound)
                    ) <= 1)
                }
            }
        }

        let resource = try #require(NerdFontSymbolsResource.packaged)
        let suppliedBaseFont = CTFontCreateWithName("Menlo" as CFString, 19, nil)
        let mismatched = try #require(TerminalRenderMetrics(
            displayScale: 2,
            baseFont: suppliedBaseFont,
            symbolsResource: resource
        ))
        let symbolsFont = try #require(mismatched.fonts.symbols?.font)
        let mismatchedBitmap = try renderBitmap(
            plan: makePlan(input: "\u{F07B}X", columns: 3, rows: 1),
            metrics: mismatched
        )
        let mismatchedCell = cellRect(row: 0, column: 0, metrics: mismatched)
        let mismatchedInk = try #require(mismatchedBitmap.inkBounds(in: mismatchedCell))

        #expect(mismatched.baseFontSize == 19)
        #expect(mismatched.cellSize.width != mismatched.baseFontSize)
        #expect(CTFontGetSize(symbolsFont) == mismatched.baseFontSize)
        #expect(mismatchedInk.x.count >= mismatched.cellWidthPixels - 2)
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

    @Test("A branch icon uses text height and is vertically centered", arguments: [1.0, 2.0])
    func branchIconUsesTextHeight(scale: CGFloat) throws {
        // Intent: a packaged branch icon that fits at configured text size is at
        //   least cap-height tall and centered in its terminal cell.
        // Why it exists: sizing the symbols face from cell width made prompt
        //   branch icons visibly shorter than the text beside them on Retina.
        // Scenario: a lualine-style U+E0A0 branch icon precedes ` master`.
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let branch = try renderBitmap(
            plan: makePlan(input: "\u{E0A0} master", columns: 9, rows: 1),
            metrics: metrics
        )
        let cap = try renderBitmap(
            plan: makePlan(input: "M", columns: 2, rows: 1),
            metrics: metrics
        )
        let branchCell = cellRect(row: 0, column: 0, metrics: metrics)
        let capCell = cellRect(row: 0, column: 0, metrics: metrics)
        let branchInk = try #require(branch.inkBounds(in: branchCell))
        let capInk = try #require(cap.inkBounds(in: capCell))
        let topPadding = branchInk.y.lowerBound - branchCell.y.lowerBound
        let bottomPadding = branchCell.y.upperBound - branchInk.y.upperBound

        #expect(branchInk.y.count >= capInk.y.count)
        #expect(abs(topPadding - bottomPadding) <= 1)
    }

    @Test("Sprites and configured-face PUA glyphs keep precedence over packaged symbols")
    func existingRoutesKeepPrecedence() throws {
        let withSymbols = try #require(TerminalRenderMetrics(displayScale: 2))
        let withoutSymbols = try #require(TerminalRenderMetrics(
            displayScale: 2,
            symbolsResource: nil
        ))

        for scalar in ["\u{E0B0}", "\u{F8FF}"] {
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

    @Test("Representative packaged symbols fit, center, and keep source proportions", arguments: [1.0, 2.0])
    func packagedSymbolsFitWithoutDistortion(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let symbolsFont = try #require(metrics.fonts.symbols?.font)

        for scalar in ["\u{E0A0}", "\u{F07B}", "\u{F0219}"] {
            let bitmap = try renderBitmap(
                plan: makePlan(input: scalar + "X", columns: 3, rows: 1),
                metrics: metrics
            )
            let cell = cellRect(row: 0, column: 0, metrics: metrics)
            let ink = try #require(bitmap.inkBounds(in: cell))
            let sourceBounds = try glyphBounds(
                for: try #require(scalar.unicodeScalars.first),
                font: symbolsFont
            )
            let fit = min(
                metrics.cellSize.width / sourceBounds.width,
                metrics.cellSize.height / sourceBounds.height,
                1
            )
            let expectedWidth = sourceBounds.width * fit * scale
            let expectedHeight = sourceBounds.height * fit * scale
            let horizontalPadding = (
                ink.x.lowerBound - cell.x.lowerBound,
                cell.x.upperBound - ink.x.upperBound
            )
            let verticalPadding = (
                ink.y.lowerBound - cell.y.lowerBound,
                cell.y.upperBound - ink.y.upperBound
            )

            #expect(abs(CGFloat(ink.x.count) - expectedWidth) <= 3, Comment(rawValue: scalar))
            #expect(abs(CGFloat(ink.y.count) - expectedHeight) <= 3, Comment(rawValue: scalar))
            #expect(abs(horizontalPadding.0 - horizontalPadding.1) <= 1)
            #expect(abs(verticalPadding.0 - verticalPadding.1) <= 1)
        }
    }

    @Test("A full-em symbol uses its span and cannot alter later text", arguments: [1.0, 2.0])
    func fullEmSymbolUsesContainedSpan(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let icon = try renderBitmap(
            plan: makePlan(input: "\u{F07B}X", columns: 3, rows: 1),
            metrics: metrics
        )
        let control = try renderBitmap(
            plan: makePlan(input: "\u{1B}[2GX", columns: 3, rows: 1),
            metrics: metrics
        )
        let iconCell = cellRect(row: 0, column: 0, metrics: metrics)
        let trailingCell = cellRect(row: 0, column: 1, metrics: metrics)
        let ink = try #require(icon.inkBounds(in: iconCell))

        #expect(ink.x.count >= metrics.cellWidthPixels - 2)
        #expect(icon.bytes(in: trailingCell) == control.bytes(in: trailingCell))
    }

    @Test("A mapped zero-ink glyph stays blank and cannot alter later text")
    func zeroInkSymbolStaysBlank() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let face = try #require(metrics.fonts.symbols)
        let scalar = try #require(firstZeroInkScalar(in: face))
        let rendered = try renderBitmap(
            plan: makePlan(input: scalar.description + "X", columns: 3, rows: 1),
            metrics: metrics
        )
        let control = try renderBitmap(
            plan: makePlan(input: "\u{1B}[2GX", columns: 3, rows: 1),
            metrics: metrics
        )

        #expect(rendered.inkCount(in: cellRect(row: 0, column: 0, metrics: metrics)) == 0)
        #expect(rendered.bytes(in: cellRect(row: 0, column: 1, metrics: metrics))
            == control.bytes(in: cellRect(row: 0, column: 1, metrics: metrics)))
    }

    @Test("A mapped configured-face astral glyph uses the unclipped nominal path")
    func configuredAstralGlyphUsesNominalPath() throws {
        let resource = try #require(NerdFontSymbolsResource.packaged)
        let configuredFont = resource.face(pointSize: 13)
        let metrics = try #require(TerminalRenderMetrics(
            displayScale: 2,
            baseFont: configuredFont,
            symbolsResource: nil
        ))
        let face = metrics.fonts.regular
        let scalar = try #require((UInt32(0xF0000)...UInt32(0xFFFFD)).first { value in
            guard var glyph = face.nominalGlyph(value) else { return false }
            let bounds = CTFontGetBoundingRectsForGlyphs(face.font, .horizontal, &glyph, nil, 1)
            return bounds.minX >= 0 && bounds.maxX > metrics.cellSize.width
        })
        let text = try #require(Unicode.Scalar(scalar)).description
        let bitmap = try renderBitmap(
            plan: makePlan(input: text, columns: 2, rows: 1),
            metrics: metrics
        )
        let withPackagedSymbols = try #require(TerminalRenderMetrics(
            displayScale: 2,
            baseFont: configuredFont,
            symbolsResource: resource
        ))
        let packagedControl = try renderBitmap(
            plan: makePlan(input: text, columns: 2, rows: 1),
            metrics: withPackagedSymbols
        )
        let bmpScalar = try #require((UInt32(0xE000)...UInt32(0xF8FF)).first { value in
            guard var glyph = face.nominalGlyph(value) else { return false }
            let bounds = CTFontGetBoundingRectsForGlyphs(face.font, .horizontal, &glyph, nil, 1)
            return bounds.minX >= 0 && bounds.maxX <= metrics.cellSize.width
        })
        let bmp = try #require(Unicode.Scalar(bmpScalar)).description
        let mixed = try renderBitmap(
            plan: makePlan(input: bmp + "\u{1B}[3;1H" + text, columns: 2, rows: 3),
            metrics: metrics
        )
        let bmpOnly = try renderBitmap(
            plan: makePlan(input: bmp, columns: 2, rows: 3),
            metrics: metrics
        )
        let astralOnly = try renderBitmap(
            plan: makePlan(input: "\u{1B}[3;1H" + text, columns: 2, rows: 3),
            metrics: metrics
        )

        #expect(bitmap.inkCount(in: cellRect(row: 0, column: 1, metrics: metrics)) > 0)
        expectBitmap(packagedControl, matches: bitmap)
        let firstRow = cellRect(row: 0, column: 0, columnCount: 2, metrics: metrics)
        let secondRow = cellRect(row: 2, column: 0, columnCount: 2, metrics: metrics)
        #expect(mixed.bytes(in: firstRow) == bmpOnly.bytes(in: firstRow))
        #expect(mixed.bytes(in: secondRow) == astralOnly.bytes(in: secondRow))
        #expect(face.nominalGlyph(0x1F600) == nil)
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

    @Test("Packaged astral and fallback runs render as they do alone")
    func packagedAstralAndFallbackRunsStayIsolated() throws {
        // Intent: a packaged plane-15 run and a fallback-only run each own only
        //   their glyphs, positions, and candidate state.
        // Why it exists: astral candidates occupy two UTF-16 slots while both
        //   routes reuse the same per-draw buffers across styled runs.
        // Scenario: a plane-15 prompt icon is followed by emoji on another row.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let packaged = "\u{1B}[31m\u{F0219}"
        let fallback = "\u{1B}[3;1H\u{1B}[34m😀"
        let combined = try renderBitmap(
            plan: makePlan(input: packaged + fallback, columns: 4, rows: 3),
            metrics: metrics
        )
        let packagedOnly = try renderBitmap(
            plan: makePlan(input: packaged, columns: 4, rows: 3),
            metrics: metrics
        )
        let fallbackOnly = try renderBitmap(
            plan: makePlan(input: fallback, columns: 4, rows: 3),
            metrics: metrics
        )
        let firstRow = cellRect(row: 0, column: 0, columnCount: 4, metrics: metrics)
        let lastRow = cellRect(row: 2, column: 0, columnCount: 4, metrics: metrics)

        #expect(combined.bytes(in: firstRow) == packagedOnly.bytes(in: firstRow))
        #expect(combined.bytes(in: lastRow) == fallbackOnly.bytes(in: lastRow))
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

private func glyphBounds(for scalar: Unicode.Scalar, font: CTFont) throws -> CGRect {
    var characters = Array(String(scalar).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    try #require(CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count))
    var glyph = try #require(glyphs.first)
    let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
    return try #require(bounds.isEmpty == false ? bounds : nil)
}

private func firstZeroInkScalar(in face: TerminalFace) -> Unicode.Scalar? {
    for range in [
        UInt32(0xE000)...UInt32(0xF8FF),
        UInt32(0xF0000)...UInt32(0xFFFFD),
    ] {
        for value in range {
            guard var glyph = face.nominalGlyph(value) else { continue }
            let bounds = CTFontGetBoundingRectsForGlyphs(
                face.font,
                .horizontal,
                &glyph,
                nil,
                1
            )
            if bounds.isEmpty, let scalar = Unicode.Scalar(value) {
                return scalar
            }
        }
    }
    return nil
}
