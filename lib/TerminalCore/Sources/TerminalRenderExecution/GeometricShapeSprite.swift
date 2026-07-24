// Exact Unicode classification and render-boundary conversion for corner triangles.
import CoreGraphics
import TerminalSpriteGeometry

/// Couples the finite Geometric Shapes codepoint set to corner and fill behavior.
struct GeometricShapePattern: Equatable, Sendable {
    let corner: GeometricShapeCorner
    let style: GeometricShapeStyle
}

/// Holds one translated triangle while keeping its path policy in pure geometry.
struct GeometricShapeRenderTriangle {
    let geometry: GeometricShapePixelTriangle
    let cellOrigin: CGPoint
}

/// Maps the supported Geometric Shapes scalars and translates their pure geometry.
enum GeometricShapeSprite {
    /// Coarse routing span for the classifier switch. Wider than the sparse membership decoded
    /// in `pattern(for:)`; interior gaps return nil there and fall through to the font path.
    static let coarseRange: ClosedRange<UInt32> = 0x25E2...0x25FF

    static func pattern(for scalars: [Unicode.Scalar]) -> GeometricShapePattern? {
        guard scalars.count == 1, let value = scalars.first?.value else { return nil }
        return switch value {
        case 0x25E2: GeometricShapePattern(corner: .bottomRight, style: .filled)
        case 0x25E3: GeometricShapePattern(corner: .bottomLeft, style: .filled)
        case 0x25E4: GeometricShapePattern(corner: .topLeft, style: .filled)
        case 0x25E5: GeometricShapePattern(corner: .topRight, style: .filled)
        case 0x25F8: GeometricShapePattern(corner: .topLeft, style: .outlined)
        case 0x25F9: GeometricShapePattern(corner: .topRight, style: .outlined)
        case 0x25FA: GeometricShapePattern(corner: .bottomLeft, style: .outlined)
        case 0x25FF: GeometricShapePattern(corner: .bottomRight, style: .outlined)
        default: nil
        }
    }

    static func triangle(
        pattern: GeometricShapePattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics
    ) -> GeometricShapeRenderTriangle? {
        let strokeWidth = max(
            1,
            Int((metrics.underlineThickness * metrics.displayScale).rounded())
        )
        guard let geometry = GeometricShapeSpriteGeometry.triangle(
            corner: pattern.corner,
            style: pattern.style,
            cellWidthPixels: metrics.cellWidthPixels,
            cellHeightPixels: metrics.cellHeightPixels,
            strokeWidthPixels: strokeWidth
        ) else {
            return nil
        }
        return GeometricShapeRenderTriangle(
            geometry: geometry,
            cellOrigin: CGPoint(
                x: CGFloat(column * metrics.cellWidthPixels) / metrics.displayScale,
                y: CGFloat(row * metrics.cellHeightPixels) / metrics.displayScale
            )
        )
    }
}
