// Classification and bitmap proofs for Ghostty's complete legacy-computing family.
import CoreGraphics
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

struct LegacyComputingSpriteExecutionTests {
    @Test("Representative shape classes render cell-locally at scales 1 and 2", arguments: [1.0, 2.0])
    func representativeRendering(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let representatives = [
            "\u{1FB00}", "\u{1FB3C}", "\u{1FB68}", "\u{1FB70}", "\u{1FB7C}",
            "\u{1FB8C}", "\u{1FB95}", "\u{1FB98}", "\u{1FB9A}", "\u{1FBA0}",
            "\u{1FBAF}", "\u{1FBBD}", "\u{1FBCE}", "\u{1FBD0}", "\u{1FBE0}", "\u{1FBE8}",
        ]
        let foreground = Pixel(RenderTheme.dark.ansiColors[1])
        let background = Pixel(RenderTheme.dark.defaultBackground)
        for scalar in representatives {
            let bitmap = try renderBitmap(
                plan: makePlan(input: "\u{1B}[31m\(scalar)", columns: 2, rows: 1),
                metrics: metrics
            )
            let cell = cellRect(row: 0, column: 0, metrics: metrics)
            let neighbor = cellRect(row: 0, column: 1, metrics: metrics)
            #expect(bitmap.pixels(in: cell).contains { $0 != background })
            #expect(bitmap.pixels(in: cell).allSatisfy {
                $0.alpha == 255
                    && (min(foreground.red, background.red)...max(foreground.red, background.red)).contains($0.red)
            })
            #expect(bitmap.pixels(in: neighbor).allSatisfy { $0 == background })
        }
    }

    @Test("Legacy sprites, text, and adjacent sprites redraw and replace without stale pixels")
    func replacementAndRedraw() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        for pair in [("\u{1FB95}", "\u{1FBE8}"), ("\u{1FB68}", "A"), ("A", "\u{1FBD8}")] {
            let previous = try makePlan(input: pair.0 + "\u{1FB70}\r\nkeep", columns: 4, rows: 2)
            let current = try makePlan(input: pair.1 + "\u{1FB70}\r\nkeep", columns: 4, rows: 2)
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
                dirtyRect: CGRect(
                    x: 0, y: 0,
                    width: metrics.cellSize.width * 4,
                    height: metrics.cellSize.height
                ),
                metrics: metrics
            )
            expectBitmap(damaged, matches: full)
            expectBitmap(dirty, matches: full)
        }
    }
}
