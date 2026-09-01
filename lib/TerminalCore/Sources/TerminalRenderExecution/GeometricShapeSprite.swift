// Render-boundary conversion for corner triangles: cell translation and Core Graphics types.
// Scalar decoding lives in `GeometricShapeSpriteGeometry`.
import CoreGraphics
import TerminalSpriteGeometry

/// Holds one translated triangle while keeping its path policy in pure geometry.
struct GeometricShapeRenderTriangle {
    let geometry: GeometricShapePixelTriangle
    let cellOrigin: CGPoint
}

/// Places one decoded Geometric Shapes triangle at its terminal cell in display points.
enum GeometricShapeSprite {
    static func triangle(
        pattern: GeometricShapePattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics
    ) -> GeometricShapeRenderTriangle? {
        let strokeWidth = metrics.lightStrokePixels
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
