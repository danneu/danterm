// Bitmap proofs for supplement sprites. Decoding is proved in TerminalSpriteGeometryTests.
import CoreGraphics
import Testing
import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning
import TerminalSpriteGeometry

struct LegacyComputingSupplementSpriteExecutionTests {
    @Test("Every supported scalar renders only inside its cell", arguments: [1.0, 2.0])
    func exhaustiveBitmapCoverage(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let background = Pixel(RenderTheme.dark.defaultBackground)
        for range in LegacyComputingSupplementSpriteGeometry.implementedRanges {
            for value in range {
                let scalar = Unicode.Scalar(value)!
                let bitmap = try renderBitmap(
                    plan: makePlan(input: "\u{1B}[31m\(String(scalar))", columns: 2, rows: 1),
                    metrics: metrics
                )
                let cell = cellRect(row: 0, column: 0, metrics: metrics)
                let adjacent = cellRect(row: 0, column: 1, metrics: metrics)
                #expect(
                    bitmap.pixels(in: cell).contains { $0 != background },
                    "U+\(String(value, radix: 16, uppercase: true))"
                )
                #expect(bitmap.pixels(in: adjacent).allSatisfy { $0 == background })
            }
        }
    }

    @Test("Supplement damage-row and dirty-rect redraws match a fresh frame")
    func incrementalRedraws() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let previous = try makePlan(input: "\u{1CD00}\r\nkeep", columns: 4, rows: 2)
        let current = try makePlan(input: "\u{1CEAF}\r\nkeep", columns: 4, rows: 2)
        let full = try renderBitmap(plan: current, metrics: metrics)
        let dirtyRect = CGRect(
            x: 0, y: 0,
            width: metrics.cellSize.width * 4,
            height: metrics.cellSize.height
        )
        let damaged = try renderIncrementalBitmap(
            previous: previous, current: current,
            damage: TerminalDamage(rows: [0]), metrics: metrics
        )
        let dirty = try renderDirtyRectBitmap(
            previous: previous, current: current, dirtyRect: dirtyRect, metrics: metrics
        )
        expectBitmap(damaged, matches: full)
        expectBitmap(dirty, matches: full)
    }
}
