// Proofs that the CTLine fallback states the presentation Unicode defines: a bare
// default-text emoji variation base gains U+FE0E on the way to CoreText, every other
// fallback cell is submitted exactly as the stream wrote it, and the appended selector
// never costs a scalar its glyph.
//
// The submitted-sequence proof lives here rather than in a bitmap because macOS resolves
// U+23FA to the same text face with and without the selector, so the pixels are identical
// on this host and cannot tell whether the rule ran at all.
import CoreGraphics
import CoreText
import Foundation
import Testing

import TerminalCore
@testable import TerminalRenderExecution

struct PresentationSelectorExecutionTests {
    @Test("A bare default-text base reaches CoreText with the text selector appended")
    func fallbackStatesTextPresentation() throws {
        // Intent: rendering a frame whose only fallback cell holds U+23FA submits
        //   U+23FA U+FE0E to CoreText.
        // Why it exists: the classifier and its gate are pure and already pinned, so
        //   every unit proof of them passes against a draw path that never calls them.
        //   This is the one assertion that goes red if the append is deleted from
        //   `drawTextCell`, or if the fallback stops asking.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let plan = try makePlan(input: "\u{23FA}", columns: 4, rows: 1)
        let log = SubmissionLog()

        _ = try withFallbackSubmissionObserver({ log.record($0) }) {
            try renderBitmap(plan: plan, metrics: metrics)
        }

        #expect(log.recorded == ["\u{23FA}\u{FE0E}"])
    }

    @Test("A cell that stated its own presentation is submitted unchanged")
    func fallbackLeavesAStatedPresentationAlone() throws {
        // Intent: a cell holding U+23FA U+FE0F reaches CoreText as those two scalars,
        //   with no second selector appended.
        // Why it exists: the gate's exclusions are what keep the rule from demoting a
        //   cell the stream asked for as emoji and the grid then sized wide. A blanket
        //   append would pass the included case above and break this one silently.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let plan = try makePlan(input: "\u{23FA}\u{FE0F}", columns: 4, rows: 1)
        let log = SubmissionLog()

        _ = try withFallbackSubmissionObserver({ log.record($0) }) {
            try renderBitmap(plan: plan, metrics: metrics)
        }

        #expect(log.recorded == ["\u{23FA}\u{FE0F}"])
    }

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

/// Collects the strings the fallback submitted during one draw.
///
/// A class so the observer closure the executor holds and the test that reads the result
/// share one box; locked because the observer's type is `Sendable` and nothing in the
/// signature promises the executor stays on the calling thread.
private final class SubmissionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String] = []

    func record(_ submitted: String) {
        lock.lock()
        defer { lock.unlock() }
        strings.append(submitted)
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return strings
    }
}
