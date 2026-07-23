// Pure physical-pixel geometry proofs for Unicode Block Elements sprites.
import Testing

@testable import TerminalSpriteGeometry

struct BlockElementSpriteGeometryTests {
    @Test(
        "Aligned blocks round their requested eighth and half extents",
        arguments: [
            BlockElementGeometrySample(
                pattern: .aligned(horizontal: .full, vertical: .start, widthEighths: 8, heightEighths: 4),
                width: 7, height: 9,
                rects: [SpritePixelRect(x: 0, y: 0, width: 7, height: 5)]
            ),
            BlockElementGeometrySample(
                pattern: .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 1),
                width: 7, height: 9,
                rects: [SpritePixelRect(x: 0, y: 8, width: 7, height: 1)]
            ),
            BlockElementGeometrySample(
                pattern: .aligned(horizontal: .start, vertical: .full, widthEighths: 7, heightEighths: 8),
                width: 7, height: 9,
                rects: [SpritePixelRect(x: 0, y: 0, width: 6, height: 9)]
            ),
            BlockElementGeometrySample(
                pattern: .aligned(horizontal: .end, vertical: .full, widthEighths: 1, heightEighths: 8),
                width: 7, height: 9,
                rects: [SpritePixelRect(x: 6, y: 0, width: 1, height: 9)]
            ),
            BlockElementGeometrySample(
                pattern: .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 1),
                width: 3, height: 3,
                rects: []
            ),
        ]
    )
    func alignedGoldenGeometry(sample: BlockElementGeometrySample) {
        #expect(
            BlockElementSpriteGeometry.rects(
                pattern: sample.pattern,
                cellWidthPixels: sample.width,
                cellHeightPixels: sample.height
            ) == sample.rects
        )
    }

    @Test("Quadrants overlap at odd-size center axes so adjoining fills have no seam")
    func seamFreeOddQuadrants() {
        let rects = BlockElementSpriteGeometry.rects(
            pattern: .quadrants([.topLeft, .topRight, .bottomLeft, .bottomRight]),
            cellWidthPixels: 7,
            cellHeightPixels: 9
        )

        #expect(rects == [
            SpritePixelRect(x: 0, y: 0, width: 4, height: 5),
            SpritePixelRect(x: 3, y: 0, width: 4, height: 5),
            SpritePixelRect(x: 0, y: 4, width: 4, height: 5),
            SpritePixelRect(x: 3, y: 4, width: 4, height: 5),
        ])
    }

    @Test("Every Block Elements pattern remains contained across positive cell sizes")
    func boundedGeometryMatrix() {
        let patterns = BlockElementPattern.allGeometryPatterns
        for width in 1...17 {
            for height in 1...33 {
                let context = Comment(rawValue: "cell \(width)x\(height)")
                for pattern in patterns {
                    let rects = BlockElementSpriteGeometry.rects(
                        pattern: pattern,
                        cellWidthPixels: width,
                        cellHeightPixels: height
                    )
                    for rect in rects {
                        #expect(
                            rect.x >= 0 && rect.y >= 0
                                && rect.width > 0 && rect.height > 0
                                && rect.x + rect.width <= width
                                && rect.y + rect.height <= height,
                            context
                        )
                    }
                }
            }
        }
    }
}

struct BlockElementGeometrySample: Sendable, CustomTestStringConvertible {
    let pattern: BlockElementPattern
    let width: Int
    let height: Int
    let rects: [SpritePixelRect]

    var testDescription: String { "\(width)x\(height) \(pattern)" }
}

private extension BlockElementPattern {
    static let allGeometryPatterns: [Self] = [
        .aligned(horizontal: .full, vertical: .start, widthEighths: 8, heightEighths: 4),
        .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 1),
        .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 2),
        .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 3),
        .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 4),
        .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 5),
        .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 6),
        .aligned(horizontal: .full, vertical: .end, widthEighths: 8, heightEighths: 7),
        .full(shade: .solid),
        .aligned(horizontal: .start, vertical: .full, widthEighths: 7, heightEighths: 8),
        .aligned(horizontal: .start, vertical: .full, widthEighths: 6, heightEighths: 8),
        .aligned(horizontal: .start, vertical: .full, widthEighths: 5, heightEighths: 8),
        .aligned(horizontal: .start, vertical: .full, widthEighths: 4, heightEighths: 8),
        .aligned(horizontal: .start, vertical: .full, widthEighths: 3, heightEighths: 8),
        .aligned(horizontal: .start, vertical: .full, widthEighths: 2, heightEighths: 8),
        .aligned(horizontal: .start, vertical: .full, widthEighths: 1, heightEighths: 8),
        .aligned(horizontal: .end, vertical: .full, widthEighths: 4, heightEighths: 8),
        .full(shade: .light), .full(shade: .medium), .full(shade: .dark),
        .aligned(horizontal: .full, vertical: .start, widthEighths: 8, heightEighths: 1),
        .aligned(horizontal: .end, vertical: .full, widthEighths: 1, heightEighths: 8),
        .quadrants([.bottomLeft]), .quadrants([.bottomRight]), .quadrants([.topLeft]),
        .quadrants([.topLeft, .bottomLeft, .bottomRight]),
        .quadrants([.topLeft, .bottomRight]),
        .quadrants([.topLeft, .topRight, .bottomLeft]),
        .quadrants([.topLeft, .topRight, .bottomRight]),
        .quadrants([.topRight]), .quadrants([.topRight, .bottomLeft]),
        .quadrants([.topRight, .bottomLeft, .bottomRight]),
    ]
}
