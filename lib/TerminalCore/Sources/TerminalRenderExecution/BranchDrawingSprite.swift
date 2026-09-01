// Render-boundary conversion for Branch Drawing sprites: cell translation and Core Graphics
// types. Scalar decoding lives in `BranchDrawingSpriteGeometry`.
import CoreGraphics
import TerminalSpriteGeometry

/// Holds one translated Branch Drawing glyph while its geometry stays cell-local.
struct BranchDrawingRenderGeometry {
    let geometry: BranchPixelGeometry
    let cellOrigin: CGPoint
}

/// Places one decoded Branch Drawing pattern at its terminal cell in display points.
enum BranchDrawingSprite {
    static func geometry(
        pattern: BranchDrawingPattern,
        row: Int,
        column: Int,
        metrics: TerminalRenderMetrics
    ) -> BranchDrawingRenderGeometry {
        let light = metrics.lightStrokePixels
        return BranchDrawingRenderGeometry(
            geometry: BranchDrawingSpriteGeometry.geometry(
                pattern: pattern,
                cellWidthPixels: metrics.cellWidthPixels,
                cellHeightPixels: metrics.cellHeightPixels,
                lightStrokePixels: light
            ),
            cellOrigin: CGPoint(
                x: CGFloat(column * metrics.cellWidthPixels) / metrics.displayScale,
                y: CGFloat(row * metrics.cellHeightPixels) / metrics.displayScale
            )
        )
    }
}
