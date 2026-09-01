// Behavioral and bitmap proofs for executor-local Geometric Shapes sprites.
import CoreGraphics
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning

struct GeometricShapeSpriteExecutionTests {
    @Test("A geometric-shape scalar plus a variation selector is not reduced to its first scalar")
    func variationSelectorTakesFontPath() throws {
        // Intent: a multi-scalar cell whose first scalar is a procedural geometric
        //   shape must not be reduced to that scalar and drawn as the sprite; the
        //   cell must take the font/fallback path instead.
        // Why it exists: the executor's `count == 1` gate is the sole guard that
        //   keeps multi-scalar graphemes off the procedural path. Once the family
        //   classifiers take a single scalar, that guarantee can no longer be
        //   expressed at the `pattern(for:)` unit level (the old multi-scalar-array
        //   assertions this replaces), so it needs an executor-level test.
        // Scenario: rendering "\u{25E2}\u{FE0F}" (bottom-right corner + emoji
        //   variation selector) must differ from the bare "\u{25E2}", which draws
        //   the procedural filled corner triangle.
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let cell = cellRect(row: 0, column: 0, metrics: metrics)
        let bare = try renderBitmap(
            plan: makePlan(input: "\u{25E2}", columns: 2, rows: 1),
            metrics: metrics
        )
        let withSelector = try renderBitmap(
            plan: makePlan(input: "\u{25E2}\u{FE0F}", columns: 2, rows: 1),
            metrics: metrics
        )
        #expect(bare.pixels(in: cell) != withSelector.pixels(in: cell))
    }

    @Test("All triangles use their foreground, remain contained, and isolate adjacent cells", arguments: [1.0, 2.0])
    func exhaustiveBitmapCoverage(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        for scalar in ["\u{25E2}", "\u{25E3}", "\u{25E4}", "\u{25E5}",
                       "\u{25F8}", "\u{25F9}", "\u{25FA}", "\u{25FF}"] {
            let bitmap = try renderBitmap(
                plan: makePlan(input: "\u{1B}[31m\(scalar)", columns: 2, rows: 1),
                metrics: metrics
            )
            let cell = cellRect(row: 0, column: 0, metrics: metrics)
            let adjacent = cellRect(row: 0, column: 1, metrics: metrics)
            let foreground = Pixel(RenderTheme.dark.ansiColors[1])
            let background = Pixel(RenderTheme.dark.defaultBackground)
            let pixels = bitmap.pixels(in: cell)

            #expect(pixels.contains(foreground))
            #expect(pixels.contains(background))
            #expect(pixels.allSatisfy {
                $0.isOpaqueBlend(between: foreground, and: background)
            })
            #expect(bitmap.pixels(in: adjacent).allSatisfy { $0 == background })
        }
    }

    @Test("Filled triangles cover their corner while outlines retain only the inner border")
    func filledAndOutlinedCoverage() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let filled = try renderBitmap(
            plan: makePlan(input: "\u{25E4}", columns: 2, rows: 1),
            metrics: metrics
        )
        let outlined = try renderBitmap(
            plan: makePlan(input: "\u{25F8}", columns: 2, rows: 1),
            metrics: metrics
        )
        let cell = cellRect(row: 0, column: 0, metrics: metrics)
        let background = Pixel(RenderTheme.dark.defaultBackground)

        #expect(filled.inkCount(in: cell) > outlined.inkCount(in: cell))
        #expect(cell.x.allSatisfy { filled.pixel(x: $0, yFromTop: cell.y.lowerBound) != background })
        #expect(cell.x.allSatisfy { outlined.pixel(x: $0, yFromTop: cell.y.lowerBound) != background })
        #expect(cell.y.allSatisfy { filled.pixel(x: cell.x.lowerBound, yFromTop: $0) != background })
        #expect(cell.y.allSatisfy { outlined.pixel(x: cell.x.lowerBound, yFromTop: $0) != background })
        #expect(filled.pixel(x: cell.x.upperBound - 1, yFromTop: cell.y.upperBound - 1) == background)
        #expect(outlined.pixel(x: cell.x.upperBound - 1, yFromTop: cell.y.upperBound - 1) == background)
    }

    @Test("Filled and outlined corners are bitmap mirrors within raster quantization", arguments: [1.0, 2.0])
    func bitmapMirroring(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        for pair in [("\u{25E4}", "\u{25E5}"), ("\u{25F8}", "\u{25F9}")] {
            let left = try spriteCellPixels(input: pair.0, metrics: metrics)
            let right = try spriteCellPixels(input: pair.1, metrics: metrics)
            for y in 0..<metrics.cellHeightPixels {
                for x in 0..<metrics.cellWidthPixels {
                    let leftPixel = left[y * metrics.cellWidthPixels + x]
                    let rightPixel = right[
                        y * metrics.cellWidthPixels + metrics.cellWidthPixels - 1 - x
                    ]
                    #expect(leftPixel.isWithinOneChannelValue(of: rightPixel))
                }
            }
        }
    }

    @Test("Filled, outlined, and text cells replace one another without stale pixels")
    func replacements() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        for pair in [("\u{25E2}", "\u{25FF}"), ("\u{25FF}", "A"), ("A", "\u{25E2}")] {
            let previous = try makePlan(input: pair.0, columns: 3, rows: 1)
            let current = try makePlan(input: pair.1, columns: 3, rows: 1)
            let full = try renderBitmap(plan: current, metrics: metrics)
            let damaged = try renderIncrementalBitmap(
                previous: previous,
                current: current,
                damage: TerminalDamage(rows: [0]),
                metrics: metrics
            )
            expectBitmap(damaged, matches: full)
        }
    }

    @Test("Full, damage-row, and dirty-rectangle redraws agree for triangle replacement")
    func incrementalRedrawsMatchFullFrame() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        let previous = try makePlan(input: "\u{25E2}\r\nkeep", columns: 4, rows: 2)
        let current = try makePlan(input: "\u{25F8}\r\nkeep", columns: 4, rows: 2)
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

private func spriteCellPixels(
    input: String,
    metrics: TerminalRenderMetrics
) throws -> [Pixel] {
    let bitmap = try renderBitmap(
        plan: makePlan(input: input, columns: 2, rows: 1),
        metrics: metrics
    )
    return bitmap.pixels(in: cellRect(row: 0, column: 0, metrics: metrics))
}

private extension Pixel {
    func isOpaqueBlend(between first: Self, and second: Self) -> Bool {
        func contains(_ value: UInt8, _ lower: UInt8, _ upper: UInt8) -> Bool {
            min(lower, upper)...max(lower, upper) ~= value
        }

        return alpha == 255
            && contains(red, first.red, second.red)
            && contains(green, first.green, second.green)
            && contains(blue, first.blue, second.blue)
    }

    func isWithinOneChannelValue(of other: Self) -> Bool {
        abs(Int(red) - Int(other.red)) <= 1
            && abs(Int(green) - Int(other.green)) <= 1
            && abs(Int(blue) - Int(other.blue)) <= 1
            && alpha == other.alpha
    }
}
