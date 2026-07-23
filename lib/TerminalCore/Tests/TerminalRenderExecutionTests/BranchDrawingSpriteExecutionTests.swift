// Classification and bitmap proofs for the complete Branch Drawing sprite family.
import CoreGraphics
import Testing

import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning
import TerminalSpriteGeometry

struct BranchDrawingSpriteExecutionTests {
    @Test("Sprite membership is exactly U+F5D0 through U+F60D as single scalars")
    func exactMembership() {
        for value in UInt32(0xF5CF)...UInt32(0xF60E) {
            #expect(
                (BranchDrawingSprite.pattern(for: [Unicode.Scalar(value)!]) != nil)
                    == (0xF5D0...0xF60D).contains(value)
            )
        }
        #expect(BranchDrawingSprite.pattern(for: []) == nil)
        #expect(BranchDrawingSprite.pattern(for: ["\u{F5D0}", "\u{FE0F}"]) == nil)
    }

    @Test("All 62 scalars map exhaustively in Ghostty order")
    func exhaustiveMapping() {
        for offset in 0..<30 {
            #expect(BranchDrawingSprite.pattern(
                for: [Unicode.Scalar(0xF5D0 + offset)!]
            ) == .line(BranchLinePattern(rawValue: offset)!))
        }
        let masks: [Set<BranchDirection>] = [
            [], [.right], [.left], [.left, .right],
            [.down], [.up], [.up, .down], [.right, .down],
            [.left, .down], [.up, .right], [.up, .left],
            [.up, .right, .down], [.up, .down, .left],
            [.right, .down, .left], [.up, .right, .left],
            [.up, .right, .down, .left],
        ]
        for (pair, directions) in masks.enumerated() {
            for pairOffset in 0...1 {
                let offset = 30 + pair * 2 + pairOffset
                #expect(BranchDrawingSprite.pattern(
                    for: [Unicode.Scalar(0xF5D0 + offset)!]
                ) == .node(.init(
                    directions: directions,
                    filled: pairOffset == 0
                )))
            }
        }
    }

    @Test("Every glyph renders, clips, and isolates its adjacent cell", arguments: [1.0, 2.0])
    func exhaustiveBitmapCoverage(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let background = Pixel(RenderTheme.dark.defaultBackground)
        for value in UInt32(0xF5D0)...UInt32(0xF60D) {
            let scalar = Unicode.Scalar(value)!
            let bitmap = try renderBitmap(
                plan: makePlan(input: "\u{1B}[31m\(scalar)", columns: 2, rows: 1),
                metrics: metrics
            )
            #expect(bitmap.pixels(in: cellRect(row: 0, column: 0, metrics: metrics))
                .contains { $0 != background })
            #expect(bitmap.pixels(in: cellRect(row: 0, column: 1, metrics: metrics))
                .allSatisfy { $0 == background })
        }
    }

    @Test("Connected lines meet across horizontal and vertical cell boundaries", arguments: [1.0, 2.0])
    func adjacency(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let background = Pixel(RenderTheme.dark.defaultBackground)
        let horizontal = try renderBitmap(
            plan: makePlan(input: "\u{1B}[31m\u{F5D0}\u{F5D0}", columns: 2, rows: 1),
            metrics: metrics
        )
        let middleY = (metrics.cellHeightPixels - 1) / 2
        #expect(horizontal.pixel(x: metrics.cellWidthPixels - 1, yFromTop: middleY) != background)
        #expect(horizontal.pixel(x: metrics.cellWidthPixels, yFromTop: middleY) != background)

        let vertical = try renderBitmap(
            plan: makePlan(input: "\u{1B}[31m\u{F5D1}\r\n\u{F5D1}", columns: 2, rows: 2),
            metrics: metrics
        )
        let middleX = (metrics.cellWidthPixels - 1) / 2
        #expect(vertical.pixel(x: middleX, yFromTop: metrics.cellHeightPixels - 1) != background)
        #expect(vertical.pixel(x: middleX, yFromTop: metrics.cellHeightPixels) != background)
    }

    @Test("Branch sprites, text, and other sprites replace without stale pixels")
    func replacementAndRedraw() throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: 2))
        for pair in [("\u{F5EE}", "\u{F5EF}"), ("\u{F60D}", "A"), ("A", "\u{F5D6}")] {
            let previous = try makePlan(input: pair.0 + "\r\nkeep", columns: 4, rows: 2)
            let current = try makePlan(input: pair.1 + "\r\nkeep", columns: 4, rows: 2)
            let full = try renderBitmap(plan: current, metrics: metrics)
            let damaged = try renderIncrementalBitmap(
                previous: previous, current: current,
                damage: TerminalDamage(rows: [0]), metrics: metrics
            )
            let dirty = try renderDirtyRectBitmap(
                previous: previous, current: current,
                dirtyRect: CGRect(
                    x: 0, y: 0,
                    width: metrics.cellSize.width * 4,
                    height: metrics.cellSize.height
                ),
                metrics: metrics
            )
            #expect(damaged.bytes == full.bytes)
            #expect(dirty.bytes == full.bytes)
        }
    }
}
