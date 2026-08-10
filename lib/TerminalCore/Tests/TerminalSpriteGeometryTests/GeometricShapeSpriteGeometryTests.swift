// Pure physical-pixel geometry proofs for Geometric Shapes corner triangles.
import Testing

@testable import TerminalSpriteGeometry

struct GeometricShapeSpriteGeometryTests {
    @Test(
        "Corner triangles use the complete cell and share exact mirrored endpoints",
        arguments: [
            TriangleGeometrySample(width: 8, height: 16),
            TriangleGeometrySample(width: 7, height: 16),
            TriangleGeometrySample(width: 8, height: 15),
            TriangleGeometrySample(width: 7, height: 15),
            TriangleGeometrySample(width: 2, height: 3),
            TriangleGeometrySample(width: 1, height: 1),
        ]
    )
    func exactCornerGeometry(sample: TriangleGeometrySample) {
        let topLeft = GeometricShapeSpriteGeometry.triangle(
            corner: .topLeft,
            style: .filled,
            cellWidthPixels: sample.width,
            cellHeightPixels: sample.height,
            strokeWidthPixels: 1
        )
        #expect(topLeft?.vertices == [
            SpritePixelPoint(x: 0, y: 0),
            SpritePixelPoint(x: 0, y: sample.height),
            SpritePixelPoint(x: sample.width, y: 0),
        ])

        for corner in GeometricShapeCorner.allCases {
            let triangle = GeometricShapeSpriteGeometry.triangle(
                corner: corner,
                style: .outlined,
                cellWidthPixels: sample.width,
                cellHeightPixels: sample.height,
                strokeWidthPixels: 1
            )
            #expect(triangle?.vertices == topLeft?.vertices.map {
                $0.transformed(
                    horizontal: corner.isRight,
                    vertical: corner.isBottom,
                    width: sample.width,
                    height: sample.height
                )
            })
        }
    }

    @Test("Outlined triangles retain one-pixel inner strokes or degrade as a whole shape")
    func outlineScarcity() {
        #expect(
            GeometricShapeSpriteGeometry.triangle(
                corner: .bottomRight,
                style: .outlined,
                cellWidthPixels: 8,
                cellHeightPixels: 16,
                strokeWidthPixels: 2
            )?.renderStyle == .innerStroke(widthPixels: 2)
        )
        #expect(
            GeometricShapeSpriteGeometry.triangle(
                corner: .bottomRight,
                style: .outlined,
                cellWidthPixels: 2,
                cellHeightPixels: 7,
                strokeWidthPixels: 1
            )?.renderStyle == .innerStroke(widthPixels: 1)
        )
        #expect(
            GeometricShapeSpriteGeometry.triangle(
                corner: .bottomRight,
                style: .outlined,
                cellWidthPixels: 1,
                cellHeightPixels: 7,
                strokeWidthPixels: 1
            )?.renderStyle == .fill
        )
        #expect(
            GeometricShapeSpriteGeometry.triangle(
                corner: .bottomRight,
                style: .outlined,
                cellWidthPixels: 0,
                cellHeightPixels: 7,
                strokeWidthPixels: 1
            ) == nil
        )
    }

    @Test("All triangles are deterministic, contained, and mirrored across a bounded size matrix")
    func boundedGeometryMatrix() {
        for width in 1...17 {
            for height in 1...33 {
                let context = Comment(rawValue: "cell \(width)x\(height)")
                let topLeft = GeometricShapeSpriteGeometry.triangle(
                    corner: .topLeft,
                    style: .filled,
                    cellWidthPixels: width,
                    cellHeightPixels: height,
                    strokeWidthPixels: 1
                )
                for corner in GeometricShapeCorner.allCases {
                    let first = GeometricShapeSpriteGeometry.triangle(
                        corner: corner,
                        style: .outlined,
                        cellWidthPixels: width,
                        cellHeightPixels: height,
                        strokeWidthPixels: 1
                    )
                    let second = GeometricShapeSpriteGeometry.triangle(
                        corner: corner,
                        style: .outlined,
                        cellWidthPixels: width,
                        cellHeightPixels: height,
                        strokeWidthPixels: 1
                    )
                    #expect(first == second, context)
                    #expect(first?.vertices.allSatisfy {
                        (0...width).contains($0.x) && (0...height).contains($0.y)
                    } == true, context)
                    #expect(first?.vertices == topLeft?.vertices.map {
                        $0.transformed(
                            horizontal: corner.isRight,
                            vertical: corner.isBottom,
                            width: width,
                            height: height
                        )
                    }, context)
                }
            }
        }
    }
}

struct TriangleGeometrySample: Sendable, CustomTestStringConvertible {
    let width: Int
    let height: Int

    var testDescription: String { "\(width)x\(height)" }
}

private extension GeometricShapePixelTriangle {
    // Packages the three scalar vertices into an array so tests can assert the
    // closed-path order and positions; the collection lives only in the test, off
    // the hot draw path.
    var vertices: [SpritePixelPoint] { [v0, v1, v2] }
}

private extension SpritePixelPoint {
    func transformed(horizontal: Bool, vertical: Bool, width: Int, height: Int) -> Self {
        Self(
            x: horizontal ? width - x : x,
            y: vertical ? height - y : y
        )
    }
}

private extension GeometricShapeCorner {
    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
}
