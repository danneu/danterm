// Classification and bitmap proofs for the complete Powerline sprite family.
import CoreGraphics
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

struct PowerlineSpriteExecutionTests {
    @Test("All glyphs render in the foreground, clip to their cell, and isolate adjacency", arguments: [1.0, 2.0])
    func exhaustiveBitmapCoverage(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let scalars = (UInt32(0xE0B0)...UInt32(0xE0BF)).map { Unicode.Scalar($0)! }
            + ["\u{E0D2}", "\u{E0D4}"]
        for scalar in scalars {
            let bitmap = try renderBitmap(
                plan: makePlan(input: "\u{1B}[31m\(scalar)", columns: 2, rows: 1),
                metrics: metrics
            )
            let cell = cellRect(row: 0, column: 0, metrics: metrics)
            let adjacent = cellRect(row: 0, column: 1, metrics: metrics)
            let foreground = Pixel(RenderTheme.dark.ansiColors[1])
            let background = Pixel(RenderTheme.dark.defaultBackground)
            #expect(bitmap.pixels(in: cell).contains { $0 != background })
            #expect(bitmap.pixels(in: cell).allSatisfy {
                $0.alpha == 255
                    && (min(foreground.red, background.red)...max(foreground.red, background.red)).contains($0.red)
            })
            #expect(bitmap.pixels(in: adjacent).allSatisfy { $0 == background })
        }
    }

    @Test("Adjacent hard dividers share their boundary midpoint without leaking", arguments: [1.0, 2.0])
    func adjacency(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let bitmap = try renderBitmap(
            plan: makePlan(input: "\u{E0B0}\u{E0B2}", columns: 2, rows: 1),
            metrics: metrics
        )
        let background = Pixel(RenderTheme.dark.defaultBackground)
        let boundary = metrics.cellWidthPixels
        let middle = metrics.cellHeightPixels / 2
        #expect(bitmap.pixel(x: boundary - 1, yFromTop: middle) != background)
        #expect(bitmap.pixel(x: boundary, yFromTop: middle) != background)
    }

    @Test("Powerline, text, and other sprites replace one another without stale pixels")
    func replacementAndRedraw() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        for pair in [("\u{E0B4}", "\u{E0B5}"), ("\u{E0D2}", "A"), ("A", "\u{E0BA}")] {
            let previous = try makePlan(input: pair.0 + "\r\nkeep", columns: 4, rows: 2)
            let current = try makePlan(input: pair.1 + "\r\nkeep", columns: 4, rows: 2)
            let full = try renderBitmap(plan: current, metrics: metrics)
            let damaged = try renderIncrementalBitmap(
                previous: previous,
                current: current,
                damage: TerminalDamage(rows: [0]),
                metrics: metrics
            )
            let dirty = try renderDirtyRectBitmap(
                previous: previous,
                current: current,
                dirtyRect: CGRect(x: 0, y: 0, width: metrics.cellSize.width * 4, height: metrics.cellSize.height),
                metrics: metrics
            )
            expectBitmap(damaged, matches: full)
            expectBitmap(dirty, matches: full)
        }
    }
}
