// Proofs that a drawn default-text symbol is monochrome ink in its cell, and that stating
// text presentation never costs a scalar its glyph.
//
// What is deliberately not proved here: that `drawTextCell` appends the selector at all.
// macOS resolves U+23FA to the same text face with and without U+FE0E, so no bitmap on
// this host can see the difference, and the seam that made the submitted sequence
// observable was removed as test bloat -- iOS shows the regression on sight, and this is a
// one-user app whose user runs it there.
import CoreGraphics
import CoreText
import Foundation
import Testing

import TerminalCore
@testable import TerminalRenderExecution

struct PresentationSelectorExecutionTests {
    @Test("A drawn U+23FA cell has ink and none of it is chromatic")
    func drawnMarkerIsMonochromeInk() throws {
        // Intent: the frame Claude Code's tool-line marker produces draws something, and
        //   no pixel in it has disagreeing color channels.
        // Why it exists: this is the failure as seen -- a color glyph clipped into a
        //   narrow cell on the phone. Both halves are needed: "no chromatic pixel" alone
        //   also passes on an empty cell and on a missing-glyph box, so it cannot tell a
        //   text glyph from no glyph. The chromatic half is vacuous on macOS today and is
        //   written against the draw path so it binds wherever the suite runs.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let plan = try makePlan(input: "\u{23FA}", columns: 4, rows: 1)
        let bitmap = try renderBitmap(plan: plan, metrics: metrics)

        #expect(bitmap.inkCount(in: cellRect(row: 0, column: 0, metrics: metrics)) > 0)

        // The whole surface, not just the cell: the terminal's baked defaults are both
        // achromatic, so a chromatic pixel anywhere is color-glyph ink -- including ink
        // that overhung the cell it was drawn for.
        let surface = PixelRect(x: 0..<bitmap.width, y: 0..<bitmap.height)
        let chromatic = bitmap.pixels(in: surface).filter {
            $0.red != $0.green || $0.green != $0.blue
        }
        let firstChromatic = chromatic.first.map { "\($0)" } ?? "none"
        #expect(
            chromatic.isEmpty,
            "\(chromatic.count) chromatic pixels; first: \(firstChromatic)"
        )
    }

    @Test("Every scalar the gate transforms still resolves to a glyph with U+FE0E appended")
    func gatedScalarsKeepTheirGlyphs() throws {
        // Intent: across the whole codespace, each scalar the gate appends U+FE0E to
        //   resolves through CoreText to a real glyph for the base scalar, never the
        //   missing-glyph box.
        // Why it exists: U+FE0E is a preference and not a restriction, so a scalar no
        //   text face covers must still fall through to a face that can draw it. Reading
        //   the gated set from the generated table rather than a literal list keeps this
        //   exhaustive when the Unicode pin moves. Resolved output is the observable: a
        //   face that carries the scalar proves nothing about which face CoreText picks
        //   for the appended sequence.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let font = metrics.fonts.face(bold: false, italic: false).font
        var gatedCount = 0
        var unresolved: [String] = []

        for value in 0...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            guard let selector = terminalPresentationSelectorToAppend(for: [scalar]) else {
                continue
            }
            gatedCount += 1
            var scalars = String.UnicodeScalarView()
            scalars.append(scalar)
            scalars.append(selector)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: String(scalars),
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
            ))
            if baseScalarGlyph(of: line) ?? 0 == 0 {
                unresolved.append("U+\(String(value, radix: 16, uppercase: true))")
            }
        }

        #expect(gatedCount > 0, "the gate transforms no scalar at all")
        #expect(
            unresolved.isEmpty,
            "\(unresolved.count) gated scalars lost their glyph; first: \(unresolved.first ?? "")"
        )
    }

    /// The glyph CoreText chose for the first scalar of the line, or nil when the line
    /// produced no run covering it.
    ///
    /// Reads the glyph by string index rather than by position, because a variation
    /// selector may occupy a glyph slot of its own and asking "does any glyph equal 0"
    /// would then report a missing base glyph for every gated scalar.
    private func baseScalarGlyph(of line: CTLine) -> CGGlyph? {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRangeMake(0, count), &indices)
            guard let slot = indices.firstIndex(of: 0) else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            return glyphs[slot]
        }
        return nil
    }
}
