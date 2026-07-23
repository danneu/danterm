// Classification and bitmap proofs for supplement sprites.
import CoreGraphics
import Testing
import TerminalCore
@testable import TerminalRenderExecution
import TerminalRenderPlanning
import TerminalSpriteGeometry

struct LegacyComputingSupplementSpriteExecutionTests {
    @Test("Sprite membership exactly matches Ghostty's supplement ranges")
    func exactMembership() {
        let expected = Set(LegacyComputingSupplementSprite.implementedRanges.flatMap { Array($0) })
        for value in UInt32(0x1CC00)...UInt32(0x1CEBF) {
            let actual = LegacyComputingSupplementSprite.pattern(for: [Unicode.Scalar(value)!]) != nil
            #expect(actual == expected.contains(value))
        }
        #expect(LegacyComputingSupplementSprite.pattern(for: ["\u{1CD00}", "\u{FE0F}"]) == nil)
    }

    @Test("Every subgroup scalar decodes in exact Unicode order")
    func exhaustivePatternDecoding() {
        for offset in 0..<4 {
            #expect(pattern(0x1CC1B + UInt32(offset)) == .box(UInt8(offset)))
            #expect(pattern(0x1CE16 + UInt32(offset)) == .box(UInt8(offset + 4)))
        }
        for value in UInt32(1)...15 {
            #expect(pattern(0x1CC20 + value) == .separatedQuadrants(UInt8(value)))
        }
        for value in UInt32(1)...63 {
            #expect(pattern(0x1CE50 + value) == .separatedSextants(UInt8(value)))
        }
        for index in 0..<32 {
            #expect(pattern(0x1CE90 + UInt32(index)) == .sixteenth(index: index))
        }
        let circles: [LegacySupplementCirclePiece] = [
            piece(0,0,2,2,.topLeft), piece(1,0,2,2,.topLeft),
            piece(2,0,2,2,.topRight), piece(3,0,2,2,.topRight),
            piece(0,1,2,2,.topLeft), piece(0,0,1,1,.topLeft),
            piece(1,0,1,1,.topRight), piece(3,1,2,2,.topRight),
            piece(0,2,2,2,.bottomLeft), piece(0,1,1,1,.bottomLeft),
            piece(1,1,1,1,.bottomRight), piece(3,2,2,2,.bottomRight),
            piece(0,3,2,2,.bottomLeft), piece(1,3,2,2,.bottomLeft),
            piece(2,3,2,2,.bottomRight), piece(3,3,2,2,.bottomRight),
        ]
        for (index, circle) in circles.enumerated() {
            #expect(pattern(0x1CC30 + UInt32(index)) == .circlePieces([circle]))
        }
        #expect(pattern(0x1CE0B) == .circlePieces([
            piece(0,0,1,0.5,.topLeft), piece(0,0,1,0.5,.bottomLeft),
        ]))
        #expect(pattern(0x1CE0C) == .circlePieces([
            piece(1,0,1,0.5,.topRight), piece(1,0,1,0.5,.bottomRight),
        ]))
    }

    @Test("Every supported scalar renders only inside its cell", arguments: [1.0, 2.0])
    func exhaustiveBitmapCoverage(scale: CGFloat) throws {
        let metrics = try #require(TerminalRenderMetrics(displayScale: scale))
        let background = Pixel(RenderTheme.dark.defaultBackground)
        for range in LegacyComputingSupplementSprite.implementedRanges {
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
        #expect(damaged.bytes == full.bytes)
        #expect(dirty.bytes == full.bytes)
    }

    private func pattern(_ value: UInt32) -> LegacySupplementPattern? {
        LegacyComputingSupplementSprite.pattern(for: [Unicode.Scalar(value)!])
    }

    private func piece(
        _ x: Double, _ y: Double, _ width: Double, _ height: Double,
        _ corner: LegacySupplementArcCorner
    ) -> LegacySupplementCirclePiece {
        LegacySupplementCirclePiece(
            xCells: x, yCells: y, widthCells: width, heightCells: height, corner: corner
        )
    }
}
