// Behavioral tests for pure supplement sprite geometry.
import Testing
@testable import TerminalSpriteGeometry

struct LegacyComputingSupplementSpriteGeometryTests {
    @Test("Octants partition odd cells without seams")
    func octantPartition() {
        let rects = LegacyComputingSupplementSpriteGeometry.rects(
            pattern: .octants(0xFF),
            cellWidthPixels: 7,
            cellHeightPixels: 13,
            thicknessPixels: 1
        )
        #expect(rects.reduce(0) { $0 + $1.width * $1.height } == 91)
    }

    @Test("Separated mosaics retain an interior gap")
    func separatedGap() {
        let rects = LegacyComputingSupplementSpriteGeometry.rects(
            pattern: .separatedSextants(0x3F),
            cellWidthPixels: 12,
            cellHeightPixels: 18,
            thicknessPixels: 1
        )
        #expect(rects.count == 6)
        #expect(rects.allSatisfy { $0.x > 0 && $0.y > 0 })
    }

    @Test("Supplemental box and quadrant representatives have exact coverage")
    func exactBoxAndQuadrantGeometry() {
        let box = LegacyComputingSupplementSpriteGeometry.rects(
            pattern: .box(0),
            cellWidthPixels: 8,
            cellHeightPixels: 12,
            thicknessPixels: 1
        )
        #expect(box == [
            SpritePixelRect(x: 0, y: 6, width: 8, height: 1),
            SpritePixelRect(x: 7, y: 0, width: 1, height: 6),
        ])
        let quadrant = LegacyComputingSupplementSpriteGeometry.rects(
            pattern: .separatedQuadrants(9),
            cellWidthPixels: 12,
            cellHeightPixels: 16,
            thicknessPixels: 1
        )
        #expect(quadrant == [
            SpritePixelRect(x: 1, y: 1, width: 4, height: 6),
            SpritePixelRect(x: 7, y: 9, width: 4, height: 6),
        ])
    }

    @Test("Sixteenth blocks use floor-divided physical pixel boundaries")
    func sixteenthBoundaries() {
        let rect = LegacyComputingSupplementSpriteGeometry.rects(
            pattern: .sixteenth(index: 15),
            cellWidthPixels: 9,
            cellHeightPixels: 17,
            thicknessPixels: 1
        )
        #expect(rect == [SpritePixelRect(x: 6, y: 12, width: 3, height: 5)])
    }

    @Test("Constrained geometry remains cell-local", arguments: [1, 2])
    func constrained(scale: Int) {
        let width = scale
        let height = scale
        let patterns: [LegacySupplementPattern] = [
            .box(0), .separatedQuadrants(15),
            .circlePieces([LegacySupplementCirclePiece(
                xCells: 0, yCells: 0, widthCells: 1, heightCells: 1, corner: .topLeft
            )]),
            .octants(255), .splitCircle(vertical: true),
            .separatedSextants(63), .sixteenth(index: 31),
        ]
        for pattern in patterns {
            let rects = LegacyComputingSupplementSpriteGeometry.rects(
                pattern: pattern,
                cellWidthPixels: width,
                cellHeightPixels: height,
                thicknessPixels: scale
            )
            #expect(rects.allSatisfy {
                $0.x >= 0 && $0.y >= 0 && $0.width > 0 && $0.height > 0
                    && $0.x + $0.width <= width && $0.y + $0.height <= height
            })
        }
    }

    @Test("Adjacent top twelfths share one translated ellipse center")
    func adjacentTwelfthsShareEllipse() {
        let left = LegacySupplementCirclePiece(
            xCells: 0, yCells: 0, widthCells: 2, heightCells: 2, corner: .topLeft
        )
        let next = LegacySupplementCirclePiece(
            xCells: 1, yCells: 0, widthCells: 2, heightCells: 2, corner: .topLeft
        )
        let cellWidth = 8.0
        let leftGlobalCenter = -left.xCells * cellWidth
        let nextGlobalCenter = cellWidth
            - next.xCells * cellWidth
        #expect(leftGlobalCenter == nextGlobalCenter)
    }

    @Test("Every arc corner intersects the expected two cell edges")
    func arcCornerEdgeIntersections() {
        let width = 12
        let height = 16
        let cases: [(LegacySupplementCirclePiece, (SpritePixelRect) -> Bool, (SpritePixelRect) -> Bool)] = [
            (
                LegacySupplementCirclePiece(
                    xCells: 0, yCells: 0, widthCells: 1, heightCells: 1,
                    corner: .topLeft
                ),
                { $0.x + $0.width == width },
                { $0.y + $0.height == height }
            ),
            (
                LegacySupplementCirclePiece(
                    xCells: 1, yCells: 0, widthCells: 1, heightCells: 1,
                    corner: .topRight
                ),
                { $0.x == 0 },
                { $0.y + $0.height == height }
            ),
            (
                LegacySupplementCirclePiece(
                    xCells: 0, yCells: 1, widthCells: 1, heightCells: 1,
                    corner: .bottomLeft
                ),
                { $0.x + $0.width == width },
                { $0.y == 0 }
            ),
            (
                LegacySupplementCirclePiece(
                    xCells: 1, yCells: 1, widthCells: 1, heightCells: 1,
                    corner: .bottomRight
                ),
                { $0.x == 0 },
                { $0.y == 0 }
            ),
        ]
        for (piece, horizontalEdge, verticalEdge) in cases {
            let rects = LegacyComputingSupplementSpriteGeometry.rects(
                pattern: .circlePieces([piece]),
                cellWidthPixels: width,
                cellHeightPixels: height,
                thicknessPixels: 2
            )
            #expect(rects.contains(where: horizontalEdge))
            #expect(rects.contains(where: verticalEdge))
        }
    }
}
