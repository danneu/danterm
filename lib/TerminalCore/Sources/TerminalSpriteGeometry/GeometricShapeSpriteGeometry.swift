// Cell-local physical-pixel geometry for Geometric Shapes corner triangles.

/// Selects the corner whose two cell edges form a triangle's right angle.
public enum GeometricShapeCorner: CaseIterable, Equatable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

/// Distinguishes solid corner coverage from Ghostty-style inner outlines.
public enum GeometricShapeStyle: Equatable, Sendable {
    case filled
    case outlined
}

/// Makes filled and inner-stroked raster behavior explicit at the pure geometry seam.
public enum GeometricShapeRenderStyle: Equatable, Sendable {
    case fill
    case innerStroke(widthPixels: Int)
}

/// Carries one closed triangle path and its scarcity-resolved rendering behavior.
public struct GeometricShapePixelTriangle: Equatable, Sendable {
    public let points: [SpritePixelPoint]
    public let renderStyle: GeometricShapeRenderStyle

    public init(points: [SpritePixelPoint], renderStyle: GeometricShapeRenderStyle) {
        self.points = points
        self.renderStyle = renderStyle
    }
}

/// Derives every corner from one canonical path so odd dimensions cannot drift.
public enum GeometricShapeSpriteGeometry {
    public static func triangle(
        corner: GeometricShapeCorner,
        style: GeometricShapeStyle,
        cellWidthPixels: Int,
        cellHeightPixels: Int,
        strokeWidthPixels: Int
    ) -> GeometricShapePixelTriangle? {
        precondition(cellWidthPixels >= 0 && cellHeightPixels >= 0)
        precondition(strokeWidthPixels > 0)
        guard cellWidthPixels > 0 && cellHeightPixels > 0 else { return nil }

        let canonical = [
            SpritePixelPoint(x: 0, y: 0),
            SpritePixelPoint(x: 0, y: cellHeightPixels),
            SpritePixelPoint(x: cellWidthPixels, y: 0),
        ]
        let horizontalMirror = corner == .topRight || corner == .bottomRight
        let verticalMirror = corner == .bottomLeft || corner == .bottomRight
        let points = canonical.map { point in
            SpritePixelPoint(
                x: horizontalMirror ? cellWidthPixels - point.x : point.x,
                y: verticalMirror ? cellHeightPixels - point.y : point.y
            )
        }
        let renderStyle: GeometricShapeRenderStyle
        if style == .filled
            || cellWidthPixels <= strokeWidthPixels
            || cellHeightPixels <= strokeWidthPixels
        {
            renderStyle = .fill
        } else {
            renderStyle = .innerStroke(widthPixels: strokeWidthPixels)
        }

        assert(points.count == 3)
        assert(Set(points.map(\.x)) == Set([0, cellWidthPixels]))
        assert(Set(points.map(\.y)) == Set([0, cellHeightPixels]))
        assert(points.allSatisfy {
            (0...cellWidthPixels).contains($0.x)
                && (0...cellHeightPixels).contains($0.y)
        })
        if case let .innerStroke(widthPixels) = renderStyle {
            assert(widthPixels > 0)
            assert(widthPixels < cellWidthPixels)
            assert(widthPixels < cellHeightPixels)
        }

        return GeometricShapePixelTriangle(points: points, renderStyle: renderStyle)
    }
}
