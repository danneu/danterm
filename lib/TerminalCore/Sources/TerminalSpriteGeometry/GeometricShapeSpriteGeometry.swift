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
///
/// A corner triangle is by definition exactly three vertices, so they are stored as
/// three fixed scalar fields in closed-path order (`v0` is the right-angle corner;
/// `v0 -> v1 -> v2 -> v0` closes the path). This encodes the fixed arity in the type
/// and keeps the per-cell draw path free of the array/`map` allocations a collection
/// field would force.
public struct GeometricShapePixelTriangle: Equatable, Sendable {
    public let v0: SpritePixelPoint
    public let v1: SpritePixelPoint
    public let v2: SpritePixelPoint
    public let renderStyle: GeometricShapeRenderStyle

    public init(
        v0: SpritePixelPoint,
        v1: SpritePixelPoint,
        v2: SpritePixelPoint,
        renderStyle: GeometricShapeRenderStyle
    ) {
        self.v0 = v0
        self.v1 = v1
        self.v2 = v2
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

        let horizontalMirror = corner == .topRight || corner == .bottomRight
        let verticalMirror = corner == .bottomLeft || corner == .bottomRight
        // Mirror each canonical vertex in place -- no intermediate array or mapped
        // collection, so the debug-build draw path stays allocation-free.
        func place(x: Int, y: Int) -> SpritePixelPoint {
            SpritePixelPoint(
                x: horizontalMirror ? cellWidthPixels - x : x,
                y: verticalMirror ? cellHeightPixels - y : y
            )
        }
        let v0 = place(x: 0, y: 0)
        let v1 = place(x: 0, y: cellHeightPixels)
        let v2 = place(x: cellWidthPixels, y: 0)
        let renderStyle: GeometricShapeRenderStyle
        if style == .filled
            || cellWidthPixels <= strokeWidthPixels
            || cellHeightPixels <= strokeWidthPixels
        {
            renderStyle = .fill
        } else {
            renderStyle = .innerStroke(widthPixels: strokeWidthPixels)
        }

        // The two legs share the right-angle corner's x/y, and the opposite ends
        // span the cell -- compared directly on the scalars, no collection built.
        assert(v0.x == v1.x)
        assert(v0.y == v2.y)
        assert((v0.x == 0 && v2.x == cellWidthPixels) || (v0.x == cellWidthPixels && v2.x == 0))
        assert((v0.y == 0 && v1.y == cellHeightPixels) || (v0.y == cellHeightPixels && v1.y == 0))
        assert((0...cellWidthPixels).contains(v0.x) && (0...cellHeightPixels).contains(v0.y))
        assert((0...cellWidthPixels).contains(v1.x) && (0...cellHeightPixels).contains(v1.y))
        assert((0...cellWidthPixels).contains(v2.x) && (0...cellHeightPixels).contains(v2.y))
        if case let .innerStroke(widthPixels) = renderStyle {
            assert(widthPixels > 0)
            assert(widthPixels < cellWidthPixels)
            assert(widthPixels < cellHeightPixels)
        }

        return GeometricShapePixelTriangle(v0: v0, v1: v1, v2: v2, renderStyle: renderStyle)
    }
}
