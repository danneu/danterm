// Behavioral and bitmap proofs for executor-local Unicode Block Elements sprites.
import CoreGraphics
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

struct BlockElementSpriteExecutionTests {
    @Test("All 32 Block Elements render as contained, pixel-aligned sprites", arguments: [1.0, 2.0])
    func exhaustiveBitmapCoverage(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        for value in UInt32(0x2580)...UInt32(0x259F) {
            let scalar = Unicode.Scalar(value)!
            let bitmap = try renderBitmap(
                plan: makePlan(input: "\u{1B}[31m\(String(scalar))", columns: 2, rows: 1),
                metrics: metrics
            )
            let cell = cellRect(row: 0, column: 0, metrics: metrics)
            let adjacent = cellRect(row: 0, column: 1, metrics: metrics)
            let background = Pixel(RenderTheme.dark.defaultBackground)

            #expect(bitmap.pixels(in: cell).contains { $0 != background })
            #expect(bitmap.pixels(in: adjacent).allSatisfy { $0 == background })
        }
    }

    @Test("Odd-size quadrant pairs cover the cell without a background seam")
    func seamFreeQuadrants() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 1))
        let bitmap = try renderBitmap(
            plan: makePlan(input: "\u{259B}", columns: 2, rows: 1),
            metrics: metrics
        )
        let cell = cellRect(row: 0, column: 0, metrics: metrics)
        let background = Pixel(RenderTheme.dark.defaultBackground)
        let topRows = cell.y.prefix((metrics.cellHeightPixels + 1) / 2)

        #expect(topRows.flatMap { y in cell.x.map { bitmap.pixel(x: $0, yFromTop: y) } }
            .allSatisfy { $0 != background })
    }

    @Test("Shade glyphs cover the cell at increasing foreground intensity")
    func shadeIntensity() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let bitmap = try renderBitmap(
            plan: makePlan(input: "\u{2591}\u{2592}\u{2593}\u{2588}", columns: 4, rows: 1),
            metrics: metrics
        )
        let background = Pixel(RenderTheme.dark.defaultBackground)
        let samples = (0..<4).map {
            bitmap.pixel(
                x: $0 * metrics.cellWidthPixels,
                yFromTop: 0
            )
        }

        #expect(samples[0] != background)
        #expect(samples[0] != samples[1])
        #expect(samples[1] != samples[2])
        #expect(samples[2] != samples[3])
    }

    @Test("Block Elements damage-row and dirty-rect redraws match a fresh frame")
    func incrementalRedrawsMatchFullFrame() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let previous = try makePlan(input: "\u{2581}\r\nkeep", columns: 4, rows: 2)
        let current = try makePlan(input: "\u{259F}\r\nkeep", columns: 4, rows: 2)
        let full = try renderBitmap(plan: current, metrics: metrics)
        let dirtyRect = CGRect(
            x: 0, y: 0,
            width: metrics.cellSize.width * 4,
            height: metrics.cellSize.height
        )

        let damaged = try renderIncrementalBitmap(
            previous: previous,
            current: current,
            damage: TerminalDamage(rows: [0]),
            metrics: metrics
        )
        let dirty = try renderDirtyRectBitmap(
            previous: previous,
            current: current,
            dirtyRect: dirtyRect,
            metrics: metrics
        )

        expectBitmap(damaged, matches: full)
        expectBitmap(dirty, matches: full)
    }
}
